import SwiftUI
import FacetCore
import FacetDesign

/// Build the selected visual: its type, the fields in each well, sorting, drilling, calculations and analytics.
struct BuildPane: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        if let spec = store.selectedVisual {
            VisualBuilder(spec: spec)
        } else if store.selection.count > 1 {
            MultiSelectionBuilder()
        } else {
            BuildGallery()
        }
    }
}

// MARK: - Nothing selected: gallery

private struct BuildGallery: View {
    @EnvironmentObject var store: DocumentStore
    private let columns = Array(repeating: GridItem(.flexible(minimum: 56), spacing: 6), count: 4)

    var body: some View {
        VStack(spacing: 0) {
            FieldPaneHeader("Build", subtitle: "Choose a visual, or drag fields onto the page") {
                Button("Open Data pane") { store.inspector = .data }
            }
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.l) {
                    ForEach(VisualCatalog.groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: Design.Space.s) {
                            SectionLabel(group.name)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                                ForEach(group.types, id: \.self) { t in
                                    TypeTile(type: t, isCurrent: false) { AppCommands.run("insert.visual.\(t.rawValue)", store) }
                                }
                            }
                        }
                    }
                }
                .padding(Design.Space.m)
            }
        }
    }
}

/// Icon + short name for a visual type.
struct TypeTile: View {
    let type: VisualType
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: VisualCatalog.symbol(for: type)).font(.system(size: 17, weight: .light)).frame(height: 20)
                Text(type.displayName.replacingOccurrences(of: " chart", with: ""))
                    .font(.system(size: 9.5)).lineLimit(2).multilineTextAlignment(.center)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
            }
            .foregroundStyle(isCurrent ? Color.accentColor : Color.primary)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, minHeight: 58, maxHeight: 58)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : (hovering ? Design.Palette.fillStrong : Design.Palette.fill)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(type.displayName)
        .accessibilityLabel(type.displayName)
    }
}

// MARK: - Several selected

private struct MultiSelectionBuilder: View {
    @EnvironmentObject var store: DocumentStore
    private let align: [(String, String, String)] = [
        ("format.alignLeft", "align.horizontal.left", "Align left"), ("format.alignCenter", "align.horizontal.center", "Align centre"),
        ("format.alignRight", "align.horizontal.right", "Align right"), ("format.alignTop", "align.vertical.top", "Align top"),
        ("format.alignMiddle", "align.vertical.center", "Align middle"), ("format.alignBottom", "align.vertical.bottom", "Align bottom"),
    ]
    var body: some View {
        let grouped = store.selectedVisuals.contains { $0.groupID != nil }
        VStack(alignment: .leading, spacing: 0) {
            FieldPaneHeader("\(store.selection.count) visuals selected", subtitle: "Arrange them together") {
                Button("Deselect all") { store.selection = [] }
            }
            Hairline()
            VStack(alignment: .leading, spacing: Design.Space.m) {
                SectionLabel("Align")
                HStack(spacing: 2) {
                    ForEach(align, id: \.0) { id, symbol, help in IconButton(symbol, help: help) { AppCommands.run(id, store) } }
                }
                SectionLabel("Distribute")
                HStack(spacing: 2) {
                    IconButton("distribute.horizontal", help: "Distribute horizontally") { AppCommands.run("format.distributeH", store) }
                    IconButton("distribute.vertical", help: "Distribute vertically") { AppCommands.run("format.distributeV", store) }
                }
                .disabled(store.selection.count < 3)
                SectionLabel("Size")
                HStack(spacing: Design.Space.s) {
                    Button("Match width") { AppCommands.run("format.sameWidth", store) }
                    Button("Match height") { AppCommands.run("format.sameHeight", store) }
                }
                .controlSize(.small)
                SectionLabel("Group")
                HStack(spacing: Design.Space.s) {
                    Button("Group") { AppCommands.run("format.group", store) }
                    Button("Ungroup") { AppCommands.run("format.ungroup", store) }.disabled(!grouped)
                }
                .controlSize(.small)
            }
            .padding(Design.Space.m)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - One selected

private struct VisualBuilder: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        let wells = spec.type.wells
        let hasData = !spec.type.isPageElement && !wells.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                TypeSwitcher(spec: spec)
                Hairline()
                if !wells.isEmpty {
                    FieldPaneSection("Data", count: spec.allFields.count) {
                        VStack(alignment: .leading, spacing: Design.Space.m) {
                            ForEach(wells, id: \.self) { w in WellSection(spec: spec, well: w) }
                        }
                    }
                }
                if hasData {
                    if !spec.allFields.isEmpty { SortSection(spec: spec) }
                    if let w = BuildLogic.drillWell(spec), spec.fields(w).count >= 2 { DrillSection(spec: spec, well: w) }
                    if !spec.type.isSlicer { VisualCalculationsSection(spec: spec) }
                    if !BuildLogic.analyticsKinds(for: spec, model: store.model).isEmpty || !spec.analytics.isEmpty { AnalyticsSection(spec: spec) }
                }
                if !BuildLogic.conditionalTargets(for: spec.type).isEmpty { ConditionalFormatsSection(spec: spec) }
                if hasData && !spec.type.isSlicer { TooltipSection(spec: spec) }
                if spec.type.isSlicer { SlicerSettingsSection(spec: spec) }
                if spec.type == .button || spec.type == .image || spec.type == .shape { ActionSection(spec: spec) }
                if wells.isEmpty && !(spec.type == .button || spec.type == .image || spec.type == .shape) {
                    PaneHint("This element has no data fields. Style it in the Format pane.")
                        .padding(Design.Space.m)
                }
            }
        }
    }
}

