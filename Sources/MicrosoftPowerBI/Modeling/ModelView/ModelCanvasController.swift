import SwiftUI
import AppKit
import FacetCore

/// Drives the Model-view diagram: turns pointer events into selection, card moves and resizes,
/// relationship drags, panning and zooming. Geometry and hit-testing come from `ModelDiagram`;
/// every document change goes through `ModelLayoutOps`, `ModelOps` or `RelationshipOps`.
@MainActor
final class ModelCanvasController: ObservableObject {
    /// A pointer gesture in progress. Card moves and resizes are shown live from here and written
    /// to the document once, when the pointer is released — one undo step per drag.
    enum Gesture: Equatable {
        case move(cards: [String: ModelLayout.Card], start: CGPoint, delta: CGSize)
        case resize(table: String, card: ModelLayout.Card, size: CGSize, start: CGPoint, delta: CGSize)
        /// Dragging a column towards another table's column.
        case link(table: String, column: String, start: CGPoint, point: CGPoint, target: LinkTarget?)
        case pan(start: CGPoint, offset: CGSize)
    }
    struct LinkTarget: Equatable {
        var table: String
        var column: String
        /// Why a relationship can't be made here; nil when it can.
        var problem: String?
    }

    private weak var store: DocumentStore?
    @Published private(set) var gesture: Gesture?
    /// Size of the diagram area, for fitting and for zooming around its centre.
    var viewSize: CGSize = .zero
    /// The pointer has to travel this far before a press becomes a drag.
    private static let dragThreshold: CGFloat = 3
    private var pressed: (hit: ModelDiagram.Hit, point: CGPoint)?
    /// A card of a multi-selection was pressed without a modifier: if the press turns out to be
    /// a click rather than a drag, the selection narrows to that card.
    private var narrowOnRelease: String?

    init(store: DocumentStore) { self.store = store }

    // MARK: Scene

    var viewport: ModelDiagram.Viewport {
        guard let ui = store?.modeling else { return ModelDiagram.Viewport() }
        return ModelDiagram.Viewport(zoom: ui.zoom, offset: ui.offset)
    }

    private func setViewport(_ v: ModelDiagram.Viewport) {
        guard let ui = store?.modeling else { return }
        if ui.zoom != v.zoom { ui.zoom = v.zoom }
        if ui.offset != v.offset { ui.offset = v.offset }
    }

    func layout(_ store: DocumentStore) -> ModelLayout { ModelLayouts.current(store.model, id: store.modeling.layoutID) }

    /// Cards as they are being dragged or resized, replacing the stored ones while a gesture runs.
    var overrides: [String: ModelLayout.Card] {
        switch gesture {
        case .move(let cards, _, let delta): return cards.mapValues { ModelDiagram.moved($0, by: delta) }
        case .resize(let table, let card, let size, _, let delta): return [table: ModelDiagram.resized(card, from: size, by: delta)]
        default: return [:]
        }
    }

    func scene(_ store: DocumentStore) -> ModelDiagram.Scene {
        ModelDiagram.scene(model: store.model, layout: layout(store), overrides: overrides, front: store.modeling.primary?.tableName)
    }

    private func hit(_ point: CGPoint, _ store: DocumentStore) -> ModelDiagram.Hit {
        let v = viewport
        return ModelDiagram.hit(v.toCanvas(point), in: scene(store), tolerance: ModelDiagram.Metrics.edgeTolerance / v.zoom)
    }

    // MARK: Pointer

