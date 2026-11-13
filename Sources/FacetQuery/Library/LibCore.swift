import Foundation
import FacetCore

extension MLibrary {
    /// Registration functions, one per library area. Each lives in its own `Library/Lib*.swift` file.
    static let registrars: [(MLibrary) -> Void] = [
        registerCore, registerRecord,
        registerTable, registerList, registerText, registerNumber, registerDateTime,
        registerFiles, registerSQL, registerWeb, registerScripts, registerAI,
    ]

    /// Build a date from calendar components, or throw M's out-of-range error.
    public static func makeDate(_ y: Int, _ m: Int, _ d: Int) throws -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d
        guard y >= 1, y <= 9999, m >= 1, m <= 12, d >= 1, d <= 31, let date = Calendar.utc.date(from: c),
              Calendar.utc.component(.day, from: date) == d else {
            throw MError("The date \(y)-\(m)-\(d) is not valid.")
        }
        return date
    }

    static func registerCore(_ lib: MLibrary) {
        // MARK: Constructors
        lib.fn("#date", 3) { a, _ in .date(try makeDate(try a.int(0), try a.int(1), try a.int(2))) }
        lib.fn("#time", 3) { a, _ in
            let h = try a.int(0), m = try a.int(1), s = try a.number(2)
            guard (0...24).contains(h), (0..<60).contains(m), s >= 0, s < 61 else { throw MError("The time \(h):\(m):\(s) is not valid.") }
            return .time(Double(h) * 3600 + Double(m) * 60 + s)
        }
        lib.fn("#datetime", 6) { a, _ in
            let d = try makeDate(try a.int(0), try a.int(1), try a.int(2))
            return .datetime(d.addingTimeInterval(Double(try a.int(3)) * 3600 + Double(try a.int(4)) * 60 + (try a.number(5))))
        }
        lib.fn("#datetimezone", 8) { a, _ in
            let d = try makeDate(try a.int(0), try a.int(1), try a.int(2))
            let wall = d.addingTimeInterval(Double(try a.int(3)) * 3600 + Double(try a.int(4)) * 60 + (try a.number(5)))
            let off = try a.int(6) * 60 + (try a.int(7))
            return .datetimezone(wall.addingTimeInterval(-Double(off) * 60), offsetMinutes: off)
        }
        lib.fn("#duration", 4) { a, _ in
            .duration(try a.number(0) * 86400 + (try a.number(1)) * 3600 + (try a.number(2)) * 60 + (try a.number(3)))
        }
        lib.fn("#binary", 1) { a, _ in
            if case .text(let s) = a[0] {
                guard let d = Data(base64Encoded: s) else { throw MError("The text is not valid Base64.") }
                return .binary(d)
            }
            return .binary(Data(try a.forcedList(0).map { v -> UInt8 in
                guard case .number(let n) = v, n >= 0, n <= 255 else { throw MError("Binary bytes must be numbers 0-255.") }
                return UInt8(n)
            }))
        }
        lib.fn("#table", 2) { a, _ in
            var names: [String], types: [MType]?
            let rowsArg = try a.list(1)
            switch a[0] {
            case .list: names = try a.textList(0)
            case .type(let t):
                guard case .table(let f) = t else { throw MError("#table needs a table type.") }
                names = f.map(\.name); types = f.map(\.type)
            case .number(let n): names = (0..<Int(n)).map { "Column\($0 + 1)" }
            case .null:
                let width = try rowsArg.first.map { try $0.forced().listValue?.count ?? 0 } ?? 0
                names = (0..<width).map { "Column\($0 + 1)" }
            default: throw MError("#table: the first argument must be a list of column names, a table type, or a column count.")
            }
            if Set(names).count != names.count { throw MError("#table: column names must be unique.") }
            var rows: [[MValue]] = []
            rows.reserveCapacity(rowsArg.count)
            for r in rowsArg {
                guard case .list(let cells) = try r.forced() else { throw MError("#table: each row must be a list.") }
                guard cells.count == names.count else {
                    throw MError("#table: a row has \(cells.count) values but the table has \(names.count) columns.")
                }
                rows.append(cells.map { $0.forcedCell() })
            }
            return .table(MTable(names: names, types: types, rows: rows))
        }

        // MARK: Type constants
        let typeConsts: [(String, MType)] = [
            ("Int64.Type", .number(.int64)), ("Int32.Type", .number(.int32)), ("Int16.Type", .number(.int16)),
            ("Int8.Type", .number(.int8)), ("Byte.Type", .number(.byte)), ("Single.Type", .number(.single)),
            ("Double.Type", .plainNumber), ("Decimal.Type", .number(.decimal)), ("Currency.Type", .number(.currency)),
            ("Percentage.Type", .number(.percentage)), ("Number.Type", .plainNumber), ("Text.Type", .text),
            ("Character.Type", .text), ("Guid.Type", .text), ("Password.Type", .text), ("Uri.Type", .text),
            ("Logical.Type", .logical), ("Date.Type", .date), ("DateTime.Type", .datetime),
            ("DateTimeZone.Type", .datetimezone), ("Time.Type", .time), ("Duration.Type", .duration),
            ("Binary.Type", .binary), ("Any.Type", .any), ("List.Type", .anyList), ("Record.Type", .anyRecord),
            ("Table.Type", .anyTable), ("Function.Type", .function), ("Type.Type", .type), ("None.Type", .none),
            ("Null.Type", .null),
        ]
        for (n, t) in typeConsts { lib.const(n, .type(t)) }

        // MARK: Enumerations shared across areas
        lib.enumeration("Order", [("Ascending", 0), ("Descending", 1)])
        lib.enumeration("MissingField", [("Error", 0), ("Ignore", 1), ("UseNull", 2)])
        lib.enumeration("TraceLevel", [("Critical", 1), ("Error", 2), ("Warning", 4), ("Information", 8), ("Verbose", 16)])
        lib.enumeration("Occurrence", [("First", 0), ("Last", 1), ("All", 2), ("Optional", 0), ("Required", 1), ("Repeating", 2)])
        lib.enumeration("Precision", [("Double", 0), ("Decimal", 1)])
        lib.const("Culture.Current", .text("en-US")) // constant in M; the session culture is applied by conversion functions

        // MARK: Comparer
        lib.fn("Comparer.Ordinal", 2) { a, _ in .int(MValue.order(a[0], a[1])) }
        lib.fn("Comparer.OrdinalIgnoreCase", 2) { a, _ in .int(MCriteria.order(a[0], a[1], ignoreCase: true)) }
        lib.fn("Comparer.FromCulture", 1...2) { a, _ in
            let ignoreCase = try a.optLogical(1) ?? false
            return lib.values[ignoreCase ? "Comparer.OrdinalIgnoreCase" : "Comparer.Ordinal"] ?? .null
        }
        lib.fn("Comparer.Equals", 3) { a, ctx in
            let cmp = try MCriteria.comparer(a[0], ctx)
            return .logical(try cmp(a[1], a[2]) == 0)
        }

        // MARK: Value
        lib.fn("Value.Type", 1) { a, _ in .type(MType.of(a[0])) }
        lib.fn("Value.Is", 2) { a, _ in .logical(try a.type(1).matches(a[0])) }
        lib.fn("Value.As", 2) { a, _ in
            let t = try a.type(1)
            guard t.matches(a[0]) else { throw MError.typeMismatch(expected: t.mText, got: a[0]) }
            return a[0]
        }
        lib.fn("Value.ReplaceType", 2) { a, _ in
            let t = try a.type(1)
            if case .table(let tbl) = a[0], case .table(let fields) = t.nonNullable {
                guard fields.count == tbl.columnCount else { throw MError("Value.ReplaceType: the table type has a different number of columns.") }
                return .table(MTable(names: fields.map(\.name), types: fields.map(\.type), columns: try tbl.columns, rowCount: try tbl.rowCount))
            }
            return a[0]
        }
        lib.fn("Value.Metadata", 1) { a, _ in .record(MInterpreter.metadata(of: a[0])) }
        lib.fn("Value.ReplaceMetadata", 2) { a, _ in
            let stripped = MLibrary.stripMeta(a[0])
            return MInterpreter.attach(meta: try a.record(1), to: stripped)
        }
        lib.fn("Value.RemoveMetadata", 1...2) { a, _ in MLibrary.stripMeta(a[0]) }
        lib.fn("Value.Compare", 2...3) { a, _ in .int(MValue.order(a[0], a[1])) }
        lib.fn("Value.Equals", 2...3) { a, _ in .logical(MValue.equals(a[0], a[1])) }
        lib.fn("Value.NullableEquals", 2...3) { a, _ in
            (a[0].isNull || a[1].isNull) ? .null : .logical(MValue.equals(a[0], a[1]))
        }
        lib.fn("Value.Add", 2...3) { a, _ in try MOps.add(a[0], a[1]) }
        lib.fn("Value.Subtract", 2...3) { a, _ in try MOps.subtract(a[0], a[1]) }
        lib.fn("Value.Multiply", 2...3) { a, _ in try MOps.multiply(a[0], a[1]) }
        lib.fn("Value.Divide", 2...3) { a, _ in try MOps.divide(a[0], a[1]) }
        lib.fn("Value.FromText", 1...2) { a, ctx in
            guard case .text(let s) = a[0] else { return a[0] }
            let culture = try a.optText(1) ?? ctx.culture
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return .text(s) }
            if t == "null" { return .null }
            if t.lowercased() == "true" { return .logical(true) }
            if t.lowercased() == "false" { return .logical(false) }
            if let d = MConvert.parseNumber(t, culture: culture) { return .number(d) }
            if let p = MConvert.parseDateTime(t, culture: culture) {
                if let off = p.offsetMinutes { return .datetimezone(p.date.addingTimeInterval(-Double(off) * 60), offsetMinutes: off) }
                if p.hasDate && p.hasTime { return .datetime(p.date) }
                if p.hasDate { return .date(p.date) }
                return .time(p.date.timeIntervalSince(MOps.dayFloor(p.date)))
            }
            if t.contains(":"), let dur = MConvert.parseDuration(t) { return .duration(dur) }
            return .text(s)
        }
        lib.fn("Value.Firewall", 1) { a, _ in a[0] }
        lib.fn("Value.Optimize", 1) { a, _ in a[0] }
        lib.fn("Value.Alternates", 1) { a, _ in try a.forcedList(0).first ?? .null }
        lib.fn("Value.Expression", 1) { _, _ in .null }

        // MARK: Type
        lib.fn("Type.IsNullable", 1) { a, _ in .logical(try a.type(0).isNullable) }
        lib.fn("Type.NonNullable", 1) { a, _ in .type(try a.type(0).nonNullable) }
        lib.fn("Type.Is", 2) { a, _ in
            let t1 = try a.type(0), t2 = try a.type(1)
            if t2 == .any || t1 == t2 { return .logical(true) }
            if case .nullable(let inner) = t2 { return .logical(t1 == .null || t1.nonNullable == inner || MLibrary.sameKind(t1.nonNullable, inner)) }
            if t1.isNullable && t1 != .null { return .logical(false) }
            if t2 == .anynonnull { return .logical(t1 != .null) }
            return .logical(MLibrary.sameKind(t1, t2))
        }
        lib.fn("Type.ForRecord", 2) { a, _ in
            let r = try a.record(0)
            var fields: [MTypeField] = []
            for (i, n) in r.names.enumerated() {
                guard case .record(let spec) = try r.value(at: i), case .type(let t)? = try spec.get("Type") else {
                    throw MError("Type.ForRecord: each field needs [Type=…, Optional=…].")
                }
                fields.append(MTypeField(n, t, optional: try spec.logical("Optional") ?? false))
            }
            return .type(.record(fields, open: try a.logical(1)))
        }
        lib.fn("Type.RecordFields", 1) { a, _ in
            let f = try a.type(0).fields
            return .record(MRecord(names: f.map(\.name), values: f.map {
                .record(MRecord(names: ["Type", "Optional"], values: [.type($0.type), .logical($0.isOptional)]))
            }))
        }
        lib.fn("Type.ListItem", 1) { a, _ in
            guard case .list(let item) = try a.type(0).nonNullable else { throw MError("Type.ListItem needs a list type.") }
            return .type(item)
        }
        lib.fn("Type.TableRow", 1) { a, _ in .type(.record(try a.type(0).fields, open: false)) }
        lib.fn("Type.TableColumn", 2) { a, _ in
            guard let f = try a.type(0).fields.first(where: { $0.name == (try? a.text(1)) }) else {
                throw MError("Type.TableColumn: the column '\(try a.text(1))' wasn't found.")
            }
            return .type(f.type)
        }
        lib.fn("Type.TableSchema", 1) { a, _ in
            let f = try a.type(0).fields
            return .table(MTable(names: ["Name", "Position", "TypeName", "Kind", "IsNullable"], rows: f.enumerated().map { i, fld in
                [.text(fld.name), .int(i), .text(MLibrary.typeName(fld.type)), .text(MLibrary.kindName(fld.type)), .logical(fld.type.isNullable)]
            }))
        }
        lib.fn("Type.AddTableKey", 3) { a, _ in a[0] }
        lib.fn("Type.ReplaceTableKeys", 2) { a, _ in a[0] }
        lib.fn("Type.TableKeys", 1) { _, _ in .list([]) }
        lib.fn("Type.ClosedRecord", 1) { a, _ in .type(.record(try a.type(0).fields, open: false)) }
        lib.fn("Type.OpenRecord", 1) { a, _ in .type(.record(try a.type(0).fields, open: true)) }
        lib.fn("Type.IsOpenRecord", 1) { a, _ in
            if case .record(_, let open) = try a.type(0).nonNullable { return .logical(open) }
            throw MError("Type.IsOpenRecord needs a record type.")
        }
        lib.fn("Type.ForFunction", 2) { _, _ in .type(.function) }
        lib.fn("Type.FunctionParameters", 1) { _, _ in .record(.empty) }
        lib.fn("Type.FunctionRequiredParameters", 1) { _, _ in .number(0) }
        lib.fn("Type.FunctionReturn", 1) { _, _ in .type(.any) }
        lib.fn("Type.Facets", 1) { _, _ in .record(.empty) }
        lib.fn("Type.ReplaceFacets", 2) { a, _ in a[0] }
        lib.fn("Type.Union", 1) { a, _ in
            let types = try a.forcedList(0).compactMap(\.typeValue)
            guard let first = types.first else { return .type(.none) }
            return .type(types.allSatisfy { $0 == first } ? first : .any)
        }

        // MARK: Function
        lib.fn("Function.Invoke", 2) { a, ctx in try ctx.call(try a.function(0), try a.forcedList(1)) }
        lib.fn("Function.InvokeAfter", 2) { a, ctx in
            if case .duration(let s) = a[1], s > 0 { Thread.sleep(forTimeInterval: min(s, 60)) }
            return try ctx.call(try a.function(0), [])
        }
        lib.fn("Function.InvokeWithErrorContext", 2) { a, ctx in try ctx.call(try a.function(0), []) }
        lib.fn("Function.From", 2) { a, ctx in
            let f = try a.function(1)
            return .function(MFunction(name: nil, minArgs: 0, maxArgs: nil) { args, ctx in try ctx.call(f, [.list(args.values)]) })
        }
        lib.fn("Function.IsDataSource", 1) { a, _ in
            let n = try a.function(0).name ?? ""
            return .logical(MLibrary.dataSourceFunctionNames.contains(n))
        }
        lib.fn("Function.ScalarVector", 2) { a, _ in a[1] }

        // MARK: Errors, expressions, diagnostics
        lib.fn("Error.Record", 1...5) { a, _ in
            .record(MRecord(names: ["Reason", "Message", "Detail"], values: [a[0], a[1], a[2]]))
        }
        lib.fn("Expression.Evaluate", 1...2) { a, ctx in
            let env = MEnv()
            if let r = try a.optRecord(1) { for (i, n) in r.names.enumerated() { env.define(n, r.values[i]) } }
            do { return try ctx.evaluate(try a.text(0), env: env) } catch let d as MDiagnostic {
                throw MError(d.message, reason: "Expression.SyntaxError")
            }
        }
        lib.fn("Expression.Constant", 1) { a, _ in .text(MSyntax.literal(a[0])) }
        lib.fn("Expression.Identifier", 1) { a, _ in .text(MSyntax.identifier(try a.text(0))) }
        lib.fn("Diagnostics.Trace", 3...4) { a, ctx in
            ctx.addTrace(try a.text(1))
            if try a.optLogical(3) ?? false { return try ctx.call(try a.function(2), []) }
            return a[2]
        }
        lib.fn("Diagnostics.ActivityId", 0) { _, _ in .text(UUID().uuidString.lowercased()) }
        lib.fn("Diagnostics.CorrelationId", 0) { _, _ in .text(UUID().uuidString.lowercased()) }

        // MARK: Logical
        lib.fn("Logical.From", 1) { a, _ in try MConvert.toLogical(a[0]) }
        lib.fn("Logical.FromText", 1) { a, _ in try MConvert.toLogical(a[0]) }
        lib.fn("Logical.ToText", 1) { a, _ in a[0].isNull ? .null : .text(try a.logical(0) ? "true" : "false") }
    }

    static let dataSourceFunctionNames: Set<String> = [
        "File.Contents", "Folder.Files", "Folder.Contents", "Web.Contents", "Web.Page", "Web.BrowserContents", "OData.Feed",
        "Sqlite.Database", "PostgreSQL.Database", "MySQL.Database", "Sql.Database", "Sql.Databases", "Odbc.Query", "Odbc.DataSource",
        "Excel.Workbook", "Csv.Document", "Json.Document", "Xml.Tables", "Parquet.Document", "Pdf.Tables",
        "PowerBI.Dataflows", "PowerPlatform.Dataflows", "SharePoint.Tables", "SharePoint.Files", "SharePoint.Contents",
        "CommonDataService.Database", "AzureStorage.Blobs", "AzureStorage.DataLake", "AnalysisServices.Database",
    ]

    static func stripMeta(_ v: MValue) -> MValue {
        switch v {
        case .record(let r): return .record(MRecord(fields: r.fields, values: r.values))
        case .table(let t):
            guard t.meta != nil, let cols = try? t.columns, let n = try? t.rowCount else { return v }
            return .table(MTable(names: t.columnNames, types: t.columnTypes, columns: cols, rowCount: n))
        default: return v
        }
    }
    static func sameKind(_ a: MType, _ b: MType) -> Bool {
        switch (a, b) {
        case (.number, .number), (.list, .list), (.record, .record), (.table, .table): return true
        default: return a == b
        }
    }
    /// .NET-ish type name as `Table.Schema` reports it ("Int64.Type", "Text.Type", …).
    public static func typeName(_ t: MType) -> String {
        switch t.nonNullable {
        case .number(let k): return k.libraryName ?? "Number.Type"
        case .text: return "Text.Type"
        case .logical: return "Logical.Type"
        case .date: return "Date.Type"
        case .datetime: return "DateTime.Type"
        case .datetimezone: return "DateTimeZone.Type"
        case .time: return "Time.Type"
        case .duration: return "Duration.Type"
        case .binary: return "Binary.Type"
        case .list: return "List.Type"
        case .record: return "Record.Type"
        case .table: return "Table.Type"
        case .function: return "Function.Type"
        case .type: return "Type.Type"
        case .null: return "Null.Type"
        case .none: return "None.Type"
        default: return "Any.Type"
        }
    }
    /// Primitive kind name ("number", "text", "any", …).
    public static func kindName(_ t: MType) -> String {
        switch t.nonNullable {
        case .number: return "number"
        case .list: return "list"
        case .record: return "record"
        case .table: return "table"
        case .anynonnull: return "any"
        default: return t.nonNullable.mText
        }
    }
}