/// Current type chip with a popover grid to switch type.
private struct TypeSwitcher: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    @State private var showing = false

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Image(systemName: VisualCatalog.symbol(for: spec.type))
                .font(.system(size: 15, weight: .light))
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Design.Palette.fill))
            VStack(alignment: .leading, spacing: 1) {
                Text(spec.name).font(Design.Typeface.bodyStrong).lineLimit(1)
                Text(spec.type.displayName).font(Design.Typeface.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !spec.type.isPageElement {
                Button("Change") { showing = true }
                    .controlSize(.small)
                    .help("Change visual type")
                    .popover(isPresented: $showing, arrowEdge: .leading) {
                        TypeGrid(spec: spec) { t in
                            showing = false
                            if t != spec.type { store.changeType(of: spec.id, to: t) }
                        }
                    }
            }
        }
        .padding(Design.Space.m)
    }
}

private struct TypeGrid: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let choose: (VisualType) -> Void
    @State private var search = ""
    private let columns = Array(repeating: GridItem(.fixed(66), spacing: 6), count: 5)

    var body: some View {
        let suggested = BuildLogic.suggestedTypes(for: spec, model: store.model)
        VStack(spacing: 0) {
            SearchField(text: $search, prompt: "Search visuals").padding(Design.Space.s)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    if search.isEmpty, !suggested.isEmpty {
                        group("Suggested for these fields", suggested)
                    }
                    ForEach(VisualCatalog.groups, id: \.name) { g in
                        let types = g.types.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
                        if !types.isEmpty { group(g.name, types) }
                    }
                }
                .padding(Design.Space.m)
            }
        }
        .frame(width: 5 * 66 + 4 * 6 + 2 * Design.Space.m, height: 420)
    }

    private func group(_ name: String, _ types: [VisualType]) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            SectionLabel(name)
            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(types, id: \.self) { t in TypeTile(type: t, isCurrent: t == spec.type) { choose(t) } }
            }
        }
    }
}

// MARK: - Wells

/// One field well: a drop target holding reorderable field chips.
struct WellSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let well: Well
    @State private var targeted = false
    @State private var picking = false

    var body: some View {
        let fields = spec.fields(well)
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(well.displayName).font(Design.Typeface.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                MiniIconButton("plus", help: "Add data to \(well.displayName)") { picking = true }
                    .popover(isPresented: $picking, arrowEdge: .leading) {
                        FieldPicker(allowsMeasures: !well.isGrouping) { ref in
                            picking = false
                            store.dropField(ref, on: spec.id, well: well)
                        }
                    }
            }
            .frame(height: 20)
            VStack(spacing: 2) {
                if fields.isEmpty {
                    Text(well.isGrouping ? "Drop a column here" : "Drop a field here")
                        .font(Design.Typeface.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Design.Space.s)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                            .strokeBorder(Design.Palette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                } else {
                    ForEach(Array(fields.enumerated()), id: \.element.id) { i, f in
                        FieldChipRow(spec: spec, well: well, field: f, index: i)
                    }
                    // Tail zone so a drop below the last chip appends.
                    Color.clear.frame(height: 6)
                }
            }
            .contentShape(Rectangle())
            .dropHighlight(targeted)
            .dropDestination(for: String.self) { items, _ in
                store.handleWellDrop(items, visualID: spec.id, well: well, at: nil)
            } isTargeted: { targeted = $0 }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(well.displayName) well")
    }
}

