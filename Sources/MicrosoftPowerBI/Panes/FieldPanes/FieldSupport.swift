import SwiftUI
import FacetCore
import FacetDesign

// Shared pieces of the Data, Build and Filters panes: glyphs, drag payloads, the field picker,
// and a few compact controls sized for a 300-pt inspector.

// MARK: - Glyphs

enum FieldGlyph {
    static let measure = "function"
    static let hierarchy = "list.bullet.indent"
    static let dateLevel = "calendar.day.timeline.left"
    static let folder = "folder"

    static func symbol(column c: ModelColumn) -> String {
        switch c.dataCategory {
        case .address, .city, .continent, .country, .county, .stateOrProvince, .postalCode, .place, .latitude, .longitude:
            return "globe"
        case .webURL: return "link"
        case .imageURL: return "photo"
        case .barcode: return "barcode"
        case .uncategorized: break
        }
        if c.isKey { return "key" }
        if c.grouping != nil { return "square.on.square.dashed" }
        if c.dataType.isTemporal { return "calendar" }
        if c.dataType.isNumeric { return c.summarizeBy == .none ? "number" : "sum" }
        if c.dataType == .boolean { return "checkmark.circle" }
        return "textformat"
    }
    static func symbol(table t: ModelTable) -> String {
        if t.isDateTable { return "calendar" }
        return t.isCalculated ? "tablecells.badge.ellipsis" : "tablecells"
    }
    static func symbol(for ref: FieldRef, in model: SemanticModel) -> String {
        if ref.kind == .measure { return measure }
        guard let c = model.column(ref) else { return "questionmark.circle" }
        if ref.aggregation != .none { return "sum" }
        return symbol(column: c)
    }
}

extension SemanticModel {
    func column(_ ref: FieldRef) -> ModelColumn? {
        ref.kind == .column ? table(ref.table)?.column(ref.name) : nil
    }
    /// True when the referenced column or measure still exists.
    func contains(_ ref: FieldRef) -> Bool {
        ref.kind == .measure ? table(ref.table)?.measure(ref.name) != nil : column(ref) != nil
    }
    /// The type of the values a field produces in a visual or filter.
    func resultType(of ref: FieldRef) -> DataType {
        if ref.kind == .measure { return .decimal }
        let base = column(ref)?.dataType ?? .text
        switch ref.aggregation {
        case .none, .min, .max, .first, .last: return base
        case .count, .distinctCount: return .integer
        default: return .decimal
        }
    }
}

extension Aggregation {
    /// Aggregations that make sense for a column of the given type (excluding `.none`).
    static func valid(for type: DataType) -> [Aggregation] {
        if type.isNumeric { return [.sum, .average, .min, .max, .count, .distinctCount, .stdDev, .variance, .median] }
        if type.isTemporal { return [.min, .max, .count, .distinctCount] }
        return [.first, .last, .count, .distinctCount]
    }
    func label(for type: DataType) -> String {
        if type.isTemporal { if self == .min { return "Earliest" }; if self == .max { return "Latest" } }
        return displayName
    }
}

// MARK: - Drag payloads private to the panes

/// Payloads for dragging things that already live in a pane (the canvas ignores them).
enum PaneDrag {
    struct ChipRef { var visual: UUID; var well: Well; var field: UUID }

    static func chip(visual: UUID, well: Well, field: UUID) -> String {
        "facet-chip:\(visual.uuidString)|\(well.rawValue)|\(field.uuidString)"
    }
    static func decodeChip(_ s: String) -> ChipRef? {
        guard s.hasPrefix("facet-chip:") else { return nil }
        let p = s.dropFirst("facet-chip:".count).split(separator: "|").map(String.init)
        guard p.count == 3, let v = UUID(uuidString: p[0]), let w = Well(rawValue: p[1]), let f = UUID(uuidString: p[2]) else { return nil }
        return ChipRef(visual: v, well: w, field: f)
    }
    static func filter(_ id: UUID) -> String { "facet-filter:\(id.uuidString)" }
    static func decodeFilter(_ s: String) -> UUID? {
        s.hasPrefix("facet-filter:") ? UUID(uuidString: String(s.dropFirst("facet-filter:".count))) : nil
    }
}

// MARK: - Field picker

