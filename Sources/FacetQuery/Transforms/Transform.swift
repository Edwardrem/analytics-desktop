import Foundation
import FacetCore

/// A row-filter condition built by the filter UI. Renders to an M boolean expression over the row (`[Column] …`).
public indirect enum FilterCondition {
    public enum Comparison: String, CaseIterable, Sendable { case equals = "=", notEquals = "<>", greaterThan = ">", greaterOrEqual = ">=", lessThan = "<", lessOrEqual = "<=" }
    public enum TextMatch: String, CaseIterable, Sendable { case beginsWith, doesNotBeginWith, endsWith, doesNotEndWith, contains, doesNotContain }
    public enum DateUnit: String, CaseIterable, Sendable { case day = "Day", week = "Week", month = "Month", quarter = "Quarter", year = "Year" }
    public enum RelativeDate {
        case inCurrent(DateUnit), inPrevious(DateUnit), inNext(DateUnit)
        case inPreviousN(Int, DateUnit), inNextN(Int, DateUnit)
        case yearToDate
        case isEarliest, isLatest, isNotEarliest, isNotLatest
        case year(Int), quarter(Int), month(Int), day(Int)
    }
    /// `[column] op value`; `type` picks the literal form for dates (`.date` → `#date`, `.dateTime` → `#datetime`).
    case compare(column: String, Comparison, Value, type: DataType = .any)
    case text(column: String, TextMatch, String, ignoreCase: Bool = false)
    case isNull(column: String), isNotNull(column: String)
    case isBlank(column: String), isNotBlank(column: String)
    case between(column: String, Value, Value, type: DataType = .any)
    case inList(column: String, [Value], type: DataType = .any)
    case date(column: String, RelativeDate)
    case and([FilterCondition]), or([FilterCondition]), not(FilterCondition)
    /// A hand-written M boolean expression over the row, e.g. `[A] + [B] > 10`.
    case custom(String)
}

/// Aggregations offered by Group By, Pivot and "Aggregate" on table columns.
public enum GroupAggregation: Sendable {
    case sum(column: String), average(column: String), median(column: String), min(column: String), max(column: String)
    case standardDeviation(column: String), countDistinct(column: String)
    case countRows, countDistinctRows, allRows
}

/// Kinds of join for Merge Queries (M `JoinKind.*`).
public enum MergeJoinKind: String, CaseIterable, Sendable {
    case leftOuter = "LeftOuter", rightOuter = "RightOuter", fullOuter = "FullOuter", inner = "Inner", leftAnti = "LeftAnti", rightAnti = "RightAnti"
}

/// Fuzzy matching options for Merge Queries.
public struct FuzzyMergeOptions: Sendable {
    public var threshold: Double = 0.8
    public var ignoreCase = true
    public var ignoreSpace = true
    public var maximumMatches: Int?
    /// Name of a query holding a From/To transformation table.
    public var transformationTable: String?
    public init(threshold: Double = 0.8) { self.threshold = threshold }
}

public enum SplitPosition: Sendable { case leftmost, rightmost, each }
public enum SplitTarget: Sendable {
    /// Split into this many new columns (the UI counts the parts in the preview, as Power Query does).
    case columns(Int)
    case rows
}
public enum CharacterTransition: Sendable { case lowerToUpper, upperToLower, digitToNonDigit, nonDigitToDigit }

public enum TextFormat: String, CaseIterable, Sendable { case lowercase, uppercase, capitalizeEachWord, trim, clean }
public enum TextExtract: Sendable {
    case length, firstCharacters(Int), lastCharacters(Int), range(start: Int, count: Int)
    case beforeDelimiter(String), afterDelimiter(String), betweenDelimiters(String, String)
}
public enum ParseKind: String, Sendable { case json, xml }

public enum NumberOperation: Sendable {
    case add(Double), subtract(Double), multiply(Double), divide(Double), integerDivide(Double), modulo(Double)
    case percentage(Double), percentOf(Double)
    case absolute, power(Double), squareRoot, exponent, log10, naturalLog, factorial
    case sine, cosine, tangent, arcsine, arccosine, arctangent
    case round(digits: Int), roundUp, roundDown
    case isEven, isOdd, sign
}
public enum ColumnStatistic: String, CaseIterable, Sendable { case sum, minimum, maximum, median, average, standardDeviation, countValues, countDistinctValues }

public enum DateOperation: String, CaseIterable, Sendable {
    case age, dateOnly, timeOnly
    case year, startOfYear, endOfYear
    case quarter, startOfQuarter, endOfQuarter
    case month, monthName, startOfMonth, endOfMonth, daysInMonth
    case weekOfYear, weekOfMonth, startOfWeek, endOfWeek
    case day, dayOfWeek, dayOfYear, dayName, startOfDay, endOfDay
    case hour, minute, second, startOfHour, endOfHour
    case durationDays, durationHours, durationMinutes, durationSeconds
    case totalDays, totalHours, totalMinutes, totalSeconds
}

/// One `if` branch of a conditional column.
public struct ConditionalClause: Sendable {
    public enum Operator: String, CaseIterable, Sendable {
        case equals, notEquals, greaterThan, greaterOrEqual, lessThan, lessOrEqual, contains, doesNotContain, beginsWith, endsWith, isNull, isNotNull
    }
    public enum Operand: Sendable { case value(Value), column(String) }
    public var column: String
    public var op: Operator
    public var value: Operand
    public var output: Operand
    public init(column: String, op: Operator, value: Operand, output: Operand) {
        self.column = column; self.op = op; self.value = value; self.output = output
    }
}

