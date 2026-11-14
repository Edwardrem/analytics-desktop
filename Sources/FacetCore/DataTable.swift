import Foundation

/// One column of in-memory data.
public struct DataColumn: Codable, Sendable {
    public var name: String
    public var type: DataType
    public var values: [Value]

    public init(name: String, type: DataType = .any, values: [Value] = []) {
        self.name = name; self.type = type; self.values = values
    }

    private enum CodingKeys: String, CodingKey { case name, type, values }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(DataType.self, forKey: .type)
        let raw = try c.decode([Value].self, forKey: .values)
        // JSON has one kind of number, so a whole decimal (2399.0) reads back as an integer. A
        // decimal column gets its numbers back as decimals, the kind it was saved with.
        switch type {
        case .decimal, .currency, .duration:
            values = raw.map { if case .int(let i) = $0 { return .double(Double(i)) } else { return $0 } }
        default:
            values = raw
        }
    }
}

/// A columnar in-memory table. The universal exchange format between the query
/// engine, the DAX engine, storage, and the visuals.
public struct DataTable: Codable, Sendable {
    public var name: String
    public var columns: [DataColumn]

    public init(name: String = "", columns: [DataColumn] = []) {
        self.name = name; self.columns = columns
    }

    /// Build from row-major data. Short rows are padded with nulls.
    public init(name: String = "", columnNames: [String], rows: [[Value]], types: [DataType]? = nil) {
        self.name = name
        var cols = columnNames.enumerated().map { DataColumn(name: $1, type: types?[safe: $0] ?? .any, values: []) }
        for i in cols.indices {
            cols[i].values.reserveCapacity(rows.count)
            for r in rows { cols[i].values.append(i < r.count ? r[i] : .null) }
        }
        self.columns = cols
        if types == nil { inferTypes() }
    }

    public var rowCount: Int { columns.first?.values.count ?? 0 }
    public var columnCount: Int { columns.count }
    public var columnNames: [String] { columns.map(\.name) }

    public func columnIndex(_ name: String) -> Int? {
        columns.firstIndex { $0.name == name } ?? columns.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    public func column(_ name: String) -> DataColumn? { columnIndex(name).map { columns[$0] } }
    public subscript(row: Int, col: Int) -> Value {
        get { columns[col].values[row] }
        set { columns[col].values[row] = newValue }
    }
    public func row(_ i: Int) -> [Value] { columns.map { $0.values[i] } }
    public var rows: [[Value]] { (0..<rowCount).map(row) }

    public mutating func appendRow(_ r: [Value]) {
        for i in columns.indices { columns[i].values.append(i < r.count ? r[i] : .null) }
    }
    /// A new table containing only the given row indices, in order.
    public func selecting(rows idx: [Int]) -> DataTable {
        DataTable(name: name, columns: columns.map { c in
            DataColumn(name: c.name, type: c.type, values: idx.map { c.values[$0] })
        })
    }
    public func prefix(_ n: Int) -> DataTable {
        DataTable(name: name, columns: columns.map { DataColumn(name: $0.name, type: $0.type, values: Array($0.values.prefix(n))) })
    }

    /// Set each column's type to the narrowest type that fits its non-null values.
    public mutating func inferTypes() {
        for i in columns.indices where columns[i].type == .any {
            columns[i].type = DataTable.inferType(columns[i].values)
        }
    }
    public static func inferType(_ values: [Value]) -> DataType {
        var seen = Set<DataType>()
        for v in values where !v.isNull {
            seen.insert(v.dataType)
            if seen.count > 2 { break }
        }
        if seen.isEmpty { return .text }
        if seen.count == 1 { return seen.first! }
        if seen == [.integer, .decimal] { return .decimal }
        return .text
    }

    /// Detect types for text columns (as produced by CSV parsing) and convert values in place.
    public mutating func detectAndConvertTextTypes(sample: Int = 2000) {
        for i in columns.indices {
            let col = columns[i]
            guard col.type == .text || col.type == .any else { continue }
            let strings: [String] = col.values.prefix(sample).compactMap {
                if case .string(let s) = $0 { let t = s.trimmingCharacters(in: .whitespaces); return t.isEmpty ? nil : t }
                return nil
            }
            guard !strings.isEmpty else { continue }
            let target: DataType
            if strings.allSatisfy({ Int64($0) != nil }) { target = .integer }
            else if strings.allSatisfy({ DataTable.parseNumber($0) != nil }) { target = .decimal }
            else if strings.allSatisfy({ ["true", "false"].contains($0.lowercased()) }) { target = .boolean }
            else if strings.allSatisfy({ DateParsing.parse($0) != nil }) {
                target = strings.allSatisfy({ $0.count <= 11 }) ? .date : .dateTime
            } else { continue }
            columns[i].type = target
            columns[i].values = col.values.map { v in
                guard case .string(let s) = v else { return v }
                let t = s.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { return .null }
                switch target {
                case .integer: return Int64(t).map(Value.int) ?? .null
                case .decimal: return DataTable.parseNumber(t).map(Value.double) ?? .null
                case .boolean: return .bool(t.lowercased() == "true")
                default: return DateParsing.parse(t).map(Value.date) ?? .null
                }
            }
        }
    }
    /// Parses "1,234.5", "$12", "45%", "(3.2)".
    public static func parseNumber(_ s: String) -> Double? {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return nil }
        var negative = false, percent = false
        if t.hasPrefix("("), t.hasSuffix(")") { negative = true; t = String(t.dropFirst().dropLast()) }
        if t.hasSuffix("%") { percent = true; t.removeLast() }
        if let f = t.first, "$€£¥".contains(f) { t.removeFirst() }
        t = t.replacingOccurrences(of: ",", with: "")
        guard let f = t.first, f.isNumber || f == "-" || f == "+" || f == ".", var d = Double(t) else { return nil }
        if negative { d = -d }
        if percent { d /= 100 }
        return d
    }
}

/// Holds the materialised data for every table in a document, keyed by table name.
public struct DataStore: Sendable {
    public var tables: [String: DataTable]
    public init(tables: [String: DataTable] = [:]) { self.tables = tables }
    public subscript(name: String) -> DataTable? {
        get { tables[name] }
        set { tables[name] = newValue }
    }
}

public extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
