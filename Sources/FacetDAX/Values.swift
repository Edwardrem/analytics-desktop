import Foundation
import FacetCore

/// Metadata of one column of an intermediate table.
struct ColInfo {
    var name: String
    /// Source table name for `Table[Column]` matching; nil for extension columns.
    var table: String?
    /// The model column this column's values come from (data lineage), if any.
    var lineage: ColumnID?
    var type: DataType = .any

    init(name: String, table: String? = nil, lineage: ColumnID? = nil, type: DataType = .any) {
        self.name = name; self.table = table; self.lineage = lineage; self.type = type
    }
    /// Name used in query results: `Table[Column]` for model columns, the bare name otherwise.
    var displayName: String { table.map { "\($0)[\(name)]" } ?? name }
}

/// Column list with name and lineage lookup.
final class Columns {
    let infos: [ColInfo]
    init(_ infos: [ColInfo]) { self.infos = infos }
    var count: Int { infos.count }

    lazy var byName: [String: Int] = {
        var d: [String: Int] = [:]
        for (i, c) in infos.enumerated() where d[c.name.daxKey] == nil { d[c.name.daxKey] = i }
        return d
    }()
    lazy var byQualified: [String: Int] = {
        var d: [String: Int] = [:]
        for (i, c) in infos.enumerated() {
            guard let t = c.table else { continue }
            let k = t.daxKey + "\u{1F}" + c.name.daxKey
            if d[k] == nil { d[k] = i }
        }
        return d
    }()
    lazy var byLineage: [ColumnID: Int] = {
        var d: [ColumnID: Int] = [:]
        for (i, c) in infos.enumerated() { if let l = c.lineage, d[l] == nil { d[l] = i } }
        return d
    }()
    func index(table: String?, name: String) -> Int? {
        if let t = table { return byQualified[t.daxKey + "\u{1F}" + name.daxKey] }
        return byName[name.daxKey]
    }
}

/// A table value: either a set of rows of a model table (kept by reference) or materialised rows.
struct TableValue {
    let cols: Columns
    /// Rows of a model table (row -1 is the virtual blank row).
    let base: (table: Int, rows: [Int32])?
    let data: [[Value]]

    init(cols: Columns, rows: [[Value]]) { self.cols = cols; base = nil; data = rows }
    init(table: Int, rows: [Int32], db: Database) {
        cols = db.tables[table].cols
        base = (table, rows)
        data = []
    }
    var count: Int { base?.rows.count ?? data.count }
    var isEmpty: Bool { count == 0 }

    /// Materialised row-major data.
    func rows(_ db: Database) -> [[Value]] {
        guard let b = base else { return data }
        let stores = db.tables[b.table].columns.map { $0.values }
        return b.rows.map { r in r < 0 ? [Value](repeating: .null, count: stores.count) : stores.map { $0[Int(r)] } }
    }
    func materialized(_ db: Database) -> TableValue { base == nil ? self : TableValue(cols: cols, rows: rows(db)) }

    func toDataTable(_ db: Database, name: String = "") -> DataTable {
        let rs = rows(db)
        var used = Set<String>()
        let columns: [DataColumn] = cols.infos.enumerated().map { i, info in
            var n = info.displayName
            var k = 2
            while !used.insert(n).inserted { n = "\(info.displayName) \(k)"; k += 1 }
            let vals = rs.map { $0[i] }
            var type = info.type
            if type == .any { type = DataTable.inferType(vals) }
            return DataColumn(name: n, type: type, values: vals)
        }
        return DataTable(name: name, columns: columns)
    }
}

extension TableStore {
    /// Column metadata (with lineage) for this table, cached until columns change.
    var cols: Columns {
        if let c = colsCache, c.count == columns.count { return c }
        let c = Columns(columns.enumerated().map { i, col in
            ColInfo(name: col.name, table: name, lineage: ColumnID(table: index, col: i), type: col.type)
        })
        colsCache = c
        return c
    }
}

enum DAXResult {
    case scalar(Value)
    case table(TableValue)
}

/// The row being iterated.
enum RowFrame {
    case base(Int, Int32)
    case row(Columns, [Value])
}

enum VarValue {
    case scalar(Value)
    case table(TableValue)
    /// An unevaluated argument of an `expr`-mode function parameter, with the caller's variable scope.
    case thunk(Node, VarScope?)
}

final class VarScope {
    let name: String
    let value: VarValue
    let parent: VarScope?
    init(name: String, value: VarValue, parent: VarScope?) { self.name = name.daxKey; self.value = value; self.parent = parent }
    func lookup(_ key: String) -> VarValue? {
        var s: VarScope? = self
        while let c = s { if c.name == key { return c.value }; s = c.parent }
        return nil
    }
}

final class MeasureDef {
    let name: String
    let table: String
    let source: String
    let expr: Node
    var formatString: String
    var formatExpr: Node?
    var description: String
    init(name: String, table: String, source: String, expr: Node, formatString: String = "", formatExpr: Node? = nil, description: String = "") {
        self.name = name; self.table = table; self.source = source; self.expr = expr
        self.formatString = formatString; self.formatExpr = formatExpr; self.description = description
    }
}

final class FunctionDef {
    let name: String
    let params: [ParsedParam]
    let body: Node
    init(name: String, params: [ParsedParam], body: Node) { self.name = name; self.params = params; self.body = body }
}

final class CalcItemDef {
    let name: String
    let expr: Node
    let formatExpr: Node?
    init(name: String, expr: Node, formatExpr: Node?) { self.name = name; self.expr = expr; self.formatExpr = formatExpr }
}
final class CalcGroupDef {
    let name: String
    let column: ColumnID
    let precedence: Int
    let items: [String: CalcItemDef]
    init(name: String, column: ColumnID, precedence: Int, items: [String: CalcItemDef]) {
        self.name = name; self.column = column; self.precedence = precedence; self.items = items
    }
}

struct CalendarDef {
    let name: String
    let table: Int
    let dateColumn: ColumnID
    let yearEndMonth: Int
}

/// State for evaluating visual calculations over a visual's result grid.
final class VisualCalcContext {
    /// The grid at the current level.
    var grid: TableValue
    /// Column indices of row-axis and column-axis grouping fields present at this level.
    var rowAxis: [Int]
    var colAxis: [Int]
    /// All row-axis / column-axis field names (full depth), for COLLAPSE / EXPAND and ISATLEVEL.
    var allRowFields: [String]
    var allColFields: [String]
    /// Index of the current row in `grid`.
    var row = 0
    /// Rows aggregations operate over (nil = the current row only).
    var aggRows: [Int]?
    /// Produces the grid at another level: (number of row fields, number of column fields).
    var level: ((Int, Int) throws -> VisualCalcContext)?

    init(grid: TableValue, rowAxis: [Int], colAxis: [Int], allRowFields: [String], allColFields: [String]) {
        self.grid = grid; self.rowAxis = rowAxis; self.colAxis = colAxis
        self.allRowFields = allRowFields; self.allColFields = allColFields
    }
}

struct MeasureKey: Hashable {
    let measure: ObjectIdentifier
    let selected: ObjectIdentifier?
}

/// Evaluation context: filter context, row context, variables.
struct Ctx {
    var fc: FilterContext
    var frames: [RowFrame] = []
    var vars: VarScope?
    /// The filter context ALLSELECTED restores (the query's outer context).
    var selected: FilterContext?
    /// The measure a calculation item is being applied to.
    var selectedMeasure: MeasureDef?
    var visual: VisualCalcContext?
    var currentGroup: TableValue?
    var depth = 0

    init(fc: FilterContext) { self.fc = fc }
}
