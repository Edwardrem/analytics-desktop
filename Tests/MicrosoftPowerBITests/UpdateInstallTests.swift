import XCTest
import CryptoKit
import FacetCore
@testable import MicrosoftPowerBI

/// Installing an update: Ed25519 signature checks, staging checks on unpacked bundles, the folder checks,
/// the whole download-verify-unpack path against URLProtocol stubs, and the helper script's swap on a
/// temporary bundle. Never the network, never the real app bundle.
@MainActor
final class UpdateInstallTests: XCTestCase {
    private var dir: URL!
    private let key = Curve25519.Signing.PrivateKey()

    override func setUp() async throws {
        UpdateStubProtocol.reset()
        dir = try UpdateFixtures.temporaryFolder()
    }
    override func tearDown() async throws {
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("Locked").path)
        try? FileManager.default.removeItem(at: dir)
    }

    private func v(_ s: String) -> SemanticVersion { SemanticVersion(s) ?? .init(major: 0, minor: 0, patch: 0) }
    private func signature(_ data: Data, _ k: Curve25519.Signing.PrivateKey? = nil) throws -> String {
        try (k ?? key).signature(for: data).base64EncodedString()
    }

    // MARK: Signatures

    func testGoodSignatureIsAccepted() throws {
        let data = Data("the zip's bytes".utf8)
        let pub = try UpdateSignature.publicKey(key.publicKey.rawRepresentation.base64EncodedString() + "\n")
        XCTAssertNoThrow(try UpdateSignature.verify(data, signatureText: try signature(data) + "\n", key: pub))
    }

    func testBadSignaturesAreRefused() throws {
        let data = Data("the zip's bytes".utf8)
        let pub = key.publicKey
        let good = try key.signature(for: data)
        // Another key's signature, a signature of other bytes, and one flipped bit.
        XCTAssertThrowsError(try UpdateSignature.verify(data, signatureText: try signature(data, Curve25519.Signing.PrivateKey()), key: pub))
        XCTAssertThrowsError(try UpdateSignature.verify(data + Data([0]), signatureText: good.base64EncodedString(), key: pub))
        var flipped = good; flipped[10] ^= 0x01
        XCTAssertThrowsError(try UpdateSignature.verify(data, signatureText: flipped.base64EncodedString(), key: pub))
        // Truncated signature, truncated data, empty, not base64, and two signatures in one file.
        XCTAssertThrowsError(try UpdateSignature.verify(data, signatureText: good.prefix(63).base64EncodedString(), key: pub)) { e in
            XCTAssertTrue(e.localizedDescription.contains("malformed"))
        }
        XCTAssertThrowsError(try UpdateSignature.verify(data.prefix(5), signatureText: good.base64EncodedString(), key: pub))
        XCTAssertThrowsError(try UpdateSignature.verify(data, signatureText: "", key: pub))
        XCTAssertThrowsError(try UpdateSignature.verify(data, signatureText: "not base64!", key: pub))
        XCTAssertThrowsError(try UpdateSignature.verify(data, signatureText: good.base64EncodedString() + " " + good.base64EncodedString(), key: pub))
        // A damaged key file.
        XCTAssertThrowsError(try UpdateSignature.publicKey(String(key.publicKey.rawRepresentation.base64EncodedString().dropLast(4))))
        XCTAssertThrowsError(try UpdateSignature.bundledKey(Bundle(for: Self.self))) { e in
            XCTAssertTrue(e.localizedDescription.contains("without an update signing key"))
        }
    }

    // MARK: Staging

    func testStagingAcceptsOnlyThisAppNewerAndWhole() throws {
        let installed = v("0.9.0")
        let good = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("a/Analytics Desktop.app"), version: "0.9.1")
        XCTAssertEqual(try UpdateStaging.validate(good, expected: v("0.9.1"), installed: installed).version, v("0.9.1"))

        func refused(_ app: URL, expected: String = "0.9.1", _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try UpdateStaging.validate(app, expected: v(expected), installed: installed), file: file, line: line) { e in
                XCTAssertTrue(e.localizedDescription.contains(reason), e.localizedDescription, file: file, line: line)
            }
        }
        refused(try UpdateFixtures.makeApp(at: dir.appendingPathComponent("b/X.app"), identifier: "com.example.other", version: "0.9.1"), "different app")
        refused(try UpdateFixtures.makeApp(at: dir.appendingPathComponent("c/X.app"), version: "0.9.0"), expected: "0.9.0", "isn't newer")
        refused(try UpdateFixtures.makeApp(at: dir.appendingPathComponent("d/X.app"), version: "0.8.0"), expected: "0.8.0", "isn't newer")
        refused(try UpdateFixtures.makeApp(at: dir.appendingPathComponent("e/X.app"), version: "0.9.2"), "not the 0.9.1")
        refused(try UpdateFixtures.makeApp(at: dir.appendingPathComponent("f/X.app"), version: "0.9.1", signed: false), "code signed")
        refused(try UpdateFixtures.makeApp(at: dir.appendingPathComponent("g/X.app"), version: "0.9.1", executable: "../evil"), "no executable")

        let noBinary = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("h/X.app"), version: "0.9.1")
        try FileManager.default.removeItem(at: noBinary.appendingPathComponent("Contents/MacOS/MicrosoftPowerBI"))
        refused(noBinary, "executable is missing")

        let escaping = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("i/X.app"), version: "0.9.1")
        try FileManager.default.createSymbolicLink(atPath: escaping.appendingPathComponent("Contents/Resources").path, withDestinationPath: "/etc")
        refused(escaping, "links outside")

        let linkedApp = dir.appendingPathComponent("j/X.app")
        try FileManager.default.createDirectory(at: linkedApp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: linkedApp, withDestinationURL: good)
        refused(linkedApp, "is a link")

        refused(dir.appendingPathComponent("missing.app"), "missing")
    }

    func testTheArchiveMustHoldExactlyOneApp() throws {
        let unpacked = dir.appendingPathComponent("unpacked")
        try UpdateFixtures.makeApp(at: unpacked.appendingPathComponent("Analytics Desktop.app"), version: "0.9.1")
        try Data().write(to: unpacked.appendingPathComponent(".DS_Store"))
        XCTAssertEqual(try UpdateStaging.locateApp(in: unpacked).lastPathComponent, "Analytics Desktop.app")
        try Data("x".utf8).write(to: unpacked.appendingPathComponent("payload.sh"))
        XCTAssertThrowsError(try UpdateStaging.locateApp(in: unpacked))
    }

    func testInstallLocationProblemsAreExplained() throws {
        let app = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("Apps/Analytics Desktop.app"), version: "0.9.0")
        XCTAssertNil(UpdateInstaller.locationProblem(appURL: app))
        XCTAssertTrue(UpdateInstaller.locationProblem(appURL: URL(fileURLWithPath: "/private/var/folders/xy/AppTranslocation/ABC/d/Analytics Desktop.app"))?
            .contains("Applications folder") == true)
        XCTAssertTrue(UpdateInstaller.locationProblem(appURL: dir.appendingPathComponent("debug"))?.contains("isn't running from an app bundle") == true)

        let locked = dir.appendingPathComponent("Locked")
        let lockedApp = try UpdateFixtures.makeApp(at: locked.appendingPathComponent("Analytics Desktop.app"), version: "0.9.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let problem = try XCTUnwrap(UpdateInstaller.locationProblem(appURL: lockedApp))
        XCTAssertTrue(problem.contains("permission") && problem.contains(locked.path), problem)
    }

    // MARK: Download, verify, unpack

    private func offer(version: String, zip: Data, signature: String) throws -> AvailableUpdate {
        let tag = "v\(version)"
        let zipURL = "\(UpdateCheckTests.base)/\(tag)/AnalyticsDesktop-\(version).zip"
        let storage = "https://objects.githubusercontent.com/github-production-release-asset/\(version)"
        UpdateStubProtocol.on(zipURL, .redirect(to: storage))
        UpdateStubProtocol.on(storage, .respond(status: 200, headers: ["Content-Length": "\(zip.count)"], body: zip))
        UpdateStubProtocol.on(zipURL + ".sig", .redirect(to: storage + ".sig"))
        UpdateStubProtocol.on(storage + ".sig", .respond(status: 200, headers: [:], body: Data(signature.utf8)))
        let releases = try ReleaseFeed.decode(UpdateCheckTests.list([UpdateCheckTests.releaseJSON(tag, size: zip.count)]))
        return try XCTUnwrap(ReleaseFeed.update(installed: v("0.9.0"), releases: releases, includeBeta: false, skipped: nil))
    }

    private func controller(_ app: URL) -> UpdateController {
        let suite = "UpdateInstallTests.\(UUID().uuidString)"
        let c = UpdateController(http: UpdateHTTP(protocolClasses: [UpdateStubProtocol.self], timeout: 5),
                                 cache: ReleaseListCache(directory: dir.appendingPathComponent("cache")),
                                 defaults: UserDefaults(suiteName: suite) ?? .standard, installed: v("0.9.0"), appURL: app,
                                 publicKey: { [key] in key.publicKey })
        c.present = { _ in }
        return c
    }

    private func builtZip(version: String) throws -> Data {
        let src = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("build-\(version)/Analytics Desktop.app"), version: version, marker: "new")
        let zip = dir.appendingPathComponent("AnalyticsDesktop-\(version).zip")
        try UpdateFixtures.zip(src, to: zip)
        return try Data(contentsOf: zip)
    }

    func testASignedUpdateIsDownloadedVerifiedAndStaged() async throws {
        let installed = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("Apps/Analytics Desktop.app"), version: "0.9.0")
        let zip = try builtZip(version: "0.9.1")
        let update = try offer(version: "0.9.1", zip: zip, signature: try signature(zip))
        let c = controller(installed)
        let staged = try await c.prepare(update)
        XCTAssertEqual(staged.app.version, v("0.9.1"))
        XCTAssertEqual(UpdateFixtures.version(of: staged.app.url), "0.9.1")
        XCTAssertEqual(UpdateFixtures.version(of: installed), "0.9.0", "nothing touches the installed app before it quits")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.work.appendingPathComponent("AnalyticsDesktop-0.9.1.zip").path))
        XCTAssertTrue(UpdateStubProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        try? FileManager.default.removeItem(at: staged.work)
    }

    func testATamperedUpdateIsRefusedBeforeItIsUnpacked() async throws {
        let installed = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("Apps/Analytics Desktop.app"), version: "0.9.0")
        let zip = try builtZip(version: "0.9.1")
        let signedOriginal = try signature(zip)
        var tampered = zip; tampered[tampered.count / 2] ^= 0xFF
        let update = try offer(version: "0.9.1", zip: tampered, signature: signedOriginal)
        let c = controller(installed)
        do { _ = try await c.prepare(update); XCTFail("a tampered archive must be refused") }
        catch { XCTAssertEqual((error as? UpdateError).map { if case .signature = $0 { return true } else { return false } }, true, "\(error)") }

        let truncated = try offer(version: "0.9.1", zip: zip.prefix(zip.count - 10), signature: signedOriginal)
        do { _ = try await c.prepare(truncated); XCTFail("a truncated archive must be refused") }
        catch { XCTAssertTrue(error is UpdateError, "\(error)") }
        XCTAssertEqual(UpdateFixtures.version(of: installed), "0.9.0")
    }

    func testAnUnwritableFolderFailsBeforeDownloading() async throws {
        let locked = dir.appendingPathComponent("Locked")
        let installed = try UpdateFixtures.makeApp(at: locked.appendingPathComponent("Analytics Desktop.app"), version: "0.9.0")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        let zip = try builtZip(version: "0.9.1")
        let update = try offer(version: "0.9.1", zip: zip, signature: try signature(zip))
        let message = await controller(installed).installAndRelaunch(update)
        XCTAssertTrue(message?.contains("permission") == true, message ?? "nil")
        XCTAssertTrue(UpdateStubProtocol.requests.isEmpty, "nothing is downloaded")
    }

    // MARK: The swap

    /// A launcher standing in for `/usr/bin/open`: records each launch, and fails for bundles whose
    /// Info.plist contains `failVersion`.
    private func launcher(failVersion: String?) throws -> (URL, URL) {
        let log = dir.appendingPathComponent("launches.txt")
        let script = dir.appendingPathComponent("launcher.sh")
        let failing = failVersion.map { "if grep -q '\($0)' \"$1/Contents/Info.plist\"; then exit 1; fi\n" } ?? ""
        try Data("#!/bin/sh\necho \"$1\" >> '\(log.path)'\n\(failing)exit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, log)
    }

    private func runSwap(failVersion: String?) throws -> (app: URL, work: URL, launches: [String]) {
        let app = try UpdateFixtures.makeApp(at: dir.appendingPathComponent("Apps/Analytics Desktop.app"), version: "0.9.0", marker: "old")
        let work = dir.appendingPathComponent("work")
        let staged = try UpdateFixtures.makeApp(at: work.appendingPathComponent("unpacked/Analytics Desktop.app"), version: "0.9.1", marker: "new")
        let (script, launches) = try launcher(failVersion: failVersion)
        let running = Process()          // stands in for the app that has to quit first
        running.executableURL = URL(fileURLWithPath: "/bin/sleep")
        running.arguments = ["0.5"]
        try running.run()
        let helper = try UpdateInstaller.launchHelper(app: app, staged: staged, work: work, pid: running.processIdentifier,
                                                      launcher: script.path, log: dir.appendingPathComponent("install.log"))
        XCTAssertEqual(UpdateFixtures.version(of: app), "0.9.0", "nothing moves while the app is running")
        helper.waitUntilExit()
        running.waitUntilExit()
        let lines = ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (app, work, lines)
    }

    func testTheHelperSwapsTheBundleAfterTheAppQuitsAndRelaunches() throws {
        let (app, work, launches) = try runSwap(failVersion: nil)
        XCTAssertEqual(UpdateFixtures.version(of: app), "0.9.1")
        XCTAssertEqual(launches, [app.path], "relaunched once, at the same path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "the old copy is deleted once the new one launched")
        let log = try String(contentsOf: dir.appendingPathComponent("install.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("Installed and relaunched."), log)
    }

    func testTheHelperPutsTheOldAppBackWhenTheNewOneDoesNotLaunch() throws {
        let (app, _, launches) = try runSwap(failVersion: "0.9.1")
        XCTAssertEqual(UpdateFixtures.version(of: app), "0.9.0", "the previous version is restored")
        XCTAssertEqual(launches, [app.path, app.path], "the new version was tried, then the old one relaunched")
        let exe = try String(contentsOf: app.appendingPathComponent("Contents/MacOS/MicrosoftPowerBI"), encoding: .utf8)
        XCTAssertTrue(exe.contains("old"))
    }
}
