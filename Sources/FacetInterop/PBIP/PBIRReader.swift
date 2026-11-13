import Foundation
import FacetCore

/// Derives a stable UUID from an arbitrary object name (Power BI uses 20-character hex names, Facet uses UUIDs).
func stableUUID(from name: String) -> UUID {
    if let u = UUID(uuidString: name) { return u }
    func fnv(_ seed: UInt64) -> UInt64 {
        var h = seed
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01b3 }
        return h
    }
    let a = fnv(0xcbf2_9ce4_8422_2325), b = fnv(0x8422_2325_cbf2_9ce4)
    var bytes = [UInt8](repeating: 0, count: 16)
    for i in 0..<8 { bytes[i] = UInt8((a >> (8 * UInt64(i))) & 0xFF); bytes[8 + i] = UInt8((b >> (8 * UInt64(i))) & 0xFF) }
    bytes[6] = (bytes[6] & 0x0F) | 0x50   // version 5-style, name based
    bytes[8] = (bytes[8] & 0x3F) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                       bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
}

/// Reading PBIR JSON back into FacetCore. For each natively written section the reader checks whether the file still
/// holds exactly what Facet would write for the object saved in the `Facet_*` annotation; if so the saved object is
/// kept verbatim (lossless round trip), otherwise the section was edited externally and is re-read from the JSON.
extension PBIR {
    // MARK: Shared pieces

    static func parseFilters(_ config: JSONValue?, warnings: inout [ImportWarning], location: String) -> (filters: [FilterSpec], drillthrough: [FilterSpec]) {
        var normal: [FilterSpec] = [], drill: [FilterSpec] = []
        for entry in config?["filters"]?.arrayValue ?? [] {
            guard let f = PBIExpr.parseFilterEntry(entry, warnings: &warnings, location: location) else { continue }
            let how = entry["howCreated"]
            if how?.stringValue == "Drillthrough" || how?.intValue == 2 { drill.append(f) } else { normal.append(f) }
        }
        return (normal, drill)
    }

    static func parseQueryState(_ state: JSONValue?, type: VisualType, warnings: inout [ImportWarning], location: String) -> [String: [FieldRef]] {
        var wells: [String: [FieldRef]] = [:]
        for (role, body) in (state?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            var fields: [FieldRef] = []
            for p in body["projections"]?.arrayValue ?? [] {
                guard var f = PBIExpr.parseField(p["field"]) else {
                    warnings.append(ImportWarning("A field in role “\(role)” uses an unsupported expression and was skipped.", location: location))
                    continue
                }
                if let d = p["displayName"]?.stringValue { f.displayName = d }
                if p["hidden"]?.boolValue == true { f.isHidden = true }
                fields.append(f)
            }
            guard !fields.isEmpty else { continue }
            let key = PowerBIMapping.well(forRole: role, in: type)?.rawValue
                ?? Well.allCases.first { PowerBIMapping.defaultRole($0) == role }?.rawValue
            guard let key else {
                warnings.append(ImportWarning("Data role “\(role)” has no equivalent in a \(type.displayName); its fields were skipped.", location: location))
                continue
            }
            wells[key, default: []] += fields
        }
        return wells
    }

    static func parseSort(_ def: JSONValue?) -> [SortSpec] {
        (def?["sort"]?.arrayValue ?? []).compactMap { s in
            PBIExpr.parseField(s["field"]).map { SortSpec(field: $0, descending: s["direction"]?.stringValue != "Ascending") }
        }
    }

    static func text(fromParagraphs p: JSONValue?) -> String? {
        guard let paragraphs = p?.arrayValue else { return nil }
        return paragraphs.map { para in
            (para["textRuns"]?.arrayValue ?? []).compactMap { $0["value"]?.stringValue }.joined()
        }.joined(separator: "\n")
    }

    static func frame(_ pos: JSONValue?, fallback: Frame = Frame(x: 0, y: 0, width: 300, height: 200)) -> Frame {
        var f = Frame(x: pos?["x"]?.doubleValue ?? fallback.x, y: pos?["y"]?.doubleValue ?? fallback.y,
                      width: pos?["width"]?.doubleValue ?? fallback.width, height: pos?["height"]?.doubleValue ?? fallback.height)
        f.rotation = pos?["angle"]?.doubleValue ?? 0
        return f
    }

