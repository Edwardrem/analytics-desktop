import Foundation
import FacetCore

/// What one reader changed about a visual without editing the report: its type, its fields, its sort.
/// Layered over the saved visual in the reading view and kept per user, outside the document.
struct Personalization: Codable, Equatable {
    var type: VisualType?
    var wells: [String: [FieldRef]]?
    var sort: [SortSpec]?
    var isEmpty: Bool { type == nil && wells == nil && sort == nil }
}

enum Personalize {
    /// Chart types a reader can switch between.
    static let offeredTypes: [VisualType] = [
        .clusteredColumn, .stackedColumn, .clusteredBar, .stackedBar, .line, .area,
        .pie, .donut, .treemap, .funnel, .table, .matrix,
    ]

    /// Visuals a reader may personalise: data visuals whose fields make sense in another shape.
    static func canPersonalize(_ type: VisualType) -> Bool {
        if offeredTypes.contains(type) { return true }
        switch type {
        case .stackedBar100, .stackedColumn100, .stackedArea, .stackedArea100, .lineStackedColumn, .lineClusteredColumn,
             .ribbon, .waterfall, .scatter, .dotPlot, .multiRowCard, .card, .cardLegacy, .radar, .heatmap, .sunburst:
            return true
        default: return false
        }
    }

    /// The saved visual with a reader's changes applied.
    static func apply(_ p: Personalization?, to spec: VisualSpec, aggregation: (FieldRef) -> Aggregation = { _ in .sum }) -> VisualSpec {
        guard let p, !p.isEmpty else { return spec }
        var out = spec
        if let type = p.type, type != out.type { VisualRetype.apply(&out, to: type, aggregation: aggregation) }
        if let wells = p.wells {
            // Only wells the (possibly new) type has; an emptied well stays empty.
            out.wells = wells.filter { key, _ in out.type.wells.contains { $0.rawValue == key } }
        }
        if let sort = p.sort { out.sort = sort }
        // Drill state and sorts that name fields no longer in the visual would query nothing.
        let keys = Set(out.allFields.map(\.key))
        out.sort.removeAll { !keys.contains($0.field.key) }
        let levels = out.type == .matrix ? out.fields(.rows).count : out.fields(.category).count
        if out.drillLevel >= max(1, levels) { out.drillLevel = 0; out.drillPath = []; out.expandedAllLevels = false }
        return out
    }

    /// The personalisation after changing the type; choosing the saved type again clears the change.
    static func settingType(_ p: Personalization?, _ type: VisualType, saved: VisualSpec,
                            aggregation: (FieldRef) -> Aggregation = { _ in .sum }) -> Personalization {
        var out = p ?? Personalization()
        // Field edits were made for the previous shape; carry the current fields over to the new one.
        let current = apply(out, to: saved, aggregation: aggregation)
        out.type = type == saved.type ? nil : type
        if out.wells != nil {
            var moved = current
            if moved.type != type { VisualRetype.apply(&moved, to: type, aggregation: aggregation) }
            out.wells = moved.wells
        }
        return out
    }

    /// The personalisation after replacing one well's fields.
    static func settingFields(_ p: Personalization?, well: Well, fields: [FieldRef], saved: VisualSpec,
                              aggregation: (FieldRef) -> Aggregation = { _ in .sum }) -> Personalization {
        var out = p ?? Personalization()
        var wells = out.wells ?? apply(out, to: saved, aggregation: aggregation).wells
        wells[well.rawValue] = fields.isEmpty ? nil : fields
        out.wells = wells
        return out
    }

    /// The personalisation after choosing a sort (nil field = the saved order).
    static func settingSort(_ p: Personalization?, field: FieldRef?, descending: Bool) -> Personalization {
        var out = p ?? Personalization()
        out.sort = field.map { [SortSpec(field: $0, descending: descending)] }
        return out
    }

