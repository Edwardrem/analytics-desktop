import Foundation

extension MLibrary {
    static func registerRecord(_ lib: MLibrary) {
        lib.fn("Record.Field", 2) { a, _ in try a.record(0).require(try a.text(1)) }
        lib.fn("Record.FieldOrDefault", 2...3) { a, _ in
            guard let r = try a.optRecord(0) else { return a[2] }
            return try r.get(try a.text(1)) ?? a[2]
        }
        lib.fn("Record.FieldNames", 1) { a, _ in .list(try a.record(0).names.map(MValue.text)) }
        lib.fn("Record.FieldValues", 1) { a, _ in .list(try a.record(0).cells) }
        lib.fn("Record.ToList", 1) { a, _ in .list(try a.record(0).cells) }
        lib.fn("Record.FieldCount", 1) { a, _ in .int(try a.record(0).count) }
        lib.fn("Record.HasFields", 2) { a, _ in
            let r = try a.record(0)
            return .logical(try a.textList(1).allSatisfy(r.has))
        }
        lib.fn("Record.AddField", 3...4) { a, ctx in
            let r = try a.record(0), name = try a.text(1)
            if r.has(name) { throw MError("The field '\(name)' already exists in the record.") }
            var v = a[2]
            if try a.optLogical(3) ?? false, case .function(let f) = v { v = .lazy(MThunk { try ctx.call(f, []) }) }
            return .record(r.setting(name, v))
        }
        lib.fn("Record.RemoveFields", 2...3) { a, _ in
            let r = try a.record(0), names = try a.textList(1)
            if (try a.optInt(2) ?? 0) == 0, let missing = names.first(where: { !r.has($0) }) {
                throw MError("The field '\(missing)' of the record wasn't found.")
            }
            return .record(r.removing(Set(names)))
        }
        lib.fn("Record.RenameFields", 2...3) { a, _ in
            let r = try a.record(0)
            var pairs: [(String, String)] = []
            let spec = try a.forcedList(1)
            if spec.count == 2, case .text(let x) = spec[0], case .text(let y) = spec[1] { pairs = [(x, y)] }
            else {
                for p in spec {
                    guard case .list(let l) = p, l.count == 2, case .text(let x) = try l[0].forced(), case .text(let y) = try l[1].forced() else {
                        throw MError("Record.RenameFields expects {old, new} pairs.")
                    }
                    pairs.append((x, y))
                }
            }
            let missing = try a.optInt(2) ?? 0
            var names = r.names
            for (old, new) in pairs {
                guard let i = names.firstIndex(of: old) else {
                    if missing == 0 { throw MError("The field '\(old)' of the record wasn't found.") }
                    continue
                }
                names[i] = new
            }
            if Set(names).count != names.count { throw MError("Record.RenameFields: the rename would create duplicate field names.") }
            return .record(MRecord(names: names, values: r.values))
        }
        lib.fn("Record.ReorderFields", 2...3) { a, _ in
            let r = try a.record(0), order = try a.textList(1)
            let missing = try a.optInt(2) ?? 0
            if missing == 0, let m = order.first(where: { !r.has($0) }) { throw MError("The field '\(m)' of the record wasn't found.") }
            let present = order.filter(r.has)
            var queue = present.makeIterator()
            let set = Set(present)
            var names: [String] = []
            for n in r.names { names.append(set.contains(n) ? (queue.next() ?? n) : n) }
            return .record(MRecord(names: names, values: names.map { r.values[r.fields.index[$0] ?? 0] }))
        }
        lib.fn("Record.SelectFields", 2...3) { a, _ in
            let r = try a.record(0), names = try a.textList(1)
            let missing = try a.optInt(2) ?? 0
            var outN: [String] = [], outV: [MValue] = []
            for n in names {
                if let i = r.fields.index[n] { outN.append(n); outV.append(r.values[i]) }
                else if missing == 2 { outN.append(n); outV.append(.null) }
                else if missing == 0 { throw MError("The field '\(n)' of the record wasn't found.") }
            }
            return .record(MRecord(names: outN, values: outV))
        }
        lib.fn("Record.TransformFields", 2...3) { a, ctx in
            let r = try a.record(0)
            var ops: [(String, MFunction)] = []
            let spec = try a.forcedList(1)
            if spec.count == 2, case .text(let n) = spec[0], case .function(let f) = spec[1] { ops = [(n, f)] }
            else {
                for p in spec {
                    guard case .list(let l) = p, l.count == 2, case .text(let n) = try l[0].forced(), case .function(let f) = try l[1].forced() else {
                        throw MError("Record.TransformFields expects {field, function} pairs.")
                    }
                    ops.append((n, f))
                }
            }
            let missing = try a.optInt(2) ?? 0
            var out = r
            for (n, f) in ops {
                if r.has(n) { out = out.setting(n, try ctx.call(f, [try r.require(n)])) }
                else if missing == 2 { out = out.setting(n, try ctx.call(f, [.null])) }
                else if missing == 0 { throw MError("The field '\(n)' of the record wasn't found.") }
            }
            return .record(out)
        }
        lib.fn("Record.Combine", 1) { a, _ in
            var out = MRecord.empty
            for v in try a.forcedList(0) {
                guard case .record(let r) = v else { throw MError.typeMismatch(expected: "record", got: v) }
                out = out.merging(r)
            }
            return .record(out)
        }
        lib.fn("Record.FromList", 2) { a, _ in
            let values = try a.list(0)
            let names: [String]
            if case .type(let t) = a[1] { names = t.fields.map(\.name) } else { names = try a.textList(1) }
            guard names.count == values.count else { throw MError("Record.FromList: the number of values and field names differ.") }
            return .record(MRecord(names: names, values: values))
        }
        lib.fn("Record.FromTable", 1) { a, _ in
            let t = try a.table(0)
            let names = try t.column("Name").map { v -> String in
                guard case .text(let s) = try v.forced() else { throw MError("Record.FromTable: Name must be text.") }
                return s
            }
            return .record(MRecord(names: names, values: try t.column("Value")))
        }
        lib.fn("Record.ToTable", 1) { a, _ in
            let r = try a.record(0)
            return .table(MTable(names: ["Name", "Value"], types: [.text, .any], columns: [r.names.map(MValue.text), r.cells]))
        }
    }
}
