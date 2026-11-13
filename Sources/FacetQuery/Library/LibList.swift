import Foundation
import FacetCore

extension MLibrary {
    static func registerList(_ lib: MLibrary) {
        // MARK: Information and selection
        lib.fn("List.Count", 1) { a, _ in .int(try a.list(0).count) }
        lib.fn("List.NonNullCount", 1) { a, _ in .int(try a.forcedList(0).filter { !$0.isNull }.count) }
        lib.fn("List.IsEmpty", 1) { a, _ in .logical(try a.list(0).isEmpty) }
        lib.fn("List.First", 1...2) { a, _ in try a.list(0).first?.forced() ?? a[1] }
        lib.fn("List.Last", 1...2) { a, _ in try a.list(0).last?.forced() ?? a[1] }
        lib.fn("List.FirstN", 2) { a, ctx in
            let l = try a.list(0)
            return .list(Array(l.prefix(try MLib.leadingCount(a[1], l, ctx))))
        }
        lib.fn("List.LastN", 1...2) { a, ctx in
            let l = try a.list(0)
            return .list(Array(l.suffix(try MLib.trailingCount(a[1], l, ctx))))
        }
        for name in ["List.Skip", "List.RemoveFirstN"] {
            lib.fn(name, 1...2) { a, ctx in
                let l = try a.list(0)
                return .list(Array(l.dropFirst(try MLib.leadingCount(a[1], l, ctx))))
            }
        }
        lib.fn("List.RemoveLastN", 1...2) { a, ctx in
            let l = try a.list(0)
            return .list(Array(l.dropLast(try MLib.trailingCount(a[1], l, ctx))))
        }
        lib.fn("List.Range", 2...3) { a, _ in
            let l = try a.list(0), offset = try MLib.index(a, 1)
            let rest = l.dropFirst(offset)
            return .list(Array(try a.optInt(2).map { rest.prefix(max(0, $0)) } ?? rest))
        }
        lib.fn("List.Single", 1) { a, _ in
            let l = try a.list(0)
            guard l.count == 1 else {
                throw MError(l.isEmpty ? "There weren't enough elements in the enumeration to complete the operation."
                                       : "There were too many elements in the enumeration to complete the operation.")
            }
            return try l[0].forced()
        }
        lib.fn("List.SingleOrDefault", 1...2) { a, _ in
            let l = try a.list(0)
            if l.isEmpty { return a[1] }
            guard l.count == 1 else { throw MError("There were too many elements in the enumeration to complete the operation.") }
            return try l[0].forced()
        }
        lib.fn("List.Select", 2) { a, ctx in
            let f = try a.function(1)
            return .list(try a.forcedList(0).filter { try MLib.test(f, $0, ctx) })
        }
        lib.fn("List.Alternate", 2...4) { a, _ in
            // List.Alternate(list, count, repeatInterval, offset): keep `offset`, then skip `count` / keep `repeatInterval`.
            let l = try a.list(0), skip = try MLib.index(a, 1), offset = try a.optInt(3) ?? 0
            var out = Array(l.prefix(offset)), i = offset
            guard let keep = try a.optInt(2) else { return .list(out + l.dropFirst(offset + skip)) }
            guard skip + keep > 0 else { return .list(l) }
            while i < l.count {
                i += skip
                out.append(contentsOf: l.dropFirst(i).prefix(keep)); i += keep
            }
            return .list(out)
        }
        lib.fn("List.FindText", 2) { a, _ in
            let needle = try a.text(1)
            return .list(try a.forcedList(0).filter { ($0.textValue ?? "").contains(needle) && $0.textValue != nil })
        }
        lib.fn("List.Buffer", 1) { a, _ in .list(try a.list(0).map { $0.forcedCell() }) }

        // MARK: Transformation
        lib.fn("List.Transform", 2) { a, ctx in
            let f = try a.function(1)
            return .list(try a.list(0).map { item in MValue.capturing { try ctx.call(f, [try item.forced()]) } })
        }
        lib.fn("List.TransformMany", 3) { a, ctx in
            let collection = try a.function(1), result = try a.function(2)
            var out: [MValue] = []
            for x in try a.forcedList(0) {
                guard case .list(let ys) = try ctx.call(collection, [x]) else { throw MError("List.TransformMany: the collection function must return a list.") }
                for y in ys { out.append(try ctx.call(result, [x, try y.forced()])) }
            }
            return .list(out)
        }
        lib.fn("List.Reverse", 1) { a, _ in .list(try a.list(0).reversed()) }
        lib.fn("List.Combine", 1) { a, _ in
            .list(try a.forcedList(0).flatMap { v -> [MValue] in
                guard case .list(let l) = v else { throw MError.typeMismatch(expected: "list", got: v) }
                return l
            })
        }
        lib.fn("List.Repeat", 2) { a, _ in
            let l = try a.list(0)
            return .list((0..<(try MLib.index(a, 1))).flatMap { _ in l })
        }
        lib.fn("List.Zip", 1) { a, _ in
            let lists = try a.forcedList(0).map { v -> [MValue] in
                guard case .list(let l) = v else { throw MError.typeMismatch(expected: "list", got: v) }
                return l
            }
            let n = lists.map(\.count).max() ?? 0
            return .list((0..<n).map { i in .list(lists.map { i < $0.count ? $0[i] : .null }) })
        }
        lib.fn("List.Split", 2) { a, _ in
            let l = try a.list(0), size = try a.int(1)
            guard size > 0 else { throw MError("List.Split: the page size must be positive.") }
            return .list(stride(from: 0, to: l.count, by: size).map { .list(Array(l[$0..<min($0 + size, l.count)])) })
        }
        lib.fn("List.Sort", 1...2) { a, ctx in
            let cmp = try MCriteria.comparer(a[1], ctx)
            return .list(try a.forcedList(0).stableSorted(cmp))
        }
        lib.fn("List.Accumulate", 3) { a, ctx in
            let f = try a.function(2)
            var state = a[1]
            for x in try a.forcedList(0) { state = try ctx.call(f, [state, x]) }
            return state
        }
        lib.fn("List.InsertRange", 3) { a, _ in
            var l = try a.list(0)
            let i = try MLib.index(a, 1)
            guard i <= l.count else { throw MError("List.InsertRange: the index is out of range.") }
            l.insert(contentsOf: try a.list(2), at: i)
            return .list(l)
        }
        lib.fn("List.RemoveRange", 2...3) { a, _ in
            var l = try a.list(0)
            let i = try MLib.index(a, 1), n = try a.optInt(2) ?? 1
            guard n >= 0, i + n <= l.count else { throw MError("List.RemoveRange: the range is outside the list.") }
            l.removeSubrange(i..<(i + n))
            return .list(l)
        }
        lib.fn("List.ReplaceRange", 4) { a, _ in
            var l = try a.list(0)
            let i = try MLib.index(a, 1), n = try MLib.index(a, 2)
            guard i + n <= l.count else { throw MError("List.ReplaceRange: the range is outside the list.") }
            l.replaceSubrange(i..<(i + n), with: try a.list(3))
            return .list(l)
        }
        lib.fn("List.ReplaceValue", 4) { a, ctx in
            let replacer = try a.function(3)
            return .list(try a.forcedList(0).map { try ctx.call(replacer, [$0, a[1], a[2]]) })
        }
        lib.fn("List.ReplaceMatchingItems", 2...3) { a, ctx in
            let key = try MCriteria.keyer(a[2], ctx)
            var map: [MKey: MValue] = [:]
            for pair in try a.forcedList(1) {
                guard case .list(let p) = pair, p.count == 2 else { throw MError("List.ReplaceMatchingItems: each replacement must be a {old, new} list.") }
                map[try key(try p[0].forced())] = try p[1].forced()
            }
            return .list(try a.forcedList(0).map { map[try key($0)] ?? $0 })
        }

        // MARK: Membership and set operations
        lib.fn("List.Contains", 2...3) { a, ctx in
            let key = try MCriteria.keyer(a[2], ctx), wanted = try key(a[1])
            return .logical(try a.forcedList(0).contains { try key($0) == wanted })
        }
        lib.fn("List.ContainsAll", 2...3) { a, ctx in
            let key = try MCriteria.keyer(a[2], ctx)
            let have = Set(try a.forcedList(0).map(key))
            return .logical(try a.forcedList(1).allSatisfy { have.contains(try key($0)) })
        }
        lib.fn("List.ContainsAny", 2...3) { a, ctx in
            let key = try MCriteria.keyer(a[2], ctx)
            let have = Set(try a.forcedList(0).map(key))
            return .logical(try a.forcedList(1).contains { have.contains(try key($0)) })
        }
        lib.fn("List.PositionOf", 2...4) { a, ctx in
            let key = try MCriteria.keyer(a[3], ctx), wanted = try key(a[1])
            let hits = try a.forcedList(0).enumerated().filter { try key($0.element) == wanted }.map(\.offset)
            return MLibrary.occurrence(hits, try a.optInt(2) ?? 0)
        }
        lib.fn("List.PositionOfAny", 2...4) { a, ctx in
            let key = try MCriteria.keyer(a[3], ctx)
            let wanted = Set(try a.forcedList(1).map(key))
            let hits = try a.forcedList(0).enumerated().filter { wanted.contains(try key($0.element)) }.map(\.offset)
            return MLibrary.occurrence(hits, try a.optInt(2) ?? 0)
        }
        lib.fn("List.Positions", 1) { a, _ in .list((0..<(try a.list(0).count)).map(MValue.int)) }
        lib.fn("List.Distinct", 1...2) { a, ctx in
            let key = try MCriteria.keyer(a[1], ctx)
            var seen = Set<MKey>()
            return .list(try a.forcedList(0).filter { seen.insert(try key($0)).inserted })
        }
        lib.fn("List.IsDistinct", 1...2) { a, ctx in
            let key = try MCriteria.keyer(a[1], ctx)
            let l = try a.forcedList(0)
            return .logical(Set(try l.map(key)).count == l.count)
        }
        lib.fn("List.RemoveNulls", 1) { a, _ in .list(try a.forcedList(0).filter { !$0.isNull }) }
        for name in ["List.RemoveItems", "List.RemoveMatchingItems"] {
            lib.fn(name, 2...3) { a, ctx in
                let key = try MCriteria.keyer(a[2], ctx)
                let drop = Set(try a.forcedList(1).map(key))
                return .list(try a.forcedList(0).filter { !drop.contains(try key($0)) })
            }
        }
        lib.fn("List.Difference", 2...3) { a, ctx in
            let key = try MCriteria.keyer(a[2], ctx)
            var remove: [MKey: Int] = [:]
            for v in try a.forcedList(1) { remove[try key(v), default: 0] += 1 }
            return .list(try a.forcedList(0).filter { v in
                let k = try key(v)
                if let n = remove[k], n > 0 { remove[k] = n - 1; return false }
                return true
            })
        }
        lib.fn("List.Union", 1...2) { a, ctx in
            // Bag union: each value appears as often as in the list where it is most frequent.
            let key = try MCriteria.keyer(a[1], ctx)
            var out: [MValue] = [], have: [MKey: Int] = [:]
            for case .list(let l) in try a.forcedList(0) {
                var seen: [MKey: Int] = [:]
                for v in try l.map({ try $0.forced() }) {
                    let k = try key(v)
                    seen[k, default: 0] += 1
                    if seen[k, default: 0] > have[k, default: 0] { have[k, default: 0] += 1; out.append(v) }
                }
            }
            return .list(out)
        }
        lib.fn("List.Intersect", 1...2) { a, ctx in
            let key = try MCriteria.keyer(a[1], ctx)
            let lists = try a.forcedList(0).map { v -> [MValue] in
                guard case .list(let l) = v else { throw MError.typeMismatch(expected: "list", got: v) }
                return try l.map { try $0.forced() }
            }
            guard var result = lists.first else { return .list([]) }
            for other in lists.dropFirst() {
                var available: [MKey: Int] = [:]
                for v in other { available[try key(v), default: 0] += 1 }
                result = try result.filter { v in
                    let k = try key(v)
                    if let n = available[k], n > 0 { available[k] = n - 1; return true }
                    return false
                }
            }
            return .list(result)
        }
        lib.fn("List.AllTrue", 1) { a, _ in .logical(try a.forcedList(0).allSatisfy { v in
            guard case .logical(let b) = v else { throw MError.typeMismatch(expected: "logical", got: v) }
            return b
        }) }
        lib.fn("List.AnyTrue", 1) { a, _ in .logical(try a.forcedList(0).contains { v in
            guard case .logical(let b) = v else { throw MError.typeMismatch(expected: "logical", got: v) }
            return b
        }) }
        lib.fn("List.MatchesAll", 2) { a, ctx in
            let f = try a.function(1)
            return .logical(try a.forcedList(0).allSatisfy { try MLib.test(f, $0, ctx) })
        }
        lib.fn("List.MatchesAny", 2) { a, ctx in
            let f = try a.function(1)
            return .logical(try a.forcedList(0).contains { try MLib.test(f, $0, ctx) })
        }

        registerListAggregates(lib)
        registerListGenerators(lib)
    }

