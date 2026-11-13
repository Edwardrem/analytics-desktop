import XCTest
import FacetCore
@testable import FacetQuery

/// Reshape, split/merge, text, number, statistics and date transforms.
final class TransformReshapeTests: TransformTestCase {
    func testPivotColumn() async throws {
        let p = "#table({\"Region\", \"Product\", \"Qty\"}, {{\"North\", \"Apple\", 10}, {\"South\", \"Pear\", 5}, {\"North\", \"Pear\", 7}, {\"North\", \"Apple\", 2}, {\"East\", \"Apple\", null}})"
        // one row per remaining key, one column per distinct product; a missing combination aggregates an empty list
        try await expect(.pivotColumn(column: "Product", valueColumn: "Qty", aggregation: .sum), on: p, columns: ["Region", "Apple", "Pear"],
                         rows: [["East", "null", "null"], ["North", "12", "7"], ["South", "null", "5"]])
        try await expect(.pivotColumn(column: "Product", valueColumn: "Qty", aggregation: .countValues), on: p,
                         rows: [["East", "0", "0"], ["North", "2", "1"], ["South", "0", "1"]])
        try await expect(.pivotColumn(column: "Product", valueColumn: "Qty", aggregation: .maximum), on: p,
                         rows: [["East", "null", "null"], ["North", "10", "7"], ["South", "null", "5"]])
        try await expect(.pivotColumn(column: "Product", valueColumn: "Qty", aggregation: .average), on: p,
                         rows: [["East", "null", "null"], ["North", "6", "7"], ["South", "null", "5"]])
        // "don't aggregate": two values for North/Apple is an error in that cell only
        try await expect(.pivotColumn(column: "Product", valueColumn: "Qty", aggregation: nil), on: p,
                         rows: [["East", "null", "null"], ["North", "<error>", "7"], ["South", "null", "5"]])
        XCTAssertTrue(script([.pivotColumn(column: "Product", valueColumn: "Qty", aggregation: .sum)], on: p)
            .contains("Table.Pivot(Source, List.Distinct(Source[Product]), \"Product\", \"Qty\", List.Sum)"))
    }
    func testUnpivot() async throws {
        let u = "#table({\"Id\", \"Jan\", \"Feb\"}, {{1, 10, null}, {2, 30, 40}})"
        let expected = [["1", "Jan", "10"], ["2", "Jan", "30"], ["2", "Feb", "40"]] // null cells are dropped
        try await expect(.unpivotColumns(["Jan", "Feb"]), on: u, columns: ["Id", "Attribute", "Value"], rows: expected)
        try await expect(.unpivotOtherColumns(keeping: ["Id"]), on: u, columns: ["Id", "Attribute", "Value"], rows: expected)
        try await expect(.unpivotColumns(["Feb"]), on: u, columns: ["Id", "Jan", "Attribute", "Value"], rows: [["2", "30", "Feb", "40"]])
        // unpivot then pivot restores the table (with the null back)
        let round = try await apply([.unpivotOtherColumns(keeping: ["Id"]), .pivotColumn(column: "Attribute", valueColumn: "Value", aggregation: nil)], on: u)
        XCTAssertEqual(try tableRows(round), [["1", "10", "null"], ["2", "30", "40"]])
    }
    func testTransposeAndCountRows() async throws {
        try await expect(.transpose, on: "#table({\"a\", \"b\"}, {{1, 2}, {3, 4}, {5, 6}})", columns: ["Column1", "Column2", "Column3"],
                         rows: [["1", "3", "5"], ["2", "4", "6"]])
        let n = try await apply(.countRows, on: sales)
        XCTAssertEqual(n.numberValue, 5)
        XCTAssertEqual(Transform.countRows.stepName, "Counted Rows")
    }
    func testGroupBy() async throws {
        let aggregations: [(name: String, aggregation: GroupAggregation)] = [
            ("Total", .sum(column: "Qty")), ("AvgPrice", .average(column: "Price")), ("Rows", .countRows), ("Median", .median(column: "Qty")),
            ("Min", .min(column: "Qty")), ("Max", .max(column: "Qty")), ("Products", .countDistinct(column: "Product")),
        ]
        // groups appear in the order their key first occurs; aggregates ignore nulls
        try await expect(.groupBy(keys: ["Region"], aggregations: aggregations), on: sales,
                         columns: ["Region", "Total", "AvgPrice", "Rows", "Median", "Min", "Max", "Products"],
                         rows: [["North", "17", "1.75", "2", "8.5", "7", "10", "2"], ["South", "8", "1.75", "2", "4", "3", "5", "2"],
                                ["East", "null", "1.5", "1", "null", "null", "null", "1"]])
        var v = try await apply(.groupBy(keys: ["Region"], aggregations: [("SD", .standardDeviation(column: "Qty"))]), on: sales)
        let sd = try XCTUnwrap(v.tableValue).column("SD").map { $0.numberValue }
        XCTAssertEqual(try XCTUnwrap(sd[0]), 4.5.squareRoot(), accuracy: 1e-12) // {10, 7}: sample variance 4.5
        XCTAssertEqual(try XCTUnwrap(sd[1]), 2.0.squareRoot(), accuracy: 1e-12) // {5, 3}
        XCTAssertNil(sd[2]) // a single value has no sample deviation
        try await expect(.groupBy(keys: ["Region", "Product"], aggregations: [("Total", .sum(column: "Qty"))]), on: sales,
                         rows: [["North", "Apple", "10"], ["South", "Pear", "5"], ["North", "Pear", "7"], ["East", "Apple", "null"], ["South", "Apple", "3"]])
        let dup = "#table({\"k\", \"v\"}, {{\"a\", 1}, {\"a\", 1}, {\"a\", 2}, {\"b\", 3}})"
        try await expect(.groupBy(keys: ["k"], aggregations: [("Distinct", .countDistinctRows)]), on: dup, rows: [["a", "2"], ["b", "1"]])
        v = try await apply([.groupBy(keys: ["k"], aggregations: [("All", .allRows)]), .addCustomColumn(name: "n", expression: "Table.RowCount([All])", type: .integer)], on: dup)
        XCTAssertEqual(try tableRows(v), [["a", "<table>", "3"], ["b", "<table>", "1"]])
        v = try await apply(.groupBy(keys: ["Region"], aggregations: [("Total", .sum(column: "Qty")), ("Rows", .countRows)]), on: sales)
        XCTAssertEqual(v.tableValue?.columnTypes, [.text, .nullable(.plainNumber), .int64])
    }
    func testSplitByDelimiter() async throws {
        let s = "#table({\"Name\", \"Code\"}, {{\"Ann Lee Smith\", \"AB-12\"}, {\"Bob\", \"cd34\"}, {null, \"x\"}})"
        try await expect(.splitByDelimiter(column: "Name", delimiter: " ", at: .each, into: .columns(3)), on: s,
                         columns: ["Name.1", "Name.2", "Name.3", "Code"],
                         rows: [["Ann", "Lee", "Smith", "AB-12"], ["Bob", "null", "null", "cd34"], ["null", "null", "null", "x"]])
        try await expect(.splitByDelimiter(column: "Name", delimiter: " ", at: .each, into: .columns(2)), on: s,
                         rows: [["Ann", "Lee", "AB-12"], ["Bob", "null", "cd34"], ["null", "null", "x"]]) // extra parts are dropped
        try await expect(.splitByDelimiter(column: "Name", delimiter: " ", at: .leftmost, into: .columns(2)), on: s,
                         rows: [["Ann", "Lee Smith", "AB-12"], ["Bob", "null", "cd34"], ["null", "null", "x"]])
        try await expect(.splitByDelimiter(column: "Name", delimiter: " ", at: .rightmost, into: .columns(2)), on: s,
                         rows: [["Ann Lee", "Smith", "AB-12"], ["Bob", "null", "cd34"], ["null", "null", "x"]])
        try await expect(.splitByDelimiter(column: "Name", delimiter: " ", at: .each, into: .rows), on: s, columns: ["Name", "Code"],
                         rows: [["Ann", "AB-12"], ["Lee", "AB-12"], ["Smith", "AB-12"], ["Bob", "cd34"], ["null", "x"]])
        // a quoted delimiter is not a split point
        try await expect(.splitByDelimiter(column: "t", delimiter: ",", at: .each, into: .columns(2)), on: "#table({\"t\"}, {{\"\"\"a,b\"\",c\"}})",
                         rows: [["a,b", "c"]])
    }
    func testSplitByLengthPositionsAndTransition() async throws {
        let s = "#table({\"Code\"}, {{\"AB-12\"}, {\"cd34\"}, {\"x\"}})"
        try await expect(.splitByLength(column: "Code", length: 2, repeated: false, into: .columns(2)), on: s, columns: ["Code.1", "Code.2"],
                         rows: [["AB", "-12"], ["cd", "34"], ["x", ""]])
        try await expect(.splitByLength(column: "Code", length: 2, repeated: true, into: .columns(3)), on: s,
                         rows: [["AB", "-1", "2"], ["cd", "34", "null"], ["x", "null", "null"]])
        try await expect(.splitByLength(column: "Code", length: 2, repeated: true, into: .rows), on: s, rows: [["AB"], ["-1"], ["2"], ["cd"], ["34"], ["x"]])
        try await expect(.splitByPositions(column: "Code", positions: [0, 1, 3], into: .columns(3)), on: s,
                         rows: [["A", "B-", "12"], ["c", "d3", "4"], ["x", "", ""]])
        func transition(_ kind: CharacterTransition, _ text: String, _ parts: [String], line: UInt = #line) async throws {
            try await expect(.splitByTransition(column: "t", kind, into: .columns(parts.count)), on: "#table({\"t\"}, {{\"\(text)\"}})", rows: [parts], line: line)
        }
        try await transition(.lowerToUpper, "camelCaseText", ["camel", "Case", "Text"])
        try await transition(.upperToLower, "ABcd", ["AB", "cd"])
        try await transition(.digitToNonDigit, "12ab34", ["12", "ab34"])
        try await transition(.nonDigitToDigit, "ab12cd3", ["ab", "12cd", "3"])
    }
    func testMergeColumns() async throws {
        try await expect(.mergeColumns(["Region", "Product"], separator: "-", newName: "Key"), on: sales, columns: ["Key", "Qty", "Price"],
                         rows: [["North-Apple", "10", "1.5"], ["South-Pear", "5", "2"], ["North-Pear", "7", "2"], ["East-Apple", "null", "1.5"], ["South-Apple", "3", "1.5"]])
        // numbers are converted to text; a null contributes nothing but its separator stays
        try await expect(.mergeColumns(["Product", "Qty"], separator: " x ", newName: "Line"), on: sales, columns: ["Region", "Line", "Price"],
                         rows: [["North", "Apple x 10", "1.5"], ["South", "Pear x 5", "2"], ["North", "Pear x 7", "2"], ["East", "Apple x ", "1.5"], ["South", "Apple x 3", "1.5"]])
    }
    func testFormatTextPrefixSuffix() async throws {
        let t = "#table({\"t\"}, {{\"  hello WORLD  \"}, {null}})"
        try await expect(.formatText(columns: ["t"], .lowercase), on: t, rows: [["  hello world  "], ["null"]])
        try await expect(.formatText(columns: ["t"], .uppercase), on: t, rows: [["  HELLO WORLD  "], ["null"]])
        try await expect(.formatText(columns: ["t"], .capitalizeEachWord), on: t, rows: [["  Hello World  "], ["null"]])
        try await expect(.formatText(columns: ["t"], .trim), on: t, rows: [["hello WORLD"], ["null"]])
        try await expect(.formatText(columns: ["t"], .clean), on: "#table({\"t\"}, {{\"a#(lf)b#(tab)c\"}})", rows: [["abc"]])
        let q = "Table.SelectColumns(\(sales), {\"Qty\", \"Product\"})"
        try await expect(.addPrefix(columns: ["Qty", "Product"], "#"), on: q, rows: [["#10", "#Apple"], ["#5", "#Pear"], ["#7", "#Pear"], ["null", "#Apple"], ["#3", "#Apple"]])
        try await expect(.addSuffix(columns: ["Qty"], " pcs"), on: q, rows: [["10 pcs", "Apple"], ["5 pcs", "Pear"], ["7 pcs", "Pear"], ["null", "Apple"], ["3 pcs", "Apple"]])
        XCTAssertEqual(Transform.formatText(columns: ["t"], .capitalizeEachWord).stepName, "Capitalized Each Word")
    }
    func testExtractText() async throws {
        let e = "#table({\"Email\"}, {{\"john.smith@example.com\"}})"
        func extract(_ kind: TextExtract, _ expected: String, line: UInt = #line) async throws {
            let inPlace = try await cell(.extractText(column: "Email", kind, newColumn: nil), on: e)
            XCTAssertEqual(inPlace, expected, line: line)
            try await expect(.extractText(column: "Email", kind, newColumn: "X"), on: e, columns: ["Email", "X"], rows: [["john.smith@example.com", expected]], line: line)
        }
        try await extract(.length, "22")
        try await extract(.firstCharacters(4), "john")
        try await extract(.lastCharacters(3), "com")
        try await extract(.range(start: 5, count: 5), "smith")
        try await extract(.beforeDelimiter("@"), "john.smith")
        try await extract(.afterDelimiter("@"), "example.com")
        try await extract(.betweenDelimiters(".", "@"), "smith")
        XCTAssertEqual(Transform.extractText(column: "Email", .length, newColumn: nil).stepName, "Extracted Text Length")
        XCTAssertEqual(Transform.extractText(column: "Email", .length, newColumn: "X").stepName, "Inserted Text Length")
    }
    func testParseJsonAndXml() async throws {
        var v = try await apply([.parse(column: "j", .json), .expandRecordColumn(column: "j", fields: ["a", "b"], newNames: nil)],
                                on: "#table({\"j\"}, {{\"{\"\"a\"\":1,\"\"b\"\":[true]}\"}, {\"{\"\"a\"\":2}\"}})")
        XCTAssertEqual(columnNames(v), ["j.a", "j.b"])
        XCTAssertEqual(try tableRows(v), [["1", "{true}"], ["2", "null"]])
        v = try await apply([.parse(column: "x", .xml), .expandTableColumn(column: "x", columns: ["Name"], newNames: ["Element"])],
                            on: "#table({\"x\"}, {{\"<r><i>1</i><j>2</j></r>\"}})")
        XCTAssertEqual(try tableRows(v), [["i"], ["j"]])
        v = try await apply(.parse(column: "j", .json), on: "#table({\"j\"}, {{\"{oops\"}})")
        XCTAssertEqual(try tableRows(v), [["<error>"]]) // malformed text is a cell error, not a failed query
    }
    func testNumberOperations() async throws {
        let cases: [(NumberOperation, String, String)] = [
            (.add(2), "5", "7"), (.subtract(2), "5", "3"), (.multiply(3), "5", "15"), (.divide(2), "5", "2.5"), (.integerDivide(2), "5", "2"),
            (.integerDivide(2), "-5", "-2"), (.modulo(3), "5", "2"), (.percentage(10), "50", "5"), (.percentOf(200), "50", "25"),
            (.absolute, "-5", "5"), (.power(2), "5", "25"), (.squareRoot, "16", "4"), (.exponent, "0", "1"), (.log10, "100", "2"),
            (.naturalLog, "1", "0"), (.factorial, "5", "120"), (.sine, "0", "0"), (.cosine, "0", "1"), (.tangent, "0", "0"),
            (.arcsine, "0", "0"), (.arccosine, "1", "0"), (.arctangent, "0", "0"), (.round(digits: 1), "2.25", "2.2"), (.round(digits: 0), "3.5", "4"),
            (.roundUp, "2.1", "3"), (.roundDown, "2.9", "2"), (.isEven, "4", "true"), (.isOdd, "4", "false"), (.sign, "-3", "-1"), (.sign, "0", "0"),
            (.add(2), "null", "null"), (.squareRoot, "null", "null"),
        ]
        for (op, input, expected) in cases {
            let got = try await cell(.number(columns: ["N"], op, newColumn: nil), on: "#table({\"N\"}, {{\(input)}})")
            XCTAssertEqual(got, expected, "\(op) of \(input)")
        }
        // as a new column the source column stays; several columns can be transformed in place at once
        try await expect(.number(columns: ["Qty"], .multiply(2), newColumn: "Double"), on: "Table.SelectColumns(\(sales), {\"Qty\"})",
                         columns: ["Qty", "Double"], rows: [["10", "20"], ["5", "10"], ["7", "14"], ["null", "null"], ["3", "6"]])
        try await expect(.number(columns: ["Qty", "Price"], .multiply(10), newColumn: nil), on: "Table.SelectColumns(\(sales), {\"Qty\", \"Price\"})",
                         rows: [["100", "15"], ["50", "20"], ["70", "20"], ["null", "15"], ["30", "15"]])
        let v = try await apply(.number(columns: ["Qty"], .isEven, newColumn: "Even"), on: sales)
        XCTAssertEqual(v.tableValue?.columnTypes.last, .logical)
        XCTAssertEqual(Transform.number(columns: ["Qty"], .squareRoot, newColumn: nil).stepName, "Calculated Square Root")
        XCTAssertEqual(Transform.number(columns: ["Qty"], .squareRoot, newColumn: "x").stepName, "Inserted Square Root")
    }
    func testStatistics() async throws {
        // Qty is 10, 5, 7, null, 3
        func stat(_ s: ColumnStatistic, _ column: String = "Qty") async throws -> MValue { try await apply(.statistic(column: column, s), on: sales) }
        var v = try await stat(.sum); XCTAssertEqual(v.numberValue, 25)
        v = try await stat(.minimum); XCTAssertEqual(v.numberValue, 3)
        v = try await stat(.maximum); XCTAssertEqual(v.numberValue, 10)
        v = try await stat(.median); XCTAssertEqual(v.numberValue, 6) // middle of 3, 5, 7, 10
        v = try await stat(.average); XCTAssertEqual(v.numberValue, 6.25)
        v = try await stat(.standardDeviation); XCTAssertEqual(try XCTUnwrap(v.numberValue), (26.75 / 3).squareRoot(), accuracy: 1e-12)
        v = try await stat(.countValues); XCTAssertEqual(v.numberValue, 4)
        v = try await stat(.countDistinctValues); XCTAssertEqual(v.numberValue, 5) // null counts as a distinct value
        v = try await stat(.countDistinctValues, "Product"); XCTAssertEqual(v.numberValue, 2)
        v = try await stat(.maximum, "Region"); XCTAssertEqual(v.textValue, "South")
    }
    func testDateOperations() async throws {
        env.timeZone = TimeZone(identifier: "UTC") ?? .current
        env.now = { Date(timeIntervalSince1970: 1_724_112_000) } // 20 August 2024 00:00 UTC
        // Thursday 15 August 2024
        let d = "#table(type table [Day = date, When = datetime, Span = duration], {{#date(2024, 8, 15), #datetime(2024, 8, 15, 10, 30, 45), #duration(2, 5, 30, 15)}})"
        let cases: [(DateOperation, String, String)] = [
            (.age, "Day", "#duration(5, 0, 0, 0)"), (.dateOnly, "When", "#date(2024, 8, 15)"), (.timeOnly, "When", "#time(10, 30, 45)"),
            (.year, "Day", "2024"), (.startOfYear, "Day", "#date(2024, 1, 1)"), (.endOfYear, "Day", "#date(2024, 12, 31)"),
            (.quarter, "Day", "3"), (.startOfQuarter, "Day", "#date(2024, 7, 1)"), (.endOfQuarter, "Day", "#date(2024, 9, 30)"),
            (.month, "Day", "8"), (.monthName, "Day", "August"), (.startOfMonth, "Day", "#date(2024, 8, 1)"), (.endOfMonth, "Day", "#date(2024, 8, 31)"),
            (.daysInMonth, "Day", "31"), (.weekOfYear, "Day", "33"), (.weekOfMonth, "Day", "3"),
            (.startOfWeek, "Day", "#date(2024, 8, 11)"), (.endOfWeek, "Day", "#date(2024, 8, 17)"),
            (.day, "Day", "15"), (.dayOfWeek, "Day", "4"), (.dayOfYear, "Day", "228"), (.dayName, "Day", "Thursday"),
            (.startOfDay, "When", "#datetime(2024, 8, 15, 0, 0, 0)"), (.endOfDay, "Day", "#date(2024, 8, 15)"),
            (.hour, "When", "10"), (.minute, "When", "30"), (.second, "When", "45"), (.startOfHour, "When", "#datetime(2024, 8, 15, 10, 0, 0)"),
            (.durationDays, "Span", "2"), (.durationHours, "Span", "5"), (.durationMinutes, "Span", "30"), (.durationSeconds, "Span", "15"),
            (.totalMinutes, "Span", "3210.25"), (.totalSeconds, "Span", "192615"),
        ]
        for (op, column, expected) in cases {
            let got = try await cell(.date(columns: [column], op, newColumn: "X"), on: d)
            XCTAssertEqual(got, expected, "\(op)")
        }
        // 2 days 5:30:15 is 192615 seconds
        var v = try await apply(.date(columns: ["Span"], .totalDays, newColumn: "X"), on: d)
        XCTAssertEqual(try XCTUnwrap(try v.tableValue?.column("X")[0].numberValue), 192615.0 / 86400, accuracy: 1e-12)
        v = try await apply(.date(columns: ["Span"], .totalHours, newColumn: "X"), on: d)
        XCTAssertEqual(try XCTUnwrap(try v.tableValue?.column("X")[0].numberValue), 192615.0 / 3600, accuracy: 1e-12)
        // the end of the hour is its last instant
        v = try await apply([.date(columns: ["When"], .endOfHour, newColumn: "X"),
                             .addCustomColumn(name: "Check", expression: "{Time.Hour([X]), Time.Minute([X]), [X] < #datetime(2024, 8, 15, 11, 0, 0)}", type: nil)], on: d)
        XCTAssertEqual(show(try XCTUnwrap(try v.tableValue?.column("Check")[0])), "{10,59,true}")
        // in place the column is replaced and retyped
        v = try await apply(.date(columns: ["Day"], .year, newColumn: nil), on: d)
        XCTAssertEqual(try tableRows(v).first?.first, "2024")
        XCTAssertEqual(v.tableValue?.columnTypes.first, .int64)
        XCTAssertEqual(Transform.date(columns: ["Day"], .startOfMonth, newColumn: nil).stepName, "Calculated Start Of Month")
        XCTAssertEqual(Transform.date(columns: ["Day"], .dayOfWeek, newColumn: "X").stepName, "Inserted Day Of Week")
        XCTAssertEqual(DateOperation.allCases.count, cases.count + 3) // totalDays, totalHours and endOfHour are checked separately above
    }
    func testEarliestAndLatest() async throws {
        let d = "#table(type table [D = date], {{#date(2024, 3, 1)}, {null}, {#date(2023, 12, 31)}, {#date(2024, 8, 15)}})"
        var v = try await apply(.earliest(column: "D"), on: d)
        XCTAssertEqual(show(v), "#date(2023, 12, 31)")
        v = try await apply(.latest(column: "D"), on: d)
        XCTAssertEqual(show(v), "#date(2024, 8, 15)")
    }
}
