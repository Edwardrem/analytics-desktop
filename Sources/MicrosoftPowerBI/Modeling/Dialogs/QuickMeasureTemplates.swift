import Foundation
import FacetCore

/// The quick-measure catalog and its DAX generators. Pure: no UI, no store.
enum QuickMeasureTemplates {
    enum Calculation: String, CaseIterable, Identifiable {
        // Aggregate per category
        case averagePerCategory, variancePerCategory, maxPerCategory, minPerCategory, weightedAveragePerCategory
        // Filters
        case filteredValue, differenceFromFiltered, percentDifferenceFromFiltered
        // Time intelligence
        case yearToDate, quarterToDate, monthToDate, yearOverYear, quarterOverQuarter, monthOverMonth, rollingAverage
        // Totals
        case runningTotal, totalForCategoryFiltered, totalForCategoryUnfiltered
        // Mathematical operations
        case addition, subtraction, multiplication, division, percentageDifference, correlation
        // Text
        case starRating, concatenatedList

        var id: String { rawValue }
        var title: String {
            switch self {
            case .averagePerCategory: return "Average per category"
            case .variancePerCategory: return "Variance per category"
            case .maxPerCategory: return "Max per category"
            case .minPerCategory: return "Min per category"
            case .weightedAveragePerCategory: return "Weighted average per category"
            case .filteredValue: return "Filtered value"
            case .differenceFromFiltered: return "Difference from filtered value"
            case .percentDifferenceFromFiltered: return "Percentage difference from filtered value"
            case .yearToDate: return "Year-to-date total"
            case .quarterToDate: return "Quarter-to-date total"
            case .monthToDate: return "Month-to-date total"
            case .yearOverYear: return "Year-over-year change"
            case .quarterOverQuarter: return "Quarter-over-quarter change"
            case .monthOverMonth: return "Month-over-month change"
            case .rollingAverage: return "Rolling average"
            case .runningTotal: return "Running total"
            case .totalForCategoryFiltered: return "Total for category (filters applied)"
            case .totalForCategoryUnfiltered: return "Total for category (filters not applied)"
            case .addition: return "Addition"
            case .subtraction: return "Subtraction"
            case .multiplication: return "Multiplication"
            case .division: return "Division"
            case .percentageDifference: return "Percentage difference"
            case .correlation: return "Correlation coefficient"
            case .starRating: return "Star rating"
            case .concatenatedList: return "Concatenated list of values"
            }
        }
        var summary: String {
            switch self {
            case .averagePerCategory: return "The average of the base value across each category."
            case .variancePerCategory: return "The variance of the base value across each category."
            case .maxPerCategory: return "The largest base value of any category."
            case .minPerCategory: return "The smallest base value of any category."
            case .weightedAveragePerCategory: return "The average of the base value per category, weighted by another value."
            case .filteredValue: return "The base value with a fixed filter applied."
            case .differenceFromFiltered: return "How far the base value is from its filtered baseline."
            case .percentDifferenceFromFiltered: return "The relative change of the base value against its filtered baseline."
            case .yearToDate: return "The base value accumulated from the start of the year."
            case .quarterToDate: return "The base value accumulated from the start of the quarter."
            case .monthToDate: return "The base value accumulated from the start of the month."
            case .yearOverYear: return "The relative change against the same period in an earlier year."
            case .quarterOverQuarter: return "The relative change against an earlier quarter."
            case .monthOverMonth: return "The relative change against an earlier month."
            case .rollingAverage: return "The average of the base value over a moving window of periods."
            case .runningTotal: return "The base value accumulated along a field."
            case .totalForCategoryFiltered: return "The total across every category still visible after filters."
            case .totalForCategoryUnfiltered: return "The total across every category, ignoring filters on it."
            case .addition: return "The sum of two values."
            case .subtraction: return "One value minus another."
            case .multiplication: return "The product of two values."
            case .division: return "One value divided by another, blank when the divisor is zero."
            case .percentageDifference: return "The relative difference between two values."
            case .correlation: return "The Pearson correlation of two measures across a category."
            case .starRating: return "The base value drawn as filled and empty stars."
            case .concatenatedList: return "The distinct values of a column joined into one text."
            }
        }
        /// Suggested display format for the new measure.
        var formatString: String {
            switch self {
            case .percentDifferenceFromFiltered, .yearOverYear, .quarterOverQuarter, .monthOverMonth, .percentageDifference: return "0.0%"
            case .correlation: return "0.00"
            default: return ""
            }
        }
    }

