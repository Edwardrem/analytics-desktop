import SwiftUI
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
    @Published private var gridStates: [String: GridViewState] = [:]
    @Published private(set) var gridRevision = 0

    func gridState(for table: String) -> GridViewState { gridStates[table] ?? GridViewState() }
    func setGridState(_ state: GridViewState, for table: String) {
        gridStates[table] = state
        gridRevision += 1
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

/// Resolves "the current table / field" for commands: modeling selection, then the Data pane's
/// context, then the table chosen in Table view, then the first table.
@MainActor
enum ModelingTarget {
    /// What the Data pane last focused, when that pane publishes it. See `ModelingExternalContext.swift`.
    static var externalTable: (DocumentStore) -> String? = { _ in nil }
    static var externalField: (DocumentStore) -> FieldRef? = { _ in nil }

    static func table(_ store: DocumentStore) -> String? {
        let ui = store.modeling
        for r in ui.selection.reversed() { if let t = r.tableName, store.model.table(t) != nil { return t } }
        if let t = externalTable(store) ?? externalField(store)?.table, store.model.table(t) != nil { return t }
        if let t = ui.tableViewTable, store.model.table(t) != nil { return t }
        return store.model.tables.first?.name
    }
    static func column(_ store: DocumentStore) -> (table: String, name: String)? {
        if let c = store.modeling.selectedColumn, store.model.table(c.table)?.column(c.name) != nil { return c }
        if let f = externalField(store), f.kind == .column, store.model.table(f.table)?.column(f.name) != nil { return (f.table, f.name) }
        return nil
    }
    static func measure(_ store: DocumentStore) -> (table: String, name: String)? {
        if let m = store.modeling.selectedMeasure, store.model.table(m.table)?.measure(m.name) != nil { return m }
        if let f = externalField(store), f.kind == .measure, let found = store.model.measure(f.name) { return (found.table.name, found.measure.name) }
        return nil
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
