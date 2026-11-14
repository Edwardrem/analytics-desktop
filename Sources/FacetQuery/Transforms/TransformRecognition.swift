import Foundation
import FacetCore

public extension Transform {
    /// Recognises the M of an applied step as the UI transformation that produces it ("Edit settings", the gear beside
    /// a step): the transform and the identifier source text of the step it reads (`#"Changed Type"`, `Source`).
    ///
    /// Every candidate is checked by re-emitting it with `expression(previous:)` and comparing tokens (spacing,
    /// identifier quoting and `type nullable` aside), so a recognised step re-emits the same M. A few Power BI forms that
    /// mean the same are accepted as well: fuzzy-merge options in another order or left at their defaults, Merge Columns
    /// without the text conversion, Expand without new names, Add Index without a type, and Group By aggregations with
    /// other type annotations. Anything else is nil.
    static func recognize(_ expression: String) -> (transform: Transform, previous: String)? {
        StepRecognizer.recognize(expression)
    }
}

enum StepRecognizer {
    typealias Candidate = (transform: Transform, previous: String)

    static func recognize(_ text: String) -> Candidate? {
        guard let step = StepFragment(text) else { return nil }
        let target = step.key
        for c in candidates(step) where StepFragment.key(c.transform.expression(previous: c.previous)) == target { return c }
        return equivalent(step)
    }

    static func matches(_ t: Transform, _ previous: String, _ text: String) -> Bool {
        StepFragment.key(t.expression(previous: previous)) == StepFragment.key(text)
    }

    // MARK: Candidates

