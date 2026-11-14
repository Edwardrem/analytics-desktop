import Foundation
import FacetCore

/// One file attached to a GitHub release.
struct ReleaseAsset: Codable, Equatable {
    var name: String
    var size: Int
    var downloadURL: URL

    enum CodingKeys: String, CodingKey { case name, size, downloadURL = "browser_download_url" }
}

/// One release, as GitHub's REST API returns it (`GET /repos/{owner}/{repo}/releases`).
struct Release: Codable, Equatable {
    var tag: String
    var title: String?
    var notes: String?
    var isDraft: Bool
    var isPrerelease: Bool
    var pageURL: URL?
    var publishedAt: Date?
    var assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name", title = "name", notes = "body", isDraft = "draft", isPrerelease = "prerelease"
        case pageURL = "html_url", publishedAt = "published_at", assets
    }

    /// The version the tag names (`v1.2.3` → 1.2.3), or nil for tags that aren't versions.
    var version: SemanticVersion? { SemanticVersion(tag) }
    /// A beta: GitHub's pre-release flag, or a pre-release version such as 1.0.0-beta.1.
    var isBeta: Bool { isPrerelease || (version?.isPrerelease ?? false) }

    /// The update archive and its Ed25519 signature, named as `Scripts/release.sh` names them.
    func archive(for version: SemanticVersion) -> (zip: ReleaseAsset, signature: ReleaseAsset)? {
        let zipName = ReleaseFeed.archiveName(version)
        guard let zip = assets.first(where: { $0.name == zipName }),
              let sig = assets.first(where: { $0.name == zipName + ".sig" }) else { return nil }
        return (zip, sig)
    }
}

/// An update on offer: the newest eligible release, with every newer-than-installed release's notes.
struct AvailableUpdate: Equatable {
    var version: SemanticVersion
    var release: Release
    /// Newest first: the offered release, then each version between it and the installed one.
    var releases: [Release]
}

enum ReleaseFeed {
    static let owner = "Edwardrem"
    static let repository = "analytics-desktop"
    /// The release list. Unauthenticated; 30 releases is far more than the notes ever need.
    static let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases?per_page=30")!
    static func archiveName(_ v: SemanticVersion) -> String { "AnalyticsDesktop-\(v).zip" }

    static func decode(_ data: Data) throws -> [Release] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode([Release].self, from: data) }
        catch { throw UpdateError.badResponse("GitHub's release list couldn't be read (\(error.localizedDescription)).") }
    }

    /// The releases newer than `installed`, newest first: published (not drafts), tagged with a version,
    /// carrying the signed archive, and betas only when `includeBeta`.
    static func newer(than installed: SemanticVersion, in releases: [Release], includeBeta: Bool) -> [Release] {
        releases
            .filter { r in
                guard !r.isDraft, let v = r.version, v > installed else { return false }
                return (includeBeta || !r.isBeta) && r.archive(for: v) != nil
            }
            .sorted { ($0.version ?? installed) > ($1.version ?? installed) }
    }

    /// What to offer, or nil when the installed version is the newest. A skipped version is not offered
    /// again, but a later one is (with the skipped version's notes, since it was never installed).
    static func update(installed: SemanticVersion, releases: [Release], includeBeta: Bool,
                       skipped: SemanticVersion?) -> AvailableUpdate? {
        let list = newer(than: installed, in: releases, includeBeta: includeBeta)
        guard let newest = list.first, let v = newest.version, v != skipped else { return nil }
        return AvailableUpdate(version: v, release: newest, releases: list)
    }

    /// The release for one version (What's New for the installed version).
    static func release(for version: SemanticVersion, in releases: [Release]) -> Release? {
        releases.first { !$0.isDraft && $0.version == version }
    }
}

/// The manifest `Scripts/release.sh` writes beside each release (`latest.json`). The app reads releases from
/// GitHub's API; this type documents and tests the manifest's shape.
struct ReleaseManifest: Codable, Equatable {
    struct File: Codable, Equatable {
        var name: String
        var url: URL
        var size: Int
        var sha256: String
    }
    var version: String
    var build: String
    var notesURL: URL
    var archive: File
    var signature: File
}

/// Everything that can go wrong checking for, downloading or installing an update, worded for the user.
enum UpdateError: LocalizedError, Equatable {
    case notAllowed(String)
    case badResponse(String)
    case network(String)
    case rateLimited(Date?)
    case tooLarge(String)
    case signature(String)
    case staging(String)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .notAllowed(let s), .badResponse(let s), .network(let s), .tooLarge(let s),
             .signature(let s), .staging(let s), .install(let s):
            return s
        case .rateLimited(let reset):
            let when = reset.map { " after " + $0.formatted(date: .omitted, time: .shortened) } ?? " later"
            return "GitHub limits how often a Mac can check for updates without signing in. Try again\(when)."
        }
    }
}
