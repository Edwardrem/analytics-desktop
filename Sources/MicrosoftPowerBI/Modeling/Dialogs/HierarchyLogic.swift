import Foundation
import FacetCore

/// User-defined hierarchies: creating, reordering levels and validating.
enum HierarchyLogic {
    /// A new hierarchy over the given columns, named "<first column> Hierarchy" as Power BI does.
    static func make(from columns: [String], in table: ModelTable, alongside drafts: [Hierarchy]? = nil) -> Hierarchy {
        let base = columns.first.map { "\($0) Hierarchy" } ?? "Hierarchy"
        let taken = (drafts ?? table.hierarchies).map(\.name) + table.columns.map(\.name) + table.measures.map(\.name)
        var name = base
        var n = 2
        while taken.contains(where: { ModelDAX.same($0, name) }) { name = "\(base) \(n)"; n += 1 }
        var levels: [String] = []
        for c in columns where table.column(c) != nil && !levels.contains(where: { ModelDAX.same($0, c) }) { levels.append(c) }
        return Hierarchy(name: name, levels: levels)
    }

    /// Moves a level; out-of-range moves change nothing.
    static func move(_ levels: [String], from: Int, to: Int) -> [String] {
        guard levels.indices.contains(from), levels.indices.contains(to), from != to else { return levels }
        var out = levels
        let item = out.remove(at: from)
        out.insert(item, at: to)
        return out
    }

    /// Adds a column as the lowest level, unless it is already a level.
    static func adding(_ column: String, to levels: [String]) -> [String] {
        levels.contains(where: { ModelDAX.same($0, column) }) ? levels : levels + [column]
    }

    static func problems(_ hierarchies: [Hierarchy], table: ModelTable) -> [String] {
        var out: [String] = []
        for (i, h) in hierarchies.enumerated() {
            let name = h.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let others = hierarchies.enumerated().filter { $0.offset < i }.map(\.element.name)
            if let p = ModelNames.problem(name, noun: "hierarchy", others: others) { if !out.contains(p) { out.append(p) }; continue }
            if name.contains("[") || name.contains("]") { out.append("Names can't contain square brackets.") }
            if table.column(name) != nil { out.append("“\(name)” is already a column in \(table.name).") }
            if table.measure(name) != nil { out.append("“\(name)” is already a measure in \(table.name).") }
            if h.levels.isEmpty { out.append("“\(name)” needs at least one level.") }
            if let missing = h.levels.first(where: { table.column($0) == nil }) { out.append("“\(name)” uses “\(missing)”, which is not a column of \(table.name).") }
            if let dup = ModelNames.firstDuplicate(h.levels) { out.append("“\(name)” lists “\(dup)” twice.") }
        }
        return out
    }

    static func cleaned(_ hierarchies: [Hierarchy]) -> [Hierarchy] {
        hierarchies.map { h in var h = h; h.name = h.name.trimmingCharacters(in: .whitespacesAndNewlines); return h }
    }
}
