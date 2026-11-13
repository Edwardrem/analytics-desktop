import XCTest
import FacetCore
@testable import FacetCloud

/// Runs the offline FacetCloud self-check: everything that does not need a live Microsoft or
/// Anthropic service, including the assistant's SSE parsing, request building and tool loop.
final class FacetCloudSelfCheckTests: XCTestCase {
    func testSelfCheckPasses() {
        let report = FacetCloudSelfCheck.runReportBlocking()
        if !report.failures.isEmpty {
            print("DEBUG passed:", report.passed)
            print("DEBUG failures:", report.failures)
            print("DEBUG skipped:", report.skipped)
        }
        XCTAssertTrue(report.failures.isEmpty, "self-check failures:\n" + report.failures.joined(separator: "\n"))
        XCTAssertGreaterThan(report.passed, 0, "no checks ran")
    }
}
