import Foundation
import FacetCore

/// An unpacked update that passed every check, ready to replace the running app.
struct StagedApp: Equatable {
    var url: URL
    var version: SemanticVersion
}

/// Unpacks and checks a downloaded update. Only ever called after `UpdateSignature.verify` accepted the
/// archive; nothing here runs code from the download (`ditto` is the system's own tool).
enum UpdateStaging {
    /// Unzips with `/usr/bin/ditto -x -k` into `folder` (which must be new and empty).
    static func unzip(_ zip: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, folder.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { throw UpdateError.staging("Couldn't unpack the update: \(error.localizedDescription)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let detail = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UpdateError.staging("Couldn't unpack the update" + (detail.isEmpty ? "." : ": \(detail)"))
        }
    }

    /// The one app bundle at the top of an unpacked archive.
    static func locateApp(in folder: URL) throws -> URL {
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let visible = items.filter { !$0.lastPathComponent.hasPrefix(".") }
        guard visible.count == 1, let app = visible.first, app.pathExtension == "app" else {
            throw UpdateError.staging("The update archive should hold exactly one app, but holds \(visible.map(\.lastPathComponent).joined(separator: ", ")).")
        }
        return app
    }

    /// Checks a staged bundle: it is this app (bundle identifier), it is the version that was offered and newer
    /// than the one running, and it is a whole, signed app bundle whose links stay inside it.
    static func validate(_ app: URL, expected: SemanticVersion, installed: SemanticVersion,
                         bundleIdentifier: String = AppIdentity.bundleIdentifier) throws -> StagedApp {
        let fm = FileManager.default
        func fail(_ why: String) -> UpdateError { .staging("The update isn't a valid copy of \(AppIdentity.name): \(why) It was not installed.") }
        guard !isSymlink(app), isDirectory(app) else { throw fail("the app is missing or is a link.") }
        let contents = app.appendingPathComponent("Contents")
        let plist = contents.appendingPathComponent("Info.plist")
        guard isRegularFile(plist), let info = NSDictionary(contentsOf: plist) as? [String: Any] else {
            throw fail("its Info.plist is missing or unreadable.")
        }
        guard (info["CFBundleIdentifier"] as? String) == bundleIdentifier else {
            throw fail("it is a different app (\(info["CFBundleIdentifier"] as? String ?? "no bundle identifier")).")
        }
        guard (info["CFBundlePackageType"] as? String) == "APPL" else { throw fail("it isn't an application bundle.") }
        guard let version = SemanticVersion(AppIdentity.version(in: info)) else {
            throw fail("its version “\(info["CFBundleShortVersionString"] as? String ?? "")” can't be read.")
        }
        guard version == expected else { throw fail("it is version \(version), not the \(expected) that was offered.") }
        guard version > installed else { throw fail("version \(version) isn't newer than the \(installed) already installed.") }
        guard let exe = info["CFBundleExecutable"] as? String, !exe.isEmpty, !exe.contains("/"), exe != "..", exe != "." else {
            throw fail("it names no executable.")
        }
        let binary = contents.appendingPathComponent("MacOS").appendingPathComponent(exe)
        guard isRegularFile(binary), fm.isExecutableFile(atPath: binary.path) else { throw fail("its executable is missing.") }
        guard isRegularFile(contents.appendingPathComponent("_CodeSignature/CodeResources")) else {
            throw fail("it isn't code signed.")
        }
        try checkLinksStayInside(app, fail: fail)
        return StagedApp(url: app, version: version)
    }

    private static func checkLinksStayInside(_ app: URL, fail: (String) -> UpdateError) throws {
        let root = app.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard let walk = FileManager.default.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in walk where isSymlink(url) {
            let target = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard target.hasPrefix(root) else { throw fail("\(url.lastPathComponent) links outside the app.") }
        }
    }

    static func isSymlink(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true }
    static func isDirectory(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    static func isRegularFile(_ u: URL) -> Bool { (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true && !isSymlink(u) }
}

/// Replaces the running app with a staged update. The app can't replace itself while it runs, so a small
/// shell script, written here (never downloaded), waits for this process to exit, moves the old bundle aside,
/// moves the new one into place, and relaunches it; the old bundle is deleted only once the new one has
/// launched, and put back if it doesn't.
///
/// Quarantine: files this app downloads with URLSession get no `com.apple.quarantine` attribute (only apps
/// that opt in with LSFileQuarantineEnabled, or browsers and Mail, set it). So Gatekeeper doesn't assess the
/// new bundle when it launches, which is what lets an ad-hoc signed update open without the System Settings ▸
/// Privacy & Security ▸ Open Anyway step a first download needs. The Ed25519 signature check stands in for
/// notarisation.
enum UpdateInstaller {
    /// Why the app's folder can't take an update, or nil when it can.
    static func locationProblem(appURL: URL, fileManager fm: FileManager = .default) -> String? {
        let path = appURL.path
        if path.contains("/AppTranslocation/") {
            return "macOS is running \(AppIdentity.name) from a temporary, read-only location because it was opened straight from the download. Move it to your Applications folder, open it from there, and check again."
        }
        guard appURL.pathExtension == "app" else {
            return "\(AppIdentity.name) isn't running from an app bundle, so there is nothing to update."
        }
        let parent = appURL.deletingLastPathComponent()
        if path.hasPrefix("/Volumes/"), (try? parent.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) == true {
            return "\(AppIdentity.name) is running from a read-only disk. Copy it to your Applications folder first."
        }
        guard fm.isWritableFile(atPath: parent.path), fm.isWritableFile(atPath: path) else {
            return "You don't have permission to change “\(parent.path)”, where \(AppIdentity.name) is installed. Move the app to a folder you can write to (such as Applications in your home folder), or ask an administrator to install the update."
        }
        return nil
    }

    /// A fresh folder on the same volume as the app, so the final moves are renames rather than copies.
    static func workFolder(for appURL: URL, fileManager fm: FileManager = .default) throws -> URL {
        if let u = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true) {
            return u
        }
        let u = fm.temporaryDirectory.appendingPathComponent("AnalyticsDesktop-update-\(UUID().uuidString)")
        do { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        catch { throw UpdateError.install("Couldn't make a folder for the update: \(error.localizedDescription)") }
        return u
    }

    /// Usage: sh install-update.sh PID APP STAGED WORK [LAUNCHER]. LAUNCHER defaults to /usr/bin/open.
    static let script = """
    #!/bin/sh
    # Installs an Analytics Desktop update after the app quits. Written by the app itself; never downloaded.
    pid="$1"; app="$2"; staged="$3"; work="$4"; launcher="${5:-/usr/bin/open}"
    backup="$work/Previous version.app"
    log() { printf '%s %s\\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
    tries=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 0.2
        tries=$((tries + 1))
        if [ "$tries" -ge 1500 ]; then log "The app didn't quit within 5 minutes; update abandoned."; exit 1; fi
    done
    if [ ! -d "$staged" ]; then log "The staged update is missing."; exit 1; fi
    if ! mv "$app" "$backup"; then log "Couldn't move the installed copy aside."; "$launcher" "$app"; exit 1; fi
    if ! mv "$staged" "$app"; then
        log "Couldn't move the new version into place; restoring the previous one."
        mv "$backup" "$app"; "$launcher" "$app"; exit 1
    fi
    if "$launcher" "$app"; then
        log "Installed and relaunched."
        rm -rf "$backup" "$work"
        exit 0
    fi
    log "The new version didn't launch; restoring the previous one."
    rm -rf "$app"
    mv "$backup" "$app"
    "$launcher" "$app"
    exit 1
    """

    /// Starts the helper. Call it as this process is about to exit (it waits for `pid` to end).
    @discardableResult
    static func launchHelper(app: URL, staged: URL, work: URL, pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                             launcher: String? = nil, log: URL) throws -> Process {
        let scriptURL = work.appendingPathComponent("install-update.sh")
        do {
            try Data(script.utf8).write(to: scriptURL, options: .atomic)
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: nil)
        } catch { throw UpdateError.install("Couldn't prepare the installer: \(error.localizedDescription)") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [scriptURL.path, String(pid), app.path, staged.path, work.path] + (launcher.map { [$0] } ?? [])
        let out = try? FileHandle(forWritingTo: log)
        _ = try? out?.seekToEnd()
        p.standardOutput = out ?? FileHandle.nullDevice
        p.standardError = out ?? FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { throw UpdateError.install("Couldn't start the installer: \(error.localizedDescription)") }
        return p
    }
}