/// Searchable list of the model's fields, grouped by table. Used by every "Add data" button.
struct FieldPicker: View {
    @EnvironmentObject var store: DocumentStore
    var allowsMeasures = true
    var allowsColumns = true
    /// Extra restriction on columns (e.g. numeric only).
    var columnFilter: (ModelColumn) -> Bool = { _ in true }
    let onPick: (FieldRef) -> Void
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private struct Entry: Identifiable { var id: String; var ref: FieldRef; var symbol: String }

    private func entries(_ t: ModelTable) -> [Entry] {
        var out: [Entry] = []
        let tableMatches = search.isEmpty || t.name.localizedCaseInsensitiveContains(search)
        func matches(_ name: String) -> Bool { tableMatches || name.localizedCaseInsensitiveContains(search) }
        if allowsMeasures {
            for m in t.measures where !m.isHidden && matches(m.name) {
                out.append(Entry(id: "m|\(t.name)|\(m.name)", ref: .measure(t.name, m.name), symbol: FieldGlyph.measure))
            }
        }
        if allowsColumns {
            for c in t.columns where !c.isHidden && columnFilter(c) && matches(c.name) {
                out.append(Entry(id: "c|\(t.name)|\(c.name)", ref: .column(t.name, c.name), symbol: FieldGlyph.symbol(column: c)))
            }
        }
        return out
    }

    var body: some View {
        let groups = store.model.tables.filter { !$0.isHidden }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            .map { ($0, entries($0)) }.filter { !$0.1.isEmpty }
        VStack(spacing: 0) {
            SearchField(text: $search, prompt: "Search fields")
                .focused($searchFocused)
                .padding(Design.Space.s)
            Hairline()
            if groups.isEmpty {
                EmptyState(systemImage: "magnifyingglass", title: store.model.tables.isEmpty ? "No data yet" : "No matching fields")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(groups, id: \.0.id) { table, items in
                            SectionLabel(table.name)
                                .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.s).padding(.bottom, Design.Space.xs)
                            ForEach(items) { e in
                                PickerRow(symbol: e.symbol, title: e.ref.name) { onPick(e.ref) }
                            }
                        }
                    }
                    .padding(.bottom, Design.Space.s)
                }
            }
        }
        .frame(width: 248, height: 320)
        .onAppear { searchFocused = true }
    }
}

private struct PickerRow: View {
    let symbol: String
    let title: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
                Text(title).font(Design.Typeface.body).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.m)
            .frame(height: 26)
            .background(hovering ? Design.Palette.fillStrong : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Button showing the chosen field (or a placeholder) that opens the field picker.
struct FieldPickerButton: View {
    @EnvironmentObject var store: DocumentStore
    let selection: FieldRef?
    var placeholder = "Choose a field"
    var allowsMeasures = true
    var allowsColumns = true
    var allowsClear = true
    var columnFilter: (ModelColumn) -> Bool = { _ in true }
    let onChange: (FieldRef?) -> Void
    @State private var picking = false

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Button { picking = true } label: {
                HStack(spacing: Design.Space.xs) {
                    if let s = selection {
                        Image(systemName: FieldGlyph.symbol(for: s, in: store.model)).font(.system(size: 10)).foregroundStyle(.secondary)
                        Text(s.caption).lineLimit(1).truncationMode(.middle)
                    } else {
                        Text(placeholder).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                .font(Design.Typeface.caption)
                .padding(.horizontal, Design.Space.s)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Design.Palette.fill))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $picking, arrowEdge: .leading) {
                FieldPicker(allowsMeasures: allowsMeasures, allowsColumns: allowsColumns, columnFilter: columnFilter) { ref in
                    picking = false
                    onChange(ref)
                }
            }
            if allowsClear, selection != nil {
                MiniIconButton("xmark", help: "Clear") { onChange(nil) }
            }
        }
    }
}

// MARK: - Compact controls

/// Quiet inline search field.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.tertiary)
            TextField(prompt, text: $text).textFieldStyle(.plain).font(Design.Typeface.body)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.fill))
    }
}

/// 22-pt icon button for dense rows.
struct MiniIconButton: View {
    let systemName: String
    let help: String
    var isOn = false
    var role: ButtonRole?
    let action: () -> Void
    @State private var hovering = false
    init(_ systemName: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.isOn = isOn; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? Color.accentColor : (hovering ? Color.primary : Color.secondary))
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(hovering ? Design.Palette.fillStrong : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Text field that writes back on Return or when focus leaves, so each edit is one undo step.
struct CommitTextField: View {
    let placeholder: String
    let text: String
    var font: Font = Design.Typeface.body
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    init(_ placeholder: String, text: String, font: Font = Design.Typeface.body, onCommit: @escaping (String) -> Void) {
        self.placeholder = placeholder; self.text = text; self.font = font; self.onCommit = onCommit
    }
    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.roundedBorder).controlSize(.small).font(font)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, f in if !f { commit() } }
            .onAppear { draft = text }
            .onChange(of: text) { _, t in if !focused { draft = t } }
    }
    private func commit() { if draft != text { onCommit(draft) } }
}

