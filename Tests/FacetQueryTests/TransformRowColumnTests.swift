import XCTest
import FacetCore
@testable import FacetQuery

/// Row, column, header, fill and replace transforms. Row labels below: r1 North/Apple/10/1.5, r2 South/Pear/5/2,
/// r3 North/Pear/7/2, r4 East/Apple/null/1.5, r5 South/Apple/3/1.5.
final class TransformRowColumnTests: TransformTestCase {
    let r1 = ["North", "Apple", "10", "1.5"], r2 = ["South", "Pear", "5", "2"], r3 = ["North", "Pear", "7", "2"]
    let r4 = ["East", "Apple", "null", "1.5"], r5 = ["South", "Apple", "3", "1.5"]

    func testKeepAndRemoveRowsByPosition() async throws {
        try await expect(.keepTopRows(2), on: sales, rows: [r1, r2])
        try await expect(.keepBottomRows(2), on: sales, rows: [r4, r5])
        try await expect(.keepTopRows(99), on: sales, rows: [r1, r2, r3, r4, r5])
        // the dialogs count rows from 1: "first row 2, number of rows 2" keeps rows 2 and 3
        try await expect(.keepRangeOfRows(first: 2, count: 2), on: sales, rows: [r2, r3])
        XCTAssertTrue(script([.keepRangeOfRows(first: 2, count: 2)], on: sales).contains("#\"Kept Range of Rows\" = Table.Range(Source, 1, 2)"))
        try await expect(.removeTopRows(1), on: sales, rows: [r2, r3, r4, r5])
        try await expect(.removeBottomRows(2), on: sales, rows: [r1, r2, r3])
        // first row to remove 2, remove 1, keep 2: row 1 stays, 2 goes, 3-4 stay, 5 goes
        try await expect(.removeAlternateRows(firstToRemove: 2, numberToRemove: 1, numberToKeep: 2), on: sales, rows: [r1, r3, r4])
        try await expect(.removeAlternateRows(firstToRemove: 1, numberToRemove: 1, numberToKeep: 1), on: sales, rows: [r2, r4])
        try await expect(.reverseRows, on: sales, rows: [r5, r4, r3, r2, r1])
    }
    func testDuplicates() async throws {
        try await expect(.removeDuplicates(columns: ["Region"]), on: sales, rows: [r1, r2, r4]) // first of each region
        try await expect(.removeDuplicates(columns: ["Region", "Product"]), on: sales, rows: [r1, r2, r3, r4, r5])
        try await expect(.removeDuplicates(columns: []), on: "#table({\"a\", \"b\"}, {{1, \"x\"}, {1, \"x\"}, {1, \"y\"}, {null, null}, {null, null}})",
                         rows: [["1", "x"], ["1", "y"], ["null", "null"]])
        // regions that occur more than once keep all their rows, in the original order
        try await expect(.keepDuplicates(columns: ["Region"]), on: sales, columns: ["Region", "Product", "Qty", "Price"], rows: [r1, r2, r3, r5])
        try await expect(.keepDuplicates(columns: []), on: "#table({\"a\"}, {{1}, {2}, {1}, {3}})", rows: [["1"], ["1"]])
    }
    func testBlankAndErrorRows() async throws {
        let blanks = "#table({\"a\", \"b\"}, {{1, \"x\"}, {null, \"\"}, {null, null}, {null, \"y\"}, {\"\", \"\"}})"
        try await expect(.removeBlankRows, on: blanks, rows: [["1", "x"], ["null", "y"]])
        let errors = "Table.TransformColumnTypes(#table({\"a\", \"b\"}, {{\"1\", \"2\"}, {\"x\", \"3\"}, {\"4\", \"y\"}}), {{\"a\", Int64.Type}, {\"b\", Int64.Type}})"
        try await expect(.removeErrors(columns: []), on: errors, rows: [["1", "2"]])
        try await expect(.removeErrors(columns: ["a"]), on: errors, rows: [["1", "2"], ["4", "<error>"]])
        try await expect(.keepErrors(columns: []), on: errors, rows: [["<error>", "3"], ["4", "<error>"]])
        try await expect(.keepErrors(columns: ["b"]), on: errors, rows: [["4", "<error>"]])
        try await expect(.replaceErrors(columns: ["a", "b"], with: .int(0)), on: errors, rows: [["1", "2"], ["0", "3"], ["4", "0"]])
    }
    func testFilterRowsComparisons() async throws {
        func filter(_ c: QFilter, _ expected: [[String]], line: UInt = #line) async throws {
            try await expect(.filterRows(c), on: sales, rows: expected, line: line)
        }
        try await filter(.compare(column: "Qty", .greaterThan, .int(5)), [r1, r3])
        try await filter(.compare(column: "Qty", .greaterOrEqual, .int(5)), [r1, r2, r3])
        try await filter(.compare(column: "Qty", .lessThan, .int(5)), [r5]) // the null quantity is not less than 5
        try await filter(.compare(column: "Qty", .lessOrEqual, .int(5)), [r2, r5])
        try await filter(.compare(column: "Region", .equals, .string("North")), [r1, r3])
        try await filter(.compare(column: "Qty", .notEquals, .int(10)), [r2, r3, r4, r5]) // null <> 10 is true in M
        try await filter(.isNull(column: "Qty"), [r4])
        try await filter(.isNotNull(column: "Qty"), [r1, r2, r3, r5])
        try await filter(.between(column: "Qty", .int(5), .int(7)), [r2, r3])
        try await filter(.inList(column: "Region", [.string("East"), .string("South")]), [r2, r4, r5])
        try await filter(.text(column: "Product", .beginsWith, "Ap"), [r1, r4, r5])
        try await filter(.text(column: "Product", .doesNotBeginWith, "Ap"), [r2, r3])
        try await filter(.text(column: "Region", .endsWith, "th"), [r1, r2, r3, r5])
        try await filter(.text(column: "Region", .doesNotEndWith, "th"), [r4])
        try await filter(.text(column: "Region", .contains, "ou"), [r2, r5])
        try await filter(.text(column: "Region", .contains, "OU"), [])
        try await filter(.text(column: "Region", .contains, "OU", ignoreCase: true), [r2, r5])
        try await filter(.text(column: "Region", .doesNotContain, "or"), [r2, r4, r5])
        try await filter(.and([.compare(column: "Region", .equals, .string("North")), .compare(column: "Qty", .greaterThan, .int(7))]), [r1])
        try await filter(.or([.compare(column: "Region", .equals, .string("East")), .compare(column: "Qty", .equals, .int(3))]), [r4, r5])
        try await filter(.not(.compare(column: "Product", .equals, .string("Apple"))), [r2, r3])
        try await filter(.and([]), [r1, r2, r3, r4, r5])
        try await filter(.or([]), [])
        try await filter(.custom("[Qty] * [Price] > 12"), [r1, r3]) // 15, 10, 14, null, 4.5
        let blanks = "#table({\"t\"}, {{\"a\"}, {\"\"}, {null}})"
        try await expect(.filterRows(.isBlank(column: "t")), on: blanks, rows: [[""], ["null"]])
        try await expect(.filterRows(.isNotBlank(column: "t")), on: blanks, rows: [["a"]])
    }
    func testFilterRowsByDate() async throws {
        env.timeZone = TimeZone(identifier: "UTC") ?? .current
        env.now = { Date(timeIntervalSince1970: 1_723_717_800) } // Thursday 15 August 2024, 10:30 UTC
        let days = "#table(type table [D = date], {{#date(2023, 12, 31)}, {#date(2024, 7, 31)}, {#date(2024, 8, 12)}, {#date(2024, 8, 15)}, {#date(2024, 8, 16)}, {#date(2024, 9, 1)}})"
        func d(_ y: Int, _ m: Int, _ d: Int) -> [String] { ["#date(\(y), \(m), \(d))"] }
        func filter(_ r: QFilter.RelativeDate, _ expected: [[String]], line: UInt = #line) async throws {
            try await expect(.filterRows(.date(column: "D", r)), on: days, rows: expected, line: line)
        }
        try await filter(.inCurrent(.day), [d(2024, 8, 15)])
        try await filter(.inPrevious(.month), [d(2024, 7, 31)])
        try await filter(.inNext(.day), [d(2024, 8, 16)])
        try await filter(.inCurrent(.week), [d(2024, 8, 12), d(2024, 8, 15), d(2024, 8, 16)]) // Sunday 11th to Saturday 17th
        try await filter(.inCurrent(.quarter), [d(2024, 7, 31), d(2024, 8, 12), d(2024, 8, 15), d(2024, 8, 16), d(2024, 9, 1)])
        try await filter(.inPrevious(.year), [d(2023, 12, 31)])
        try await filter(.inPreviousN(3, .day), [d(2024, 8, 12)]) // the 12th, 13th and 14th
        try await filter(.inNextN(1, .month), [d(2024, 9, 1)])
        try await filter(.yearToDate, [d(2024, 7, 31), d(2024, 8, 12), d(2024, 8, 15)])
        try await filter(.isEarliest, [d(2023, 12, 31)])
        try await filter(.isLatest, [d(2024, 9, 1)])
        try await filter(.isNotEarliest, [d(2024, 7, 31), d(2024, 8, 12), d(2024, 8, 15), d(2024, 8, 16), d(2024, 9, 1)])
        try await filter(.isNotLatest, [d(2023, 12, 31), d(2024, 7, 31), d(2024, 8, 12), d(2024, 8, 15), d(2024, 8, 16)])
        try await filter(.year(2023), [d(2023, 12, 31)])
        try await filter(.quarter(4), [d(2023, 12, 31)])
        try await filter(.month(8), [d(2024, 8, 12), d(2024, 8, 15), d(2024, 8, 16)])
        try await filter(.day(31), [d(2023, 12, 31), d(2024, 7, 31)])
        try await expect(.filterRows(.compare(column: "D", .greaterThan, .date(try MLibrary.makeDate(2024, 8, 15)), type: .date)), on: days,
                         rows: [d(2024, 8, 16), d(2024, 9, 1)])
        try await expect(.filterRows(.between(column: "D", .date(try MLibrary.makeDate(2024, 8, 12)), .date(try MLibrary.makeDate(2024, 8, 15)), type: .date)),
                         on: days, rows: [d(2024, 8, 12), d(2024, 8, 15)])
    }
    func testSortRows() async throws {
        // nulls sort first ascending; ties keep their order
        try await expect(.sortRows([("Qty", false)]), on: sales, rows: [r4, r5, r2, r3, r1])
        try await expect(.sortRows([("Qty", true)]), on: sales, rows: [r1, r3, r2, r5, r4])
        try await expect(.sortRows([("Region", false), ("Qty", true)]), on: sales, rows: [r4, r1, r3, r2, r5])
        try await expect(.sortRows([("Product", false)]), on: sales, rows: [r1, r4, r5, r2, r3])
    }
    func testChooseRemoveReorderRenameDuplicateColumns() async throws {
        try await expect(.chooseColumns(["Price", "Region"]), on: sales, columns: ["Price", "Region"], rows: [["1.5", "North"], ["2", "South"], ["2", "North"], ["1.5", "East"], ["1.5", "South"]])
        try await expect(.removeOtherColumns(keeping: ["Qty"]), on: sales, columns: ["Qty"], rows: [["10"], ["5"], ["7"], ["null"], ["3"]])
        try await expect(.removeColumns(["Product", "Price"]), on: sales, columns: ["Region", "Qty"], rows: [["North", "10"], ["South", "5"], ["North", "7"], ["East", "null"], ["South", "3"]])
        var v = try await apply(.reorderColumns(["Price", "Qty", "Product", "Region"]), on: sales)
        XCTAssertEqual(columnNames(v), ["Price", "Qty", "Product", "Region"])
        XCTAssertEqual(try tableRows(v).first, ["1.5", "10", "Apple", "North"])
        v = try await apply(.reorderColumns(["Price", "Region"]), on: sales) // unlisted columns keep their place
        XCTAssertEqual(columnNames(v), ["Price", "Product", "Qty", "Region"])
        v = try await apply(.renameColumns([("Qty", "Quantity"), ("Region", "Area")]), on: sales)
        XCTAssertEqual(columnNames(v), ["Area", "Product", "Quantity", "Price"])
        XCTAssertEqual(v.tableValue?.columnTypes, [.text, .text, .int64, .plainNumber])
        v = try await apply(.duplicateColumn("Qty", newName: "Qty - Copy"), on: sales)
        XCTAssertEqual(columnNames(v), ["Region", "Product", "Qty", "Price", "Qty - Copy"])
        XCTAssertEqual(v.tableValue?.columnTypes.last, .int64)
        XCTAssertEqual(try tableRows(v).map(\.last), ["10", "5", "7", "null", "3"])
        // a missing or clashing column is an error naming it
        for bad in [Transform.removeColumns(["Nope"]), .chooseColumns(["Nope"]), .renameColumns([("Nope", "x")]), .renameColumns([("Qty", "Price")])] {
            do { _ = try await apply(bad, on: sales); XCTFail("expected an error") } catch {
                let message = MError.wrap(error).message
                XCTAssertTrue(message.contains("Nope") || message.contains("Price"), message)
            }
        }
    }
    func testChangeType() async throws {
        let raw = "#table({\"n\", \"d\", \"f\", \"t\"}, {{\"12\", \"2024-03-05\", \"true\", 5}, {\"2.5\", \"\", \"no\", null}, {\"abc\", \"05/03/2024\", \"FALSE\", 1.5}})"
        var v = try await apply(.changeType([("n", .decimal), ("d", .date), ("f", .boolean), ("t", .text)], culture: nil), on: raw)
        XCTAssertEqual(v.tableValue?.columnTypes, [.plainNumber, .date, .logical, .text])
        XCTAssertEqual(try tableRows(v), [["12", "#date(2024, 3, 5)", "true", "5"], ["2.5", "null", "<error>", "null"], ["<error>", "#date(2024, 5, 3)", "false", "1.5"]])
        // with a locale: day first, decimal comma
        v = try await apply(.changeType([("d", .date)], culture: "en-GB"), on: raw)
        XCTAssertEqual(try tableRows(v).map { $0[1] }, ["#date(2024, 3, 5)", "null", "#date(2024, 3, 5)"])
        v = try await apply(.changeType([("n", .decimal)], culture: "fr-FR"), on: "#table({\"n\"}, {{\"1 234,5\"}, {\"0,25\"}})")
        XCTAssertEqual(try tableRows(v), [["1234.5"], ["0.25"]])
        v = try await apply(.changeType([("n", .integer)], culture: nil), on: "#table({\"n\"}, {{\"7\"}, {2.5}, {3.5}, {\"-1.2\"}})")
        XCTAssertEqual(try tableRows(v), [["7"], ["2"], ["4"], ["-1"]]) // whole numbers round half to even
        XCTAssertEqual(Transform.changeType([("n", .integer)], culture: nil).stepName, "Changed Type")
        XCTAssertEqual(Transform.changeType([("n", .integer)], culture: "de-DE").stepName, "Changed Type with Locale")
        XCTAssertTrue(script([.changeType([("n", .integer), ("d", .dateTime)], culture: "de-DE")], on: raw)
            .contains("Table.TransformColumnTypes(Source, {{\"n\", Int64.Type}, {\"d\", type datetime}}, \"de-DE\")"))
    }
    func testPromoteAndDemoteHeaders() async throws {
        let raw = "#table({\"Column1\", \"Column2\", \"Column3\", \"Column4\"}, {{\"Name\", 2024, null, \"Name\"}, {\"Ann\", 1, 2, 3}})"
        try await expect(.promoteHeaders, on: raw, columns: ["Name", "2024", "Column3", "Name_1"], rows: [["Ann", "1", "2", "3"]])
        try await expect(.demoteHeaders, on: sales, columns: ["Column1", "Column2", "Column3", "Column4"],
                         rows: [["Region", "Product", "Qty", "Price"], r1, r2, r3, r4, r5])
        // promote then demote restores the header row
        let v = try await apply([.promoteHeaders, .demoteHeaders], on: "#table({\"Column1\", \"Column2\"}, {{\"a\", \"b\"}, {1, 2}})")
        XCTAssertEqual(try tableRows(v), [["a", "b"], ["1", "2"]])
    }
    func testFillDownAndUp() async throws {
        let gaps = "#table({\"g\", \"v\"}, {{null, 1}, {\"a\", 2}, {null, 3}, {\"\", 4}, {null, 5}, {\"b\", 6}, {null, 7}})"
        // only nulls are filled; an empty text is a value
        try await expect(.fillDown(["g"]), on: gaps, rows: [["null", "1"], ["a", "2"], ["a", "3"], ["", "4"], ["", "5"], ["b", "6"], ["b", "7"]])
        try await expect(.fillUp(["g"]), on: gaps, rows: [["a", "1"], ["a", "2"], ["", "3"], ["", "4"], ["b", "5"], ["b", "6"], ["null", "7"]])
    }
    func testReplaceValues() async throws {
        // text replacement inside the cell
        try await expect(.replaceValues(columns: ["Region"], find: .string("th"), replaceWith: .string("TH"), matchEntireCell: false),
                         on: "Table.SelectColumns(\(sales), {\"Region\"})", rows: [["NorTH"], ["SouTH"], ["NorTH"], ["East"], ["SouTH"]])
        // whole-cell replacement only touches exact matches
        try await expect(.replaceValues(columns: ["Region"], find: .string("Nor"), replaceWith: .string("X"), matchEntireCell: true),
                         on: "Table.SelectColumns(\(sales), {\"Region\"})", rows: [["North"], ["South"], ["North"], ["East"], ["South"]])
        try await expect(.replaceValues(columns: ["Region"], find: .string("East"), replaceWith: .string("West"), matchEntireCell: true),
                         on: "Table.SelectColumns(\(sales), {\"Region\"})", rows: [["North"], ["South"], ["North"], ["West"], ["South"]])
        // numbers and null are whole values
        try await expect(.replaceValues(columns: ["Qty", "Price"], find: .null, replaceWith: .int(0), matchEntireCell: false),
                         on: "Table.SelectColumns(\(sales), {\"Qty\", \"Price\"})", rows: [["10", "1.5"], ["5", "2"], ["7", "2"], ["0", "1.5"], ["3", "1.5"]])
        try await expect(.replaceValues(columns: ["Qty"], find: .int(1), replaceWith: .int(9), matchEntireCell: false),
                         on: "Table.SelectColumns(\(sales), {\"Qty\"})", rows: [["10"], ["5"], ["7"], ["null"], ["3"]])
    }
}
