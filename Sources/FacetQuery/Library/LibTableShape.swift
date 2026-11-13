import Foundation
import FacetCore

extension MLibrary {
    static func registerTableShape(_ lib: MLibrary) {
        lib.fn("Table.PromoteHeaders", 1...2) { a, ctx in
            let t = try a.table(0), cols = try t.columns, n = try t.rowCount
            var allScalars = false, culture = ctx.culture
            if case .record(let o) = a[1] {
                allScalars = try o.logical("PromoteAllScalars") ?? false
                culture = try o.text("Culture") ?? culture
            }
            guard n > 0 else { return a[0] }
            let names = try cols.enumerated().map { i, c -> String in
                let cell = try c[0].forced()
                switch cell {
                case .text(let s): return s.isEmpty ? "Column\(i + 1)" : s
                case .number: return try MConvert.text(cell, culture: culture)
                case .null: return "Column\(i + 1)"
                default:
                    guard allScalars, !cell.isStructured else { return "Column\(i + 1)" }
                    return try MConvert.text(cell, culture: culture)
                }
            }
            return .table(MTable(names: MLib.uniqued(names), types: nil, columns: cols.map { Array($0.dropFirst()) }, rowCount: n - 1))
        }
        lib.fn("Table.DemoteHeaders", 1) { a, _ in
            let t = try a.table(0), cols = try t.columns
            return .table(MTable(names: (0..<t.columnCount).map { "Column\($0 + 1)" }, types: nil,
                                 columns: cols.enumerated().map { i, c in [.text(t.columnNames[i])] + c }, rowCount: try t.rowCount + 1))
        }
        lib.fn("Table.Transpose", 1...2) { a, _ in
            let t = try a.table(0), rows = try t.rows
            let spec = try MLib.columnSpec(a[1], defaultCount: rows.count)
            guard spec.names.count == rows.count else { throw MError("Table.Transpose: \(spec.names.count) column names were given for \(rows.count) columns.") }
            return .table(try MTable.make(spec.names, spec.types ?? spec.names.map { _ in .any }, rows, rows: t.columnCount))
        }
        func unpivot(_ t: MTable, _ pivot: [Int], _ attribute: String, _ value: String) throws -> MTable {
            let cols = try t.columns, keep = (0..<t.columnCount).filter { !pivot.contains($0) }
            var out = [[MValue]](repeating: [], count: keep.count + 2)
            for r in 0..<(try t.rowCount) {
                for p in pivot {
                    let cell = cols[p][r].forcedCell()
                    if cell.isNull { continue }
                    for (k, c) in keep.enumerated() { out[k].append(cols[c][r]) }
                    out[keep.count].append(.text(t.columnNames[p]))
                    out[keep.count + 1].append(cell)
                }
            }
            return try MTable.make(keep.map { t.columnNames[$0] } + [attribute, value], keep.map { t.columnTypes[$0] } + [.text, .any],
                                   out, rows: out[keep.count].count)
        }
        lib.fn("Table.Unpivot", 4) { a, _ in
            let t = try a.table(0)
            return .table(try unpivot(t, try t.requiredIndices(try a.textList(1)), try a.text(2), try a.text(3)))
        }
        lib.fn("Table.UnpivotOtherColumns", 4) { a, _ in
            let t = try a.table(0), keep = Set(try t.requiredIndices(try a.textList(1)))
            return .table(try unpivot(t, (0..<t.columnCount).filter { !keep.contains($0) }, try a.text(2), try a.text(3)))
        }
        lib.fn("Table.Pivot", 4...5) { a, ctx in
            let t = try a.table(0), pivotValues = try a.forcedList(1).filter { !$0.isNull }
            let attr = try t.requireColumn(try a.text(2)), value = try t.requireColumn(try a.text(3)), aggregate = try a.optFunction(4)
            let cols = try t.columns, keys = (0..<t.columnCount).filter { $0 != attr && $0 != value }
            var groups: [MKey: Int] = [:], groupRows: [[Int]] = []
            for r in 0..<(try t.rowCount) {
                let k = MLib.rowKey(cols, keys, r)
                if let g = groups[k] { groupRows[g].append(r) } else { groups[k] = groupRows.count; groupRows.append([r]) }
            }
            // Power Query returns the pivoted rows ordered by the remaining (key) columns.
            let ordered = try groupRows.stableSorted { x, y in
                for k in keys {
                    let c = MValue.order(cols[k][x[0]].forcedCell(), cols[k][y[0]].forcedCell())
                    if c != 0 { return c }
                }
                return 0
            }
            var out = keys.map { k in ordered.map { cols[k][$0[0]] } }
            for pv in pivotValues {
                out.append(ordered.map { rows in
                    let values = rows.filter { MValue.equals(cols[attr][$0].forcedCell(), pv) }.map { cols[value][$0] }
                    if let aggregate { return MValue.capturing { try ctx.call(aggregate, [.list(values)]) } }
                    switch values.count {
                    case 0: return .null
                    case 1: return values[0]
                    default: return .error(MError("There were too many elements in the enumeration to complete the operation.", detail: .list(values)))
                    }
                })
            }
            let names = try keys.map { t.columnNames[$0] } + pivotValues.map { try MConvert.text($0, culture: ctx.culture) }
            return .table(try MTable.make(names, keys.map { t.columnTypes[$0] } + pivotValues.map { _ in aggregate == nil ? t.columnTypes[value] : .any },
                                          out, rows: ordered.count))
        }
        lib.fn("Table.Group", 3...5) { a, ctx in
            let t = try a.table(0), keys = try t.requiredIndices(try a.textList(1)), cols = try t.columns
            let local = (try a.optInt(3) ?? 1) == 0, ignoreCase = MLib.ignoresCase(a[4])
            var groups: [MKey: Int] = [:], groupRows: [[Int]] = [], lastKey: MKey?
            for r in 0..<(try t.rowCount) {
                let k = MLib.rowKey(cols, keys, r, ignoreCase: ignoreCase)
                if local {
                    if k == lastKey { groupRows[groupRows.count - 1].append(r) } else { groupRows.append([r]); lastKey = k }
                } else if let g = groups[k] { groupRows[g].append(r) } else { groups[k] = groupRows.count; groupRows.append([r]) }
            }
            var names = keys.map { t.columnNames[$0] }, types = keys.map { t.columnTypes[$0] }
            var out = keys.map { k in groupRows.map { cols[k][$0[0]] } }
            let subTables = try groupRows.map { MValue.table(try t.selecting(rows: $0)) }
            for spec in try MLib.specList(a[2]) {
                guard spec.count >= 2, case .text(let name) = spec[0], case .function(let f) = spec[1] else {
                    throw MError("Table.Group: each aggregation must be {name, function} or {name, function, type}.")
                }
                names.append(name); types.append(spec.count > 2 ? spec[2].typeValue ?? .any : .any)
                out.append(subTables.map { sub in MValue.capturing { try ctx.call(f, [sub]) } })
            }
            return .table(try MTable.make(names, types, out, rows: groupRows.count))
        }
    }

