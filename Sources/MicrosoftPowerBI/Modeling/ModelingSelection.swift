import SwiftUI
import Combine
import FacetCore

/// Identifies one object of the semantic model. Tables, columns and measures are addressed by name
/// (the way the rest of the app refers to them); everything else by its stable id.
enum ModelObjectRef: Hashable {
    case table(String)
    case column(table: String, name: String)
    case measure(table: String, name: String)
    case hierarchy(table: String, id: UUID)
    case calendar(table: String, id: UUID)
    case relationship(UUID)
    case calcGroup(UUID)
    case calcItem(group: UUID, item: UUID)
    case function(UUID)
    case role(UUID)
    case perspective(UUID)
    case culture(UUID)
    case whatIf(UUID)
    case fieldParameter(UUID)
    case aggregation(UUID)

    /// The table this object belongs to, when it has one.
    var tableName: String? {
        switch self {
        case .table(let t), .column(let t, _), .measure(let t, _), .hierarchy(let t, _), .calendar(let t, _): return t
        default: return nil
        }
    }
}

/// A formula being written in the formula bar: `Name = expression`.
struct FormulaEdit: Identifiable, Equatable {
    enum Kind: String { case measure, column, table
        var noun: String { self == .measure ? "measure" : (self == .column ? "column" : "table") }
        var expressionKind: ExpressionKind {
            switch self { case .measure: return .measure; case .column: return .calculatedColumn; case .table: return .calculatedTable }
        }
    }
    var id = UUID()
    var kind: Kind
    /// Home table for measures and columns; unused for calculated tables.
    var table: String
    /// Name of the object being edited; nil when creating.
    var original: String?
    var text: String
}

/// Transient Model/Table-view state for one document: what is selected, which table the grid shows,
/// and the formula being edited. Never holds document content.
@MainActor
final class ModelingState: ObservableObject {
    /// Selected model objects, in selection order (the last is the primary one).
    @Published var selection: [ModelObjectRef] = []
    /// The table shown in Table view.
    @Published var tableViewTable: String?
    /// Formula bar session, when a measure/column/table is being created or edited inline.
    @Published var formula: FormulaEdit?
    /// The object most recently committed from a formula bar, so its engine error can be surfaced.
    @Published var lastCommitted: ModelObjectRef?
    /// The Model-view layout tab on screen.
    @Published var layoutID: UUID?
    @Published var explorerVisible = true
    @Published var propertiesVisible = true
    /// Diagram viewport.
    @Published var zoom: CGFloat = 1
    @Published var offset: CGSize = .zero
    /// Bumped to ask the diagram to zoom to fit.
    @Published var fitRequest = 0
    /// View-only sort and filters per table in Table view, with a revision bumped on every
    /// change so the grid recomputes its row order. Never written to the document.
    @Published private var grid = GridViewStates()
    @Published private(set) var gridRevision = 0
    /// Bumped whenever the engine publishes data, so the grid reloads after a refresh that
    /// returns the same shape with new values.
    @Published private(set) var dataRevision = 0
    private var subscriptions: Set<AnyCancellable> = []

    func gridState(for table: String) -> GridViewState { grid.state(for: table) }
    func setGridState(_ state: GridViewState, for table: String) {
        grid.set(state, for: table)
        gridRevision += 1
    }
    /// Carries a table's sort and filters over to its new name. Call before the rename is written.
    func renameGridTable(_ old: String, to new: String) {
        if grid.renameTable(old, to: new) { gridRevision += 1 }
    }
    func renameGridColumn(table: String, _ old: String, to new: String) {
        if grid.renameColumn(table: table, old, to: new) { gridRevision += 1 }
    }
    /// Drops sort and filters that point at tables or columns the model no longer has.
    func pruneGrid(to model: SemanticModel) {
        if grid.prune(to: model) { gridRevision += 1 }
    }

    /// Follows a document: view state is pruned whenever the document changes (delete, undo,
    /// open), and the data revision moves whenever the engine publishes data.
    func bind(to store: DocumentStore) {
        subscriptions.removeAll()
        store.$doc.dropFirst()
            .sink { [weak self] doc in self?.pruneGrid(to: doc.model) }
            .store(in: &subscriptions)
        store.$computedData.dropFirst()
            .sink { [weak self] _ in self?.dataRevision += 1 }
            .store(in: &subscriptions)
    }

    var primary: ModelObjectRef? { selection.last }
    func isSelected(_ ref: ModelObjectRef) -> Bool { selection.contains(ref) }

    func select(_ ref: ModelObjectRef?, extending: Bool = false) {
        guard let ref else { selection = []; return }
        if extending {
            if let i = selection.firstIndex(of: ref) { selection.remove(at: i) } else { selection.append(ref) }
        } else if selection != [ref] {
            selection = [ref]
        }
    }

