import Foundation
import FacetCore

private func q(_ s: String) -> String { MSyntax.text(s) }
private func f(_ column: String) -> String { MSyntax.field(column) }
private func names(_ cols: [String]) -> String { MSyntax.textList(cols) }
private func lit(_ v: Value, _ type: DataType = .any) -> String { MSyntax.literal(MValue(v, type: type)) }
private func num(_ d: Double) -> String { MSyntax.number(d) }
private func mType(_ t: DataType) -> String { MType(dataType: t).mExpression }

public extension FilterCondition {
    /// The M boolean expression for this condition, evaluated per row inside `each`.
    /// `previous` is the identifier of the table being filtered (needed by earliest/latest conditions).
    func mExpression(previous: String) -> String {
        switch self {
        case .compare(let c, let op, let v, let type):
            return "\(f(c)) \(op.rawValue) \(lit(v, type))"
        case .text(let c, let match, let s, let ignoreCase):
            let cmp = ignoreCase ? ", Comparer.OrdinalIgnoreCase" : ""
            switch match {
            case .beginsWith: return "Text.StartsWith(\(f(c)), \(q(s))\(cmp))"
            case .doesNotBeginWith: return "not Text.StartsWith(\(f(c)), \(q(s))\(cmp))"
            case .endsWith: return "Text.EndsWith(\(f(c)), \(q(s))\(cmp))"
            case .doesNotEndWith: return "not Text.EndsWith(\(f(c)), \(q(s))\(cmp))"
            case .contains: return "Text.Contains(\(f(c)), \(q(s))\(cmp))"
            case .doesNotContain: return "not Text.Contains(\(f(c)), \(q(s))\(cmp))"
            }
        case .isNull(let c): return "\(f(c)) = null"
        case .isNotNull(let c): return "\(f(c)) <> null"
        case .isBlank(let c): return "(\(f(c)) = null or \(f(c)) = \"\")"
        case .isNotBlank(let c): return "(\(f(c)) <> null and \(f(c)) <> \"\")"
        case .between(let c, let lo, let hi, let type):
            return "(\(f(c)) >= \(lit(lo, type)) and \(f(c)) <= \(lit(hi, type)))"
        case .inList(let c, let values, let type):
            return "List.Contains({" + values.map { lit($0, type) }.joined(separator: ", ") + "}, \(f(c)))"
        case .date(let c, let rel):
            switch rel {
            case .inCurrent(let u): return "Date.IsInCurrent\(u.rawValue)(\(f(c)))"
            case .inPrevious(let u): return "Date.IsInPrevious\(u.rawValue)(\(f(c)))"
            case .inNext(let u): return "Date.IsInNext\(u.rawValue)(\(f(c)))"
            case .inPreviousN(let n, let u): return "Date.IsInPreviousN\(u.rawValue)s(\(f(c)), \(n))"
            case .inNextN(let n, let u): return "Date.IsInNextN\(u.rawValue)s(\(f(c)), \(n))"
            case .yearToDate: return "Date.IsInYearToDate(\(f(c)))"
            case .isEarliest: return "\(f(c)) = List.Min(\(previous)\(f(c)))"
            case .isLatest: return "\(f(c)) = List.Max(\(previous)\(f(c)))"
            case .isNotEarliest: return "\(f(c)) <> List.Min(\(previous)\(f(c)))"
            case .isNotLatest: return "\(f(c)) <> List.Max(\(previous)\(f(c)))"
            case .year(let y): return "Date.Year(\(f(c))) = \(y)"
            case .quarter(let n): return "Date.QuarterOfYear(\(f(c))) = \(n)"
            case .month(let n): return "Date.Month(\(f(c))) = \(n)"
            case .day(let n): return "Date.Day(\(f(c))) = \(n)"
            }
        case .and(let parts):
            return parts.isEmpty ? "true" : parts.map { "(" + $0.mExpression(previous: previous) + ")" }.joined(separator: " and ")
        case .or(let parts):
            return parts.isEmpty ? "false" : parts.map { "(" + $0.mExpression(previous: previous) + ")" }.joined(separator: " or ")
        case .not(let inner): return "not (" + inner.mExpression(previous: previous) + ")"
        case .custom(let m): return m
        }
    }
}

