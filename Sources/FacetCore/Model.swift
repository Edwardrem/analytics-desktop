import Foundation

// MARK: - Semantic model metadata
// The semantic model is pure metadata. Row data lives in `DataStore`, keyed by table name.

public enum Aggregation: String, Codable, CaseIterable, Sendable {
    case none, sum, average, min, max, count, distinctCount, stdDev, variance, median, first, last
    public var displayName: String {
        switch self {
        case .none: return "Don't summarize"
        case .sum: return "Sum"
        case .average: return "Average"
        case .min: return "Minimum"
        case .max: return "Maximum"
        case .count: return "Count"
        case .distinctCount: return "Count (distinct)"
        case .stdDev: return "Standard deviation"
        case .variance: return "Variance"
        case .median: return "Median"
        case .first: return "First"
        case .last: return "Last"
        }
    }
    /// The DAX function implementing this aggregation over a column.
    public var daxFunction: String? {
        switch self {
        case .none: return nil
        case .sum: return "SUM"
        case .average: return "AVERAGE"
        case .min: return "MIN"
        case .max: return "MAX"
        case .count: return "COUNTA"
        case .distinctCount: return "DISTINCTCOUNT"
        case .stdDev: return "STDEV.S"
        case .variance: return "VAR.S"
        case .median: return "MEDIAN"
        case .first: return "FIRSTNONBLANK"
        case .last: return "LASTNONBLANK"
        }
    }
}

public enum DataCategory: String, Codable, CaseIterable, Sendable {
    case uncategorized, address, city, continent, country, county, stateOrProvince, postalCode, place
    case latitude, longitude, webURL, imageURL, barcode
}

public enum StorageMode: String, Codable, CaseIterable, Sendable {
    case `import`, directQuery, dual, directLake, live
}

public struct ModelColumn: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var dataType: DataType
    public var formatString: String = ""
    public var formatLocale: String = ""
    public var dataCategory: DataCategory = .uncategorized
    public var summarizeBy: Aggregation = .none
    public var sortByColumn: String?
    public var displayFolder: String = ""
    public var isHidden = false
    public var isKey = false
    public var isNullable = true
    public var description: String = ""
    public var synonyms: [String] = []
    /// DAX expression when this is a calculated column; nil for source columns.
    public var expression: String?
    /// Grouping/binning definition when this column is a derived group.
    public var grouping: ColumnGrouping?

    public init(name: String, dataType: DataType, expression: String? = nil) {
        self.name = name; self.dataType = dataType; self.expression = expression
        self.summarizeBy = dataType.isNumeric ? .sum : .none
    }
    public var isCalculated: Bool { expression != nil }
}

