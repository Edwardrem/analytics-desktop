import Foundation
import FacetCore

/// A value supplied for a quick-measure parameter.
public enum QuickMeasureArgument: Sendable, Hashable {
    case field(FieldRef)
    case number(Double)
    case text(String)
}

/// One input of a quick-measure template.
public struct QuickMeasureParameter: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        /// A measure or a column to aggregate.
        case value
        /// A column to group or filter by.
        case category
        /// A date column.
        case date
        case number
        case text
    }
    /// Key used in the argument dictionary.
    public var name: String
    public var kind: Kind
    /// Label shown next to the input.
    public var prompt: String
    /// Used when the argument is omitted; parameters without a default are required.
    public var defaultValue: QuickMeasureArgument?

    public init(name: String, kind: Kind, prompt: String, defaultValue: QuickMeasureArgument? = nil) {
        self.name = name; self.kind = kind; self.prompt = prompt; self.defaultValue = defaultValue
    }
}

/// A gallery entry that generates a DAX measure expression from chosen fields.
public struct QuickMeasureTemplate: Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Gallery section, e.g. "Time intelligence".
    public var category: String
    public var description: String
    public var parameters: [QuickMeasureParameter]
    let namer: @Sendable (QuickMeasureResolver) -> String
    let builder: @Sendable (QuickMeasureResolver) throws -> String

    /// A default name for the new measure, e.g. "Sales YTD".
    public func suggestedName(_ args: [String: QuickMeasureArgument]) -> String {
        namer(QuickMeasureResolver(template: self, args: args))
    }

    /// The formatted DAX expression for the measure. Throws `DAXError` when a required argument is missing or of the wrong kind.
    public func dax(_ args: [String: QuickMeasureArgument]) throws -> String {
        let r = QuickMeasureResolver(template: self, args: args)
        for p in parameters where p.defaultValue == nil && args[p.name] == nil {
            throw DAXError("“\(name)” needs a value for “\(p.prompt)”.")
        }
        return DAXFormatter.format(try builder(r))
    }
}

/// Turns template arguments into DAX fragments.
struct QuickMeasureResolver: Sendable {
    let template: QuickMeasureTemplate
    let args: [String: QuickMeasureArgument]

    private func arg(_ name: String) throws -> QuickMeasureArgument {
        if let a = args[name] { return a }
        if let d = template.parameters.first(where: { $0.name == name })?.defaultValue { return d }
        let prompt = template.parameters.first(where: { $0.name == name })?.prompt ?? name
        throw DAXError("“\(template.name)” needs a value for “\(prompt)”.")
    }
    private static func columnRef(_ f: FieldRef) -> String {
        "'" + f.table.replacingOccurrences(of: "'", with: "''") + "'[" + f.name.replacingOccurrences(of: "]", with: "]]") + "]"
    }
    /// A scalar expression: `[Measure]` or an aggregated column.
    func value(_ name: String) throws -> String {
        switch try arg(name) {
        case .number(let d): return QuickMeasureResolver.literal(d)
        case .text(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .field(let f):
            if f.kind == .measure { return "[" + f.name.replacingOccurrences(of: "]", with: "]]") + "]" }
            let col = QuickMeasureResolver.columnRef(f)
            switch f.aggregation {
            case .first: return "FIRSTNONBLANK(\(col), 1)"
            case .last: return "LASTNONBLANK(\(col), 1)"
            default: return "\(f.aggregation.daxFunction ?? "SUM")(\(col))"
            }
        }
    }
    /// A column reference `'Table'[Column]`.
    func column(_ name: String) throws -> String {
        guard case .field(let f) = try arg(name), f.kind == .column else {
            let prompt = template.parameters.first(where: { $0.name == name })?.prompt ?? name
            throw DAXError("“\(prompt)” must be a column.")
        }
        return QuickMeasureResolver.columnRef(f)
    }
    func number(_ name: String) throws -> Double {
        switch try arg(name) {
        case .number(let d): return d
        case .text(let s):
            if let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            throw DAXError("“\(s)” is not a number.")
        case .field: throw DAXError("“\(name)” must be a number.")
        }
    }
    func numberLiteral(_ name: String) throws -> String { QuickMeasureResolver.literal(try number(name)) }
    func text(_ name: String) throws -> String {
        switch try arg(name) {
        case .text(let s): return s
        case .number(let d): return QuickMeasureResolver.literal(d)
        case .field(let f): return f.name
        }
    }
    /// A DAX literal for a filter value: numbers stay numbers, everything else is quoted text.
    func literalValue(_ name: String) throws -> String {
        switch try arg(name) {
        case .number(let d): return QuickMeasureResolver.literal(d)
        case .text(let s): return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        case .field(let f): return f.daxReference
        }
    }
    /// Caption for names: the field caption, or the literal.
    func caption(_ name: String) -> String {
        guard let a = try? arg(name) else { return name }
        switch a {
        case .field(let f): return f.kind == .measure ? f.name : (f.displayName?.isEmpty == false ? f.displayName! : f.name)
        case .number(let d): return QuickMeasureResolver.literal(d)
        case .text(let s): return s
        }
    }
    static func literal(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }
}

/// The quick-measure gallery.
public enum QuickMeasures {
    public static let templates: [QuickMeasureTemplate] = perCategory + filters + timeIntelligence + totals + math + text

