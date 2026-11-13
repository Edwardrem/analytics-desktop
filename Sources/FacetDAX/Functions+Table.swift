import Foundation
import FacetCore

extension DAXEngine {
    /// Stable sort of row indices by per-row key lists.
    static func sortedIndices(_ keys: [[Value]], descending: [Bool]) -> [Int] {
        keys.indices.sorted { x, y in
            for k in 0..<descending.count {
                let c = DAXOps.sortCompare(keys[x][k], keys[y][k])
                if c != 0 { return descending[k] ? c > 0 : c < 0 }
            }
            return x < y
        }
    }

    /// Selects rows of a table by position, preserving base storage when possible.
    func pick(_ t: TableValue, _ idx: [Int]) -> TableValue {
        if let b = t.base { return TableValue(table: b.table, rows: idx.map { b.rows[$0] }, db: db) }
        return TableValue(cols: t.cols, rows: idx.map { t.data[$0] })
    }

    /// Parses trailing (orderBy, [order]) argument pairs starting at `start`.
    func orderPairs(_ a: [Node], from start: Int, _ ctx: Ctx, defaultDescending: Bool) throws -> [(Node, Bool)] {
        var out: [(Node, Bool)] = []
        var i = start
        while i < a.count {
            if a[i].isMissing { i += 1; continue }
            out.append((a[i], (try orderDescending(a, i + 1, ctx)) ?? defaultDescending))
            i += 2
        }
        return out
    }

    func orderKeys(_ t: TableValue, _ order: [(Node, Bool)], _ ctx: Ctx) throws -> [[Value]] {
        var keys: [[Value]] = []
        keys.reserveCapacity(t.count)
        try forEachRow(t, ctx) { rc, _ in keys.append(try order.map { try scalar($0.0, rc) }) }
        return keys
    }

