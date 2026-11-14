import XCTest
import FacetCore
@testable import FacetQuery

/// `Transform.recognize`: every step the editor writes is read back as the same transform ("Edit settings").
final class TransformRecognitionTests: XCTestCase {
    private let prev = "#\"Prev Step\""
    /// 1 January 2024, midnight UTC, and 13:30 that day.
    private let day = Value.date(Date(timeIntervalSince1970: 1_704_067_200))
    private let moment = Value.date(Date(timeIntervalSince1970: 1_704_067_200 + 48_600))

    /// Each transform's M is recognised as a transform that re-emits it byte for byte and, unless the M is shared by
    /// two transforms, as the same kind of step (same default step name).
    private func assertRoundTrip(_ transforms: [Transform], sameStep: Bool = true, file: StaticString = #filePath, line: UInt = #line) {
        for t in transforms {
            let m = t.expression(previous: prev)
            guard let r = Transform.recognize(m) else { XCTFail("not recognised: \(m)", file: file, line: line); continue }
            XCTAssertEqual(r.previous, prev, m, file: file, line: line)
            XCTAssertEqual(r.transform.expression(previous: prev), m, file: file, line: line)
            if sameStep { XCTAssertEqual(r.transform.stepName, t.stepName, m, file: file, line: line) }
        }
    }

    // MARK: Round trips

    func testRowTransforms() {
        assertRoundTrip([
            .keepTopRows(3), .keepBottomRows(2), .keepRangeOfRows(first: 4, count: 10), .removeTopRows(1), .removeBottomRows(5),
            .removeAlternateRows(firstToRemove: 2, numberToRemove: 1, numberToKeep: 3),
            .removeDuplicates(columns: []), .removeDuplicates(columns: ["A", "B c"]), .keepDuplicates(columns: []), .keepDuplicates(columns: ["A"]),
            .removeBlankRows, .removeErrors(columns: []), .removeErrors(columns: ["A"]), .keepErrors(columns: []), .keepErrors(columns: ["A", "B"]),
            .sortRows([("A", false), ("Unit Price", true)]),
        ])
    }

    func testFilterConditions() {
        var conditions: [QFilter] = []
        for op in QFilter.Comparison.allCases {
            conditions += [.compare(column: "Qty", op, 5), .compare(column: "Price", op, 2.5), .compare(column: "Region", op, "North"),
                           .compare(column: "Date", op, day, type: .date), .compare(column: "At", op, moment, type: .dateTime),
                           .compare(column: "Qty", op, -3)]
        }
        for m in QFilter.TextMatch.allCases {
            conditions += [.text(column: "Name", m, "an"), .text(column: "Name", m, "An", ignoreCase: true)]
        }
        conditions += [
            .isNull(column: "A"), .isNotNull(column: "A"), .isBlank(column: "A b"), .isNotBlank(column: "A"),
            .between(column: "Qty", 1, 10), .between(column: "Date", day, day, type: .date),
            .inList(column: "Region", ["North", "South"]), .inList(column: "Qty", [1, 2, 3]),
            .and([.compare(column: "Qty", .greaterThan, 5), .isNotNull(column: "Region")]),
            .or([.text(column: "Name", .contains, "x"), .isBlank(column: "Name"), .compare(column: "Qty", .equals, 0)]),
            .not(.inList(column: "Region", ["East"])),
            .and([.or([.isNull(column: "A"), .isNull(column: "B")]), .not(.isBlank(column: "C"))]),
            .custom("[A] + [B] > 10"),
        ]
        var relative: [QFilter.RelativeDate] = [.yearToDate, .isEarliest, .isLatest, .isNotEarliest, .isNotLatest,
                                                .year(2024), .quarter(2), .month(11), .day(14)]
        for u in QFilter.DateUnit.allCases { relative += [.inCurrent(u), .inPrevious(u), .inNext(u), .inPreviousN(3, u), .inNextN(2, u)] }
        conditions += relative.map { .date(column: "Order Date", $0) }
        assertRoundTrip(conditions.map { .filterRows($0) })
    }

    func testColumnAndHeaderTransforms() {
        assertRoundTrip([
            .chooseColumns(["A", "B"]), .removeOtherColumns(keeping: ["A"]), .removeColumns(["A", "B"]), .reorderColumns(["B", "A"]),
            .renameColumns([("A", "Alpha"), ("B c", "Beta")]), .duplicateColumn("A", newName: "A - Copy"),
            .changeType([("A", .integer), ("B", .decimal), ("C", .currency), ("D", .text), ("E", .date), ("F", .dateTime),
                         ("G", .time), ("H", .duration), ("I", .boolean), ("J", .binary), ("K", .any)], culture: nil),
            .changeType([("Amount", .decimal), ("When", .date)], culture: "de-DE"),
            .promoteHeaders, .demoteHeaders,
        ])
    }