    public static func template(id: String) -> QuickMeasureTemplate? { templates.first { $0.id == id } }

    /// Gallery section names in display order.
    public static let categories: [String] = ["Aggregate per category", "Filters", "Time intelligence", "Totals", "Mathematical operations", "Text"]

    private typealias P = QuickMeasureParameter
    private static let base = P(name: "base", kind: .value, prompt: "Base value")
    private static let cat = P(name: "category", kind: .category, prompt: "Category")
    private static let date = P(name: "date", kind: .date, prompt: "Date")

    private static func perCat(_ id: String, _ name: String, _ fn: String, _ word: String, _ desc: String) -> QuickMeasureTemplate {
        QuickMeasureTemplate(id: id, name: name, category: "Aggregate per category", description: desc, parameters: [base, cat],
            namer: { "\($0.caption("base")) \(word) per \($0.caption("category"))" },
            builder: { "\(fn)(KEEPFILTERS(VALUES(\(try $0.column("category")))), CALCULATE(\(try $0.value("base"))))" })
    }

    private static let perCategory: [QuickMeasureTemplate] = [
        perCat("averagePerCategory", "Average per category", "AVERAGEX", "average", "The average of the base value across the categories."),
        perCat("variancePerCategory", "Variance per category", "VARX.S", "variance", "The variance of the base value across the categories."),
        perCat("maxPerCategory", "Max per category", "MAXX", "max", "The largest base value across the categories."),
        perCat("minPerCategory", "Min per category", "MINX", "min", "The smallest base value across the categories."),
        QuickMeasureTemplate(id: "weightedAveragePerCategory", name: "Weighted average per category", category: "Aggregate per category",
            description: "The average of the base value across the categories, weighted by another value.",
            parameters: [base, P(name: "weight", kind: .value, prompt: "Weight"), cat],
            namer: { "\($0.caption("base")) weighted by \($0.caption("weight")) per \($0.caption("category"))" },
            builder: { r in
                let b = try r.value("base"), w = try r.value("weight"), c = try r.column("category")
                return """
                VAR __CATEGORY_VALUES = VALUES(\(c))
                RETURN DIVIDE(SUMX(KEEPFILTERS(__CATEGORY_VALUES), CALCULATE(\(b) * \(w))), SUMX(KEEPFILTERS(__CATEGORY_VALUES), CALCULATE(\(w))))
                """
            }),
    ]

    private static let filterParams = [base, P(name: "filter", kind: .category, prompt: "Filter"), P(name: "value", kind: .text, prompt: "Filter value")]