    private static func candidates(_ s: StepFragment) -> [Candidate] {
        guard let head = s.tokens.first else { return [] }
        if head.kind == .keyword, head.text == "let" { return keepDuplicates(s) }
        if head.kind == .identifier, head.text == "Python.Execute" || head.text == "R.Execute" { return script(s) }
        guard let (name, args) = s.call else { return [] }
        func arg(_ i: Int) -> StepFragment? { i < args.count ? args[i] : nil }
        if let statistics = statistic(name, args) { return statistics }
        if name == "Table.Combine" { return combine(arg(0)) }
        guard let p = arg(0)?.identifier?.source else {
            return name == "Table.CombineColumns" || name == "Table.ExpandListColumn" ? nested(name, args) : []
        }
        let ts: [Transform]
        switch name {
        case "Table.FirstN": ts = arg(1)?.intValue.map { [.keepTopRows($0)] } ?? []
        case "Table.LastN": ts = arg(1)?.intValue.map { [.keepBottomRows($0)] } ?? []
        case "Table.Skip": ts = arg(1)?.intValue.map { [.removeTopRows($0)] } ?? []
        case "Table.RemoveLastN": ts = arg(1)?.intValue.map { [.removeBottomRows($0)] } ?? []
        case "Table.Range":
            guard let a = arg(1)?.intValue, let b = arg(2)?.intValue else { return [] }
            ts = [.keepRangeOfRows(first: a + 1, count: b)]
        case "Table.AlternateRows":
            guard let a = arg(1)?.intValue, let b = arg(2)?.intValue, let c = arg(3)?.intValue else { return [] }
            ts = [.removeAlternateRows(firstToRemove: a + 1, numberToRemove: b, numberToKeep: c)]
        case "Table.Distinct": ts = (args.count == 1 ? [] : arg(1)?.names).map { [.removeDuplicates(columns: $0)] } ?? []
        case "Table.RemoveRowsWithErrors": ts = (args.count == 1 ? [] : arg(1)?.names).map { [.removeErrors(columns: $0)] } ?? []
        case "Table.SelectRowsWithErrors": ts = (args.count == 1 ? [] : arg(1)?.names).map { [.keepErrors(columns: $0)] } ?? []
        case "Table.SelectRows":
            guard let body = arg(1)?.eachBody else { return [] }
            ts = [.removeBlankRows] + (FilterRecognizer.condition(body, previous: p).map { [.filterRows($0)] } ?? []) + [.filterRows(.custom(body.text))]
        case "Table.Sort":
            guard let keys = arg(1)?.items?.map(sortKey), keys.allSatisfy({ $0 != nil }) else { return [] }
            ts = [.sortRows(keys.compactMap { $0 })]
        case "Table.SelectColumns": ts = arg(1)?.names.map { [.chooseColumns($0)] } ?? []
        case "Table.RemoveColumns": ts = arg(1)?.names.map { [.removeColumns($0)] } ?? []
        case "Table.ReorderColumns": ts = arg(1)?.names.map { [.reorderColumns($0)] } ?? []
        case "Table.RenameColumns":
            guard let pairs = arg(1)?.items?.map({ $0.texts }), pairs.allSatisfy({ $0?.count == 2 }) else { return [] }
            ts = [.renameColumns(pairs.compactMap { $0.map { (from: $0[0], to: $0[1]) } })]
        case "Table.DuplicateColumn":
            guard let c = arg(1)?.textValue, let n = arg(2)?.textValue else { return [] }
            ts = [.duplicateColumn(c, newName: n)]
        case "Table.TransformColumnTypes":
            guard let changes = arg(1)?.items?.map(typePair), changes.allSatisfy({ $0 != nil }) else { return [] }
            let culture = arg(2)?.textValue
            if args.count > 2, culture == nil { return [] }
            ts = [.changeType(changes.compactMap { $0 }, culture: culture)]
        case "Table.PromoteHeaders": ts = [.promoteHeaders]
        case "Table.DemoteHeaders": ts = [.demoteHeaders]
        case "Table.Transpose": ts = [.transpose]
        case "Table.ReverseRows": ts = [.reverseRows]
        case "Table.RowCount": ts = [.countRows]
        case "Table.Pivot":
            guard let c = arg(2)?.textValue, let v = arg(3)?.textValue else { return [] }
            ts = ([nil] + ColumnStatistic.allCases.map { Optional($0) }).map { .pivotColumn(column: c, valueColumn: v, aggregation: $0) }
        case "Table.Unpivot": ts = arg(1)?.names.map { [.unpivotColumns($0)] } ?? []
        case "Table.UnpivotOtherColumns": ts = arg(1)?.names.map { [.unpivotOtherColumns(keeping: $0)] } ?? []
        case "Table.Group": ts = groupBy(args).map { [$0] } ?? []
        case "Table.SplitColumn":
            guard let c = arg(1)?.textValue, let splitter = arg(2), let n = arg(3)?.texts?.count else { return [] }
            ts = splits(c, splitter, .columns(n))
        case "Table.ExpandListColumn": ts = arg(1)?.textValue.map { [.expandListColumn(column: $0)] } ?? []
        case "Table.TransformColumns": ts = arg(1).map(transformColumns) ?? []
        case "Table.FillDown": ts = arg(1)?.names.map { [.fillDown($0)] } ?? []
        case "Table.FillUp": ts = arg(1)?.names.map { [.fillUp($0)] } ?? []
        case "Table.ReplaceValue":
            guard let find = arg(1)?.literal, let with = arg(2)?.literal, let cols = arg(4)?.names else { return [] }
            ts = [true, false].map { .replaceValues(columns: cols, find: find.value, replaceWith: with.value, matchEntireCell: $0) }
        case "Table.ReplaceErrorValues":
            guard let pairs = arg(1)?.items?.compactMap({ $0.items }), !pairs.isEmpty,
                  let value = pairs[0].last?.literal?.value else { return [] }
            let cols = pairs.compactMap { $0.count == 2 && $0[1].literal?.value == value ? $0[0].textValue : nil }
            guard cols.count == pairs.count else { return [] }
            ts = [.replaceErrors(columns: cols, with: value)]
        case "Table.AddColumn": ts = addColumn(args)
        case "Table.AddIndexColumn": ts = indexColumn(args).map { [$0] } ?? []
        case "Table.NestedJoin", "Table.FuzzyNestedJoin": ts = merge(name, args).map { [$0] } ?? []
        case "Table.ExpandRecordColumn", "Table.ExpandTableColumn": ts = expand(name, args)
        case "Table.AggregateTableColumn":
            guard let c = arg(1)?.textValue, let elements = arg(2)?.items else { return [] }
            let aggs = elements.map(tableAggregation)
            guard !aggs.isEmpty, aggs.allSatisfy({ $0 != nil }) else { return [] }
            ts = [.aggregateTableColumn(column: c, aggregations: aggs.compactMap { $0 })]
        case "Table.CombineColumns": return nested(name, args)
        default: return []
        }
        return ts.map { ($0, p) }
    }

