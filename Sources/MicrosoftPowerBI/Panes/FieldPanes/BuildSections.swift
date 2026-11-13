import SwiftUI
import FacetCore
import FacetDesign

// Sort, drill, tooltip, slicer and action sections of the Build pane.

// MARK: - Sort

struct SortSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    /// Distinct fields of the visual, by key.
    private var choices: [FieldRef] {
        var seen = Set<String>()
        return spec.allFields.filter { seen.insert($0.key).inserted }
    }
    private var allowsLevels: Bool { spec.type == .table || spec.type == .matrix }

    var body: some View {
        let fields = choices
        FieldPaneSection("Sort", expanded: !spec.sort.isEmpty) {
            if spec.sort.isEmpty {
                row(index: nil, sort: nil, fields: fields)
            } else {
                ForEach(Array(spec.sort.enumerated()), id: \.offset) { i, s in row(index: i, sort: s, fields: fields) }
            }
            if allowsLevels, !spec.sort.isEmpty, spec.sort.count < fields.count {
                Button("Add sort level") {
                    let used = Set(spec.sort.map(\.field.key))
                    guard let next = fields.first(where: { !used.contains($0.key) }) else { return }
                    store.updateVisual(spec.id, name: "Sort") { $0.sort.append(SortSpec(field: next, descending: false)) }
                }
                .controlSize(.small).buttonStyle(.link)
            }
        }
    }

    private func row(index: Int?, sort: SortSpec?, fields: [FieldRef]) -> some View {
        HStack(spacing: Design.Space.xs) {
            Picker(index.map { $0 == 0 ? "Sort by" : "Then by" } ?? "Sort by", selection: Binding(get: { sort?.field.key ?? "" }, set: { key in
                store.updateVisual(spec.id, name: "Sort") { v in
                    guard let f = fields.first(where: { $0.key == key }) else {
                        if let index { v.sort.remove(at: index) }
                        return
                    }
                    if let index, v.sort.indices.contains(index) { v.sort[index].field = f }
                    else { v.sort = [SortSpec(field: f, descending: f.isAggregate)] }
                }
            })) {
                Text(index == nil || index == 0 ? "Default order" : "None").tag("")
                Divider()
                ForEach(fields) { f in Text(f.caption).tag(f.key) }
            }
            .labelsHidden().controlSize(.small)
            .frame(maxWidth: .infinity)
            if let index, let sort {
                MiniIconButton(sort.descending ? "arrow.down" : "arrow.up",
                               help: sort.descending ? "Descending — click for ascending" : "Ascending — click for descending") {
                    store.updateVisual(spec.id, name: "Sort Direction") { v in
                        if v.sort.indices.contains(index) { v.sort[index].descending.toggle() }
                    }
                }
            }
        }
    }
}

// MARK: - Drill

struct DrillSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let well: Well

    var body: some View {
        let levels = spec.fields(well)
        let level = min(spec.drillLevel, levels.count - 1)
        FieldPaneSection("Drill") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(levels.enumerated()), id: \.element.id) { i, f in
                    HStack(spacing: Design.Space.s) {
                        Circle().fill(i == level ? Color.accentColor : (i < level || spec.expandedAllLevels ? Color.accentColor.opacity(0.35) : Design.Palette.fillStrong))
                            .frame(width: 6, height: 6)
                        Text(f.caption).font(Design.Typeface.caption)
                            .foregroundStyle(i == level ? .primary : .secondary).fontWeight(i == level ? .semibold : .regular)
                        if i < spec.drillPath.count {
                            Text(ValueFormatter.format(spec.drillPath[i])).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 18)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Level \(level + 1) of \(levels.count): \(levels[level].caption)")
            HStack(spacing: Design.Space.s) {
                Button { store.drill(.up, in: spec.id) } label: { Label("Drill up", systemImage: "arrow.up") }
                    .disabled(spec.drillLevel == 0)
                    .help("Go back up one level")
                Button { store.drill(.down(nil), in: spec.id) } label: { Label("Next level", systemImage: "arrow.down") }
                    .disabled(level >= levels.count - 1)
                    .help("Show the next level for all data")
                if well == .category {
                    Button { store.drill(.expandAll, in: spec.id) } label: { Label("Expand", systemImage: "arrow.down.right.and.arrow.up.left") }
                        .disabled(level >= levels.count - 1)
                        .help("Expand all down one level, keeping parent levels")
                }
            }
            .controlSize(.small).labelStyle(.titleOnly)
        }
    }
}

// MARK: - Tooltip

struct TooltipSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        let pages = store.report.pages.filter(\.isTooltipPage)
        FieldPaneSection("Tooltip", expanded: spec.tooltipPageID != nil) {
            if pages.isEmpty {
                PaneHint("Design a small page to show when readers hover over this visual.")
                Button("New tooltip page") { AppCommands.run("insert.tooltipPage", store) }.controlSize(.small)
            } else {
                PropertyRow("Page") {
                    Picker("Tooltip page", selection: Binding(get: { spec.tooltipPageID }, set: { id in
                        store.updateVisual(spec.id, name: "Tooltip Page", invalidates: .layout) { $0.tooltipPageID = id }
                    })) {
                        Text("Default tooltip").tag(UUID?.none)
                        Divider()
                        ForEach(pages) { p in Text(p.name).tag(UUID?.some(p.id)) }
                    }
                    .labelsHidden().controlSize(.small)
                }
            }
        }
    }
}