    static func registerTableStructured(_ lib: MLibrary) {
        /// Replace column `i` by `newNames` columns, each row expanding to the rows `expand` returns (row-major cells).
        func expanding(_ t: MTable, _ i: Int, _ newNames: [String], _ expand: (MValue) throws -> [[MValue]]) throws -> MTable {
            let cols = try t.columns
            var out = [[MValue]](repeating: [], count: t.columnCount - 1 + newNames.count), total = 0
            for r in 0..<(try t.rowCount) {
                let produced: [[MValue]]
                do { produced = try expand(try cols[i][r].forced()) } catch {
                    produced = [[MValue](repeating: .error(MError.wrap(error)), count: newNames.count)]
                }
                for row in produced {
                    var k = 0
                    for c in 0..<t.columnCount {
                        if c == i { for v in row { out[k].append(v); k += 1 } } else { out[k].append(cols[c][r]); k += 1 }
                    }
                    total += 1
                }
            }
            return try MTable.make(Array(t.columnNames[..<i]) + newNames + Array(t.columnNames[(i + 1)...]),
                                   Array(t.columnTypes[..<i]) + newNames.map { _ in .any } + Array(t.columnTypes[(i + 1)...]), out, rows: total)
        }
        lib.fn("Table.ExpandRecordColumn", 3...4) { a, _ in
            let t = try a.table(0), i = try t.requireColumn(try a.text(1)), fields = try a.textList(2)
            let newNames = a.has(3) ? try a.textList(3) : fields
            guard newNames.count == fields.count else { throw MError("Table.ExpandRecordColumn: the new column names don't match the field names.") }
            return .table(try expanding(t, i, newNames) { cell in
                switch cell {
                case .null: return [[MValue](repeating: .null, count: fields.count)]
                case .record(let r): return [fields.map { f in r.fields.index[f].map { r.cell(at: $0) } ?? .null }]
                default: throw MError.typeMismatch(expected: "record", got: cell)
                }
            })
        }
        lib.fn("Table.ExpandTableColumn", 2...4) { a, _ in
            let t = try a.table(0), i = try t.requireColumn(try a.text(1))
            var wanted: [String]
            if a.has(2) { wanted = try a.textList(2) } else {
                wanted = []
                for cell in try t.columns[i] { if case .table(let n) = cell.forcedCell() { for c in n.columnNames where !wanted.contains(c) { wanted.append(c) } } }
            }
            let newNames = a.has(3) ? try a.textList(3) : wanted
            guard newNames.count == wanted.count else { throw MError("Table.ExpandTableColumn: the new column names don't match the column names.") }
            return .table(try expanding(t, i, newNames) { cell in
                let blank = [[MValue](repeating: .null, count: wanted.count)]
                switch cell {
                case .null: return blank
                case .table(let nested):
                    let cols = try nested.columns, n = try nested.rowCount, idx = wanted.map { nested.columnIndex($0) }
                    return n == 0 ? blank : (0..<n).map { r in idx.map { $0.map { cols[$0][r] } ?? .null } }
                default: throw MError.typeMismatch(expected: "table", got: cell)
                }
            })
        }
        lib.fn("Table.ExpandListColumn", 2) { a, _ in
            let t = try a.table(0), name = try a.text(1), i = try t.requireColumn(name)
            return .table(try expanding(t, i, [name]) { cell in
                switch cell {
                case .null: return [[.null]]
                case .list(let l): return l.isEmpty ? [[.null]] : l.map { [$0] }
                default: throw MError.typeMismatch(expected: "list", got: cell)
                }
            })
        }
        lib.fn("Table.AggregateTableColumn", 3) { a, ctx in
            let t = try a.table(0), i = try t.requireColumn(try a.text(1))
            let specs = try MLib.specList(a[2]).map { s -> (String, MFunction, String) in
                guard s.count == 3, case .text(let c) = s[0], case .function(let f) = s[1], case .text(let n) = s[2] else {
                    throw MError("Table.AggregateTableColumn: each aggregation must be {column, function, new column name}.")
                }
                return (c, f, n)
            }
            return .table(try expanding(t, i, specs.map(\.2)) { cell in
                var nested: MTable?
                switch cell {
                case .null: nested = nil
                case .table(let n): nested = n
                default: throw MError.typeMismatch(expected: "table", got: cell)
                }
                return [specs.map { column, f, _ in
                    MValue.capturing { try ctx.call(f, [.list(try nested.map { try $0.column(column) } ?? [])]) }
                }]
            })
        }
    }
}