public extension MSyntax {
    /// M source for a value: literals for primitives, `#date(…)` etc. for temporal values, `{…}` / `[…]` / `#table(…)`
    /// for structured values. Functions and types that cannot be written back render as `null`.
    static func literal(_ v: MValue) -> String {
        switch v {
        case .null, .error, .function: return "null"
        case .lazy(let t): return literal((try? t.force()) ?? .null)
        case .logical(let b): return b ? "true" : "false"
        case .number(let d): return number(d)
        case .text(let s): return text(s)
        case .date(let d):
            let c = Calendar.utc.dateComponents([.year, .month, .day], from: d)
            return "#date(\(c.year ?? 1), \(c.month ?? 1), \(c.day ?? 1))"
        case .datetime(let d):
            let c = Calendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
            let frac = d.timeIntervalSince1970 - d.timeIntervalSince1970.rounded(.down)
            return "#datetime(\(c.year ?? 1), \(c.month ?? 1), \(c.day ?? 1), \(c.hour ?? 0), \(c.minute ?? 0), \(number(Double(c.second ?? 0) + (frac * 1e6).rounded() / 1e6)))"
        case .datetimezone(let d, let off):
            let local = d.addingTimeInterval(Double(off) * 60)
            let c = Calendar.utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local)
            let sign = off < 0 ? -1 : 1
            return "#datetimezone(\(c.year ?? 1), \(c.month ?? 1), \(c.day ?? 1), \(c.hour ?? 0), \(c.minute ?? 0), \(c.second ?? 0), \(sign * (abs(off) / 60)), \(sign * (abs(off) % 60)))"
        case .time(let t):
            let h = Int(t / 3600), m = Int(t / 60) % 60
            return "#time(\(h), \(m), \(number(t - Double(h * 3600 + m * 60))))"
        case .duration(let s):
            let neg = s < 0 ? -1.0 : 1.0
            var r = abs(s)
            let d = (r / 86400).rounded(.down); r -= d * 86400
            let h = (r / 3600).rounded(.down); r -= h * 3600
            let m = (r / 60).rounded(.down); r -= m * 60
            return "#duration(\(number(neg * d)), \(number(neg * h)), \(number(neg * m)), \(number(neg * r)))"
        case .binary(let d): return "Binary.FromText(\(text(d.base64EncodedString())), BinaryEncoding.Base64)"
        case .list(let l): return "{" + l.map { literal($0.forcedCell()) }.joined(separator: ", ") + "}"
        case .record(let r):
            return "[" + zip(r.names, r.cells).map { fieldName($0) + " = " + literal($1) }.joined(separator: ", ") + "]"
        case .table(let t):
            let rows = (try? t.rows) ?? []
            let typed = t.columnTypes.contains { $0 != .any }
            let header = typed ? t.tableType.mExpression : textList(t.columnNames)
            return "#table(" + header + ", {" + rows.map { "{" + $0.map { literal($0.forcedCell()) }.joined(separator: ", ") + "}" }.joined(separator: ", ") + "})"
        case .type(let t): return t.mExpression
        }
    }
    /// A record-literal field name (`name` or `#"quoted name"`).
    static func fieldName(_ name: String) -> String {
        let f = field(name)
        return String(f.dropFirst().dropLast())
    }
}