    func mouseDown(at point: CGPoint, clicks: Int, extend: Bool) {
        guard let store else { return }
        let hit = hit(point, store)
        pressed = (hit, point)
        narrowOnRelease = nil
        let ui = store.modeling
        switch hit {
        case .toggle(let table):
            pressed = nil
            ModelLayoutOps.toggleCollapsed(store, table: table, layout: ui.layoutID)
        case .more(let table):
            pressed = nil
            ModelLayoutOps.showAllFields(store, table: table, layout: ui.layoutID)
        case .resize(let table):
            ui.select(.table(table))
        case .header(let table), .card(let table):
            // Pressing a card that is already part of a multi-selection keeps it, so the whole
            // selection can be dragged.
            if extend || !ui.isSelected(.table(table)) { ui.select(.table(table), extending: extend) }
            else if ui.selection.count > 1 { narrowOnRelease = table }
            if clicks == 2 { pressed = nil; ModelLayoutOps.toggleCollapsed(store, table: table, layout: ui.layoutID) }
        case .field(let table, let name, let kind):
            let ref: ModelObjectRef = kind == .column ? .column(table: table, name: name) : .measure(table: table, name: name)
            ui.select(ref, extending: extend)
            if clicks == 2 { pressed = nil; editFormula(of: ref, store) }
        case .edge(let id):
            ui.select(.relationship(id), extending: extend)
            if clicks == 2, let r = store.model.relationships.first(where: { $0.id == id }) {
                pressed = nil
                store.present { RelationshipEditSheet(relationship: r) }
            }
        case .canvas:
            if !extend { ui.select(nil) }
        }
    }

    func mouseDragged(to point: CGPoint) {
        guard let store else { return }
        let v = viewport
        if gesture == nil {
            guard let pressed, hypot(point.x - pressed.point.x, point.y - pressed.point.y) >= Self.dragThreshold else { return }
            gesture = begin(pressed.hit, at: pressed.point, store)
        }
        switch gesture {
        case .move(let cards, let start, _):
            gesture = .move(cards: cards, start: start, delta: CGSize(width: (point.x - start.x) / v.zoom, height: (point.y - start.y) / v.zoom))
        case .resize(let table, let card, let size, let start, _):
            gesture = .resize(table: table, card: card, size: size, start: start,
                              delta: CGSize(width: (point.x - start.x) / v.zoom, height: (point.y - start.y) / v.zoom))
        case .link(let table, let column, let start, _, _):
            var target: LinkTarget?
            if case .field(let t, let c, .column) = hit(point, store), !(ModelDAX.same(t, table) && ModelDAX.same(c, column)) {
                target = LinkTarget(table: t, column: c,
                                    problem: ModelDiagram.dropProblem(model: store.model, fromTable: table, fromColumn: column, toTable: t, toColumn: c))
            }
            gesture = .link(table: table, column: column, start: start, point: v.toCanvas(point), target: target)
        case .pan(let start, let offset):
            setViewport(ModelDiagram.Viewport(zoom: v.zoom, offset: CGSize(width: offset.width + point.x - start.x, height: offset.height + point.y - start.y)))
        case nil:
            break
        }
    }

    func mouseUp() {
        defer { gesture = nil; pressed = nil; narrowOnRelease = nil }
        guard let store else { return }
        let ui = store.modeling
        switch gesture {
        case .move(let cards, _, let delta) where delta != .zero:
            ModelLayoutOps.setCards(store, cards.mapValues { ModelDiagram.moved($0, by: delta) },
                                    name: cards.count == 1 ? "Move Table" : "Move Tables", layout: ui.layoutID)
        case .resize(let table, let card, let size, _, let delta) where delta != .zero:
            ModelLayoutOps.setCards(store, [table: ModelDiagram.resized(card, from: size, by: delta)], name: "Resize Table", layout: ui.layoutID)
        case .link(let table, let column, _, _, let target?):
            // Validated again by RelationshipOps, which reports why a drop can't make a relationship.
            RelationshipOps.create(store, tableA: table, columnA: column, tableB: target.table, columnB: target.column)
        default:
            if gesture == nil, let table = narrowOnRelease { ui.select(.table(table)) }
        }
    }

    func cancelGesture() {
        gesture = nil
        pressed = nil
        narrowOnRelease = nil
    }