    static let groups: [(name: String, calculations: [Calculation])] = [
        ("Aggregate per category", [.averagePerCategory, .variancePerCategory, .maxPerCategory, .minPerCategory, .weightedAveragePerCategory]),
        ("Filters", [.filteredValue, .differenceFromFiltered, .percentDifferenceFromFiltered]),
        ("Time intelligence", [.yearToDate, .quarterToDate, .monthToDate, .yearOverYear, .quarterOverQuarter, .monthOverMonth, .rollingAverage]),
        ("Totals", [.runningTotal, .totalForCategoryFiltered, .totalForCategoryUnfiltered]),
        ("Mathematical operations", [.addition, .subtraction, .multiplication, .division, .percentageDifference, .correlation]),
        ("Text", [.starRating, .concatenatedList]),
    ]

    enum SlotKind { case value, column, dateColumn, measure }
    /// One field input of a template.
    struct Slot: Identifiable {
        var key: String
        var title: String
        var kind: SlotKind
        var id: String { key }
    }
    enum OptionKind { case integer(ClosedRange<Int>), number, choice([String]) }
    /// One non-field input of a template.
    struct Option: Identifiable {
        var key: String
        var title: String
        var kind: OptionKind
        var defaultValue: String
        var id: String { key }
    }

    struct Inputs {
        var fields: [String: [FieldRef]] = [:]
        var options: [String: String] = [:]
        /// Values picked for the filter templates.
        var filterValues: [Value] = []
        init() {}
        func field(_ key: String) -> FieldRef? { fields[key]?.first }
    }

    static func slots(_ c: Calculation) -> [Slot] {
        let base = Slot(key: "base", title: "Base value", kind: .value)
        let category = Slot(key: "category", title: "Category", kind: .column)
        let date = Slot(key: "date", title: "Date", kind: .dateColumn)
        switch c {
        case .averagePerCategory, .variancePerCategory, .maxPerCategory, .minPerCategory: return [base, category]
        case .weightedAveragePerCategory: return [base, Slot(key: "weight", title: "Weight", kind: .value), category]
        case .filteredValue, .differenceFromFiltered, .percentDifferenceFromFiltered: return [base, Slot(key: "filter", title: "Filter", kind: .column)]
        case .yearToDate, .quarterToDate, .monthToDate, .yearOverYear, .quarterOverQuarter, .monthOverMonth, .rollingAverage: return [base, date]
        case .runningTotal: return [base, Slot(key: "field", title: "Field", kind: .column)]
        case .totalForCategoryFiltered, .totalForCategoryUnfiltered: return [base, category]
        case .addition: return [base, Slot(key: "second", title: "Value to add", kind: .value)]
        case .subtraction: return [base, Slot(key: "second", title: "Value to subtract", kind: .value)]
        case .multiplication: return [base, Slot(key: "second", title: "Value to multiply by", kind: .value)]
        case .division: return [Slot(key: "base", title: "Numerator", kind: .value), Slot(key: "second", title: "Denominator", kind: .value)]
        case .percentageDifference: return [base, Slot(key: "second", title: "Value to compare", kind: .value)]
        case .correlation: return [category, Slot(key: "x", title: "Measure X", kind: .value), Slot(key: "y", title: "Measure Y", kind: .value)]
        case .starRating: return [base]
        case .concatenatedList: return [Slot(key: "field", title: "Field", kind: .column)]
        }
    }

    static func options(_ c: Calculation) -> [Option] {
        switch c {
        case .yearOverYear, .quarterOverQuarter, .monthOverMonth:
            return [Option(key: "periods", title: "Number of periods", kind: .integer(1...120), defaultValue: "1")]
        case .rollingAverage:
            return [Option(key: "unit", title: "Period", kind: .choice(["Days", "Months", "Quarters", "Years"]), defaultValue: "Months"),
                    Option(key: "before", title: "Periods before", kind: .integer(0...366), defaultValue: "3"),
                    Option(key: "after", title: "Periods after", kind: .integer(0...366), defaultValue: "0")]
        case .runningTotal:
            return [Option(key: "direction", title: "Direction", kind: .choice(["Ascending", "Descending"]), defaultValue: "Ascending")]
        case .starRating:
            return [Option(key: "stars", title: "Number of stars", kind: .integer(1...10), defaultValue: "5"),
                    Option(key: "low", title: "Lowest star value", kind: .number, defaultValue: "0"),
                    Option(key: "high", title: "Highest star value", kind: .number, defaultValue: "100")]
        case .concatenatedList:
            return [Option(key: "max", title: "Values before truncation", kind: .integer(1...100), defaultValue: "3")]
        default: return []
        }
    }
    static var needsFilterValues: Set<Calculation> { [.filteredValue, .differenceFromFiltered, .percentDifferenceFromFiltered] }