    var selectedColumn: (table: String, name: String)? {
        for r in selection.reversed() { if case .column(let t, let n) = r { return (t, n) } }
        return nil
    }
    var selectedMeasure: (table: String, name: String)? {
        for r in selection.reversed() { if case .measure(let t, let n) = r { return (t, n) } }
        return nil
    }
}

/// Registry of per-document modeling state. Other feature areas (the Data pane) tell modeling what
/// the user picked through `ModelingSelection.select(...)`.
@MainActor
final class ModelingSelection: ObservableObject {
    static let shared = ModelingSelection()
    private struct Entry { weak var store: DocumentStore?; var state: ModelingState }
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// The modeling state for a document, created on first use.
    func state(for store: DocumentStore) -> ModelingState {
        let key = ObjectIdentifier(store)
        if let e = entries[key], e.store != nil { return e.state }
        entries = entries.filter { $0.value.store != nil }
        let s = ModelingState()
        s.bind(to: store)
        entries[key] = Entry(store: store, state: s)
        return s
    }

    /// Select a measure (e.g. from the Data pane) so Measure tools and Properties edit it.
    static func select(measure name: String, table: String? = nil, in store: DocumentStore) {
        guard let found = store.model.measure(name) else { return }
        shared.state(for: store).select(.measure(table: table ?? found.table.name, name: found.measure.name))
    }
    /// Select a column so Column tools and Properties edit it.
    static func select(column name: String, table: String, in store: DocumentStore) {
        shared.state(for: store).select(.column(table: table, name: name))
    }
    /// Select a table (also makes it the table shown in Table view).
    static func select(table: String, in store: DocumentStore) {
        let s = shared.state(for: store)
        s.select(.table(table))
        s.tableViewTable = table
    }
    /// Select whatever a field reference points at.
    static func select(field: FieldRef, in store: DocumentStore) {
        if field.kind == .measure { select(measure: field.name, table: field.table, in: store) }
        else { select(column: field.name, table: field.table, in: store) }
    }
}

extension DocumentStore {
    /// Model/Table-view state for this document.
    var modeling: ModelingState { ModelingSelection.shared.state(for: self) }
    /// The measure selected for Measure tools, if any.
    var selectedMeasure: (table: String, measure: Measure)? {
        guard let (t, n) = ModelingTarget.measure(self), let m = model.table(t)?.measure(n) else { return nil }
        return (t, m)
    }
}

/// Resolves "the current table / field" for commands.
///
/// The Data pane's context is only live while a command it started is running for the same
/// document (`FieldPaneContext.run` sets it, runs the command and clears it), so it can't go stale
/// or leak into another window. It wins while live because the user pointed at that object. After
/// that: in Table view the table on screen; otherwise the modeling selection, the table last shown
/// in Table view, and the first table.
@MainActor
enum ModelingTarget {
    /// What the Data pane is running a command on, for this document, right now.
    static var externalTable: (DocumentStore) -> String? = { _ in nil }
    static var externalField: (DocumentStore) -> FieldRef? = { _ in nil }

    static func table(_ store: DocumentStore) -> String? {
        let ui = store.modeling
        return resolveTable(model: store.model, view: store.view, selection: ui.selection, shown: ui.tableViewTable,
                            external: externalTable(store) ?? externalField(store)?.table)
    }
    static func column(_ store: DocumentStore) -> (table: String, name: String)? {
        resolveField(.column, model: store.model, selection: store.modeling.selection, external: externalField(store))
    }
    static func measure(_ store: DocumentStore) -> (table: String, name: String)? {
        resolveField(.measure, model: store.model, selection: store.modeling.selection, external: externalField(store))
    }

    nonisolated static func resolveTable(model: SemanticModel, view: WorkspaceView, selection: [ModelObjectRef],
                                         shown: String?, external: String?) -> String? {
        if let t = external, let found = model.table(t) { return found.name }
        if view == .table, let t = shown, let found = model.table(t) { return found.name }
        for r in selection.reversed() { if let t = r.tableName, let found = model.table(t) { return found.name } }
        if let t = shown, let found = model.table(t) { return found.name }
        return model.tables.first?.name
    }

    nonisolated static func resolveField(_ kind: FieldRef.Kind, model: SemanticModel, selection: [ModelObjectRef],
                                         external: FieldRef?) -> (table: String, name: String)? {
        if let f = external, f.kind == kind {
            switch kind {
            case .column:
                if let t = model.table(f.table), let c = t.column(f.name) { return (t.name, c.name) }
            case .measure:
                if let t = model.table(f.table), let m = t.measure(f.name) { return (t.name, m.name) }
                if let found = model.measure(f.name) { return (found.table.name, found.measure.name) }
            }
        }
        for r in selection.reversed() {
            switch (kind, r) {
            case (.column, .column(let t, let n)):
                if let table = model.table(t), let c = table.column(n) { return (table.name, c.name) }
                return nil
            case (.measure, .measure(let t, let n)):
                if let table = model.table(t), let m = table.measure(n) { return (table.name, m.name) }
                return nil
            default: continue
            }
        }
        return nil
    }
}