/// A "group" or "bin" column derived from another column.
public struct ColumnGrouping: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case list, binSize, binCount }
    public var kind: Kind
    public var sourceColumn: String
    /// For `.list`: group name → member values. Unlisted values fall into `otherGroupName` (or keep their own value when nil).
    public var groups: [String: [Value]] = [:]
    public var otherGroupName: String?
    /// For `.binSize`: the width of each bin. For `.binCount`: the number of bins.
    public var binValue: Double = 10
    /// For `.binSize` on a date column: the unit `binValue` counts. Nil bins plain numbers (and dates by days).
    public var binUnit: BinUnit?
    public init(kind: Kind, sourceColumn: String) { self.kind = kind; self.sourceColumn = sourceColumn }

    /// Units a date column can be binned by.
    public enum BinUnit: String, Codable, CaseIterable, Sendable {
        case second, minute, hour, day, month, year
        /// Length in days for the fixed-length units; nil for calendar units.
        public var days: Double? {
            switch self {
            case .second: return 1.0 / 86400
            case .minute: return 1.0 / 1440
            case .hour: return 1.0 / 24
            case .day: return 1
            case .month, .year: return nil
            }
        }
    }

    /// The bin a value falls in: the lower bound of its bin, a date for date values. Blank and
    /// non-numeric values have no bin.
    /// - `.binSize`: bins are multiples of the size (size 10 puts 37 in bin 30); dates count whole
    ///   units from the calendar (2 months puts 14 Mar in the bin starting 1 Mar when Mar is the bin's first month).
    /// - `.binCount`: the range `minimum...maximum` is split into that many equal bins; the maximum
    ///   belongs to the last bin.
    public func bin(_ v: Value, minimum: Double, maximum: Double) -> Value {
        var isDate = false
        if case .date = v { isDate = true }
        guard isDate || v.isNumber, let d = v.asDouble, d.isFinite else { return .null }
        func wrap(_ x: Double) -> Value { isDate ? .date(Value.date(fromSerial: x)) : .double((x * 1e9).rounded() / 1e9) }
        switch kind {
        case .list:
            return .null
        case .binCount:
            let count = Swift.max(1, Int(binValue))
            let width = (maximum - minimum) / Double(count)
            guard width > 0 else { return wrap(minimum) }
            let index = Swift.min(count - 1, Swift.max(0, Int(((d - minimum) / width + 1e-9).rounded(.down))))
            return wrap(minimum + Double(index) * width)
        case .binSize:
            let size = Swift.max(binValue, 1e-9)
            if isDate, let unit = binUnit, unit.days == nil, case .date(let date) = v {
                let cal = Calendar.utc
                let c = cal.dateComponents([.year, .month], from: date)
                let months = (c.year ?? 1900) * 12 + (c.month ?? 1) - 1
                let step = Swift.max(1, Int(size)) * (unit == .year ? 12 : 1)
                let start = Int((Double(months) / Double(step)).rounded(.down)) * step
                var out = DateComponents()
                out.year = Int((Double(start) / 12).rounded(.down)); out.month = start - (out.year ?? 0) * 12 + 1; out.day = 1
                return cal.date(from: out).map(Value.date) ?? .null
            }
            let width = size * ((isDate ? binUnit?.days : nil) ?? 1)
            return wrap(((d / width) + 1e-9).rounded(.down) * width)
        }
    }
}

public struct Measure: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var expression: String
    public var formatString: String = ""
    /// Dynamic format string: a DAX expression returning a format string.
    public var formatExpression: String?
    public var displayFolder: String = ""
    public var description: String = ""
    public var isHidden = false
    public var dataCategory: DataCategory = .uncategorized
    public init(name: String, expression: String, formatString: String = "") {
        self.name = name; self.expression = expression; self.formatString = formatString
    }
}

public struct Hierarchy: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// Column names, top level first.
    public var levels: [String]
    public var isHidden = false
    public init(name: String, levels: [String]) { self.name = name; self.levels = levels }
}

/// A custom calendar for calendar-based time intelligence (fiscal, retail 4-4-5, 13-period…).
public struct CalendarDefinition: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// Maps time units ("year", "quarter", "month", "week", "date") to column names in the table.
    public var columnsByUnit: [String: String]
    public var fiscalYearStartMonth: Int = 1
    public init(name: String, columnsByUnit: [String: String]) { self.name = name; self.columnsByUnit = columnsByUnit }
    /// The time units a calendar can map, largest first.
    public static let units = ["year", "quarter", "month", "week", "date"]
    /// The last month of the fiscal year: the month before it starts (a January start ends in December).
    public var fiscalYearEndMonth: Int { (Swift.min(12, Swift.max(1, fiscalYearStartMonth)) + 10) % 12 + 1 }
}