    func testReshapeTransforms() {
        var ts: [Transform] = [.pivotColumn(column: "Attribute", valueColumn: "Value", aggregation: nil)]
        ts += ColumnStatistic.allCases.map { .pivotColumn(column: "Attribute", valueColumn: "Value", aggregation: $0) }
        ts += [
            .unpivotColumns(["Jan", "Feb"]), .unpivotOtherColumns(keeping: ["Region"]), .transpose, .reverseRows, .countRows,
            .groupBy(keys: ["Region", "Product"], aggregations: [
                ("Total", .sum(column: "Qty")), ("Mean", .average(column: "Qty")), ("Mid", .median(column: "Qty")),
                ("Low", .min(column: "Price")), ("High", .max(column: "Price")), ("Spread", .standardDeviation(column: "Price")),
                ("Kinds", .countDistinct(column: "Product")), ("Count", .countRows), ("Distinct", .countDistinctRows), ("Rows", .allRows),
            ]),
            .groupBy(keys: [], aggregations: [("Count", .countRows)]),
        ]
        assertRoundTrip(ts)
    }

    func testSplitAndMergeTransforms() {
        var ts: [Transform] = []
        for target in [SplitTarget.columns(3), .rows] {
            for at in [SplitPosition.each, .leftmost, .rightmost] { ts.append(.splitByDelimiter(column: "Name", delimiter: ", ", at: at, into: target)) }
            ts += [.splitByLength(column: "Code", length: 2, repeated: true, into: target),
                   .splitByLength(column: "Code", length: 4, repeated: false, into: target),
                   .splitByPositions(column: "Code", positions: [0, 2, 5], into: target)]
            for k in [CharacterTransition.lowerToUpper, .upperToLower, .digitToNonDigit, .nonDigitToDigit] {
                ts.append(.splitByTransition(column: "Code", k, into: target))
            }
        }
        ts.append(.mergeColumns(["First", "Last"], separator: " ", newName: "Full Name"))
        assertRoundTrip(ts)
    }

    func testTextTransforms() {
        var ts: [Transform] = TextFormat.allCases.map { .formatText(columns: ["A", "B"], $0) }
        ts += [.addPrefix(columns: ["A"], "ID-"), .addSuffix(columns: ["A", "B"], " kg"), .parse(column: "Raw", .json), .parse(column: "Raw", .xml)]
        let extracts: [TextExtract] = [.length, .firstCharacters(3), .lastCharacters(2), .range(start: 1, count: 4),
                                       .beforeDelimiter("-"), .afterDelimiter("/"), .betweenDelimiters("(", ")")]
        for e in extracts { ts += [.extractText(column: "Code", e, newColumn: nil), .extractText(column: "Code", e, newColumn: "Part")] }
        assertRoundTrip(ts)
    }

    func testNumberAndDateTransforms() {
        let ops: [NumberOperation] = [.add(5), .subtract(1.5), .multiply(2), .divide(4), .integerDivide(3), .modulo(7), .percentage(15),
                                      .percentOf(200), .absolute, .power(2), .squareRoot, .exponent, .log10, .naturalLog, .factorial,
                                      .sine, .cosine, .tangent, .arcsine, .arccosine, .arctangent, .round(digits: 2), .roundUp, .roundDown,
                                      .isEven, .isOdd, .sign, .add(-3)]
        var ts: [Transform] = []
        for op in ops { ts += [.number(columns: ["Qty", "Price"], op, newColumn: nil), .number(columns: ["Qty"], op, newColumn: "Result")] }
        for op in DateOperation.allCases { ts += [.date(columns: ["When", "Then"], op, newColumn: nil), .date(columns: ["When"], op, newColumn: op.rawValue)] }
        ts += ColumnStatistic.allCases.map { .statistic(column: "Qty", $0) }
        assertRoundTrip(ts)
        // Earliest and latest are written as List.Min / List.Max, the same M as the minimum and maximum statistics.
        assertRoundTrip([.earliest(column: "When"), .latest(column: "When")], sameStep: false)
    }