    /// Steps whose previous step is read inside a nested call: Merge Columns (inside its text conversion) and Split
    /// Column into rows (inside its `Table.TransformColumns`).
    private static func nested(_ name: String, _ args: [StepFragment]) -> [Candidate] {
        guard let inner = args.first?.call, let p = inner.args.first?.identifier?.source else { return [] }
        if name == "Table.CombineColumns", inner.name == "Table.TransformColumnTypes", args.count == 4,
           let cols = args[1].names, let sep = combinerSeparator(args[2]), let new = args[3].textValue {
            return [(.mergeColumns(cols, separator: sep, newName: new), p)]
        }
        if name == "Table.ExpandListColumn", inner.name == "Table.TransformColumns", args.count == 2, let c = args[1].textValue,
           inner.args.count == 2, let element = inner.args[1].items?.first?.items, element.count == 3, element[0].textValue == c {
            return splits(c, element[1], .rows).map { ($0, p) }
        }
        return []
    }

    private static func combinerSeparator(_ f: StepFragment) -> String? {
        guard let (name, args) = f.call, name == "Combiner.CombineTextByDelimiter", args.count == 2,
              args[1].identifier?.name == "QuoteStyle.None" else { return nil }
        return args[0].textValue
    }

    private static func sortKey(_ f: StepFragment) -> (column: String, descending: Bool)? {
        guard let pair = f.items, pair.count == 2, let c = pair[0].textValue, let order = pair[1].identifier?.name else { return nil }
        switch order {
        case "Order.Ascending": return (c, false)
        case "Order.Descending": return (c, true)
        default: return nil
        }
    }

    private static func typePair(_ f: StepFragment) -> (column: String, type: DataType)? {
        guard let pair = f.items, pair.count == 2, let c = pair[0].textValue, let t = pair[1].dataType else { return nil }
        return (c, t)
    }

    // MARK: Rows and columns

    private static let statisticFunctions: [String: ColumnStatistic] = [
        "List.Sum": .sum, "List.Min": .minimum, "List.Max": .maximum, "List.Median": .median, "List.Average": .average,
        "List.StandardDeviation": .standardDeviation, "List.NonNullCount": .countValues,
    ]

    /// `List.Sum(Prev[Column])`, `List.Count(List.Distinct(Prev[Column]))`, earliest and latest.
    private static func statistic(_ name: String, _ args: [StepFragment]) -> [Candidate]? {
        guard args.count == 1 else { return nil }
        if name == "List.Count", let inner = args[0].call, inner.name == "List.Distinct", inner.args.count == 1,
           let access = inner.args[0].fieldAccess {
            return [(.statistic(column: access.column, .countDistinctValues), access.target)]
        }
        guard let s = statisticFunctions[name], let access = args[0].fieldAccess else { return nil }
        var ts: [Transform] = [.statistic(column: access.column, s)]
        if s == .minimum { ts.append(.earliest(column: access.column)) }
        if s == .maximum { ts.append(.latest(column: access.column)) }
        return ts.map { ($0, access.target) }
    }

    private static func groupBy(_ args: [StepFragment]) -> Transform? {
        guard args.count == 3, let keys = args[1].names, let elements = args[2].items else { return nil }
        let aggs = elements.map(groupAggregation)
        guard aggs.allSatisfy({ $0 != nil }) else { return nil }
        return .groupBy(keys: keys, aggregations: aggs.compactMap { $0 })
    }

    /// One `{"Name", each body, type}` of Table.Group, matched on its name and body (the type annotation may differ).
    private static func groupAggregation(_ element: StepFragment) -> (name: String, aggregation: GroupAggregation)? {
        guard let parts = element.items, parts.count == 2 || parts.count == 3, let name = parts[0].textValue,
              let body = parts[1].eachBody else { return nil }
        var options: [GroupAggregation] = [.countRows, .countDistinctRows, .allRows]
        for c in body.columnReferences {
            options += [.sum(column: c), .average(column: c), .median(column: c), .min(column: c), .max(column: c),
                        .standardDeviation(column: c), .countDistinct(column: c)]
        }
        let wanted = body.key
        for option in options {
            let rendered = Transform.groupBy(keys: [], aggregations: [(name, option)]).expression(previous: "x")
            guard let e = StepFragment(rendered)?.call?.args.last?.items?.first?.items, e.count >= 2, let b = e[1].eachBody else { continue }
            if b.key == wanted { return (name, option) }
        }
        return nil
    }