    // MARK: Visual

    /// Reads a `visual.json`. Returns nil for visual groups (which have no `visual`).
    static func readVisual(_ j: JSONValue, mobile: JSONValue?, warnings: inout [ImportWarning], location: String) -> VisualSpec? {
        guard let visual = j["visual"] else { return nil }
        let pbiType = visual["visualType"]?.stringValue ?? ""
        let saved = annotation(j, Annotation.visual).flatMap { try? $0.decode(VisualSpec.self) }
        let expected = saved.map { visualJSON($0, includeAnnotations: false) }

        var spec: VisualSpec
        if let saved, expected?["visual"]?["visualType"]?.stringValue == pbiType {
            spec = saved
        } else {
            let type: VisualType
            if let t = PowerBIMapping.facetType(forPowerBI: pbiType) { type = t }
            else {
                type = visual["query"]?["queryState"]?.objectValue?.isEmpty == false ? .table : .shape
                warnings.append(ImportWarning("Visual type “\(pbiType)” isn't supported; it was imported as a \(type.displayName.lowercased()).", location: location))
            }
            if var s = saved { s.type = type; spec = s } else { spec = VisualSpec(type: type, frame: frame(j["position"])) }
            if saved == nil, pbiType.hasPrefix(PowerBIMapping.facetPrefix) {
                warnings.append(ImportWarning("Facet visual “\(pbiType)” lost its Facet annotation; only fields and position were recovered.", location: location))
            }
        }
        if let n = j["name"]?.stringValue { spec.id = stableUUID(from: n) }

        if expected?["position"] != j["position"] {
            spec.frame = frame(j["position"], fallback: spec.frame)
            spec.zIndex = j["position"]?["z"]?.intValue ?? spec.zIndex
            spec.tabOrder = j["position"]?["tabOrder"]?.intValue ?? spec.tabOrder
        }
        let query = visual["query"]
        if expected?["visual"]?["query"]?["queryState"] != query?["queryState"] {
            spec.wells = parseQueryState(query?["queryState"], type: spec.type, warnings: &warnings, location: location)
        }
        if expected?["visual"]?["query"]?["sortDefinition"] != query?["sortDefinition"] {
            spec.sort = parseSort(query?["sortDefinition"])
        }
        if expected?["visual"]?["objects"] != visual["objects"] || expected?["visual"]?["visualContainerObjects"] != visual["visualContainerObjects"] {
            var bag = PBIExpr.parseObjects([visual["objects"], visual["visualContainerObjects"]], skipping: ["general.altText", "general.paragraphs"])
            // Keep saved values Power BI can't express (arrays, nested objects); they were never in the file.
            for (card, props) in saved?.format ?? [:] {
                for (k, v) in props where k != PBIExpr.selectorsKey && PBIExpr.objectValue(v) == nil { bag[card, default: [:]][k] = v }
            }
            spec.format = bag
            let general = visual["visualContainerObjects"]?["general"]?[0]?["properties"]
            spec.altText = general?["altText"].map(PBIExpr.parseObjectValue)?.stringValue ?? ""
            if spec.type == .textBox {
                let paragraphs = (visual["objects"]?["general"]?.arrayValue ?? []).compactMap { $0["properties"]?["paragraphs"] }.first
                if let t = text(fromParagraphs: paragraphs) { spec.content = t }
            }
        }
        if expected?["filterConfig"] != j["filterConfig"] {
            spec.filters = parseFilters(j["filterConfig"], warnings: &warnings, location: location).filters
        }
        spec.isHidden = j["isHidden"]?.boolValue ?? false
        spec.groupID = j["parentGroupName"]?.stringValue.map(stableUUID)
        if let mobile, let pos = mobile["position"] {
            let f = frame(pos)
            if spec.mobileFrame.map({ $0.x != f.x || $0.y != f.y || $0.width != f.width || $0.height != f.height }) ?? true { spec.mobileFrame = f }
        } else if saved != nil { spec.mobileFrame = nil }
        if saved == nil {
            spec.name = spec.fmtString("title", "text", spec.type.displayName)
        }
        return spec
    }