    private func begin(_ hit: ModelDiagram.Hit, at point: CGPoint, _ store: DocumentStore) -> Gesture? {
        let scene = scene(store)
        let placed = ModelDiagram.placements(model: store.model, layout: layout(store))
        func card(_ table: String) -> ModelLayout.Card? { placed.first { ModelDAX.same($0.table.name, table) }?.card }
        switch hit {
        case .header(let table), .card(let table):
            var tables = store.modeling.selection.compactMap { ref -> String? in
                if case .table(let t) = ref { return t } else { return nil }
            }
            if !tables.contains(where: { ModelDAX.same($0, table) }) { tables = [table] }
            var cards: [String: ModelLayout.Card] = [:]
            for t in tables { if let c = card(t), let name = scene.card(t)?.table { cards[name] = c } }
            return cards.isEmpty ? nil : .move(cards: cards, start: point, delta: .zero)
        case .resize(let table):
            guard let c = card(table), let shown = scene.card(table) else { return nil }
            return .resize(table: shown.table, card: c, size: shown.frame.size, start: point, delta: .zero)
        case .field(let table, let name, .column):
            return .link(table: table, column: name, start: viewport.toCanvas(point), point: viewport.toCanvas(point), target: nil)
        case .field(let table, _, .measure):
            // Measures don't take part in relationships; dragging one moves its card.
            guard let c = card(table), let shown = scene.card(table) else { return nil }
            return .move(cards: [shown.table: c], start: point, delta: .zero)
        case .canvas, .edge:
            return .pan(start: point, offset: viewport.offset)
        case .toggle, .more:
            return nil
        }
    }

    private func editFormula(of ref: ModelObjectRef, _ store: DocumentStore) {
        switch ref {
        case .measure(let table, let name):
            ModelOps.beginFormula(store, kind: .measure, table: table, editing: name)
        case .column(let table, let name) where store.model.table(table)?.column(name)?.isCalculated == true:
            ModelOps.beginFormula(store, kind: .column, table: table, editing: name)
        default:
            break
        }
    }

    // MARK: Viewport

    func scroll(by delta: CGSize) {
        let v = viewport
        setViewport(ModelDiagram.Viewport(zoom: v.zoom, offset: CGSize(width: v.offset.width + delta.width, height: v.offset.height + delta.height)))
    }

    func zoom(by factor: CGFloat, around anchor: CGPoint? = nil) {
        let centre = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        setViewport(ModelDiagram.zoomed(viewport, by: factor, around: centre))
    }

    func resetZoom() {
        let v = viewport
        guard v.zoom > 0 else { return }
        zoom(by: 1 / v.zoom)
    }

    func fit() {
        guard let store, viewSize.width > 0 else { return }
        setViewport(ModelDiagram.fit(ModelDiagram.scene(model: store.model, layout: layout(store)).bounds, in: viewSize))
    }

    /// Scrolls so a table's card is in the middle of the diagram.
    func reveal(_ table: String) {
        guard let store, let card = scene(store).card(table) else { return }
        let v = viewport
        setViewport(ModelDiagram.Viewport(zoom: v.zoom, offset: CGSize(width: viewSize.width / 2 - card.frame.midX * v.zoom,
                                                                     height: viewSize.height / 2 - card.frame.midY * v.zoom)))
    }

    // MARK: Keyboard, menus, tooltips, drops

    /// Deletes what is selected: relationships at once (undoable), tables, columns and measures
    /// after a confirmation.
    func deleteSelection() {
        guard let store else { return }
        let refs = store.modeling.selection
        guard !refs.isEmpty else { return }
        let onlyRelationships = refs.allSatisfy { if case .relationship = $0 { return true } else { return false } }
        if !onlyRelationships {
            let title = refs.count == 1 ? "Delete this \(ModelOps.noun(refs[0]).lowercased()) from the model?" : "Delete \(refs.count) objects from the model?"
            guard ModelPrompt.confirm(title: title, message: "Anything that depends on them stops working. You can undo this.") else { return }
        }
        ModelOps.delete(store, refs)
    }

    func menu(at point: CGPoint) -> [ModelMenuEntry] {
        guard let store else { return [] }
        let hit = hit(point, store)
        let ui = store.modeling
        switch hit {
        case .edge(let id):
            ui.select(.relationship(id))
            return ModelDiagramMenus.relationship(store, id: id)
        case .field(let table, let name, let kind):
            let ref: ModelObjectRef = kind == .column ? .column(table: table, name: name) : .measure(table: table, name: name)
            if !ui.isSelected(ref) { ui.select(ref) }
            return ModelDiagramMenus.field(store, ref: ref)
        case .canvas:
            return ModelDiagramMenus.canvas(store, controller: self)
        default:
            guard let table = hit.table else { return [] }
            if !ui.isSelected(.table(table)) { ui.select(.table(table)) }
            return ModelDiagramMenus.table(store, table: table, controller: self)
        }
    }

