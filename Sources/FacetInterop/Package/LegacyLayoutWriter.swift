import Foundation
import FacetCore

/// Writes a report as the legacy `Report/Layout` JSON that `.pbix` and `.pbit` packages carry.
/// The inverse of `LegacyReportLayout.convert`: sections, visual containers with their position,
/// and each visual's projections (by data role), prototype query, sort, formatting and filters.
enum LegacyLayoutWriter {
    static func layout(_ report: Report) -> JSONValue {
        jo([
            "id": jn(0),
            "resourcePackages": ja([]),
            "config": js(text(jo(["version": js("5.43"), "themeCollection": jo([:]), "activeSectionIndex": jn(0)]))),
            "layoutOptimization": jn(0),
            "filters": js(filterText(report.filters)),
            "sections": ja(report.pages.enumerated().map { section($1, ordinal: $0) }),
        ])
    }

    private static func text(_ j: JSONValue) -> String { String(decoding: j.serialized(pretty: false), as: UTF8.self) }

    private static func filterText(_ filters: [FilterSpec]) -> String {
        text(ja(filters.map { PBIExpr.filterEntry($0) }))
    }

    private static func section(_ page: Page, ordinal: Int) -> JSONValue {
        jo([
            "name": js("ReportSection" + page.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20)),
            "displayName": js(page.name),
            "ordinal": jn(ordinal),
            "displayOption": jn(1),
            "width": jn(page.size.width), "height": jn(page.size.height),
            "config": js(page.isHidden ? text(jo(["visibility": jn(1)])) : "{}"),
            "filters": js(filterText(page.filters)),
            "visualContainers": ja(page.visuals.map(container)),
        ])
    }

    private static func container(_ v: VisualSpec) -> JSONValue {
        jo([
            "x": jn(v.frame.x), "y": jn(v.frame.y), "z": jn(v.zIndex), "width": jn(v.frame.width), "height": jn(v.frame.height),
            "config": js(text(config(v))),
            "filters": js(filterText(v.filters)),
        ])
    }

    static func config(_ v: VisualSpec) -> JSONValue {
        var visual: [String: JSONValue] = ["visualType": js(PowerBIMapping.powerBIType(for: v.type)), "drillFilterOtherVisuals": jb(true)]

        // One query source alias per table, in first-use order.
        var aliases: [String: String] = [:]
        var from: [JSONValue] = []
        var select: [JSONValue] = []
        var selected: Set<String> = []
        var projections: [String: JSONValue] = [:]
        func alias(_ table: String) -> String {
            if let a = aliases[table] { return a }
            let stem = table.lowercased().first.map { $0.isLetter ? String($0) : "t" } ?? "t"
            var candidate = stem, n = 1
            while aliases.values.contains(candidate) { candidate = "\(stem)\(n)"; n += 1 }
            aliases[table] = candidate
            from.append(jo(["Name": js(candidate), "Entity": js(table), "Type": jn(0)]))
            return candidate
        }
        for (well, role) in PowerBIMapping.roles(for: v.type) {
            let fields = v.fields(well)
            guard !fields.isEmpty else { continue }
            projections[role] = ja(fields.map { f in
                let ref = PBIExpr.queryRef(f)
                if selected.insert(ref).inserted, var entry = PBIExpr.field(f, alias: alias(f.table)).objectValue {
                    entry["Name"] = js(ref)
                    select.append(.object(entry))
                }
                return jo(["queryRef": js(ref)])
            })
        }
        if !projections.isEmpty {
            visual["projections"] = .object(projections)
            visual["prototypeQuery"] = jo(["Version": jn(2), "From": ja(from), "Select": ja(select)])
        }
        if !v.sort.isEmpty {
            visual["sortDefinition"] = jo(["sort": ja(v.sort.map { s in
                jo(["field": PBIExpr.field(s.field, alias: aliases[s.field.table]), "direction": jn(s.descending ? 2 : 1)])
            })])
        }
        let (objects, containerObjects) = PBIExpr.objects(v.format)
        var inner = objects?.objectValue ?? [:]
        if v.type == .textBox, !v.content.isEmpty {
            inner["general"] = ja([jo(["properties": jo(["paragraphs": PBIR.paragraphs(v.content)])])])
        }
        if !inner.isEmpty { visual["objects"] = .object(inner) }
        if let c = containerObjects { visual["vcObjects"] = c }

        let position = jo(["x": jn(v.frame.x), "y": jn(v.frame.y), "z": jn(v.zIndex), "width": jn(v.frame.width), "height": jn(v.frame.height)])
        return jo(["name": js(v.id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(20).description),
                   "layouts": ja([jo(["id": jn(0), "position": position])]),
                   "singleVisual": .object(visual)])
    }
}
