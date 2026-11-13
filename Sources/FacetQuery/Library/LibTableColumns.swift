import Foundation
import FacetCore

extension MLibrary {
    static func registerTableColumns(_ lib: MLibrary) {
        func project(_ t: MTable, _ idx: [Int?]) throws -> MTable {
            let cols = try t.columns, n = try t.rowCount
            return try MTable.make(idx.enumerated().map { k, i in i.map { t.columnNames[$0] } ?? "Column\(k + 1)" },
                                   idx.map { $0.map { t.columnTypes[$0] } ?? .any },
                                   idx.map { $0.map { cols[$0] } ?? [MValue](repeating: .null, count: n) }, rows: n)
        }
        lib.fn("Table.SelectColumns", 2...3) { a, ctx in
            let t = try a.table(0), names = try a.textList(1), missing = try a.optInt(2) ?? 0
            if names.allSatisfy({ t.columnIndex($0) != nil }), let folded = t.folded(.selectColumns(names), ctx) { return .table(folded) }
            let idx = try t.indices(of: names, missing: missing)
            if missing == 2 {
                let cols = try t.columns, n = try t.rowCount
                return .table(try MTable.make(names, idx.map { $0.map { t.columnTypes[$0] } ?? .any },
                                              idx.map { $0.map { cols[$0] } ?? [MValue](repeating: .null, count: n) }, rows: n))
            }
            return .table(try project(t, idx))
        }
        lib.fn("Table.RemoveColumns", 2...3) { a, ctx in
            let t = try a.table(0), names = try a.textList(1)
            if (try a.optInt(2) ?? 0) == 0 { _ = try t.requiredIndices(names) }
            let keep = t.columnNames.filter { !names.contains($0) }
            if let folded = t.folded(.selectColumns(keep), ctx) { return .table(folded) }
            return .table(try project(t, try t.indices(of: keep)))
        }
        lib.fn("Table.ReorderColumns", 2...3) { a, _ in
            let t = try a.table(0), missing = try a.optInt(2) ?? 0
            let wanted = try t.indices(of: try a.textList(1), missing: missing == 2 ? 1 : missing).compactMap { $0 }
            // The listed columns swap among the positions they occupy; other columns stay where they are.
            var order = Array(0..<t.columnCount)
            for (slot, column) in zip(wanted.sorted(), wanted) { order[slot] = column }
            return .table(try project(t, order))
        }
        lib.fn("Table.RenameColumns", 2...3) { a, _ in
            let t = try a.table(0), missing = try a.optInt(2) ?? 0
            var names = t.columnNames
            for pair in try MLib.specList(a[1]) {
                guard pair.count == 2, case .text(let old) = pair[0], case .text(let new) = pair[1] else {
                    throw MError("Table.RenameColumns: each rename must be {old name, new name}.")
                }
                if let i = t.columnIndex(old) { names[i] = new } else if missing == 0 { _ = try t.requireColumn(old) }
            }
            return .table(try MTable.make(names, t.columnTypes, try t.columns, rows: try t.rowCount))
        }
        lib.fn("Table.TransformColumnNames", 2...3) { a, ctx in
            let t = try a.table(0), f = try a.function(1)
            let names = try t.columnNames.map { n -> String in
                guard case .text(let s) = try ctx.call(f, [.text(n)]) else { throw MError("Table.TransformColumnNames: the function must return text.") }
                return s
            }
            return .table(try MTable.make(names, t.columnTypes, try t.columns, rows: try t.rowCount))
        }
        lib.fn("Table.PrefixColumns", 2) { a, _ in
            let t = try a.table(0), prefix = try a.text(1)
            return .table(try MTable.make(t.columnNames.map { "\(prefix).\($0)" }, t.columnTypes, try t.columns, rows: try t.rowCount))
        }
        lib.fn("Table.DuplicateColumn", 3...4) { a, _ in
            let t = try a.table(0), i = try t.requireColumn(try a.text(1)), cols = try t.columns
            return .table(try MTable.make(t.columnNames + [try a.text(2)], t.columnTypes + [a.has(3) ? try a.type(3) : t.columnTypes[i]],
                                          cols + [cols[i]], rows: try t.rowCount))
        }
        lib.fn("Table.AddColumn", 3...4) { a, ctx in
            let t = try a.table(0), f = try a.function(2)
            let cells = try t.records().map { r in MValue.capturing { try ctx.call(f, [.record(r)]) } }
            return .table(try MTable.make(t.columnNames + [try a.text(1)], t.columnTypes + [a.has(3) ? try a.type(3) : .any],
                                          try t.columns + [cells], rows: cells.count))
        }
        lib.fn("Table.AddIndexColumn", 2...5) { a, _ in
            let t = try a.table(0), n = try t.rowCount, start = try a.optNumber(2) ?? 0, step = try a.optNumber(3) ?? 1
            return .table(try MTable.make(t.columnNames + [try a.text(1)], t.columnTypes + [a.has(4) ? try a.type(4) : .plainNumber],
                                          try t.columns + [(0..<n).map { .number(start + Double($0) * step) }], rows: n))
        }
        lib.fn("Table.TransformRows", 2) { a, ctx in
            let f = try a.function(1)
            return .list(try a.table(0).records().map { r in MValue.capturing { try ctx.call(f, [.record(r)]) } })
        }
        lib.fn("Table.TransformColumns", 2...4) { a, ctx in
            var t = try a.table(0)
            let missing = try a.optInt(3) ?? 0
            var touched = Set<Int>()
            for spec in try MLib.specList(a[1]) {
                guard spec.count >= 2, case .text(let name) = spec[0], case .function(let f) = spec[1] else {
                    throw MError("Table.TransformColumns: each transformation must be {column name, function} or {column name, function, type}.")
                }
                guard let i = t.columnIndex(name) else {
                    if missing == 0 { _ = try t.requireColumn(name) }
                    continue
                }
                touched.insert(i)
                t = try t.mappingColumn(i, type: spec.count > 2 ? spec[2].typeValue : .any) { try ctx.call(f, [$0]) }
            }
            if let f = try a.optFunction(2) {
                for i in 0..<t.columnCount where !touched.contains(i) { t = try t.mappingColumn(i, type: .any) { try ctx.call(f, [$0]) } }
            }
            return .table(t)
        }
        lib.fn("Table.TransformColumnTypes", 2...3) { a, ctx in
            var t = try a.table(0)
            let culture = try a.optText(2) ?? ctx.culture
            for spec in try MLib.specList(a[1]) {
                guard spec.count == 2, case .text(let name) = spec[0], case .type(let type) = spec[1] else {
                    throw MError("Table.TransformColumnTypes: each change must be {column name, type}.")
                }
                let i = try t.requireColumn(name), target = type.nonNullable
                t = try t.mappingColumn(i, type: type) { v in
                    // Blank text converts to null for every non-text type, as it does when a CSV column is typed.
                    if case .text(let s) = v, target != .text, target != .any, target != .anynonnull,
                       s.trimmingCharacters(in: .whitespaces).isEmpty { return .null }
                    return try MConvert.convert(v, to: type, culture: culture)
                }
            }
            return .table(t)
        }
        lib.fn("Table.ReplaceValue", 5) { a, ctx in
            var t = try a.table(0)
            let replacer = try a.function(3)
            for i in try t.requiredIndices(try a.textList(4)) {
                t = try t.mappingColumn(i) { try ctx.call(replacer, [$0, a[1], a[2]]) }
            }
            return .table(t)
        }
        lib.fn("Table.ReplaceErrorValues", 2) { a, _ in
            let t = try a.table(0)
            var cols = try t.columns
            for spec in try MLib.specList(a[1]) {
                guard spec.count == 2, case .text(let name) = spec[0] else { throw MError("Table.ReplaceErrorValues: each replacement must be {column name, value}.") }
                let i = try t.requireColumn(name)
                cols[i] = cols[i].map { $0.forcedCell().isError ? spec[1] : $0 }
            }
            return .table(MTable(names: t.columnNames, types: t.columnTypes, columns: cols, rowCount: try t.rowCount))
        }
        func fill(_ name: String, up: Bool) {
            lib.fn(name, 2) { a, _ in
                let t = try a.table(0), n = try t.rowCount
                var cols = try t.columns
                for i in try t.requiredIndices(try a.textList(1)) {
                    var last: MValue = .null
                    for r in up ? Array((0..<n).reversed()) : Array(0..<n) {
                        let cell = cols[i][r].forcedCell()
                        if cell.isNull { cols[i][r] = last } else { last = cell }
                    }
                }
                return .table(MTable(names: t.columnNames, types: t.columnTypes, columns: cols, rowCount: n))
            }
        }
        fill("Table.FillDown", up: false)
        fill("Table.FillUp", up: true)
        lib.fn("Table.CombineColumns", 4) { a, ctx in
            let t = try a.table(0), sources = try a.textList(1), combiner = try a.function(2), new = try a.text(3)
            let idx = try t.requiredIndices(sources), cols = try t.columns, n = try t.rowCount
            let merged = (0..<n).map { r in MValue.capturing { try ctx.call(combiner, [.list(idx.map { cols[$0][r] })]) } }
            // The new column takes the place of the leftmost source column.
            let at = idx.min() ?? 0
            var names: [String] = [], types: [MType] = [], out: [[MValue]] = []
            for i in 0..<t.columnCount {
                if i == at { names.append(new); types.append(.text); out.append(merged) }
                if !idx.contains(i) { names.append(t.columnNames[i]); types.append(t.columnTypes[i]); out.append(cols[i]) }
            }
            return .table(try MTable.make(names, types, out, rows: n))
        }
        lib.fn("Table.SplitColumn", 3...6) { a, ctx in
            let t = try a.table(0), i = try t.requireColumn(try a.text(1)), splitter = try a.function(2)
            let cols = try t.columns, n = try t.rowCount
            let parts = try cols[i].map { cell -> [MValue] in
                guard case .list(let l) = try ctx.call(splitter, [try cell.forced()]) else { throw MError("Table.SplitColumn: the splitter must return a list.") }
                return l
            }
            let newNames: [String]
            switch a[3] {
            case .null: newNames = (0..<(parts.map(\.count).max() ?? 1)).map { "\(t.columnNames[i]).\($0 + 1)" }
            case .number(let k): newNames = (0..<Int(k)).map { "\(t.columnNames[i]).\($0 + 1)" }
            default: newNames = try a.textList(3)
            }
            let fallback = a[4], extra = try a.optInt(5) ?? 2
            var newCols = [[MValue]](repeating: [], count: newNames.count)
            for p in parts {
                if p.count > newNames.count, extra == 1 { throw MError("Table.SplitColumn: a value split into more parts than there are columns.") }
                for k in 0..<newNames.count {
                    if extra == 0, k == newNames.count - 1, p.count > newNames.count { newCols[k].append(.list(Array(p[k...]))) }
                    else { newCols[k].append(k < p.count ? p[k] : fallback) }
                }
            }
            return .table(try MTable.make(Array(t.columnNames[..<i]) + newNames + Array(t.columnNames[(i + 1)...]),
                                          Array(t.columnTypes[..<i]) + newNames.map { _ in .any } + Array(t.columnTypes[(i + 1)...]),
                                          Array(cols[..<i]) + newCols + Array(cols[(i + 1)...]), rows: n))
        }
        lib.fn("Table.Profile", 1...2) { a, _ in
            let t = try a.table(0), cols = try t.columns
            let rows = t.columnNames.enumerated().map { i, name -> [MValue] in
                let cells = cols[i].map { $0.forcedCell() }
                let values = cells.filter { !$0.isNull && !$0.isError }
                let numbers = values.compactMap(\.numberValue)
                let allNumbers = !values.isEmpty && numbers.count == values.count
                let sorted = values.sorted { MValue.order($0, $1) < 0 }
                return [.text(name), sorted.first ?? .null, sorted.last ?? .null,
                        allNumbers ? .number(numbers.reduce(0, +) / Double(numbers.count)) : .null,
                        allNumbers ? .optNumber(MLib.standardDeviation(numbers)) : .null,
                        .int(cells.count), .int(cells.filter(\.isNull).count), .int(Set(cells.map { MKey($0) }).count)]
            }
            return .table(MTable(names: ["Column", "Min", "Max", "Average", "StandardDeviation", "Count", "NullCount", "DistinctCount"],
                                 types: [.text, .any, .any, .any, .any, .plainNumber, .plainNumber, .plainNumber], rows: rows))
        }
    }

