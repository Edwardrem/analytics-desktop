import Foundation
import FacetCore
import FacetQuery

/// Transform ▸ Data Type: one command per type the model supports.
@MainActor
enum DataTypeCommands {
    static let types: [(type: DataType, title: String)] = [
        (.decimal, "Decimal Number"), (.currency, "Fixed Decimal Number"), (.integer, "Whole Number"),
        (.dateTime, "Date/Time"), (.date, "Date"), (.time, "Time"), (.duration, "Duration"),
        (.text, "Text"), (.boolean, "True/False"), (.binary, "Binary"),
    ]
    static func id(_ type: DataType) -> String { "pq.type.\(type.rawValue)" }

    static let all: [EditorCommand] = types.map { entry in
        EditorCommand(id: id(entry.type), title: entry.title, symbol: QueryCellText.typeSymbol(entry.type), blocker: Need.columns) { s in
            s.changeTypes(s.selectedColumns.map { ($0, entry.type) }, culture: nil)
        }
    }
}

/// Text, number and date/time column operations, for the Transform tab (in place) and the Add Column tab (new column).
@MainActor
enum ColumnOperationCommands {
    // MARK: Titles and new-column names (Power Query's)

    static let textFormats: [(TextFormat, String, String)] = [
        (.lowercase, "lowercase", "lowercase"), (.uppercase, "UPPERCASE", "UPPERCASE"), (.capitalizeEachWord, "Capitalize Each Word", "Capitalized Each Word"),
        (.trim, "Trim", "Trim"), (.clean, "Clean", "Clean"),
    ]
    static let extracts: [(String, String, EditorDialog.ExtractKind?)] = [
        ("length", "Length", nil), ("first", "First Characters…", .first), ("last", "Last Characters…", .last), ("range", "Range…", .range),
        ("before", "Text Before Delimiter…", .before), ("after", "Text After Delimiter…", .after), ("between", "Text Between Delimiters…", .between),
    ]
    static let statistics: [(ColumnStatistic, String)] = [
        (.sum, "Sum"), (.minimum, "Minimum"), (.maximum, "Maximum"), (.median, "Median"), (.average, "Average"),
        (.standardDeviation, "Standard Deviation"), (.countValues, "Count Values"), (.countDistinctValues, "Count Distinct Values"),
    ]
    /// Number operations without a value: (operation, id, title, new column name).
    static let unaryNumbers: [(NumberOperation, String, String, String)] = [
        (.absolute, "absolute", "Absolute Value", "Absolute Value"), (.squareRoot, "sqrt", "Square Root", "Square Root"),
        (.exponent, "exp", "Exponent", "Exponent"), (.log10, "log10", "Base-10", "Base-10 Logarithm"), (.naturalLog, "ln", "Natural", "Natural Logarithm"),
        (.factorial, "factorial", "Factorial", "Factorial"),
        (.sine, "sin", "Sine", "Sine"), (.cosine, "cos", "Cosine", "Cosine"), (.tangent, "tan", "Tangent", "Tangent"),
        (.arcsine, "asin", "Arcsine", "Arcsine"), (.arccosine, "acos", "Arccosine", "Arccosine"), (.arctangent, "atan", "Arctangent", "Arctangent"),
        (.roundUp, "roundUp", "Round Up", "Round Up"), (.roundDown, "roundDown", "Round Down", "Round Down"),
        (.isEven, "isEven", "Is Even", "Is Even"), (.isOdd, "isOdd", "Is Odd", "Is Odd"), (.sign, "sign", "Sign", "Sign"),
    ]
    static let valueNumbers: [EditorDialog.NumberValueKind] = [.add, .multiply, .subtract, .divide, .integerDivide, .modulo, .percentage, .percentOf, .power, .round]

