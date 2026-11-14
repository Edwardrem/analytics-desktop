import Foundation
import FacetCore

extension DAXEngine {
    // MARK: Logical functions (lazy — their arguments evaluate on demand)

    static let logicalFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        d["IF"] = { e, a, c, _ in
            let cond = try DAXOps.truthy(e.scalar(a[0], c))
            if cond { return try e.eval(a[1], c) }
            if let alt = e.arg(a, 2) { return try e.eval(alt, c) }
            return .scalar(.null)
        }
        d["IF.EAGER"] = d["IF"]
        d["SWITCH"] = { e, a, c, _ in
            let value = try e.scalar(a[0], c)
            var i = 1
            while i + 1 < a.count {
                let candidate = try e.scalar(a[i], c)
                if DAXOps.equals(value, candidate) { return try e.eval(a[i + 1], c) }
                i += 2
            }
            // A lone final argument is the else branch.
            if i < a.count, i + 1 >= a.count { return try e.eval(a[i], c) }
            return .scalar(.null)
        }
        d["COALESCE"] = { e, a, c, _ in
            for arg in a {
                let v = try e.scalar(arg, c)
                if !v.isNull { return .scalar(v) }
            }
            return .scalar(.null)
        }
        d["IFERROR"] = { e, a, c, _ in
            do { return try e.eval(a[0], c) } catch { return try e.eval(a[1], c) }
        }
        d["ISERROR"] = { e, a, c, _ in
            do { _ = try e.eval(a[0], c); return .scalar(.bool(false)) } catch { return .scalar(.bool(true)) }
        }
        d["ERROR"] = { e, a, c, _ in
            throw DAXError("An error occurred: \(try e.scalar(a[0], c).asString)", range: nil)
        }
        return d
    }()

    // MARK: Information and model metadata

    static let infoFns: [String: Fn] = {
        var d: [String: Fn] = [:]
        d["ISEMPTY"] = { e, a, c, _ in .scalar(.bool(try e.table(a[0], c).isEmpty)) }
        d["CONTAINS"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            var pairs: [(Int, Value)] = []
            var i = 1
            while i + 1 < a.count {
                let cid = try e.columnArg(a[i], c, "CONTAINS")
                let name = e.db.tables[cid.table].columns[cid.col].name
                guard let col = t.cols.infos.firstIndex(where: {
                    $0.lineage == cid || ($0.name.caseInsensitiveCompare(name) == .orderedSame)
                }) else {
                    throw DAXError("CONTAINS: the column is not in the table.")
                }
                pairs.append((col, try e.scalar(a[i + 1], c)))
                i += 2
            }
            guard !pairs.isEmpty else { throw DAXError("CONTAINS needs at least one column and value.") }
            for row in t.rows(e.db) {
                if pairs.allSatisfy({ DAXOps.strictEquals(row[$0.0], $0.1) }) { return .scalar(.bool(true)) }
            }
            return .scalar(.bool(false))
        }
        d["CONTAINSROW"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            let values = try a.dropFirst().map { try e.scalar($0, c) }
            guard values.count == t.cols.count else {
                throw DAXError("CONTAINSROW: the number of values must match the number of table columns.")
            }
            for row in t.rows(e.db) where zip(row, values).allSatisfy({ DAXOps.strictEquals($0, $1) }) {
                return .scalar(.bool(true))
            }
            return .scalar(.bool(false))
        }
        d["TEXTSEARCH"] = { e, a, c, _ in
            let cid = try e.columnArg(a[0], c, "TEXTSEARCH")
            let query = try e.scalar(a[1], c).asString
            let words = ColumnStore.words(query)
            guard let row = e.rowOfColumnArg(a[0], c) else { return .scalar(.bool(false)) }
            let value = e.cell(cid, row)
            let text = value.asString.lowercased()
            return .scalar(.bool(words.allSatisfy { text.contains($0) }))
        }
        for (name, key) in [("USERNAME", \DAXEngine.userName), ("USERPRINCIPALNAME", \DAXEngine.userPrincipalName),
                            ("USERCULTURE", \DAXEngine.userCulture), ("USEROBJECTID", \DAXEngine.userObjectID),
                            ("CUSTOMDATA", \DAXEngine.customData)] {
            d[name] = { e, _, _, _ in .scalar(.string(e[keyPath: key])) }
        }
        d["SELECTEDMEASURE"] = { e, _, c, _ in
            guard let m = c.selectedMeasure else { throw DAXError("SELECTEDMEASURE can only be used inside a calculation item.") }
            return .scalar(try e.evalMeasure(m, c))
        }
        d["SELECTEDMEASURENAME"] = { _, _, c, _ in
            guard let m = c.selectedMeasure else { throw DAXError("SELECTEDMEASURENAME can only be used inside a calculation item.") }
            return .scalar(.string(m.name))
        }
        d["SELECTEDMEASUREFORMATSTRING"] = { e, _, c, _ in
            guard let m = c.selectedMeasure else { throw DAXError("SELECTEDMEASUREFORMATSTRING can only be used inside a calculation item.") }
            return .scalar(.string(e.formatString(for: m, c)))
        }
        d["ISSELECTEDMEASURE"] = { e, a, c, _ in
            guard let m = c.selectedMeasure else { throw DAXError("ISSELECTEDMEASURE can only be used inside a calculation item.") }
            for arg in a {
                if case .column(let table, let name, _) = (e.deref(arg, c)).0.kind {
                    if name.caseInsensitiveCompare(m.name) == .orderedSame { return .scalar(.bool(true)) }
                    _ = table
                }
            }
            return .scalar(.bool(false))
        }
        d["COLUMNSTATISTICS"] = { e, _, _, _ in
            var rows: [[Value]] = []
            for t in e.db.tables {
                for (i, c) in t.columns.enumerated() where !t.variationColumns.contains(i) {
                    let dict = c.dict
                    let minMax = c.values.filter { !$0.isNull }.min(by: { $0 < $1 })
                    let max = c.values.filter { !$0.isNull }.max(by: { $0 < $1 })
                    let longest = c.values.compactMap { v -> String? in if case .string(let s) = v { return s }; return nil }.max(by: { $0.count < $1.count })
                    rows.append([.string(t.name), .string(c.name), minMax ?? .null, max ?? .null,
                                 .int(Int64(dict.count)), .int(Int64(longest?.count ?? 0))])
                }
            }
            return .table(TableValue(cols: Columns([ColInfo(name: "Table"), ColInfo(name: "Column"), ColInfo(name: "Min"),
                                                    ColInfo(name: "Max"), ColInfo(name: "Cardinality"), ColInfo(name: "MaxLength")]), rows: rows))
        }

        // PATH functions over parent-child hierarchies.
        d["PATH"] = { e, a, c, _ in
            let idCid = try e.columnArg(a[0], c, "PATH")
            let parentCid = try e.columnArg(a[1], c, "PATH")
            guard let row = e.rowOfColumnArg(a[0], c) else { return .scalar(.null) }
            var path: [Value] = []
            var current = row
            var hops = 0
            while current >= 0, hops < 64 {
                path.append(e.cell(idCid, current))
                let parent = e.cell(parentCid, current)
                guard let next = e.rowOf(parentCid, parent) else { break }
                current = next
                hops += 1
            }
            return .scalar(.string(path.reversed().map(\.asString).joined(separator: "|")))
        }
        d["PATHLENGTH"] = { e, a, c, _ in
            let path = try e.scalar(a[0], c).asString
            guard !path.isEmpty, !path.contains("\u{0}") else { return .scalar(.null) }
            return .scalar(.int(Int64(path.split(separator: "|", omittingEmptySubsequences: false).count)))
        }
        d["PATHITEM"] = { e, a, c, _ in
            return .scalar(try pathItem(e, a, c, fromLeaf: false))
        }
        d["PATHITEMREVERSE"] = { e, a, c, _ in
            return .scalar(try pathItem(e, a, c, fromLeaf: true))
        }
        d["PATHCONTAINS"] = { e, a, c, _ in
            let path = try e.scalar(a[0], c).asString
            let item = try e.scalar(a[1], c).asString
            return .scalar(.bool(path.split(separator: "|", omittingEmptySubsequences: false).contains { $0.caseInsensitiveCompare(item) == .orderedSame }))
        }

        // INFO functions: model metadata as queryable tables.
        for name in ["INFO.TABLES", "INFO.COLUMNS", "INFO.MEASURES", "INFO.RELATIONSHIPS", "INFO.FUNCTIONS",
                     "INFO.CALCULATIONGROUPS", "INFO.CALCULATIONITEMS", "INFO.ROLES",
                     "INFO.VIEW.TABLES", "INFO.VIEW.COLUMNS", "INFO.VIEW.MEASURES", "INFO.VIEW.RELATIONSHIPS"] {
            d[name] = { e, _, _, _ in .table(e.infoTable(name)) }
        }
        return d
    }()

    // MARK: Table functions missing from the core set

    // MARK: Helpers

    /// The row of the innermost iterated model table that a column argument refers to.
    func rowOfColumnArg(_ node: Node, _ ctx: Ctx) -> Int32? {
        for f in ctx.frames.reversed() {
            if case .base(_, let r) = f { return r }
            if case .row = f { return nil }
        }
        return nil
    }

    /// The row of a table holding a value, or nil.
    func rowOf(_ cid: ColumnID, _ v: Value) -> Int32? {
        let col = db.column(cid)
        if let code = col.code(of: v), let first = col.postings[Int(code)].first { return first }
        return nil
    }

    private static func pathItem(_ e: DAXEngine, _ a: [Node], _ c: Ctx, fromLeaf: Bool) throws -> Value {
        let path = try e.scalar(a[0], c).asString
        let position = try PureArgs.i(try a.dropFirst().map { try e.scalar($0, c) }, 0)
        let parts = path.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard position >= 1, position <= parts.count else { return .null }
        let text = fromLeaf ? parts[parts.count - position] : parts[position - 1]
        // An optional type argument: 0 = text, 1 = integer.
        if let typeArg = e.arg(a.dropFirst().map { $0 }, 1) {
            if try DAXOps.number(e.scalar(typeArg, c)) >= 1 { return .int(Int64(text) ?? 0) }
        }
        return .string(text)
    }

    /// NATURALINNERJOIN / NATURALLEFTOUTERJOIN on common column names.
    private func naturalJoin(_ a: [Node], _ c: Ctx, inner: Bool) throws -> DAXResult {
        let left = try table(a[0], c).materialized(db), right = try table(a[1], c).materialized(db)
        var common: [(Int, Int)] = []
        for (i, l) in left.cols.infos.enumerated() {
            if let j = right.cols.infos.firstIndex(where: { $0.name.caseInsensitiveCompare(l.name) == .orderedSame }) { common.append((i, j)) }
        }
        guard !common.isEmpty else { throw DAXError("The two tables have no columns in common.") }
        var index: [[Value]: [[Value]]] = [:]
        for r in right.data {
            index[key(common.map { r[$0.1] }), default: []].append(r)
        }
        let rightOnly = right.cols.infos.indices.filter { j in !common.contains { $0.1 == j } }
        var out: [[Value]] = []
        for l in left.data {
            let matches = index[key(common.map { l[$0.0] })] ?? []
            if matches.isEmpty && inner { continue }
            for r in matches { out.append(l + rightOnly.map { r[$0] }) }
        }
        let infos = left.cols.infos + rightOnly.map { right.cols.infos[$0] }
        return .table(TableValue(cols: Columns(infos), rows: out))
    }

    private func key(_ values: [Value]) -> [Value] { values.map(DAXEngine.normKey) }

    /// GENERATE / GENERATEALL: evaluates the second table per row of the first.
    private func generate(_ a: [Node], _ c: Ctx, keepEmpty: Bool) throws -> DAXResult {
        let outer = try table(a[0], c).materialized(db)
        var out: [[Value]] = []
        var infos: [ColInfo] = outer.cols.infos
        for outerRow in outer.data {
            var c2 = c
            c2.frames.append(.row(outer.cols, outerRow))
            let inner = try table(a[1], c2).materialized(db)
            if infos.count == outer.cols.count, !inner.cols.infos.isEmpty {
                infos = outer.cols.infos + inner.cols.infos
            }
            if inner.isEmpty {
                if keepEmpty { out.append(outerRow) }
            } else {
                for r in inner.data { out.append(outerRow + r) }
            }
        }
        return .table(TableValue(cols: Columns(infos), rows: out))
    }

    /// Model metadata as a table, for the INFO functions.
    func infoTable(_ name: String) -> TableValue {
        func table(_ infos: [ColInfo], _ rows: [[Value]]) -> TableValue { TableValue(cols: Columns(infos), rows: rows) }
        let friendly = name.hasPrefix("INFO.VIEW")
        switch name {
        case "INFO.TABLES", "INFO.VIEW.TABLES":
            var rows: [[Value]] = []
            for t in db.tables {
                guard let m = t.model else { continue }
                rows.append([.string(t.name), .string(m.description), .bool(m.isHidden), .string(m.storageMode.rawValue)])
            }
            if friendly {
                return table([ColInfo(name: "Name"), ColInfo(name: "Description"), ColInfo(name: "Is Hidden"), ColInfo(name: "Storage Mode")], rows)
            }
            return table([ColInfo(name: "Name"), ColInfo(name: "Description"), ColInfo(name: "IsHidden"), ColInfo(name: "Mode")], rows)
        case "INFO.COLUMNS", "INFO.VIEW.COLUMNS":
            var rows: [[Value]] = []
            for t in db.tables {
                for (i, c) in t.columns.enumerated() where !t.variationColumns.contains(i) {
                    let hidden = t.model?.columns[safe: i]?.isHidden ?? false
                    rows.append([.string(t.name), .string(c.name), .string(c.type.rawValue), .bool(hidden)])
                }
            }
            if friendly {
                return table([ColInfo(name: "Table"), ColInfo(name: "Name"), ColInfo(name: "Data Type"), ColInfo(name: "Is Hidden")], rows)
            }
            return table([ColInfo(name: "Table"), ColInfo(name: "Name"), ColInfo(name: "DataType"), ColInfo(name: "IsHidden")], rows)
        case "INFO.MEASURES", "INFO.VIEW.MEASURES":
            var rows: [[Value]] = []
            for tt in model.tables {
                for m in tt.measures {
                    rows.append([.string(tt.name), .string(m.name), .string(m.expression), .string(m.formatString), .bool(m.isHidden)])
                }
            }
            if friendly {
                return table([ColInfo(name: "Table"), ColInfo(name: "Name"), ColInfo(name: "Expression"), ColInfo(name: "Format String"), ColInfo(name: "Is Hidden")], rows)
            }
            return table([ColInfo(name: "Table"), ColInfo(name: "Name"), ColInfo(name: "Expression"), ColInfo(name: "FormatString"), ColInfo(name: "IsHidden")], rows)
        case "INFO.RELATIONSHIPS", "INFO.VIEW.RELATIONSHIPS":
            var rows: [[Value]] = []
            for r in db.rels {
                let from = "\(db.tables[r.manyT].name)[\(db.tables[r.manyT].columns[r.manyC].name)]"
                let to = "\(db.tables[r.oneT].name)[\(db.tables[r.oneT].columns[r.oneC].name)]"
                rows.append([.string(from), .string(to), .bool(r.def.isActive), .string(r.def.crossFilter.rawValue)])
            }
            return table([ColInfo(name: "From"), ColInfo(name: "To"), ColInfo(name: "Active"), ColInfo(name: "CrossFilter")], rows)
        case "INFO.FUNCTIONS":
            var rows: [[Value]] = []
            for f in DAXCatalog.functions {
                rows.append([.string(f.name), .string(f.category.rawValue), .string(f.signature), .string(f.description)])
            }
            for f in functionDefs.values { rows.append([.string(f.name), .string("other"), .string(""), .string("")]) }
            return table([ColInfo(name: "Name"), ColInfo(name: "Category"), ColInfo(name: "Signature"), ColInfo(name: "Description")], rows)
        case "INFO.CALCULATIONGROUPS":
            let rows = calcGroups.map { [Value.string($0.name), Value.int(Int64($0.precedence)), Value.string(db.name($0.column))] }
            return table([ColInfo(name: "Name"), ColInfo(name: "Precedence"), ColInfo(name: "Column")], rows)
        case "INFO.CALCULATIONITEMS":
            var rows: [[Value]] = []
            for g in calcGroups {
                for item in g.items.values {
                    rows.append([.string(g.name), .string(item.name), .string(""), .int(0)])
                }
            }
            return table([ColInfo(name: "Group"), ColInfo(name: "Name"), ColInfo(name: "Expression"), ColInfo(name: "Ordinal")], rows)
        case "INFO.ROLES":
            let rows = roleNames.sorted().map { [Value.string($0), Value.string("read")] }
            return table([ColInfo(name: "Name"), ColInfo(name: "ModelPermission")], rows)
        default:
            return TableValue(cols: Columns([ColInfo(name: "Value")]), rows: [])
        }
    }
}
