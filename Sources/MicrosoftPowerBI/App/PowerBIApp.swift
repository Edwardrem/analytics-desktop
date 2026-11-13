import SwiftUI
import FacetCore
import FacetDesign

/// Identifies one document window. Codable so SwiftUI can restore windows.
struct DocumentHandle: Codable, Hashable, Identifiable {
    var id = UUID()
    var url: URL?
}

/// Live stores by window handle, so auxiliary windows (Power Query Editor…) can find their document.
@MainActor
final class StoreRegistry {
    static let shared = StoreRegistry()
    private var stores: [UUID: DocumentStore] = [:]

    func store(for handle: DocumentHandle) -> DocumentStore {
        if let s = stores[handle.id] { return s }
        var doc = FacetDocument()
        var url: URL?
        var problem: String?
        if let u = handle.url {
            do {
                let result = try FileOperations.read(u)
                doc = result.document
                if u.pathExtension.lowercased() == DocumentPackage.fileExtension { url = u }
                if !result.warnings.isEmpty { problem = "Opened with notes:\n" + result.warnings.prefix(8).joined(separator: "\n") }
            } catch { problem = "Couldn't open “\(u.lastPathComponent)”. \(error.localizedDescription)" }
        }
        let s = DocumentStore(document: doc, url: url, services: .live())
        if let problem { s.status = StatusMessage(kind: url == nil && handle.url != nil && doc.model.tables.isEmpty ? .error : .warning, text: problem) }
        stores[handle.id] = s
        return s
    }
    func store(id: UUID) -> DocumentStore? { stores[id] }
    func id(of store: DocumentStore) -> UUID? { stores.first { $0.value === store }?.key }
    func remove(_ id: UUID) { stores[id] = nil }
    var all: [DocumentStore] { Array(stores.values) }
}

@main
struct PowerBIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("appearance") private var appearance = "system"

    init() { Features.registerAll() }

    var body: some Scene {
        WindowGroup(id: "document", for: DocumentHandle.self) { $handle in
            DocumentWindow(handle: handle)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        } defaultValue: {
            DocumentHandle()
        }
        .defaultSize(width: 1440, height: 900)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands { PowerBIMenus() }

        // Auxiliary windows are addressed by their document's handle id.
        WindowGroup("Power Query Editor", id: "query-editor", for: UUID.self) { $id in
            AuxiliaryWindow(documentID: id) { Features.queryEditor($0) }
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
        .defaultSize(width: 1280, height: 800)

        Settings {
            Features.settings()
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for store in StoreRegistry.shared.all where store.isDirty {
            if !FileOperations.confirmClose(store) { return .terminateCancel }
        }
        return .terminateNow
    }

    /// Finder double-click / `open` of documents.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { FileOperations.openInNewWindow?(url) }
    }
}

/// Hosts a view that belongs to another window's document.
struct AuxiliaryWindow<Content: View>: View {
    let documentID: UUID?
    @ViewBuilder let content: (DocumentStore) -> Content
    var body: some View {
        if let id = documentID, let store = StoreRegistry.shared.store(id: id) {
            content(store).environmentObject(store)
        } else {
            EmptyState(systemImage: "macwindow", title: "Document closed", message: "The document this window belonged to is no longer open.")
                .frame(minWidth: 400, minHeight: 240)
        }
    }
}

/// The menu bar, generated from the command registry so it can never drift from the palette.
struct PowerBIMenus: Commands {
    @FocusedObject var store: DocumentStore?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New") { openWindow(id: "document", value: DocumentHandle()) }.keyboardShortcut("n")
            items(.file, upTo: "file.save")
        }
        CommandGroup(replacing: .saveItem) { items(.file, from: "file.save") }
        CommandGroup(replacing: .undoRedo) { items(.edit, upTo: "edit.cut") }
        CommandGroup(after: .pasteboard) { items(.edit, from: "edit.cut") }
        CommandMenu("Insert") {
            items(.insert, upTo: "insert.visual.")
            Divider()
            ForEach(VisualCatalog.groups, id: \.name) { group in
                Menu(group.name) {
                    ForEach(group.types, id: \.self) { t in item("insert.visual.\(t.rawValue)") }
                }
            }
        }
        CommandMenu("Data") { items(.data) }
        CommandMenu("Modeling") { items(.modeling) }
        CommandMenu("Format") { items(.format) }
        CommandGroup(before: .toolbar) { items(.view); Divider() }
        CommandMenu("Optimize") { items(.optimize) }
        CommandMenu("Account") { items(.account) }
        CommandGroup(after: .help) { items(.help) }
    }

    /// Items of one menu, optionally limited to the range before/after a command id prefix.
    @ViewBuilder private func items(_ menu: AppCommand.Menu, upTo: String? = nil, from: String? = nil) -> some View {
        let all = AppCommands.all.filter { $0.menu == menu }
        let list: [AppCommand] = {
            if let upTo, let i = all.firstIndex(where: { $0.id.hasPrefix(upTo) }) { return Array(all[..<i]) }
            if let from, let i = all.firstIndex(where: { $0.id.hasPrefix(from) }) { return Array(all[i...]) }
            return all
        }()
        ForEach(Array(list.enumerated()), id: \.element.id) { index, c in
            if c.separatorBefore, index > 0 { Divider() }
            row(c)
        }
    }
    @ViewBuilder private func item(_ id: String) -> some View {
        if let c = AppCommands.command(id) { row(c) }
    }
    @ViewBuilder private func row(_ c: AppCommand) -> some View {
        let enabled = store.map(c.isEnabled) ?? false
        let title = title(for: c)
        if let isOn = c.isOn {
            Toggle(title, isOn: Binding(get: { store.map(isOn) ?? false }, set: { _ in if let store { c.run(store) } }))
                .keyboardShortcut(c.shortcut).disabled(!enabled)
        } else {
            Button(title) { if let store { c.run(store) } }
                .keyboardShortcut(c.shortcut).disabled(!enabled)
        }
    }
    private func title(for c: AppCommand) -> String {
        switch c.id {
        case "edit.undo": return store?.undoName.map { "Undo \($0)" } ?? "Undo"
        case "edit.redo": return store?.redoName.map { "Redo \($0)" } ?? "Redo"
        default: return c.title
        }
    }
}
