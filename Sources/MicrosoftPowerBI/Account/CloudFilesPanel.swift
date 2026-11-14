import SwiftUI
import FacetCore
import FacetCloud
import FacetDesign

/// Browses OneDrive and SharePoint to open a document or choose where to save one.
struct CloudFilesPanel: View {
    enum Mode: Equatable { case open, save }
    let mode: Mode
    @EnvironmentObject var store: DocumentStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var runtime = MicrosoftRuntime.shared
    @StateObject private var browser: CloudFileBrowserModel
    @State private var fileName: String
    @State private var saving = false
    @State private var newFolder: String?

    init(mode: Mode, suggestedName: String) {
        self.mode = mode
        _browser = StateObject(wrappedValue: CloudFileBrowserModel(client: MicrosoftRuntime.shared.services.graph))
        _fileName = State(initialValue: suggestedName)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if !runtime.isSignedIn {
                EmptyState(systemImage: "person.crop.circle", title: "Sign in to see your files",
                           message: "Sign in with a Microsoft account to open and save documents in OneDrive and SharePoint.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .bottom) {
                        Button("Sign In…") { dismiss(); AppCommands.run("account.signIn", store) }.padding(Design.Space.xl)
                    }
            } else {
                HStack(spacing: 0) {
                    sidebar.frame(width: 170)
                    Hairline(vertical: true)
                    VStack(spacing: 0) {
                        breadcrumbs
                        Hairline()
                        listing
                    }
                }
            }
            Hairline()
            footer
        }
        .frame(width: 720, height: 480)
        .onAppear {
            browser.allowedExtensions = mode == .open ? CloudDocuments.documentExtensions : [DocumentPackage.fileExtension]
            if runtime.isSignedIn { browser.reload() }
        }
    }

    private var header: some View {
        HStack {
            Text(mode == .open ? "Open from OneDrive or SharePoint" : "Save to OneDrive or SharePoint").font(Design.Typeface.headline)
            Spacer()
            if let account = runtime.activeAccount {
                Text(account.username).font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            TextField("Search", text: $browser.searchText).textFieldStyle(.roundedBorder).frame(width: 180)
                .onSubmit { browser.submitSearch() }
        }
        .padding(Design.Space.l)
    }

    private var sidebar: some View {
        List(selection: Binding(get: { browser.currentPlace }, set: { if let p = $0 { browser.show(p) } })) {
            ForEach(CloudFileBrowserModel.Place.allCases) { place in
                Label(place.title, systemImage: symbol(place)).tag(place)
            }
        }
        .listStyle(.sidebar)
    }

    private func symbol(_ place: CloudFileBrowserModel.Place) -> String {
        switch place {
        case .oneDrive: return "cloud"
        case .recent: return "clock"
        case .shared: return "person.2"
        case .sites: return "building.2"
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: Design.Space.xxs) {
            IconButton("chevron.left", help: "Back to the enclosing folder") { browser.goUp() }.disabled(!browser.canGoUp)
            ForEach(Array(browser.breadcrumbs.enumerated()), id: \.element.id) { index, crumb in
                if index > 0 { Image(systemName: "chevron.right").font(Design.Typeface.caption).foregroundStyle(.tertiary) }
                Button(crumb.title) { browser.navigate(toBreadcrumbAt: index) }
                    .buttonStyle(.plain).font(Design.Typeface.caption)
                    .foregroundStyle(index == browser.breadcrumbs.count - 1 ? .primary : .secondary)
            }
            Spacer()
            if mode == .save, browser.currentFolder != nil {
                IconButton("folder.badge.plus", help: "New folder") { newFolder = "" }
            }
            IconButton("arrow.clockwise", help: "Reload") { browser.reload() }
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.xs)
        .popover(isPresented: Binding(get: { newFolder != nil }, set: { if !$0 { newFolder = nil } })) {
            HStack {
                TextField("Folder name", text: Binding(get: { newFolder ?? "" }, set: { newFolder = $0 })).frame(width: 200)
                Button("Create") {
                    let name = (newFolder ?? "").trimmingCharacters(in: .whitespaces)
                    newFolder = nil
                    guard !name.isEmpty else { return }
                    Task { do { try await browser.createFolder(named: name) } catch { store.status = StatusMessage(kind: .error, text: AccountMessages.describe(error)) } }
                }
            }
            .padding(Design.Space.m)
        }
    }

    @ViewBuilder private var listing: some View {
        if browser.isLoading && browser.entries.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = browser.lastError {
            EmptyState(systemImage: "exclamationmark.triangle", title: "Couldn't list files", message: AccountMessages.describe(error))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if browser.visibleEntries.isEmpty {
            EmptyState(systemImage: "folder", title: "Nothing here", message: mode == .open ? "No documents or folders in this place." : "")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $browser.selection) {
                ForEach(browser.visibleEntries) { entry in
                    row(entry).tag(entry.id)
                }
                if browser.hasMore {
                    Button("Load More") { browser.loadMore() }.buttonStyle(.link).disabled(browser.isLoadingMore)
                }
            }
            .listStyle(.inset)
        }
    }

    private func row(_ entry: CloudFileBrowserModel.Entry) -> some View {
        let document = asDocument(entry)
        let dimmed = mode == .save && !entry.isContainer
        return HStack(spacing: Design.Space.s) {
            Image(systemName: icon(entry, document: document != nil)).foregroundStyle(.secondary).frame(width: 18)
            Text(entry.name).lineLimit(1).foregroundStyle(dimmed ? .tertiary : .primary)
            Spacer()
            if let modified = entry.modified {
                Text(modified, format: .dateTime.day().month(.abbreviated).year()).font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            if let size = entry.size, !entry.isContainer || document != nil {
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(Design.Typeface.caption)
                    .foregroundStyle(.tertiary).frame(width: 70, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { activate(entry) }
        .onTapGesture { browser.selection = entry.id }
    }

    private func icon(_ entry: CloudFileBrowserModel.Entry, document: Bool) -> String {
        switch entry {
        case .site: return "building.2"
        case .library: return "books.vertical"
        case .item(let item):
            if document { return (item.name as NSString).pathExtension.lowercased() == "pbip" ? "folder.badge.gearshape" : "doc.richtext" }
            return item.isFolder ? "folder" : "doc"
        }
    }

    /// The drive item an entry opens as a document, if it is one (in open mode).
    private func asDocument(_ entry: CloudFileBrowserModel.Entry) -> DriveItem? {
        guard case .item(let item) = entry, CloudDocuments.isDocument(item) else { return nil }
        return item
    }

    private func activate(_ entry: CloudFileBrowserModel.Entry) {
        if mode == .open, let item = asDocument(entry) {
            dismiss()
            CloudDocuments.open(item, into: store)
        } else if entry.isContainer {
            browser.open(entry)
        } else if mode == .save, case .item(let item) = entry {
            fileName = item.name
        }
    }

    private var footer: some View {
        HStack(spacing: Design.Space.m) {
            if mode == .save {
                Text("Save as").font(Design.Typeface.caption).foregroundStyle(.secondary)
                TextField("Name", text: $fileName).frame(width: 240)
                Text(browser.currentFolder == nil ? "Choose a folder in OneDrive or a document library." : "Saved as a single .facet file.")
                    .font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            if mode == .open {
                Button("Open") { if let e = browser.selectedEntry { activate(e) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(browser.selectedEntry.map { asDocument($0) == nil && !$0.isContainer } ?? true)
            } else {
                Button(saving ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || browser.currentFolder == nil || fileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Design.Space.l)
    }

    private func save() {
        guard let folder = browser.currentFolder else { return }
        let folderName = browser.breadcrumbs.map(\.title).joined(separator: " ▸ ")
        saving = true
        Task { @MainActor in
            let ok = await CloudDocuments.saveNew(store, in: folder, folderName: folderName, name: fileName)
            saving = false
            if ok { dismiss() }
        }
    }
}
