import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Checking for updates: semantic version order, GitHub's release JSON, which release is offered, the host
/// allow-list, and the HTTP layer (ETag cache, redirects, size limits, rate limits). URLProtocol stubs only.
@MainActor
final class UpdateCheckTests: XCTestCase {
    private func v(_ s: String, file: StaticString = #filePath, line: UInt = #line) -> SemanticVersion {
        guard let x = SemanticVersion(s) else { XCTFail("\(s) should parse", file: file, line: line); return .init(major: 0, minor: 0, patch: 0) }
        return x
    }

    // MARK: Versions

    func testParsingFollowsSemVer() {
        XCTAssertEqual(v("v1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(v("1.2.3-beta.2+exp.sha.5114f85").prerelease, ["beta", "2"])
        XCTAssertEqual(v("0.9.0").description, "0.9.0")
        XCTAssertEqual(v("1.0.0-rc.1").description, "1.0.0-rc.1")
        for bad in ["1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.3-", "1.2.3-01", "1.2.3-beta..1", "1.2.3+", "a.b.c", "", "v", "1.2.-3"] {
            XCTAssertNil(SemanticVersion(bad), bad)
        }
    }

    /// The precedence example from semver.org §11, in order.
    func testPrecedenceMatchesTheSpecExample() {
        let ordered = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                       "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"].map { v($0) }
        for (a, b) in zip(ordered, ordered.dropFirst()) { XCTAssertLessThan(a, b, "\(a) < \(b)") }
        XCTAssertLessThan(v("1.0.0"), v("2.0.0"))
        XCTAssertLessThan(v("2.0.0"), v("2.1.0"))
        XCTAssertLessThan(v("2.1.0"), v("2.1.1"))
        XCTAssertLessThan(v("0.9.0"), v("0.10.0"), "numeric, not text")
        XCTAssertEqual(v("1.0.0+a"), v("1.0.0+b"), "build metadata is ignored")
        XCTAssertFalse(v("1.0.0") < v("1.0.0"))
    }

    // MARK: Release JSON

    static let base = "https://github.com/Edwardrem/analytics-desktop/releases/download"

    static func releaseJSON(_ tag: String, prerelease: Bool = false, draft: Bool = false, notes: String = "Notes", assets: Bool = true, size: Int = 1234) -> String {
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let files = assets ? """
        [{"url": "https://api.github.com/repos/Edwardrem/analytics-desktop/releases/assets/1", "id": 1, "name": "AnalyticsDesktop-\(version).zip",
          "label": "", "content_type": "application/zip", "state": "uploaded", "size": \(size), "download_count": 3,
          "browser_download_url": "\(base)/\(tag)/AnalyticsDesktop-\(version).zip"},
         {"id": 2, "name": "AnalyticsDesktop-\(version).zip.sig", "size": 89, "content_type": "application/octet-stream",
          "browser_download_url": "\(base)/\(tag)/AnalyticsDesktop-\(version).zip.sig"},
         {"id": 3, "name": "latest.json", "size": 600, "browser_download_url": "\(base)/\(tag)/latest.json"}]
        """ : "[]"
        return """
        {"url": "https://api.github.com/repos/Edwardrem/analytics-desktop/releases/1", "id": 1, "tag_name": "\(tag)",
         "target_commitish": "main", "name": "Analytics Desktop \(version)", "draft": \(draft), "prerelease": \(prerelease),
         "created_at": "2026-11-10T09:00:00Z", "published_at": "2026-11-10T10:00:00Z",
         "html_url": "https://github.com/Edwardrem/analytics-desktop/releases/tag/\(tag)",
         "author": {"login": "Edwardrem"}, "body": \(String(data: (try? JSONEncoder().encode(notes)) ?? Data(), encoding: .utf8) ?? "\"\""),
         "assets": \(files)}
        """
    }

    static func list(_ releases: [String]) -> Data { Data("[\(releases.joined(separator: ","))]".utf8) }

    func testGitHubReleaseJSONDecodes() throws {
        let releases = try ReleaseFeed.decode(Self.list([Self.releaseJSON("v0.9.1", notes: "## Fixes\r\n- One"), Self.releaseJSON("v0.9.0")]))
        XCTAssertEqual(releases.count, 2)
        let r = try XCTUnwrap(releases.first)
        XCTAssertEqual(r.tag, "v0.9.1")
        XCTAssertEqual(r.version, v("0.9.1"))
        XCTAssertEqual(r.notes, "## Fixes\r\n- One")
        XCTAssertEqual(r.pageURL?.absoluteString, "https://github.com/Edwardrem/analytics-desktop/releases/tag/v0.9.1")
        XCTAssertEqual(r.publishedAt, ISO8601DateFormatter().date(from: "2026-11-10T10:00:00Z"))
        let files = try XCTUnwrap(r.archive(for: v("0.9.1")))
        XCTAssertEqual(files.zip.name, "AnalyticsDesktop-0.9.1.zip")
        XCTAssertEqual(files.zip.size, 1234)
        XCTAssertEqual(files.signature.name, "AnalyticsDesktop-0.9.1.zip.sig")
        XCTAssertThrowsError(try ReleaseFeed.decode(Data("{\"message\": \"Not Found\"}".utf8)))
    }

    func testOfferIsTheNewestEligibleReleaseWithEverySkippedVersionsNotes() throws {
        let releases = try ReleaseFeed.decode(Self.list([
            Self.releaseJSON("v1.1.0-beta.1", prerelease: true),
            Self.releaseJSON("v1.0.0"),
            Self.releaseJSON("v0.11.0", draft: true),
            Self.releaseJSON("v0.10.0"),
            Self.releaseJSON("v0.9.5", assets: false),     // no signed archive: never offered
            Self.releaseJSON("nightly"),
            Self.releaseJSON("v0.9.0"),
        ]))
        let stable = try XCTUnwrap(ReleaseFeed.update(installed: v("0.9.0"), releases: releases, includeBeta: false, skipped: nil))
        XCTAssertEqual(stable.version, v("1.0.0"))
        XCTAssertEqual(stable.releases.map(\.tag), ["v1.0.0", "v0.10.0"])

        let beta = try XCTUnwrap(ReleaseFeed.update(installed: v("0.9.0"), releases: releases, includeBeta: true, skipped: nil))
        XCTAssertEqual(beta.version, v("1.1.0-beta.1"))
        XCTAssertEqual(beta.releases.map(\.tag), ["v1.1.0-beta.1", "v1.0.0", "v0.10.0"])

        XCTAssertNil(ReleaseFeed.update(installed: v("1.0.0"), releases: releases, includeBeta: false, skipped: nil))
        XCTAssertNil(ReleaseFeed.update(installed: v("0.9.0"), releases: releases, includeBeta: false, skipped: v("1.0.0")),
                     "a skipped version isn't offered again")
        XCTAssertEqual(ReleaseFeed.update(installed: v("0.9.0"), releases: releases, includeBeta: false, skipped: v("0.10.0"))?.version, v("1.0.0"),
                       "a later version is offered even after skipping an earlier one")
        XCTAssertEqual(ReleaseFeed.update(installed: v("1.1.0-alpha"), releases: releases, includeBeta: true, skipped: nil)?.version, v("1.1.0-beta.1"))
    }

    func testABetaVersionWithoutThePrereleaseFlagIsStillABeta() throws {
        let releases = try ReleaseFeed.decode(Self.list([Self.releaseJSON("v1.0.0-rc.1")]))
        XCTAssertNil(ReleaseFeed.update(installed: v("0.9.0"), releases: releases, includeBeta: false, skipped: nil))
    }

    func testManifestShape() throws {
        let json = """
        {"version": "0.9.0", "build": "412", "notesURL": "https://github.com/Edwardrem/analytics-desktop/releases/tag/v0.9.0",
         "archive": {"name": "AnalyticsDesktop-0.9.0.zip", "url": "\(Self.base)/v0.9.0/AnalyticsDesktop-0.9.0.zip", "size": 9000000,
                     "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
         "signature": {"name": "AnalyticsDesktop-0.9.0.zip.sig", "url": "\(Self.base)/v0.9.0/AnalyticsDesktop-0.9.0.zip.sig", "size": 89,
                       "sha256": "0000000000000000000000000000000000000000000000000000000000000000"}}
        """
        let m = try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8))
        XCTAssertEqual(m.version, "0.9.0")
        XCTAssertEqual(m.archive.name, "AnalyticsDesktop-0.9.0.zip")
        XCTAssertEqual(m.signature.size, 89)
    }

    // MARK: Allow-list

    func testOnlyGitHubHostsOverHTTPSAreAllowed() {
        for ok in ["https://api.github.com/repos/Edwardrem/analytics-desktop/releases", "https://github.com/Edwardrem/x",
                   "https://objects.githubusercontent.com/a", "https://release-assets.githubusercontent.com/b",
                   "https://API.GitHub.com/x", "https://github.com:443/x"] {
            XCTAssertNoThrow(try UpdateHosts.check(URL(string: ok)), ok)
        }
        for bad in ["http://api.github.com/x", "https://evil.com/x", "https://github.com.evil.com/x", "https://evilgithub.com/x",
                    "https://raw.githubusercontent.com/x", "https://user:pw@github.com/x", "https://github.com:8443/x",
                    "file:///etc/passwd", "ftp://github.com/x"] {
            XCTAssertThrowsError(try UpdateHosts.check(URL(string: bad)), bad)
        }
        XCTAssertThrowsError(try UpdateHosts.check(nil))
    }

    // MARK: HTTP

    private var cacheDir: URL!
    override func setUp() async throws {
        UpdateStubProtocol.reset()
        cacheDir = try UpdateFixtures.temporaryFolder()
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: cacheDir) }

    private var http: UpdateHTTP { UpdateHTTP(protocolClasses: [UpdateStubProtocol.self], timeout: 5) }
    private let api = ReleaseFeed.releasesURL.absoluteString

    func testTheReleaseListIsCachedByETagAndTheRequestCarriesNothingElse() async throws {
        let cache = ReleaseListCache(directory: cacheDir)
        UpdateStubProtocol.on(api, .respond(status: 200, headers: ["ETag": "\"abc\""], body: Self.list([Self.releaseJSON("v1.0.0")])))
        let first = try await cache.fetch(with: http)
        XCTAssertEqual(first.map(\.tag), ["v1.0.0"])

        UpdateStubProtocol.on(api, .respond(status: 304, headers: [:], body: Data()))
        let second = try await cache.fetch(with: http)
        XCTAssertEqual(second, first, "a 304 reuses the cached list")

        let requests = UpdateStubProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"abc\"")
        for r in requests {
            XCTAssertEqual(r.httpMethod, "GET")
            XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(r.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(r.httpBody)
            XCTAssertEqual(r.value(forHTTPHeaderField: "User-Agent"), "AnalyticsDesktop/\(AppIdentity.version)")
            XCTAssertEqual(r.url?.query, "per_page=30")
        }
    }

    func testA304WithoutACachedCopyIsAnError() async {
        UpdateStubProtocol.on(api, .respond(status: 304, headers: [:], body: Data()))
        do { _ = try await ReleaseListCache(directory: cacheDir).fetch(with: http); XCTFail("expected an error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("hadn't changed")) }
    }

    func testRateLimitIsReportedWithTheResetTime() async {
        UpdateStubProtocol.on(api, .respond(status: 403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1794650000"], body: Data("{}".utf8)))
        do { _ = try await ReleaseListCache(directory: cacheDir).fetch(with: http); XCTFail("expected an error") }
        catch { XCTAssertEqual(error as? UpdateError, .rateLimited(Date(timeIntervalSince1970: 1794650000))) }
    }

    func testRedirectsAreFollowedOnlyToAllowedHosts() async throws {
        let asset = "\(Self.base)/v1.0.0/AnalyticsDesktop-1.0.0.zip.sig"
        let storage = "https://release-assets.githubusercontent.com/github-production-release-asset/1?sig=x"
        UpdateStubProtocol.on(asset, .redirect(to: storage))
        UpdateStubProtocol.on(storage, .respond(status: 200, headers: [:], body: Data("c2ln".utf8)))
        let ok = try await http.data(try http.request(try XCTUnwrap(URL(string: asset)), accept: "application/octet-stream"), limit: 100)
        XCTAssertEqual(ok.body, Data("c2ln".utf8))
        XCTAssertEqual(UpdateStubProtocol.requests.last?.url?.absoluteString, storage)

        UpdateStubProtocol.reset()
        UpdateStubProtocol.on(asset, .redirect(to: "https://attacker.example/payload"))
        UpdateStubProtocol.on("https://attacker.example/payload", .respond(status: 200, headers: [:], body: Data("x".utf8)))
        do { _ = try await http.data(try http.request(try XCTUnwrap(URL(string: asset)), accept: "*/*"), limit: 100); XCTFail("expected a refusal") }
        catch { XCTAssertEqual((error as? UpdateError).map { if case .notAllowed = $0 { return true } else { return false } }, true, "\(error)") }
        XCTAssertFalse(UpdateStubProtocol.requests.contains { $0.url?.host == "attacker.example" }, "the disallowed host is never contacted")

        UpdateStubProtocol.reset()
        UpdateStubProtocol.on(asset, .redirect(to: "http://objects.githubusercontent.com/plain"))
        do { _ = try await http.data(try http.request(try XCTUnwrap(URL(string: asset)), accept: "*/*"), limit: 100); XCTFail("expected a refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("https"), error.localizedDescription) }
    }

    func testResponsesAreBounded() async throws {
        let url = "\(Self.base)/v1.0.0/AnalyticsDesktop-1.0.0.zip"
        UpdateStubProtocol.on(url, .respond(status: 200, headers: [:], body: Data(repeating: 7, count: 5000)))
        do { _ = try await http.data(try http.request(try XCTUnwrap(URL(string: url)), accept: "*/*"), limit: 4096); XCTFail("expected tooLarge") }
        catch { XCTAssertEqual((error as? UpdateError).map { if case .tooLarge = $0 { return true } else { return false } }, true, "\(error)") }

        let file = cacheDir.appendingPathComponent("a.zip")
        let fine = try await http.download(try http.request(try XCTUnwrap(URL(string: url)), accept: "*/*"), to: file, limit: 5000)
        XCTAssertEqual(fine.status, 200)
        XCTAssertEqual(try Data(contentsOf: file).count, 5000)
        XCTAssertThrowsError(try http.request(try XCTUnwrap(URL(string: "https://example.com/x")), accept: "*/*"))
    }

    // MARK: The check itself

    private func controller(_ defaults: UserDefaults, installed: String) -> (UpdateController, () -> [WhatsNewContent]) {
        var shown: [WhatsNewContent] = []
        let c = UpdateController(http: http, cache: ReleaseListCache(directory: cacheDir), defaults: defaults, installed: v(installed),
                                 appURL: cacheDir.appendingPathComponent("Analytics Desktop.app"), publicKey: { throw UpdateError.signature("no key in tests") })
        c.present = { shown.append($0) }
        return (c, { shown })
    }

    func testManualAndAutomaticChecks() async throws {
        let suite = "UpdateCheckTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        UpdateStubProtocol.on(api, .respond(status: 200, headers: [:], body: Self.list([Self.releaseJSON("v1.0.0"), Self.releaseJSON("v0.9.0")])))

        let (c, shown) = controller(defaults, installed: "0.9.0")
        XCTAssertTrue(c.automatic, "automatic checks are on by default")
        XCTAssertFalse(c.includeBeta, "betas are opt-in")
        XCTAssertTrue(c.isDue(now: Date()))
        await c.check(manual: false)
        guard case .available(let u) = c.phase else { return XCTFail("\(c.phase)") }
        XCTAssertEqual(u.version, v("1.0.0"))
        XCTAssertEqual(shown().count, 1, "an automatic check opens What's New when there is an update")
        XCTAssertNotNil(c.lastCheck)
        XCTAssertFalse(c.isDue(now: Date()))
        XCTAssertTrue(c.isDue(now: Date().addingTimeInterval(UpdateController.interval)))

        c.remindLater()
        await c.check(manual: false)
        XCTAssertEqual(shown().count, 1, "Remind Me Later keeps automatic checks quiet for a day")
        await c.check(manual: true)
        XCTAssertEqual(shown().count, 2, "a manual check always shows the offer")

        c.skip(u)
        XCTAssertEqual(defaults.string(forKey: UpdateController.Key.skipped), "1.0.0")
        await c.check(manual: false)
        XCTAssertEqual(c.phase, .upToDate)
        XCTAssertEqual(shown().count, 2, "a skipped version isn't offered automatically")
        await c.check(manual: true)
        XCTAssertEqual(shown().last, .offer(u), "but a manual check still offers it")

        let (current, shownCurrent) = controller(defaults, installed: "1.0.0")
        await current.check(manual: true)
        XCTAssertEqual(shownCurrent(), [.upToDate(v("1.0.0"))])

        UpdateStubProtocol.on(api, .respond(status: 500, headers: [:], body: Data()))
        try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent("releases.etag"))
        await current.check(manual: false)
        guard case .failed(let message) = current.phase else { return XCTFail("\(current.phase)") }
        XCTAssertTrue(message.contains("500"))
        XCTAssertEqual(shownCurrent().count, 1, "a failed automatic check stays quiet")
    }

    func testARepositoryWithNoReleasesSaysSo() async throws {
        let suite = "UpdateCheckTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        UpdateStubProtocol.on(api, .respond(status: 200, headers: [:], body: Self.list([])))

        let (c, shown) = controller(defaults, installed: "0.9.0")
        await c.check(manual: false)
        XCTAssertEqual(c.phase, .noReleases)
        XCTAssertTrue(shown().isEmpty, "an automatic check stays quiet")
        await c.check(manual: true)
        XCTAssertEqual(shown(), [.noReleases(v("0.9.0"))])
        await c.whatsNew()
        XCTAssertEqual(shown().last, .noReleases(v("0.9.0")), "What's New says there are no releases, not that notes are missing")

        XCTAssertFalse(c.canVerifyUpdates, "the test controller has no key, like a build without UpdatePublicKey.txt")
        XCTAssertTrue(UpdateController.missingKeyNote.contains("signing key"))
    }

    func testReleaseNotesMarkdownBlocks() {
        let notes = "## New\r\nThe **ribbon** and\r\nthe panes.\r\n\r\n- One\r\n  - Nested\r\n1. First\r\n> Quote\r\n```\r\nlet x = 1\r\n```\r\n---\r\n#NotAHeading"
        XCTAssertEqual(MarkdownBlocks.parse(notes), [
            .heading(2, "New"), .paragraph("The **ribbon** and the panes."),
            .bullet("One", depth: 0), .bullet("Nested", depth: 1), .numbered("1", "First", depth: 0),
            .quote("Quote"), .code("let x = 1"), .rule, .paragraph("#NotAHeading"),
        ])
        XCTAssertEqual(String(MarkdownBlocks.inline("**bold** and `code`").characters), "bold and code")
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
    }

    func testHelpCommandsAreRegisteredAndOnTheRibbon() {
        Features.registerAll()
        XCTAssertEqual(AppCommands.command(UpdatesFeature.checkCommand)?.title, "Check for Updates…")
        XCTAssertEqual(AppCommands.command(UpdatesFeature.checkCommand)?.menu, .help)
        XCTAssertEqual(AppCommands.command(UpdatesFeature.whatsNewCommand)?.title, "What's New")
        XCTAssertTrue(RibbonLayout.referencedIDs.contains(UpdatesFeature.checkCommand))
        XCTAssertTrue(RibbonLayout.referencedIDs.contains(UpdatesFeature.whatsNewCommand))
        XCTAssertFalse(RibbonLayout.unregisteredIDs(in: Set(AppCommands.all.map(\.id))).contains(UpdatesFeature.checkCommand))
        XCTAssertTrue(SettingsSections.extra.contains { $0.title == "Updates" })
    }
}
