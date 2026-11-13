import Foundation

/// Line-based text diff (Myers' O(ND) algorithm) producing unified-style hunks for display.
public enum TextDiff {
    public struct Line: Hashable, Sendable {
        public enum Kind: String, Sendable { case context, added, removed }
        public var kind: Kind
        public var text: String
        /// 1-based line number in the old text (nil for added lines).
        public var oldNumber: Int?
        /// 1-based line number in the new text (nil for removed lines).
        public var newNumber: Int?
    }

    public struct Hunk: Hashable, Sendable {
        public var oldStart: Int
        public var oldCount: Int
        public var newStart: Int
        public var newCount: Int
        public var lines: [Line]
        /// "@@ -a,b +c,d @@"
        public var header: String { "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@" }
    }

    public struct Stats: Hashable, Sendable { public var added: Int; public var removed: Int }

    /// Diffs two texts line by line. Returns no hunks when they are identical.
    /// - Parameter context: unchanged lines kept around each change.
    public static func diff(old: String, new: String, context: Int = 3) -> [Hunk] {
        hunks(from: lines(old: old, new: new), context: context)
    }

    /// Every line of the merged view (context, added and removed), in order.
    public static func lines(old: String, new: String) -> [Line] {
        let a = split(old), b = split(new)
        var out: [Line] = []
        out.reserveCapacity(max(a.count, b.count))
        var i = 0, j = 0
        for op in script(a, b) {
            switch op {
            case .equal: out.append(Line(kind: .context, text: a[i], oldNumber: i + 1, newNumber: j + 1)); i += 1; j += 1
            case .delete: out.append(Line(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil)); i += 1
            case .insert: out.append(Line(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1)); j += 1
            }
        }
        return out
    }

    public static func stats(_ hunks: [Hunk]) -> Stats {
        var s = Stats(added: 0, removed: 0)
        for h in hunks { for l in h.lines { if l.kind == .added { s.added += 1 } else if l.kind == .removed { s.removed += 1 } } }
        return s
    }

    /// Renders hunks as a unified diff.
    public static func unified(old: String, new: String, oldName: String = "before", newName: String = "after", context: Int = 3) -> String {
        let hs = diff(old: old, new: new, context: context)
        if hs.isEmpty { return "" }
        var out = "--- \(oldName)\n+++ \(newName)\n"
        for h in hs {
            out += h.header + "\n"
            for l in h.lines {
                out += (l.kind == .added ? "+" : l.kind == .removed ? "-" : " ") + l.text + "\n"
            }
        }
        return out
    }

    static func split(_ s: String) -> [String] {
        if s.isEmpty { return [] }
        var parts = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        if parts.last == "" { parts.removeLast() }
        return parts
    }

    static func hunks(from lines: [Line], context: Int) -> [Hunk] {
        let changed = lines.indices.filter { lines[$0].kind != .context }
        guard !changed.isEmpty else { return [] }
        let ctx = max(0, context)
        // Merge change positions into ranges with context.
        var ranges: [ClosedRange<Int>] = []
        for c in changed {
            let lo = max(0, c - ctx), hi = min(lines.count - 1, c + ctx)
            if let last = ranges.last, lo <= last.upperBound + 1 { ranges[ranges.count - 1] = last.lowerBound...max(hi, last.upperBound) }
            else { ranges.append(lo...hi) }
        }
        // Running old/new line numbers before each index.
        var oldBefore = [Int](repeating: 0, count: lines.count + 1), newBefore = oldBefore
        for (i, l) in lines.enumerated() {
            oldBefore[i + 1] = oldBefore[i] + (l.kind == .added ? 0 : 1)
            newBefore[i + 1] = newBefore[i] + (l.kind == .removed ? 0 : 1)
        }
        return ranges.map { r in
            let slice = Array(lines[r])
            let oc = slice.filter { $0.kind != .added }.count, nc = slice.filter { $0.kind != .removed }.count
            return Hunk(oldStart: oc == 0 ? oldBefore[r.lowerBound] : oldBefore[r.lowerBound] + 1, oldCount: oc,
                        newStart: nc == 0 ? newBefore[r.lowerBound] : newBefore[r.lowerBound] + 1, newCount: nc, lines: slice)
        }
    }

    enum Op { case equal, delete, insert }

    /// Shortest edit script between two sequences.
    static func script<T: Hashable>(_ a: [T], _ b: [T], maxD: Int = 2500) -> [Op] {
        // Trim common prefix and suffix; they dominate real edits.
        var pre = 0
        while pre < a.count, pre < b.count, a[pre] == b[pre] { pre += 1 }
        var suf = 0
        while suf < a.count - pre, suf < b.count - pre, a[a.count - 1 - suf] == b[b.count - 1 - suf] { suf += 1 }
        let x = Array(a[pre..<(a.count - suf)]), y = Array(b[pre..<(b.count - suf)])
        var ops = [Op](repeating: .equal, count: pre)
        ops += myers(x, y, maxD: maxD)
        ops += [Op](repeating: .equal, count: suf)
        return ops
    }

    private static func myers<T: Hashable>(_ a: [T], _ b: [T], maxD: Int) -> [Op] {
        let n = a.count, m = b.count
        if n == 0 { return [Op](repeating: .insert, count: m) }
        if m == 0 { return [Op](repeating: .delete, count: n) }
        let limit = min(n + m, maxD)
        let off = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var found = -1
        outer: for d in 0...limit {
            trace.append(Array(v[(off - d - 1)...(off + d + 1)]))
            var k = -d
            while k <= d {
                var xx: Int
                if k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) { xx = v[off + k + 1] } else { xx = v[off + k - 1] + 1 }
                var yy = xx - k
                while xx < n, yy < m, a[xx] == b[yy] { xx += 1; yy += 1 }
                v[off + k] = xx
                if xx >= n, yy >= m { found = d; break outer }
                k += 2
            }
        }
        guard found >= 0 else {
            // Too different to align cheaply: replace wholesale.
            return [Op](repeating: .delete, count: n) + [Op](repeating: .insert, count: m)
        }
        // Backtrack through the saved frontiers. trace[d] holds v for k in -(d+1)...(d+1) as it was before round d.
        var ops: [Op] = []
        var x = n, y = m
        var d = found
        while d > 0 {
            let snap = trace[d]
            func at(_ k: Int) -> Int { snap[k + d + 1] }
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && at(k - 1) < at(k + 1)) { prevK = k + 1 } else { prevK = k - 1 }
            let prevX = at(prevK), prevY = prevX - prevK
            while x > prevX, y > prevY { ops.append(.equal); x -= 1; y -= 1 }
            if x == prevX { ops.append(.insert); y -= 1 } else { ops.append(.delete); x -= 1 }
            d -= 1
        }
        while x > 0, y > 0 { ops.append(.equal); x -= 1; y -= 1 }
        return ops.reversed()
    }
}
