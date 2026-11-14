import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// The Analytics pane offers error bars on a scatter chart, along X, Y or both.
@MainActor
final class ScatterErrorBarsTests: XCTestCase {
    func testScatterChartsOfferErrorBarsOnce() {
        var spec = VisualSpec(type: .scatter, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        spec.setFields(.x, [.measure("S", "X")]); spec.setFields(.y, [.measure("S", "Y")])
        let kinds = BuildLogic.analyticsKinds(for: spec, model: SemanticModel())
        XCTAssertTrue(kinds.contains(.errorBars))
        XCTAssertTrue(BuildLogic.isSingleton(.errorBars))
        // A new card is ± 10 %, on the Y axis.
        let item = BuildLogic.newItem(.errorBars)
        XCTAssertEqual(item.secondaryValue, 10)
        XCTAssertNil(item.errorAxis)
    }

    func testAnOldErrorBarsCardReadsBackOnTheYAxis() throws {
        let old = #"{"id":"6F0D1E9B-6C76-4C8B-9C2E-0E7A1C2B3D4E","kind":"errorBars","name":"","value":0,"secondaryValue":10,"style":"solid","showLabel":true}"#
        XCTAssertNil(try JSONDecoder().decode(AnalyticsItem.self, from: Data(old.utf8)).errorAxis)
        var item = BuildLogic.newItem(.errorBars)
        item.errorAxis = .both
        let back = try JSONDecoder().decode(AnalyticsItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(back.errorAxis, .both)
    }
}
