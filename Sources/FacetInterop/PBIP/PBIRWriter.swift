import Foundation
import FacetCore

/// Builds the PBIR (enhanced report format) JSON documents for a Facet report.
/// Everything Power BI can represent is written natively; the full Facet object also rides along in a
/// `Facet_*` annotation so that Facet reads back exactly what it wrote.
enum PBIR {
    static let schemaBase = "https://developer.microsoft.com/json-schemas/fabric/item/report/definition/"
    static func schema(_ name: String, _ version: String = "1.0.0") -> JSONValue { js("\(schemaBase)\(name)/\(version)/schema.json") }

    enum Annotation {
        static let visual = "Facet_visual", page = "Facet_page", bookmark = "Facet_bookmark", report = "Facet_report"
        static let dataSources = "Facet_dataSources"
    }

    static func annotations(_ pairs: [(String, JSONValue)]) -> JSONValue {
        ja(pairs.map { jo(["name": js($0.0), "value": js($0.1.compactString)]) })
    }
    static func annotation(_ j: JSONValue, _ name: String) -> JSONValue? {
        guard let text = j["annotations"]?.arrayValue?.first(where: { $0["name"]?.stringValue == name })?["value"]?.stringValue else { return nil }
        return try? JSONValue.parse(text)
    }

    // MARK: Visual

    static func position(_ f: Frame, z: Int, tabOrder: Int) -> JSONValue {
        var o: [String: JSONValue] = ["x": jn(f.x), "y": jn(f.y), "z": jn(z), "width": jn(f.width), "height": jn(f.height), "tabOrder": jn(tabOrder)]
        if f.rotation != 0 { o["angle"] = jn(f.rotation) }
        return .object(o)
    }

    /// `query.queryState`: role → projections.
    static func queryState(_ v: VisualSpec) -> JSONValue? {
        var state: [String: JSONValue] = [:]
        let roleMap = PowerBIMapping.roles(for: v.type)
        var handled = Set<String>()
        func projections(_ fields: [FieldRef], grouping: Bool) -> JSONValue {
            jo(["projections": ja(fields.map { f in
                var p: [String: JSONValue] = ["field": PBIExpr.field(f), "queryRef": js(PBIExpr.queryRef(f)), "nativeQueryRef": js(PBIExpr.nativeQueryRef(f))]
                if let d = f.displayName, !d.isEmpty { p["displayName"] = js(d) }
                if f.isHidden { p["hidden"] = jb(true) }
                if grouping { p["active"] = jb(true) }
                return .object(p)
            })])
        }
        for (well, role) in roleMap {
            handled.insert(well.rawValue)
            let fields = v.fields(well)
            if !fields.isEmpty { state[role] = projections(fields, grouping: well.isGrouping) }
        }
        // Wells the visual type doesn't declare are still written so nothing silently disappears.
        for (key, fields) in v.wells where !handled.contains(key) && !fields.isEmpty {
            state[Well(rawValue: key).map(PowerBIMapping.defaultRole) ?? key] = projections(fields, grouping: false)
        }
        return state.isEmpty ? nil : .object(state)
    }

    static func sortDefinition(_ sort: [SortSpec]) -> JSONValue? {
        guard !sort.isEmpty else { return nil }
        return jo(["sort": ja(sort.map { jo(["field": PBIExpr.field($0.field), "direction": js($0.descending ? "Descending" : "Ascending")]) }),
                   "isDefaultSort": jb(false)])
    }

    static func filterConfig(_ filters: [FilterSpec], drillthrough: [FilterSpec] = []) -> JSONValue? {
        let all = filters.map { PBIExpr.filterEntry($0) } + drillthrough.map { PBIExpr.filterEntry($0, drillthrough: true) }
        return all.isEmpty ? nil : jo(["filters": ja(all)])
    }

    /// Text box content as PBIR paragraphs (one per line).
    static func paragraphs(_ text: String) -> JSONValue {
        ja(text.components(separatedBy: "\n").map { jo(["textRuns": ja([jo(["value": js($0)])])]) })
    }

