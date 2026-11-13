import SwiftUI
import Combine
import UniformTypeIdentifiers
import FacetCore
import FacetDesign

// Shared building blocks for the report panes: per-document transient state, and a handful of
// small views (header, collapsible section, inline rename, colour well, drag-to-reorder).

// MARK: - Per-document runtime

/// Transient, per-document state owned by the report panes: the bookmark slideshow, the page
/// auto-refresh timer, and "scroll the Theme pane to…" requests. Never persisted.
@MainActor
final class ReportPaneRuntime: ObservableObject {
    enum ThemeFocus { case page, reportSettings }

    /// Set by the "Page Settings…" / "Report Settings…" commands; consumed by the Theme pane.
    @Published var themeFocus: ThemeFocus?
    let player: BookmarkPlayer
    let autoRefresh: AutoRefreshState
    private(set) weak var store: DocumentStore?
    private var cancellables: Set<AnyCancellable> = []
    private var slicerFields = SyncedFieldWatcher()

    private static var all: [ObjectIdentifier: ReportPaneRuntime] = [:]

    /// The runtime for a document, created (and wired to the store) on first use.
    static func of(_ store: DocumentStore) -> ReportPaneRuntime {
        let key = ObjectIdentifier(store)
        if let existing = all[key], existing.store === store { return existing }
        for (k, r) in all where r.store == nil { r.autoRefresh.stop(); all[k] = nil }
        let runtime = ReportPaneRuntime(store)
        all[key] = runtime
        return runtime
    }

    private init(_ store: DocumentStore) {
        self.store = store
        player = BookmarkPlayer(store: store)
        autoRefresh = AutoRefreshController.shared.state(for: store)
        // Document or page changes may turn page auto refresh on or off, or change a synced slicer's field.
        // `objectWillChange` fires before the change lands, so look on the next main-queue turn.
        store.objectWillChange
            .throttle(for: .milliseconds(150), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.documentChanged() } }
            .store(in: &cancellables)
        documentChanged()
    }

    private func documentChanged() {
        guard let store else { return }
        AutoRefreshController.shared.sync(store)
        slicerFields.reconcile(store)
    }
}

// MARK: - Pane chrome

/// Title row at the top of a pane, with trailing actions.
struct PaneHeader<Trailing: View>: View {
    let title: String
    var detail: String = ""
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Text(title).font(Design.Typeface.headline)
            if !detail.isEmpty {
                Text(detail).font(Design.Typeface.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: Design.Space.s)
            trailing
        }
        .padding(.leading, Design.Space.m).padding(.trailing, Design.Space.s)
        .frame(height: 40)
    }
}

/// Collapsible section that looks like `InspectorSection` but whose expansion the pane controls,
/// so commands can open and scroll to it.
struct PaneSection<Content: View>: View {
    let title: String
    @Binding var expanded: Bool
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(title).font(Design.Typeface.bodyStrong)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, Design.Space.s)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                VStack(alignment: .leading, spacing: Design.Space.s) { content }
                    .padding(.leading, 14)
                    .padding(.bottom, Design.Space.m)
            }
            Hairline()
        }
        .padding(.horizontal, Design.Space.m)
    }
}

/// Quiet explanatory line under a control.
struct PaneNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Design.Typeface.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Row highlight used by the list-like panes.
struct RowHighlight: ViewModifier {
    enum Style { case none, hover, selected, active }
    let style: Style
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(fill)
        )
    }
    private var fill: Color {
        switch style {
        case .none: return .clear
        case .hover: return Design.Palette.fill
        case .selected: return Design.Palette.fillStrong
        case .active: return Color.accentColor.opacity(0.16)
        }
    }
}
extension View {
    func rowHighlight(_ style: RowHighlight.Style) -> some View { modifier(RowHighlight(style: style)) }
}

/// Small disclosure chevron for group rows.
struct DisclosureChevron: View {
    let expanded: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(expanded ? "Collapse \(label)" : "Expand \(label)")
        .accessibilityLabel(expanded ? "Collapse \(label)" : "Expand \(label)")
    }
}

// MARK: - Inline rename