/// View-only sort and filters for every table, keyed case-insensitively by table name the way the
/// model resolves names. Pure, so its upkeep on rename and delete is tested.
struct GridViewStates: Equatable {
    private var states: [String: GridViewState] = [:]

    private func key(_ table: String) -> String { table.lowercased() }
    var isEmpty: Bool { states.isEmpty }

    func state(for table: String) -> GridViewState { states[key(table)] ?? GridViewState() }

    mutating func set(_ state: GridViewState, for table: String) {
        if state == GridViewState() { states[key(table)] = nil } else { states[key(table)] = state }
    }

    /// Moves a table's state to its new name. Returns whether anything changed.
    @discardableResult
    mutating func renameTable(_ old: String, to new: String) -> Bool {
        guard key(old) != key(new), let state = states.removeValue(forKey: key(old)) else { return false }
        states[key(new)] = state
        return true
    }

    @discardableResult
    mutating func renameColumn(table: String, _ old: String, to new: String) -> Bool {
        guard var state = states[key(table)] else { return false }
        var changed = false
        if let sort = state.sortColumn, ModelDAX.same(sort, old), sort != new { state.sortColumn = new; changed = true }
        for name in state.filters.keys where ModelDAX.same(name, old) && name != new {
            state.filters[new] = state.filters.removeValue(forKey: name)
            changed = true
        }
        if changed { states[key(table)] = state }
        return changed
    }

    /// Drops state for tables the model no longer has, and sort and filters on columns it no
    /// longer has. Returns whether anything changed.
    @discardableResult
    mutating func prune(to model: SemanticModel) -> Bool {
        var changed = false
        for (name, var state) in states {
            guard let table = model.table(name) else {
                states[name] = nil
                changed = true
                continue
            }
            let before = state
            if let sort = state.sortColumn, table.column(sort) == nil { state.sortColumn = nil }
            state.filters = state.filters.filter { table.column($0.key) != nil }
            if state != before {
                set(state, for: name)
                changed = true
            }
        }
        return changed
    }
}

// MARK: - Glyphs shared by the grid, diagram and explorer

enum ModelGlyph {
    static func symbol(for type: DataType) -> String {
        switch type {
        case .text: return "textformat"
        case .integer: return "number"
        case .decimal, .currency: return "textformat.123"
        case .boolean: return "checkmark.square"
        case .date: return "calendar"
        case .dateTime: return "calendar.badge.clock"
        case .time, .duration: return "clock"
        case .binary: return "doc"
        case .any: return "questionmark.square.dashed"
        }
    }
    static func symbol(for column: ModelColumn) -> String {
        if column.isKey { return "key" }
        if column.grouping != nil { return "square.stack.3d.up" }
        if column.isCalculated { return "function" }
        switch column.dataCategory {
        case .uncategorized: break
        case .webURL: return "link"
        case .imageURL: return "photo"
        case .barcode: return "barcode"
        default: return "mappin.and.ellipse"
        }
        if column.summarizeBy != .none, column.dataType.isNumeric { return "sum" }
        return symbol(for: column.dataType)
    }
    static let measure = "function"
    static let table = "tablecells"
    static let calculatedTable = "tablecells.badge.ellipsis"
    static let dateTable = "calendar"
    static let hierarchy = "list.bullet.indent"
    static let relationship = "arrow.left.arrow.right"

    static func symbol(for table: ModelTable) -> String {
        table.isDateTable ? dateTable : (table.isCalculated ? calculatedTable : ModelGlyph.table)
    }
    static func label(for mode: StorageMode) -> String {
        switch mode {
        case .import: return "Import"
        case .directQuery: return "DirectQuery"
        case .dual: return "Dual"
        case .directLake: return "Direct Lake"
        case .live: return "Live"
        }
    }
    static func label(for category: DataCategory) -> String {
        switch category {
        case .uncategorized: return "Uncategorized"
        case .address: return "Address"
        case .city: return "City"
        case .continent: return "Continent"
        case .country: return "Country/Region"
        case .county: return "County"
        case .stateOrProvince: return "State or province"
        case .postalCode: return "Postal code"
        case .place: return "Place"
        case .latitude: return "Latitude"
        case .longitude: return "Longitude"
        case .webURL: return "Web URL"
        case .imageURL: return "Image URL"
        case .barcode: return "Barcode"
        }
    }
}