/// A field in a well: drag to reorder or move, chevron for options, × to remove.
private struct FieldChipRow: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let well: Well
    let field: FieldRef
    let index: Int
    @State private var insertTargeted = false
    @State private var hovering = false
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    private var column: ModelColumn? { store.model.column(field) }
    private var exists: Bool { store.model.contains(field) }

    var body: some View {
        HStack(spacing: Design.Space.xs) {
            Image(systemName: exists ? FieldGlyph.symbol(for: field, in: store.model) : "exclamationmark.triangle")
                .font(.system(size: 10)).foregroundStyle(exists ? AnyShapeStyle(.secondary) : AnyShapeStyle(Design.Palette.caution))
                .frame(width: 14)
                .help(exists ? "\(field.table) · \(field.name)" : "“\(field.name)” is no longer in the model")
            if renaming {
                TextField(field.name, text: $draft)
                    .textFieldStyle(.plain).font(Design.Typeface.body)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { renaming = false }
                    .onChange(of: renameFocused) { _, f in if !f && renaming { commitRename() } }
                    .onAppear { renameFocused = true }
            } else {
                Text(field.caption).font(Design.Typeface.body).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(field.isHidden ? .secondary : .primary)
                if field.isHidden {
                    Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary).help("Hidden — still available to visual calculations")
                }
                if !field.showAs.isEmpty {
                    Text("%").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).help(Self.showAsTitle(field.showAs))
                }
            }
            Spacer(minLength: 0)
            Menu { menu } label: {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 20, height: 22).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Field options").accessibilityLabel("Options for \(field.caption)")
            MiniIconButton("xmark", help: "Remove \(field.caption)") { store.removeField(field.id, from: well, in: spec.id) }
        }
        .padding(.leading, Design.Space.s).padding(.trailing, 2)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(hovering ? Design.Palette.fillStrong : Design.Palette.fill))
        .overlay(alignment: .top) {
            Capsule().fill(Color.accentColor).frame(height: 2).offset(y: -2).opacity(insertTargeted ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .draggable(PaneDrag.chip(visual: spec.id, well: well, field: field.id)) {
            Chip(field.caption, systemImage: FieldGlyph.symbol(for: field, in: store.model)).padding(2)
        }
        .dropDestination(for: String.self) { items, _ in
            store.handleWellDrop(items, visualID: spec.id, well: well, at: index)
        } isTargeted: { insertTargeted = $0 }
        .contextMenu { menu }
    }

    private func commitRename() {
        let name = draft.trimmingCharacters(in: .whitespaces)
        renaming = false
        var plain = field
        plain.displayName = nil
        let new: String? = (name.isEmpty || name == plain.caption) ? nil : name
        guard new != field.displayName else { return }
        store.updateField(field.id, in: well, of: spec.id, name: "Rename Field", invalidates: .visuals([spec.id])) { $0.displayName = new }
    }

    static func showAsTitle(_ key: String) -> String {
        switch key {
        case "percentOfGrandTotal": return "Percent of grand total"
        case "percentOfColumnTotal": return "Percent of column total"
        case "percentOfRowTotal": return "Percent of row total"
        default: return "No calculation"
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button("Rename for this visual") { draft = field.caption; renaming = true }
        if field.displayName != nil {
            Button("Reset name") { store.updateField(field.id, in: well, of: spec.id, name: "Reset Field Name") { $0.displayName = nil } }
        }
        if field.kind == .column, !well.isGrouping, let c = column {
            Divider()
            Picker("Summarize", selection: Binding(get: { field.aggregation }, set: { a in
                store.updateField(field.id, in: well, of: spec.id, name: "Change Aggregation") { $0.aggregation = a; if a == .none { $0.showAs = "" } }
            })) {
                if BuildLogic.acceptsRawColumns(well, in: spec.type) {
                    Text(Aggregation.none.displayName).tag(Aggregation.none)
                    Divider()
                }
                ForEach(Aggregation.valid(for: c.dataType), id: \.self) { a in Text(a.label(for: c.dataType)).tag(a) }
            }
        }
        if field.isAggregate, !well.isGrouping, spec.type == .table || spec.type == .matrix {
            Picker("Show value as", selection: Binding(get: { field.showAs }, set: { s in
                store.updateField(field.id, in: well, of: spec.id, name: "Show Value As") { $0.showAs = s }
            })) {
                Text("No calculation").tag("")
                Divider()
                Text("Percent of grand total").tag("percentOfGrandTotal")
                Text("Percent of column total").tag("percentOfColumnTotal")
                if spec.type == .matrix { Text("Percent of row total").tag("percentOfRowTotal") }
            }
        }
        if !well.isGrouping {
            Toggle("Hide", isOn: Binding(get: { field.isHidden }, set: { h in
                store.updateField(field.id, in: well, of: spec.id, name: h ? "Hide Field" : "Show Field") { $0.isHidden = h }
            }))
        }
        let others = spec.type.wells.filter { $0 != well && !($0.isGrouping && field.kind == .measure) }
        if !others.isEmpty {
            Menu("Move to") {
                ForEach(others, id: \.self) { w in
                    Button(w.displayName) { store.moveChip(.init(visual: spec.id, well: well, field: field.id), to: w) }
                }
            }
        }
        if AppCommands.command("model.quickMeasure") != nil {
            Button("New quick measure…") { FieldPaneContext.run("model.quickMeasure", table: field.table, field: field, store) }
        }
        Divider()
        Button("Remove", role: .destructive) { store.removeField(field.id, from: well, in: spec.id) }
    }
}
