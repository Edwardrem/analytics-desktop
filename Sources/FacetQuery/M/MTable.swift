import Foundation
import FacetCore

/// An operation a table source may be able to push down ("fold") to the data source.
public enum MFoldOperation {
    /// `Table.SelectRows` with a row predicate.
    case selectRows(MFunction)
    /// `Table.SelectColumns` / `RemoveColumns` — the surviving columns, in order.
    case selectColumns([String])
    /// `Table.FirstN` with a count.
    case firstN(Int)
    /// `Table.Skip` with a count.
    case skip(Int)
    /// `Table.Sort` — (column, descending) keys.
    case sort([(column: String, descending: Bool)])
    /// `Table.RowCount` — folds to `SELECT COUNT(*)`; `load` then returns a 1×1 table.
    case rowCount
    /// `Table.Distinct` over all columns.
    case distinct
    /// `Table.Group` (global, case-sensitive keys): key columns and `{name, each …, type}` aggregations.
    case group(keys: [String], aggregations: [MGroupAggregation])
    /// `Table.Join` with key columns and a `JoinKind` value.
    case join(right: MTable, leftKeys: [String], rightKeys: [String], kind: Int)
    /// `Table.NestedJoin`: the right rows matching each left row, as a new table column.
    case nestedJoin(right: MTable, leftKeys: [String], rightKeys: [String], newColumn: String, kind: Int)
    /// `Table.ExpandTableColumn` with explicit column names.
    case expandTableColumn(column: String, names: [String], newNames: [String])
}

/// One aggregation of `Table.Group`.
public struct MGroupAggregation {
    public var name: String
    public var function: MFunction
    public var type: MType?
    public init(name: String, function: MFunction, type: MType?) { self.name = name; self.function = function; self.type = type }
}

/// A lazily loaded table backing store (SQL sources). Schema is known up front; rows load on demand.
/// Sources that can fold operations return a new source from `folding(_:)`; returning nil makes the
/// engine load the rows and run the operation locally (folding stops at that step).
public protocol MTableSource: AnyObject {
    var columnNames: [String] { get }
    var columnTypes: [MType] { get }
    /// Load rows column-major. `limit` caps the number of rows fetched (previews).
    func load(limit: Int?) throws -> [[MValue]]
    func folding(_ operation: MFoldOperation, _ ctx: MInterpreter) -> MTableSource?
    /// The native (SQL) query this source would run, if any — shown by "View native query".
    var nativeQuery: String? { get }
    /// Human-readable source description, e.g. "SQLite: /path/db.sqlite".
    var sourceDescription: String { get }
}

/// An M table: named, typed columns stored column-major. Cells may be `.error` (cell-level errors).
/// A table may be backed by a lazy `MTableSource`, in which case rows are loaded on first access.
public final class MTable: @unchecked Sendable {
    public let columnNames: [String]
    public let columnTypes: [MType]
    public let source: MTableSource?
    public var meta: MRecord?
    private var storage: [[MValue]]?
    private var storedRowCount: Int
    private let lock = NSLock()
    /// Shared header used by row records.
    public private(set) lazy var fieldNames = MFieldNames(columnNames)

    /// In-memory table from column-major data. All columns must have the same length.
    public init(names: [String], types: [MType]? = nil, columns: [[MValue]], rowCount: Int? = nil) {
        self.columnNames = names
        self.columnTypes = MTable.normalise(types, count: names.count)
        self.storage = columns
        self.storedRowCount = rowCount ?? columns.first?.count ?? 0
        self.source = nil
    }
    /// In-memory table from row-major data. Short rows are padded with null.
    public convenience init(names: [String], types: [MType]? = nil, rows: [[MValue]]) {
        var cols = [[MValue]](repeating: [], count: names.count)
        for c in cols.indices {
            cols[c].reserveCapacity(rows.count)
            for r in rows { cols[c].append(c < r.count ? r[c] : .null) }
        }
        self.init(names: names, types: types, columns: cols, rowCount: rows.count)
    }
    /// Lazy table over a source.
    public init(source: MTableSource) {
        self.columnNames = source.columnNames
        self.columnTypes = MTable.normalise(source.columnTypes, count: source.columnNames.count)
        self.source = source
        self.storage = nil
        self.storedRowCount = 0
    }
    public static let empty = MTable(names: [], columns: [])

    private static func normalise(_ types: [MType]?, count: Int) -> [MType] {
        var t = types ?? []
        if t.count < count { t.append(contentsOf: [MType](repeating: .any, count: count - t.count)) }
        return Array(t.prefix(count))
    }

    /// True when rows have not been loaded from a lazy source yet (the step is still folded).
    public var isLazy: Bool { lock.lock(); defer { lock.unlock() }; return storage == nil }
    /// True when this table is backed by a foldable source and has a native query.
    public var isFolded: Bool { source?.nativeQuery != nil }

