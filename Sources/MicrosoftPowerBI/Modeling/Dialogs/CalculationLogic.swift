import Foundation
import FacetCore

/// Calculation groups: items, ordinals, precedence and format string expressions.
enum CalculationGroupLogic {
    static func make(model: SemanticModel, alongside drafts: [CalculationGroup]) -> CalculationGroup {
        let taken = model.tables.map(\.name) + drafts.map(\.name)
        var name = "Calculation group"
        var n = 2
        while taken.contains(where: { ModelDAX.same($0, name) }) { name = "Calculation group \(n)"; n += 1 }
        var g = CalculationGroup(name: name)
        g.columnName = "Calculation item"
        // Each group needs its own precedence; take the next free one.
        g.precedence = (drafts.map(\.precedence).max() ?? -1) + 1
        g.items = [CalculationItem(name: "Current", expression: "SELECTEDMEASURE()")]
        return g
    }

    static func makeItem(in group: CalculationGroup) -> CalculationItem {
        var name = "Calculation item"
        var n = 2
        while group.items.contains(where: { ModelDAX.same($0.name, name) }) { name = "Calculation item \(n)"; n += 1 }
        return CalculationItem(name: name, expression: "SELECTEDMEASURE()")
    }

    /// Common time-intelligence items over a date column, skipping names the group already has.
    static func timeIntelligenceItems(dateTable: String, dateColumn: String, existing: [CalculationItem]) -> [CalculationItem] {
        let d = ModelDAX.column(dateTable, dateColumn)
        var py = CalculationItem(name: "PY", expression: "CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR(\(d)))")
        py.formatExpression = nil
        var yoyPct = CalculationItem(name: "YoY %", expression:
            "VAR Prior = CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR(\(d)))\nRETURN DIVIDE(SELECTEDMEASURE() - Prior, Prior)")
        yoyPct.formatExpression = "\"0.0%\""
        let all = [
            CalculationItem(name: "Current", expression: "SELECTEDMEASURE()"),
            CalculationItem(name: "YTD", expression: "CALCULATE(SELECTEDMEASURE(), DATESYTD(\(d)))"),
            py,
            CalculationItem(name: "YoY", expression: "SELECTEDMEASURE() - CALCULATE(SELECTEDMEASURE(), SAMEPERIODLASTYEAR(\(d)))"),
            yoyPct,
        ]
        return all.filter { item in !existing.contains { ModelDAX.same($0.name, item.name) } }
    }

    /// Trims names, drops empty format expressions and numbers the items 0, 1, 2… in list order.
    static func normalized(_ groups: [CalculationGroup]) -> [CalculationGroup] {
        groups.map { g in
            var g = g
            g.name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
            g.columnName = g.columnName.trimmingCharacters(in: .whitespacesAndNewlines)
            for i in g.items.indices {
                g.items[i].name = g.items[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
                g.items[i].ordinal = i
                if let f = g.items[i].formatExpression, f.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { g.items[i].formatExpression = nil }
            }
            return g
        }
    }

    static func problems(_ groups: [CalculationGroup], model: SemanticModel) -> [String] {
        var out: [String] = []
        for (i, g) in groups.enumerated() {
            let name = g.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let others = groups.enumerated().filter { $0.offset < i }.map(\.element.name)
            if let p = ModelNames.problem(name, noun: "calculation group", others: others) { if !out.contains(p) { out.append(p) }; continue }
            if model.table(name) != nil { out.append("A table named “\(name)” already exists.") }
            if g.columnName.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Name the column of “\(name)”.") }
            if g.items.isEmpty { out.append("“\(name)” needs at least one calculation item.") }
            for (j, item) in g.items.enumerated() {
                let itemOthers = g.items.enumerated().filter { $0.offset < j }.map(\.element.name)
                if let p = ModelNames.problem(item.name, noun: "calculation item", others: itemOthers) {
                    let text = "In “\(name)”: \(p)"
                    if !out.contains(text) { out.append(text) }
                } else if item.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append("“\(item.name)” in “\(name)” needs an expression.")
                }
            }
        }
        return out
    }

    /// Groups that share a precedence: the order they apply in is then undefined.
    static func precedenceWarning(_ groups: [CalculationGroup]) -> String? {
        var seen: [Int: String] = [:]
        for g in groups {
            if let other = seen[g.precedence] {
                return "“\(other)” and “\(g.name)” both have precedence \(g.precedence). Give each group its own precedence; the higher one is applied first."
            }
            seen[g.precedence] = g.name
        }
        return nil
    }
}

