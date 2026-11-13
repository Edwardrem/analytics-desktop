import AppKit
import FacetCore

/// A tool registered on the External tools tab. The file format is Power BI Desktop's
/// `*.pbitool.json` (`name`, `description`, `path`, `arguments`), so existing registrations carry over;
/// `path` is an executable or an `.app` bundle on this Mac.
struct ExternalTool: Equatable {
    var name: String
    var description: String
    var path: String
    var arguments: String

    /// Reads one registration file. Returns nil when it is not a usable registration.
    static func decode(_ data: Data) -> ExternalTool? {
        struct File: Decodable { var name: String?; var description: String?; var path: String?; var arguments: String? }
        guard let f = try? JSONDecoder().decode(File.self, from: data),
              let name = f.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let path = f.path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else { return nil }
        return ExternalTool(name: name, description: f.description ?? "", path: path, arguments: f.arguments ?? "")
    }

    /// Command id for this tool: stable for a given name.
    var commandID: String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        return "externalTools.tool." + slug
    }

    /// Splits an argument string the way a shell would for plain words and double-quoted runs, after
    /// filling the placeholders. `%file%` is the saved document; Desktop's `%server%` and `%database%`
    /// have no counterpart here (there is no local Analysis Services port) and become empty arguments.
    static func arguments(_ template: String, file: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var started = false
        for ch in template {
            if ch == "\"" { quoted.toggle(); started = true }
            else if ch.isWhitespace && !quoted {
                if started { out.append(current); current = ""; started = false }
            } else { current.append(ch); started = true }
        }
        if started { out.append(current) }
        return out.map {
            $0.replacingOccurrences(of: "%file%", with: file)
                .replacingOccurrences(of: "%server%", with: "")
                .replacingOccurrences(of: "%database%", with: "")
        }
    }
}

@MainActor
enum ExternalTools {
    /// Where registrations live: ~/Library/Application Support/Analytics Desktop/External Tools.
    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Analytics Desktop/External Tools", isDirectory: true)
    }

    /// The registered tools, by name. Files that are not valid registrations are skipped.
    static func load() -> [ExternalTool] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var seen = Set<String>()
        return files.filter { $0.lastPathComponent.lowercased().hasSuffix(".pbitool.json") }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(ExternalTool.decode) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .filter { seen.insert($0.commandID).inserted }
    }

    /// One command per registered tool, plus the two that manage registrations.
    static func commands() -> [AppCommand] {
        var c = load().map { tool in
            AppCommand(id: tool.commandID, title: tool.name, menu: .tools, symbol: "hammer") { launch(tool, $0) }
        }
        c.append(AppCommand(id: "externalTools.openFolder", title: "Open External Tools Folder", menu: .tools, symbol: "folder",
                            separatorBefore: true) { openFolder($0) })
        c.append(AppCommand(id: "externalTools.reload", title: "Reload External Tools", menu: .tools, symbol: "arrow.clockwise") { store in
            AppCommands.invalidate()
            let count = load().count
            store.status = StatusMessage(kind: .info, text: count == 0
                ? "No external tools are registered. Put a .pbitool.json file in the tools folder."
                : "\(count) external tool\(count == 1 ? "" : "s") registered.")
        })
        return c
    }

    private static func openFolder(_ store: DocumentStore) {
        guard let folder else {
            store.status = StatusMessage(kind: .error, text: "Couldn't find the Application Support folder.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            store.status = StatusMessage(kind: .error, text: "Couldn't create the tools folder. \(error.localizedDescription)")
        }
    }

    private static func launch(_ tool: ExternalTool, _ store: DocumentStore) {
        let path = (tool.path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            store.status = StatusMessage(kind: .error, text: "“\(tool.name)” points at \(path), which doesn't exist. Fix its .pbitool.json and reload.")
            return
        }
        let arguments = ExternalTool.arguments(tool.arguments, file: store.fileURL?.path ?? "")
        let url = URL(fileURLWithPath: path)
        if url.pathExtension.lowercased() == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = arguments
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                guard let error else { return }
                let message = error.localizedDescription
                Task { @MainActor in store.status = StatusMessage(kind: .error, text: "Couldn't open “\(tool.name)”. \(message)") }
            }
        } else {
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            do { try process.run() } catch {
                store.status = StatusMessage(kind: .error, text: "Couldn't run “\(tool.name)”. \(error.localizedDescription)")
            }
        }
    }
}