    func tooltip(at point: CGPoint) -> String? {
        guard let store else { return nil }
        switch hit(point, store) {
        case .toggle(let table): return scene(store).card(table)?.collapsed == true ? "Expand \(table)" : "Collapse \(table)"
        case .resize: return "Drag to resize"
        case .more(let table): return "Show every field of \(table)"
        case .edge(let id):
            return store.model.relationships.first { $0.id == id }.map {
                "\(RelationshipOps.caption($0)) — \($0.cardinality.displayName)\($0.isActive ? "" : ", inactive"). Double-click to edit."
            }
        case .field(let table, let name, .column):
            guard let c = store.model.table(table)?.column(name) else { return nil }
            var notes = [c.dataType.displayName]
            if c.isKey { notes.append("key") }
            if c.isCalculated { notes.append("calculated") }
            if c.isHidden { notes.append("hidden in report view") }
            return "\(c.name) — \(notes.joined(separator: ", ")). Drag onto a column in another table to relate them."
        case .field(let table, let name, .measure):
            guard let m = store.model.table(table)?.measure(name) else { return nil }
            return "\(m.name) — measure\(m.isHidden ? ", hidden in report view" : ""). Double-click to edit."
        default: return nil
        }
    }

    /// A table dragged in from the model explorer lands on a user layout where it is dropped.
    func dropTable(_ name: String, at point: CGPoint) -> Bool {
        guard let store, let table = store.model.table(name) else { return false }
        let layout = layout(store)
        if layout.showsAllTables || ModelDiagram.storedCard(layout, table.name) != nil {
            store.modeling.select(.table(table.name))
            reveal(table.name)
            return true
        }
        ModelLayoutOps.addTables(store, [table.name], layout: store.modeling.layoutID, at: viewport.toCanvas(point))
        store.modeling.select(.table(table.name))
        return true
    }

    /// Pasteboard text that names a model table, as the explorer writes it when a row is dragged.
    static let tablePrefix = "facet-model-table:"
}

/// Context menus of the diagram.
@MainActor
enum ModelDiagramMenus {
    static func table(_ store: DocumentStore, table name: String, controller: ModelCanvasController) -> [ModelMenuEntry] {
        guard let table = store.model.table(name) else { return [] }
        let ui = store.modeling
        let layout = ModelLayouts.current(store.model, id: ui.layoutID)
        var items: [ModelMenuEntry] = [
            .item(title: "New measure", symbol: "function") { ModelOps.beginFormula(store, kind: .measure, table: table.name) },
            .item(title: "New column", symbol: "tablecells") { ModelOps.beginFormula(store, kind: .column, table: table.name) },
            .separator,
            .item(title: "Show in Table view", symbol: "tablecells") {
                ModelingSelection.select(table: table.name, in: store)
                store.view = .table
            },
            .item(title: "Rename…") {
                if let new = ModelPrompt.text(title: "Rename table", value: table.name) { ModelOps.renameTable(store, table.name, to: new) }
            },
            .item(title: table.isHidden ? "Unhide in report view" : "Hide in report view", symbol: table.isHidden ? "eye" : "eye.slash") {
                ModelOps.toggleHidden(store, .table(table.name))
            },
        ]
        if let query = table.sourceQuery {
            items.append(.item(title: "Refresh data", symbol: "arrow.triangle.2.circlepath") { store.refreshData(only: [query]) })
        }
        items.append(.separator)
        if !layout.showsAllTables {
            let related = ModelLayouts.relatedMissing(store.model, layout: layout, table: table.name)
            items.append(.item(title: "Add related tables", symbol: "plus.rectangle.on.rectangle", enabled: !related.isEmpty) {
                ModelLayoutOps.addTables(store, related.map(\.name), layout: ui.layoutID)
            })
            items.append(.item(title: "Remove from layout", symbol: "minus.rectangle") {
                ModelLayoutOps.removeTable(store, table.name, layout: ui.layoutID)
            })
        }
        items.append(.item(title: "Delete from model…", symbol: "trash") { controller.deleteSelection() })
        return items
    }