    static func registerTableConstruction(_ lib: MLibrary) {
        lib.fn("Table.FromRecords", 1...3) { a, _ in
            let records = try a.forcedList(0).map { v -> MRecord in
                guard case .record(let r) = v else { throw MError.typeMismatch(expected: "record", got: v) }
                return r
            }
            let spec = a.has(1) ? try MLib.columnSpec(a[1], defaultCount: 0) : (names: records.first?.names ?? [], types: nil)
            let useNull = (try a.optInt(2) ?? 0) == 2
            let rows = try records.map { r in
                try spec.names.map { n -> MValue in
                    if let i = r.fields.index[n] { return r.cell(at: i) }
                    if useNull { return .null }
                    throw MError("The field '\(n)' of the record wasn't found.", detail: .record(r))
                }
            }
            return .table(MTable(names: spec.names, types: spec.types, rows: rows))
        }
        lib.fn("Table.FromRows", 1...2) { a, _ in
            let rows = try a.forcedList(0).map { v -> [MValue] in
                guard case .list(let l) = v else { throw MError.typeMismatch(expected: "list", got: v) }
                return l.map { $0.forcedCell() }
            }
            let spec = try MLib.columnSpec(a[1], defaultCount: rows.first?.count ?? 0)
            if let bad = rows.first(where: { $0.count != spec.names.count }) {
                throw MError("Table.FromRows: a row has \(bad.count) values but the table has \(spec.names.count) columns.")
            }
            return .table(try MTable.make(spec.names, spec.types ?? spec.names.map { _ in .any },
                                          spec.names.indices.map { c in rows.map { $0[c] } }, rows: rows.count))
        }
        lib.fn("Table.FromColumns", 1...2) { a, _ in
            let lists = try a.forcedList(0).map { v -> [MValue] in
                guard case .list(let l) = v else { throw MError.typeMismatch(expected: "list", got: v) }
                return l.map { $0.forcedCell() }
            }
            let spec = try MLib.columnSpec(a[1], defaultCount: lists.count)
            guard spec.names.count == lists.count else { throw MError("Table.FromColumns: \(lists.count) columns were given for \(spec.names.count) column names.") }
            let n = lists.map(\.count).max() ?? 0
            return .table(try MTable.make(spec.names, spec.types ?? spec.names.map { _ in .any },
                                          lists.map { $0 + [MValue](repeating: .null, count: n - $0.count) }, rows: n))
        }
        lib.fn("Table.FromList", 1...5) { a, ctx in
            let items = try a.forcedList(0)
            let splitter = try a.optFunction(1) ?? library(ctx, "Splitter.SplitTextByDelimiter", [.text(",")])
            let rows = try items.map { item -> [MValue] in
                guard case .list(let parts) = try ctx.call(splitter, [item]) else { throw MError("Table.FromList: the splitter must return a list.") }
                return parts.map { $0.forcedCell() }
            }
            let spec = try MLib.columnSpec(a[2], defaultCount: rows.map(\.count).max() ?? 1)
            let extra = try a.optInt(4) ?? 1
            let fitted = try rows.map { r -> [MValue] in
                if r.count > spec.names.count {
                    if extra == 1 { throw MError("Table.FromList: an item split into \(r.count) values but the table has \(spec.names.count) columns.") }
                    if extra == 0 { return Array(r.prefix(spec.names.count - 1)) + [.list(Array(r[(spec.names.count - 1)...]))] }
                    return Array(r.prefix(spec.names.count))
                }
                return r + [MValue](repeating: a[3], count: spec.names.count - r.count)
            }
            return .table(MTable(names: spec.names, types: spec.types, rows: fitted))
        }
        lib.fn("Table.FromValue", 1...2) { a, _ in
            switch a[0] {
            case .table: return a[0]
            case .list(let l): return .table(MTable(names: ["Value"], columns: [l.map { $0.forcedCell() }]))
            case .record(let r): return .table(MTable(names: ["Name", "Value"], types: [.text, .any], columns: [r.names.map(MValue.text), r.cells]))
            default: return .table(MTable(names: ["Value"], columns: [[a[0]]]))
            }
        }
        lib.fn("Table.Combine", 1...2) { a, _ in
            let tables = try a.forcedList(0).map { v -> MTable in
                guard case .table(let t) = v else { throw MError.typeMismatch(expected: "table", got: v) }
                return t
            }
            let all = try MOps.appendTables(tables)
            guard a.has(1) else { return .table(all) }
            let spec = try MLib.columnSpec(a[1], defaultCount: 0), cols = try all.columns, n = try all.rowCount
            return .table(try MTable.make(spec.names, spec.types ?? spec.names.map { all.columnIndex($0).map { all.columnTypes[$0] } ?? .any },
                                          spec.names.map { all.columnIndex($0).map { cols[$0] } ?? [MValue](repeating: .null, count: n) }, rows: n))
        }
    }
}
