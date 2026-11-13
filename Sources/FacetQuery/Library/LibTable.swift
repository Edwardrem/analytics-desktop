import Foundation
import FacetCore

extension MLibrary {
    static func registerTable(_ lib: MLibrary) {
        lib.enumeration("JoinKind", [("Inner", 0), ("LeftOuter", 1), ("RightOuter", 2), ("FullOuter", 3), ("LeftAnti", 4), ("RightAnti", 5),
                                      ("LeftSemi", 6), ("RightSemi", 7)])
        lib.enumeration("ExtraValues", [("List", 0), ("Error", 1), ("Ignore", 2)])
        lib.enumeration("GroupKind", [("Local", 0), ("Global", 1)])
        lib.enumeration("JoinAlgorithm", [("Dynamic", 0), ("PairwiseHash", 1), ("SortMerge", 2), ("LeftHash", 3), ("RightHash", 4), ("LeftIndex", 5), ("RightIndex", 6)])
        lib.enumeration("JoinSide", [("Left", 0), ("Right", 1)])

        // MARK: Information
        lib.fn("Table.RowCount", 1) { a, ctx in
            let t = try a.table(0)
            if t.isLazy, let counted = t.folded(.rowCount, ctx), let cell = try counted.columns.first?.first { return cell }
            return .int(try t.rowCount)
        }
        lib.fn("Table.ColumnCount", 1) { a, _ in .int(try a.table(0).columnCount) }
        lib.fn("Table.ColumnNames", 1) { a, _ in .list(try a.table(0).columnNames.map(MValue.text)) }
        lib.fn("Table.IsEmpty", 1) { a, _ in .logical(try a.table(0).rowCount == 0) }
        lib.fn("Table.Column", 2) { a, _ in .list(try a.table(0).column(try a.text(1))) }
        lib.fn("Table.HasColumns", 2) { a, _ in
            let t = try a.table(0)
            return .logical(try a.textList(1).allSatisfy { t.columnIndex($0) != nil })
        }
        lib.fn("Table.ColumnsOfType", 2) { a, _ in
            let t = try a.table(0), wanted = try a.forcedList(1).compactMap(\.typeValue)
            return .list(zip(t.columnNames, t.columnTypes).filter { wanted.contains($0.1) }.map { .text($0.0) })
        }
        lib.fn("Table.Schema", 1) { a, _ in
            let t = try a.table(0)
            return .table(MTable(names: ["Name", "Position", "TypeName", "Kind", "IsNullable"], rows: t.columnNames.enumerated().map { i, n in
                [.text(n), .int(i), .text(typeName(t.columnTypes[i])), .text(kindName(t.columnTypes[i])), .logical(t.columnTypes[i].isNullable)]
            }))
        }
        lib.fn("Table.ToRecords", 1) { a, _ in .list(try a.table(0).records().map(MValue.record)) }
        lib.fn("Table.ToRows", 1) { a, _ in .list(try a.table(0).rows.map(MValue.list)) }
        lib.fn("Table.ToColumns", 1) { a, _ in .list(try a.table(0).columns.map(MValue.list)) }
        lib.fn("Table.ToList", 1...2) { a, ctx in
            let combiner = try a.optFunction(1) ?? library(ctx, "Combiner.CombineTextByDelimiter", [.text(",")])
            return .list(try a.table(0).rows.map { try ctx.call(combiner, [.list($0)]) })
        }
        for name in ["Table.Buffer", "Table.StopFolding"] {
            lib.fn(name, 1...2) { a, _ in
                let t = try a.table(0)
                return .table(MTable(names: t.columnNames, types: t.columnTypes, columns: try t.columns, rowCount: try t.rowCount))
            }
        }
        lib.fn("Table.AddKey", 3) { a, _ in a[0] }
        lib.fn("Table.Keys", 1) { _, _ in .list([]) }

        // MARK: Row selection
        lib.fn("Table.FirstN", 2) { a, ctx in
            let t = try a.table(0)
            if case .number(let n) = a[1], n >= 0, let folded = t.folded(.firstN(Int(n)), ctx) { return .table(folded) }
            let n = try MLib.leadingCount(a[1], try t.records().map(MValue.record), ctx)
            return .table(try t.selecting(rows: Array(0..<n)))
        }
        lib.fn("Table.LastN", 2) { a, ctx in
            let t = try a.table(0), total = try t.rowCount
            let n = try MLib.trailingCount(a[1], try t.records().map(MValue.record), ctx)
            return .table(try t.selecting(rows: Array((total - n)..<total)))
        }
        for name in ["Table.Skip", "Table.RemoveFirstN"] {
            lib.fn(name, 1...2) { a, ctx in
                let t = try a.table(0)
                if case .number(let n) = a[1], n >= 0, let folded = t.folded(.skip(Int(n)), ctx) { return .table(folded) }
                let n = try MLib.leadingCount(a[1], try t.records().map(MValue.record), ctx)
                return .table(try t.selecting(rows: Array(n..<(try t.rowCount))))
            }
        }
        lib.fn("Table.RemoveLastN", 1...2) { a, ctx in
            let t = try a.table(0)
            let n = try MLib.trailingCount(a[1], try t.records().map(MValue.record), ctx)
            return .table(try t.selecting(rows: Array(0..<(try t.rowCount - n))))
        }
        lib.fn("Table.Range", 2...3) { a, _ in
            let t = try a.table(0), total = try t.rowCount, offset = min(try MLib.index(a, 1), total)
            let n = min(try a.optInt(2).map { max(0, $0) } ?? total, total - offset)
            return .table(try t.selecting(rows: Array(offset..<(offset + n))))
        }
        lib.fn("Table.RemoveRows", 2...3) { a, _ in
            let t = try a.table(0), total = try t.rowCount, offset = try MLib.index(a, 1), n = try a.optInt(2) ?? 1
            guard n >= 0, offset + n <= total else { throw MError("Table.RemoveRows: the rows to remove are outside the table.") }
            return .table(try t.selecting(rows: Array(0..<offset) + Array((offset + n)..<total)))
        }
        lib.fn("Table.AlternateRows", 4) { a, _ in
            let t = try a.table(0), total = try t.rowCount
            let offset = try MLib.index(a, 1), skip = try MLib.index(a, 2), take = try MLib.index(a, 3)
            var keep = Array(0..<min(offset, total)), i = offset
            guard skip + take > 0 else { return a[0] }
            while i < total {
                i += skip
                keep.append(contentsOf: i..<max(i, min(i + take, total)))
                i += take
            }
            return .table(try t.selecting(rows: keep))
        }
        lib.fn("Table.ReverseRows", 1) { a, _ in
            let t = try a.table(0)
            return .table(try t.selecting(rows: (0..<(try t.rowCount)).reversed()))
        }
        lib.fn("Table.Repeat", 2) { a, _ in
            let t = try a.table(0), n = try t.rowCount
            return .table(try t.selecting(rows: (0..<(try MLib.index(a, 1))).flatMap { _ in 0..<n }))
        }
        lib.fn("Table.First", 1...2) { a, _ in
            let t = try a.table(0)
            return try t.rowCount > 0 ? .record(try t.record(0)) : a[1]
        }
        lib.fn("Table.Last", 1...2) { a, _ in
            let t = try a.table(0), n = try t.rowCount
            return n > 0 ? .record(try t.record(n - 1)) : a[1]
        }
        lib.fn("Table.FirstValue", 1...2) { a, _ in
            let t = try a.table(0)
            guard try t.rowCount > 0, let cell = try t.columns.first?.first else { return a[1] }
            return try cell.forced()
        }
        lib.fn("Table.SingleRow", 1) { a, _ in
            let t = try a.table(0)
            guard try t.rowCount == 1 else { throw MError("Table.SingleRow: the table doesn't have exactly one row.") }
            return .record(try t.record(0))
        }
        lib.fn("Table.SelectRows", 2) { a, ctx in
            let t = try a.table(0), f = try a.function(1)
            if let folded = t.folded(.selectRows(f), ctx) { return .table(folded) }
            var keep: [Int] = []
            for (i, r) in try t.records().enumerated() where try MLib.test(f, .record(r), ctx) { keep.append(i) }
            return .table(try t.selecting(rows: keep))
        }
        func errorRows(_ name: String, keepErrors: Bool) {
            lib.fn(name, 1...2) { a, _ in
                let t = try a.table(0), cols = try t.columns
                let check = try a.has(1) ? t.requiredIndices(try a.textList(1)) : Array(0..<t.columnCount)
                let keep = (0..<(try t.rowCount)).filter { r in check.contains { cols[$0][r].forcedCell().isError } == keepErrors }
                return .table(try t.selecting(rows: keep))
            }
        }
        errorRows("Table.SelectRowsWithErrors", keepErrors: true)
        errorRows("Table.RemoveRowsWithErrors", keepErrors: false)
        lib.fn("Table.Distinct", 1...2) { a, ctx in
            let t = try a.table(0)
            if a[1].isNull, t.isLazy, let folded = t.folded(.distinct, ctx) { return .table(folded) }
            let key = try rowKeyer(t, a[1], ctx)
            var seen = Set<MKey>()
            return .table(try t.selecting(rows: try (0..<(try t.rowCount)).filter { seen.insert(try key($0)).inserted }))
        }
        lib.fn("Table.IsDistinct", 1...2) { a, ctx in
            let t = try a.table(0), key = try rowKeyer(t, a[1], ctx), n = try t.rowCount
            return .logical(Set(try (0..<n).map(key)).count == n)
        }
        lib.fn("Table.Sort", 2) { a, ctx in
            let t = try a.table(0)
            if let keys = MLib.sortColumns(a[1]), keys.allSatisfy({ t.columnIndex($0.column) != nil }),
               let folded = t.folded(.sort(keys), ctx) { return .table(folded) }
            let cmp = try MCriteria.comparer(a[1], ctx), recs = try t.records()
            let order = try Array(0..<recs.count).stableSorted { try cmp(.record(recs[$0]), .record(recs[$1])) }
            return .table(try t.selecting(rows: order))
        }
        func extremeRows(_ name: String, descending: Bool, many: Bool) {
            lib.fn(name, many ? 3...3 : 2...3) { a, ctx in
                let t = try a.table(0), cmp = try MCriteria.comparer(a[1], ctx), recs = try t.records()
                let order = try Array(0..<recs.count).stableSorted {
                    descending ? try cmp(.record(recs[$1]), .record(recs[$0])) : try cmp(.record(recs[$0]), .record(recs[$1]))
                }
                if !many { return order.first.map { .record(recs[$0]) } ?? a[2] }
                let n = try MLib.leadingCount(a[2], order.map { .record(recs[$0]) }, ctx)
                return .table(try t.selecting(rows: Array(order.prefix(n))))
            }
        }
        extremeRows("Table.Max", descending: true, many: false)
        extremeRows("Table.Min", descending: false, many: false)
        extremeRows("Table.MaxN", descending: true, many: true)
        extremeRows("Table.MinN", descending: false, many: true)
        lib.fn("Table.Contains", 2...3) { a, ctx in
            let t = try a.table(0), wanted = try a.record(1)
            let idx = try t.requiredIndices(wanted.names), cols = try t.columns, values = try wanted.forcedValues()
            _ = ctx
            return .logical((0..<(try t.rowCount)).contains { r in
                zip(idx, values).allSatisfy { MValue.equals(cols[$0][r].forcedCell(), $1) }
            })
        }
        lib.fn("Table.MatchesAllRows", 2) { a, ctx in
            let f = try a.function(1)
            return .logical(try a.table(0).records().allSatisfy { try MLib.test(f, .record($0), ctx) })
        }
        lib.fn("Table.MatchesAnyRows", 2) { a, ctx in
            let f = try a.function(1)
            return .logical(try a.table(0).records().contains { try MLib.test(f, .record($0), ctx) })
        }
        lib.fn("Table.FindText", 2) { a, _ in
            let t = try a.table(0), needle = try a.text(1), cols = try t.columns
            return .table(try t.selecting(rows: (0..<(try t.rowCount)).filter { r in
                cols.contains { $0[r].forcedCell().textValue?.contains(needle) ?? false }
            }))
        }
        lib.fn("Table.InsertRows", 3) { a, _ in
            let t = try a.table(0), offset = try MLib.index(a, 1)
            var rows = try t.rows
            guard offset <= rows.count else { throw MError("Table.InsertRows: the offset is outside the table.") }
            let new = try a.forcedList(2).map { v -> [MValue] in
                guard case .record(let r) = v else { throw MError.typeMismatch(expected: "record", got: v) }
                return try t.columnNames.map { try r.require($0) }
            }
            rows.insert(contentsOf: new, at: offset)
            return .table(t.with(rows: rows))
        }

        registerTableColumns(lib)
        registerTableConstruction(lib)
        registerTableShape(lib)
        registerTableStructured(lib)
        registerTableJoins(lib)
    }

    /// Call a library function by name (used to build default splitters/combiners).
    static func library(_ ctx: MInterpreter, _ name: String, _ args: [MValue]) throws -> MFunction {
        guard case .function(let f)? = ctx.library.values[name], case .function(let made) = try ctx.call(f, args) else {
            throw MError("The library function '\(name)' is not available.")
        }
        return made
    }

    /// Row → key for distinct/duplicate tests: all columns, named columns, or general equation criteria over the row record.
    static func rowKeyer(_ t: MTable, _ criteria: MValue, _ ctx: MInterpreter) throws -> (Int) throws -> MKey {
        let cols = try t.columns
        var names: [String]?
        switch criteria {
        case .null: names = t.columnNames
        case .text(let s): names = [s]
        case .list(let l):
            let texts = l.compactMap { $0.forcedCell().textValue }
            if texts.count == l.count { names = texts }
        default: break
        }
        if let names {
            let idx = try t.requiredIndices(names)
            return { MLib.rowKey(cols, idx, $0) }
        }
        let key = try MCriteria.keyer(criteria, ctx), fields = t.fieldNames
        return { r in try key(.record(MRecord(fields: fields, values: cols.map { $0[r] }))) }
    }
}
