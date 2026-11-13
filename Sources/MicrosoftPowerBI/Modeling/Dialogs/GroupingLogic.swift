import Foundation
import FacetCore

/// The groups-and-bins dialog's editable state.
struct GroupDraft: Equatable {
    enum Mode: String, CaseIterable, Identifiable { case list, bins
        var id: String { rawValue }
        var title: String { self == .list ? "List" : "Bin" }
    }
    struct Group: Identifiable, Equatable {
        var id = UUID()
        var name: String
        var members: [Value]
    }
    var name: String
    var source: String
    var mode: Mode
    var groups: [Group] = []
    var includeOther = false
    var otherName = "Other"
    /// Bins: by size (true) or by number of bins (false).
    var bySize = true
    var binSize: Double = 10
    var binCount: Double = 10
    var unit: ColumnGrouping.BinUnit?
}

/// Grouping discrete values and binning numbers and dates.
enum GroupingLogic {
    static func defaultName(source: String, mode: GroupDraft.Mode, taken: [String]) -> String {
        let base = "\(source) (\(mode == .list ? "groups" : "bins"))"
        var name = base
        var n = 2
        while taken.contains(where: { ModelDAX.same($0, name) }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// A draft for a new group column over `source`, or for editing an existing group column.
    static func draft(source: ModelColumn, existing: ModelColumn? = nil, table: ModelTable, range: (min: Double, max: Double)? = nil) -> GroupDraft {
        let binnable = source.dataType.isNumeric || source.dataType == .date || source.dataType == .dateTime
        if let existing, let g = existing.grouping {
            var d = GroupDraft(name: existing.name, source: g.sourceColumn, mode: g.kind == .list ? .list : .bins)
            d.groups = g.groups.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { GroupDraft.Group(name: $0, members: g.groups[$0] ?? []) }
            d.includeOther = g.otherGroupName != nil
            d.otherName = g.otherGroupName ?? "Other"
            d.bySize = g.kind != .binCount
            if g.kind == .binSize { d.binSize = g.binValue } else if g.kind == .binCount { d.binCount = g.binValue }
            d.unit = g.binUnit
            return d
        }
        let mode: GroupDraft.Mode = binnable ? .bins : .list
        var d = GroupDraft(name: defaultName(source: source.name, mode: mode, taken: table.columns.map(\.name) + table.measures.map(\.name)),
                           source: source.name, mode: mode)
        if source.dataType.isTemporal { d.unit = .month; d.binSize = 1 }
        else if let range { d.binSize = suggestedSize(minimum: range.min, maximum: range.max) }
        return d
    }

    /// A round bin size that gives roughly ten bins across the range.
    static func suggestedSize(minimum: Double, maximum: Double) -> Double {
        let raw = (maximum - minimum) / 10
        guard raw > 0, raw.isFinite else { return 1 }
        let magnitude = pow(10, (log10(raw)).rounded(.down))
        let fraction = raw / magnitude
        let nice: Double = fraction < 1.5 ? 1 : (fraction < 3.5 ? 2 : (fraction < 7.5 ? 5 : 10))
        return nice * magnitude
    }

    /// How many bins a size produces over a range: one per multiple of the size the range touches.
    static func binCount(size: Double, minimum: Double, maximum: Double) -> Int {
        guard size > 0, maximum >= minimum else { return 0 }
        let first = (minimum / size + 1e-9).rounded(.down)
        let last = (maximum / size + 1e-9).rounded(.down)
        return Int(last - first) + 1
    }
    /// The bin width that splits a range into `count` equal bins.
    static func binSize(count: Double, minimum: Double, maximum: Double) -> Double {
        guard count >= 1, maximum > minimum else { return 0 }
        return (maximum - minimum) / count.rounded(.down)
    }

    // MARK: List groups

    static func defaultGroupName(_ members: [Value], taken: [String]) -> String {
        let base = members.map { $0.isNull ? "(Blank)" : $0.asString }.joined(separator: " & ")
        var name = base.isEmpty ? "Group" : base
        var n = 2
        while taken.contains(where: { ModelDAX.same($0, name) }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    /// Puts values into one new group, taking them out of any group they were in. Emptied groups disappear.
    @discardableResult
    static func group(_ values: [Value], in draft: inout GroupDraft) -> UUID? {
        guard !values.isEmpty else { return nil }
        let picked = Set(values)
        for i in draft.groups.indices { draft.groups[i].members.removeAll { picked.contains($0) } }
        draft.groups.removeAll { $0.members.isEmpty }
        var members: [Value] = []
        for v in values where !members.contains(v) { members.append(v) }
        let g = GroupDraft.Group(name: defaultGroupName(members, taken: draft.groups.map(\.name)), members: members)
        draft.groups.append(g)
        return g.id
    }

    /// Adds values to an existing group, taking them out of any other group.
    static func add(_ values: [Value], to group: UUID, in draft: inout GroupDraft) {
        guard draft.groups.contains(where: { $0.id == group }) else { return }
        let picked = Set(values)
        for i in draft.groups.indices where draft.groups[i].id != group { draft.groups[i].members.removeAll { picked.contains($0) } }
        if let i = draft.groups.firstIndex(where: { $0.id == group }) {
            for v in values where !draft.groups[i].members.contains(v) { draft.groups[i].members.append(v) }
        }
        draft.groups.removeAll { $0.members.isEmpty }
    }

    /// Returns one value, or a whole group, to the ungrouped list.
    static func ungroup(value: Value, in draft: inout GroupDraft) {
        for i in draft.groups.indices { draft.groups[i].members.removeAll { $0 == value } }
        draft.groups.removeAll { $0.members.isEmpty }
    }
    static func ungroup(group: UUID, in draft: inout GroupDraft) { draft.groups.removeAll { $0.id == group } }

    /// Source values that are in no group, in their given order.
    static func ungrouped(_ distinct: [Value], draft: GroupDraft) -> [Value] {
        let grouped = Set(draft.groups.flatMap(\.members))
        return distinct.filter { !grouped.contains($0) }
    }

    // MARK: Result

    static func grouping(from d: GroupDraft) -> ColumnGrouping {
        switch d.mode {
        case .list:
            var g = ColumnGrouping(kind: .list, sourceColumn: d.source)
            for group in d.groups { g.groups[group.name.trimmingCharacters(in: .whitespacesAndNewlines)] = group.members }
            g.otherGroupName = d.includeOther ? d.otherName.trimmingCharacters(in: .whitespacesAndNewlines) : nil
            return g
        case .bins:
            var g = ColumnGrouping(kind: d.bySize ? .binSize : .binCount, sourceColumn: d.source)
            g.binValue = d.bySize ? d.binSize : d.binCount.rounded(.down)
            g.binUnit = d.bySize ? d.unit : nil
            return g
        }
    }

    /// The group column: text for a list, the source's kind of value for bins.
    static func column(from d: GroupDraft, sourceType: DataType, keeping existing: ModelColumn? = nil) -> ModelColumn {
        let type: DataType
        switch d.mode {
        case .list: type = .text
        case .bins: type = sourceType.isTemporal ? sourceType : .decimal
        }
        var c = existing ?? ModelColumn(name: d.name, dataType: type)
        c.name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        c.dataType = type
        c.summarizeBy = .none
        c.expression = nil
        c.grouping = grouping(from: d)
        return c
    }

    /// - Parameter editing: the group column being edited (its own name is allowed).
    static func problems(_ d: GroupDraft, table: ModelTable, editing: String? = nil, sourceType: DataType) -> [String] {
        var out: [String] = []
        let name = d.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { out.append("Name the group.") }
        else if name.contains("[") || name.contains("]") { out.append("Names can't contain square brackets.") }
        else if editing.map({ ModelDAX.same($0, name) }) != true {
            if table.column(name) != nil { out.append("A column named “\(name)” already exists in \(table.name).") }
            else if table.measure(name) != nil { out.append("“\(name)” is already a measure in \(table.name).") }
        }
        if table.column(d.source) == nil { out.append("The column “\(d.source)” is no longer in \(table.name).") }
        switch d.mode {
        case .list:
            if d.groups.isEmpty { out.append("Create at least one group.") }
            for g in d.groups where g.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Name every group."); break }
            var names = d.groups.map(\.name)
            if d.includeOther {
                if d.otherName.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Name the Other group.") }
                names.append(d.otherName)
            }
            if let dup = ModelNames.firstDuplicate(names) { out.append("Two groups are named “\(dup)”.") }
        case .bins:
            let binnable = sourceType.isNumeric || sourceType == .date || sourceType == .dateTime
            if !binnable { out.append("Only number and date columns can be binned. Use a list group for \(sourceType.displayName.lowercased()) values.") }
            if d.bySize {
                if !(d.binSize > 0) || !d.binSize.isFinite { out.append("Bin size must be greater than zero.") }
                else if d.unit != nil, d.binSize != d.binSize.rounded() { out.append("Bin size must be a whole number of \(d.unit?.rawValue ?? "unit")s.") }
            } else if !(d.binCount >= 1) || !d.binCount.isFinite {
                out.append("The number of bins must be at least 1.")
            }
        }
        return out
    }
}
