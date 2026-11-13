import SwiftUI
import FacetCore
import FacetDesign

/// The contents of the model explorer as plain data, so search and grouping are testable.
enum ModelExplorerItems {
    struct Item: Identifiable, Equatable {
        var ref: ModelObjectRef
        var title: String
        var glyph: String
        var isHidden = false
        var children: [Item] = []
        var id: ModelObjectRef { ref }
    }
    struct Section: Identifiable, Equatable {
        var title: String
        var items: [Item]
        var id: String { title }
    }

    /// Every section of the model that has something in it, filtered by `search`. A table stays
    /// when its name or any of its fields matches; with a field match only the matching fields
    /// are listed under it.
    static func sections(_ model: SemanticModel, search: String = "") -> [Section] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        func matches(_ s: String) -> Bool { query.isEmpty || s.lowercased().contains(query) }

        let tables: [Item] = model.tables.compactMap { t in
            var children: [Item] = t.columns.map { Item(ref: .column(table: t.name, name: $0.name), title: $0.name, glyph: ModelGlyph.symbol(for: $0), isHidden: $0.isHidden) }
            children += t.measures.map { Item(ref: .measure(table: t.name, name: $0.name), title: $0.name, glyph: ModelGlyph.measure, isHidden: $0.isHidden) }
            children += t.hierarchies.map { Item(ref: .hierarchy(table: t.name, id: $0.id), title: $0.name, glyph: ModelGlyph.hierarchy, isHidden: $0.isHidden) }
            children += t.calendars.map { Item(ref: .calendar(table: t.name, id: $0.id), title: $0.name, glyph: ModelGlyph.dateTable) }
            if !matches(t.name) {
                children = children.filter { matches($0.title) }
                if children.isEmpty { return nil }
            }
            return Item(ref: .table(t.name), title: t.name, glyph: ModelGlyph.symbol(for: t), isHidden: t.isHidden, children: children)
        }
        func flat(_ title: String, _ items: [Item]) -> Section { Section(title: title, items: items.filter { matches($0.title) }) }
        let all = [
            Section(title: "Tables", items: tables),
            flat("Relationships", model.relationships.map { Item(ref: .relationship($0.id), title: relationshipCaption($0), glyph: ModelGlyph.relationship, isHidden: !$0.isActive) }),
            flat("Calculation groups", model.calculationGroups.map { g in
                Item(ref: .calcGroup(g.id), title: g.name, glyph: "square.stack.3d.up",
                     children: g.items.map { Item(ref: .calcItem(group: g.id, item: $0.id), title: $0.name, glyph: "function") })
            }),
            flat("Functions", model.functions.map { Item(ref: .function($0.id), title: $0.name, glyph: "curlybraces") }),
            flat("Roles", model.roles.map { Item(ref: .role($0.id), title: $0.name, glyph: "lock.shield") }),
            flat("Perspectives", model.perspectives.map { Item(ref: .perspective($0.id), title: $0.name, glyph: "eye") }),
            flat("Cultures", model.translations.map { Item(ref: .culture($0.id), title: $0.culture, glyph: "globe") }),
            flat("Parameters", model.whatIfParameters.map { Item(ref: .whatIf($0.id), title: $0.name, glyph: "slider.horizontal.3") }
                + model.fieldParameters.map { Item(ref: .fieldParameter($0.id), title: $0.name, glyph: "list.bullet.rectangle") }),
        ]
        return all.filter { !$0.items.isEmpty }
    }

    /// "Sales[ProductID] → Product[ProductID]".
    static func relationshipCaption(_ r: Relationship) -> String { "\(r.fromTable)[\(r.fromColumn)] → \(r.toTable)[\(r.toColumn)]" }

    /// The display name of any model object, or nil when it is gone.
    static func caption(for ref: ModelObjectRef, in model: SemanticModel) -> String? {
        switch ref {
        case .table(let t): return model.table(t)?.name
        case .column(let t, let n): return model.table(t)?.column(n)?.name
        case .measure(let t, let n): return model.table(t)?.measure(n)?.name
        case .hierarchy(let t, let id): return model.table(t)?.hierarchies.first { $0.id == id }?.name
        case .calendar(let t, let id): return model.table(t)?.calendars.first { $0.id == id }?.name
        case .relationship(let id): return model.relationships.first { $0.id == id }.map(relationshipCaption)
        case .calcGroup(let id): return model.calculationGroups.first { $0.id == id }?.name
        case .calcItem(let group, let item): return model.calculationGroups.first { $0.id == group }?.items.first { $0.id == item }?.name
        case .function(let id): return model.functions.first { $0.id == id }?.name
        case .role(let id): return model.roles.first { $0.id == id }?.name
        case .perspective(let id): return model.perspectives.first { $0.id == id }?.name
        case .culture(let id): return model.translations.first { $0.id == id }?.culture
        case .whatIf(let id): return model.whatIfParameters.first { $0.id == id }?.name
        case .fieldParameter(let id): return model.fieldParameters.first { $0.id == id }?.name
        case .aggregation(let id): return model.aggregations.first { $0.id == id }.map { "\($0.aggTable)[\($0.aggColumn)]" }
        }
    }
}