    // MARK: Page

    static func readBackground(_ list: JSONValue?) -> BackgroundSpec {
        var b = BackgroundSpec()
        let props = list?[0]?["properties"]
        b.color = props?["color"].map(PBIExpr.parseObjectValue)?.stringValue
        b.transparency = props?["transparency"].map(PBIExpr.parseObjectValue)?.doubleValue ?? 0
        return b
    }

    static func readPage(_ j: JSONValue, visuals: [VisualSpec], groups: [UUID: String], warnings: inout [ImportWarning], location: String) -> Page {
        let saved = annotation(j, Annotation.page).flatMap { try? $0.decode(Page.self) }
        let expected = saved.map { pageJSON($0, includeAnnotations: false) }
        var p = saved ?? Page(name: j["displayName"]?.stringValue ?? "Page")
        if let n = j["name"]?.stringValue { p.id = stableUUID(from: n) }
        p.name = j["displayName"]?.stringValue ?? p.name
        if let w = j["width"]?.doubleValue, let h = j["height"]?.doubleValue { p.size = PageSize(width: w, height: h) }
        p.isHidden = j["visibility"]?.stringValue == "HiddenInViewMode"
        if expected?["filterConfig"] != j["filterConfig"] {
            let parsed = parseFilters(j["filterConfig"], warnings: &warnings, location: location)
            p.filters = parsed.filters
            p.drillthroughFilters = parsed.drillthrough
        }
        if expected?["pageBinding"] != j["pageBinding"] {
            let binding = j["pageBinding"]
            p.isTooltipPage = binding?["type"]?.stringValue == "Tooltip" || j["type"]?.stringValue == "Tooltip"
            p.allowCrossReportDrillthrough = binding?["referenceScope"]?.stringValue == "CrossReport"
            p.keepAllFiltersOnDrillthrough = binding?["acceptsFilterContext"]?.stringValue != "None"
        }
        if expected?["objects"] != j["objects"] {
            let bg = readBackground(j["objects"]?["background"]), wp = readBackground(j["objects"]?["outspace"])
            p.background.color = bg.color; p.background.transparency = bg.transparency
            p.wallpaper.color = wp.color; p.wallpaper.transparency = wp.transparency
        }
        if expected?["visualInteractions"] != j["visualInteractions"] {
            var map: [UUID: [UUID: InteractionMode]] = [:]
            for i in j["visualInteractions"]?.arrayValue ?? [] {
                guard let s = i["source"]?.stringValue, let t = i["target"]?.stringValue else { continue }
                let mode: InteractionMode
                switch i["type"]?.stringValue {
                case "DataFilter": mode = .filter
                case "NoFilter": mode = .none
                default: mode = .highlight
                }
                map[stableUUID(from: s), default: [:]][stableUUID(from: t)] = mode
            }
            p.interactions = map
        }
        p.visuals = visuals
        if p.groups != groups { p.groups = groups }
        p.hasMobileLayout = saved?.hasMobileLayout ?? visuals.contains { $0.mobileFrame != nil }
        return p
    }

    // MARK: Bookmark