    private static let filters: [QuickMeasureTemplate] = [
        QuickMeasureTemplate(id: "filteredValue", name: "Filtered value", category: "Filters",
            description: "The base value with a filter applied.", parameters: filterParams,
            namer: { "\($0.caption("base")) for \($0.caption("value"))" },
            builder: { "CALCULATE(\(try $0.value("base")), \(try $0.column("filter")) IN { \(try $0.literalValue("value")) })" }),
        QuickMeasureTemplate(id: "differenceFromFilteredValue", name: "Difference from filtered value", category: "Filters",
            description: "The difference between the base value and its filtered value.", parameters: filterParams,
            namer: { "\($0.caption("base")) difference from \($0.caption("value"))" },
            builder: { r in
                let b = try r.value("base")
                return "VAR __BASELINE_VALUE = CALCULATE(\(b), \(try r.column("filter")) IN { \(try r.literalValue("value")) }) VAR __VALUE_TO_COMPARE = \(b) RETURN IF(NOT ISBLANK(__VALUE_TO_COMPARE), __VALUE_TO_COMPARE - __BASELINE_VALUE)"
            }),
        QuickMeasureTemplate(id: "percentageDifferenceFromFilteredValue", name: "Percentage difference from filtered value", category: "Filters",
            description: "The percentage difference between the base value and its filtered value.", parameters: filterParams,
            namer: { "\($0.caption("base")) % difference from \($0.caption("value"))" },
            builder: { r in
                let b = try r.value("base")
                return "VAR __BASELINE_VALUE = CALCULATE(\(b), \(try r.column("filter")) IN { \(try r.literalValue("value")) }) VAR __VALUE_TO_COMPARE = \(b) RETURN IF(NOT ISBLANK(__VALUE_TO_COMPARE), DIVIDE(__VALUE_TO_COMPARE - __BASELINE_VALUE, __BASELINE_VALUE))"
            }),
        QuickMeasureTemplate(id: "salesFromNewCustomers", name: "Sales from new customers", category: "Filters",
            description: "The base value for customers that had no value before the first date of the current period.",
            parameters: [base, P(name: "customer", kind: .category, prompt: "Customer ID"), date],
            namer: { "\($0.caption("base")) from new customers" },
            builder: { r in
                let b = try r.value("base"), c = try r.column("customer"), d = try r.column("date")
                return "VAR __FIRST_DATE = MIN(\(d)) RETURN SUMX(FILTER(KEEPFILTERS(VALUES(\(c))), ISBLANK(CALCULATE(\(b), FILTER(ALL(\(d)), \(d) < __FIRST_DATE)))), CALCULATE(\(b)))"
            }),
    ]

    private static func toDate(_ id: String, _ name: String, _ fn: String, _ suffix: String) -> QuickMeasureTemplate {
        QuickMeasureTemplate(id: id, name: name, category: "Time intelligence",
            description: "The running total of the base value since the start of the current \(suffix == "YTD" ? "year" : suffix == "QTD" ? "quarter" : "month").",
            parameters: [base, date],
            namer: { "\($0.caption("base")) \(suffix)" },
            builder: { "\(fn)(\(try $0.value("base")), \(try $0.column("date")))" })
    }
    private static func overPeriod(_ id: String, _ name: String, _ unit: String, _ suffix: String) -> QuickMeasureTemplate {
        QuickMeasureTemplate(id: id, name: name, category: "Time intelligence",
            description: "The percentage change of the base value from the previous \(unit.lowercased()).",
            parameters: [base, date, P(name: "periods", kind: .number, prompt: "Number of periods", defaultValue: .number(1))],
            namer: { "\($0.caption("base")) \(suffix)%" },
            builder: { r in
                let b = try r.value("base")
                let n = QuickMeasureResolver.literal(-abs(try r.number("periods")))
                return "VAR __PREV_PERIOD = CALCULATE(\(b), DATEADD(\(try r.column("date")), \(n), \(unit))) RETURN DIVIDE(\(b) - __PREV_PERIOD, __PREV_PERIOD)"
            })
    }

