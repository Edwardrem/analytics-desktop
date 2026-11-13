import Foundation
import CoreGraphics
import FacetCore

/// Layout tabs of the Model view: "All tables" plus the layouts the user creates. The pure
/// functions edit a `SemanticModel`; `ModelLayoutOps` writes them to the document.
enum ModelLayouts {
    /// The layout a tab id names; otherwise "All tables"; otherwise the first layout. A model
    /// without layouts (an imported one) gets an "All tables" layout to draw from.
    static func current(_ model: SemanticModel, id: UUID?) -> ModelLayout {
        if let id, let found = model.layouts.first(where: { $0.id == id }) { return found }
        return model.layouts.first { $0.showsAllTables } ?? model.layouts.first ?? ModelLayout(name: "All tables", showsAllTables: true)
    }

    /// The tabs in display order: "All tables" first.
    static func tabs(_ model: SemanticModel) -> [ModelLayout] {
        let all = model.layouts.filter(\.showsAllTables), rest = model.layouts.filter { !$0.showsAllTables }
        return (all.isEmpty ? [current(model, id: nil)] : all) + rest
    }

    /// "Layout 1", "Layout 2"… — the first not taken.
    static func nextName(_ model: SemanticModel) -> String {
        var n = 1
        while model.layouts.contains(where: { ModelDAX.same($0.name, "Layout \(n)") }) { n += 1 }
        return "Layout \(n)"
    }

    /// Index of the layout to edit, adding `layout` to the model first when it was only
    /// synthesised for display.
    static func index(of layout: ModelLayout, in model: inout SemanticModel) -> Int {
        if let i = model.layouts.firstIndex(where: { $0.id == layout.id }) { return i }
        model.layouts.insert(layout, at: 0)
        return 0
    }

    @discardableResult
    static func add(to model: inout SemanticModel, name: String? = nil) -> UUID {
        let layout = ModelLayout(name: name ?? nextName(model))
        model.layouts.append(layout)
        return layout.id
    }

    /// Why a layout can't take this name, or nil.
    static func renameProblem(_ model: SemanticModel, id: UUID, to name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Give the layout a name." }
        if model.layouts.contains(where: { $0.id != id && ModelDAX.same($0.name, name) }) { return "A layout named “\(name)” already exists." }
        return nil
    }

    /// Removes a user layout. "All tables" can't be removed.
    @discardableResult
    static func remove(from model: inout SemanticModel, id: UUID) -> Bool {
        guard let i = model.layouts.firstIndex(where: { $0.id == id }), !model.layouts[i].showsAllTables else { return false }
        model.layouts.remove(at: i)
        return true
    }

    /// Where a table added to a layout goes: to the right of what is there, at its top.
    static func slot(for table: ModelTable, in layout: ModelLayout, model: SemanticModel) -> CGPoint {
        let frames = ModelDiagram.placements(model: model, layout: layout).map { ModelDiagram.cardLayout($0.table, card: $0.card).frame }
        guard let first = frames.first else { return CGPoint(x: ModelDiagram.Metrics.padding, y: ModelDiagram.Metrics.padding) }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        return CGPoint(x: bounds.maxX + ModelDiagram.Metrics.columnGap, y: bounds.minY)
    }

    /// Tables a user layout does not show yet.
    static func addable(_ model: SemanticModel, layout: ModelLayout) -> [ModelTable] {
        layout.showsAllTables ? [] : model.tables.filter { ModelDiagram.storedCard(layout, $0.name) == nil }
    }

    /// Tables related to `table` that a user layout does not show yet.
    static func relatedMissing(_ model: SemanticModel, layout: ModelLayout, table: String) -> [ModelTable] {
        let names = model.relationships.compactMap { r -> String? in
            if ModelDAX.same(r.fromTable, table) { return r.toTable }
            if ModelDAX.same(r.toTable, table) { return r.fromTable }
            return nil
        }
        return addable(model, layout: layout).filter { t in names.contains { ModelDAX.same($0, t.name) } }
    }

    /// Stores a card under the model's spelling of the table name, replacing any other spelling.
    static func setCard(_ card: ModelLayout.Card, for table: String, in layout: inout ModelLayout) {
        for key in layout.cards.keys where ModelDAX.same(key, table) && key != table { layout.cards[key] = nil }
        layout.cards[table] = card
    }

    /// The card positions of the star auto-arrange for the tables a layout shows, keeping each
    /// card's size and collapsed state.
    static func arranged(_ model: SemanticModel, layout: ModelLayout) -> [String: ModelLayout.Card] {
        let placed = ModelDiagram.placements(model: model, layout: layout)
        let origins = ModelDiagram.autoArrange(tables: placed.map { p in
            (p.table.name, ModelDiagram.cardLayout(p.table, card: p.card).frame.size)
        }, relationships: model.relationships)
        var cards: [String: ModelLayout.Card] = [:]
        for p in placed {
            guard let o = origins[p.table.name] else { continue }
            var card = p.card
            card.x = Double(o.x)
            card.y = Double(o.y)
            cards[p.table.name] = card
        }
        return cards
    }
}

/// Writes layout edits to the document. Card positions and layout tabs are part of the file, so
/// they go through `DocumentStore.mutate` and undo like everything else; they don't touch the
/// engine, so they invalidate nothing but layout.
@MainActor
enum ModelLayoutOps {
    private static func edit(_ store: DocumentStore, _ name: String, coalesce: String? = nil, layout id: UUID?,
                             _ body: (inout ModelLayout, SemanticModel) -> Void) {
        store.mutate(name, coalesce: coalesce, invalidates: .layout) { d in
            let layout = ModelLayouts.current(d.model, id: id)
            let i = ModelLayouts.index(of: layout, in: &d.model)
            let model = d.model
            body(&d.model.layouts[i], model)
        }
    }