/// The model explorer: every object of the semantic model in one searchable tree. Clicking an
/// object selects it (the diagram, the Properties panel and the ribbon follow); table rows can
/// be dragged onto a layout.
struct ModelObjectExplorer: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var modeling: ModelingState
    let controller: ModelCanvasController
    @State private var search = ""
    @State private var collapsedSections: Set<String> = []
    @State private var expanded: Set<ModelObjectRef> = []

    var body: some View {
        let sections = ModelExplorerItems.sections(store.model, search: search)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Text("Model").font(Design.Typeface.bodyStrong)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.m)
            .frame(height: 32)
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search the model", text: $search).textFieldStyle(.plain).font(Design.Typeface.caption)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).help("Clear search")
                }
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.bottom, Design.Space.s)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if sections.isEmpty {
                        Text(search.isEmpty ? "The model is empty." : "Nothing matches “\(search)”.")
                            .font(Design.Typeface.caption).foregroundStyle(.secondary).padding(Design.Space.m)
                    }
                    ForEach(sections) { section in
                        sectionHeader(section)
                        if !collapsedSections.contains(section.title) {
                            ForEach(section.items) { item in
                                row(item, depth: 0)
                                if isExpanded(item) {
                                    ForEach(item.children) { row($0, depth: 1) }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, Design.Space.xs)
            }
        }
    }

    /// While searching, tables open to show what matched.
    private func isExpanded(_ item: ModelExplorerItems.Item) -> Bool {
        !item.children.isEmpty && (expanded.contains(item.ref) || !search.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private func sectionHeader(_ section: ModelExplorerItems.Section) -> some View {
        let collapsed = collapsedSections.contains(section.title)
        return Button {
            if collapsed { collapsedSections.remove(section.title) } else { collapsedSections.insert(section.title) }
        } label: {
            HStack(spacing: Design.Space.xs) {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(collapsed ? 0 : 90)).foregroundStyle(.tertiary).frame(width: 10)
                SectionLabel("\(section.title) (\(section.items.count))")
            }
            .padding(.horizontal, Design.Space.m)
            .padding(.vertical, Design.Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show \(section.title.lowercased())" : "Hide \(section.title.lowercased())")
    }

    private func row(_ item: ModelExplorerItems.Item, depth: Int) -> some View {
        let selected = modeling.isSelected(item.ref)
        let label = HStack(spacing: Design.Space.xs) {
            if depth == 0 {
                Button {
                    if expanded.contains(item.ref) { expanded.remove(item.ref) } else { expanded.insert(item.ref) }
                } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded(item) ? 90 : 0)).foregroundStyle(.tertiary)
                        .frame(width: 14, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(item.children.isEmpty ? 0 : 1)
                .disabled(item.children.isEmpty)
                .help(isExpanded(item) ? "Collapse" : "Expand")
            }
            Image(systemName: item.glyph).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            Text(item.title).font(Design.Typeface.caption).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(item.isHidden ? .secondary : .primary)
            Spacer(minLength: 0)
            if item.isHidden, case .relationship = item.ref {
                Text("inactive").font(Design.Typeface.caption).foregroundStyle(.tertiary)
            } else if item.isHidden {
                Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, Design.Space.s + CGFloat(depth) * 28)
        .padding(.trailing, Design.Space.m)
        .frame(height: 22)
        .background(selected ? Design.Palette.accent.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(item) }
        .onTapGesture {
            modeling.select(item.ref, extending: NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu { ModelMenuItems(entries: menu(for: item)) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        return Group {
            if case .table(let name) = item.ref {
                label.onDrag { NSItemProvider(object: (ModelCanvasController.tablePrefix + name) as NSString) }
            } else {
                label
            }
        }
    }

    /// Double-click: bring a table's card into view, open a relationship or a formula for editing.
    private func open(_ item: ModelExplorerItems.Item) {
        modeling.select(item.ref)
        switch item.ref {
        case .table(let name):
            let layout = ModelLayouts.current(store.model, id: modeling.layoutID)
            if !layout.showsAllTables, ModelDiagram.storedCard(layout, name) == nil {
                ModelLayoutOps.addTables(store, [name], layout: modeling.layoutID)
            }
            controller.reveal(name)
        case .column(let table, _), .measure(let table, _):
            controller.reveal(table)
        case .relationship(let id):
            if let r = store.model.relationships.first(where: { $0.id == id }) { store.present { RelationshipEditSheet(relationship: r) } }
        default:
            break
        }
    }

    private func menu(for item: ModelExplorerItems.Item) -> [ModelMenuEntry] {
        switch item.ref {
        case .table(let name): return ModelDiagramMenus.table(store, table: name, controller: controller)
        case .column, .measure: return ModelDiagramMenus.field(store, ref: item.ref)
        case .relationship(let id): return ModelDiagramMenus.relationship(store, id: id)
        default:
            return [.item(title: "Delete", symbol: "trash") {
                if ModelPrompt.confirm(title: "Delete “\(item.title)”?", message: "You can undo this.") { ModelOps.delete(store, [item.ref]) }
            }]
        }
    }
}