    static func field(_ store: DocumentStore, ref: ModelObjectRef) -> [ModelMenuEntry] {
        switch ref {
        case .column(let t, let n):
            guard let table = store.model.table(t), let column = table.column(n) else { return [] }
            var items: [ModelMenuEntry] = []
            if column.isCalculated {
                items.append(.item(title: "Edit formula", symbol: "square.and.pencil") { ModelOps.beginFormula(store, kind: .column, table: table.name, editing: column.name) })
                items.append(.separator)
            }
            items += [
                .submenu(title: "Data type", symbol: "textformat.123", entries: ColumnMenus.dataType(store, table: table.name, column: column)),
                .submenu(title: "Summarize by", entries: ColumnMenus.summarizeBy(store, table: table.name, column: column)),
                .submenu(title: "Data category", entries: ColumnMenus.dataCategory(store, table: table.name, column: column)),
                .submenu(title: "Sort by column", entries: ColumnMenus.sortBy(store, table: table, column: column)),
                .separator,
                .item(title: "Rename…") {
                    if let new = ModelPrompt.text(title: "Rename column", value: column.name) { ModelOps.renameColumn(store, table: table.name, column.name, to: new) }
                },
                .item(title: column.isHidden ? "Unhide in report view" : "Hide in report view", symbol: column.isHidden ? "eye" : "eye.slash") {
                    ModelOps.toggleHidden(store, .column(table: table.name, name: column.name))
                },
                .item(title: "Delete from model…", symbol: "trash") {
                    if ModelPrompt.confirm(title: "Delete “\(column.name)”?", message: "Relationships on this column are removed too. You can undo this.") {
                        ModelOps.delete(store, [.column(table: table.name, name: column.name)])
                    }
                },
            ]
            return items
        case .measure(let t, let n):
            guard let table = store.model.table(t), let measure = table.measure(n) else { return [] }
            return [
                .item(title: "Edit formula", symbol: "square.and.pencil") { ModelOps.beginFormula(store, kind: .measure, table: table.name, editing: measure.name) },
                .submenu(title: "Home table", symbol: "tablecells", entries: ColumnMenus.homeTable(store, table: table.name, measure: measure)),
                .separator,
                .item(title: "Rename…") {
                    if let new = ModelPrompt.text(title: "Rename measure", value: measure.name) { ModelOps.renameMeasure(store, table: table.name, measure.name, to: new) }
                },
                .item(title: measure.isHidden ? "Unhide in report view" : "Hide in report view", symbol: measure.isHidden ? "eye" : "eye.slash") {
                    ModelOps.toggleHidden(store, .measure(table: table.name, name: measure.name))
                },
                .item(title: "Delete from model…", symbol: "trash") {
                    if ModelPrompt.confirm(title: "Delete “\(measure.name)”?", message: "You can undo this.") {
                        ModelOps.delete(store, [.measure(table: table.name, name: measure.name)])
                    }
                },
            ]
        default:
            return []
        }
    }

    static func relationship(_ store: DocumentStore, id: UUID) -> [ModelMenuEntry] {
        guard let r = store.model.relationships.first(where: { $0.id == id }) else { return [] }
        func change(_ body: @escaping (inout Relationship) -> Void) {
            var edited = r
            body(&edited)
            if let problem = RelationshipOps.update(store, edited) { store.status = StatusMessage(kind: .warning, text: problem) }
        }
        return [
            .item(title: "Edit relationship…", symbol: "square.and.pencil") { store.present { RelationshipEditSheet(relationship: r) } },
            .separator,
            .item(title: "Active", checked: r.isActive) { change { $0.isActive.toggle() } },
            .submenu(title: "Cross-filter direction", entries: [
                .item(title: "Single", enabled: r.cardinality != .oneToOne, checked: r.crossFilter == .single) { change { $0.crossFilter = .single } },
                .item(title: "Both", checked: r.crossFilter == .both) { change { $0.crossFilter = .both } },
            ]),
            .submenu(title: "Cardinality", entries: Cardinality.allCases.map { c in
                .item(title: c.displayName, checked: r.cardinality == c) { change { $0.cardinality = c } }
            }),
            .separator,
            .item(title: "Delete", symbol: "trash") { RelationshipOps.delete(store, id) },
        ]
    }

