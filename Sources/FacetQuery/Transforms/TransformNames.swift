import Foundation

public extension Transform {
    /// The default Applied Steps label, as Power Query names it.
    var stepName: String {
        switch self {
        case .keepTopRows: return "Kept First Rows"
        case .keepBottomRows: return "Kept Last Rows"
        case .keepRangeOfRows: return "Kept Range of Rows"
        case .removeTopRows: return "Removed Top Rows"
        case .removeBottomRows: return "Removed Bottom Rows"
        case .removeAlternateRows: return "Removed Alternate Rows"
        case .removeDuplicates: return "Removed Duplicates"
        case .keepDuplicates: return "Kept Duplicates"
        case .removeBlankRows: return "Removed Blank Rows"
        case .removeErrors: return "Removed Errors"
        case .keepErrors: return "Kept Errors"
        case .filterRows: return "Filtered Rows"
        case .sortRows: return "Sorted Rows"
        case .chooseColumns, .removeOtherColumns: return "Removed Other Columns"
        case .removeColumns: return "Removed Columns"
        case .reorderColumns: return "Reordered Columns"
        case .renameColumns: return "Renamed Columns"
        case .duplicateColumn: return "Duplicated Column"
        case .changeType(_, let culture): return culture == nil ? "Changed Type" : "Changed Type with Locale"
        case .promoteHeaders: return "Promoted Headers"
        case .demoteHeaders: return "Demoted Headers"
        case .pivotColumn: return "Pivoted Column"
        case .unpivotColumns: return "Unpivoted Columns"
        case .unpivotOtherColumns: return "Unpivoted Other Columns"
        case .transpose: return "Transposed Table"
        case .reverseRows: return "Reversed Rows"
        case .groupBy: return "Grouped Rows"
        case .countRows: return "Counted Rows"
        case .splitByDelimiter: return "Split Column by Delimiter"
        case .splitByLength: return "Split Column by Position"
        case .splitByPositions: return "Split Column by Positions"
        case .splitByTransition: return "Split Column by Character Transition"
        case .mergeColumns: return "Merged Columns"
        case .formatText(_, let f):
            switch f {
            case .lowercase: return "Lowercased Text"
            case .uppercase: return "Uppercased Text"
            case .capitalizeEachWord: return "Capitalized Each Word"
            case .trim: return "Trimmed Text"
            case .clean: return "Cleaned Text"
            }
        case .addPrefix: return "Added Prefix"
        case .addSuffix: return "Added Suffix"
        case .extractText(_, let e, let new):
            let what: String
            switch e {
            case .length: what = "Text Length"
            case .firstCharacters: what = "First Characters"
            case .lastCharacters: what = "Last Characters"
            case .range: what = "Text Range"
            case .beforeDelimiter: what = "Text Before Delimiter"
            case .afterDelimiter: what = "Text After Delimiter"
            case .betweenDelimiters: what = "Text Between Delimiters"
            }
            return (new == nil ? "Extracted " : "Inserted ") + what
        case .parse(_, let k): return k == .json ? "Parsed JSON" : "Parsed XML"
        case .number(_, let op, let new):
            let what: String
            switch op {
            case .add: what = "Addition"
            case .subtract: what = "Subtraction"
            case .multiply: what = "Multiplication"
            case .divide: what = "Division"
            case .integerDivide: what = "Integer-Division"
            case .modulo: what = "Modulo"
            case .percentage: what = "Percentage"
            case .percentOf: what = "Percent Of"
            case .absolute: what = "Absolute Value"
            case .power: what = "Power"
            case .squareRoot: what = "Square Root"
            case .exponent: what = "Exponent"
            case .log10: what = "Base-10 Logarithm"
            case .naturalLog: what = "Natural Logarithm"
            case .factorial: what = "Factorial"
            case .sine: what = "Sine"
            case .cosine: what = "Cosine"
            case .tangent: what = "Tangent"
            case .arcsine: what = "Arcsine"
            case .arccosine: what = "Arccosine"
            case .arctangent: what = "Arctangent"
            case .round: what = "Rounding"
            case .roundUp: what = "Round Up"
            case .roundDown: what = "Round Down"
            case .isEven: what = "Is Even"
            case .isOdd: what = "Is Odd"
            case .sign: what = "Sign"
            }
            return (new == nil ? "Calculated " : "Inserted ") + what
        case .statistic(_, let s):
            switch s {
            case .sum: return "Calculated Sum"
            case .minimum: return "Calculated Minimum"
            case .maximum: return "Calculated Maximum"
            case .median: return "Calculated Median"
            case .average: return "Calculated Average"
            case .standardDeviation: return "Calculated Standard Deviation"
            case .countValues: return "Calculated Count"
            case .countDistinctValues: return "Calculated Distinct Count"
            }
        case .date(_, let op, let new):
            let words = op.rawValue.reduce(into: "") { acc, ch in
                if ch.isUppercase { acc += " " }
                acc.append(ch)
            }.capitalized
            return (new == nil ? "Calculated " : "Inserted ") + words
        case .earliest: return "Calculated Earliest"
        case .latest: return "Calculated Latest"
        case .fillDown: return "Filled Down"
        case .fillUp: return "Filled Up"
        case .replaceValues: return "Replaced Value"
        case .replaceErrors: return "Replaced Errors"
        case .addCustomColumn: return "Added Custom"
        case .addConditionalColumn: return "Added Conditional Column"
        case .addIndexColumn: return "Added Index"
        case .invokeCustomFunction: return "Invoked Custom Function"
        case .addColumnFromExamples: return "Added Column From Examples"
        case .mergeQueries: return "Merged Queries"
        case .appendQueries: return "Appended Query"
        case .combineFiles: return "Combined Files"
        case .expandRecordColumn(let c, _, _), .expandTableColumn(let c, _, _), .expandListColumn(let c): return "Expanded \(c)"
        case .extractListValues: return "Extracted Values"
        case .aggregateTableColumn(let c, _): return "Aggregated \(c)"
        case .aiSentiment: return "Scored Sentiment"
        case .aiKeyPhrases: return "Extracted Key Phrases"
        case .aiDetectLanguage: return "Detected Language"
        case .aiTagImage: return "Tagged Images"
        case .runPythonScript: return "Run Python script"
        case .runRScript: return "Run R script"
        }
    }
}
