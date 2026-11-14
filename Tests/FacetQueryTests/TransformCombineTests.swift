import XCTest
import FacetCore
@testable import FacetQuery

/// Add-column, merge, append, structured-column, AI and script transforms.
final class TransformCombineTests: TransformTestCase {
    let orders = "#table({\"OrderId\", \"Cust\"}, {{1, \"A\"}, {2, \"B\"}, {3, \"C\"}, {4, null}})"
    let customers = ("Customers", "#table({\"Id\", \"Name\"}, {{\"A\", \"Ann\"}, {\"B\", \"Bob\"}, {\"B\", \"Bobby\"}, {\"D\", \"Dee\"}, {null, \"Nobody\"}})")

    func testAddCustomColumn() async throws {
        var v = try await apply(.addCustomColumn(name: "Total", expression: "[Qty] * [Price]", type: .decimal), on: sales)
        XCTAssertEqual(columnNames(v), ["Region", "Product", "Qty", "Price", "Total"])
        XCTAssertEqual(try tableRows(v).map(\.last), ["15", "10", "14", "null", "4.5"])
        XCTAssertEqual(v.tableValue?.columnTypes.last, .plainNumber)
        // a failing expression is a cell error, the query still loads
        v = try await apply(.addCustomColumn(name: "Bad", expression: "[Qty] + [Region]", type: nil), on: sales)
        XCTAssertEqual(try tableRows(v).map(\.last), ["<error>", "<error>", "<error>", "<error>", "<error>"])
        let preview = try await engine([("Q", script([.addCustomColumn(name: "Bad", expression: "if [Qty] > 6 then 1 else error \"too small\"", type: nil)], on: sales))]).evaluatePreview("Q")
        XCTAssertEqual(preview.cellErrors[4]?.keys.sorted(), [1, 3, 4]) // 5 and 3 are too small; null > 6 can't be tested
        XCTAssertTrue(preview.cellErrors[4]?[1]?.contains("too small") ?? false)
        XCTAssertEqual(preview.table.column("Bad")?.values, [.int(1), .null, .int(1), .null, .null])
    }
    func testAddConditionalColumn() async throws {
        let clauses = [ConditionalClause(column: "Qty", op: .greaterThan, value: .value(.int(6)), output: .value(.string("High"))),
                       ConditionalClause(column: "Qty", op: .greaterOrEqual, value: .value(.int(5)), output: .value(.string("Mid")))]
        var v = try await apply(.addConditionalColumn(name: "Band", clauses: clauses, otherwise: .value(.string("Low"))), on: sales)
        // "if null > 6" is an error in M, so the row without a quantity shows an error
        XCTAssertEqual(try tableRows(v).map(\.last), ["High", "Mid", "High", "<error>", "Low"])
        let text = [ConditionalClause(column: "Region", op: .beginsWith, value: .value(.string("N")), output: .column("Product")),
                    ConditionalClause(column: "Region", op: .contains, value: .value(.string("as")), output: .value(.int(0))),
                    ConditionalClause(column: "Product", op: .endsWith, value: .value(.string("ear")), output: .value(.string("pear!"))),
                    ConditionalClause(column: "Qty", op: .lessOrEqual, value: .column("Price"), output: .value(.string("few")))]
        v = try await apply(.addConditionalColumn(name: "X", clauses: text, otherwise: .column("Region")), on: sales)
        XCTAssertEqual(try tableRows(v).map(\.last), ["Apple", "pear!", "Pear", "0", "South"])
        let nulls = [ConditionalClause(column: "Qty", op: .isNull, value: .value(.null), output: .value(.string("missing"))),
                     ConditionalClause(column: "Qty", op: .equals, value: .value(.int(10)), output: .value(.string("ten"))),
                     ConditionalClause(column: "Region", op: .notEquals, value: .value(.string("South")), output: .value(.string("not south"))),
                     ConditionalClause(column: "Qty", op: .lessThan, value: .value(.int(4)), output: .value(.string("small"))),
                     ConditionalClause(column: "Product", op: .doesNotContain, value: .value(.string("zz")), output: .value(.string("other")))]
        v = try await apply(.addConditionalColumn(name: "X", clauses: nulls, otherwise: .value(.null)), on: sales)
        XCTAssertEqual(try tableRows(v).map(\.last), ["ten", "other", "not south", "missing", "small"])
        v = try await apply(.addConditionalColumn(name: "X", clauses: [ConditionalClause(column: "Qty", op: .isNotNull, value: .value(.null), output: .column("Qty"))],
                                                  otherwise: .value(.int(-1))), on: sales)
        XCTAssertEqual(try tableRows(v).map(\.last), ["10", "5", "7", "-1", "3"])
    }
    func testAddIndexColumn() async throws {
        var v = try await apply(.addIndexColumn(name: "Index", start: 1, increment: 1), on: sales)
        XCTAssertEqual(try tableRows(v).map(\.last), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(v.tableValue?.columnTypes.last, .int64)
        v = try await apply(.addIndexColumn(name: "Index", start: 0, increment: 10), on: sales)
        XCTAssertEqual(try tableRows(v).map(\.last), ["0", "10", "20", "30", "40"])
    }
    func testInvokeCustomFunction() async throws {
        let functions = [("Double", "(x) => x * 2"), ("Add Tax", "(amount as nullable number, rate as number) => amount * (1 + rate)")]
        var v = try await apply(.invokeCustomFunction(name: "R", function: "Double", arguments: [.column("Qty")]), on: sales, others: functions)
        XCTAssertEqual(try tableRows(v).map(\.last), ["20", "10", "14", "null", "6"])
        v = try await apply(.invokeCustomFunction(name: "R", function: "Add Tax", arguments: [.column("Qty"), .value(.double(0.5))]), on: sales, others: functions)
        XCTAssertEqual(try tableRows(v).map(\.last), ["15", "7.5", "10.5", "null", "4.5"])
    }
    func testMergeQueriesJoinKinds() async throws {
        func merged(_ kind: MergeJoinKind) async throws -> [[String]] {
            try tableRows(try await apply([.mergeQueries(other: "Customers", leftKeys: ["Cust"], rightKeys: ["Id"], kind: kind, newColumn: "C", fuzzy: nil),
                                           .expandTableColumn(column: "C", columns: ["Name"], newNames: ["Name"])], on: orders, others: [customers]))
        }
        // null keys match each other, as M's equality says null = null
        let matched = [["1", "A", "Ann"], ["2", "B", "Bob"], ["2", "B", "Bobby"]], nullKey = [["4", "null", "Nobody"]]
        var rows = try await merged(.leftOuter); XCTAssertEqual(rows, matched + [["3", "C", "null"]] + nullKey)
        rows = try await merged(.inner); XCTAssertEqual(rows, matched + nullKey)
        rows = try await merged(.rightOuter); XCTAssertEqual(rows, matched + nullKey + [["null", "null", "Dee"]])
        rows = try await merged(.fullOuter); XCTAssertEqual(rows, matched + [["3", "C", "null"]] + nullKey + [["null", "null", "Dee"]])
        rows = try await merged(.leftAnti); XCTAssertEqual(rows, [["3", "C", "null"]])
        rows = try await merged(.rightAnti); XCTAssertEqual(rows, [["null", "null", "Dee"]])
        XCTAssertEqual(MergeJoinKind.allCases.count, 6)
        // before expanding, each row holds the table of its matches
        let nested = try await apply([.mergeQueries(other: "Customers", leftKeys: ["Cust"], rightKeys: ["Id"], kind: .leftOuter, newColumn: "C", fuzzy: nil),
                                      .addCustomColumn(name: "n", expression: "Table.RowCount([C])", type: nil)], on: orders, others: [customers])
        XCTAssertEqual(try tableRows(nested).map(\.last), ["1", "2", "0", "1"])
        XCTAssertTrue(script([.mergeQueries(other: "My Customers", leftKeys: ["Cust"], rightKeys: ["Id"], kind: .leftAnti, newColumn: "C", fuzzy: nil)], on: orders)
            .contains("Table.NestedJoin(Source, {\"Cust\"}, #\"My Customers\", {\"Id\"}, \"C\", JoinKind.LeftAnti)"))
    }
    func testMergeOnTwoKeysAndAggregate() async throws {
        let left = "#table({\"y\", \"m\", \"v\"}, {{2024, 1, \"a\"}, {2024, 2, \"b\"}, {2023, 1, \"c\"}})"
        let right = ("R", "#table({\"year\", \"month\", \"amount\"}, {{2024, 1, 10}, {2024, 1, 5}, {2023, 1, 7}, {2023, 2, 99}})")
        let merge = Transform.mergeQueries(other: "R", leftKeys: ["y", "m"], rightKeys: ["year", "month"], kind: .leftOuter, newColumn: "R", fuzzy: nil)
        var v = try await apply([merge, .aggregateTableColumn(column: "R", aggregations: [("amount", .sum, "Sum of amount"), ("amount", .countValues, "Count of amount")])],
                                on: left, others: [right])
        XCTAssertEqual(columnNames(v), ["y", "m", "v", "Sum of amount", "Count of amount"])
        XCTAssertEqual(try tableRows(v), [["2024", "1", "a", "15", "2"], ["2024", "2", "b", "null", "0"], ["2023", "1", "c", "7", "1"]])
        v = try await apply([merge, .expandTableColumn(column: "R", columns: ["amount"], newNames: nil)], on: left, others: [right])
        XCTAssertEqual(columnNames(v), ["y", "m", "v", "R.amount"])
        XCTAssertEqual(try tableRows(v).map(\.last), ["10", "5", "null", "7"])
    }
    func testFuzzyMerge() async throws {
        let cities = "#table({\"City\"}, {{\"Seatle\"}, {\"new york\"}, {\"Boston\"}, {\"LA\"}})"
        let reference = [("Cities", "#table({\"Name\", \"Pop\"}, {{\"Seattle\", 1}, {\"New York\", 2}, {\"Austin\", 3}, {\"Los Angeles\", 4}})"),
                         ("Aliases", "#table({\"From\", \"To\"}, {{\"LA\", \"Los Angeles\"}})")]
        func pops(_ options: FuzzyMergeOptions, kind: MergeJoinKind = .leftOuter, on left: String? = nil) async throws -> [String?] {
            let v = try await apply([.mergeQueries(other: "Cities", leftKeys: ["City"], rightKeys: ["Name"], kind: kind, newColumn: "M", fuzzy: options),
                                     .expandTableColumn(column: "M", columns: ["Pop"], newNames: ["Pop"])], on: left ?? cities, others: reference)
            return try tableRows(v).map(\.last)
        }
        // default threshold 0.8: one missing letter in seven (0.857) matches; Boston/Austin (3 of 6 letters differ) does not
        var got = try await pops(FuzzyMergeOptions())
        XCTAssertEqual(got, ["1", "2", "null", "null"])
        // threshold 1 keeps only exact matches, still ignoring case and spaces
        got = try await pops(FuzzyMergeOptions(threshold: 1))
        XCTAssertEqual(got, ["null", "2", "null", "null"])
        var strict = FuzzyMergeOptions(threshold: 1); strict.ignoreCase = false
        got = try await pops(strict)
        XCTAssertEqual(got, ["null", "null", "null", "null"])
        var spaced = FuzzyMergeOptions(threshold: 1); spaced.ignoreSpace = false
        got = try await pops(spaced, on: "#table({\"City\"}, {{\"NEW YORK\"}, {\"NewYork\"}})")
        XCTAssertEqual(got, ["2", "null"])
        got = try await pops(FuzzyMergeOptions(threshold: 1), on: "#table({\"City\"}, {{\"NEW YORK\"}, {\"NewYork\"}})")
        XCTAssertEqual(got, ["2", "2"])
        // a transformation table maps one spelling to another before matching
        var aliased = FuzzyMergeOptions(); aliased.transformationTable = "Aliases"
        got = try await pops(aliased)
        XCTAssertEqual(got, ["1", "2", "null", "4"])
        // threshold 0 matches everything: 4 x 4 rows
        got = try await pops(FuzzyMergeOptions(threshold: 0), kind: .inner)
        XCTAssertEqual(got.count, 16)
        got = try await pops(FuzzyMergeOptions(), kind: .leftAnti)
        XCTAssertEqual(got.count, 2)
        // the best matches come first and can be capped
        let names = [("Cities", "#table({\"Name\", \"Pop\"}, {{\"Bobby\", 3}, {\"Bobb\", 2}, {\"Bob\", 1}, {\"Zed\", 9}})")]
        func capped(_ n: Int?) async throws -> [String?] {
            var o = FuzzyMergeOptions(threshold: 0.6); o.maximumMatches = n
            let v = try await apply([.mergeQueries(other: "Cities", leftKeys: ["City"], rightKeys: ["Name"], kind: .leftOuter, newColumn: "M", fuzzy: o),
                                     .expandTableColumn(column: "M", columns: ["Pop"], newNames: ["Pop"])], on: "#table({\"City\"}, {{\"Bob\"}})", others: names)
            return try tableRows(v).map(\.last)
        }
        got = try await capped(nil); XCTAssertEqual(got, ["1", "2", "3"]) // similarity 1, 0.75, 0.6
        got = try await capped(2); XCTAssertEqual(got, ["1", "2"])
        got = try await capped(1); XCTAssertEqual(got, ["1"])
        XCTAssertTrue(script([.mergeQueries(other: "Cities", leftKeys: ["City"], rightKeys: ["Name"], kind: .leftOuter, newColumn: "M", fuzzy: aliased)], on: cities)
            .contains("Table.FuzzyNestedJoin(Source, {\"City\"}, Cities, {\"Name\"}, \"M\", JoinKind.LeftOuter, [IgnoreCase = true, IgnoreSpace = true, Threshold = 0.8, TransformationTable = Aliases])"))
    }
    func testFuzzySimilarityMeasure() throws {
        XCTAssertEqual(FuzzyMatch.similarity("Seatle", "Seattle"), 1 - 1.0 / 7, accuracy: 1e-12)
        XCTAssertEqual(FuzzyMatch.similarity("Micorsoft", "Microsoft"), 1 - 1.0 / 9, accuracy: 1e-12) // swapped neighbours count once
        XCTAssertEqual(FuzzyMatch.similarity("Boston", "Austin"), 0.5, accuracy: 1e-12)
        XCTAssertEqual(FuzzyMatch.similarity(" New  York", "NEWYORK"), 1)
        XCTAssertEqual(FuzzyMatch.similarity("abc", "xyz"), 0)
        XCTAssertEqual(FuzzyMatch.editDistance(Array("kitten"), Array("sitting")), 3)
        XCTAssertEqual(try m("Table.RowCount(Table.FuzzyJoin(#table({\"a\"}, {{\"Seatle\"}}), {\"a\"}, #table({\"b\"}, {{\"Seattle\"}, {\"Tokyo\"}}), {\"b\"}))").numberValue, 1)
        XCTAssertEqual(try mNum("Table.FuzzyJoin(#table({\"a\"}, {{\"Seatle\"}}), {\"a\"}, #table({\"b\"}, {{\"Seattle\"}}), {\"b\"}, JoinKind.Inner, [SimilarityColumnName = \"s\"]){0}[s]"),
                       1 - 1.0 / 7, accuracy: 1e-12)
        XCTAssertNotNil(mErr("Table.FuzzyNestedJoin(#table({\"a\"}, {}), {\"a\"}, #table({\"b\"}, {}), {\"b\"}, \"m\", JoinKind.LeftOuter, [Threshold = 2])"))
    }
    func testAppendQueries() async throws {
        let others = [("B", "#table({\"b\", \"c\"}, {{\"x\", true}})"), ("C", "#table({\"a\"}, {{9}})")]
        // columns are matched by name; missing ones are null
        try await expect(.appendQueries(["B"]), on: "#table({\"a\", \"b\"}, {{1, \"p\"}, {2, \"q\"}})", others: others, columns: ["a", "b", "c"],
                         rows: [["1", "p", "null"], ["2", "q", "null"], ["null", "x", "true"]])
        try await expect(.appendQueries(["B", "C"]), on: "#table({\"a\", \"b\"}, {{1, \"p\"}})", others: others,
                         rows: [["1", "p", "null"], ["null", "x", "true"], ["9", "null", "null"]])
    }
    func testExpandAndExtractStructuredColumns() async throws {
        let s = "#table({\"id\", \"rec\", \"list\"}, {{1, [a = 1, b = \"x\"], {10, 20}}, {2, [a = 2], {}}, {3, null, null}})"
        try await expect(.expandRecordColumn(column: "rec", fields: ["a", "b"], newNames: nil), on: s, columns: ["id", "rec.a", "rec.b", "list"],
                         rows: [["1", "1", "x", "{10,20}"], ["2", "2", "null", "{}"], ["3", "null", "null", "null"]])
        try await expect(.expandRecordColumn(column: "rec", fields: ["b"], newNames: ["B"]), on: "Table.RemoveColumns(\(s), {\"list\"})", columns: ["id", "B"],
                         rows: [["1", "x"], ["2", "null"], ["3", "null"]])
        // an empty list keeps its row with null
        try await expect(.expandListColumn(column: "list"), on: "Table.RemoveColumns(\(s), {\"rec\"})", rows: [["1", "10"], ["1", "20"], ["2", "null"], ["3", "null"]])
        try await expect(.extractListValues(column: "list", delimiter: "; "), on: "Table.FirstN(Table.RemoveColumns(\(s), {\"rec\"}), 2)", rows: [["1", "10; 20"], ["2", ""]])
        let nested = "#table({\"k\", \"t\"}, {{\"a\", #table({\"x\", \"y\"}, {{1, 2}, {3, 4}})}, {\"b\", #table({\"x\", \"y\"}, {})}, {\"c\", null}})"
        try await expect(.expandTableColumn(column: "t", columns: ["y", "x"], newNames: ["Y", "X"]), on: nested, columns: ["k", "Y", "X"],
                         rows: [["a", "2", "1"], ["a", "4", "3"], ["b", "null", "null"], ["c", "null", "null"]])
        try await expect(.aggregateTableColumn(column: "t", aggregations: [("x", .sum, "Sum x"), ("y", .maximum, "Max y")]), on: nested,
                         columns: ["k", "Sum x", "Max y"], rows: [["a", "4", "4"], ["b", "null", "null"], ["c", "null", "null"]])
        XCTAssertEqual(Transform.expandListColumn(column: "list").stepName, "Expanded list")
        XCTAssertEqual(Transform.aggregateTableColumn(column: "t", aggregations: []).stepName, "Aggregated t")
    }
    func testColumnFromExamples() async throws {
        let table = DataTable(columnNames: ["First", "Last", "Email", "Joined", "Amount"], rows: [
            [.string("john"), .string("smith"), .string("john.smith@example.com"), .date(try MLibrary.makeDate(2024, 8, 15)), .double(12.5)],
            [.string("mary"), .string("jones"), .string("mary.jones@test.org"), .date(try MLibrary.makeDate(2023, 1, 2)), .int(-3)],
        ], types: [.text, .text, .text, .date, .decimal])
        func infer(_ examples: [Int: String], columns: [String]? = nil) -> (String, [Value])? {
            ColumnFromExamples.infer(table: table, examples: examples, columns: columns).map { ($0.expression, $0.values) }
        }
        XCTAssertEqual(infer([0: "JOHN"])?.0, "Text.Upper([First])")
        XCTAssertEqual(infer([0: "JOHN"])?.1, [.string("JOHN"), .string("MARY")])
        XCTAssertEqual(infer([0: "John"])?.0, "Text.Proper([First])")
        XCTAssertEqual(infer([0: "john"])?.0, "[First]")
        XCTAssertEqual(infer([1: "jones"])?.0, "[Last]")
        XCTAssertEqual(infer([0: "john smith"])?.0, "Text.Combine({[First], [Last]}, \" \")")
        XCTAssertEqual(infer([0: "smith, john", 1: "jones, mary"])?.0, "Text.Combine({[Last], [First]}, \", \")")
        XCTAssertEqual(infer([0: "example.com"])?.0, "Text.AfterDelimiter([Email], \"@\")")
        XCTAssertEqual(infer([0: "com", 1: "org"])?.0, "Text.AfterDelimiter([Email], \".\", {0, RelativePosition.FromEnd})")
        XCTAssertEqual(infer([0: "smith"], columns: ["Email"])?.0, "Text.BetweenDelimiters([Email], \".\", \"@\")")
        XCTAssertEqual(infer([0: "smith"], columns: ["Email"])?.1, [.string("smith"), .string("jones")])
        XCTAssertEqual(infer([0: "SMITH"], columns: ["Email"])?.0, "Text.Upper(Text.BetweenDelimiters([Email], \".\", \"@\"))")
        XCTAssertEqual(infer([0: "jo"])?.0, "Text.Start([First], 2)")
        XCTAssertEqual(infer([0: "4"], columns: ["First"])?.0, "Text.Length([First])")
        XCTAssertEqual(infer([0: "2024"])?.0, "Date.Year([Joined])")
        XCTAssertEqual(infer([0: "2024"])?.1, [.int(2024), .int(2023)])
        XCTAssertEqual(infer([0: "August", 1: "January"])?.0, "Date.MonthName([Joined])")
        XCTAssertEqual(infer([1: "Monday"])?.0, "Date.DayOfWeekName([Joined])") // 2 January 2023 was a Monday
        XCTAssertEqual(infer([0: "Q3"])?.0, "\"Q\" & Text.From(Date.QuarterOfYear([Joined]))")
        XCTAssertEqual(infer([0: "25", 1: "-6"])?.0, "[Amount] * 2")
        XCTAssertEqual(infer([1: "3"], columns: ["Amount"])?.0, "Number.Abs([Amount])")
        // a later example can rule a first guess out
        XCTAssertEqual(infer([0: "j"])?.0, "Text.Start([First], 1)")
        XCTAssertEqual(infer([0: "n", 1: "y"])?.0, "Text.End([First], 1)")
        XCTAssertNil(infer([0: "j", 1: "y"])) // first letter of one row, last of the other: no single rule
        XCTAssertNil(infer([0: "zzz"]))
        XCTAssertNil(infer([:]))
        XCTAssertNil(infer([7: "john"]))
        // the inferred expression runs as a step
        let found = try XCTUnwrap(ColumnFromExamples.infer(table: table, examples: [0: "example.com"]))
        XCTAssertEqual(found.description, "Text after \"@\" in Email")
        let v = try await apply(.addColumnFromExamples(name: "Domain", expression: found.expression),
                                on: "#table({\"Email\"}, {{\"a@b.c\"}, {\"no-at-sign\"}, {null}})")
        XCTAssertEqual(try tableRows(v), [["a@b.c", "b.c"], ["no-at-sign", ""], ["null", "null"]])
        XCTAssertEqual(Transform.addColumnFromExamples(name: "x", expression: "1").stepName, "Added Column From Examples")
    }
    func testAIAndScriptStepsFailClearlyWhenUnavailable() async throws {
        func message(_ t: Transform) async -> String {
            do { let v = try await apply(t, on: sales); return (try? tableRows(v).first?.last) ?? "no error" } catch { return MError.wrap(error).description }
        }
        // Without the app's on-device engine (AIInsightsTests covers it installed) every row says why.
        let installed = AIInsights.provider
        AIInsights.provider = nil
        defer { AIInsights.provider = installed }
        let preview = try await engine([("Q", script([.aiSentiment(column: "Product", newColumn: "S")], on: sales))]).evaluatePreview("Q")
        XCTAssertTrue(preview.cellErrors[4]?[0]?.contains("on-device language and image models") ?? false, "\(preview.cellErrors)")
        for t in [Transform.aiKeyPhrases(column: "Product", newColumn: "S"), .aiDetectLanguage(column: "Product", newColumn: "S"), .aiTagImage(column: "Product", newColumn: "S")] {
            let p = try await engine([("Q", script([t], on: sales))]).evaluatePreview("Q")
            XCTAssertEqual(p.cellErrors[4]?.count, 5, t.stepName)
        }
        // scripts are off until the user allows them
        var text = await message(.runPythonScript("dataset = dataset.head(1)"))
        XCTAssertTrue(text.contains("Python scripts are turned off"), text)
        text = await message(.runRScript("dataset <- head(dataset, 1)"))
        XCTAssertTrue(text.contains("R scripts are turned off"), text)
        env.allowScripts = true
        env.pythonPath = "/nonexistent/python3"
        env.rPath = "/nonexistent/Rscript"
        text = await message(.runPythonScript("dataset = dataset.head(1)"))
        XCTAssertTrue(text.contains("/nonexistent/python3"), text)
        text = await message(.runRScript("x <- 1"))
        XCTAssertTrue(text.contains("/nonexistent/Rscript"), text)
        XCTAssertTrue(script([.runPythonScript("x = 1")], on: sales).contains("Python.Execute(\"x = 1\", [dataset = Source]){[Name = \"dataset\"]}[Value]"))
    }
    func testPythonScriptRunsWhenPandasIsInstalled() async throws {
        let python = ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
        let exe = try XCTUnwrap(python, "python3 not found").self
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: exe)
        probe.arguments = ["-c", "import pandas"]
        probe.standardError = FileHandle.nullDevice
        try probe.run(); probe.waitUntilExit()
        try XCTSkipUnless(probe.terminationStatus == 0, "pandas is not installed for \(exe)")
        env.allowScripts = true
        env.pythonPath = exe
        let v = try await apply(.runPythonScript("dataset = dataset[dataset['Qty'] > 5][['Region', 'Qty']]"), on: sales)
        XCTAssertEqual(columnNames(v), ["Region", "Qty"])
        XCTAssertEqual(try tableRows(v), [["North", "10"], ["North", "7"]])
    }
}
