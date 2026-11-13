import XCTest
@testable import MicrosoftPowerBI

/// Proves the app target is importable from tests; feature suites for app-level logic live beside this file.
final class AppTargetTests: XCTestCase {
    func testEveryWorkspaceViewHasATitleAndSymbol() {
        for view in WorkspaceView.allCases {
            XCTAssertFalse(view.title.isEmpty)
            XCTAssertFalse(view.symbol.isEmpty)
        }
    }
}