    private static func tableAggregation(_ element: StepFragment) -> (column: String, statistic: ColumnStatistic, newName: String)? {
        guard let parts = element.items, parts.count == 3, let c = parts[0].textValue, let n = parts[2].textValue else { return nil }
        let wanted = "Table.AggregateTableColumn(x, \"t\", {\(element.text)})"
        return ColumnStatistic.allCases.first { matches(.aggregateTableColumn(column: "t", aggregations: [(c, $0, n)]), "x", wanted) }
            .map { (c, $0, n) }
    }

    private static func splits(_ column: String, _ splitter: StepFragment, _ target: SplitTarget) -> [Transform] {
        guard let (name, args) = splitter.call, let first = args.first else { return [] }
        switch name {
        case "Splitter.SplitTextByDelimiter":
            return first.textValue.map { [.splitByDelimiter(column: column, delimiter: $0, at: .each, into: target)] } ?? []
        case "Splitter.SplitTextByEachDelimiter":
            guard let d = first.texts?.first else { return [] }
            return [SplitPosition.leftmost, .rightmost].map { .splitByDelimiter(column: column, delimiter: d, at: $0, into: target) }
        case "Splitter.SplitTextByRepeatedLengths":
            return first.intValue.map { [.splitByLength(column: column, length: $0, repeated: true, into: target)] } ?? []
        case "Splitter.SplitTextByPositions":
            guard let items = first.items else { return [] }
            let positions = items.compactMap(\.intValue)
            guard positions.count == items.count else { return [] }
            var out: [Transform] = []
            if positions.count == 2, positions[0] == 0 { out.append(.splitByLength(column: column, length: positions[1], repeated: false, into: target)) }
            return out + [.splitByPositions(column: column, positions: positions, into: target)]
        case "Splitter.SplitTextByCharacterTransition":
            return [CharacterTransition.lowerToUpper, .upperToLower, .digitToNonDigit, .nonDigitToDigit]
                .map { .splitByTransition(column: column, $0, into: target) }
        default: return []
        }
    }

    // MARK: Per-value operations

    private static let textFormats: [String: TextFormat] = [
        "Text.Lower": .lowercase, "Text.Upper": .uppercase, "Text.Proper": .capitalizeEachWord, "Text.Trim": .trim, "Text.Clean": .clean,
    ]

    private static func numberOperations(_ numbers: [Double]) -> [NumberOperation] {
        var out: [NumberOperation] = [.absolute, .squareRoot, .exponent, .log10, .naturalLog, .factorial, .sine, .cosine, .tangent,
                                      .arcsine, .arccosine, .arctangent, .roundUp, .roundDown, .isEven, .isOdd, .sign]
        for n in numbers {
            out += [.add(n), .subtract(n), .multiply(n), .divide(n), .integerDivide(n), .modulo(n), .percentage(n), .percentOf(n), .power(n)]
            if n == n.rounded(), abs(n) < 1000 { out.append(.round(digits: Int(n))) }
        }
        return out
    }

    private static func textExtracts(_ body: StepFragment) -> [TextExtract] {
        let ints = body.numbers.filter { $0 >= 0 && $0 == $0.rounded() && $0 < 1e9 }.map { Int($0) }
        let texts = body.textLiterals
        var out: [TextExtract] = [.length]
        for n in ints { out += [.firstCharacters(n), .lastCharacters(n)] }
        for a in ints { for b in ints { out.append(.range(start: a, count: b)) } }
        for t in texts { out += [.beforeDelimiter(t), .afterDelimiter(t)] }
        for a in texts { for b in texts { out.append(.betweenDelimiters(a, b)) } }
        return out
    }