    /// UserDefaults key under which a document's personalisations are kept; nil for unsaved documents.
    static func storageKey(for url: URL?) -> String? {
        url.map { "personalize:" + $0.standardizedFileURL.path }
    }
    static func encode(_ all: [UUID: Personalization]) -> Data? {
        try? JSONEncoder().encode(all.filter { !$0.value.isEmpty })
    }
    static func decode(_ data: Data?) -> [UUID: Personalization] {
        data.flatMap { try? JSONDecoder().decode([UUID: Personalization].self, from: $0) } ?? [:]
    }
}

/// Changing a visual's type while keeping its fields in the closest wells of the new type.
enum VisualRetype {
    static func apply(_ v: inout VisualSpec, to type: VisualType, aggregation: (FieldRef) -> Aggregation) {
        let old = v.wells
        let groups = v.type.wells.filter(\.isGrouping).flatMap { old[$0.rawValue] ?? [] }
        let values = v.type.wells.filter { !$0.isGrouping && $0 != .tooltips }.flatMap { old[$0.rawValue] ?? [] }
        let tooltips = old[Well.tooltips.rawValue] ?? []
        v.type = type
        v.wells = [:]
        let targetGroups = type.wells.filter(\.isGrouping)
        let targetValues = type.wells.filter { !$0.isGrouping && $0 != .tooltips }
        // Preserve same-named wells first, then spill the rest in order.
        var remainingGroups = groups, remainingValues = values
        for w in type.wells {
            if let f = old[w.rawValue], !f.isEmpty {
                v.wells[w.rawValue] = f
                remainingGroups.removeAll { g in f.contains { $0.id == g.id } }
                remainingValues.removeAll { g in f.contains { $0.id == g.id } }
            }
        }
        if let first = targetGroups.first(where: { v.fields($0).isEmpty }), !remainingGroups.isEmpty {
            v.setFields(first, remainingGroups)
        } else if let first = targetGroups.first, !remainingGroups.isEmpty {
            v.setFields(first, v.fields(first) + remainingGroups)
        }
        if let first = targetValues.first, !remainingValues.isEmpty {
            v.setFields(first, v.fields(first) + remainingValues.map { f in
                var f = f
                if f.kind == .column, f.aggregation == .none, type != .table { f.aggregation = aggregation(f) }
                return f
            })
        }
        if type.wells.contains(.tooltips), !tooltips.isEmpty { v.setFields(.tooltips, tooltips) }
        if v.name == VisualType.allCases.first(where: { $0.displayName == v.name })?.displayName { v.name = type.displayName }
    }
}

/// "See records": the rows behind one data point.
enum SeeRecords {
    static let rowLimit = 1_000

    /// A table of the records behind a visual's values: every visible column of the table its first
    /// summarised column comes from, plus how many identical rows each line stands for. Nil when the
    /// visual shows only measures (a measure has no single table of records).
    static func recordsSpec(for visual: VisualSpec, model: SemanticModel) -> VisualSpec? {
        let summarised = visual.type.wells.filter { !$0.isGrouping }.flatMap { visual.fields($0) }
            .first { $0.kind == .column && $0.aggregation != .none }
        guard let source = summarised, let table = model.table(source.table) else { return nil }
        let columns = table.columns.filter { !$0.isHidden }
        guard let first = columns.first else { return nil }
        var spec = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 900, height: 520), name: "Records")
        var count = FieldRef.column(table.name, first.name, .count)
        count.displayName = "Rows"
        spec.setFields(.values, columns.map { FieldRef.column(table.name, $0.name) } + [count])
        return spec
    }

    /// The data point itself as a table: the visual's own fields, one line.
    static func pointSpec(for visual: VisualSpec) -> VisualSpec {
        var spec = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 900, height: 520), name: "Data point")
        var seen = Set<String>()
        spec.setFields(.values, visual.allFields.filter { seen.insert($0.key).inserted })
        return spec
    }

    /// The query for the records: the visual's own context narrowed to the point.
    static func request(source: VisualRequest, point: DataPointSelection) -> VisualRequest {
        var r = source
        r.crossFilters.append([point])
        r.highlights = []
        r.rowLimit = rowLimit
        return r
    }
}