    private static let timeIntelligence: [QuickMeasureTemplate] = [
        toDate("yearToDateTotal", "Year-to-date total", "TOTALYTD", "YTD"),
        toDate("quarterToDateTotal", "Quarter-to-date total", "TOTALQTD", "QTD"),
        toDate("monthToDateTotal", "Month-to-date total", "TOTALMTD", "MTD"),
        overPeriod("yearOverYearChange", "Year-over-year change", "YEAR", "YoY"),
        overPeriod("quarterOverQuarterChange", "Quarter-over-quarter change", "QUARTER", "QoQ"),
        overPeriod("monthOverMonthChange", "Month-over-month change", "MONTH", "MoM"),
        QuickMeasureTemplate(id: "rollingAverage", name: "Rolling average", category: "Time intelligence",
            description: "The average of the base value per date over a trailing period ending at the last visible date.",
            parameters: [base, date,
                         P(name: "period", kind: .text, prompt: "Period (DAY, MONTH, QUARTER or YEAR)", defaultValue: .text("DAY")),
                         P(name: "periods", kind: .number, prompt: "Number of periods", defaultValue: .number(7))],
            namer: { "\($0.caption("base")) rolling average" },
            builder: { r in
                let unit = try r.text("period").uppercased()
                guard ["DAY", "MONTH", "QUARTER", "YEAR"].contains(unit) else {
                    throw DAXError("The period must be DAY, MONTH, QUARTER or YEAR.")
                }
                let d = try r.column("date")
                let n = QuickMeasureResolver.literal(-abs(try r.number("periods")))
                return "VAR __LAST_DATE = MAX(\(d)) RETURN AVERAGEX(DATESINPERIOD(\(d), __LAST_DATE, \(n), \(unit)), CALCULATE(\(try r.value("base"))))"
            }),
    ]

    private static let totals: [QuickMeasureTemplate] = [
        QuickMeasureTemplate(id: "runningTotal", name: "Running total", category: "Totals",
            description: "The cumulative base value over a field, in ascending or descending order.",
            parameters: [base, P(name: "field", kind: .category, prompt: "Field"),
                         P(name: "direction", kind: .text, prompt: "Direction (ascending or descending)", defaultValue: .text("ascending"))],
            namer: { "\($0.caption("base")) running total in \($0.caption("field"))" },
            builder: { r in
                let f = try r.column("field")
                let descending = try r.text("direction").lowercased().hasPrefix("desc")
                let cond = descending ? "\(f) >= MIN(\(f))" : "\(f) <= MAX(\(f))"
                return "CALCULATE(\(try r.value("base")), FILTER(ALLSELECTED(\(f)), \(cond)))"
            }),
        QuickMeasureTemplate(id: "totalForCategoryFiltersApplied", name: "Total for category (filters applied)", category: "Totals",
            description: "The base value for all visible categories, keeping slicer and report filters.", parameters: [base, cat],
            namer: { "\($0.caption("base")) total for \($0.caption("category"))" },
            builder: { "CALCULATE(\(try $0.value("base")), ALLSELECTED(\(try $0.column("category"))))" }),
        QuickMeasureTemplate(id: "totalForCategoryFiltersNotApplied", name: "Total for category (filters not applied)", category: "Totals",
            description: "The base value for all categories, ignoring every filter on the category.", parameters: [base, cat],
            namer: { "\($0.caption("base")) total for all \($0.caption("category"))" },
            builder: { "CALCULATE(\(try $0.value("base")), ALL(\(try $0.column("category"))))" }),
    ]

    private static func binary(_ id: String, _ name: String, _ word: String, _ desc: String,
                               _ make: @escaping @Sendable (String, String) -> String) -> QuickMeasureTemplate {
        QuickMeasureTemplate(id: id, name: name, category: "Mathematical operations", description: desc,
            parameters: [base, P(name: "other", kind: .value, prompt: "Second value")],
            namer: { "\($0.caption("base")) \(word) \($0.caption("other"))" },
            builder: { make(try $0.value("base"), try $0.value("other")) })
    }

