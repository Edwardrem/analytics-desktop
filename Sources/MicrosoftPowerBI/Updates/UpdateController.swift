import AppKit
import Combine
import CryptoKit
import FacetCore

/// Checks GitHub for new releases, offers them on the What's New page, and downloads, verifies and installs
/// the one the user accepts. Automatic checks run a minute after launch, then daily, while the setting is on.
@MainActor
final class UpdateController: ObservableObject {
    static let shared = UpdateController()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(AvailableUpdate)
        case downloading(AvailableUpdate, received: Int64, total: Int64)
        /// Downloaded, verified and staged; installs as the app quits.
        case ready(AvailableUpdate)
        case failed(String)
    }

    enum Key {
        static let skipped = "updates.skippedVersion"
        static let lastCheck = "updates.lastCheck"
        static let remindAfter = "updates.remindAfter"
        static let whatsNewPending = "updates.whatsNewPending"
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastCheck: Date?

    let http: UpdateHTTP
    let cache: ReleaseListCache
    let defaults: UserDefaults
    var installed: SemanticVersion
    var appURL: URL
    var publicKey: () throws -> Curve25519.Signing.PublicKey
    /// Shows the What's New page; replaced in tests.
    var present: (WhatsNewContent) -> Void = { WhatsNewWindow.show($0) }

    private var timer: Timer?
    private var staged: (app: StagedApp, work: URL)?
    private var quitObserver: NSObjectProtocol?
    static let launchDelay: TimeInterval = 60
    static let interval: TimeInterval = 24 * 60 * 60

    init(http: UpdateHTTP = UpdateHTTP(), cache: ReleaseListCache = .standard, defaults: UserDefaults = AppSettings.defaults,
         installed: SemanticVersion? = nil, appURL: URL = Bundle.main.bundleURL,
         publicKey: @escaping () throws -> Curve25519.Signing.PublicKey = { try UpdateSignature.bundledKey() }) {
        self.http = http; self.cache = cache; self.defaults = defaults
        self.installed = installed ?? SemanticVersion(AppIdentity.version) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
        self.appURL = appURL
        self.publicKey = publicKey
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
    }

    var automatic: Bool { defaults.object(forKey: AppSettings.Key.checkForUpdates.rawValue) as? Bool ?? true }
    var includeBeta: Bool { defaults.bool(forKey: AppSettings.Key.includeBetaUpdates.rawValue) }
    var skipped: SemanticVersion? { defaults.string(forKey: Key.skipped).flatMap(SemanticVersion.init) }

    // MARK: Scheduling

    /// At launch: shows What's New after an update, then schedules the automatic checks.
    func start() {
        showWhatsNewAfterInstall()
        timer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchDelay) { [weak self] in
            guard let self, self.automatic else { return }
            Task { await self.check(manual: false) }
        }
        // An hourly look at the clock keeps "daily" true across sleep, and picks up the setting being turned on.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automatic, self.isDue(now: Date()) else { return }
                await self.check(manual: false)
            }
        }
    }

    func isDue(now: Date) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= Self.interval - 60
    }

    // MARK: Checking

    /// Asks GitHub for releases. A manual check (Help ▸ Check for Updates…) always reports back and also offers
    /// a version the user skipped; an automatic one stays quiet unless there is something new to offer.
    func check(manual: Bool) async {
        switch phase {
        case .ready(let u):
            if manual { present(.offer(u)) }
            return
        case .checking, .downloading: return
        default: break
        }
        phase = .checking
        do {
            let releases = try await cache.fetch(with: http)
            lastCheck = Date()
            defaults.set(lastCheck, forKey: Key.lastCheck)
            guard let update = ReleaseFeed.update(installed: installed, releases: releases, includeBeta: includeBeta,
                                                  skipped: manual ? nil : skipped) else {
                phase = .upToDate
                if manual { present(.upToDate(installed)) }
                return
            }
            phase = .available(update)
            let remindAfter = defaults.object(forKey: Key.remindAfter) as? Date
            if manual || remindAfter.map({ $0 <= Date() }) ?? true { present(.offer(update)) }
        } catch {
            phase = .failed(error.localizedDescription)
            if manual { present(.failed(error.localizedDescription)) }
        }
    }

    /// The installed version's own notes, for Help ▸ What's New (or the offer, when one is waiting).
    func whatsNew() async {
        switch phase {
        case .available(let u), .ready(let u), .downloading(let u, _, _): present(.offer(u)); return
        default: break
        }
        present(.loading)
        do {
            let releases = try await cache.fetch(with: http)
            present(.installed(ReleaseFeed.release(for: installed, in: releases).map { [$0] } ?? [], installed))
        } catch {
            present(.failed(error.localizedDescription))
        }
    }

    func remindLater() {
        defaults.set(Date().addingTimeInterval(Self.interval), forKey: Key.remindAfter)
    }

    func skip(_ update: AvailableUpdate) {
        defaults.set(update.version.description, forKey: Key.skipped)
        defaults.removeObject(forKey: Key.remindAfter)
        phase = .idle
    }

    // MARK: Installing

    /// Downloads the update and its signature, verifies the signature, unpacks and checks the app, then quits
    /// so the helper can swap it in and relaunch. Returns the error to show, or nil once the app is quitting.
    func installAndRelaunch(_ update: AvailableUpdate) async -> String? {
        do {
            let staged = try await prepare(update)
            self.staged = staged
            phase = .ready(update)
            rememberWhatsNew(update)
            armInstallOnQuit()
            NSApp.terminate(nil)
            return nil
        } catch {
            phase = .available(update)
            return error.localizedDescription
        }
    }

    /// Everything up to the swap. The signature is checked before the archive is opened in any way.
    func prepare(_ update: AvailableUpdate) async throws -> (app: StagedApp, work: URL) {
        if let problem = UpdateInstaller.locationProblem(appURL: appURL) { throw UpdateError.install(problem) }
        let key = try publicKey()
        guard let files = update.release.archive(for: update.version) else {
            throw UpdateError.badResponse("Release \(update.version) has no signed archive.")
        }
        guard files.zip.size > 0, files.zip.size <= UpdateHTTP.archiveLimit else {
            throw UpdateError.tooLarge("Release \(update.version)'s archive is an unexpected size.")
        }
        let work = try UpdateInstaller.workFolder(for: appURL)
        do {
            phase = .downloading(update, received: 0, total: Int64(files.zip.size))
            let sigResponse = try await http.data(try http.request(files.signature.downloadURL, accept: "application/octet-stream"),
                                                  limit: UpdateHTTP.signatureLimit)
            guard sigResponse.status == 200, let signature = String(data: sigResponse.body, encoding: .utf8) else {
                throw UpdateError.badResponse("GitHub answered HTTP \(sigResponse.status) for the update's signature.")
            }
            let zip = work.appendingPathComponent(files.zip.name)
            let total = Int64(files.zip.size)
            let zipResponse = try await http.download(try http.request(files.zip.downloadURL, accept: "application/octet-stream"),
                                                      to: zip, limit: files.zip.size) { [weak self] n in
                Task { @MainActor in self?.phase = .downloading(update, received: n, total: total) }
            }
            guard zipResponse.status == 200 else {
                throw UpdateError.badResponse("GitHub answered HTTP \(zipResponse.status) for the update.")
            }
            // Nothing from the download is opened, unpacked or run before this line accepts it.
            try UpdateSignature.verify(file: zip, signatureText: signature, key: key)
            let unpacked = work.appendingPathComponent("unpacked")
            try UpdateStaging.unzip(zip, into: unpacked)
            try? FileManager.default.removeItem(at: zip)
            let app = try UpdateStaging.validate(try UpdateStaging.locateApp(in: unpacked), expected: update.version, installed: installed)
            return (app, work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Starts the helper as the app quits, whichever way it quits from now on (the user may cancel the first
    /// quit to save a document; the update then installs the next time the app quits).
    private func armInstallOnQuit() {
        guard quitObserver == nil else { return }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let s = UpdateController.shared.staged else { return }
                _ = try? UpdateInstaller.launchHelper(app: UpdateController.shared.appURL, staged: s.app.url, work: s.work,
                                                      log: UpdateController.installLog)
            }
        }
    }

    static var installLog: URL { ReleaseListCache.standard.directory.appendingPathComponent("install.log") }

    // MARK: What's New after an install

    private struct Pending: Codable { var version: String; var from: String; var releases: [Release] }

    private func rememberWhatsNew(_ update: AvailableUpdate) {
        let p = Pending(version: update.version.description, from: installed.description, releases: update.releases)
        if let data = try? JSONEncoder().encode(p) { defaults.set(data, forKey: Key.whatsNewPending) }
    }

    /// After an update, the notes of every version it brought; if the new version isn't the one running,
    /// the swap was rolled back, and the user is told so.
    func showWhatsNewAfterInstall() {
        guard let data = defaults.data(forKey: Key.whatsNewPending) else { return }
        defaults.removeObject(forKey: Key.whatsNewPending)
        guard let p = try? JSONDecoder().decode(Pending.self, from: data), let target = SemanticVersion(p.version) else { return }
        if installed == target {
            defaults.removeObject(forKey: Key.remindAfter)
            present(.installed(p.releases, target))
        } else if installed < target {
            present(.failed("The update to \(target) wasn't installed, so \(AppIdentity.name) \(installed) is still running. The installer's log is at \(Self.installLog.path)."))
        }
    }
}
