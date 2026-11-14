import Foundation
import FacetCore

/// Titles from a measure: a `.title` conditional format ("field value") names the measure or column
/// whose value, under the visual's filters, replaces the title text.
enum DynamicTitles {
    /// The field that supplies a visual's title, when it has one.
    static func source(_ spec: VisualSpec) -> FieldRef? {
        spec.conditionalFormats.first { $0.target == .title && $0.mode == .fieldValue }?.basedOn
    }

    /// The query for the title's value: the field, summarized, under the visual's filter tables.
    static func query(_ field: FieldRef, filters: [String], model: SemanticModel, name: String = "__title") -> String {
        let args = filters + [ModelDAX.string(name), ModelDAX.aggregate(field, model: model)]
        return "EVALUATE\n    SUMMARIZECOLUMNS(\n" + args.map { "        " + $0 }.joined(separator: ",\n") + "\n    )"
    }

    /// The title text, formatted with the field's format string; nil when the visual has no dynamic
    /// title, or the value is blank or cannot be computed (the static title shows instead).
    static func text(for spec: VisualSpec, filters: [String], model: SemanticModel, run: (String) throws -> DataTable?) -> String? {
        guard let field = source(spec), let table = try? run(query(field, filters: filters, model: model)),
              table.rowCount > 0, table.columnCount > 0 else { return nil }
        let value = table[0, table.columnCount - 1]
        guard !value.isNull else { return nil }
        let format = field.kind == .measure ? model.table(field.table)?.measure(field.name)?.formatString
            : model.table(field.table)?.column(field.name)?.formatString
        let text = ValueFormatter.format(value, format ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
