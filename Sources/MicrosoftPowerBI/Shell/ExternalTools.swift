import AppKit
import FacetCore

/// A tool registered on the External tools tab. The file format is Power BI Desktop's
/// `*.pbitool.json` (`name`, `description`, `path`, `arguments`), so existing registrations carry over;
/// `path` is an executable or an `.app` bundle on this Mac.
struct ExternalTool: Equatable {
    /// What a registration's argument template may ask for.
    enum Placeholder: String, CaseIterable {
        /// The saved document on disk.
        case file = "%file%"
        /// Desktop's local Analysis Services endpoint and database: this app has neither.
        case server = "%server%"
        case database = "%database%"
    }

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
        return ExternalTool(name: name, description: (f.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                            path: path, arguments: f.arguments ?? "")
    }

    /// The name as an id fragment: letters and digits, everything else a dash.
    var slug: String { name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined() }

    /// A command id for each tool, in order. Names that differ only in case or punctuation share a
    /// slug; the later ones get "-2", "-3"… so no tool is dropped.
    static func commandIDs(for tools: [ExternalTool]) -> [String] {
        var used = Set<String>()
        return tools.map { tool in
            let base = "externalTools.tool." + tool.slug
            var id = base
            var n = 2
            while !used.insert(id).inserted { id = "\(base)-\(n)"; n += 1 }
            return id
        }
    }

    /// Splits an argument template into words the way a command line does for plain words and
    /// double-quoted runs. Nothing is substituted and no shell is involved.
    static func split(_ template: String) -> [String] {
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
        return out
    }

    /// The placeholders a template uses.
    static func placeholders(in template: String) -> Set<Placeholder> {
        let lowered = template.lowercased()
        return Set(Placeholder.allCases.filter { lowered.contains($0.rawValue) })
    }

    /// Fills placeholders in one pass over `text`: what is substituted in is never scanned again, so a
    /// file path that happens to contain "%database%" stays as it is.
    static func substitute(_ text: String, values: [Placeholder: String]) -> String {
        var out = ""
        var rest = Substring(text)
        scan: while !rest.isEmpty {
            if rest.first == "%" {
                for (placeholder, value) in values where rest.prefix(placeholder.rawValue.count).lowercased() == placeholder.rawValue {
                    out += value
                    rest = rest.dropFirst(placeholder.rawValue.count)
                    continue scan
                }
            }
            out.append(rest.removeFirst())
        }
        return out
    }

    /// The argv for this tool: the template split into words, then each word filled. Always an array —
    /// a value with spaces or quotes stays one argument.
    func argv(file: String) -> [String] {
        ExternalTool.split(arguments).map { ExternalTool.substitute($0, values: [.file: file]) }
    }

    /// True when the template is nothing but the document, so an app can simply be asked to open it.
    var opensOnlyTheFile: Bool {
        ExternalTool.split(arguments).map { $0.lowercased() } == [Placeholder.file.rawValue]
    }

    /// What to do when the tool is chosen.
    enum Launch: Equatable {
        /// Start it with these arguments.
        case run(arguments: [String])
        /// Ask the app to open the document (works whether or not the app is already running).
        case openDocument(URL)
        /// The tool needs the document on disk and it is untitled or has unsaved changes.
        case saveFirst
        case refuse(String)
    }

    /// Decides how to launch, from the document's saved state. Never produces an empty stand-in for a
    /// placeholder: a tool that needs something this app cannot give is refused with the reason.
    func launch(file: URL?, isDirty: Bool, isApplication: Bool) -> Launch {
        let used = ExternalTool.placeholders(in: arguments)
        if used.contains(.server) || used.contains(.database) {
            return .refuse("“\(name)” asks for %server% or %database%. \(AppIdentity.name) has no local Analysis Services endpoint for a tool to connect to, so it can't be started with those arguments. Change its .pbitool.json to use %file% (the saved document) and reload.")
        }
        guard used.contains(.file) else { return .run(arguments: argv(file: "")) }
        guard let file, !isDirty else { return .saveFirst }
        if isApplication && opensOnlyTheFile { return .openDocument(file) }
        return .run(arguments: argv(file: file.path))
    }
}