// MARK: - Slicer

struct SlicerSettingsSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        let groups = Set(store.report.pages.flatMap { $0.visuals.compactMap(\.syncGroup) }).filter { !$0.isEmpty }.sorted()
        FieldPaneSection("Slicer settings") {
            PropertyRow("Sync group") {
                CommitTextField("None", text: spec.syncGroup ?? "") { name in
                    let n = name.trimmingCharacters(in: .whitespaces)
                    store.updateVisual(spec.id, name: "Sync Group", invalidates: .layout) { $0.syncGroup = n.isEmpty ? nil : n }
                }
            }
            let others = groups.filter { $0 != spec.syncGroup }
            if !others.isEmpty {
                PropertyRow("Join") {
                    Menu("Existing group") {
                        ForEach(others, id: \.self) { g in
                            Button(g) { store.updateVisual(spec.id, name: "Sync Group", invalidates: .layout) { $0.syncGroup = g } }
                        }
                    }
                    .controlSize(.small).fixedSize()
                }
            }
            PaneHint("Slicers that share a group name keep the same selection on every page.")
        }
    }
}

// MARK: - Action

struct ActionSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    static func title(_ k: ActionSpec.Kind) -> String {
        switch k {
        case .none: return "None"
        case .back: return "Back"
        case .bookmark: return "Bookmark"
        case .drillthrough: return "Drill through"
        case .pageNavigation: return "Page navigation"
        case .qna: return "Q&A"
        case .webURL: return "Web URL"
        case .applyAllSlicers: return "Apply all slicers"
        case .clearAllSlicers: return "Clear all slicers"
        case .dataFunction: return "Data function"
        }
    }

    private func edit(_ name: String = "Change Action", _ change: @escaping (inout ActionSpec) -> Void) {
        store.updateVisual(spec.id, name: name, invalidates: .layout) { v in
            var a = v.action ?? ActionSpec()
            change(&a)
            v.action = a
        }
    }

    var body: some View {
        let action = spec.action ?? ActionSpec()
        FieldPaneSection("Action") {
            PropertyRow("Type") {
                Picker("Action type", selection: Binding(get: { action.kind }, set: { k in edit { $0.kind = k } })) {
                    ForEach(ActionSpec.Kind.allCases, id: \.self) { k in Text(Self.title(k)).tag(k) }
                }
                .labelsHidden().controlSize(.small)
            }
            switch action.kind {
            case .bookmark:
                if store.report.bookmarks.isEmpty {
                    PaneHint("This report has no bookmarks yet. Add one in the Bookmarks pane.")
                } else {
                    PropertyRow("Bookmark") {
                        Picker("Bookmark", selection: Binding(get: { action.bookmarkID }, set: { id in edit { $0.bookmarkID = id } })) {
                            Text("Choose…").tag(UUID?.none)
                            ForEach(store.report.bookmarks) { b in Text(b.name).tag(UUID?.some(b.id)) }
                        }
                        .labelsHidden().controlSize(.small)
                    }
                }
            case .pageNavigation, .drillthrough:
                let pages = action.kind == .drillthrough ? store.report.pages.filter(\.isDrillthroughPage) : store.report.pages.filter { !$0.isTooltipPage }
                if pages.isEmpty {
                    PaneHint("No drillthrough pages yet. Add a drillthrough field to a page in the Filters pane.")
                } else {
                    PropertyRow("Destination") {
                        Picker("Destination", selection: Binding(get: { action.pageID }, set: { id in edit { $0.pageID = id } })) {
                            Text(action.kind == .drillthrough ? "First matching page" : "Choose…").tag(UUID?.none)
                            ForEach(pages) { p in Text(p.name).tag(UUID?.some(p.id)) }
                        }
                        .labelsHidden().controlSize(.small)
                    }
                }
            case .webURL:
                PropertyRow("URL") {
                    CommitTextField("https://", text: action.url) { u in edit { $0.url = u.trimmingCharacters(in: .whitespaces) } }
                }
                if !action.url.isEmpty, !["http", "https", "mailto"].contains(URL(string: action.url)?.scheme?.lowercased() ?? "") {
                    PaneHint("Only http, https and mailto links open.")
                }
            case .dataFunction:
                PropertyRow("Function") {
                    CommitTextField("Function name", text: action.functionName) { n in edit { $0.functionName = n.trimmingCharacters(in: .whitespaces) } }
                }
            case .none, .back, .qna, .applyAllSlicers, .clearAllSlicers:
                EmptyView()
            }
            if action.kind != .none {
                PropertyRow("Tooltip") {
                    CommitTextField("Shown on hover", text: action.tooltip) { t in edit { $0.tooltip = t } }
                }
                if [.bookmark, .pageNavigation, .drillthrough, .webURL].contains(action.kind) {
                    PropertyRow("Conditional") {
                        FieldPickerButton(selection: action.conditionalMeasure, placeholder: "No measure", allowsColumns: false) { m in
                            edit { $0.conditionalMeasure = m }
                        }
                    }
                    .help("A measure whose value supplies the destination dynamically")
                }
            }
        }
    }
}