    /// What is still missing before DAX can be generated, or nil when the inputs are complete.
    static func missing(_ c: Calculation, _ inputs: Inputs) -> String? {
        for s in slots(c) where inputs.field(s.key) == nil { return "Add a field to “\(s.title)”." }
        if needsFilterValues.contains(c), inputs.filterValues.isEmpty { return "Choose at least one filter value." }
        if c == .starRating, number(inputs, "high", 100) <= number(inputs, "low", 0) { return "The highest star value must be greater than the lowest." }
        return nil
    }

    private static func number(_ i: Inputs, _ key: String, _ fallback: Double) -> Double {
        i.options[key].flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } ?? fallback
    }
    private static func int(_ i: Inputs, _ key: String, _ fallback: Int) -> Int { Int(number(i, key, Double(fallback)).rounded()) }

    /// The measure name Power BI-style: "Sales average per Category".
    static func suggestedName(_ c: Calculation, _ inputs: Inputs) -> String {
        let base = inputs.field("base")?.caption ?? "Value"
        let category = inputs.field("category")?.name ?? "category"
        switch c {
        case .averagePerCategory: return "\(base) average per \(category)"
        case .variancePerCategory: return "\(base) variance per \(category)"
        case .maxPerCategory: return "\(base) max per \(category)"
        case .minPerCategory: return "\(base) min per \(category)"
        case .weightedAveragePerCategory: return "\(base) weighted by \(inputs.field("weight")?.caption ?? "weight") per \(category)"
        case .filteredValue: return "\(base) for \(filterCaption(inputs))"
        case .differenceFromFiltered: return "\(base) difference from \(filterCaption(inputs))"
        case .percentDifferenceFromFiltered: return "\(base) % difference from \(filterCaption(inputs))"
        case .yearToDate: return "\(base) YTD"
        case .quarterToDate: return "\(base) QTD"
        case .monthToDate: return "\(base) MTD"
        case .yearOverYear: return "\(base) YoY %"
        case .quarterOverQuarter: return "\(base) QoQ %"
        case .monthOverMonth: return "\(base) MoM %"
        case .rollingAverage: return "\(base) rolling average"
        case .runningTotal: return "\(base) running total in \(inputs.field("field")?.name ?? "field")"
        case .totalForCategoryFiltered: return "\(base) total for \(category)"
        case .totalForCategoryUnfiltered: return "\(base) total for all \(category)"
        case .addition: return "\(base) plus \(inputs.field("second")?.caption ?? "value")"
        case .subtraction: return "\(base) minus \(inputs.field("second")?.caption ?? "value")"
        case .multiplication: return "\(base) times \(inputs.field("second")?.caption ?? "value")"
        case .division: return "\(base) divided by \(inputs.field("second")?.caption ?? "value")"
        case .percentageDifference: return "\(inputs.field("second")?.caption ?? "Value") % difference from \(base)"
        case .correlation: return "\(inputs.field("x")?.caption ?? "X") and \(inputs.field("y")?.caption ?? "Y") correlation for \(category)"
        case .starRating: return "\(base) star rating"
        case .concatenatedList: return "List of \(inputs.field("field")?.name ?? "field") values"
        }
    }
    private static func filterCaption(_ i: Inputs) -> String {
        let shown = i.filterValues.prefix(2).map { ValueFormatter.format($0) }.joined(separator: ", ")
        return shown.isEmpty ? (i.field("filter")?.name ?? "filter") : shown + (i.filterValues.count > 2 ? "…" : "")
    }

    /// The DAX expression for a template, or nil while inputs are incomplete.
    static func dax(_ c: Calculation, _ inputs: Inputs, model: SemanticModel) -> String? {
        guard missing(c, inputs) == nil else { return nil }
        func value(_ key: String) -> String { inputs.field(key).map { ModelDAX.aggregate($0, model: model) } ?? "BLANK()" }
        func column(_ key: String) -> String { inputs.field(key).map { ModelDAX.column($0.table, $0.name) } ?? "" }
        let base = value("base")

        func perCategory(_ iterator: String) -> String {
            "\(iterator)(\n    KEEPFILTERS(VALUES(\(column("category")))),\n    CALCULATE(\(base))\n)"
        }
        func filterPredicate() -> String {
            let col = column("filter")
            let nonBlank = inputs.filterValues.filter { !$0.isNull }
            var parts: [String] = []
            if !nonBlank.isEmpty { parts.append("\(col) IN { \(nonBlank.map(ModelDAX.literal).joined(separator: ", ")) }") }
            if nonBlank.count != inputs.filterValues.count { parts.append("ISBLANK(\(col))") }
            return parts.joined(separator: " || ")
        }
        func filtered() -> String {
            let needsKeepAll = inputs.filterValues.contains { $0.isNull }
            let col = column("filter")
            return needsKeepAll ? "CALCULATE(\(base), FILTER(ALL(\(col)), \(filterPredicate())))" : "CALCULATE(\(base), \(filterPredicate()))"
        }
        func periodChange(_ unit: String, _ variable: String) -> String {
            let n = max(1, int(inputs, "periods", 1))
            return """
            VAR \(variable) =
                CALCULATE(\(base), DATEADD(\(column("date")), -\(n), \(unit)))
            RETURN
                DIVIDE(\(base) - \(variable), \(variable))
            """
        }

        switch c {
        case .averagePerCategory: return perCategory("AVERAGEX")
        case .variancePerCategory: return perCategory("VARX.S")
        case .maxPerCategory: return perCategory("MAXX")
        case .minPerCategory: return perCategory("MINX")
        case .weightedAveragePerCategory:
            let w = value("weight")
            return """
            VAR __CATEGORY_VALUES = VALUES(\(column("category")))
            RETURN
                DIVIDE(
                    SUMX(KEEPFILTERS(__CATEGORY_VALUES), CALCULATE(\(base) * \(w))),
                    SUMX(KEEPFILTERS(__CATEGORY_VALUES), CALCULATE(\(w)))
                )
            """
        case .filteredValue: return filtered()
        case .differenceFromFiltered:
            return """
            VAR __BASELINE_VALUE = \(filtered())
            VAR __VALUE_TO_COMPARE = \(base)
            RETURN
                IF(NOT ISBLANK(__VALUE_TO_COMPARE), __VALUE_TO_COMPARE - __BASELINE_VALUE)
            """
        case .percentDifferenceFromFiltered:
            return """
            VAR __BASELINE_VALUE = \(filtered())
            VAR __VALUE_TO_COMPARE = \(base)
            RETURN
                IF(
                    NOT ISBLANK(__VALUE_TO_COMPARE),
                    DIVIDE(__VALUE_TO_COMPARE - __BASELINE_VALUE, __BASELINE_VALUE)
                )
            """
        case .yearToDate: return "TOTALYTD(\(base), \(column("date")))"
        case .quarterToDate: return "TOTALQTD(\(base), \(column("date")))"
        case .monthToDate: return "TOTALMTD(\(base), \(column("date")))"
        case .yearOverYear: return periodChange("YEAR", "__PREV_YEAR")
        case .quarterOverQuarter: return periodChange("QUARTER", "__PREV_QUARTER")
        case .monthOverMonth: return periodChange("MONTH", "__PREV_MONTH")
        case .rollingAverage:
            let d = column("date")
            let before = max(0, int(inputs, "before", 3)), after = max(0, int(inputs, "after", 0))
            let unit = inputs.options["unit"] ?? "Months"
            if unit == "Days" {
                return """
                VAR __LAST_DATE = LASTDATE(\(d))
                VAR __DATE_PERIOD =
                    DATESBETWEEN(\(d), DATEADD(__LAST_DATE, -\(before), DAY), DATEADD(__LAST_DATE, \(after), DAY))
                RETURN
                    AVERAGEX(__DATE_PERIOD, CALCULATE(\(base)))
                """
            }
            let (interval, start, end, key): (String, String, String, String)
            switch unit {
            case "Quarters": (interval, start, end, key) = ("QUARTER", "STARTOFQUARTER", "ENDOFQUARTER", "YEAR(\(d)) * 4 + QUARTER(\(d))")
            case "Years": (interval, start, end, key) = ("YEAR", "STARTOFYEAR", "ENDOFYEAR", "YEAR(\(d))")
            default: (interval, start, end, key) = ("MONTH", "STARTOFMONTH", "ENDOFMONTH", "YEAR(\(d)) * 12 + MONTH(\(d))")
            }
            return """
            VAR __LAST_DATE = LASTDATE(\(d))
            VAR __DATE_PERIOD =
                DATESBETWEEN(
                    \(d),
                    \(start)(DATEADD(__LAST_DATE, -\(before), \(interval))),
                    \(end)(DATEADD(__LAST_DATE, \(after), \(interval)))
                )
            VAR __PERIODS = DISTINCT(SELECTCOLUMNS(__DATE_PERIOD, "__Period", \(key)))
            RETURN
                AVERAGEX(
                    __PERIODS,
                    VAR __PERIOD = [__Period]
                    RETURN CALCULATE(\(base), FILTER(__DATE_PERIOD, \(key) = __PERIOD))
                )
            """
        case .runningTotal:
            let f = column("field")
            let order = (inputs.options["direction"] ?? "Ascending") == "Descending" ? "ASC" : "DESC"
            return """
            CALCULATE(
                \(base),
                FILTER(
                    ALLSELECTED(\(f)),
                    ISONORAFTER(\(f), MAX(\(f)), \(order))
                )
            )
            """
        case .totalForCategoryFiltered: return "CALCULATE(\(base), ALLSELECTED(\(column("category"))))"
        case .totalForCategoryUnfiltered: return "CALCULATE(\(base), ALL(\(column("category"))))"
        case .addition: return "\(base) + \(value("second"))"
        case .subtraction: return "\(base) - \(value("second"))"
        case .multiplication: return "\(base) * \(value("second"))"
        case .division: return "DIVIDE(\(base), \(value("second")))"
        case .percentageDifference:
            return """
            VAR __BASELINE_VALUE = \(base)
            VAR __VALUE_TO_COMPARE = \(value("second"))
            RETURN
                IF(
                    NOT ISBLANK(__VALUE_TO_COMPARE),
                    DIVIDE(__VALUE_TO_COMPARE - __BASELINE_VALUE, __BASELINE_VALUE)
                )
            """
        case .correlation:
            let x = value("x"), y = value("y")
            return """
            VAR __CORRELATION_TABLE = VALUES(\(column("category")))
            VAR __COUNT =
                COUNTX(KEEPFILTERS(__CORRELATION_TABLE), CALCULATE(\(x) * \(y)))
            VAR __SUM_X = SUMX(KEEPFILTERS(__CORRELATION_TABLE), CALCULATE(\(x)))
            VAR __SUM_Y = SUMX(KEEPFILTERS(__CORRELATION_TABLE), CALCULATE(\(y)))
            VAR __SUM_XY =
                SUMX(KEEPFILTERS(__CORRELATION_TABLE), CALCULATE(\(x) * \(y) * 1.0))
            VAR __SUM_X2 = SUMX(KEEPFILTERS(__CORRELATION_TABLE), CALCULATE(\(x) ^ 2))
            VAR __SUM_Y2 = SUMX(KEEPFILTERS(__CORRELATION_TABLE), CALCULATE(\(y) ^ 2))
            RETURN
                DIVIDE(
                    __COUNT * __SUM_XY - __SUM_X * __SUM_Y * 1.0,
                    SQRT(
                        (__COUNT * __SUM_X2 - __SUM_X ^ 2)
                            * (__COUNT * __SUM_Y2 - __SUM_Y ^ 2)
                    )
                )
            """
        case .starRating:
            let stars = max(1, int(inputs, "stars", 5))
            return """
            VAR __MAX_NUMBER_OF_STARS = \(stars)
            VAR __MIN_RATED_VALUE = \(ModelDAX.number(number(inputs, "low", 0)))
            VAR __MAX_RATED_VALUE = \(ModelDAX.number(number(inputs, "high", 100)))
            VAR __BASE_VALUE = \(base)
            VAR __NORMALIZED_BASE_VALUE =
                MIN(
                    MAX(
                        DIVIDE(
                            __BASE_VALUE - __MIN_RATED_VALUE,
                            __MAX_RATED_VALUE - __MIN_RATED_VALUE
                        ),
                        0
                    ),
                    1
                )
            VAR __STAR_RATING = ROUND(__NORMALIZED_BASE_VALUE * __MAX_NUMBER_OF_STARS, 0)
            RETURN
                IF(
                    NOT ISBLANK(__BASE_VALUE),
                    REPT(UNICHAR(9733), __STAR_RATING)
                        & REPT(UNICHAR(9734), __MAX_NUMBER_OF_STARS - __STAR_RATING)
                )
            """
        case .concatenatedList:
            let f = column("field")
            return """
            VAR __DISTINCT_VALUES_COUNT = DISTINCTCOUNT(\(f))
            VAR __MAX_VALUES_TO_SHOW = \(max(1, int(inputs, "max", 3)))
            RETURN
                IF(
                    __DISTINCT_VALUES_COUNT > __MAX_VALUES_TO_SHOW,
                    CONCATENATE(
                        CONCATENATEX(
                            TOPN(__MAX_VALUES_TO_SHOW, VALUES(\(f)), \(f), ASC),
                            \(f),
                            ", ",
                            \(f),
                            ASC
                        ),
                        ", etc."
                    ),
                    CONCATENATEX(VALUES(\(f)), \(f), ", ", \(f), ASC)
                )
            """
        }
    }
}