    /// Date and time operations: (operation, title, new column name, kind of column it needs).
    enum Needs { case date, time, duration }
    static let dates: [(DateOperation, String, String, Needs)] = [
        (.age, "Age", "Age", .date), (.dateOnly, "Date Only", "Date", .date),
        (.year, "Year", "Year", .date), (.startOfYear, "Start of Year", "Start of Year", .date), (.endOfYear, "End of Year", "End of Year", .date),
        (.month, "Month", "Month", .date), (.startOfMonth, "Start of Month", "Start of Month", .date), (.endOfMonth, "End of Month", "End of Month", .date),
        (.daysInMonth, "Days in Month", "Days in Month", .date), (.monthName, "Name of Month", "Month Name", .date),
        (.quarter, "Quarter of Year", "Quarter", .date), (.startOfQuarter, "Start of Quarter", "Start of Quarter", .date), (.endOfQuarter, "End of Quarter", "End of Quarter", .date),
        (.weekOfYear, "Week of Year", "Week of Year", .date), (.weekOfMonth, "Week of Month", "Week of Month", .date),
        (.startOfWeek, "Start of Week", "Start of Week", .date), (.endOfWeek, "End of Week", "End of Week", .date),
        (.day, "Day", "Day", .date), (.dayOfWeek, "Day of Week", "Day of Week", .date), (.dayOfYear, "Day of Year", "Day of Year", .date),
        (.startOfDay, "Start of Day", "Start of Day", .date), (.endOfDay, "End of Day", "End of Day", .date), (.dayName, "Name of Day", "Day Name", .date),
        (.timeOnly, "Time Only", "Time", .time), (.hour, "Hour", "Hour", .time), (.startOfHour, "Start of Hour", "Start of Hour", .time),
        (.endOfHour, "End of Hour", "End of Hour", .time), (.minute, "Minute", "Minute", .time), (.second, "Second", "Second", .time),
        (.durationDays, "Days", "Days", .duration), (.durationHours, "Hours", "Hours", .duration), (.durationMinutes, "Minutes", "Minutes", .duration),
        (.durationSeconds, "Seconds", "Seconds", .duration), (.totalDays, "Total Days", "Total Days", .duration),
        (.totalHours, "Total Hours", "Total Hours", .duration), (.totalMinutes, "Total Minutes", "Total Minutes", .duration),
        (.totalSeconds, "Total Seconds", "Total Seconds", .duration),
    ]
    static func need(_ n: Needs) -> @MainActor (QueryEditorSession) -> String? {
        switch n {
        case .date: return Need.date
        case .time: return Need.time
        case .duration: return Need.duration
        }
    }
    private static func newName(_ s: QueryEditorSession, _ base: String) -> String { QueryEditorPlans.uniqueColumnName(base, taken: s.columnNames) }

    // MARK: Transform tab (in place)

    static let transform: [EditorCommand] =
        textFormats.map { fmt, title, _ in
            EditorCommand(id: "pq.text.\(fmt.rawValue)", title: title, symbol: "textformat", blocker: Need.text) { $0.apply(.formatText(columns: $0.selectedColumns, fmt)) }
        }
        + extracts.map { id, title, kind in
            EditorCommand(id: "pq.extract.\(id)", title: title, symbol: "text.viewfinder", blocker: Need.text) { s in
                if let kind { s.dialog = .extract(columns: s.selectedColumns, kind, asNewColumn: false) }
                else { s.apply(.extractText(column: s.selectedColumns.first ?? "", .length, newColumn: nil)) }
            }
        }
        + statistics.map { stat, title in
            EditorCommand(id: "pq.stat.\(stat.rawValue)", title: title, symbol: "sum", blocker: { s in Need.oneColumn(s) ?? Need.number(s) }) {
                $0.apply(.statistic(column: $0.selectedColumns.first ?? "", stat))
            }
        }
        + unaryNumbers.map { op, id, title, _ in
            EditorCommand(id: "pq.num.\(id)", title: title, symbol: "plus.forwardslash.minus", blocker: Need.number) { $0.apply(.number(columns: $0.selectedColumns, op, newColumn: nil)) }
        }
        + valueNumbers.map { kind in
            EditorCommand(id: "pq.num.\(kind.rawValue)", title: kind.title + "…", symbol: "plus.forwardslash.minus", blocker: Need.number) {
                $0.dialog = .numberValue(columns: $0.selectedColumns, kind, asNewColumn: false)
            }
        }
        + dates.map { op, title, _, needs in
            EditorCommand(id: "pq.date.\(op.rawValue)", title: title, symbol: "calendar", blocker: need(needs)) { $0.apply(.date(columns: $0.selectedColumns, op, newColumn: nil)) }
        }