    /// Stores cards. On "All tables" every card on screen is stored with them, so the tables that
    /// were still auto-placed keep the places they are shown in.
    static func setCards(_ store: DocumentStore, _ cards: [String: ModelLayout.Card], name: String, coalesce: String? = nil, layout id: UUID?) {
        edit(store, name, coalesce: coalesce, layout: id) { layout, model in
            if layout.showsAllTables {
                for p in ModelDiagram.placements(model: model, layout: layout) where ModelDiagram.storedCard(layout, p.table.name) == nil {
                    ModelLayouts.setCard(p.card, for: p.table.name, in: &layout)
                }
            }
            for (table, card) in cards {
                guard let t = model.table(table) else { continue }
                ModelLayouts.setCard(card, for: t.name, in: &layout)
            }
        }
    }

    static func toggleCollapsed(_ store: DocumentStore, table: String, layout id: UUID?) {
        let layout = ModelLayouts.current(store.model, id: id)
        guard let placed = ModelDiagram.placements(model: store.model, layout: layout).first(where: { ModelDAX.same($0.table.name, table) }) else { return }
        var card = placed.card
        card.collapsed.toggle()
        setCards(store, [placed.table.name: card], name: card.collapsed ? "Collapse Table" : "Expand Table", layout: id)
    }

    static func setAllCollapsed(_ store: DocumentStore, _ collapsed: Bool, layout id: UUID?) {
        let layout = ModelLayouts.current(store.model, id: id)
        var cards: [String: ModelLayout.Card] = [:]
        for p in ModelDiagram.placements(model: store.model, layout: layout) {
            var card = p.card
            card.collapsed = collapsed
            cards[p.table.name] = card
        }
        guard !cards.isEmpty else { return }
        setCards(store, cards, name: collapsed ? "Collapse All" : "Expand All", layout: id)
    }

    /// Makes a card tall enough to show every field.
    static func showAllFields(_ store: DocumentStore, table: String, layout id: UUID?) {
        let layout = ModelLayouts.current(store.model, id: id)
        guard let placed = ModelDiagram.placements(model: store.model, layout: layout).first(where: { ModelDAX.same($0.table.name, table) }) else { return }
        var card = placed.card
        card.height = Double(ModelDiagram.naturalHeight(fieldCount: placed.table.columns.count + placed.table.measures.count))
        setCards(store, [placed.table.name: card], name: "Resize Table", layout: id)
    }

    static func autoArrange(_ store: DocumentStore, layout id: UUID?) {
        let cards = ModelLayouts.arranged(store.model, layout: ModelLayouts.current(store.model, id: id))
        guard !cards.isEmpty else { return }
        setCards(store, cards, name: "Auto Arrange", layout: id)
    }

    @discardableResult
    static func addLayout(_ store: DocumentStore) -> UUID {
        var id = UUID()
        store.mutate("New Layout", invalidates: .layout) { d in id = ModelLayouts.add(to: &d.model) }
        store.modeling.layoutID = id
        return id
    }

    static func renameLayout(_ store: DocumentStore, id: UUID, to name: String) {
        if let problem = ModelLayouts.renameProblem(store.model, id: id, to: name) {
            store.status = StatusMessage(kind: .warning, text: problem)
            return
        }
        let name = name.trimmingCharacters(in: .whitespaces)
        store.mutate("Rename Layout", invalidates: .layout) { d in
            if let i = d.model.layouts.firstIndex(where: { $0.id == id }) { d.model.layouts[i].name = name }
        }
    }

    static func deleteLayout(_ store: DocumentStore, id: UUID) {
        store.mutate("Delete Layout", invalidates: .layout) { d in ModelLayouts.remove(from: &d.model, id: id) }
        if store.modeling.layoutID == id { store.modeling.layoutID = nil }
    }

    /// Adds tables to a user layout, each to the right of what is already there.
    static func addTables(_ store: DocumentStore, _ tables: [String], layout id: UUID?, at point: CGPoint? = nil) {
        guard !tables.isEmpty else { return }
        edit(store, tables.count == 1 ? "Add Table to Layout" : "Add Tables to Layout", layout: id) { layout, model in
            guard !layout.showsAllTables else { return }
            var next = point
            for name in tables {
                guard let t = model.table(name), ModelDiagram.storedCard(layout, t.name) == nil else { continue }
                let origin = next ?? ModelLayouts.slot(for: t, in: layout, model: model)
                ModelLayouts.setCard(ModelLayout.Card(x: Double(origin.x), y: Double(origin.y)), for: t.name, in: &layout)
                next = next.map { CGPoint(x: $0.x + ModelDiagram.Metrics.cardWidth + ModelDiagram.Metrics.columnGap, y: $0.y) }
            }
        }
    }

    /// Takes a table off a user layout. The table stays in the model.
    static func removeTable(_ store: DocumentStore, _ table: String, layout id: UUID?) {
        edit(store, "Remove from Layout", layout: id) { layout, _ in
            guard !layout.showsAllTables else { return }
            layout.cards = layout.cards.filter { !ModelDAX.same($0.key, table) }
        }
    }
}