    func testFillReplaceAndAddColumnTransforms() {
        assertRoundTrip([
            .fillDown(["A"]), .fillUp(["A", "B"]),
            .replaceValues(columns: ["Name"], find: "St.", replaceWith: "Street", matchEntireCell: false),
            .replaceValues(columns: ["Name"], find: "n/a", replaceWith: nil, matchEntireCell: true),
            .replaceValues(columns: ["Qty", "Price"], find: nil, replaceWith: 0, matchEntireCell: true),
            .replaceValues(columns: ["Date"], find: day, replaceWith: moment, matchEntireCell: true),
            .replaceErrors(columns: ["Qty", "Price"], with: 0), .replaceErrors(columns: ["Name"], with: "unknown"),
            .addCustomColumn(name: "Total", expression: "[Qty] * [Price]", type: nil),
            .addCustomColumn(name: "Total", expression: "[Qty] * [Price]", type: .currency),
            .addCustomColumn(name: "Label", expression: "if [Qty] > 5 then \"big\" else \"small\"", type: .text),
            .addConditionalColumn(name: "Band", clauses: [
                ConditionalClause(column: "Qty", op: .greaterThan, value: .value(100), output: .value("High")),
                ConditionalClause(column: "Qty", op: .lessOrEqual, value: .column("Limit"), output: .column("Region")),
                ConditionalClause(column: "Name", op: .contains, value: .value("x"), output: .value(1)),
                ConditionalClause(column: "Name", op: .doesNotContain, value: .value("y"), output: .value(nil)),
                ConditionalClause(column: "Name", op: .beginsWith, value: .value("A"), output: .value(true)),
                ConditionalClause(column: "Name", op: .endsWith, value: .value("z"), output: .value(2.5)),
                ConditionalClause(column: "Name", op: .isNotNull, value: .value(nil), output: .value("set")),
                ConditionalClause(column: "When", op: .equals, value: .value(day), output: .value("new year")),
                ConditionalClause(column: "Qty", op: .notEquals, value: .value(0), output: .value("some")),
                ConditionalClause(column: "Qty", op: .greaterOrEqual, value: .value(1), output: .value("one")),
                ConditionalClause(column: "Qty", op: .lessThan, value: .value(-1), output: .value("negative")),
            ], otherwise: .value("Low")),
            .addConditionalColumn(name: "Flag", clauses: [ConditionalClause(column: "A", op: .isNull, value: .value(nil), output: .column("B"))],
                                  otherwise: .column("A")),
            .addIndexColumn(name: "Index", start: 1, increment: 1), .addIndexColumn(name: "Row", start: 0, increment: 10),
            .invokeCustomFunction(name: "Score", function: "fnScore", arguments: [.column("Qty"), .value("x"), .value(2)]),
            .invokeCustomFunction(name: "Score", function: "My Function", arguments: [.column("Unit Price")]),
        ])
        // A column from examples is a custom column without a type: the same M.
        assertRoundTrip([.addColumnFromExamples(name: "First", expression: "Text.BeforeDelimiter([Name], \" \")")], sameStep: false)
    }

    func testCombineStructuredAndScriptTransforms() {
        var fuzzy = FuzzyMergeOptions(threshold: 0.7)
        fuzzy.ignoreCase = false
        fuzzy.maximumMatches = 1
        fuzzy.transformationTable = "Synonyms"
        var ts: [Transform] = MergeJoinKind.allCases.map {
            .mergeQueries(other: "Products", leftKeys: ["ProductID"], rightKeys: ["ID"], kind: $0, newColumn: "Products", fuzzy: nil)
        }
        ts += [
            .mergeQueries(other: "Other Query", leftKeys: ["A", "B"], rightKeys: ["A", "B"], kind: .inner, newColumn: "Other", fuzzy: FuzzyMergeOptions()),
            .mergeQueries(other: "Fruits", leftKeys: ["Fruit"], rightKeys: ["Name"], kind: .leftOuter, newColumn: "Fruits", fuzzy: fuzzy),
            .appendQueries(["Sales 2023"]), .appendQueries(["A", "B", "C"]),
            .combineFiles(.csv(delimiter: ";", promoteHeaders: true)), .combineFiles(.csv(delimiter: ",", promoteHeaders: false)),
            .combineFiles(.json), .combineFiles(.excel(sheet: nil)), .combineFiles(.excel(sheet: "Data")), .combineFiles(.parquet),
            .expandRecordColumn(column: "Address", fields: ["City", "Zip"], newNames: nil),
            .expandRecordColumn(column: "Address", fields: ["City"], newNames: ["Town"]),
            .expandTableColumn(column: "Orders", columns: ["Qty", "Price"], newNames: nil),
            .expandTableColumn(column: "Orders", columns: ["Qty"], newNames: ["Quantity"]),
            .expandListColumn(column: "Tags"), .extractListValues(column: "Tags", delimiter: ", "),
            .aggregateTableColumn(column: "Orders", aggregations: [("Qty", .sum, "Sum of Qty"), ("Price", .average, "Average Price"),
                                                                   ("Id", .countDistinctValues, "Orders")]),
            .aiSentiment(column: "Review", newColumn: "Sentiment"), .aiKeyPhrases(column: "Review", newColumn: "Phrases"),
            .aiDetectLanguage(column: "Review", newColumn: "Language"), .aiTagImage(column: "Photo", newColumn: "Tags"),
            .runPythonScript("dataset['x'] = 1\nprint(\"done\")"), .runRScript("dataset$x <- 1"),
        ]
        assertRoundTrip(ts)
    }