    private static let math: [QuickMeasureTemplate] = [
        binary("addition", "Addition", "plus", "The sum of two values.") { "\($0) + \($1)" },
        binary("subtraction", "Subtraction", "minus", "The difference of two values.") { "\($0) - \($1)" },
        binary("multiplication", "Multiplication", "times", "The product of two values.") { "\($0) * \($1)" },
        binary("division", "Division", "divided by", "The ratio of two values, blank when the divisor is zero.") { "DIVIDE(\($0), \($1))" },
        binary("percentageDifference", "Percentage difference", "% difference from", "The percentage difference of the base value from a second value.") {
            "VAR __BASELINE_VALUE = \($1) VAR __VALUE_TO_COMPARE = \($0) RETURN IF(NOT ISBLANK(__VALUE_TO_COMPARE), DIVIDE(__VALUE_TO_COMPARE - __BASELINE_VALUE, __BASELINE_VALUE))"
        },
        QuickMeasureTemplate(id: "correlationCoefficient", name: "Correlation coefficient", category: "Mathematical operations",
            description: "The Pearson correlation between two values across the categories.",
            parameters: [cat, P(name: "x", kind: .value, prompt: "Measure X"), P(name: "y", kind: .value, prompt: "Measure Y")],
            namer: { "\($0.caption("x")) and \($0.caption("y")) correlation for \($0.caption("category"))" },
            builder: { r in
                let c = try r.column("category"), x = try r.value("x"), y = try r.value("y")
                let t = "KEEPFILTERS(__CORRELATION_TABLE)"
                return """
                VAR __CORRELATION_TABLE = FILTER(VALUES(\(c)), NOT ISBLANK(CALCULATE(\(x))) && NOT ISBLANK(CALCULATE(\(y))))
                VAR __COUNT = COUNTROWS(__CORRELATION_TABLE)
                VAR __SUM_X = SUMX(\(t), CALCULATE(\(x)))
                VAR __SUM_Y = SUMX(\(t), CALCULATE(\(y)))
                VAR __SUM_XY = SUMX(\(t), CALCULATE(\(x)) * CALCULATE(\(y)))
                VAR __SUM_X2 = SUMX(\(t), CALCULATE(\(x)) ^ 2)
                VAR __SUM_Y2 = SUMX(\(t), CALCULATE(\(y)) ^ 2)
                RETURN DIVIDE(__COUNT * __SUM_XY - __SUM_X * __SUM_Y, SQRT((__COUNT * __SUM_X2 - __SUM_X ^ 2) * (__COUNT * __SUM_Y2 - __SUM_Y ^ 2)))
                """
            }),
    ]

    private static let text: [QuickMeasureTemplate] = [
        QuickMeasureTemplate(id: "starRating", name: "Star rating", category: "Text",
            description: "Shows the base value as a row of filled and empty stars.",
            parameters: [base,
                         P(name: "stars", kind: .number, prompt: "Number of stars", defaultValue: .number(5)),
                         P(name: "lowest", kind: .number, prompt: "Lowest value", defaultValue: .number(0)),
                         P(name: "highest", kind: .number, prompt: "Highest value", defaultValue: .number(100))],
            namer: { "\($0.caption("base")) star rating" },
            builder: { r in
                """
                VAR __MAX_NUMBER_OF_STARS = \(try r.numberLiteral("stars"))
                VAR __MIN_RATED_VALUE = \(try r.numberLiteral("lowest"))
                VAR __MAX_RATED_VALUE = \(try r.numberLiteral("highest"))
                VAR __BASE_VALUE = \(try r.value("base"))
                VAR __NORMALIZED_BASE_VALUE = MIN(MAX(DIVIDE(__BASE_VALUE - __MIN_RATED_VALUE, __MAX_RATED_VALUE - __MIN_RATED_VALUE), 0), 1)
                VAR __STAR_RATING = ROUND(__NORMALIZED_BASE_VALUE * __MAX_NUMBER_OF_STARS, 0)
                RETURN IF(NOT ISBLANK(__BASE_VALUE), REPT(UNICHAR(9733), __STAR_RATING) & REPT(UNICHAR(9734), __MAX_NUMBER_OF_STARS - __STAR_RATING))
                """
            }),
        QuickMeasureTemplate(id: "concatenatedListOfValues", name: "Concatenated list of values", category: "Text",
            description: "Lists the distinct values of a field, truncated after a number of values.",
            parameters: [P(name: "field", kind: .category, prompt: "Field"),
                         P(name: "count", kind: .number, prompt: "Number of values before truncation", defaultValue: .number(3))],
            namer: { "List of \($0.caption("field")) values" },
            builder: { r in
                let f = try r.column("field")
                return """
                VAR __DISTINCT_VALUES_COUNT = DISTINCTCOUNT(\(f))
                VAR __MAX_VALUES_TO_SHOW = \(try r.numberLiteral("count"))
                RETURN IF(__DISTINCT_VALUES_COUNT > __MAX_VALUES_TO_SHOW, CONCATENATE(CONCATENATEX(TOPN(__MAX_VALUES_TO_SHOW, VALUES(\(f)), \(f), ASC), \(f), ", ", \(f), ASC), ", etc."), CONCATENATEX(VALUES(\(f)), \(f), ", ", \(f), ASC))
                """
            }),
    ]
}