    /// Column-major cells; loads from the source on first use.
    public var columns: [[MValue]] {
        get throws {
            lock.lock()
            if let s = storage { lock.unlock(); return s }
            lock.unlock()
            guard let src = source else { return [] }
            let loaded = try src.load(limit: nil)
            lock.lock(); defer { lock.unlock() }
            storage = loaded
            storedRowCount = loaded.first?.count ?? 0
            return loaded
        }
    }
    public var rowCount: Int {
        get throws {
            if isLazy { _ = try columns }
            return storedRowCount
        }
    }
    public var columnCount: Int { columnNames.count }
    public func columnIndex(_ name: String) -> Int? { fieldNames.index[name] }
    /// Index of a column, or M's "column not found" error.
    public func requireColumn(_ name: String) throws -> Int {
        guard let i = fieldNames.index[name] else {
            throw MError("The column '\(name)' of the table wasn't found.", detail: .text(name))
        }
        return i
    }
    /// The cells of one column.
    public func column(_ name: String) throws -> [MValue] { try columns[try requireColumn(name)] }
    public func row(_ i: Int) throws -> [MValue] { try columns.map { $0[i] } }
    /// Row-major cells.
    public var rows: [[MValue]] {
        get throws {
            let cols = try columns, n = try rowCount
            return (0..<n).map { i in cols.map { $0[i] } }
        }
    }
    /// Row `i` as a record (shares the header).
    public func record(_ i: Int) throws -> MRecord {
        MRecord(fields: fieldNames, values: try row(i))
    }
    /// All rows as records.
    public func records() throws -> [MRecord] {
        let cols = try columns, n = try rowCount, f = fieldNames
        return (0..<n).map { i in MRecord(fields: f, values: cols.map { $0[i] }) }
    }
    /// Up to `limit` rows, column-major, without caching a full load of a lazy source.
    public func columns(limit: Int?) throws -> [[MValue]] {
        guard let limit else { return try columns }
        if isLazy, let src = source { return try src.load(limit: limit) }
        return try columns.map { Array($0.prefix(limit)) }
    }
    /// A new in-memory table with the given rows (indices into this table), keeping the schema.
    public func selecting(rows idx: [Int]) throws -> MTable {
        let cols = try columns
        return MTable(names: columnNames, types: columnTypes, columns: cols.map { c in idx.map { c[$0] } }, rowCount: idx.count)
    }
    /// A copy with different column types (same data; stays lazy if lazy).
    public func withTypes(_ types: [MType]) throws -> MTable {
        MTable(names: columnNames, types: types, columns: try columns, rowCount: try rowCount)
    }
    /// The table's M type (`type table [..]`).
    public var tableType: MType {
        .table(zip(columnNames, columnTypes).map { MTypeField($0, $1) })
    }
    /// Try to push an operation down to the source. Returns nil when not foldable.
    public func folded(_ op: MFoldOperation, _ ctx: MInterpreter) -> MTable? {
        guard let src = source, let next = src.folding(op, ctx) else { return nil }
        return MTable(source: next)
    }
}

// MARK: - FacetCore bridging

public extension MValue {
    /// Wrap a FacetCore scalar. Dates become `datetime` unless `type` says otherwise.
    init(_ value: Value, type: DataType = .any) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .logical(b)
        case .int(let i): self = .number(Double(i))
        case .double(let d): self = type == .duration ? .duration(d * 86400) : .number(d)
        case .string(let s): self = .text(s)
        case .date(let d):
            switch type {
            case .date: self = .date(d)
            case .time: self = .time(d.timeIntervalSince(Calendar.utc.startOfDay(for: d)))
            case .any: self = d.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400) == 0 ? .date(d) : .datetime(d)
            default: self = .datetime(d)
            }
        }
    }

    /// Convert to a FacetCore scalar for loading into the model. Structured values become placeholder
    /// text (`[Record]`, `[List]`, `[Table]`, `[Binary]`, `[Function]`); cell errors become null.
    func toValue(type: MType = .any) -> Value {
        switch self {
        case .null, .error: return .null
        case .lazy(let t): return ((try? t.force()) ?? .null).toValue(type: type)
        case .logical(let b): return .bool(b)
        case .number(let d):
            if case .number(let k) = type.nonNullable {
                if k.isInteger, d.isFinite, abs(d) < 9.2e18 { return .int(Int64(d.rounded())) }
                return .double(d)
            }
            if d.isFinite, d == d.rounded(), abs(d) < 9.0e15 { return .int(Int64(d)) }
            return .double(d)
        case .text(let s): return .string(s)
        case .date(let d), .datetime(let d): return .date(d)
        case .datetimezone(let d, let off): return .date(d.addingTimeInterval(Double(off) * 60))
        case .time(let s): return .date(Value.date(fromSerial: s / 86400))
        case .duration(let s): return .double(s / 86400)
        case .binary: return .string("[Binary]")
        case .list: return .string("[List]")
        case .record: return .string("[Record]")
        case .table: return .string("[Table]")
        case .function: return .string("[Function]")
        case .type: return .string("[Type]")
        }
    }
}

public extension MTable {
    /// Wrap a FacetCore table.
    convenience init(_ table: DataTable) {
        self.init(names: table.columnNames, types: table.columns.map { MType(dataType: $0.type).asNullable },
                  columns: table.columns.map { c in c.values.map { MValue($0, type: c.type) } }, rowCount: table.rowCount)
    }
    /// Materialise as a FacetCore table. Column types come from the M column types; untyped (`any`)
    /// columns are inferred from their values.
    func toDataTable(name: String = "", limit: Int? = nil) throws -> DataTable {
        let cols = try columns(limit: limit)
        var out: [DataColumn] = []
        out.reserveCapacity(columnNames.count)
        for (i, n) in columnNames.enumerated() {
            let t = columnTypes[i]
            let dt = t.dataType
            let values = (i < cols.count ? cols[i] : []).map { $0.toValue(type: t) }
            var c = DataColumn(name: n, type: dt, values: values)
            if dt == .any { c.type = DataTable.inferType(values) }
            out.append(c)
        }
        return DataTable(name: name, columns: out)
    }
}