    // MARK: Decoded values

    func testPowerBIChangedTypeStep() throws {
        let r = try XCTUnwrap(Transform.recognize(#"Table.TransformColumnTypes(#"Promoted Headers",{{"A", Int64.Type}, {"B", type text}, {"C", type nullable number}})"#))
        XCTAssertEqual(r.previous, #"#"Promoted Headers""#)
        guard case .changeType(let changes, let culture) = r.transform else { return XCTFail("\(r.transform)") }
        XCTAssertEqual(changes.map(\.column), ["A", "B", "C"])
        XCTAssertEqual(changes.map(\.type), [.integer, .text, .decimal])
        XCTAssertNil(culture)
        let localised = try XCTUnwrap(Transform.recognize(#"Table.TransformColumnTypes(Source, {{"Date", type date}}, "en-GB")"#))
        guard case .changeType(let c2, let culture2) = localised.transform else { return XCTFail() }
        XCTAssertEqual(c2.first?.type, .date)
        XCTAssertEqual(culture2, "en-GB")
    }

    func testPowerBICustomColumnAndGroupBy() throws {
        let custom = try XCTUnwrap(Transform.recognize(#"Table.AddColumn(Source, "Custom", each [A] * 2)"#))
        XCTAssertEqual(custom.previous, "Source")
        guard case .addCustomColumn(let name, let expression, let type) = custom.transform else { return XCTFail("\(custom.transform)") }
        XCTAssertEqual(name, "Custom")
        XCTAssertEqual(expression, "[A] * 2")
        XCTAssertNil(type)

        let group = try XCTUnwrap(Transform.recognize(
            #"Table.Group(Source, {"K"}, {{"Count", each Table.RowCount(_), Int64.Type}, {"Total", each List.Sum([Amount]), type number}, {"All", each _, type table [K=text, Amount=number]}})"#))
        guard case .groupBy(let keys, let aggs) = group.transform else { return XCTFail("\(group.transform)") }
        XCTAssertEqual(keys, ["K"])
        XCTAssertEqual(aggs.map(\.name), ["Count", "Total", "All"])
        guard case .countRows = aggs[0].aggregation, case .sum(let column) = aggs[1].aggregation, case .allRows = aggs[2].aggregation else {
            return XCTFail("\(aggs)")
        }
        XCTAssertEqual(column, "Amount")
    }

    func testPowerBIMerges() throws {
        let plain = try XCTUnwrap(Transform.recognize(#"Table.NestedJoin(#"Changed Type", {"ProductID"}, Products, {"ID"}, "Products", JoinKind.LeftAnti)"#))
        XCTAssertEqual(plain.previous, #"#"Changed Type""#)
        guard case .mergeQueries(let other, let lk, let rk, let kind, let new, let fuzzy) = plain.transform else { return XCTFail() }
        XCTAssertEqual(other, "Products"); XCTAssertEqual(lk, ["ProductID"]); XCTAssertEqual(rk, ["ID"])
        XCTAssertEqual(kind, .leftAnti); XCTAssertEqual(new, "Products"); XCTAssertNil(fuzzy)

        // Options in another order, IgnoreSpace left at its default.
        let fz = try XCTUnwrap(Transform.recognize(#"Table.FuzzyNestedJoin(Source, {"Fruit"}, Fruits, {"Name"}, "Fruits", JoinKind.LeftOuter, [Threshold=0.65, IgnoreCase=false, NumberOfMatches=2])"#))
        guard case .mergeQueries(_, _, _, .leftOuter, _, let options?) = fz.transform else { return XCTFail("\(fz.transform)") }
        XCTAssertEqual(options.threshold, 0.65)
        XCTAssertFalse(options.ignoreCase)
        XCTAssertTrue(options.ignoreSpace)
        XCTAssertEqual(options.maximumMatches, 2)
        XCTAssertNil(options.transformationTable)
    }

    func testPowerBIFiltersAndOtherForms() throws {
        // Power BI wraps a simple filter in parentheses: kept as the hand-written condition.
        let wrapped = try XCTUnwrap(Transform.recognize(#"Table.SelectRows(#"Changed Type", each ([Region] = "North"))"#))
        guard case .filterRows(.custom(let body)) = wrapped.transform else { return XCTFail("\(wrapped.transform)") }
        XCTAssertEqual(body, #"([Region] = "North")"#)

        let structured = try XCTUnwrap(Transform.recognize(#"Table.SelectRows(Source, each ([Qty] > 5) and ([Region] <> null))"#))
        guard case .filterRows(.and(let parts)) = structured.transform, parts.count == 2,
              case .compare("Qty", .greaterThan, let five, _) = parts[0], case .isNotNull("Region") = parts[1] else {
            return XCTFail("\(structured.transform)")
        }
        XCTAssertEqual(five, 5)

        let replace = try XCTUnwrap(Transform.recognize(#"Table.ReplaceValue(#"Changed Type",null,0,Replacer.ReplaceValue,{"Qty"})"#))
        guard case .replaceValues(let cols, let find, let with, _) = replace.transform else { return XCTFail() }
        XCTAssertEqual(cols, ["Qty"]); XCTAssertEqual(find, .null); XCTAssertEqual(with, 0)

        let split = try XCTUnwrap(Transform.recognize(#"Table.SplitColumn(Source, "Name", Splitter.SplitTextByDelimiter(" ", QuoteStyle.Csv), {"Name.1", "Name.2"})"#))
        guard case .splitByDelimiter("Name", " ", .each, .columns(2)) = split.transform else { return XCTFail("\(split.transform)") }

        let sort = try XCTUnwrap(Transform.recognize(#"Table.Sort(Source,{{"Date", Order.Descending}})"#))
        guard case .sortRows(let keys) = sort.transform else { return XCTFail() }
        XCTAssertEqual(keys.map(\.column), ["Date"]); XCTAssertEqual(keys.map(\.descending), [true])

        let index = try XCTUnwrap(Transform.recognize(#"Table.AddIndexColumn(Source, "Index", 0, 1)"#))
        guard case .addIndexColumn("Index", 0, 1) = index.transform else { return XCTFail("\(index.transform)") }

        let merged = try XCTUnwrap(Transform.recognize(#"Table.CombineColumns(Source,{"First", "Last"},Combiner.CombineTextByDelimiter(" ", QuoteStyle.None),"Full Name")"#))
        guard case .mergeColumns(["First", "Last"], " ", "Full Name") = merged.transform else { return XCTFail("\(merged.transform)") }

        let expand = try XCTUnwrap(Transform.recognize(#"Table.ExpandTableColumn(Source, "Orders", {"Qty"})"#))
        guard case .expandTableColumn("Orders", ["Qty"], ["Qty"]) = expand.transform else { return XCTFail("\(expand.transform)") }

        let top = try XCTUnwrap(Transform.recognize("Table.FirstN(Source, 3)"))
        XCTAssertEqual(top.previous, "Source")
        guard case .keepTopRows(3) = top.transform else { return XCTFail() }
    }

    func testUnrecognisedStepsAreNil() {
        for text in ["Table.Buffer(Source)", "Source{0}[Data]", "Table.FirstN(Source", "\"abc", "", "Table.FirstN(Source, each [A] > 1)",
                     #"Table.Sort(Source, {{"A", 0}})"#, #"Table.TransformColumnTypes(Source, {{"A", type table}})"#,
                     "Table.PromoteHeaders(Source)", #"Table.AddColumn(Source, "X", (r) => r[A])"#, "Table.FirstN(Table.Skip(Source, 1), 2)",
                     #"Table.SplitColumn(Source, "N", Splitter.SplitTextByDelimiter(","), {"A", "B"})"#] {
            XCTAssertNil(Transform.recognize(text), text)
        }
    }
}