private extension ColumnStatistic {
    var listFunction: String {
        switch self {
        case .sum: return "List.Sum"
        case .minimum: return "List.Min"
        case .maximum: return "List.Max"
        case .median: return "List.Median"
        case .average: return "List.Average"
        case .standardDeviation: return "List.StandardDeviation"
        case .countValues: return "List.NonNullCount"
        case .countDistinctValues: return "(values) => List.Count(List.Distinct(values))"
        }
    }
}

private extension NumberOperation {
    /// (expression over `x`, result type)
    func m(_ x: String) -> (String, String) {
        switch self {
        case .add(let v): return ("\(x) + \(num(v))", "type number")
        case .subtract(let v): return ("\(x) - \(num(v))", "type number")
        case .multiply(let v): return ("\(x) * \(num(v))", "type number")
        case .divide(let v): return ("\(x) / \(num(v))", "type number")
        case .integerDivide(let v): return ("Number.IntegerDivide(\(x), \(num(v)))", "Int64.Type")
        case .modulo(let v): return ("Number.Mod(\(x), \(num(v)))", "type number")
        case .percentage(let v): return ("\(x) * \(num(v)) / 100", "type number")
        case .percentOf(let v): return ("\(x) / \(num(v)) * 100", "type number")
        case .absolute: return ("Number.Abs(\(x))", "type number")
        case .power(let v): return ("Number.Power(\(x), \(num(v)))", "type number")
        case .squareRoot: return ("Number.Sqrt(\(x))", "type number")
        case .exponent: return ("Number.Exp(\(x))", "type number")
        case .log10: return ("Number.Log10(\(x))", "type number")
        case .naturalLog: return ("Number.Ln(\(x))", "type number")
        case .factorial: return ("Number.Factorial(\(x))", "type number")
        case .sine: return ("Number.Sin(\(x))", "type number")
        case .cosine: return ("Number.Cos(\(x))", "type number")
        case .tangent: return ("Number.Tan(\(x))", "type number")
        case .arcsine: return ("Number.Asin(\(x))", "type number")
        case .arccosine: return ("Number.Acos(\(x))", "type number")
        case .arctangent: return ("Number.Atan(\(x))", "type number")
        case .round(let d): return ("Number.Round(\(x), \(d))", "type number")
        case .roundUp: return ("Number.RoundUp(\(x))", "Int64.Type")
        case .roundDown: return ("Number.RoundDown(\(x))", "Int64.Type")
        case .isEven: return ("Number.IsEven(\(x))", "type logical")
        case .isOdd: return ("Number.IsOdd(\(x))", "type logical")
        case .sign: return ("Number.Sign(\(x))", "type number")
        }
    }
}

