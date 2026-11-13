import Foundation
import FacetCore

/// Converts Power BI `executeQueries` responses into FacetCore `DataTable`s.
public enum DAXResultParser {
    /// Parses an `executeQueries` response body (`results[0].tables[0].rows`).
    ///
    /// - Column order follows the key order of the row objects.
    /// - `Table[Column]` and `[Measure]` keys are reduced to `Column` / `Measure` when `stripTablePrefixes` is true;
    ///   if two columns would collide, later ones keep their full name.
    /// - Types are inferred per column: whole numbers → integer, mixed/decimal → decimal, booleans, ISO date-times → date/dateTime, else text.
    public static func dataTable(from data: Data, name: String = "Query", stripTablePrefixes: Bool = true) throws -> DataTable {
        let json: JSONValue
        do { json = try JSONValue.parse(data) }
        catch { throw CloudAPIError(service: "Power BI", kind: .invalidResponse, statusCode: 0, message: "The query result was not valid JSON.") }
        if let err = json["error"] ?? json["results"]?[0]?["error"] {
            let details = (err["pbi.error"]?["details"]?.arrayValue ?? []).compactMap { $0["detail"]?["value"]?.stringValue }
            let message = details.isEmpty ? (err["message"]?.stringValue ?? "The query failed.") : details.joined(separator: " ")
            throw CloudAPIError(service: "Power BI", kind: .badRequest, statusCode: 0, code: err["code"]?.stringValue, message: message)
        }
        guard let rows = json["results"]?[0]?["tables"]?[0]?["rows"]?.arrayValue else {
            // A query that returns no table (e.g. only DEFINE) yields no tables array.
            if json["results"] != nil { return DataTable(name: name, columns: []) }
            throw CloudAPIError(service: "Power BI", kind: .invalidResponse, statusCode: 0, message: "The query result did not contain a table.")
        }
        return table(fromRows: rows, name: name, stripTablePrefixes: stripTablePrefixes)
    }

    static func table(fromRows rows: [JSONValue], name: String, stripTablePrefixes: Bool) -> DataTable {
        // Collect keys in first-seen order (rows normally share one shape; includeNulls keeps them complete).
        var keys: [String] = []
        var index: [String: Int] = [:]
        for row in rows {
            for m in row.members ?? [] where index[m.key] == nil {
                index[m.key] = keys.count
                keys.append(m.key)
            }
        }
        var values = [[Value]](repeating: [], count: keys.count)
        for i in values.indices { values[i].reserveCapacity(rows.count) }
        for row in rows {
            var filled = [Bool](repeating: false, count: keys.count)
            for m in row.members ?? [] {
                guard let i = index[m.key], !filled[i] else { continue }
                values[i].append(value(m.value))
                filled[i] = true
            }
            for i in keys.indices where !filled[i] { values[i].append(.null) }
        }
        var used = Set<String>()
        let names: [String] = keys.map { key in
            let short = stripTablePrefixes ? displayName(forResultKey: key) : key
            let chosen = used.contains(short.lowercased()) || short.isEmpty ? key : short
            used.insert(chosen.lowercased())
            return chosen
        }
        let columns = zip(names, values).map { n, v -> DataColumn in
            let (type, converted) = typed(v)
            return DataColumn(name: n, type: type, values: converted)
        }
        return DataTable(name: name, columns: columns)
    }

    /// `Sales[Region]` → `Region`, `[Total Sales]` → `Total Sales`, `'My Table'[Col]]umn]` → `Col]umn`.
    public static func displayName(forResultKey key: String) -> String {
        guard key.hasSuffix("]"), let open = openingBracket(in: key) else { return key }
        let inner = key[key.index(after: open)..<key.index(before: key.endIndex)]
        return inner.replacingOccurrences(of: "]]", with: "]")
    }

    /// Finds the `[` that starts the trailing bracketed name, skipping a quoted table name.
    private static func openingBracket(in key: String) -> String.Index? {
        var i = key.startIndex
        if key.hasPrefix("'") {
            // Skip 'quoted table name' ('' is an escaped quote).
            var j = key.index(after: i)
            while j < key.endIndex {
                if key[j] == "'" {
                    let n = key.index(after: j)
                    if n < key.endIndex, key[n] == "'" { j = key.index(after: n); continue }
                    i = n
                    break
                }
                j = key.index(after: j)
            }
        }
        return key[i...].firstIndex(of: "[")
    }