    // MARK: Add Column tab (new column from the first selected column)

    static let addColumn: [EditorCommand] =
        textFormats.map { fmt, title, _ in
            EditorCommand(id: "pq.add.text.\(fmt.rawValue)", title: title, symbol: "textformat", blocker: { s in Need.oneColumn(s) ?? Need.text(s) }) { s in
                let column = s.selectedColumns.first ?? ""
                let fn = ["lowercase": "Text.Lower", "uppercase": "Text.Upper", "capitalizeEachWord": "Text.Proper", "trim": "Text.Trim", "clean": "Text.Clean"][fmt.rawValue] ?? "Text.From"
                EditorCommands.addCustom(s, title, "\(fn)(\(MSyntax.field(column)))", .text)
            }
        }
        + extracts.map { id, title, kind in
            EditorCommand(id: "pq.add.extract.\(id)", title: title, symbol: "text.viewfinder", blocker: { s in Need.oneColumn(s) ?? Need.text(s) }) { s in
                if let kind { s.dialog = .extract(columns: s.selectedColumns, kind, asNewColumn: true) }
                else { s.apply(.extractText(column: s.selectedColumns.first ?? "", .length, newColumn: newName(s, "Length"))) }
            }
        }
        + statistics.map { stat, title in
            // Row-wise statistics across the selected columns.
            EditorCommand(id: "pq.add.stat.\(stat.rawValue)", title: title, symbol: "sum", blocker: Need.number) { s in
                let list = "{" + s.selectedColumns.map(MSyntax.field).joined(separator: ", ") + "}"
                let body: String
                switch stat {
                case .sum: body = "List.Sum(\(list))"
                case .minimum: body = "List.Min(\(list))"
                case .maximum: body = "List.Max(\(list))"
                case .median: body = "List.Median(\(list))"
                case .average: body = "List.Average(\(list))"
                case .standardDeviation: body = "List.StandardDeviation(\(list))"
                case .countValues: body = "List.NonNullCount(\(list))"
                case .countDistinctValues: body = "List.Count(List.Distinct(\(list)))"
                }
                EditorCommands.addCustom(s, title, body, stat == .countValues || stat == .countDistinctValues ? .integer : .decimal)
            }
        }
        + unaryNumbers.map { op, id, title, column in
            EditorCommand(id: "pq.add.num.\(id)", title: title, symbol: "plus.forwardslash.minus", blocker: { s in Need.oneColumn(s) ?? Need.number(s) }) { s in
                s.apply(.number(columns: s.selectedColumns, op, newColumn: newName(s, column)))
            }
        }
        + valueNumbers.map { kind in
            EditorCommand(id: "pq.add.num.\(kind.rawValue)", title: kind.title + "…", symbol: "plus.forwardslash.minus", blocker: { s in Need.oneColumn(s) ?? Need.number(s) }) {
                $0.dialog = .numberValue(columns: $0.selectedColumns, kind, asNewColumn: true)
            }
        }
        + dates.map { op, title, column, needs in
            EditorCommand(id: "pq.add.date.\(op.rawValue)", title: title, symbol: "calendar", blocker: { s in Need.oneColumn(s) ?? need(needs)(s) }) { s in
                s.apply(.date(columns: s.selectedColumns, op, newColumn: newName(s, column)))
            }
        }

    /// New column names for value operations (Add Column ▸ Standard…).
    static func newColumnName(_ kind: EditorDialog.NumberValueKind) -> String {
        switch kind {
        case .add: return "Addition"
        case .subtract: return "Subtraction"
        case .multiply: return "Multiplication"
        case .divide: return "Division"
        case .integerDivide: return "Integer-Division"
        case .modulo: return "Modulo"
        case .percentage: return "Percentage"
        case .percentOf: return "Percent Of"
        case .power: return "Power"
        case .round: return "Round"
        }
    }
}