/// Numeric field that commits on Return / focus loss.
struct CommitNumberField: View {
    let value: Double
    var width: CGFloat? = 64
    var range: ClosedRange<Double>?
    let onCommit: (Double) -> Void
    var body: some View {
        TextField("", value: Binding(get: { value }, set: { v in
            let c = range.map { min(max(v, $0.lowerBound), $0.upperBound) } ?? v
            if c != value { onCommit(c) }
        }), format: .number.grouping(.never))
        .textFieldStyle(.roundedBorder).controlSize(.small)
        .multilineTextAlignment(.trailing)
        .frame(width: width)
    }
}

/// Optional numeric field: empty means "automatic".
struct OptionalNumberField: View {
    let value: Double?
    var placeholder = "Auto"
    var width: CGFloat? = 64
    let onCommit: (Double?) -> Void
    var body: some View {
        CommitTextField(placeholder, text: value.map { Value.double($0).asString } ?? "") { s in
            let t = s.trimmingCharacters(in: .whitespaces)
            onCommit(t.isEmpty ? nil : DataTable.parseNumber(t))
        }
        .multilineTextAlignment(.trailing)
        .frame(width: width)
    }
}

/// Colour well bound to a "#RRGGBB" string.
struct CommitColorWell: View {
    let hex: String
    let onChange: (String) -> Void
    var body: some View {
        ColorPicker("", selection: Binding(get: { Color(hex: hex) }, set: { c in
            let h = c.hexString
            if h.caseInsensitiveCompare(hex) != .orderedSame { onChange(h) }
        }), supportsOpacity: false)
        .labelsHidden()
        .controlSize(.small)
    }
}

/// Collapsible pane section with an optional count and trailing accessory (e.g. an add button).
struct FieldPaneSection<Accessory: View, Content: View>: View {
    let title: String
    var count: Int?
    @State private var expanded: Bool
    let accessory: Accessory
    let content: Content
    init(_ title: String, count: Int? = nil, expanded: Bool = true,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title; self.count = count; self._expanded = State(initialValue: expanded)
        self.accessory = accessory(); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                    HStack(spacing: Design.Space.xs) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(.tertiary).frame(width: 10)
                        Text(title).font(Design.Typeface.bodyStrong).lineLimit(1)
                        if let count, count > 0 {
                            Text("\(count)").font(Design.Typeface.caption).foregroundStyle(.tertiary).monospacedDigit()
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title), \(expanded ? "expanded" : "collapsed")")
                accessory
            }
            .frame(height: 32)
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
extension FieldPaneSection where Accessory == EmptyView {
    init(_ title: String, count: Int? = nil, expanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.init(title, count: count, expanded: expanded, accessory: { EmptyView() }, content: content)
    }
}

/// Small secondary line of explanatory text.
struct PaneHint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Design.Typeface.caption).foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title row at the top of a pane with a trailing ••• menu.
struct FieldPaneHeader<MenuContent: View>: View {
    let title: String
    var subtitle: String?
    let menu: MenuContent
    init(_ title: String, subtitle: String? = nil, @ViewBuilder menu: () -> MenuContent) {
        self.title = title; self.subtitle = subtitle; self.menu = menu()
    }
    var body: some View {
        HStack(spacing: Design.Space.s) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Design.Typeface.headline)
                if let subtitle { Text(subtitle).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
            Menu { menu } label: {
                Image(systemName: "ellipsis").font(.system(size: 13)).frame(width: 24, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("More options").accessibilityLabel("More options")
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.top, Design.Space.m).padding(.bottom, Design.Space.s)
    }
}

extension View {
    /// Accent outline + tint shown while a drag hovers over a drop target.
    func dropHighlight(_ on: Bool, radius: CGFloat = Design.Radius.control) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.accentColor.opacity(on ? 0.10 : 0)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor.opacity(on ? 0.8 : 0), lineWidth: 1.5))
            .animation(Design.Motion.quick, value: on)
    }
}