    /// `Occurrence.First` / `Last` → a position or -1; `Occurrence.All` → the list of positions.
    static func occurrence(_ hits: [Int], _ occurrence: Int) -> MValue {
        switch occurrence {
        case 1: return .int(hits.last ?? -1)
        case 2: return .list(hits.map(MValue.int))
        default: return .int(hits.first ?? -1)
        }
    }

    private static func registerListAggregates(_ lib: MLibrary) {
        lib.fn("List.Sum", 1...2) { a, _ in
            var total: MValue = .null
            for v in try a.forcedList(0) where !v.isNull { total = total.isNull ? v : try MOps.add(total, v) }
            return total
        }
        lib.fn("List.Product", 1...2) { a, _ in
            let xs = try MLib.numbers(try a.list(0))
            return xs.isEmpty ? .null : .number(xs.reduce(1, *))
        }
        lib.fn("List.Average", 1...2) { a, _ in
            let items = try a.forcedList(0).filter { !$0.isNull }
            guard let first = items.first else { return .null }
            switch first {
            case .number:
                let xs = try MLib.numbers(items)
                return .number(xs.reduce(0, +) / Double(xs.count))
            case .duration:
                var total = 0.0
                for v in items { guard case .duration(let s) = v else { throw MError.typeMismatch(expected: "duration", got: v) }; total += s }
                return .duration(total / Double(items.count))
            case .date, .datetime, .datetimezone:
                var total = 0.0
                for v in items {
                    switch v {
                    case .date(let d), .datetime(let d), .datetimezone(let d, _): total += d.timeIntervalSince1970
                    default: throw MError.typeMismatch(expected: first.typeName, got: v)
                    }
                }
                let mean = Date(timeIntervalSince1970: total / Double(items.count))
                if case .date = first { return .date(MOps.dayFloor(mean)) }
                if case .datetimezone(_, let off) = first { return .datetimezone(mean, offsetMinutes: off) }
                return .datetime(mean)
            default: throw MError.typeMismatch(expected: "number", got: first)
            }
        }
        lib.fn("List.Median", 1...2) { a, ctx in
            let items = try a.forcedList(0).filter { !$0.isNull }
            guard !items.isEmpty else { return .null }
            if items.allSatisfy({ $0.numberValue != nil }) {
                return .optNumber(MLib.median(items.compactMap(\.numberValue).sorted()))
            }
            let sorted = try items.stableSorted(try MCriteria.comparer(a[1], ctx))
            return sorted[(sorted.count - 1) / 2]
        }
        lib.fn("List.StandardDeviation", 1) { a, _ in .optNumber(MLib.standardDeviation(try MLib.numbers(try a.list(0)))) }
        lib.fn("List.Covariance", 2) { a, _ in
            let x = try MLib.numbers(try a.list(0)), y = try MLib.numbers(try a.list(1))
            guard x.count == y.count, !x.isEmpty else { throw MError("List.Covariance: both lists must have the same, non-zero number of values.") }
            let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
            return .number(zip(x, y).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) } / Double(x.count))
        }
        func extreme(_ name: String, wantMax: Bool) {
            lib.fn(name, 1...4) { a, ctx in
                let includeNulls = try a.optLogical(3) ?? false
                let items = try a.forcedList(0).filter { includeNulls || !$0.isNull }
                let cmp = try MCriteria.comparer(a[2], ctx)
                guard var best = items.first else { return a[1] }
                for v in items.dropFirst() {
                    let c = try cmp(v, best)
                    if wantMax ? c > 0 : c < 0 { best = v }
                }
                return best
            }
        }
        extreme("List.Max", wantMax: true)
        extreme("List.Min", wantMax: false)
        func extremeN(_ name: String, descending: Bool) {
            lib.fn(name, 2...4) { a, ctx in
                let includeNulls = try a.optLogical(3) ?? false
                let cmp = try MCriteria.comparer(a[2], ctx)
                let sorted = try a.forcedList(0).filter { includeNulls || !$0.isNull }
                    .stableSorted { descending ? try cmp($1, $0) : try cmp($0, $1) }
                return .list(Array(sorted.prefix(try MLib.leadingCount(a[1], sorted, ctx))))
            }
        }
        extremeN("List.MaxN", descending: true)
        extremeN("List.MinN", descending: false)
        func modes(_ a: MArgs, _ ctx: MInterpreter) throws -> [MValue] {
            let key = try MCriteria.keyer(a[1], ctx)
            var counts: [MKey: Int] = [:], order: [(MKey, MValue)] = []
            for v in try a.forcedList(0) {
                let k = try key(v)
                if counts[k] == nil { order.append((k, v)) }
                counts[k, default: 0] += 1
            }
            let top = counts.values.max() ?? 0
            return order.filter { counts[$0.0] == top }.map(\.1)
        }
        lib.fn("List.Modes", 1...2) { a, ctx in .list(try modes(a, ctx)) }
        lib.fn("List.Mode", 1...2) { a, ctx in
            guard let last = try modes(a, ctx).last else { throw MError("List.Mode: the list is empty.") }
            return last
        }
        lib.fn("List.Percentile", 2...3) { a, _ in
            let xs = try MLib.numbers(try a.list(0)).sorted()
            func at(_ p: Double) throws -> MValue {
                guard p >= 0, p <= 1 else { throw MError("List.Percentile: the percentile must be between 0 and 1.") }
                guard !xs.isEmpty else { return .null }
                let pos = p * Double(xs.count - 1), lo = Int(pos.rounded(.down)), hi = min(lo + 1, xs.count - 1)
                return .number(xs[lo] + (xs[hi] - xs[lo]) * (pos - Double(lo)))
            }
            if case .list(let ps) = a[1] { return .list(try ps.map { try at(try MArgs(values: [try $0.forced()], functionName: "List.Percentile").number(0)) }) }
            return try at(try a.number(1))
        }
    }

    private static func registerListGenerators(_ lib: MLibrary) {
        let limit = 50_000_000
        func count(_ a: MArgs, _ i: Int) throws -> Int {
            let n = try MLib.index(a, i)
            guard n <= limit else { throw MError("\(a.functionName): the list would be too large.") }
            return n
        }
        lib.fn("List.Numbers", 2...3) { a, _ in
            let start = try a.number(0), step = try a.optNumber(2) ?? 1
            return .list((0..<(try count(a, 1))).map { .number(start + Double($0) * step) })
        }
        for name in ["List.Dates", "List.DateTimes", "List.DateTimeZones", "List.Times", "List.Durations"] {
            lib.fn(name, 3) { a, _ in
                guard case .duration(let step) = a[2] else { throw MError.typeMismatch(expected: "duration", got: a[2]) }
                var out: [MValue] = []
                for k in 0..<(try count(a, 1)) { out.append(try MOps.add(a[0], .duration(step * Double(k)))) }
                return .list(out)
            }
        }
        lib.fn("List.Generate", 3...4) { a, ctx in
            let initial = try a.function(0), condition = try a.function(1), next = try a.function(2), selector = try a.optFunction(3)
            var out: [MValue] = [], state = try ctx.call(initial, [])
            while try MLib.test(condition, state, ctx) {
                guard out.count < limit else { throw MError("List.Generate: the list would be too large.") }
                out.append(try selector.map { try ctx.call($0, [state]) } ?? state)
                state = try ctx.call(next, [state])
            }
            return .list(out)
        }
        lib.fn("List.Random", 1...2) { a, _ in
            let n = try count(a, 0)
            if let seed = try a.optNumber(1) {
                var state = UInt64(bitPattern: Int64(seed)) &+ 0x9E3779B97F4A7C15
                return .list((0..<n).map { _ in
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    return .number(Double(state >> 11) / Double(1 << 53))
                })
            }
            return .list((0..<n).map { _ in .number(Double.random(in: 0..<1)) })
        }
    }
}
