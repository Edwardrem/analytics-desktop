import Foundation
import FacetCore

/// Grouping of DAX functions for IntelliSense and the function browser.
public enum DAXFunctionCategory: String, Sendable, CaseIterable {
    case aggregation, filter, table, window, timeIntelligence, logical, information, math, text, dateTime, financial
    case relationship, visualCalculation, other

    public var displayName: String {
        switch self {
        case .aggregation: return "Aggregation"
        case .filter: return "Filter"
        case .table: return "Table manipulation"
        case .window: return "Window"
        case .timeIntelligence: return "Time intelligence"
        case .logical: return "Logical"
        case .information: return "Information"
        case .math: return "Math and trig"
        case .text: return "Text"
        case .dateTime: return "Date and time"
        case .financial: return "Financial"
        case .relationship: return "Relationship"
        case .visualCalculation: return "Visual calculation"
        case .other: return "Other"
        }
    }
}

/// Describes one built-in DAX function: used for completion, signature help and arity checking.
public struct DAXFunctionInfo: Sendable, Hashable, Identifiable {
    public var id: String { name }
    /// Upper-case function name.
    public var name: String
    public var category: DAXFunctionCategory
    /// Human-readable signature, e.g. `CALCULATE(<expression> [, <filter>…])`.
    public var signature: String
    /// One-sentence description.
    public var description: String
    public var minArgs: Int
    /// Maximum argument count; nil when the function is variadic.
    public var maxArgs: Int?
    /// True when the function returns a table (or is a table-valued CALCULATE modifier).
    public var returnsTable: Bool

    public init(name: String, category: DAXFunctionCategory, signature: String, description: String,
                minArgs: Int, maxArgs: Int?, returnsTable: Bool = false) {
        self.name = name; self.category = category; self.signature = signature; self.description = description
        self.minArgs = minArgs; self.maxArgs = maxArgs; self.returnsTable = returnsTable
    }
}

/// The built-in function catalog.
public enum DAXCatalog {
    /// Every built-in function, sorted by name.
    public static let functions: [DAXFunctionInfo] = {
        let all = aggregationEntries + filterEntries + tableEntries + windowEntries + timeIntelligenceEntries
            + logicalEntries + informationEntries + mathEntries + textEntries + dateTimeEntries + financialEntries
            + visualCalculationEntries
        var seen = Set<String>()
        return all.filter { seen.insert($0.name).inserted }.sorted { $0.name < $1.name }
    }()

    private static let byName: [String: DAXFunctionInfo] = {
        var d: [String: DAXFunctionInfo] = [:]
        for f in functions { d[f.name] = f }
        return d
    }()

    /// Case-insensitive lookup.
    public static func function(named name: String) -> DAXFunctionInfo? { byName[name.uppercased()] }

    /// Functions whose name starts with `prefix` (case-insensitive), sorted by name. An empty prefix returns everything.
    public static func completions(prefix: String) -> [DAXFunctionInfo] {
        let p = prefix.uppercased()
        if p.isEmpty { return functions }
        return functions.filter { $0.name.hasPrefix(p) }
    }

    /// Functions in one category, sorted by name.
    public static func functions(in category: DAXFunctionCategory) -> [DAXFunctionInfo] {
        functions.filter { $0.category == category }
    }

    /// Language keywords and keyword-like arguments offered by completion.
    public static let keywords: [String] = [
        "VAR", "RETURN", "DEFINE", "EVALUATE", "MEASURE", "COLUMN", "TABLE", "FUNCTION", "ORDER BY", "START AT",
        "IN", "NOT", "ASC", "DESC", "TRUE", "FALSE", "BLANKS", "FIRST", "LAST", "ROWS", "COLUMNS",
        "DAY", "MONTH", "QUARTER", "YEAR", "WEEK", "HOUR", "MINUTE", "SECOND",
        "BOTH", "NONE", "ONEWAY", "ONEWAY_LEFTFILTERSRIGHT", "ONEWAY_RIGHTFILTERSLEFT",
        "SKIP", "DENSE", "ABS", "REL", "KEEP", "DEFAULT",
        "INTEGER", "DOUBLE", "STRING", "BOOLEAN", "CURRENCY", "DATETIME",
        "VAL", "EXPR", "SCALAR", "ANYVAL", "ANYREF", "NUMERIC",
    ]

    /// Compact entry builder: `args` is the text between the parentheses of the signature.
    static func make(_ category: DAXFunctionCategory,
                     _ entries: [(name: String, args: String, min: Int, max: Int?, table: Bool, desc: String)]) -> [DAXFunctionInfo] {
        entries.map {
            DAXFunctionInfo(name: $0.name, category: category, signature: "\($0.name)(\($0.args))", description: $0.desc,
                            minArgs: $0.min, maxArgs: $0.max, returnsTable: $0.table)
        }
    }
}
