import Foundation
import FacetCore
import FacetVisuals

/// Measure-driven formatting ("fx") beyond titles and data colours: which Format pane properties
/// can take their value from a field, and what each binding evaluates to under a visual's
/// filters. The values reach the renderer as `VisualData.formatOverrides`.
enum FormatBindings {
    /// Text properties that offer fx: the subtitle, button and shape text, alt text and the
    /// action tooltip. Every colour property offers it, and the per-column widths of a table.
    static let textProperties: Set<String> = ["subtitle.text", "text.text",
                                              FormatBinding.altTextCard + ".text", FormatBinding.actionCard + ".tooltip"]

    /// The kind of value a Format pane row takes from a field, or nil when the row offers no fx.
    static func kind(of property: FormatProperty) -> FormatBinding.Kind? {
        switch property.kind {
        case .color: return .color
        case .string: return textProperties.contains(property.id) ? .text : nil
        case .number: return property.card == "columnWidths" ? .number : nil
        case .bool, .options, .field: return nil
        }
    }

    /// The format styles a kind of property offers, as Power BI lists them.
    static func modes(for kind: FormatBinding.Kind) -> [ConditionalFormat.Mode] {
        switch kind {
        case .text: return [.fieldValue]
        case .color: return [.gradient, .rules, .fieldValue]
        case .number: return [.rules, .fieldValue]
        }
    }

    /// A first binding for a property: field value, based on the visual's first value field.
    static func newBinding(card: String, key: String, kind: FormatBinding.Kind, for spec: VisualSpec) -> FormatBinding {
        var b = FormatBinding(card: card, key: key, kind: kind)
        b.field = spec.allFields.first { $0.isAggregate }
        b.mode = kind == .number ? .rules : .fieldValue
        if b.mode == .rules { b.rules = [newRule(kind: kind)] }
        return b
    }

    static func newRule(kind: FormatBinding.Kind) -> ConditionalFormat.Rule {
        var r = ConditionalFormat.Rule()
        r.upperOp = nil
        if kind == .number { r.number = 120 }
        return r
    }

    /// True when the visual must be queried: data visuals, text boxes, and page elements with fx.
    static func queriesData(_ spec: VisualSpec) -> Bool {
        !spec.type.isPageElement || spec.type == .textBox || !(spec.formatBindings ?? []).isEmpty
    }

    // MARK: - Evaluation

    /// The value of each of the visual's bindings under `filters` (card → key → value). A binding
    /// with no field, whose query fails, or whose value gives nothing usable (a blank text, a
    /// value no rule matches, a text that is no colour) is left out: the static value shows.
    static func overrides(for spec: VisualSpec, filters: [String], model: SemanticModel,
                          run: (String) throws -> DataTable?) -> FormatBag {
        var out: FormatBag = [:]
        var cache: [String: Value] = [:]
        for binding in spec.formatBindings ?? [] {
            guard let field = binding.field else { continue }
            let value: Value
            if let known = cache[field.key] {
                value = known
            } else {
                guard let table = try? run(DynamicTitles.query(field, filters: filters, model: model, name: "__fx")) else { continue }
                value = table.rowCount > 0 && table.columnCount > 0 ? table[0, table.columnCount - 1] : .null
                cache[field.key] = value
            }
            guard let result = output(binding, value: value, format: formatString(of: field, model: model)) else { continue }
            out[binding.card, default: [:]][binding.key] = result
        }
        return out
    }

    /// What one binding gives for the field's `value` (formatted with `format` for text).
    static func output(_ b: FormatBinding, value: Value, format: String) -> JSONValue? {
        let range = ConditionalFormatEvaluator.Range(min: b.minValue, max: b.maxValue)
        switch (b.kind, b.mode) {
        case (.text, .fieldValue):
            guard !value.isNull else { return nil }
            let text = ValueFormatter.format(value, format).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .string(text)
        case (.text, _):
            return nil
        case (.color, .fieldValue):
            return ConditionalFormatEvaluator.colorString(value.asString).map(JSONValue.string)
        case (.color, .gradient):
            var scale = ConditionalFormat(target: .background)
            scale.mode = .gradient
            scale.minColor = b.minColor; scale.maxColor = b.maxColor
            scale.minValue = b.minValue; scale.maxValue = b.maxValue
            return ConditionalFormatEvaluator.hex(for: value, range: range, format: scale).map(JSONValue.string)
        case (.color, .rules):
            guard let rule = ConditionalFormatEvaluator.matchingRule(value, range: range, format: rulesFormat(b)),
                  let hex = ConditionalFormatEvaluator.colorString(rule.color) else { return nil }
            return .string(hex)
        case (.number, .fieldValue):
            if case .string = value { return nil }
            guard let d = value.asDouble, let n = clamped(d, b) else { return nil }
            return .number(n)
        case (.number, .rules):
            guard let rule = ConditionalFormatEvaluator.matchingRule(value, range: range, format: rulesFormat(b)),
                  let d = rule.number, let n = clamped(d, b) else { return nil }
            return .number(n)
        case (.number, .gradient):
            return nil
        }
    }

    private static func rulesFormat(_ b: FormatBinding) -> ConditionalFormat {
        var f = ConditionalFormat(target: .background)
        f.mode = .rules
        f.rules = b.rules
        return f
    }

    /// Numbers stay finite; a column width stays within what the Format pane accepts.
    private static func clamped(_ d: Double, _ b: FormatBinding) -> Double? {
        guard d.isFinite else { return nil }
        return b.card == "columnWidths" ? min(2_000, max(28, d)) : d
    }

    private static func formatString(of field: FieldRef, model: SemanticModel) -> String {
        let table = model.table(field.table)
        return (field.kind == .measure ? table?.measure(field.name)?.formatString : table?.column(field.name)?.formatString) ?? ""
    }
}
