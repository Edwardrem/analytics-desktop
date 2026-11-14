import XCTest
import AppKit
import SwiftUI
import FacetCore
@testable import MicrosoftPowerBI

/// Performance analyzer: each event splits into DAX query, visual display (from the results
/// arriving to the visual being drawn with them) and other.
@MainActor
final class PerformanceDisplayTests: XCTestCase {
    private func event(query: Double, total: Double, display: Double? = nil) -> PerformanceEvent {
        PerformanceEvent(visualID: UUID(), visualName: "Chart", queryMilliseconds: query, totalMilliseconds: total,
                         dax: "EVALUATE x", displayMilliseconds: display, delivered: 100)
    }

    func testOtherIsWhatTheQueryAndTheDisplayLeave() {
        // 30 ms query in 80 ms of processing: 50 ms other, before and after a 20 ms display.
        XCTAssertEqual(event(query: 30, total: 80).otherMilliseconds, 50)
        XCTAssertEqual(event(query: 30, total: 100, display: 20).otherMilliseconds, 50)
        XCTAssertEqual(event(query: 90, total: 80).otherMilliseconds, 0)
        // A 100-point bar for a 100 ms event when the slowest took 200 ms is half filled: 15, 10 and 25.
        XCTAssertEqual(DurationBar.segments(query: 30, display: 20, other: 50, scale: 200, width: 100), [15, 10, 25])
        XCTAssertEqual(DurationBar.segments(query: 0, display: 0, other: 0, scale: 200, width: 100), [0, 0, 0])
    }

    func testTheStoreAddsTheDisplayTimeToTheTotalOnce() async throws {
        let store = ReportFixture.store()
        let chart = ReportFixture.chart()
        store.mutate("Add", invalidates: .visuals(nil)) { d in d.report.pages[0].visuals.append(chart) }
        await Smoke.settle(store)
        store.performanceRecording = true
        store.refreshVisuals([chart.id])
        await Smoke.settle(store)

        let recorded = try XCTUnwrap(store.performanceLog.last { $0.visualID == chart.id })
        let delivered = try XCTUnwrap(recorded.delivered)
        XCTAssertNil(recorded.displayMilliseconds)
        XCTAssertEqual(store.eventAwaitingDisplay(chart.id), recorded.id)

        // Absolute times near 7e8 s keep about a tenth of a microsecond: compare to a microsecond.
        store.visualDisplayed(recorded.id, at: delivered + 0.025)
        let drawn = try XCTUnwrap(store.performanceLog.last { $0.visualID == chart.id })
        XCTAssertEqual(drawn.displayMilliseconds ?? 0, 25, accuracy: 1e-3)
        XCTAssertEqual(drawn.totalMilliseconds, recorded.totalMilliseconds + 25, accuracy: 1e-3)
        XCTAssertEqual(drawn.otherMilliseconds, recorded.otherMilliseconds, accuracy: 1e-3)
        XCTAssertNil(store.eventAwaitingDisplay(chart.id))

        // A later draw of the same results changes nothing.
        store.visualDisplayed(recorded.id, at: delivered + 1)
        XCTAssertEqual(store.performanceLog.last { $0.visualID == chart.id }?.displayMilliseconds ?? 0, 25, accuracy: 1e-3)

        // Nothing is timed while not recording.
        store.performanceRecording = false
        store.refreshVisuals([chart.id])
        await Smoke.settle(store)
        XCTAssertNil(store.eventAwaitingDisplay(chart.id))
    }

    func testTheProbeReportsTheFirstDrawAfterEachToken() async {
        let view = DisplayProbeView(frame: NSRect(x: 0, y: 0, width: 100, height: 60))
        var reported: [UUID] = []
        view.onDrawn = { id, _ in reported.append(id) }
        let first = UUID(), second = UUID()
        view.arm(first)
        XCTAssertEqual(view.armed, first)
        view.draw(view.bounds)
        view.draw(view.bounds)                       // drawn again: already reported
        await hop()
        XCTAssertEqual(reported, [first])
        view.arm(first)                              // the same results again: not re-armed
        XCTAssertNil(view.armed)
        view.arm(second)
        view.draw(view.bounds)
        await hop()
        XCTAssertEqual(reported, [first, second])
        XCTAssertNil(view.hitTest(NSPoint(x: 10, y: 10)))
    }

    func testAProbeInAWindowReportsWhenTheWindowDraws() async {
        var reported: [UUID] = []
        let token = UUID()
        let probe = DisplayProbe(token: token) { id, _ in reported.append(id) }
        _ = await Smoke.bitmap(probe, size: CGSize(width: 120, height: 80))
        await hop()
        XCTAssertEqual(reported, [token])
    }

    func testTheExportCarriesTheDisplayTime() throws {
        let data = try PerformanceExport.data([event(query: 30, total: 100, display: 20), event(query: 30, total: 80)])
        let file = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(file["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["displayMs"] as? Double, 20)
        XCTAssertEqual(events[0]["otherMs"] as? Double, 50)
        XCTAssertEqual(events[0]["totalMs"] as? Double, 100)
        XCTAssertNil(events[1]["displayMs"])
        XCTAssertEqual(events[1]["otherMs"] as? Double, 50)
    }

    private func hop() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
    }
}