    /// `Table.TransformColumns(Prev, {{"Column", function, type}, …})`: text format, prefix/suffix, extract, parse,
    /// number and date operations in place, and extracting the values of a list column.
    private static func transformColumns(_ list: StepFragment) -> [Transform] {
        guard let elements = list.items, !elements.isEmpty else { return [] }
        var columns: [String] = [], functions: [StepFragment] = []
        for e in elements {
            guard let parts = e.items, parts.count == 2 || parts.count == 3, let c = parts[0].textValue else { return [] }
            columns.append(c)
            functions.append(parts[1])
        }
        if let f = functions[0].identifier?.name {
            var out: [Transform] = textFormats[f].map { [.formatText(columns: columns, $0)] } ?? []
            if columns.count == 1, f == "Json.Document" || f == "Xml.Tables" { out.append(.parse(column: columns[0], f == "Json.Document" ? .json : .xml)) }
            return out
        }
        guard let body = functions[0].eachBody else { return [] }
        var out: [Transform] = []
        for t in body.textLiterals { out += [.addPrefix(columns: columns, t), .addSuffix(columns: columns, t)] }
        out += numberOperations(body.numbers).map { .number(columns: columns, $0, newColumn: nil) }
        out += DateOperation.allCases.map { .date(columns: columns, $0, newColumn: nil) }
        if columns.count == 1 {
            out += textExtracts(body).map { .extractText(column: columns[0], $0, newColumn: nil) }
            out += body.textLiterals.map { .extractListValues(column: columns[0], delimiter: $0) }
        }
        return out
    }

    /// `Table.AddColumn(Prev, "Name", each body[, type])`: the Add Column tab's operations, conditional columns, invoked
    /// custom functions, and otherwise a custom column.
    private static func addColumn(_ args: [StepFragment]) -> [Transform] {
        guard args.count == 3 || args.count == 4, let name = args[1].textValue, let body = args[2].eachBody else { return [] }
        var out: [Transform] = []
        for c in body.columnReferences {
            out += numberOperations(body.numbers).map { .number(columns: [c], $0, newColumn: name) }
            out += DateOperation.allCases.map { .date(columns: [c], $0, newColumn: name) }
            out += textExtracts(body).map { .extractText(column: c, $0, newColumn: name) }
            out += [.aiSentiment(column: c, newColumn: name), .aiKeyPhrases(column: c, newColumn: name),
                    .aiDetectLanguage(column: c, newColumn: name), .aiTagImage(column: c, newColumn: name)]
        }
        if args.count == 3, let conditional = ConditionalRecognizer.column(name, body) { out.append(conditional) }
        if args.count == 3, let (fn, fargs) = body.call, MLibrary.shared.values[fn] == nil {
            let operands = fargs.map(ConditionalRecognizer.operand)
            if operands.allSatisfy({ $0 != nil }) { out.append(.invokeCustomFunction(name: name, function: fn, arguments: operands.compactMap { $0 })) }
        }
        if args.count == 3 { out.append(.addCustomColumn(name: name, expression: body.text, type: nil)) }
        else if let t = args[3].dataType { out.append(.addCustomColumn(name: name, expression: body.text, type: t)) }
        return out
    }

    private static func indexColumn(_ args: [StepFragment]) -> Transform? {
        guard args.count == 4 || args.count == 5, let name = args[1].textValue, let start = args[2].intValue,
              let step = args[3].intValue else { return nil }
        return .addIndexColumn(name: name, start: start, increment: step)
    }

    // MARK: Combine

    private static func merge(_ name: String, _ args: [StepFragment]) -> Transform? {
        let fuzzy = name == "Table.FuzzyNestedJoin"
        guard args.count == (fuzzy ? 7 : 6), let lk = args[1].names, let other = args[2].identifier?.name, let rk = args[3].names,
              let new = args[4].textValue, let kindName = args[5].identifier?.name, kindName.hasPrefix("JoinKind."),
              let kind = MergeJoinKind(rawValue: String(kindName.dropFirst("JoinKind.".count))) else { return nil }
        guard fuzzy else { return .mergeQueries(other: other, leftKeys: lk, rightKeys: rk, kind: kind, newColumn: new, fuzzy: nil) }
        guard let fields = args[6].fields else { return nil }
        var o = FuzzyMergeOptions()
        for (field, value) in fields {
            switch field {
            case "IgnoreCase": guard let b = value.boolValue else { return nil }; o.ignoreCase = b
            case "IgnoreSpace": guard let b = value.boolValue else { return nil }; o.ignoreSpace = b
            case "Threshold": guard let d = value.numberValue else { return nil }; o.threshold = d
            case "NumberOfMatches": guard let n = value.intValue else { return nil }; o.maximumMatches = n
            case "TransformationTable": guard let t = value.identifier?.name else { return nil }; o.transformationTable = t
            default: return nil
            }
        }
        return .mergeQueries(other: other, leftKeys: lk, rightKeys: rk, kind: kind, newColumn: new, fuzzy: o)
    }

