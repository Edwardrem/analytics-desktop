import Foundation
import FacetCore

/// Imports and exports Power BI report theme JSON as `ThemeSpec`.
public enum PowerBITheme {
    /// Key of the optional block holding properties only Facet understands (ignored by other tools).
    public static let facetExtensionKey = "facet"

    static let textClasses: [(String, WritableKeyPath<ThemeSpec, TextStyle>)] = [
        ("callout", \.callout), ("title", \.title), ("header", \.header), ("label", \.label),
    ]

    /// Reads a Power BI theme. Unknown keys are ignored; invalid colours are skipped; both are reported as warnings.
    public static func importTheme(from data: Data) throws -> (ThemeSpec, [ImportWarning]) {
        let j = try JSONValue.parse(data)
        guard let root = j.objectValue else { throw InteropError.invalidFormat("A theme file must be a JSON object.") }
        var warnings: [ImportWarning] = []
        func color(_ key: String) -> String? {
            guard let v = root[key] else { return nil }
            guard let s = v.stringValue, PBIExpr.isHexColor(s) else {
                warnings.append(ImportWarning("“\(key)” is not a valid colour (expected #RGB, #RRGGBB or #RRGGBBAA); ignored.", location: key))
                return nil
            }
            return s
        }
        var colors: [String] = []
        for (i, c) in (root["dataColors"]?.arrayValue ?? []).enumerated() {
            if let s = c.stringValue, PBIExpr.isHexColor(s) { colors.append(s) }
            else { warnings.append(ImportWarning("dataColors[\(i)] is not a valid colour; skipped.", location: "dataColors")) }
        }
        if colors.isEmpty {
            colors = ThemeSpec.facet.dataColors
            warnings.append(ImportWarning("The theme defines no data colours; Facet's default palette is used.", severity: .info, location: "dataColors"))
        }
        var t = ThemeSpec(name: root["name"]?.stringValue ?? "Imported theme", dataColors: colors)
        if root["name"]?.stringValue == nil { warnings.append(ImportWarning("The theme has no name.", severity: .info, location: "name")) }

        // Structural colours: modern names first, then the legacy "level" names.
        if let c = color("foreground") ?? color("firstLevelElements") { t.foreground = c }
        if let c = color("foregroundNeutralSecondary") ?? color("secondLevelElements") { t.secondaryForeground = c }
        if let c = color("background") { t.cardBackground = c; t.background = c }
        if let c = color("backgroundLight") ?? color("secondaryBackground") ?? color("thirdLevelElements") { t.gridline = c }
        if let c = color("tableAccent") ?? color("accent") { t.accent = c }
        if let c = color("good") { t.good = c }
        if let c = color("neutral") { t.neutral = c }
        if let c = color("bad") { t.bad = c }
        if let c = color("maximum") { t.maximum = c }
        if let c = color("center") { t.center = c }
        if let c = color("minimum") { t.minimum = c }

        // Text classes.
        for (name, cls) in root["textClasses"]?.objectValue ?? [:] {
            guard let kp = textClasses.first(where: { $0.0 == name })?.1 else {
                warnings.append(ImportWarning("Text class “\(name)” has no Facet equivalent; ignored.", severity: .info, location: "textClasses"))
                continue
            }
            var style = t[keyPath: kp]
            if let size = cls["fontSize"]?.doubleValue { style.size = size }
            if let face = cls["fontFace"]?.stringValue {
                style.fontFamily = face
                let l = face.lowercased()
                style.weight = l.contains("semibold") ? "semibold" : l.contains("bold") ? "bold" : l.contains("light") ? "light"
                    : l.contains("medium") ? "medium" : "regular"
            }
            if let c = cls["color"] {
                if let s = c.stringValue, PBIExpr.isHexColor(s) { style.color = s }
                else { warnings.append(ImportWarning("textClasses.\(name).color is not a valid colour; ignored.", location: "textClasses")) }
            }
            t[keyPath: kp] = style
        }

        // Visual styles → per-type default format bags.
        for (pbiType, styles) in root["visualStyles"]?.objectValue ?? [:] {
            let key = pbiType == "*" ? "*" : PowerBIMapping.facetType(forPowerBI: pbiType)?.rawValue ?? pbiType
            for (styleName, cards) in styles.objectValue ?? [:] {
                guard styleName == "*" else {
                    warnings.append(ImportWarning("Style preset “\(styleName)” for \(pbiType) is not supported; ignored.", severity: .info, location: "visualStyles"))
                    continue
                }
                var bag = t.visualDefaults[key] ?? [:]
                for (card, list) in cards.objectValue ?? [:] {
                    let entries = list.arrayValue ?? []
                    if entries.count > 1 {
                        warnings.append(ImportWarning("\(pbiType).\(card) has \(entries.count) entries; only the first is used.", severity: .info, location: "visualStyles"))
                    }
                    guard let props = entries.first?.objectValue else { continue }
                    var out = bag[card] ?? [:]
                    for (k, v) in props {
                        let value = themeValue(v)
                        if pbiType == "page", card == "background", k == "color", let s = value.stringValue, PBIExpr.isHexColor(s) {
                            t.background = s   // the page background is a first-class ThemeSpec property
                            continue
                        }
                        out[k] = value
                    }
                    if !out.isEmpty { bag[card] = out }
                }
                if !bag.isEmpty { t.visualDefaults[key] = bag }
            }
        }

        // Facet-only properties, when the theme was exported by Facet.
        if let ext = root[facetExtensionKey] {
            for (name, kp) in textClasses { if let w = ext["weights"]?[name]?.stringValue { t[keyPath: kp].weight = w } }
            if let v = ext["cornerRadius"]?.doubleValue { t.cornerRadius = v }
            if let v = ext["visualPadding"]?.doubleValue { t.visualPadding = v }
            if let v = ext["isDark"]?.boolValue { t.isDark = v }
            if let v = ext["isHighContrast"]?.boolValue { t.isHighContrast = v }
            if let w = ext["defaultPageSize"]?["width"]?.doubleValue, let h = ext["defaultPageSize"]?["height"]?.doubleValue {
                t.defaultPageSize = PageSize(width: w, height: h)
            }
        } else if let rgb = HexColor.rgb(t.background) {
            t.isDark = 0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b < 0.4
        }

        let known: Set<String> = ["name", "dataColors", "foreground", "firstLevelElements", "foregroundNeutralSecondary", "secondLevelElements",
                                  "background", "backgroundLight", "secondaryBackground", "thirdLevelElements", "tableAccent", "accent",
                                  "good", "neutral", "bad", "maximum", "center", "minimum", "textClasses", "visualStyles", facetExtensionKey, "$schema"]
        let unknown = root.keys.filter { !known.contains($0) }.sorted()
        if !unknown.isEmpty {
            warnings.append(ImportWarning("Ignored theme properties Facet doesn't use: \(unknown.joined(separator: ", ")).", severity: .info))
        }
        return (t, warnings)
    }

