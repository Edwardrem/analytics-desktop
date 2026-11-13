import SwiftUI
import FacetCore
import FacetDesign

/// The frame every modeling dialog shares: quiet title, content, and a footer of actions.
struct ModelingSheet<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String = ""
    var width: CGFloat = 640
    /// Fixed height, or nil to size to content.
    var height: CGFloat? = 480
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                Text(title).font(Design.Typeface.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, Design.Space.l)
            .padding(.top, Design.Space.l)
            .padding(.bottom, Design.Space.m)
            Hairline()
            content()
                .frame(maxWidth: .infinity, maxHeight: height == nil ? nil : .infinity, alignment: .topLeading)
            Hairline()
            HStack(spacing: Design.Space.s) { footer() }
                .padding(.horizontal, Design.Space.l)
                .padding(.vertical, Design.Space.m)
        }
        .frame(width: width, height: height)
        .background(Design.Palette.surface)
    }
}

/// Standard trailing buttons for a sheet: Cancel + a default action.
struct ModelingSheetButtons: View {
    @EnvironmentObject private var store: DocumentStore
    var cancelTitle: String? = "Cancel"
    var confirmTitle = "Done"
    var confirmDisabled = false
    /// Defaults to dismissing the sheet.
    var confirm: (() -> Void)?

    var body: some View {
        Spacer()
        if let cancelTitle {
            Button(cancelTitle) { store.dismissSheet() }.keyboardShortcut(.cancelAction)
        }
        Button(confirmTitle) { if let confirm { confirm() } else { store.dismissSheet() } }
            .keyboardShortcut(.defaultAction)
            .disabled(confirmDisabled)
    }
}

/// A master list for dialogs that edit a collection (roles, functions, calculation groups…):
/// selectable rows with inline rename, and add/remove at the bottom.
struct NamedListColumn<ID: Hashable>: View {
    struct Item: Identifiable { var id: ID; var name: String; var symbol: String = ""; var detail: String = "" }
    let items: [Item]
    @Binding var selection: ID?
    var addHelp = "Add"
    var width: CGFloat = 200
    var onAdd: (() -> Void)?
    var onDelete: ((ID) -> Void)?
    var onRename: ((ID, String) -> Void)?
    var onMove: ((_ from: Int, _ to: Int) -> Void)?
    var emptyTitle = "Nothing here yet"

    @State private var renaming: ID?
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                EmptyState(systemImage: "plus.circle", title: emptyTitle)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in row(item, index: index) }
                    }
                    .padding(Design.Space.xs)
                }
            }
            Hairline()
            HStack(spacing: 0) {
                if let onAdd { IconButton("plus", help: addHelp, action: onAdd) }
                if let onDelete {
                    IconButton("minus", help: "Remove") { if let s = selection { onDelete(s) } }
                        .disabled(selection == nil).opacity(selection == nil ? 0.4 : 1)
                }
                Spacer()
                if let onMove, let s = selection, let i = items.firstIndex(where: { $0.id == s }) {
                    IconButton("chevron.up", help: "Move up") { onMove(i, i - 1) }.disabled(i == 0).opacity(i == 0 ? 0.4 : 1)
                    IconButton("chevron.down", help: "Move down") { onMove(i, i + 1) }.disabled(i == items.count - 1).opacity(i == items.count - 1 ? 0.4 : 1)
                }
            }
            .padding(.horizontal, Design.Space.xs)
            .padding(.vertical, 2)
        }
        .frame(width: width)
        .background(Design.Palette.fill.opacity(0.5))
    }

    private func row(_ item: Item, index: Int) -> some View {
        let selected = selection == item.id
        return HStack(spacing: Design.Space.s) {
            if !item.symbol.isEmpty {
                Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: 14)
            }
            if renaming == item.id {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Design.Typeface.body)
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(item.name).font(Design.Typeface.body).lineLimit(1)
                Spacer(minLength: 0)
                if !item.detail.isEmpty { Text(item.detail).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1) }
            }
        }
        .padding(.horizontal, Design.Space.s)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { beginRename(item) }
        .onTapGesture { selection = item.id }
        .contextMenu {
            if onRename != nil { Button("Rename") { beginRename(item) } }
            if let onDelete { Button("Delete", role: .destructive) { onDelete(item.id) } }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    private func beginRename(_ item: Item) {
        guard onRename != nil else { return }
        selection = item.id
        draft = item.name
        renaming = item.id
        renameFocused = true
    }
    private func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        let name = draft.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, name != items.first(where: { $0.id == id })?.name { onRename?(id, name) }
    }
}

/// A plain caption-over-control field used in dialogs and the tool strips.
struct ModelField<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) { self.label = label; self.content = content }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(Design.Typeface.caption).foregroundStyle(.secondary)
            content()
        }
    }
}

/// A text field that edits a local draft and commits on Return or when focus leaves — so a document
/// mutation (and undo step) happens once per edit, not per keystroke.
struct ModelTextField: View {
    let placeholder: String
    /// Current value; nil shows a mixed placeholder.
    let value: String?
    var mono = false
    var axis: Axis = .horizontal
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(value == nil ? "Mixed" : placeholder, text: $draft, axis: axis)
            .font(mono ? Design.Typeface.mono : Design.Typeface.body)
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { _, f in if !f { apply() } }
            .onAppear { draft = value ?? "" }
            .onChange(of: value) { _, v in if !focused { draft = v ?? "" } }
    }
    private func apply() {
        if draft != (value ?? ""), !(value == nil && draft.isEmpty) { commit(draft) }
    }
}