    /// `Table.Combine({Prev, Other, …})` (append) or the combine-files form over a folder listing.
    private static func combine(_ list: StepFragment?) -> [Candidate] {
        guard let list else { return [] }
        if let items = list.items, !items.isEmpty {
            let ids = items.compactMap(\.identifier)
            guard ids.count == items.count else { return [] }
            return [(.appendQueries(ids.dropFirst().map(\.name)), ids[0].source)]
        }
        let t = list.tokens
        guard list.call?.name == "List.Transform",
              let i = t.indices.first(where: { t[$0].kind == .identifier && t[$0].text == "Table.SelectRows" }), i + 2 < t.endIndex,
              let p = list.sub((i + 2)..<(i + 3)).identifier?.source else { return [] }
        let texts = list.textLiterals
        var formats: [CombineFilesFormat] = [.json, .parquet, .excel(sheet: nil)] + texts.map { .excel(sheet: $0) }
        for d in texts { formats += [.csv(delimiter: d, promoteHeaders: true), .csv(delimiter: d, promoteHeaders: false)] }
        return formats.map { (.combineFiles($0), p) }
    }

    private static func expand(_ name: String, _ args: [StepFragment]) -> [Transform] {
        guard args.count == 4, let c = args[1].textValue, let fields = args[2].names, let newNames = args[3].names else { return [] }
        let record = name == "Table.ExpandRecordColumn"
        return [nil, newNames].map {
            record ? .expandRecordColumn(column: c, fields: fields, newNames: $0) : .expandTableColumn(column: c, columns: fields, newNames: $0)
        }
    }

    // MARK: Other shapes

    /// Keep Duplicates: a `let` that groups by the key columns, keeps groups of more than one row and joins back.
    private static func keepDuplicates(_ s: StepFragment) -> [Candidate] {
        let t = s.tokens
        guard let g = t.indices.first(where: { t[$0].kind == .identifier && t[$0].text == "Table.Group" }), g + 2 < t.endIndex,
              let p = s.sub((g + 2)..<(g + 3)).identifier?.source else { return [] }
        var out: [Transform] = []
        if let c = t.indices.first(where: { t[$0].kind == .identifier && t[$0].text == "columnNames" }), c + 2 < t.endIndex,
           t[c + 2].text == "{", let close = s.closing(c + 2), let names = s.sub((c + 2)..<(close + 1)).texts {
            out.append(.keepDuplicates(columns: names))
        }
        out.append(.keepDuplicates(columns: []))
        return out.map { ($0, p) }
    }

    /// `Python.Execute("script", [dataset = Prev]){[Name = "dataset"]}[Value]` (and R).
    private static func script(_ s: StepFragment) -> [Candidate] {
        let start = s.tokens.startIndex
        guard start + 1 < s.tokens.endIndex, let close = s.closing(start + 1), let (name, args) = s.sub(start..<(close + 1)).call,
              args.count == 2, let code = args[0].textValue, let record = args[1].fields, record.count == 1,
              record[0].name == "dataset", let p = record[0].value.identifier?.source else { return [] }
        return [(name == "Python.Execute" ? .runPythonScript(code) : .runRScript(code), p)]
    }

    // MARK: Equivalent Power BI forms

    /// Forms that mean the same as a transform but are not written exactly as it emits them.
    private static func equivalent(_ s: StepFragment) -> Candidate? {
        guard let (name, args) = s.call, let p = args.first?.identifier?.source else { return nil }
        switch name {
        case "Table.FuzzyNestedJoin": return merge(name, args).map { ($0, p) }
        case "Table.Group": return groupBy(args).map { ($0, p) }
        case "Table.AddIndexColumn": return indexColumn(args).map { ($0, p) }
        case "Table.CombineColumns":
            guard args.count == 4, let cols = args[1].names, let sep = combinerSeparator(args[2]), let new = args[3].textValue else { return nil }
            return (.mergeColumns(cols, separator: sep, newName: new), p)
        case "Table.ExpandRecordColumn", "Table.ExpandTableColumn":
            guard args.count == 3, let c = args[1].textValue, let fields = args[2].names else { return nil }
            return (name == "Table.ExpandRecordColumn" ? .expandRecordColumn(column: c, fields: fields, newNames: fields)
                                                       : .expandTableColumn(column: c, columns: fields, newNames: fields), p)
        default: return nil
        }
    }
}