/// A label that turns into a text field while `isEditing` is true. Return or losing focus commits; Esc cancels.
struct InlineRename: View {
    let text: String
    @Binding var isEditing: Bool
    var font: Font = Design.Typeface.body
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        if isEditing {
            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .font(font)
                .focused($focused)
                .onAppear { draft = text; DispatchQueue.main.async { focused = true } }
                .onSubmit { finish(save: true) }
                .onExitCommand { finish(save: false) }
                .onChange(of: focused) { _, isFocused in if !isFocused { finish(save: true) } }
        } else {
            Text(text).font(font).lineLimit(1).truncationMode(.middle)
        }
    }

    private func finish(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if save, !name.isEmpty, name != text { commit(name) }
    }
}

// MARK: - Colour wells

/// A native colour well bound to a "#RRGGBB" string.
struct HexColorWell: View {
    let label: String
    @Binding var hex: String
    var body: some View {
        ColorPicker(label, selection: Binding(
            get: { Color(hex: hex) },
            set: { let h = $0.hexString; if h.caseInsensitiveCompare(hex) != .orderedSame { hex = h } }
        ), supportsOpacity: false)
        .labelsHidden()
        .accessibilityLabel(label)
        .help(label)
    }
}

/// A colour well for an optional colour: nil means "use the default", with a button to go back to it.
struct OptionalHexColorWell: View {
    let label: String
    @Binding var hex: String?
    /// Shown in the well while no colour is set.
    let fallback: String
    var body: some View {
        HStack(spacing: Design.Space.s) {
            HexColorWell(label: label, hex: Binding(get: { hex ?? fallback }, set: { hex = $0 }))
            if hex != nil {
                Button("Default") { hex = nil }
                    .buttonStyle(.link).font(Design.Typeface.caption)
                    .help("Use the default colour")
            } else {
                Text("Default").font(Design.Typeface.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

/// Compact numeric field with a stepper.
struct NumberField: View {
    let label: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...10_000
    var step: Double = 1
    var unit: String = ""
    var body: some View {
        HStack(spacing: Design.Space.xs) {
            TextField(label, value: Binding(
                get: { value },
                set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
            ), format: .number.precision(.fractionLength(0...2)))
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.trailing)
            .frame(width: 56)
            .accessibilityLabel(label)
            Stepper(label, value: Binding(
                get: { value },
                set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
            ), step: step)
            .labelsHidden()
            if !unit.isEmpty { Text(unit).font(Design.Typeface.caption).foregroundStyle(.secondary) }
        }
        .controlSize(.small)
    }
}

// MARK: - Drag to reorder

/// Makes a row a drag source and/or a drop target for reordering inside one pane.
/// Dropping means "insert before this row"; an accent line shows where the item will land.
struct ReorderRow: ViewModifier {
    let id: String
    @Binding var dragging: String?
    var canDrag = true
    /// Called with the dragged row's id when it is dropped on this row.
    let onDrop: (String) -> Void
    @State private var targeted = false

    func body(content: Content) -> some View {
        Group {
            if canDrag {
                content.onDrag {
                    dragging = id
                    return NSItemProvider(object: "facet-reorder:\(id)" as NSString)
                }
            } else { content }
        }
        .onDrop(of: [UTType.plainText], isTargeted: $targeted) { _ in
            defer { dragging = nil }
            guard let source = dragging, source != id else { return false }
            onDrop(source)
            return true
        }
        .overlay(alignment: .top) {
            if targeted, let dragging, dragging != id {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, Design.Space.xs)
                    .allowsHitTesting(false)
            }
        }
    }
}

extension View {
    /// Drag source + drop target ("insert before me").
    func reorderRow(_ id: String, dragging: Binding<String?>, canDrag: Bool = true, onDrop: @escaping (String) -> Void) -> some View {
        modifier(ReorderRow(id: id, dragging: dragging, canDrag: canDrag, onDrop: onDrop))
    }
    /// Drop target only — used for the space below the last row ("move to the end").
    func reorderEnd(_ id: String, dragging: Binding<String?>, onDrop: @escaping (String) -> Void) -> some View {
        modifier(ReorderRow(id: id, dragging: dragging, canDrag: false, onDrop: onDrop))
    }
}

// MARK: - Small helpers

extension Double {
    /// "12 ms", "1.24 s".
    var durationText: String {
        if self >= 1000 { return String(format: "%.2f s", self / 1000) }
        if self >= 10 { return String(format: "%.0f ms", self) }
        return String(format: "%.1f ms", self)
    }
}

extension Collection where Element == String {
    /// `base`, or `base 2`, `base 3`… — the first that isn't already taken.
    func uniqueName(_ base: String) -> String {
        let taken = Set(self)
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}