    static func visualJSON(_ v: VisualSpec, includeAnnotations: Bool) -> JSONValue {
        var visual: [String: JSONValue] = ["visualType": js(PowerBIMapping.powerBIType(for: v.type))]
        var query: [String: JSONValue] = [:]
        if let qs = queryState(v) { query["queryState"] = qs }
        if let s = sortDefinition(v.sort) { query["sortDefinition"] = s }
        if !query.isEmpty { visual["query"] = .object(query) }

        let (objects, container) = PBIExpr.objects(v.format)
        var inner = objects?.objectValue ?? [:]
        if v.type == .textBox, !v.content.isEmpty {
            var general = inner["general"]?.arrayValue ?? []
            general.append(jo(["properties": jo(["paragraphs": paragraphs(v.content)])]))
            inner["general"] = ja(general)
        }
        if !inner.isEmpty { visual["objects"] = .object(inner) }
        var outer = container?.objectValue ?? [:]
        if !v.altText.isEmpty {
            outer["general"] = ja([jo(["properties": jo(["altText": jo(["expr": PBIExpr.literalExpr(.string(v.altText))])])])])
        }
        if !outer.isEmpty { visual["visualContainerObjects"] = .object(outer) }
        visual["drillFilterOtherVisuals"] = jb(true)

        var root: [String: JSONValue] = [
            "$schema": schema("visualContainer"), "name": js(v.id.lower),
            "position": position(v.frame, z: v.zIndex, tabOrder: v.tabOrder), "visual": .object(visual),
        ]
        if let fc = filterConfig(v.filters) { root["filterConfig"] = fc }
        if v.isHidden { root["isHidden"] = jb(true) }
        if let g = v.groupID { root["parentGroupName"] = js(g.lower) }
        if includeAnnotations, let spec = try? JSONValue(encoding: v) { root["annotations"] = annotations([(Annotation.visual, spec)]) }
        return .object(root)
    }

