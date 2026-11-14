import XCTest
import FacetCore
@testable import FacetDAX

/// FORMAT uses the model's culture unless a locale is given (DAX FORMAT's third argument).
final class FormatCultureDAXTests: TimeSchemaTestCase {
    private func load(culture: String) {
        var m = TimeSchema.model()
        m.culture = culture
        engine = DAXEngine()
        engine.load(model: m, data: TimeSchema.data())
    }

    func testFormatUsesTheModelCulture() throws {
        load(culture: "de-DE")
        XCTAssertEqual(try scalar("FORMAT(1234.5, \"#,0.00\")"), .string("1.234,50"))
        XCTAssertEqual(try scalar("FORMAT(DATE(2024, 3, 5), \"mmmm\")"), .string("März"))
        XCTAssertEqual(try scalar("USERCULTURE()"), .string("de-DE"))
        load(culture: "en-US")
        XCTAssertEqual(try scalar("FORMAT(1234.5, \"#,0.00\")"), .string("1,234.50"))
    }

    func testALocaleArgumentWins() throws {
        load(culture: "de-DE")
        XCTAssertEqual(try scalar("FORMAT(1234.5, \"#,0.00\", \"en-US\")"), .string("1,234.50"))
        // 5 March 2024 was a Tuesday.
        XCTAssertEqual(try scalar("FORMAT(DATE(2024, 3, 5), \"dddd\", \"fr-FR\")"), .string("mardi"))
    }
}
