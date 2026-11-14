import Foundation
import FacetCore

/// Power BI semantic-query expressions: field references, literals, filters and formatting objects,
/// shared by the PBIR (project) format and the legacy Layout format inside .pbix files.
enum PBIExpr {
    // MARK: Literals

    static func literal(_ v: Value) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .int(let i): return "\(i)L"
        case .double(let d):
            if d == d.rounded(), abs(d) < 1e15 { return "\(Int64(d))D" }
            return "\(d)D"
        case .string(let s): return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
        case .date(let d): return "datetime'" + DateParsing.string(d, format: "yyyy-MM-dd'T'HH:mm:ss") + "'"
        }
    }

    static func parseLiteral(_ text: String) -> Value {
        let s = text.trimmingCharacters(in: .whitespaces)
        if s == "null" || s.isEmpty { return .null }
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if s.hasPrefix("'"), s.hasSuffix("'"), s.count >= 2 {
            return .string(String(s.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
        }
        if s.lowercased().hasPrefix("datetime'"), s.hasSuffix("'") {
            let body = String(s.dropFirst(9).dropLast())
            if let d = DateParsing.parse(String(body.prefix(19))) ?? DateParsing.parse(body) { return .date(d) }
            return .string(body)
        }
        if let last = s.last, "LDMldm".contains(last) {
            let n = String(s.dropLast())
            if last == "L" || last == "l", let i = Int64(n) { return .int(i) }
            if let d = Double(n) { return .double(d) }
        }
        if let i = Int64(s) { return .int(i) }
        if let d = Double(s) { return .double(d) }
        return .string(s)
    }

    static func literalExpr(_ v: Value) -> JSONValue { jo(["Literal": jo(["Value": js(literal(v))])]) }

    // MARK: Fields

    /// Power BI's names for a date column's auto date/time hierarchy: the column's variation and the hierarchy in it.
    static let dateVariation = "Variation", dateHierarchy = "Date Hierarchy"

    /// The expression for a field. With `alias`, the source is `{"Source": alias}` (inside a query); otherwise `{"Entity": table}`.
    /// A level of a date column's auto date/time hierarchy is a `HierarchyLevel` of the column's `Date Hierarchy`,
    /// reached through its variation (`PropertyVariationSource`), as Power BI Desktop writes it.
    static func field(_ f: FieldRef, alias: String? = nil) -> JSONValue {
        let source = jo(["SourceRef": alias.map { jo(["Source": js($0)]) } ?? jo(["Entity": js(f.table)])])
        let base = jo(["Expression": source, "Property": js(f.name)])
        if f.kind == .measure { return jo(["Measure": base]) }
        let grouped: JSONValue
        if let level = f.dateLevel {
            let variation = jo(["PropertyVariationSource": jo(["Expression": source, "Name": js(dateVariation), "Property": js(f.name)])])
            grouped = jo(["HierarchyLevel": jo(["Expression": jo(["Hierarchy": jo(["Expression": variation, "Hierarchy": js(dateHierarchy)])]),
                                                 "Level": js(level)])])
        } else {
            grouped = jo(["Column": base])
        }
        if let code = PowerBIMapping.aggregationCode(f.aggregation) {
            return jo(["Aggregation": jo(["Expression": grouped, "Function": jn(code)])])
        }
        return grouped
    }

    /// Parses a field expression. `aliases` maps query source aliases to entity names.
    static func parseField(_ j: JSONValue?, aliases: [String: String] = [:]) -> FieldRef? {
        guard let j else { return nil }
        func entity(_ expr: JSONValue?) -> String? {
            guard let ref = expr?["SourceRef"] else { return nil }
            if let e = ref["Entity"]?.stringValue { return e }
            if let s = ref["Source"]?.stringValue { return aliases[s] ?? s }
            return nil
        }
        if let c = j["Column"], let t = entity(c["Expression"]), let p = c["Property"]?.stringValue { return .column(t, p) }
        if let m = j["Measure"], let t = entity(m["Expression"]), let p = m["Property"]?.stringValue { return .measure(t, p) }
        if let a = j["Aggregation"], var inner = parseField(a["Expression"], aliases: aliases) {
            inner.aggregation = PowerBIMapping.aggregation(code: a["Function"]?.intValue ?? 0)
            return inner
        }
        if let h = j["HierarchyLevel"], let level = h["Level"]?.stringValue {
            let hier = h["Expression"]?["Hierarchy"]
            if let t = entity(hier?["Expression"]) { return .column(t, level) }
            // Auto date/time hierarchies hang off a column via PropertyVariationSource: the level is the field's date level.
            if let pvs = hier?["Expression"]?["PropertyVariationSource"], let t = entity(pvs["Expression"]),
               let p = pvs["Property"]?.stringValue {
                return .dateLevel(t, p, level)
            }
        }
        return nil
    }

    /// "Sales.Region", "Sum(Sales.Amount)", "Sales.Order Date.Variation.Date Hierarchy.Year".
    static func queryRef(_ f: FieldRef) -> String {
        var base = "\(f.table).\(f.name)"
        if f.kind == .column, let level = f.dateLevel { base += ".\(dateVariation).\(dateHierarchy).\(level)" }
        return f.kind == .column && f.aggregation != .none ? "\(PowerBIMapping.aggregationQueryName(f.aggregation))(\(base))" : base
    }
    /// "Region", "Sum of Amount", "Order Date Year".
    static func nativeQueryRef(_ f: FieldRef) -> String {
        let base = f.kind == .column ? f.dateLevel.map { "\(f.name) \($0)" } ?? f.name : f.name
        return f.kind == .column && f.aggregation != .none ? "\(f.aggregation.displayName) of \(base)" : base
    }

    // MARK: Filters

    static let timeUnits: [(RelativeDateFilter.Unit, code: Int, calendar: Bool)] = [
        (.days, 0, false), (.weeks, 1, false), (.calendarWeeks, 1, true), (.months, 2, false), (.calendarMonths, 2, true),
        (.years, 3, false), (.calendarYears, 3, true), (.minutes, 6, false), (.hours, 7, false),
    ]

    private static func alias(for table: String) -> String {
        String(table.first { $0.isLetter }.map { $0.lowercased() } ?? "t")
    }

    /// The `filter` body (a semantic query) for a filter, or nil when it restricts nothing.
    static func filterQuery(_ f: FilterSpec) -> JSONValue? {
        let a = alias(for: f.field.table)
        let target = field(f.field, alias: a)
        var from: [JSONValue] = [jo(["Name": js(a), "Entity": js(f.field.table), "Type": jn(0)])]
        var condition: JSONValue?
        func not(_ c: JSONValue) -> JSONValue { jo(["Not": jo(["Expression": c])]) }
        switch f.kind {
        case .basic:
            guard !f.values.isEmpty else { return nil }
            let c = jo(["In": jo(["Expressions": ja([target]), "Values": ja(f.values.map { ja([literalExpr($0)]) })])])
            condition = f.isInverted ? not(c) : c
        case .advanced:
            let parts = f.conditions.map { c -> JSONValue in
                func cmp(_ kind: Int, _ v: Value) -> JSONValue {
                    jo(["Comparison": jo(["ComparisonKind": jn(kind), "Left": target, "Right": literalExpr(v)])])
                }
                func text(_ name: String) -> JSONValue { jo([name: jo(["Left": target, "Right": literalExpr(c.value)])]) }
                switch c.op {
                case .equals: return cmp(0, c.value)
                case .notEquals: return not(cmp(0, c.value))
                case .greaterThan: return cmp(1, c.value)
                case .greaterOrEqual: return cmp(2, c.value)
                case .lessThan: return cmp(3, c.value)
                case .lessOrEqual: return cmp(4, c.value)
                case .contains: return text("Contains")
                case .notContains: return not(text("Contains"))
                case .startsWith: return text("StartsWith")
                case .notStartsWith: return not(text("StartsWith"))
                case .endsWith: return text("EndsWith")
                case .isBlank: return cmp(0, .null)
                case .isNotBlank: return not(cmp(0, .null))
                case .isEmpty: return cmp(0, .string(""))
                case .isNotEmpty: return not(cmp(0, .string("")))
                }
            }
            guard var acc = parts.first else { return nil }
            for p in parts.dropFirst() { acc = jo([f.conditionsUseOr ? "Or" : "And": jo(["Left": acc, "Right": p])]) }
            condition = acc
        case .topN:
            guard let by = f.topN.by else { return nil }
            let byAlias = by.table == f.field.table ? a : alias(for: by.table) + "2"
            var subFrom = [jo(["Name": js(a), "Entity": js(f.field.table), "Type": jn(0)])]
            if byAlias != a { subFrom.append(jo(["Name": js(byAlias), "Entity": js(by.table), "Type": jn(0)])) }
            var select = target.objectValue ?? [:]
            select["Name"] = js("field")
            let sub = jo(["Version": jn(2), "From": ja(subFrom), "Select": ja([.object(select)]),
                          "OrderBy": ja([jo(["Direction": jn(f.topN.isBottom ? 1 : 2), "Expression": field(by, alias: byAlias)])]),
                          "Top": jn(f.topN.count)])
            from.insert(jo(["Name": js("subquery"), "Expression": jo(["Subquery": jo(["Query": sub])]), "Type": jn(2)]), at: 0)
            condition = jo(["In": jo(["Expressions": ja([target]), "Table": jo(["SourceRef": jo(["Source": js("subquery")])])])])
        case .relativeDate, .relativeTime:
            let r = f.relative
            let (unit, calendar) = timeUnits.first { $0.0 == r.unit }.map { ($0.code, $0.calendar) } ?? (0, false)
            let now = jo(["Now": jo([:])])
            func add(_ e: JSONValue, _ amount: Int, _ u: Int) -> JSONValue { jo(["DateAdd": jo(["Expression": e, "Amount": jn(amount), "TimeUnit": jn(u)])]) }
            func span(_ e: JSONValue, _ u: Int) -> JSONValue { jo(["DateSpan": jo(["Expression": e, "TimeUnit": jn(u)])]) }
            let grain = f.kind == .relativeTime || unit >= 6 ? unit : 0
            let lower: JSONValue, upper: JSONValue
            switch (r.direction, calendar) {
            case (.this, _): lower = span(now, unit); upper = span(now, unit)
            case (.last, true): lower = span(add(now, -r.count, unit), unit); upper = span(add(now, -1, unit), unit)
            case (.next, true): lower = span(add(now, 1, unit), unit); upper = span(add(now, r.count, unit), unit)
            case (.last, false):
                lower = span(add(r.includeToday ? add(now, 1, grain) : now, -r.count, unit), grain)
                upper = span(r.includeToday ? now : add(now, -1, grain), grain)
            case (.next, false):
                lower = span(r.includeToday ? now : add(now, 1, grain), grain)
                upper = span(add(r.includeToday ? add(now, -1, grain) : now, r.count, unit), grain)
            }
            condition = jo(["Between": jo(["Expression": target, "LowerBound": lower, "UpperBound": upper])])
        }
        guard let condition else { return nil }
        return jo(["Version": jn(2), "From": ja(from), "Where": ja([jo(["Condition": condition])])])
    }

    static func filterTypeName(_ k: FilterSpec.Kind) -> String {
        switch k {
        case .basic: return "Categorical"
        case .advanced: return "Advanced"
        case .topN: return "TopN"
        case .relativeDate: return "RelativeDate"
        case .relativeTime: return "RelativeTime"
        }
    }

    /// One entry of a PBIR `filterConfig.filters` array.
    static func filterEntry(_ f: FilterSpec, drillthrough: Bool = false) -> JSONValue {
        var o: [String: JSONValue] = ["name": js(f.id.lower), "field": field(f.field), "type": js(filterTypeName(f.kind)),
                                      "howCreated": js(drillthrough ? "Drillthrough" : "User")]
        if let q = filterQuery(f) { o["filter"] = q }
        if f.isHidden { o["isHiddenInViewMode"] = jb(true) }
        if f.isLocked { o["isLockedInViewMode"] = jb(true) }
        if let d = f.displayName { o["displayName"] = js(d) }
        if f.requireSingleSelection {
            o["objects"] = jo(["general": ja([jo(["properties": jo(["requireSingleSelect": literalExpr(.bool(true))])])])])
        }
        return .object(o)
    }

    /// Parses a filter entry in either PBIR form (`field`) or legacy Layout form (`expression`).
    static func parseFilterEntry(_ j: JSONValue, warnings: inout [ImportWarning], location: String? = nil) -> FilterSpec? {
        guard let fieldRef = parseField(j["field"] ?? j["expression"]) else {
            warnings.append(ImportWarning("A filter on an unsupported field expression was skipped.", location: location))
            return nil
        }
        var f = FilterSpec(field: fieldRef)
        if let n = j["name"]?.stringValue, let u = UUID(uuidString: n) { f.id = u }
        f.isHidden = j["isHiddenInViewMode"]?.boolValue ?? false
        f.isLocked = j["isLockedInViewMode"]?.boolValue ?? false
        f.displayName = j["displayName"]?.stringValue
        if let v = j["objects"]?["general"]?[0]?["properties"]?["requireSingleSelect"]?["expr"]?["Literal"]?["Value"]?.stringValue {
            f.requireSingleSelection = v == "true"
        }
        let type = (j["type"]?.stringValue ?? "Categorical").lowercased()
        switch type {
        case "advanced": f.kind = .advanced
        case "topn": f.kind = .topN
        case "relativedate": f.kind = .relativeDate
        case "relativetime": f.kind = .relativeTime
        case "categorical", "include", "exclude", "passthrough", "tuple", "range", "vrange": f.kind = type == "range" ? .advanced : .basic
        default:
            f.kind = .basic
            warnings.append(ImportWarning("Filter type “\(type)” on \(fieldRef.table)[\(fieldRef.name)] isn't supported; imported without a condition.",
                                          location: location))
        }
        guard let q = j["filter"], let cond = q["Where"]?[0]?["Condition"] else { return f }
        var aliases: [String: String] = [:]
        for src in q["From"]?.arrayValue ?? [] {
            if let n = src["Name"]?.stringValue, let e = src["Entity"]?.stringValue { aliases[n] = e }
        }
        if !applyCondition(cond, query: q, aliases: aliases, to: &f) {
            warnings.append(ImportWarning("The condition of the filter on \(fieldRef.table)[\(fieldRef.name)] couldn't be fully read.", location: location))
        }
        return f
    }

    private static func unwrapNot(_ c: JSONValue) -> (JSONValue, Bool) {
        if let inner = c["Not"]?["Expression"] { return (inner, true) }
        return (c, false)
    }

    private static func literalValue(_ e: JSONValue?) -> Value? {
        e?["Literal"]?["Value"]?.stringValue.map(parseLiteral)
    }

    /// Decodes a `Where` condition into the filter. Returns false when part of it wasn't understood.
    private static func applyCondition(_ cond: JSONValue, query: JSONValue, aliases: [String: String], to f: inout FilterSpec) -> Bool {
        let (c, negated) = unwrapNot(cond)
        if let inExpr = c["In"] {
            if inExpr["Table"] != nil {
                // Top N: In over a subquery.
                let sub = query["From"]?.arrayValue?.compactMap { $0["Expression"]?["Subquery"]?["Query"] }.first
                var subAliases: [String: String] = [:]
                for src in sub?["From"]?.arrayValue ?? [] {
                    if let n = src["Name"]?.stringValue, let e = src["Entity"]?.stringValue { subAliases[n] = e }
                }
                f.kind = .topN
                f.topN.count = sub?["Top"]?.intValue ?? 10
                let order = sub?["OrderBy"]?[0]
                f.topN.isBottom = order?["Direction"]?.intValue == 1
                f.topN.by = parseField(order?["Expression"], aliases: subAliases)
                return f.topN.by != nil
            }
            if f.kind != .basic { f.kind = .basic }
            f.values = (inExpr["Values"]?.arrayValue ?? []).compactMap { literalValue($0[0]) }
            f.isInverted = negated
            return true
        }
        if let between = c["Between"] {
            return applyRelative(between, to: &f)
        }
        // Advanced: a tree of And/Or over simple conditions.
        var conditions: [FilterCondition] = []
        var usesOr = false
        var ok = true
        func walk(_ node: JSONValue) {
            if let and = node["And"], let l = and["Left"], let r = and["Right"] { walk(l); walk(r); return }
            if let or = node["Or"], let l = or["Left"], let r = or["Right"] { usesOr = true; walk(l); walk(r); return }
            let (inner, neg) = unwrapNot(node)
            if let cmp = inner["Comparison"], let v = literalValue(cmp["Right"]) {
                let kind = cmp["ComparisonKind"]?.intValue ?? 0
                if kind == 0, v.isNull { conditions.append(FilterCondition(op: neg ? .isNotBlank : .isBlank)); return }
                if kind == 0, v == .string("") { conditions.append(FilterCondition(op: neg ? .isNotEmpty : .isEmpty)); return }
                let ops: [FilterOperator] = [.equals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual]
                let negatedOps: [FilterOperator] = [.notEquals, .lessOrEqual, .lessThan, .greaterOrEqual, .greaterThan]
                guard kind >= 0, kind < ops.count else { ok = false; return }
                conditions.append(FilterCondition(op: neg ? negatedOps[kind] : ops[kind], value: v))
                return
            }
            for (name, op, negOp) in [("Contains", FilterOperator.contains, FilterOperator.notContains),
                                      ("StartsWith", .startsWith, .notStartsWith), ("EndsWith", .endsWith, .endsWith)] {
                if let t = inner[name], let v = literalValue(t["Right"]) {
                    if neg && name == "EndsWith" { ok = false }
                    conditions.append(FilterCondition(op: neg ? negOp : op, value: v))
                    return
                }
            }
            if let inList = inner["In"] {
                // An In inside an advanced tree: expand to equality tests.
                for v in (inList["Values"]?.arrayValue ?? []).compactMap({ literalValue($0[0]) }) {
                    conditions.append(FilterCondition(op: neg ? .notEquals : .equals, value: v))
                }
                usesOr = usesOr || !neg
                return
            }
            ok = false
        }
        walk(cond)
        f.kind = .advanced
        f.conditions = conditions
        f.conditionsUseOr = usesOr
        return ok
    }

    private static func applyRelative(_ between: JSONValue, to f: inout FilterSpec) -> Bool {
        struct Bound { var adds: [(amount: Int, unit: Int)] = []; var span: Int? }
        func read(_ e: JSONValue?) -> Bound {
            var b = Bound()
            var cur = e
            while let c = cur {
                if let s = c["DateSpan"] { if b.span == nil { b.span = s["TimeUnit"]?.intValue }; cur = s["Expression"]; continue }
                if let a = c["DateAdd"] { b.adds.append((a["Amount"]?.intValue ?? 0, a["TimeUnit"]?.intValue ?? 0)); cur = a["Expression"]; continue }
                break
            }
            return b
        }
        let lo = read(between["LowerBound"]), hi = read(between["UpperBound"])
        guard lo.span != nil || hi.span != nil else {
            // A literal range: treat as advanced between.
            if let l = literalValue(between["LowerBound"]), let h = literalValue(between["UpperBound"]) {
                f.kind = .advanced
                f.conditions = [FilterCondition(op: .greaterOrEqual, value: l), FilterCondition(op: .lessOrEqual, value: h)]
                return true
            }
            return false
        }
        if f.kind != .relativeTime { f.kind = .relativeDate }
        var r = RelativeDateFilter()
        func unit(_ code: Int, calendar: Bool) -> RelativeDateFilter.Unit {
            timeUnits.first { $0.code == code && $0.calendar == calendar }?.0 ?? timeUnits.first { $0.code == code }?.0 ?? .days
        }
        let grain = lo.span ?? 0
        if lo.adds.isEmpty && hi.adds.isEmpty {
            r.direction = .this; r.count = 1; r.unit = unit(grain, calendar: grain >= 1 && grain <= 3)
        } else if let main = lo.adds.first(where: { $0.amount < 0 }) {
            r.direction = .last
            let calendar = grain == main.unit && (1...3).contains(grain)
            r.count = -main.amount; r.unit = unit(main.unit, calendar: calendar)
            r.includeToday = calendar ? true : lo.adds.contains { $0.amount == 1 }
        } else if let main = hi.adds.first(where: { $0.amount > 0 }) {
            r.direction = .next
            let calendar = grain == main.unit && (1...3).contains(grain)
            r.count = main.amount; r.unit = unit(main.unit, calendar: calendar)
            r.includeToday = calendar ? true : hi.adds.contains { $0.amount == -1 }
        } else { return false }
        f.relative = r
        return true
    }

    // MARK: Formatting objects

    /// Cards that live in `visualContainerObjects` (the visual's chrome) rather than `objects`.
    static let containerCards: Set<String> = ["title", "subTitle", "background", "border", "dropShadow", "visualHeader", "padding",
                                              "visualTooltip", "divider", "spacing", "stylePreset", "lockAspect", "visualLink",
                                              "visualHeaderTooltip"]
    static let selectorsKey = "$selectors"

    static func isHexColor(_ s: String) -> Bool {
        guard s.hasPrefix("#"), [4, 7, 9].contains(s.count) else { return false }
        return s.dropFirst().allSatisfy(\.isHexDigit)
    }

    /// Encodes one property value, or nil when it has no Power BI representation.
    static func objectValue(_ v: JSONValue) -> JSONValue? {
        func lit(_ s: String) -> JSONValue { jo(["expr": jo(["Literal": jo(["Value": js(s)])])]) }
        switch v {
        case .bool(let b): return lit(b ? "true" : "false")
        case .number(let d): return lit(literal(.double(d)))
        case .string(let s): return isHexColor(s) ? jo(["solid": jo(["color": lit(literal(.string(s)))])]) : lit(literal(.string(s)))
        case .object(let o): return o["expr"] != nil || o["solid"] != nil ? v : nil
        case .null, .array: return nil
        }
    }

    static func parseObjectValue(_ j: JSONValue) -> JSONValue {
        func fromLiteral(_ e: JSONValue?) -> JSONValue? {
            guard let s = e?["expr"]?["Literal"]?["Value"]?.stringValue else { return nil }
            switch parseLiteral(s) {
            case .null: return .null
            case .bool(let b): return .bool(b)
            case .int(let i): return .number(Double(i))
            case .double(let d): return .number(d)
            case .string(let t): return .string(t)
            case .date(let d): return .string(DateParsing.isoString(d))
            }
        }
        if let v = fromLiteral(j) { return v }
        if let c = j["solid"]?["color"] {
            if let v = fromLiteral(c) { return v }
            if let s = c.stringValue { return .string(s) }
        }
        return j
    }

    /// Splits a format bag into PBIR `objects` and `visualContainerObjects`.
    static func objects(_ bag: FormatBag) -> (objects: JSONValue?, container: JSONValue?) {
        var inner: [String: JSONValue] = [:], outer: [String: JSONValue] = [:]
        for (card, props) in bag {
            var encoded: [String: JSONValue] = [:]
            for (k, v) in props where k != selectorsKey { if let e = objectValue(v) { encoded[k] = e } }
            var entries: [JSONValue] = encoded.isEmpty ? [] : [jo(["properties": .object(encoded)])]
            entries += props[selectorsKey]?.arrayValue ?? []
            guard !entries.isEmpty else { continue }
            if containerCards.contains(card) { outer[card] = ja(entries) } else { inner[card] = ja(entries) }
        }
        return (inner.isEmpty ? nil : .object(inner), outer.isEmpty ? nil : .object(outer))
    }

    /// Reads `objects`-style JSON into a format bag. Entries with selectors are kept verbatim under `$selectors`.
    static func parseObjects(_ sources: [JSONValue?], skipping: Set<String> = []) -> FormatBag {
        var bag: FormatBag = [:]
        for src in sources {
            for (card, list) in src?.objectValue ?? [:] {
                var props: [String: JSONValue] = bag[card] ?? [:]
                var selectors: [JSONValue] = []
                for entry in list.arrayValue ?? [] {
                    if entry["selector"] != nil { selectors.append(entry); continue }
                    for (k, v) in entry["properties"]?.objectValue ?? [:] where !skipping.contains("\(card).\(k)") {
                        props[k] = parseObjectValue(v)
                    }
                }
                if !selectors.isEmpty { props[selectorsKey] = ja(selectors) }
                if !props.isEmpty { bag[card] = props }
            }
        }
        return bag
    }
}