public struct ModelTable: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var columns: [ModelColumn] = []
    public var measures: [Measure] = []
    public var hierarchies: [Hierarchy] = []
    public var calendars: [CalendarDefinition] = []
    public var description: String = ""
    public var synonyms: [String] = []
    public var isHidden = false
    public var storageMode: StorageMode = .import
    public var isFeatured = false
    public var rowLabelColumn: String?
    public var keyColumn: String?
    /// Set when "Mark as date table" has been applied.
    public var dateColumn: String?
    /// DAX expression for calculated tables.
    public var expression: String?
    /// Name of the Power Query query that loads this table, if any.
    public var sourceQuery: String?
    /// Incremental refresh policy, if configured.
    public var incrementalRefresh: IncrementalRefreshPolicy?
    /// Position and state of the table card per model-view layout tab is stored in `ModelLayout`.

    public init(name: String, columns: [ModelColumn] = []) { self.name = name; self.columns = columns }
    public var isCalculated: Bool { expression != nil }
    public var isDateTable: Bool { dateColumn != nil }
    public func column(_ name: String) -> ModelColumn? {
        columns.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    public func measure(_ name: String) -> Measure? {
        measures.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct IncrementalRefreshPolicy: Codable, Hashable, Sendable {
    public var dateColumn: String
    public var archiveCount = 5
    public var archiveUnit = "year"
    public var refreshCount = 10
    public var refreshUnit = "day"
    public var detectChangesColumn: String?
    public var onlyCompletePeriods = false
    /// Hybrid table: add a DirectQuery partition for the latest data.
    public var realTimeDirectQuery = false
    public init(dateColumn: String) { self.dateColumn = dateColumn }
}

public enum Cardinality: String, Codable, CaseIterable, Sendable {
    case manyToOne, oneToOne, oneToMany, manyToMany
    public var displayName: String {
        switch self {
        case .manyToOne: return "Many to one (*:1)"
        case .oneToOne: return "One to one (1:1)"
        case .oneToMany: return "One to many (1:*)"
        case .manyToMany: return "Many to many (*:*)"
        }
    }
}
public enum CrossFilterDirection: String, Codable, CaseIterable, Sendable { case single, both }

/// A relationship. By convention `from` is the many side and `to` is the one side for `.manyToOne`.
public struct Relationship: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var fromTable: String
    public var fromColumn: String
    public var toTable: String
    public var toColumn: String
    public var cardinality: Cardinality = .manyToOne
    public var crossFilter: CrossFilterDirection = .single
    public var isActive = true
    public var assumeReferentialIntegrity = false
    public var securityFilterBothDirections = false
    public init(fromTable: String, fromColumn: String, toTable: String, toColumn: String) {
        self.fromTable = fromTable; self.fromColumn = fromColumn; self.toTable = toTable; self.toColumn = toColumn
    }
}

public struct CalculationItem: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// DAX using SELECTEDMEASURE().
    public var expression: String
    public var formatExpression: String?
    public var ordinal = 0
    public init(name: String, expression: String) { self.name = name; self.expression = expression }
}
public struct CalculationGroup: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    /// Table name of the group; it exposes one column (`columnName`) listing the items.
    public var name: String
    public var columnName: String = "Name"
    public var precedence = 0
    public var items: [CalculationItem] = []
    public init(name: String) { self.name = name }
}

public struct FunctionParameter: Codable, Hashable, Sendable {
    public var name: String
    /// "scalar", "table", "anyref", or a concrete type keyword; informational plus used for evaluation mode.
    public var type: String = "anyval"
    /// "val" (eager) or "expr" (lazy, evaluated in the callee's context).
    public var mode: String = "val"
    public var defaultExpression: String?
    public init(name: String) { self.name = name }
}
public struct UserFunction: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var parameters: [FunctionParameter] = []
    public var expression: String
    public var description: String = ""
    public init(name: String, parameters: [FunctionParameter] = [], expression: String) {
        self.name = name; self.parameters = parameters; self.expression = expression
    }
}

public struct SecurityRole: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var description: String = ""
    /// Table name → DAX boolean row filter.
    public var tableFilters: [String: String] = [:]
    /// Object-level security.
    public var hiddenTables: [String] = []
    /// "Table[Column]" identifiers hidden from this role.
    public var hiddenColumns: [String] = []
    public init(name: String) { self.name = name }
}

public struct Perspective: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    /// "Table", "Table[Column]" or "Table[Measure]" identifiers included.
    public var members: [String] = []
    public init(name: String) { self.name = name }
}
public struct Translation: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var culture: String
    /// Object identifier → translated caption.
    public var captions: [String: String] = [:]
    public init(culture: String) { self.culture = culture }
}

/// Field parameter: lets readers swap which fields a visual shows.
public struct FieldParameter: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var fields: [FieldRef]
    public init(name: String, fields: [FieldRef]) { self.name = name; self.fields = fields }
}
/// Numeric range ("what-if") parameter.
public struct WhatIfParameter: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var name: String
    public var minimum: Double
    public var maximum: Double
    public var increment: Double
    public var defaultValue: Double
    public init(name: String, minimum: Double, maximum: Double, increment: Double, defaultValue: Double) {
        self.name = name; self.minimum = minimum; self.maximum = maximum; self.increment = increment; self.defaultValue = defaultValue
    }
}

