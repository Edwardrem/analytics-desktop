import XCTest
import FacetCore
@testable import FacetDAX

/// A measure's dynamic format string is evaluated in the filter context it is shown in, with
/// SELECTEDMEASURE() standing for the measure's value there (as in a calculation item's format).
final class DynamicFormatStringTests: TimeSchemaTestCase {
    private func useFormat(_ expression: String) {
        engine = TimeSchema.makeEngine { m, _ in
            guard let t = m.tableIndex("Sales"), let i = m.tables[t].measures.firstIndex(where: { $0.name == "Amt" }) else { return }
            m.tables[t].measures[i].formatExpression = expression
        }
    }

    private func year(_ y: Int) -> FilterSpec {
        var f = FilterSpec(field: .column("Date", "Year"))
        f.values = [.int(Int64(y))]
        return f
    }

    /// Amt by year: 2023 is 210, 2025 is 6000.
    func testTheFormatFollowsTheMeasuresValue() throws {
        useFormat("IF(SELECTEDMEASURE() >= 1000, \"#,0.0,K\", SELECTEDMEASUREFORMATSTRING())")
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt", filters: [year(2023)]), "#,0", "the static format, from inside its own format string")
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt", filters: [year(2025)]), "#,0.0,K")
    }

    func testTheMeasuresNameIsAvailable() throws {
        useFormat("SELECTEDMEASURENAME() & \" \" & SELECTEDMEASUREFORMATSTRING()")
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt"), "Amt #,0")
    }

    func testABlankOrFailingExpressionFallsBackToTheStaticFormat() throws {
        useFormat("IF(SELECTEDMEASURE() > 1000000, \"0.0,,M\")")
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt"), "#,0", "blank")
        useFormat("1 / 0 & ERROR(\"no\")")
        XCTAssertEqual(try engine.formatString(forMeasure: "Amt"), "#,0", "an error")
    }
}
