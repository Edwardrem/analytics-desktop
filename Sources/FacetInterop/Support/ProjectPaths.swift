import Foundation
import FacetCore

/// Keeps project reads and writes inside the project folder: no writing through symbolic links, and nothing read
/// from or deleted outside the folder, whatever links or `..` paths a project from Git, a ZIP or a share contains.
enum ProjectPaths {
    /// The path with every symbolic link resolved, or nil when it does not exist.
    static func realPath(_ url: URL) -> String? {
        guard let p = realpath(url.path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Where `url` really points: the deepest part that exists is resolved, the rest is appended as written.
    static func resolvedPath(_ url: URL) -> String? {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while true {
            if let real = realPath(existing) { return ([real] + rest).joined(separator: "/") }
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { return nil }
            rest.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }
    }

    /// True when `url` resolves to somewhere strictly beneath `root` (a path from `realPath`).
    static func isInside(_ url: URL, root: String) -> Bool {
        guard let path = resolvedPath(url) else { return false }
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) && path.count > prefix.count
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    /// Throws when `relative` would be written through a symbolic link or outside `folder`. Every existing
    /// component beneath `folder` is checked, the last one included; `folder` itself may be reached through a link.
    static func checkWritable(_ relative: String, in folder: URL, root: String) throws {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." }) else {
            throw InteropError.io("“\(relative)” is not a path inside the project, so nothing was saved.")
        }
        var url = folder
        for (i, part) in parts.enumerated() {
            url.appendPathComponent(part)
            if isSymbolicLink(url) {
                let shown = parts[0...i].joined(separator: "/")
                throw InteropError.io("“\(shown)” in the project folder is a symbolic link. \(AppIdentity.name) doesn't save a project through links, so nothing outside the folder is changed. Replace the link with a real folder or file, or use Save As to write a new project.")
            }
            guard FileManager.default.fileExists(atPath: url.path) else { break }
        }
        guard isInside(parts.reduce(folder) { $0.appendingPathComponent($1) }, root: root) else {
            throw InteropError.io("“\(relative)” resolves outside the project folder, so nothing was saved.")
        }
    }
}