public struct AggregationMapping: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var aggTable: String
    public var aggColumn: String
    public var summarization: Aggregation
    public var detailTable: String
    public var detailColumn: String
    public init(aggTable: String, aggColumn: String, summarization: Aggregation, detailTable: String, detailColumn: String) {
        self.aggTable = aggTable; self.aggColumn = aggColumn; self.summarization = summarization
        self.detailTable = detailTable; self.detailColumn = detailColumn
    }
}

/// One layout tab in Model view.
public struct ModelLayout: Codable, Identifiable, Hashable, Sendable {
    public struct Card: Codable, Hashable, Sendable {
        public var x: Double; public var y: Double
        public var width: Double = 220; public var height: Double = 260
        public var collapsed = false
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }
    public var id = UUID()
    public var name: String
    /// Table name → card. Tables without a card are not shown on this tab ("All tables" shows everything).
    public var cards: [String: Card] = [:]
    public var showsAllTables = false
    public init(name: String, showsAllTables: Bool = false) { self.name = name; self.showsAllTables = showsAllTables }
}

public struct SemanticModel: Codable, Sendable {
    public var name: String = "Model"
    public var culture: String = "en-US"
    public var tables: [ModelTable] = []
    public var relationships: [Relationship] = []
    public var calculationGroups: [CalculationGroup] = []
    public var functions: [UserFunction] = []
    public var roles: [SecurityRole] = []
    public var perspectives: [Perspective] = []
    public var translations: [Translation] = []
    public var fieldParameters: [FieldParameter] = []
    public var whatIfParameters: [WhatIfParameter] = []
    public var aggregations: [AggregationMapping] = []
    public var layouts: [ModelLayout] = [ModelLayout(name: "All tables", showsAllTables: true)]
    public var autoDateTime = false
    /// Current file ▸ Data load ▸ "Autodetect new relationships after data is loaded"; nil follows the global option.
    public var autodetectRelationships: Bool?
    /// AI data schema: identifiers excluded from Copilot, plus free-form instructions and verified answers.
    public var aiExcludedFields: [String] = []
    public var aiInstructions: String = ""
    public var verifiedAnswers: [VerifiedAnswer] = []
    public var qnaSynonyms: [String: [String]] = [:]

    public init() {}

    public func table(_ name: String) -> ModelTable? {
        tables.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    public func tableIndex(_ name: String) -> Int? {
        tables.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
    /// Finds a measure by name across all tables (measure names are model-unique).
    public func measure(_ name: String) -> (table: ModelTable, measure: Measure)? {
        for t in tables { if let m = t.measure(name) { return (t, m) } }
        return nil
    }
    public var allMeasures: [(table: String, measure: Measure)] {
        tables.flatMap { t in t.measures.map { (t.name, $0) } }
    }
    public func relationships(involving table: String) -> [Relationship] {
        relationships.filter { $0.fromTable == table || $0.toTable == table }
    }
}

public struct VerifiedAnswer: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var question: String
    public var visualID: UUID?
    public var answer: String = ""
    public init(question: String) { self.question = question }
}

// MARK: - Power Query

/// A Power Query query. The M script is the source of truth, exactly as in Power BI;
/// the query engine parses it into applied steps and regenerates it after UI edits.
public struct QueryDefinition: Codable, Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case table, parameter, function, list, value }
    public var id = UUID()
    public var name: String
    public var kind: Kind = .table
    public var group: String = ""
    public var mScript: String
    public var loadEnabled = true
    public var includeInRefresh = true
    public var description: String = ""
    /// For `.parameter` queries.
    public var parameter: QueryParameter?
    public init(name: String, mScript: String) { self.name = name; self.mScript = mScript }
}

public struct QueryParameter: Codable, Hashable, Sendable {
    public var type: DataType = .text
    public var currentValue: Value = .null
    public var defaultValue: Value = .null
    public var suggestedValues: [Value] = []
    public var isRequired = true
    public init() {}
}

public enum PrivacyLevel: String, Codable, CaseIterable, Sendable { case none, `public`, organizational, `private` }

/// A remembered data source (for Recent sources / Data source settings). Secrets live in the Keychain, never here.
public struct DataSourceRecord: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var kind: String
    public var location: String
    public var displayName: String
    public var privacy: PrivacyLevel = .none
    public var authentication: String = "anonymous"
    public var lastUsed = Date()
    public init(kind: String, location: String, displayName: String) {
        self.kind = kind; self.location = location; self.displayName = displayName
    }
}