public enum CombineFilesFormat: Sendable {
    case csv(delimiter: String, promoteHeaders: Bool)
    case json
    case excel(sheet: String?)
    case parquet
}

/// Every transformation the Power Query Editor UI can apply. Each case produces one M step:
/// `stepName` (the default Applied Steps label) and `expression(previous:)` (the M for the step, given the
/// identifier of the previous step). Use `MScript.appending(_:to:)` to add it to a query.
///
/// Where a `newColumn` parameter is nil the transformation is applied in place ("Transform" tab);
/// with a name it adds a column ("Add Column" tab).
public enum Transform {
    // Rows
    /// `first` is the 1-based row number, as typed in the Keep Range of Rows dialog.
    case keepTopRows(Int), keepBottomRows(Int), keepRangeOfRows(first: Int, count: Int)
    case removeTopRows(Int), removeBottomRows(Int)
    /// `firstToRemove` is the 1-based row number, as typed in the Remove Alternate Rows dialog.
    case removeAlternateRows(firstToRemove: Int, numberToRemove: Int, numberToKeep: Int)
    case removeDuplicates(columns: [String]), keepDuplicates(columns: [String])
    case removeBlankRows
    case removeErrors(columns: [String]), keepErrors(columns: [String])
    case filterRows(FilterCondition)
    case sortRows([(column: String, descending: Bool)])
    // Columns
    case chooseColumns([String]), removeColumns([String]), removeOtherColumns(keeping: [String])
    case reorderColumns([String]), renameColumns([(from: String, to: String)])
    case duplicateColumn(String, newName: String)
    case changeType([(column: String, type: DataType)], culture: String?)
    // Headers
    case promoteHeaders, demoteHeaders
    // Reshape
    case pivotColumn(column: String, valueColumn: String, aggregation: ColumnStatistic?)
    case unpivotColumns([String]), unpivotOtherColumns(keeping: [String])
    case transpose, reverseRows
    case groupBy(keys: [String], aggregations: [(name: String, aggregation: GroupAggregation)])
    case countRows
    // Split & merge
    case splitByDelimiter(column: String, delimiter: String, at: SplitPosition, into: SplitTarget)
    case splitByLength(column: String, length: Int, repeated: Bool, into: SplitTarget)
    case splitByPositions(column: String, positions: [Int], into: SplitTarget)
    case splitByTransition(column: String, CharacterTransition, into: SplitTarget)
    case mergeColumns([String], separator: String, newName: String)
    // Text
    case formatText(columns: [String], TextFormat)
    case addPrefix(columns: [String], String), addSuffix(columns: [String], String)
    case extractText(column: String, TextExtract, newColumn: String?)
    case parse(column: String, ParseKind)
    // Number
    case number(columns: [String], NumberOperation, newColumn: String?)
    case statistic(column: String, ColumnStatistic)
    // Date & time
    case date(columns: [String], DateOperation, newColumn: String?)
    case earliest(column: String), latest(column: String)
    // Fill & replace
    case fillDown([String]), fillUp([String])
    case replaceValues(columns: [String], find: Value, replaceWith: Value, matchEntireCell: Bool)
    case replaceErrors(columns: [String], with: Value)
    // Add column
    case addCustomColumn(name: String, expression: String, type: DataType?)
    case addConditionalColumn(name: String, clauses: [ConditionalClause], otherwise: ConditionalClause.Operand)
    case addIndexColumn(name: String, start: Int, increment: Int)
    case invokeCustomFunction(name: String, function: String, arguments: [ConditionalClause.Operand])
    /// A column inferred by `ColumnFromExamples.infer` (its `m` is a per-row expression).
    case addColumnFromExamples(name: String, expression: String)
    // Combine
    case mergeQueries(other: String, leftKeys: [String], rightKeys: [String], kind: MergeJoinKind, newColumn: String, fuzzy: FuzzyMergeOptions?)
    case appendQueries([String])
    case combineFiles(CombineFilesFormat)
    // Structured columns
    case expandRecordColumn(column: String, fields: [String], newNames: [String]?)
    case expandTableColumn(column: String, columns: [String], newNames: [String]?)
    case expandListColumn(column: String)
    case extractListValues(column: String, delimiter: String)
    case aggregateTableColumn(column: String, aggregations: [(column: String, statistic: ColumnStatistic, newName: String)])
    // AI & scripts
    case aiSentiment(column: String, newColumn: String), aiKeyPhrases(column: String, newColumn: String)
    case aiDetectLanguage(column: String, newColumn: String), aiTagImage(column: String, newColumn: String)
    case runPythonScript(String), runRScript(String)

    /// "Detect data type": inspects text columns of a preview table and returns the `changeType` transform
    /// Power Query would apply (nil when nothing would change).
    public static func detectTypes(in table: DataTable, culture: String? = nil) -> Transform? {
        var copy = table
        for i in copy.columns.indices where copy.columns[i].type == .any {
            copy.columns[i].type = DataTable.inferType(copy.columns[i].values)
        }
        let before = copy.columns.map(\.type)
        copy.detectAndConvertTextTypes()
        var changes: [(column: String, type: DataType)] = []
        for (i, c) in copy.columns.enumerated() where c.type != before[i] || (table.columns[i].type == .any && c.type != .any) {
            changes.append((c.name, c.type))
        }
        return changes.isEmpty ? nil : .changeType(changes, culture: culture)
    }
}