/// User-defined DAX functions.
enum FunctionLogic {
    /// Parameter types, as written after the colon in a function definition.
    static let types = ["anyval", "scalar", "table", "anyref", "variant", "int64", "decimal", "double", "string", "datetime", "boolean", "numeric"]
    static let modes = ["val", "expr"]
    static let maximumParameters = 256

    static func typeTitle(_ type: String) -> String {
        switch type.lowercased() {
        case "anyval": return "Any value"
        case "scalar": return "Scalar"
        case "table": return "Table"
        case "anyref": return "Any reference"
        case "variant": return "Variant"
        case "int64": return "Whole number"
        case "decimal": return "Fixed decimal"
        case "double": return "Decimal number"
        case "string": return "Text"
        case "datetime": return "Date/Time"
        case "boolean": return "True/False"
        case "numeric": return "Numeric"
        default: return type
        }
    }

    /// Function and parameter names: letters, digits and underscores (functions may also use periods
    /// as namespace separators), not starting with a digit.
    static func isIdentifier(_ name: String, allowsPeriods: Bool) -> Bool {
        guard let first = name.unicodeScalars.first, !name.hasSuffix("."), !name.hasPrefix("."), !name.contains("..") else { return false }
        if CharacterSet.decimalDigits.contains(first) { return false }
        return name.unicodeScalars.allSatisfy { s in
            CharacterSet.alphanumerics.contains(s) || s == "_" || (allowsPeriods && s == ".")
        }
    }

    static func make(alongside drafts: [UserFunction]) -> UserFunction {
        var name = "NewFunction"
        var n = 2
        while drafts.contains(where: { ModelDAX.same($0.name, name) }) { name = "NewFunction\(n)"; n += 1 }
        var f = UserFunction(name: name, expression: "x * 2")
        f.parameters = [FunctionParameter(name: "x")]
        return f
    }

    static func makeParameter(in f: UserFunction) -> FunctionParameter {
        var name = "p\(f.parameters.count + 1)"
        var n = f.parameters.count + 2
        while f.parameters.contains(where: { ModelDAX.same($0.name, name) }) { name = "p\(n)"; n += 1 }
        return FunctionParameter(name: name)
    }

    /// `(amount : scalar val, rate : double val = 0.1)` — what the definition's parameter list looks like.
    static func signature(_ f: UserFunction) -> String {
        let params = f.parameters.map { p -> String in
            var s = p.name
            let plain = p.type.lowercased() == "anyval" && p.mode.lowercased() == "val"
            if !plain { s += " : \(p.type.lowercased()) \(p.mode.lowercased())" }
            if let d = p.defaultExpression?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty { s += " = \(d)" }
            return s
        }
        return "(" + params.joined(separator: ", ") + ")"
    }

    static func normalized(_ functions: [UserFunction]) -> [UserFunction] {
        functions.map { f in
            var f = f
            f.name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            for i in f.parameters.indices {
                f.parameters[i].name = f.parameters[i].name.trimmingCharacters(in: .whitespacesAndNewlines)
                if let d = f.parameters[i].defaultExpression, d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { f.parameters[i].defaultExpression = nil }
            }
            return f
        }
    }

    /// - Parameter builtIns: upper-cased names of built-in DAX functions, which user functions may not shadow.
    static func problems(_ functions: [UserFunction], builtIns: Set<String> = []) -> [String] {
        var out: [String] = []
        for (i, f) in functions.enumerated() {
            let name = f.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let others = functions.enumerated().filter { $0.offset < i }.map(\.element.name)
            if let p = ModelNames.problem(name, noun: "function", others: others) { if !out.contains(p) { out.append(p) }; continue }
            if !isIdentifier(name, allowsPeriods: true) {
                out.append("“\(name)” isn't a valid function name. Use letters, digits, underscores and periods, and don't start with a digit.")
                continue
            }
            if builtIns.contains(name.uppercased()) { out.append("“\(name)” is a built-in DAX function. Choose another name.") }
            if f.expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("“\(name)” needs a body.") }
            if f.parameters.count > maximumParameters { out.append("“\(name)” has more than \(maximumParameters) parameters.") }
            var sawOptional = false
            for p in f.parameters {
                if !isIdentifier(p.name, allowsPeriods: false) {
                    out.append(p.name.isEmpty ? "Name every parameter of “\(name)”." : "“\(p.name)” isn't a valid parameter name in “\(name)”.")
                    break
                }
                let optional = !(p.defaultExpression ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if sawOptional, !optional {
                    out.append("In “\(name)”, “\(p.name)” has no default but follows an optional parameter. Optional parameters go last.")
                    break
                }
                sawOptional = sawOptional || optional
            }
            if let dup = ModelNames.firstDuplicate(f.parameters.map(\.name)) { out.append("“\(name)” has two parameters named “\(dup)”.") }
        }
        return out
    }
}