    /// Writes a Power BI theme. With `includeFacetExtensions`, Facet-only properties are kept in a `facet` block so that
    /// re-importing reproduces the `ThemeSpec` exactly.
    public static func export(_ theme: ThemeSpec, includeFacetExtensions: Bool = true) -> Data {
        json(theme, includeFacetExtensions: includeFacetExtensions).serialized()
    }

    static func json(_ t: ThemeSpec, includeFacetExtensions: Bool) -> JSONValue {
        var root: [String: JSONValue] = [
            "name": js(t.name), "dataColors": ja(t.dataColors.map(js)),
            "foreground": js(t.foreground), "foregroundNeutralSecondary": js(t.secondaryForeground),
            "background": js(t.cardBackground), "backgroundLight": js(t.gridline), "tableAccent": js(t.accent),
            "good": js(t.good), "neutral": js(t.neutral), "bad": js(t.bad),
            "maximum": js(t.maximum), "center": js(t.center), "minimum": js(t.minimum),
        ]
        var classes: [String: JSONValue] = [:]
        for (name, kp) in textClasses {
            let s = t[keyPath: kp]
            var c: [String: JSONValue] = ["fontSize": jn(s.size)]
            if !s.fontFamily.isEmpty { c["fontFace"] = js(s.fontFamily) }
            if let color = s.color { c["color"] = js(color) }
            classes[name] = .object(c)
        }
        root["textClasses"] = .object(classes)

        var styles: [String: JSONValue] = [:]
        var defaults = t.visualDefaults
        var page = defaults["page"] ?? [:]
        var pageBackground = page["background"] ?? [:]
        pageBackground["color"] = js(t.background)
        page["background"] = pageBackground
        defaults["page"] = page
        for (key, bag) in defaults {
            let pbiType = key == "*" ? "*" : VisualType(rawValue: key).map(PowerBIMapping.powerBIType(for:)) ?? key
            var cards: [String: JSONValue] = [:]
            for (card, props) in bag {
                cards[card] = ja([.object(props.mapValues(exportValue))])
            }
            styles[pbiType] = jo(["*": .object(cards)])
        }
        root["visualStyles"] = .object(styles)

        if includeFacetExtensions {
            var ext: [String: JSONValue] = [
                "weights": .object(Dictionary(uniqueKeysWithValues: textClasses.map { ($0.0, js(t[keyPath: $0.1].weight)) })),
                "cornerRadius": jn(t.cornerRadius), "visualPadding": jn(t.visualPadding),
                "isDark": jb(t.isDark), "isHighContrast": jb(t.isHighContrast),
            ]
            if let p = t.defaultPageSize { ext["defaultPageSize"] = jo(["width": jn(p.width), "height": jn(p.height)]) }
            root[facetExtensionKey] = .object(ext)
        }
        return .object(root)
    }

    /// `{"solid": {"color": "#hex"}}` → "#hex"; everything else unchanged.
    static func themeValue(_ v: JSONValue) -> JSONValue {
        if let o = v.objectValue, o.count == 1, let c = o["solid"]?["color"]?.stringValue { return .string(c) }
        return v
    }
    static func exportValue(_ v: JSONValue) -> JSONValue {
        if let s = v.stringValue, PBIExpr.isHexColor(s) { return jo(["solid": jo(["color": js(s)])]) }
        return v
    }

    /// File name used for a theme inside `StaticResources/RegisteredResources`.
    static func resourceName(for theme: ThemeSpec) -> String {
        let cleaned = theme.name.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? Character($0) : "_" }
        let base = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return (base.isEmpty ? "Theme" : base) + ".json"
    }
}