    static let tableFns: [String: Fn] = {        var d: [String: Fn] = [:]
        d["ADDCOLUMNS"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            let pairs = try e.namedPairs(a.dropFirst(), "ADDCOLUMNS")
            let src = t.rows(e.db)
            var out: [[Value]] = []
            out.reserveCapacity(src.count)
            try e.forEachRow(t, c) { rc, i in out.append(src[i] + (try pairs.map { try e.scalar($0.1, rc) })) }
            return .table(TableValue(cols: Columns(t.cols.infos + pairs.map { ColInfo(name: $0.0) }), rows: out))
        }
        d["SELECTCOLUMNS"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            var specs: [(ColInfo, Node)] = []
            var i = 1
            while i < a.count {
                var name: String?
                var exprNode = a[i]
                if let s = a[i].stringConst, i + 1 < a.count { name = s; exprNode = a[i + 1]; i += 2 } else { i += 1 }
                let (dn, dc) = e.deref(exprNode, c)
                var info = ColInfo(name: name ?? "Column\(specs.count + 1)")
                if case .column(let tn, let cn, _) = dn.kind {
                    var probe = dc
                    probe.frames.append(t.base.map { .base($0.table, 0) } ?? .row(t.cols, []))
                    if let cid = try? e.modelColumn(dn, probe) {
                        let src = e.colInfo(cid)
                        info = ColInfo(name: name ?? src.name, table: name == nil || name?.daxKey == src.name.daxKey ? src.table : nil,
                                       lineage: cid, type: src.type)
                    } else if name == nil {
                        info = ColInfo(name: cn, table: tn)
                    }
                }
                specs.append((info, exprNode))
            }
            var out: [[Value]] = []
            out.reserveCapacity(t.count)
            try e.forEachRow(t, c) { rc, _ in out.append(try specs.map { try e.scalar($0.1, rc) }) }
            return .table(TableValue(cols: Columns(specs.map { $0.0 }), rows: out))
        }
        d["ROW"] = { e, a, c, _ in
            let pairs = try e.namedPairs(a[...], "ROW")
            return .table(TableValue(cols: Columns(pairs.map { ColInfo(name: $0.0) }), rows: [try pairs.map { try e.scalar($0.1, c) }]))
        }
        d["DATATABLE"] = { e, a, c, n in
            guard let last = a.last, case .tableCtor(let rows) = last.kind, a.count % 2 == 1 else {
                throw DAXError("DATATABLE expects name/type pairs followed by the rows in braces: DATATABLE(\"Name\", STRING, {{\"A\"}, {\"B\"}}).")
            }
            var infos: [ColInfo] = []
            for pair in 0..<((a.count - 1) / 2) {
                let i = pair * 2
                guard let name = a[i].stringConst else { throw DAXError("DATATABLE: column names must be text in double quotes.", range: a[i].range) }
                let type: DataType
                switch try e.keywordArg(a, i + 1, c) ?? "" {
                case "INTEGER": type = .integer
                case "DOUBLE": type = .decimal
                case "STRING": type = .text
                case "BOOLEAN": type = .boolean
                case "CURRENCY": type = .currency
                case "DATETIME": type = .dateTime
                case let other: throw DAXError("DATATABLE: unknown data type '\(other)'. Use INTEGER, DOUBLE, STRING, BOOLEAN, CURRENCY or DATETIME.")
                }
                infos.append(ColInfo(name: name, type: type))
            }
            var out: [[Value]] = []
            for r in rows {
                var cells: [Node] = r
                if r.count == 1, case .tableCtor(let inner) = r[0].kind { cells = inner.flatMap { $0 } }
                guard cells.count == infos.count else {
                    throw DAXError("DATATABLE: each row must have \(infos.count) value(s).", range: n.range)
                }
                out.append(try cells.enumerated().map { try e.scalar($1, c).converted(to: infos[$0].type) })
            }
            return .table(TableValue(cols: Columns(infos), rows: out))
        }
        d["UNION"] = { e, a, c, _ in
            let tables = try a.map { try e.table($0, c) }
            let width = tables[0].cols.count
            var out: [[Value]] = []
            for t in tables {
                guard t.cols.count == width else { throw DAXError("UNION: every table must have the same number of columns.") }
                out.append(contentsOf: t.rows(e.db))
            }
            return .table(TableValue(cols: tables[0].cols, rows: out))
        }
        for (name, keepIfPresent) in [("INTERSECT", true), ("EXCEPT", false)] {
            d[name] = { e, a, c, _ in
                let l = try e.table(a[0], c), r = try e.table(a[1], c)
                guard l.cols.count == r.cols.count else { throw DAXError("\(name): both tables must have the same number of columns.") }
                let right = Set(r.rows(e.db).map { $0.map(DAXEngine.normKey) })
                let rows = l.rows(e.db)
                let idx = rows.indices.filter { right.contains(rows[$0].map(DAXEngine.normKey)) == keepIfPresent }
                return .table(e.pick(l, idx))
            }
        }
        d["CROSSJOIN"] = { e, a, c, _ in
            var cols: [ColInfo] = []
            var rows: [[Value]] = [[]]
            for node in a {
                let t = try e.table(node, c)
                cols += t.cols.infos
                let tr = t.rows(e.db)
                guard rows.count * max(tr.count, 1) <= 5_000_000 else { throw DAXError("CROSSJOIN would produce more than 5 million rows.") }
                var next: [[Value]] = []
                next.reserveCapacity(rows.count * tr.count)
                for x in rows { for y in tr { next.append(x + y) } }
                rows = next
            }
            return .table(TableValue(cols: Columns(cols), rows: rows))
        }
        for (name, outer) in [("NATURALINNERJOIN", false), ("NATURALLEFTOUTERJOIN", true)] {
            d[name] = { e, a, c, _ in
                let l = try e.table(a[0], c), r = try e.table(a[1], c)
                var lk: [Int] = [], rk: [Int] = []
                if let lb = l.base, let rb = r.base {
                    let rel: Rel? = e.db.rels.first { rel in
                        guard c.fc.rel.active[rel.idx] else { return false }
                        let forward = rel.oneT == lb.table && rel.manyT == rb.table
                        let backward = rel.oneT == rb.table && rel.manyT == lb.table
                        return forward || backward
                    }
                    if let rel {
                        lk = [rel.oneT == lb.table ? rel.oneC : rel.manyC]
                        rk = [rel.oneT == rb.table ? rel.oneC : rel.manyC]
                    }
                }
                if lk.isEmpty {
                    for (i, li) in l.cols.infos.enumerated() {
                        if let j = r.cols.infos.firstIndex(where: { ri in
                            if let a = li.lineage, let b = ri.lineage { return a == b }
                            return li.lineage == nil && ri.lineage == nil && li.name.daxKey == ri.name.daxKey
                        }) { lk.append(i); rk.append(j) }
                    }
                }
                guard !lk.isEmpty else { throw DAXError("\(name): the tables have no common columns to join on.") }
                let keepRight = r.cols.infos.indices.filter { j in l.base != nil && r.base != nil ? true : !rk.contains(j) }
                var index: [[Value]: [Int]] = [:]
                let rr = r.rows(e.db)
                for (j, row) in rr.enumerated() { index[rk.map { DAXEngine.normKey(row[$0]) }, default: []].append(j) }
                var out: [[Value]] = []
                for row in l.rows(e.db) {
                    if let matches = index[lk.map { DAXEngine.normKey(row[$0]) }] {
                        for j in matches { out.append(row + keepRight.map { rr[j][$0] }) }
                    } else if outer {
                        out.append(row + [Value](repeating: .null, count: keepRight.count))
                    }
                }
                return .table(TableValue(cols: Columns(l.cols.infos + keepRight.map { r.cols.infos[$0] }), rows: out))
            }
        }
        for (name, all) in [("GENERATE", false), ("GENERATEALL", true)] {
            d[name] = { e, a, c, _ in
                let l = try e.table(a[0], c)
                let lr = l.rows(e.db)
                var rightCols: Columns?
                var out: [[Value]] = []
                var pendingEmpty: [Int] = []
                try e.forEachRow(l, c) { rc, i in
                    let r = try e.table(a[1], rc)
                    if rightCols == nil { rightCols = r.cols }
                    let rr = r.rows(e.db)
                    if rr.isEmpty { if all { pendingEmpty.append(out.count); out.append(lr[i]) } }
                    else { for y in rr { out.append(lr[i] + y) } }
                }
                let rc = rightCols?.infos ?? []
                for k in pendingEmpty { out[k] += [Value](repeating: .null, count: rc.count) }
                return .table(TableValue(cols: Columns(l.cols.infos + rc), rows: out))
            }
        }
        d["GENERATESERIES"] = { e, a, c, _ in
            let s = try e.scalar(a[0], c), en = try e.scalar(a[1], c)
            let stepV = try e.arg(a, 2).map { try e.scalar($0, c) } ?? .int(1)
            let step = try DAXOps.number(stepV)
            guard step > 0 else { throw DAXError("GENERATESERIES: the increment must be greater than zero.") }
            let start = try DAXOps.number(s), end = try DAXOps.number(en)
            let isDate = DAXOps.isDate(s)
            let isInt = DAXOps.isIntLike(s) && DAXOps.isIntLike(en) && DAXOps.isIntLike(stepV)
            guard (end - start) / step <= 10_000_000 else { throw DAXError("GENERATESERIES would produce more than 10 million rows.") }
            var rows: [[Value]] = []
            var k = 0.0
            while start + k * step <= end + abs(step) * 1e-9 {
                let x = start + k * step
                rows.append([isDate ? .date(Value.date(fromSerial: x)) : (isInt ? .int(Int64(x.rounded())) : .double((x * 1e10).rounded() / 1e10))])
                k += 1
            }
            return .table(TableValue(cols: Columns([ColInfo(name: "Value", type: isDate ? .dateTime : (isInt ? .integer : .decimal))]), rows: rows))
        }
        d["TOPN"] = { e, a, c, _ in
            let nValue = try DAXOps.number(e.scalar(a[0], c))
            let t = try e.table(a[1], c)
            let n = max(0, Int(nValue))
            let order = try e.orderPairs(a, from: 2, c, defaultDescending: true)
            if order.isEmpty { return .table(e.pick(t, Array(0..<min(n, t.count)))) }
            let keys = try e.orderKeys(t, order, c)
            let idx = DAXEngine.sortedIndices(keys, descending: order.map { $0.1 })
            guard n > 0 else { return .table(e.pick(t, [])) }
            var take = min(n, idx.count)
            // Include ties with the last selected row.
            while take < idx.count, take > 0, keys[idx[take]] == keys[idx[take - 1]] { take += 1 }
            return .table(e.pick(t, Array(idx.prefix(take))))
        }
        d["SAMPLE"] = { e, a, c, _ in
            let n = max(0, Int(try DAXOps.number(e.scalar(a[0], c))))
            let t = try e.table(a[1], c)
            let order = try e.orderPairs(a, from: 2, c, defaultDescending: false)
            let idx = order.isEmpty ? Array(0..<t.count) : DAXEngine.sortedIndices(try e.orderKeys(t, order, c), descending: order.map { $0.1 })
            guard n < idx.count else { return .table(e.pick(t, idx)) }
            guard n > 0 else { return .table(e.pick(t, [])) }
            if n == 1 { return .table(e.pick(t, [idx[0]])) }
            var picks: [Int] = []
            picks.reserveCapacity(n)
            for i in 0..<n {
                let position = Double(i) * Double(idx.count - 1) / Double(n - 1)
                picks.append(idx[Int(position.rounded())])
            }
            return .table(e.pick(t, picks))
        }
        d["CALENDAR"] = { e, a, c, _ in
            guard let s = try e.scalar(a[0], c).asDate, let en = try e.scalar(a[1], c).asDate else {
                throw DAXError("CALENDAR needs a start date and an end date.")
            }
            guard s <= en else { throw DAXError("CALENDAR: the start date cannot be after the end date.") }
            return .table(DAXEngine.calendarTable(from: s, to: en))
        }
        d["CALENDARAUTO"] = { e, a, c, _ in
            let fyEnd = try e.arg(a, 0).map { Int(try DAXOps.number(e.scalar($0, c))) } ?? 12
            guard (1...12).contains(fyEnd) else { throw DAXError("CALENDARAUTO: the fiscal year end month must be between 1 and 12.") }
            var lo: Date?, hi: Date?
            for t in e.db.tables where t.model?.expression == nil && !e.autoDateTables.contains(t.index) {
                for col in t.columns where col.type.isTemporal && col.model?.expression == nil {
                    for v in col.values {
                        if case .date(let dt) = v { lo = lo.map { min($0, dt) } ?? dt; hi = hi.map { max($0, dt) } ?? dt }
                    }
                }
            }
            guard let lo = lo, let hi = hi else { throw DAXError("CALENDARAUTO: the model has no date columns to derive a calendar from.") }
            let cal = Calendar.utc
            func fiscalStart(_ dt: Date) -> Date {
                let y = cal.component(.year, from: dt), m = cal.component(.month, from: dt)
                let startMonth = fyEnd % 12 + 1
                let year = m >= startMonth ? y : y - 1
                return cal.date(from: DateComponents(year: year, month: startMonth, day: 1)) ?? dt
            }
            let start = fiscalStart(lo)
            let endStart = fiscalStart(hi)
            let end = cal.date(byAdding: DateComponents(year: 1, day: -1), to: endStart) ?? hi
            return .table(DAXEngine.calendarTable(from: start, to: end))
        }
        d["ADDMISSINGITEMS"] = { e, a, c, _ in
            var showAll: [ColumnID] = []
            var i = 0
            while i < a.count, !e.isTableNode(a[i], c), let cid = try? e.modelColumn(a[i], c) { showAll.append(cid); i += 1 }
            guard i < a.count else { throw DAXError("ADDMISSINGITEMS expects the show-all columns followed by a table.") }
            let t = try e.table(a[i], c).materialized(e.db)
            let filterArgs = a[(i + 1)...].filter { e.isTableNode($0, c) }
            let inner = try e.calculateContext(filterArgs[...], c)
            let positions = showAll.compactMap { t.cols.byLineage[$0] }
            guard positions.count == showAll.count, !showAll.isEmpty else { return .table(t) }
            var combos: [[Value]] = [[]]
            var byTable: [(Int, [Int])] = []
            for (k, cid) in showAll.enumerated() {
                if let j = byTable.firstIndex(where: { $0.0 == cid.table }) { byTable[j].1.append(k) } else { byTable.append((cid.table, [k])) }
            }
            var order: [Int] = []
            for (_, ks) in byTable {
                let part = try e.distinctColumns(ks.map { showAll[$0] }, inner.fc, blankRow: false).data
                var next: [[Value]] = []
                for x in combos { for y in part { next.append(x + y) } }
                combos = next
                order += ks
            }
            let existing = Set(t.data.map { row in positions.map { row[$0] } })
            var rows = t.data
            for combo in combos {
                var key = [Value](repeating: .null, count: showAll.count)
                for (pos, k) in order.enumerated() { key[k] = combo[pos] }
                if existing.contains(key) { continue }
                var row = [Value](repeating: .null, count: t.cols.count)
                for (k, p) in positions.enumerated() { row[p] = key[k] }
                rows.append(row)
            }
            return .table(TableValue(cols: t.cols, rows: rows))
        }
        d["TABLEOF"] = { e, a, c, _ in
            let cid = try e.columnArg(a[0], c, "TABLEOF")
            try e.checkTableAccess(cid.table, a[0])
            return .table(e.visibleTable(cid.table, c))
        }
        d["NAMEOF"] = { e, a, c, _ in
            let (n, ac) = e.deref(a[0], c)
            if let cid = try e.modelColumn(n, ac) { return .scalar(.string(e.db.name(cid))) }
            if case .column(_, let name, _) = n.kind, let m = e.lookupMeasure(name.daxKey) { return .scalar(.string("[\(m.name)]")) }
            if case .ident(let name) = n.kind, let ti = e.db.tableIndex[name.daxKey] { return .scalar(.string("'\(e.db.tables[ti].name)'")) }
            throw DAXError("NAMEOF expects a column, measure or table reference.")
        }
        d["CURRENTGROUP"] = { _, _, c, _ in
            guard let g = c.currentGroup else { throw DAXError("CURRENTGROUP can only be used inside GROUPBY.") }
            return .table(g)
        }
        d["DETAILROWS"] = { e, a, c, _ in
            guard case .column(_, let name, _) = a[0].kind, let m = e.lookupMeasure(name.daxKey), let ti = e.db.tableIndex[m.table.daxKey] else {
                throw DAXError("DETAILROWS expects a measure reference.")
            }
            return .table(e.visibleTable(ti, c))
        }
        d["TOCSV"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            let maxRows = try e.arg(a, 1).map { Int(try DAXOps.number(e.scalar($0, c))) } ?? 10
            let delim = try e.arg(a, 2).map { try e.scalar($0, c).asString } ?? ","
            let headers = try e.arg(a, 3).map { try DAXOps.truthy(e.scalar($0, c)) } ?? true
            func q(_ s: String) -> String {
                s.contains(delim) || s.contains("\"") || s.contains("\n") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
            }
            var lines: [String] = []
            if headers { lines.append(t.cols.infos.map { info in q(info.table.map { tableName in "'\(tableName)'[\(info.name)]" } ?? "[\(info.name)]") }.joined(separator: delim)) }
            for row in t.rows(e.db).prefix(maxRows < 0 ? Int.max : maxRows) { lines.append(row.map { q($0.asString) }.joined(separator: delim)) }
            return .scalar(.string(lines.joined(separator: "\n")))
        }
        d["TOJSON"] = { e, a, c, _ in
            let t = try e.table(a[0], c)
            let maxRows = try e.arg(a, 1).map { Int(try DAXOps.number(e.scalar($0, c))) } ?? 10
            func js(_ v: Value) -> String {
                switch v {
                case .null: return "null"
                case .bool(let b): return b ? "true" : "false"
                case .int(let i): return String(i)
                case .double(let x): return x.isFinite ? String(x) : "null"
                default:
                    let data = (try? JSONEncoder().encode(v.asString)) ?? Data("\"\"".utf8)
                    return String(decoding: data, as: UTF8.self)
                }
            }
            let header = t.cols.infos.map { info in js(.string(info.table.map { tableName in "'\(tableName)'[\(info.name)]" } ?? "[\(info.name)]")) }.joined(separator: ",")
            let body = t.rows(e.db).prefix(maxRows < 0 ? Int.max : maxRows).map { "[" + $0.map(js).joined(separator: ",") + "]" }.joined(separator: ",")
            return .scalar(.string("{\"header\":[\(header)],\"rowCount\":\(t.count),\"data\":[\(body)]}"))
        }
        return d
    }()

    static func calendarTable(from s: Date, to en: Date) -> TableValue {
        let cal = Calendar.utc
        var cur = cal.startOfDay(for: s)
        let last = cal.startOfDay(for: en)
        var rows: [[Value]] = []
        while cur <= last {
            rows.append([.date(cur)])
            cur = cur.addingTimeInterval(86400)
        }
        return TableValue(cols: Columns([ColInfo(name: "Date", type: .date)]), rows: rows)
    }
}