    private static func value(_ v: JSONValue) -> Value {
        switch v {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .int(let i): return .int(i)
        case .double(let d): return .double(d)
        case .string(let s): return .string(s)
        case .array, .object: return .string(v.serialized())
        }
    }

    /// Infers a column type and converts ISO date-time strings to dates.
    private static func typed(_ values: [Value]) -> (DataType, [Value]) {
        var sawString = false, allDates = true, allMidnight = true, sawOther = false
        for v in values {
            switch v {
            case .null: continue
            case .string(let s):
                sawString = true
                if allDates {
                    if looksLikeISODateTime(s) { if !s.dropFirst(10).hasPrefix("T00:00:00") { allMidnight = false } }
                    else { allDates = false }
                }
            default: sawOther = true
            }
        }
        if sawString, !sawOther, allDates {
            let converted = values.map { v -> Value in
                guard case .string(let s) = v, let d = HTTPHelpers.parseISODate(s) else { return .null }
                return .date(d)
            }
            return (allMidnight ? .date : .dateTime, converted)
        }
        return (DataTable.inferType(values), values)
    }

    /// `yyyy-MM-ddTHH:mm:ss` with an optional fraction/zone — checked structurally so ordinary text is never misread.
    static func looksLikeISODateTime(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count >= 19, u.count <= 35 else { return false }
        for (i, b) in u.prefix(19).enumerated() {
            switch i {
            case 4, 7: if b != UInt8(ascii: "-") { return false }
            case 10: if b != UInt8(ascii: "T") { return false }
            case 13, 16: if b != UInt8(ascii: ":") { return false }
            default: if b < 0x30 || b > 0x39 { return false }
            }
        }
        return true
    }
}

/// Builds a FacetCore `SemanticModel` (live-connection metadata) from the result tables of
/// `INFO.VIEW.TABLES()`, `INFO.VIEW.COLUMNS()`, `INFO.VIEW.MEASURES()` and `INFO.VIEW.RELATIONSHIPS()`.
public enum LiveModelBuilder {
    public static let tablesQuery = "EVALUATE INFO.VIEW.TABLES()"
    public static let columnsQuery = "EVALUATE INFO.VIEW.COLUMNS()"
    public static let measuresQuery = "EVALUATE INFO.VIEW.MEASURES()"
    public static let relationshipsQuery = "EVALUATE INFO.VIEW.RELATIONSHIPS()"

