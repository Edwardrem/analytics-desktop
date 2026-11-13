import Foundation

/// A ready-made visual calculation: generates an expression over a visual column.
public struct VisualCalcTemplate: Sendable, Identifiable {
    public var id: String
    public var name: String
    public var description: String
    let suffix: String
    let builder: @Sendable (_ field: String, _ axis: String?, _ window: Int) -> String

    /// The expression for a visual column.
    /// - Parameters:
    ///   - field: the visual column name, without brackets.
    ///   - axis: "ROWS" (default), "COLUMNS", "ROWS COLUMNS" or "COLUMNS ROWS".
    ///   - window: window size, used by the moving average only.
    public func expression(field: String, axis: String = "ROWS", window: Int = 3) -> String {
        let f = "[" + field.replacingOccurrences(of: "]", with: "]]") + "]"
        let a = axis.trimmingCharacters(in: .whitespaces).uppercased()
        return builder(f, a.isEmpty || a == "ROWS" ? nil : a, max(1, window))
    }

    /// A default name for the calculation, e.g. "Sales running sum".
    public func suggestedName(field: String) -> String { "\(field) \(suffix)" }
}

/// The visual-calculation template gallery.
public enum VisualCalcTemplates {
    public static let all: [VisualCalcTemplate] = [
        VisualCalcTemplate(id: "runningSum", name: "Running sum", description: "Adds up the values from the first row to the current row.",
                           suffix: "running sum") { f, axis, _ in "RUNNINGSUM(\(f)\(axis.map { ", \($0)" } ?? ""))" },
        VisualCalcTemplate(id: "movingAverage", name: "Moving average", description: "Averages the values of the last rows, including the current row.",
                           suffix: "moving average") { f, axis, n in "MOVINGAVERAGE(\(f), \(n)\(axis.map { ", TRUE, \($0)" } ?? ""))" },
        VisualCalcTemplate(id: "percentOfParent", name: "Percent of parent", description: "The value as a share of its parent level.",
                           suffix: "percent of parent") { f, axis, _ in "DIVIDE(\(f), COLLAPSE(\(f), \(axis ?? "ROWS")))" },
        VisualCalcTemplate(id: "percentOfGrandTotal", name: "Percent of grand total", description: "The value as a share of the grand total.",
                           suffix: "percent of grand total") { f, axis, _ in "DIVIDE(\(f), COLLAPSEALL(\(f), \(axis ?? "ROWS")))" },
        VisualCalcTemplate(id: "averageOfChildren", name: "Average of children", description: "The average of the values one level below.",
                           suffix: "average of children") { f, axis, _ in "EXPAND(AVERAGE(\(f)), \(axis ?? "ROWS"))" },
        VisualCalcTemplate(id: "versusPrevious", name: "Versus previous", description: "The difference from the previous row.",
                           suffix: "versus previous") { f, axis, _ in "\(f) - PREVIOUS(\(f)\(axis.map { ", 1, \($0)" } ?? ""))" },
        VisualCalcTemplate(id: "versusNext", name: "Versus next", description: "The difference from the next row.",
                           suffix: "versus next") { f, axis, _ in "\(f) - NEXT(\(f)\(axis.map { ", 1, \($0)" } ?? ""))" },
        VisualCalcTemplate(id: "versusFirst", name: "Versus first", description: "The difference from the first row.",
                           suffix: "versus first") { f, axis, _ in "\(f) - FIRST(\(f)\(axis.map { ", \($0)" } ?? ""))" },
        VisualCalcTemplate(id: "versusLast", name: "Versus last", description: "The difference from the last row.",
                           suffix: "versus last") { f, axis, _ in "\(f) - LAST(\(f)\(axis.map { ", \($0)" } ?? ""))" },
    ]

    public static func template(id: String) -> VisualCalcTemplate? { all.first { $0.id == id } }
}
