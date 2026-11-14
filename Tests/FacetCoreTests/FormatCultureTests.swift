import XCTest
@testable import FacetCore

/// Formatting in a model's culture. Expected values follow the cultures' documented conventions: de-DE groups
/// thousands with "." and writes decimals with ","; month and day names are the culture's own.
final class FormatCultureTests: XCTestCase {
    private let de = FormatCulture(identifier: "de-DE")
    private let us = FormatCulture.enUS
    private var march5: Date { DateParsing.parse("2024-03-05") ?? Date(timeIntervalSince1970: 0) }

    func testNumbersUseTheCulturesSeparators() {
        XCTAssertEqual(ValueFormatter.format(.double(1234.5), "#,0.00", culture: us), "1,234.50")
        XCTAssertEqual(ValueFormatter.format(.double(1234.5), "#,0.00", culture: de), "1.234,50")
        XCTAssertEqual(ValueFormatter.format(.double(-1234567.891), "#,0.0", culture: de), "-1.234.567,9")
        XCTAssertEqual(ValueFormatter.format(.double(0.256), "0.0%", culture: de), "25,6%")
        XCTAssertEqual(ValueFormatter.format(.double(1500), "#,0.0,\"K\"", culture: de), "1,5K")
        XCTAssertEqual(ValueFormatter.format(.int(2024), "", culture: de), "2024", "a whole number with no format has no separators")
        XCTAssertEqual(ValueFormatter.formatNumber(1234.5, "Standard", culture: de), "1.234,50")
    }

    func testCurrencyUsesTheCulturesSymbol() {
        XCTAssertEqual(ValueFormatter.formatNumber(1234.5, "Currency", culture: us), "$1,234.50")
        let euro = ValueFormatter.formatNumber(1234.5, "Currency", culture: de)
        XCTAssertTrue(euro.hasPrefix("1.234,50"), euro)
        XCTAssertTrue(euro.hasSuffix("€"), euro)
    }

    func testDatesUseTheCulturesNamesAndPatterns() {
        // 5 March 2024 was a Tuesday.
        XCTAssertEqual(ValueFormatter.formatDate(march5, "mmmm yyyy", culture: us), "March 2024")
        XCTAssertEqual(ValueFormatter.formatDate(march5, "mmmm yyyy", culture: de), "März 2024")
        XCTAssertEqual(ValueFormatter.formatDate(march5, "dddd", culture: FormatCulture(identifier: "fr-FR")), "mardi")
        XCTAssertEqual(ValueFormatter.formatDate(march5, "Short Date", culture: us), "3/5/2024")
        XCTAssertEqual(ValueFormatter.formatDate(march5, "Short Date", culture: de), "05.03.2024")
    }

    func testTheCurrentCultureIsUsedWhenNoneIsGiven() {
        let saved = ValueFormatter.culture
        defer { ValueFormatter.culture = saved }
        ValueFormatter.culture = de
        XCTAssertEqual(ValueFormatter.format(.double(1234.5), "#,0.00"), "1.234,50")
        XCTAssertEqual(ValueFormatter.compact(1500), "1,5K")
        ValueFormatter.culture = us
        XCTAssertEqual(ValueFormatter.format(.double(1234.5), "#,0.00"), "1,234.50")
        XCTAssertEqual(ValueFormatter.compact(1500), "1.5K")
    }
}