    static func readBookmark(_ j: JSONValue, group: String, warnings: inout [ImportWarning], location: String) -> Bookmark {
        let saved = annotation(j, Annotation.bookmark).flatMap { try? $0.decode(Bookmark.self) }
        let expected = saved.map { bookmarkJSON($0, includeAnnotations: false) }
        let state = j["explorationState"]
        let page = state?["activeSection"]?.stringValue.map(stableUUID) ?? saved?.pageID ?? UUID()
        var b = saved ?? Bookmark(name: j["displayName"]?.stringValue ?? "Bookmark", pageID: page)
        if let n = j["name"]?.stringValue { b.id = stableUUID(from: n) }
        b.name = j["displayName"]?.stringValue ?? b.name
        b.pageID = page
        b.group = group
        if expected?["options"] != j["options"] {
            let o = j["options"]
            b.appliesData = o?["suppressData"]?.boolValue != true
            b.appliesDisplay = o?["suppressDisplay"]?.boolValue != true
            b.appliesCurrentPage = o?["suppressActiveSection"]?.boolValue != true
            b.selectedVisualIDs = o?["applyOnlyToTargetVisuals"]?.boolValue == true
                ? (o?["targetVisualNames"]?.arrayValue ?? []).compactMap { $0.stringValue.map(stableUUID) } : nil
        }
        if expected?["explorationState"]?["sections"] != state?["sections"] {
            var hidden: [UUID] = []
            for (_, section) in (state?["sections"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
                for (name, vc) in (section["visualContainers"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key })
                where vc["singleVisual"]?["display"]?["mode"]?.stringValue == "hidden" {
                    hidden.append(stableUUID(from: name))
                }
            }
            b.state.hiddenVisuals = hidden
            if saved == nil, state?["filters"] != nil || (state?["sections"]?.objectValue ?? [:]).values.contains(where: { $0["filters"] != nil }) {
                warnings.append(ImportWarning("Bookmark “\(b.name)”: captured filter and slicer state isn't imported; only page, visibility and options are.",
                                              severity: .info, location: location))
            }
        }
        return b
    }

    // MARK: Report

    static func readSettings(_ j: JSONValue?, into s: inout ReportSettings) {
        guard let j else { return }
        switch j["exportDataMode"]?.stringValue {
        case "None": s.allowExportData = "none"
        case "AllowSummarizedAndUnderlying": s.allowExportData = "underlying"
        case .some: s.allowExportData = "summarized"
        case nil: break
        }
        if let v = j["hideVisualContainerHeader"]?.boolValue { s.hideVisualHeaders = v }
        if let v = j["useCrossReportDrillthrough"]?.boolValue { s.crossReportDrillthrough = v }
        if let v = j["allowChangeFilterTypes"]?.boolValue { s.allowChangeFilterTypes = v }
        if let v = j["isPersistentUserStateDisabled"]?.boolValue { s.persistentFilters = !v }
        if let v = j["defaultFilterActionIsDataFilter"]?.boolValue {
            if v { s.defaultInteraction = .filter } else if s.defaultInteraction == .filter { s.defaultInteraction = .highlight }
        }
        if let v = j["useEnhancedTooltips"]?.boolValue { s.modernTooltips = v }
        if let v = j["allowInlineExploration"]?.boolValue { s.allowPersonalizeVisuals = v }
        if let v = j["filterPaneHiddenInEditMode"]?.boolValue { s.filterPaneVisibleToReaders = !v }
    }

    /// Reads `report.json` (without pages and bookmarks). `resource` loads a registered resource by file name.
    static func readReport(_ j: JSONValue, resource: (String) -> Data?, warnings: inout [ImportWarning]) -> (report: Report, bookmarkOrder: [UUID]?, dataSources: [DataSourceRecord]) {
        let savedJSON = annotation(j, Annotation.report)
        let saved = savedJSON.flatMap { try? $0.decode(Report.self) }
        var r = saved ?? Report()
        r.pages = []
        r.bookmarks = []
        if settings(r.settings) != j["settings"] { readSettings(j["settings"], into: &r.settings) }
        if filterConfig(r.filters) != j["filterConfig"] {
            r.filters = parseFilters(j["filterConfig"], warnings: &warnings, location: "report.json").filters
        }
        if let themeName = j["themeCollection"]?["customTheme"]?["name"]?.stringValue {
            if let data = resource(themeName), let fileJSON = try? JSONValue.parse(data) {
                if saved == nil || PowerBITheme.json(r.theme, includeFacetExtensions: true) != fileJSON {
                    if let (theme, w) = try? PowerBITheme.importTheme(from: data) {
                        r.theme = theme
                        warnings += w.map { ImportWarning($0.message, severity: $0.severity, location: "theme \(themeName)") }
                    }
                }
            } else {
                warnings.append(ImportWarning("The report's custom theme “\(themeName)” is missing; the default theme is used.", location: "report.json"))
            }
        }
        let order = savedJSON?["bookmarkOrder"]?.arrayValue?.compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) }
        let sources = annotation(j, Annotation.dataSources).flatMap { try? $0.decode([DataSourceRecord].self) } ?? []
        return (r, order, sources)
    }
}