    public static func build(name: String, tables: DataTable, columns: DataTable, measures: DataTable, relationships: DataTable) -> SemanticModel {
        var model = SemanticModel()
        model.name = name
        var byName: [String: Int] = [:]

        for r in 0..<tables.rowCount {
            guard let tableName = text(tables, r, "Name"), !tableName.isEmpty else { continue }
            var t = ModelTable(name: tableName)
            t.description = text(tables, r, "Description") ?? ""
            t.isHidden = bool(tables, r, "IsHidden")
            t.storageMode = .live
            t.expression = nonEmpty(text(tables, r, "Expression"))
            byName[tableName.lowercased()] = model.tables.count
            model.tables.append(t)
        }
        func tableIndex(_ name: String) -> Int {
            if let i = byName[name.lowercased()] { return i }
            // A column/measure may reference a table missing from the tables result (e.g. hidden by permissions).
            var t = ModelTable(name: name)
            t.storageMode = .live
            byName[name.lowercased()] = model.tables.count
            model.tables.append(t)
            return model.tables.count - 1
        }

        for r in 0..<columns.rowCount {
            guard let tableName = text(columns, r, "Table"), let colName = text(columns, r, "Name"), !colName.isEmpty,
                  !colName.hasPrefix("RowNumber-") else { continue }
            let type = dataType(text(columns, r, "DataType"))
            var c = ModelColumn(name: colName, dataType: type, expression: nonEmpty(text(columns, r, "Expression")))
            c.description = text(columns, r, "Description") ?? ""
            c.formatString = text(columns, r, "FormatString") ?? ""
            c.displayFolder = text(columns, r, "DisplayFolder") ?? ""
            c.isHidden = bool(columns, r, "IsHidden")
            c.isKey = bool(columns, r, "IsKey")
            if let nullable = optionalBool(columns, r, "IsNullable") { c.isNullable = nullable }
            c.sortByColumn = nonEmpty(text(columns, r, "SortByColumn"))
            c.dataCategory = dataCategory(text(columns, r, "DataCategory"))
            if let s = aggregation(text(columns, r, "SummarizeBy")) { c.summarizeBy = s }
            model.tables[tableIndex(tableName)].columns.append(c)
        }

        for r in 0..<measures.rowCount {
            guard let tableName = text(measures, r, "Table"), let measureName = text(measures, r, "Name"), !measureName.isEmpty else { continue }
            var m = Measure(name: measureName, expression: text(measures, r, "Expression") ?? "", formatString: text(measures, r, "FormatString") ?? "")
            m.description = text(measures, r, "Description") ?? ""
            m.displayFolder = text(measures, r, "DisplayFolder") ?? ""
            m.isHidden = bool(measures, r, "IsHidden")
            m.formatExpression = nonEmpty(text(measures, r, "FormatStringDefinition"))
            model.tables[tableIndex(tableName)].measures.append(m)
        }

        for r in 0..<relationships.rowCount {
            guard let ft = text(relationships, r, "FromTable"), let fc = text(relationships, r, "FromColumn"),
                  let tt = text(relationships, r, "ToTable"), let tc = text(relationships, r, "ToColumn") else { continue }
            var rel = Relationship(fromTable: ft, fromColumn: fc, toTable: tt, toColumn: tc)
            let fromMany = (text(relationships, r, "FromCardinality") ?? "Many").lowercased() == "many"
            let toMany = (text(relationships, r, "ToCardinality") ?? "One").lowercased() == "many"
            switch (fromMany, toMany) {
            case (true, false): rel.cardinality = .manyToOne
            case (false, true): rel.cardinality = .oneToMany
            case (false, false): rel.cardinality = .oneToOne
            case (true, true): rel.cardinality = .manyToMany
            }
            rel.crossFilter = (text(relationships, r, "CrossFilteringBehavior") ?? "").lowercased().hasPrefix("both") ? .both : .single
            rel.isActive = optionalBool(relationships, r, "IsActive") ?? true
            rel.assumeReferentialIntegrity = bool(relationships, r, "RelyOnReferentialIntegrity")
            rel.securityFilterBothDirections = (text(relationships, r, "SecurityFilteringBehavior") ?? "").lowercased().hasPrefix("both")
            model.relationships.append(rel)
        }
        return model
    }

    // MARK: Lenient cell access

    private static func cell(_ t: DataTable, _ row: Int, _ column: String) -> Value? {
        guard let i = t.columnIndex(column), row < t.columns[i].values.count else { return nil }
        let v = t.columns[i].values[row]
        return v.isNull ? nil : v
    }
    private static func text(_ t: DataTable, _ row: Int, _ column: String) -> String? { cell(t, row, column)?.asString }
    private static func optionalBool(_ t: DataTable, _ row: Int, _ column: String) -> Bool? { cell(t, row, column)?.asBool }
    private static func bool(_ t: DataTable, _ row: Int, _ column: String) -> Bool { optionalBool(t, row, column) ?? false }
    private static func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }

    static func dataType(_ s: String?) -> DataType {
        switch (s ?? "").lowercased() {
        case "string", "text": return .text
        case "int64", "integer", "whole number": return .integer
        case "double", "decimal number": return .decimal
        case "decimal", "currency", "fixed decimal number": return .currency
        case "boolean", "true/false": return .boolean
        case "datetime", "date/time": return .dateTime
        case "date": return .date
        case "time": return .time
        case "binary": return .binary
        default: return .any
        }
    }

    static func aggregation(_ s: String?) -> Aggregation? {
        switch (s ?? "").lowercased() {
        case "none": return Aggregation.none
        case "sum": return .sum
        case "min": return .min
        case "max": return .max
        case "count": return .count
        case "average": return .average
        case "distinctcount": return .distinctCount
        default: return nil // "Default" or absent: keep the type-based default
        }
    }

    static func dataCategory(_ s: String?) -> DataCategory {
        switch (s ?? "").lowercased() {
        case "address": return .address
        case "city": return .city
        case "continent": return .continent
        case "country", "countryregion": return .country
        case "county": return .county
        case "stateorprovince": return .stateOrProvince
        case "postalcode": return .postalCode
        case "place": return .place
        case "latitude": return .latitude
        case "longitude": return .longitude
        case "weburl": return .webURL
        case "imageurl": return .imageURL
        case "barcode": return .barcode
        default: return .uncategorized
        }
    }
}