private extension DateOperation {
    func m(_ x: String) -> (String, String) {
        switch self {
        case .age: return ("DateTime.LocalNow() - DateTime.From(\(x))", "type duration")
        case .dateOnly: return ("DateTime.Date(\(x))", "type date")
        case .timeOnly: return ("DateTime.Time(\(x))", "type time")
        case .year: return ("Date.Year(\(x))", "Int64.Type")
        case .startOfYear: return ("Date.StartOfYear(\(x))", "type any")
        case .endOfYear: return ("Date.EndOfYear(\(x))", "type any")
        case .quarter: return ("Date.QuarterOfYear(\(x))", "Int64.Type")
        case .startOfQuarter: return ("Date.StartOfQuarter(\(x))", "type any")
        case .endOfQuarter: return ("Date.EndOfQuarter(\(x))", "type any")
        case .month: return ("Date.Month(\(x))", "Int64.Type")
        case .monthName: return ("Date.MonthName(\(x))", "type text")
        case .startOfMonth: return ("Date.StartOfMonth(\(x))", "type any")
        case .endOfMonth: return ("Date.EndOfMonth(\(x))", "type any")
        case .daysInMonth: return ("Date.DaysInMonth(\(x))", "Int64.Type")
        case .weekOfYear: return ("Date.WeekOfYear(\(x))", "Int64.Type")
        case .weekOfMonth: return ("Date.WeekOfMonth(\(x))", "Int64.Type")
        case .startOfWeek: return ("Date.StartOfWeek(\(x))", "type any")
        case .endOfWeek: return ("Date.EndOfWeek(\(x))", "type any")
        case .day: return ("Date.Day(\(x))", "Int64.Type")
        case .dayOfWeek: return ("Date.DayOfWeek(\(x))", "Int64.Type")
        case .dayOfYear: return ("Date.DayOfYear(\(x))", "Int64.Type")
        case .dayName: return ("Date.DayOfWeekName(\(x))", "type text")
        case .startOfDay: return ("Date.StartOfDay(\(x))", "type any")
        case .endOfDay: return ("Date.EndOfDay(\(x))", "type any")
        case .hour: return ("Time.Hour(\(x))", "Int64.Type")
        case .minute: return ("Time.Minute(\(x))", "Int64.Type")
        case .second: return ("Time.Second(\(x))", "type number")
        case .startOfHour: return ("Time.StartOfHour(\(x))", "type any")
        case .endOfHour: return ("Time.EndOfHour(\(x))", "type any")
        case .durationDays: return ("Duration.Days(\(x))", "Int64.Type")
        case .durationHours: return ("Duration.Hours(\(x))", "Int64.Type")
        case .durationMinutes: return ("Duration.Minutes(\(x))", "Int64.Type")
        case .durationSeconds: return ("Duration.Seconds(\(x))", "type number")
        case .totalDays: return ("Duration.TotalDays(\(x))", "type number")
        case .totalHours: return ("Duration.TotalHours(\(x))", "type number")
        case .totalMinutes: return ("Duration.TotalMinutes(\(x))", "type number")
        case .totalSeconds: return ("Duration.TotalSeconds(\(x))", "type number")
        }
    }
}

private extension TextExtract {
    func m(_ x: String) -> (String, String) {
        switch self {
        case .length: return ("Text.Length(\(x))", "Int64.Type")
        case .firstCharacters(let n): return ("Text.Start(\(x), \(n))", "type text")
        case .lastCharacters(let n): return ("Text.End(\(x), \(n))", "type text")
        case .range(let s, let c): return ("Text.Middle(\(x), \(s), \(c))", "type text")
        case .beforeDelimiter(let d): return ("Text.BeforeDelimiter(\(x), \(q(d)))", "type text")
        case .afterDelimiter(let d): return ("Text.AfterDelimiter(\(x), \(q(d)))", "type text")
        case .betweenDelimiters(let a, let b): return ("Text.BetweenDelimiters(\(x), \(q(a)), \(q(b)))", "type text")
        }
    }
}

private func operand(_ o: ConditionalClause.Operand) -> String {
    switch o {
    case .value(let v): return lit(v)
    case .column(let c): return f(c)
    }
}

public extension Transform {
    /// Apply a per-value expression to columns in place, or as a new column computed from the first column.
    private func perValue(_ p: String, _ columns: [String], _ newColumn: String?, _ build: (String) -> (String, String)) -> String {
        if let new = newColumn, let c = columns.first {
            let (e, t) = build(f(c))
            return "Table.AddColumn(\(p), \(q(new)), each \(e), \(t))"
        }
        let ops = columns.map { c -> String in
            let (e, t) = build("_")
            return "{\(q(c)), each \(e), \(t)}"
        }
        return "Table.TransformColumns(\(p), {\(ops.joined(separator: ", "))})"
    }

    private func split(_ p: String, _ column: String, _ splitter: String, _ target: SplitTarget) -> String {
        switch target {
        case .columns(let n):
            let newNames = (1...max(1, n)).map { "\(column).\($0)" }
            return "Table.SplitColumn(\(p), \(q(column)), \(splitter), \(names(newNames)))"
        case .rows:
            return "Table.ExpandListColumn(Table.TransformColumns(\(p), {{\(q(column)), \(splitter), type {text}}}), \(q(column)))"
        }
    }

