import Foundation
import FacetCore

/// Numeric range (what-if) parameters and field parameters: validation, generated DAX, and the
/// tables, columns and measures they add to the model.
enum ParameterLogic {
    /// The most values a numeric range may generate.
    static let maximumValues = 1_000_000

    enum Parsed: Equatable {
        case parameter(WhatIfParameter)
        case problem(String)
    }

    /// Reads the numeric range form. The default is optional; it falls back to the minimum.
    static func parse(name: String, minimum: String, maximum: String, increment: String, defaultValue: String) -> Parsed {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return .problem("Name the parameter.") }
        if n.contains("[") || n.contains("]") { return .problem("Names can't contain square brackets.") }
        func number(_ s: String) -> Double? {
            let d = Double(s.trimmingCharacters(in: .whitespaces))
            return d?.isFinite == true ? d : nil
        }
        guard let lo = number(minimum) else { return .problem("Minimum must be a number.") }
        guard let hi = number(maximum) else { return .problem("Maximum must be a number.") }
        guard let inc = number(increment) else { return .problem("Increment must be a number.") }
        if hi <= lo { return .problem("Maximum must be greater than minimum.") }
        if inc <= 0 { return .problem("Increment must be greater than zero.") }
        if inc > hi - lo { return .problem("Increment can't be larger than the range.") }
        if valueCount(minimum: lo, maximum: hi, increment: inc) > maximumValues {
            return .problem("That range has more than \(maximumValues.formatted()) values. Use a larger increment.")
        }
        var def = lo
        if !defaultValue.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let d = number(defaultValue) else { return .problem("Default must be a number.") }
            if d < lo || d > hi { return .problem("Default must be between minimum and maximum.") }
            def = d
        }
        return .parameter(WhatIfParameter(name: n, minimum: lo, maximum: hi, increment: inc, defaultValue: def))
    }

    /// How many values GENERATESERIES produces: every step from the minimum that doesn't pass the maximum.
    static func valueCount(minimum: Double, maximum: Double, increment: Double) -> Int {
        guard increment > 0, maximum >= minimum else { return 0 }
        let steps = ((maximum - minimum) / increment + 1e-9).rounded(.down)
        return steps > 1e12 ? Int.max : Int(steps) + 1
    }

    static func isWhole(_ p: WhatIfParameter) -> Bool {
        p.minimum == p.minimum.rounded() && p.increment == p.increment.rounded()
    }

    // MARK: Generated DAX

    /// The parameter's table: one column, named after the parameter, holding the series.
    static func seriesExpression(_ p: WhatIfParameter) -> String {
        "SELECTCOLUMNS(GENERATESERIES(\(ModelDAX.number(p.minimum)), \(ModelDAX.number(p.maximum)), \(ModelDAX.number(p.increment))), \(ModelDAX.string(p.name)), [Value])"
    }
    static func valueMeasureName(_ name: String) -> String { "\(name) Value" }
    /// The measure that reads the slicer's selection, falling back to the default.
    static func valueMeasureExpression(_ p: WhatIfParameter) -> String {
        "SELECTEDVALUE(\(ModelDAX.column(p.name, p.name)), \(ModelDAX.number(p.defaultValue)))"
    }

    static func fieldsColumnName(_ name: String) -> String { "\(name) Fields" }
    static func orderColumnName(_ name: String) -> String { "\(name) Order" }
    /// The field parameter's table: caption, NAMEOF reference and order of each field.
    static func fieldParameterExpression(name: String, fields: [FieldRef]) -> String {
        let rows = fields.enumerated().map { i, f in
            "    (\(ModelDAX.string(f.caption)), NAMEOF(\(ModelDAX.reference(f))), \(i))"
        }
        return "SELECTCOLUMNS(\n  {\n\(rows.joined(separator: ",\n"))\n  },\n  \(ModelDAX.string(name)), [Value1],\n  \(ModelDAX.string(fieldsColumnName(name))), [Value2],\n  \(ModelDAX.string(orderColumnName(name))), [Value3]\n)"
    }

    // MARK: Installing into the model

    /// Why a numeric range parameter can't be added (or, when `replacing` names an existing one, updated).
    static func problem(_ p: WhatIfParameter, replacing: UUID? = nil, model: SemanticModel) -> String? {
        let existing = replacing.flatMap { id in model.whatIfParameters.first { $0.id == id } }
        if existing.map({ ModelDAX.same($0.name, p.name) }) != true {
            if model.table(p.name) != nil { return "A table named “\(p.name)” already exists." }
            if model.calculationGroups.contains(where: { ModelDAX.same($0.name, p.name) }) { return "A calculation group named “\(p.name)” already exists." }
        }
        let measure = valueMeasureName(p.name)
        if let found = model.measure(measure), !ModelDAX.same(found.table.name, existing?.name ?? "") {
            return "A measure named “\(measure)” already exists."
        }
        return nil
    }

    /// Adds (or regenerates) the parameter's table and value measure, and records the parameter.
    static func install(_ p: WhatIfParameter, replacing: UUID? = nil, into model: inout SemanticModel) {
        var p = p
        if let id = replacing, let i = model.whatIfParameters.firstIndex(where: { $0.id == id }) {
            let old = model.whatIfParameters[i]
            p.id = old.id
            model.tables.removeAll { ModelDAX.same($0.name, old.name) && $0.isCalculated }
            model.whatIfParameters[i] = p
        } else {
            model.whatIfParameters.append(p)
        }
        var column = ModelColumn(name: p.name, dataType: isWhole(p) ? .integer : .decimal)
        column.summarizeBy = .none
        var table = ModelTable(name: p.name, columns: [column])
        table.expression = seriesExpression(p)
        table.measures = [Measure(name: valueMeasureName(p.name), expression: valueMeasureExpression(p))]
        model.tables.append(table)
    }

    static func fieldParameterProblem(name: String, fields: [FieldRef], replacing: UUID? = nil, model: SemanticModel) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return "Name the parameter." }
        if n.contains("[") || n.contains("]") { return "Names can't contain square brackets." }
        if fields.isEmpty { return "Add at least one field." }
        for f in fields {
            let found = f.kind == .measure ? model.measure(f.name) != nil : model.table(f.table)?.column(f.name) != nil
            if !found { return "“\(f.name)” is no longer in the model." }
        }
        let existing = replacing.flatMap { id in model.fieldParameters.first { $0.id == id } }
        if existing.map({ ModelDAX.same($0.name, n) }) != true {
            if model.table(n) != nil { return "A table named “\(n)” already exists." }
            if model.calculationGroups.contains(where: { ModelDAX.same($0.name, n) }) { return "A calculation group named “\(n)” already exists." }
        }
        return nil
    }

    /// Adds (or regenerates) a field parameter's table and records the parameter.
    static func install(fieldParameter name: String, fields: [FieldRef], replacing: UUID? = nil, into model: inout SemanticModel) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var parameter = FieldParameter(name: n, fields: fields)
        if let id = replacing, let i = model.fieldParameters.firstIndex(where: { $0.id == id }) {
            let old = model.fieldParameters[i]
            parameter.id = old.id
            model.tables.removeAll { ModelDAX.same($0.name, old.name) && $0.isCalculated }
            model.fieldParameters[i] = parameter
        } else {
            model.fieldParameters.append(parameter)
        }
        var caption = ModelColumn(name: n, dataType: .text)
        caption.sortByColumn = orderColumnName(n)
        var reference = ModelColumn(name: fieldsColumnName(n), dataType: .text)
        reference.isHidden = true
        var order = ModelColumn(name: orderColumnName(n), dataType: .integer)
        order.isHidden = true
        order.summarizeBy = .none
        var table = ModelTable(name: n, columns: [caption, reference, order])
        table.expression = fieldParameterExpression(name: n, fields: fields)
        model.tables.append(table)
    }

    /// Removes a parameter together with the table generated for it.
    static func remove(parameter id: UUID, from model: inout SemanticModel) {
        var name: String?
        if let i = model.whatIfParameters.firstIndex(where: { $0.id == id }) { name = model.whatIfParameters.remove(at: i).name }
        if let i = model.fieldParameters.firstIndex(where: { $0.id == id }) { name = model.fieldParameters.remove(at: i).name }
        guard let name else { return }
        model.tables.removeAll { ModelDAX.same($0.name, name) && $0.isCalculated }
        model.relationships.removeAll { ModelDAX.same($0.fromTable, name) || ModelDAX.same($0.toTable, name) }
    }
}