    static func groupJSON(id: UUID, name: String, members: [VisualSpec]) -> JSONValue {
        let minX = members.map(\.frame.x).min() ?? 0, minY = members.map(\.frame.y).min() ?? 0
        let maxX = members.map { $0.frame.x + $0.frame.width }.max() ?? 0, maxY = members.map { $0.frame.y + $0.frame.height }.max() ?? 0
        return jo(["$schema": schema("visualContainer"), "name": js(id.lower),
                   "position": position(Frame(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                                        z: members.map(\.zIndex).min() ?? 0, tabOrder: members.map(\.tabOrder).min() ?? 0),
                   "visualGroup": jo(["displayName": js(name), "groupMode": js("ScaleMode")])])
    }

    static func mobileJSON(_ f: Frame, z: Int) -> JSONValue {
        jo(["$schema": schema("visualContainerMobileState"),
            "position": jo(["x": jn(f.x), "y": jn(f.y), "z": jn(z), "width": jn(f.width), "height": jn(f.height)])])
    }

    // MARK: Page

    static func backgroundProperties(_ b: BackgroundSpec) -> JSONValue? {
        var props: [String: JSONValue] = [:]
        if let c = b.color, let e = PBIExpr.objectValue(.string(c)) { props["color"] = e }
        if b.transparency != 0, let e = PBIExpr.objectValue(.number(b.transparency)) { props["transparency"] = e }
        return props.isEmpty ? nil : ja([jo(["properties": .object(props)])])
    }

    static func interactionName(_ m: InteractionMode) -> String {
        switch m { case .filter: return "DataFilter"; case .highlight: return "HighlightFilter"; case .none: return "NoFilter" }
    }

    static func pageJSON(_ p: Page, includeAnnotations: Bool) -> JSONValue {
        var root: [String: JSONValue] = [
            "$schema": schema("page"), "name": js(p.id.lower), "displayName": js(p.name),
            "displayOption": js("FitToPage"), "width": jn(p.size.width), "height": jn(p.size.height),
        ]
        if p.isHidden { root["visibility"] = js("HiddenInViewMode") }
        if p.isTooltipPage {
            root["pageBinding"] = jo(["name": js("Pod" + p.id.lower.replacingOccurrences(of: "-", with: "").prefix(12)), "type": js("Tooltip")])
        } else if p.isDrillthroughPage {
            root["pageBinding"] = jo(["name": js("Pod" + p.id.lower.replacingOccurrences(of: "-", with: "").prefix(12)), "type": js("Drillthrough"),
                                      "referenceScope": js(p.allowCrossReportDrillthrough ? "CrossReport" : "Default"),
                                      "acceptsFilterContext": js(p.keepAllFiltersOnDrillthrough ? "Default" : "None")])
        }
        if let fc = filterConfig(p.filters, drillthrough: p.drillthroughFilters) { root["filterConfig"] = fc }
        var objects: [String: JSONValue] = [:]
        if let b = backgroundProperties(p.background) { objects["background"] = b }
        if let w = backgroundProperties(p.wallpaper) { objects["outspace"] = w }
        if !objects.isEmpty { root["objects"] = .object(objects) }
        var interactions: [JSONValue] = []
        for (source, targets) in p.interactions.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for (target, mode) in targets.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                interactions.append(jo(["source": js(source.lower), "target": js(target.lower), "type": js(interactionName(mode))]))
            }
        }
        if !interactions.isEmpty { root["visualInteractions"] = ja(interactions) }
        if includeAnnotations {
            var shell = p
            shell.visuals = []
            if var j = (try? JSONValue(encoding: shell))?.objectValue {
                j["visualOrder"] = ja(p.visuals.map { js($0.id.lower) })
                root["annotations"] = annotations([(Annotation.page, .object(j))])
            }
        }
        return .object(root)
    }

    // MARK: Bookmarks

    static func bookmarkJSON(_ b: Bookmark, includeAnnotations: Bool) -> JSONValue {
        var options: [String: JSONValue] = [:]
        if !b.appliesData { options["suppressData"] = jb(true) }
        if !b.appliesDisplay { options["suppressDisplay"] = jb(true) }
        if !b.appliesCurrentPage { options["suppressActiveSection"] = jb(true) }
        if let ids = b.selectedVisualIDs {
            options["applyOnlyToTargetVisuals"] = jb(true)
            options["targetVisualNames"] = ja(ids.map { js($0.lower) })
        }
        var containers: [String: JSONValue] = [:]
        for id in b.state.hiddenVisuals { containers[id.lower] = jo(["singleVisual": jo(["display": jo(["mode": js("hidden")])])]) }
        var section: [String: JSONValue] = [:]
        if !containers.isEmpty { section["visualContainers"] = .object(containers) }
        var root: [String: JSONValue] = [
            "$schema": schema("bookmark"), "name": js(b.id.lower), "displayName": js(b.name),
            "explorationState": jo(["version": js("1.3"), "activeSection": js(b.pageID.lower),
                                    "sections": jo([b.pageID.lower: .object(section)])]),
        ]
        if !options.isEmpty { root["options"] = .object(options) }
        if includeAnnotations, let j = try? JSONValue(encoding: b) { root["annotations"] = annotations([(Annotation.bookmark, j)]) }
        return .object(root)
    }

    static func groupName(_ group: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in group.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return "group" + String(h, radix: 16)
    }

    /// `bookmarks.json`: bookmark order with named groups.
    static func bookmarksIndex(_ bookmarks: [Bookmark]) -> JSONValue {
        var items: [JSONValue] = []
        var groupIndex: [String: Int] = [:]
        for b in bookmarks {
            if b.group.isEmpty { items.append(jo(["name": js(b.id.lower)])); continue }
            if let i = groupIndex[b.group] {
                var o = items[i].objectValue ?? [:]
                o["children"] = ja((o["children"]?.arrayValue ?? []) + [js(b.id.lower)])
                items[i] = .object(o)
            } else {
                groupIndex[b.group] = items.count
                items.append(jo(["name": js(groupName(b.group)), "displayName": js(b.group), "children": ja([js(b.id.lower)])]))
            }
        }
        return jo(["$schema": schema("bookmarksMetadata"), "items": ja(items)])
    }

    // MARK: Report

    static func settings(_ s: ReportSettings) -> JSONValue {
        let export: String
        switch s.allowExportData {
        case "none": export = "None"
        case "underlying": export = "AllowSummarizedAndUnderlying"
        default: export = "AllowSummarized"
        }
        return jo([
            "useStylableVisualContainerHeader": jb(true), "exportDataMode": js(export),
            "hideVisualContainerHeader": jb(s.hideVisualHeaders), "useCrossReportDrillthrough": jb(s.crossReportDrillthrough),
            "allowChangeFilterTypes": jb(s.allowChangeFilterTypes), "isPersistentUserStateDisabled": jb(!s.persistentFilters),
            "defaultFilterActionIsDataFilter": jb(s.defaultInteraction == .filter), "useEnhancedTooltips": jb(s.modernTooltips),
            "allowInlineExploration": jb(s.allowPersonalizeVisuals), "filterPaneHiddenInEditMode": jb(!s.filterPaneVisibleToReaders),
        ])
    }

    static func reportJSON(_ doc: FacetDocument, themeFile: String, includeAnnotations: Bool) -> JSONValue {
        let r = doc.report
        var root: [String: JSONValue] = [
            "$schema": schema("report"),
            "themeCollection": jo([
                "baseTheme": jo(["name": js("CY24SU10"), "reportVersionAtImport": js("5.61"), "type": js("SharedResources")]),
                "customTheme": jo(["name": js(themeFile), "reportVersionAtImport": js("5.61"), "type": js("RegisteredResources")]),
            ]),
            "resourcePackages": ja([jo(["name": js("RegisteredResources"), "type": js("RegisteredResources"),
                                        "items": ja([jo(["name": js(themeFile), "path": js(themeFile), "type": js("CustomTheme")])])])]),
            "settings": settings(r.settings),
        ]
        if let fc = filterConfig(r.filters) { root["filterConfig"] = fc }
        if includeAnnotations {
            var shell = r
            shell.pages = []
            shell.bookmarks = []
            var pairs: [(String, JSONValue)] = []
            if var j = (try? JSONValue(encoding: shell))?.objectValue {
                j["bookmarkOrder"] = ja(r.bookmarks.map { js($0.id.lower) })
                pairs.append((Annotation.report, .object(j)))
            }
            if !doc.dataSources.isEmpty, let j = try? JSONValue(encoding: doc.dataSources) { pairs.append((Annotation.dataSources, j)) }
            root["annotations"] = annotations(pairs)
        }
        return .object(root)
    }
}