    static func canvas(_ store: DocumentStore, controller: ModelCanvasController) -> [ModelMenuEntry] {
        let ui = store.modeling
        let layout = ModelLayouts.current(store.model, id: ui.layoutID)
        var items: [ModelMenuEntry] = [
            .item(title: "Auto arrange", symbol: "rectangle.3.group") { ModelLayoutOps.autoArrange(store, layout: ui.layoutID); controller.fit() },
            .item(title: "Fit to window", symbol: "arrow.up.left.and.arrow.down.right") { controller.fit() },
            .separator,
            .item(title: "Collapse all") { ModelLayoutOps.setAllCollapsed(store, true, layout: ui.layoutID) },
            .item(title: "Expand all") { ModelLayoutOps.setAllCollapsed(store, false, layout: ui.layoutID) },
        ]
        let addable = ModelLayouts.addable(store.model, layout: layout)
        if !layout.showsAllTables {
            items.append(.separator)
            items.append(.submenu(title: "Add table", symbol: "plus.rectangle", entries: addable.isEmpty
                ? [.item(title: "Every table is on this layout", enabled: false) {}]
                : [.item(title: "All tables") { ModelLayoutOps.addTables(store, addable.map(\.name), layout: ui.layoutID) }, .separator]
                    + addable.map { t in .item(title: t.name, symbol: ModelGlyph.symbol(for: t)) { ModelLayoutOps.addTables(store, [t.name], layout: ui.layoutID) } }))
        }
        return items
    }
}

// MARK: - Event layer

/// The AppKit view over the diagram that receives the pointer, scroll, pinch, keyboard and drop
/// events and hands them to the controller in top-left view coordinates.
struct ModelCanvasEvents: NSViewRepresentable {
    let controller: ModelCanvasController

    func makeNSView(context: Context) -> ModelCanvasEventView {
        let view = ModelCanvasEventView()
        view.controller = controller
        return view
    }
    func updateNSView(_ view: ModelCanvasEventView, context: Context) { view.controller = controller }
}

final class ModelCanvasEventView: NSView {
    weak var controller: ModelCanvasController?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.string])
        setAccessibilityLabel("Model diagram")
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func point(_ event: NSEvent) -> CGPoint { convert(event.locationInWindow, from: nil) }

    override func layout() {
        super.layout()
        controller?.viewSize = bounds.size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let tip = controller?.tooltip(at: point(event))
        if toolTip != tip { toolTip = tip }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let extend = event.modifierFlags.contains(.command) || event.modifierFlags.contains(.shift)
        controller?.mouseDown(at: point(event), clicks: event.clickCount, extend: extend)
    }
    override func mouseDragged(with event: NSEvent) { controller?.mouseDragged(to: point(event)) }
    override func mouseUp(with event: NSEvent) { controller?.mouseUp() }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let entries = controller?.menu(at: point(event)), !entries.isEmpty else { return nil }
        let menu = NSMenu()
        ModelMenuEntry.build(entries, into: menu)
        return menu
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.1
            controller?.zoom(by: 1 + max(-0.5, min(0.5, step)), around: point(event))
        } else {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
            controller?.scroll(by: CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
        }
    }

    override func magnify(with event: NSEvent) {
        controller?.zoom(by: 1 + event.magnification, around: point(event))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: controller?.deleteSelection()   // Delete, Forward Delete
        case 53: controller?.cancelGesture()          // Esc
        default: super.keyDown(with: event)
        }
    }

    // MARK: Drops from the model explorer

    private func tableName(_ sender: NSDraggingInfo) -> String? {
        guard let text = sender.draggingPasteboard.string(forType: .string), text.hasPrefix(ModelCanvasController.tablePrefix) else { return nil }
        return String(text.dropFirst(ModelCanvasController.tablePrefix.count))
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { tableName(sender) == nil ? [] : .copy }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { tableName(sender) == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let name = tableName(sender) else { return false }
        return controller?.dropTable(name, at: convert(sender.draggingLocation, from: nil)) ?? false
    }
}