    /// The M expression for this step, given the identifier text of the previous step.
    func expression(previous p: String) -> String {
        switch self {
        case .keepTopRows(let n): return "Table.FirstN(\(p), \(n))"
        case .keepBottomRows(let n): return "Table.LastN(\(p), \(n))"
        case .keepRangeOfRows(let first, let count): return "Table.Range(\(p), \(max(0, first - 1)), \(count))"
        case .removeTopRows(let n): return "Table.Skip(\(p), \(n))"
        case .removeBottomRows(let n): return "Table.RemoveLastN(\(p), \(n))"
        case .removeAlternateRows(let first, let remove, let keep): return "Table.AlternateRows(\(p), \(max(0, first - 1)), \(remove), \(keep))"
        case .removeDuplicates(let cols): return cols.isEmpty ? "Table.Distinct(\(p))" : "Table.Distinct(\(p), \(names(cols)))"
        case .keepDuplicates(let cols):
            let keys = cols.isEmpty ? "Table.ColumnNames(\(p))" : names(cols)
            return "let columnNames = \(keys), addCount = Table.Group(\(p), columnNames, {{\"Count\", Table.RowCount, type number}}), "
                + "selectDuplicates = Table.SelectRows(addCount, each [Count] > 1), removeCount = Table.RemoveColumns(selectDuplicates, \"Count\") "
                + "in Table.Join(\(p), columnNames, removeCount, columnNames, JoinKind.Inner)"
        case .removeBlankRows:
            return "Table.SelectRows(\(p), each not List.IsEmpty(List.RemoveMatchingItems(Record.FieldValues(_), {\"\", null})))"
        case .removeErrors(let cols): return cols.isEmpty ? "Table.RemoveRowsWithErrors(\(p))" : "Table.RemoveRowsWithErrors(\(p), \(names(cols)))"
        case .keepErrors(let cols): return cols.isEmpty ? "Table.SelectRowsWithErrors(\(p))" : "Table.SelectRowsWithErrors(\(p), \(names(cols)))"
        case .filterRows(let cond): return "Table.SelectRows(\(p), each \(cond.mExpression(previous: p)))"
        case .sortRows(let keys):
            return "Table.Sort(\(p), {" + keys.map { "{\(q($0.column)), Order.\($0.descending ? "Descending" : "Ascending")}" }.joined(separator: ", ") + "})"
        case .chooseColumns(let cols), .removeOtherColumns(let cols): return "Table.SelectColumns(\(p), \(names(cols)))"
        case .removeColumns(let cols): return "Table.RemoveColumns(\(p), \(names(cols)))"
        case .reorderColumns(let cols): return "Table.ReorderColumns(\(p), \(names(cols)))"
        case .renameColumns(let pairs):
            return "Table.RenameColumns(\(p), {" + pairs.map { "{\(q($0.from)), \(q($0.to))}" }.joined(separator: ", ") + "})"
        case .duplicateColumn(let c, let new): return "Table.DuplicateColumn(\(p), \(q(c)), \(q(new)))"
        case .changeType(let changes, let culture):
            let list = changes.map { "{\(q($0.column)), \(mType($0.type))}" }.joined(separator: ", ")
            return "Table.TransformColumnTypes(\(p), {\(list)}" + (culture.map { ", \(q($0))" } ?? "") + ")"
        case .promoteHeaders: return "Table.PromoteHeaders(\(p), [PromoteAllScalars = true])"
        case .demoteHeaders: return "Table.DemoteHeaders(\(p))"
        case .pivotColumn(let c, let valueColumn, let agg):
            let base = "Table.Pivot(\(p), List.Distinct(\(p)\(f(c))), \(q(c)), \(q(valueColumn))"
            return base + (agg.map { ", \($0.listFunction)" } ?? "") + ")"
        case .unpivotColumns(let cols): return "Table.Unpivot(\(p), \(names(cols)), \"Attribute\", \"Value\")"
        case .unpivotOtherColumns(let keep): return "Table.UnpivotOtherColumns(\(p), \(names(keep)), \"Attribute\", \"Value\")"
        case .transpose: return "Table.Transpose(\(p))"
        case .reverseRows: return "Table.ReverseRows(\(p))"
        case .groupBy(let keys, let aggs):
            let list = aggs.map { a -> String in
                let body: String, type: String
                switch a.aggregation {
                case .sum(let c): body = "List.Sum(\(f(c)))"; type = "type nullable number"
                case .average(let c): body = "List.Average(\(f(c)))"; type = "type nullable number"
                case .median(let c): body = "List.Median(\(f(c)))"; type = "type nullable number"
                case .min(let c): body = "List.Min(\(f(c)))"; type = "type any"
                case .max(let c): body = "List.Max(\(f(c)))"; type = "type any"
                case .standardDeviation(let c): body = "List.StandardDeviation(\(f(c)))"; type = "type nullable number"
                case .countDistinct(let c): body = "List.Count(List.Distinct(\(f(c))))"; type = "Int64.Type"
                case .countRows: body = "Table.RowCount(_)"; type = "Int64.Type"
                case .countDistinctRows: body = "Table.RowCount(Table.Distinct(_))"; type = "Int64.Type"
                case .allRows: body = "_"; type = "type table"
                }
                return "{\(q(a.name)), each \(body), \(type)}"
            }
            return "Table.Group(\(p), \(names(keys)), {\(list.joined(separator: ", "))})"
        case .countRows: return "Table.RowCount(\(p))"
        case .splitByDelimiter(let c, let d, let at, let target):
            let splitter: String
            switch at {
            case .each: splitter = "Splitter.SplitTextByDelimiter(\(q(d)), QuoteStyle.Csv)"
            case .leftmost: splitter = "Splitter.SplitTextByEachDelimiter({\(q(d))}, QuoteStyle.Csv, false)"
            case .rightmost: splitter = "Splitter.SplitTextByEachDelimiter({\(q(d))}, QuoteStyle.Csv, true)"
            }
            return split(p, c, splitter, target)
        case .splitByLength(let c, let length, let repeated, let target):
            let splitter = repeated ? "Splitter.SplitTextByRepeatedLengths(\(length))" : "Splitter.SplitTextByPositions({0, \(length)}, false)"
            return split(p, c, splitter, target)
        case .splitByPositions(let c, let positions, let target):
            return split(p, c, "Splitter.SplitTextByPositions({\(positions.map(String.init).joined(separator: ", "))}, false)", target)
        case .splitByTransition(let c, let kind, let target):
            let lower = "{\"a\"..\"z\"}", upper = "{\"A\"..\"Z\"}", digit = "{\"0\"..\"9\"}"
            let notDigit = "(c) => not List.Contains(\(digit), c)"
            let splitter: String
            switch kind {
            case .lowerToUpper: splitter = "Splitter.SplitTextByCharacterTransition(\(lower), \(upper))"
            case .upperToLower: splitter = "Splitter.SplitTextByCharacterTransition(\(upper), \(lower))"
            case .digitToNonDigit: splitter = "Splitter.SplitTextByCharacterTransition(\(digit), \(notDigit))"
            case .nonDigitToDigit: splitter = "Splitter.SplitTextByCharacterTransition(\(notDigit), \(digit))"
            }
            return split(p, c, splitter, target)
        case .mergeColumns(let cols, let sep, let new):
            let asText = "Table.TransformColumnTypes(\(p), {" + cols.map { "{\(q($0)), type text}" }.joined(separator: ", ") + "})"
            return "Table.CombineColumns(\(asText), \(names(cols)), Combiner.CombineTextByDelimiter(\(q(sep)), QuoteStyle.None), \(q(new)))"
        case .formatText(let cols, let fmt):
            let fn: String
            switch fmt {
            case .lowercase: fn = "Text.Lower"
            case .uppercase: fn = "Text.Upper"
            case .capitalizeEachWord: fn = "Text.Proper"
            case .trim: fn = "Text.Trim"
            case .clean: fn = "Text.Clean"
            }
            return "Table.TransformColumns(\(p), {" + cols.map { "{\(q($0)), \(fn), type text}" }.joined(separator: ", ") + "})"
        case .addPrefix(let cols, let prefix):
            return "Table.TransformColumns(\(p), {" + cols.map { "{\(q($0)), each \(q(prefix)) & Text.From(_), type text}" }.joined(separator: ", ") + "})"
        case .addSuffix(let cols, let suffix):
            return "Table.TransformColumns(\(p), {" + cols.map { "{\(q($0)), each Text.From(_) & \(q(suffix)), type text}" }.joined(separator: ", ") + "})"
        case .extractText(let c, let kind, let new): return perValue(p, [c], new) { kind.m($0) }
        case .parse(let c, let kind):
            return "Table.TransformColumns(\(p), {{\(q(c)), \(kind == .json ? "Json.Document" : "Xml.Tables")}})"
        case .number(let cols, let op, let new): return perValue(p, cols, new) { op.m($0) }
        case .statistic(let c, let s):
            if s == .countDistinctValues { return "List.Count(List.Distinct(\(p)\(f(c))))" }
            return "\(s.listFunction)(\(p)\(f(c)))"
        case .date(let cols, let op, let new): return perValue(p, cols, new) { op.m($0) }
        case .earliest(let c): return "List.Min(\(p)\(f(c)))"
        case .latest(let c): return "List.Max(\(p)\(f(c)))"
        case .fillDown(let cols): return "Table.FillDown(\(p), \(names(cols)))"
        case .fillUp(let cols): return "Table.FillUp(\(p), \(names(cols)))"
        case .replaceValues(let cols, let find, let with, let entire):
            let textual: Bool = { if case .string = find, !entire { return true }; return false }()
            return "Table.ReplaceValue(\(p), \(lit(find)), \(lit(with)), \(textual ? "Replacer.ReplaceText" : "Replacer.ReplaceValue"), \(names(cols)))"
        case .replaceErrors(let cols, let v):
            return "Table.ReplaceErrorValues(\(p), {" + cols.map { "{\(q($0)), \(lit(v))}" }.joined(separator: ", ") + "})"
        case .addCustomColumn(let name, let expr, let type):
            return "Table.AddColumn(\(p), \(q(name)), each \(expr)" + (type.map { ", \(mType($0))" } ?? "") + ")"
        case .addColumnFromExamples(let name, let expr):
            return "Table.AddColumn(\(p), \(q(name)), each \(expr))"
        case .addConditionalColumn(let name, let clauses, let otherwise):
            var body = ""
            for c in clauses {
                let col = f(c.column)
                let cond: String
                switch c.op {
                case .equals: cond = "\(col) = \(operand(c.value))"
                case .notEquals: cond = "\(col) <> \(operand(c.value))"
                case .greaterThan: cond = "\(col) > \(operand(c.value))"
                case .greaterOrEqual: cond = "\(col) >= \(operand(c.value))"
                case .lessThan: cond = "\(col) < \(operand(c.value))"
                case .lessOrEqual: cond = "\(col) <= \(operand(c.value))"
                case .contains: cond = "Text.Contains(\(col), \(operand(c.value)))"
                case .doesNotContain: cond = "not Text.Contains(\(col), \(operand(c.value)))"
                case .beginsWith: cond = "Text.StartsWith(\(col), \(operand(c.value)))"
                case .endsWith: cond = "Text.EndsWith(\(col), \(operand(c.value)))"
                case .isNull: cond = "\(col) = null"
                case .isNotNull: cond = "\(col) <> null"
                }
                body += "if \(cond) then \(operand(c.output)) else "
            }
            return "Table.AddColumn(\(p), \(q(name)), each \(body)\(operand(otherwise)))"
        case .addIndexColumn(let name, let start, let inc):
            return "Table.AddIndexColumn(\(p), \(q(name)), \(start), \(inc), Int64.Type)"
        case .invokeCustomFunction(let name, let fn, let args):
            return "Table.AddColumn(\(p), \(q(name)), each \(MSyntax.identifier(fn))(\(args.map(operand).joined(separator: ", "))))"
        case .mergeQueries(let other, let lk, let rk, let kind, let new, let fuzzy):
            let o = MSyntax.identifier(other)
            guard let fz = fuzzy else {
                return "Table.NestedJoin(\(p), \(names(lk)), \(o), \(names(rk)), \(q(new)), JoinKind.\(kind.rawValue))"
            }
            var opts = ["IgnoreCase = \(fz.ignoreCase)", "IgnoreSpace = \(fz.ignoreSpace)", "Threshold = \(num(fz.threshold))"]
            if let n = fz.maximumMatches { opts.append("NumberOfMatches = \(n)") }
            if let t = fz.transformationTable { opts.append("TransformationTable = \(MSyntax.identifier(t))") }
            return "Table.FuzzyNestedJoin(\(p), \(names(lk)), \(o), \(names(rk)), \(q(new)), JoinKind.\(kind.rawValue), [\(opts.joined(separator: ", "))])"
        case .appendQueries(let others):
            return "Table.Combine({" + ([p] + others.map(MSyntax.identifier)).joined(separator: ", ") + "})"
        case .combineFiles(let format):
            let parse: String
            switch format {
            case .csv(let d, let promote):
                let doc = "Csv.Document([Content], [Delimiter = \(q(d)), QuoteStyle = QuoteStyle.Csv])"
                parse = promote ? "Table.PromoteHeaders(\(doc), [PromoteAllScalars = true])" : doc
            case .json: parse = "Table.FromRecords(Json.Document([Content]))"
            case .excel(let sheet):
                let nav = "Excel.Workbook([Content], true)"
                parse = sheet.map { "\(nav){[Item = \(q($0)), Kind = \"Sheet\"]}[Data]" } ?? "\(nav){0}[Data]"
            case .parquet: parse = "Parquet.Document([Content])"
            }
            return "Table.Combine(List.Transform(Table.ToRecords(Table.SelectRows(\(p), each [Attributes]?[Hidden]? <> true)), "
                + "each Table.AddColumn(\(parse), \"Source.Name\", (row) => [Name], type text)))"
        case .expandRecordColumn(let c, let fields, let newNames):
            return "Table.ExpandRecordColumn(\(p), \(q(c)), \(names(fields)), \(names(newNames ?? fields.map { "\(c).\($0)" })))"
        case .expandTableColumn(let c, let cols, let newNames):
            return "Table.ExpandTableColumn(\(p), \(q(c)), \(names(cols)), \(names(newNames ?? cols.map { "\(c).\($0)" })))"
        case .expandListColumn(let c): return "Table.ExpandListColumn(\(p), \(q(c)))"
        case .extractListValues(let c, let d):
            return "Table.TransformColumns(\(p), {{\(q(c)), each Text.Combine(List.Transform(_, Text.From), \(q(d))), type text}})"
        case .aggregateTableColumn(let c, let aggs):
            return "Table.AggregateTableColumn(\(p), \(q(c)), {" + aggs.map { "{\(q($0.column)), \($0.statistic.listFunction), \(q($0.newName))}" }.joined(separator: ", ") + "})"
        case .aiSentiment(let c, let new): return "Table.AddColumn(\(p), \(q(new)), each AI.Sentiment(\(f(c))), type number)"
        case .aiKeyPhrases(let c, let new):
            return "Table.AddColumn(\(p), \(q(new)), each Text.Combine(AI.KeyPhrases(\(f(c))), \", \"), type text)"
        case .aiDetectLanguage(let c, let new):
            return "Table.AddColumn(\(p), \(q(new)), each AI.DetectLanguage(\(f(c)))[Language], type text)"
        case .aiTagImage(let c, let new):
            return "Table.AddColumn(\(p), \(q(new)), each Text.Combine(AI.TagImage(\(f(c)))[Tag], \", \"), type text)"
        case .runPythonScript(let script): return "Python.Execute(\(q(script)), [dataset = \(p)]){[Name = \"dataset\"]}[Value]"
        case .runRScript(let script): return "R.Execute(\(q(script)), [dataset = \(p)]){[Name = \"dataset\"]}[Value]"
        }
    }
}