@MainActor
enum ExternalTools {
    /// Where registrations live: ~/Library/Application Support/<app name>/External Tools.
    static var folder: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("\(AppIdentity.name)/External Tools", isDirectory: true)
    }

    private static var loaded: [ExternalTool]?
    /// The registered tools, by name; read from disk once and again on reload.
    static var tools: [ExternalTool] {
        if let loaded { return loaded }
        let list = read()
        loaded = list
        return list
    }

    /// Reads the folder. Files that are not valid registrations are skipped.
    private static func read() -> [ExternalTool] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.lowercased().hasSuffix(".pbitool.json") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { (try? Data(contentsOf: $0)).flatMap(ExternalTool.decode) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One command per registered tool, plus the two that manage registrations.
    static func commands() -> [AppCommand] {
        let tools = self.tools
        var c = zip(tools, ExternalTool.commandIDs(for: tools)).map { tool, id in
            AppCommand(id: id, title: tool.name, menu: .tools, symbol: "hammer", help: tool.description) { launch(tool, $0) }
        }
        c.append(AppCommand(id: "externalTools.openFolder", title: "Open External Tools Folder", menu: .tools, symbol: "folder",
                            separatorBefore: true) { openFolder($0) })
        c.append(AppCommand(id: "externalTools.reload", title: "Reload External Tools", menu: .tools, symbol: "arrow.clockwise") { reload($0) })
        return c
    }

    private static func reload(_ store: DocumentStore) {
        let list = read()
        loaded = list
        AppCommands.invalidate()
        // Every open window draws its ribbon and menus from the registry: tell them all it changed.
        for other in StoreRegistry.shared.all { other.objectWillChange.send() }
        store.objectWillChange.send()
        store.status = StatusMessage(kind: .info, text: list.isEmpty
            ? "No external tools are registered. Put a .pbitool.json file in the tools folder."
            : "\(list.count) external tool\(list.count == 1 ? "" : "s") registered.")
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
        let url = URL(fileURLWithPath: path)
        let isApplication = url.pathExtension.lowercased() == "app"
        var decision = tool.launch(file: store.fileURL, isDirty: store.isDirty, isApplication: isApplication)
        if decision == .saveFirst {
            guard confirmSave(for: tool, untitled: store.fileURL == nil), FileOperations.save(store) else {
                store.status = StatusMessage(kind: .info, text: "“\(tool.name)” wasn't started: it reads the saved document, and this one has unsaved changes.")
                return
            }
            decision = tool.launch(file: store.fileURL, isDirty: store.isDirty, isApplication: isApplication)
        }
        switch decision {
        case .refuse(let reason):
            store.status = StatusMessage(kind: .error, text: reason)
        case .saveFirst:
            store.status = StatusMessage(kind: .error, text: "“\(tool.name)” wasn't started: the document could not be saved.")
        case .openDocument(let document):
            NSWorkspace.shared.open([document], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                report(error, tool, store)
            }
        case .run(let arguments):
            if isApplication {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = arguments
                // Launch arguments only reach a new process; without this a running copy would be
                // brought forward and the arguments silently dropped.
                configuration.createsNewApplicationInstance = !arguments.isEmpty
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in report(error, tool, store) }
            } else {
                let process = Process()
                process.executableURL = url
                process.arguments = arguments      // argv, never a shell command line
                do { try process.run() } catch {
                    store.status = StatusMessage(kind: .error, text: "Couldn't run “\(tool.name)”. \(error.localizedDescription)")
                }
            }
        }
    }

    private static func confirmSave(for tool: ExternalTool, untitled: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = untitled ? "Save this document to use “\(tool.name)”?" : "Save your changes to use “\(tool.name)”?"
        alert.informativeText = "The tool reads the document from disk, so it would not see what is only in this window."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private nonisolated static func report(_ error: Error?, _ tool: ExternalTool, _ store: DocumentStore) {
        guard let error else { return }
        let message = error.localizedDescription
        Task { @MainActor in store.status = StatusMessage(kind: .error, text: "Couldn't open “\(tool.name)”. \(message)") }
    }
}
