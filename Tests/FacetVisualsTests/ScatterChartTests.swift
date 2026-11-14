import XCTest
import SwiftUI
import FacetCore
@testable import FacetVisuals

/// The scatter chart's points: details name them, the legend colours them, the play axis splits them into frames.
@MainActor
final class ScatterChartTests: XCTestCase {
    private let store = FieldRef.column("Sales", "Store")
    private let region = FieldRef.column("Sales", "Region")
    private let year = FieldRef.column("Sales", "Year")

    /// Two stores in two regions over two years, plus a row with no year.
    private func sample(play: Bool = true) -> (VisualSpec, VisualData) {
        var spec = VisualSpec(type: .scatter, frame: Frame(x: 0, y: 0, width: 480, height: 320))
        var columns = [
            DataColumn(name: "Store", values: ["A", "B", "A", "B", "C"].map(Value.string)),
            DataColumn(name: "Region", values: ["North", "South", "North", "South", "North"].map(Value.string)),
            DataColumn(name: "Sales", type: .decimal, values: [10, 20, 15, 18, 5].map(Value.double)),
            DataColumn(name: "Profit", type: .decimal, values: [1, 4, 2, 3, 1].map(Value.double)),
        ]
        var roles: [String: [Int]] = ["details": [0], "legend": [1], "x": [2], "y": [3]]
        var fields: [FieldRef?] = [store, region, .measure("Sales", "Sales"), .measure("Sales", "Profit")]
        spec.setFields(.details, [store]); spec.setFields(.legend, [region])
        if play {
            columns.append(DataColumn(name: "Year", type: .integer, values: [.int(2025), .int(2025), .int(2024), .int(2024), .null]))
            roles["playAxis"] = [4]; fields.append(year); spec.setFields(.playAxis, [year])
        }
        let data = VisualData(table: DataTable(name: "q", columns: columns), roles: roles, fields: fields,
                              formats: Array(repeating: "", count: columns.count))
        return (spec, data)
    }

    func testDetailsNameThePointsAndLegendColoursThem() {
        let model = ScatterModel(data: sample(play: false).1)
        XCTAssertEqual(model.points.map(\.label), ["A", "B", "A", "B", "C"])
        XCTAssertEqual(model.series.map(\.name), ["North", "South"])
        XCTAssertEqual(model.points.map(\.series), [0, 1, 0, 1, 0])
        XCTAssertEqual(model.points[0].selection.fields.map(\.name), ["Store", "Region"], "a point is its details and legend values")
        XCTAssertEqual(model.series[1].selection?.values, [.string("South")])
        XCTAssertTrue(model.frames.isEmpty)
        XCTAssertEqual(model.visible(frame: 0).count, 5)
        XCTAssertEqual(model.maxSize, 0)
    }

    func testThePlayAxisSplitsRowsIntoOrderedFrames() {
        let model = ScatterModel(data: sample().1)
        XCTAssertEqual(model.frames, [.int(2024), .int(2025)])
        XCTAssertEqual(model.points.count, 4, "the row without a year belongs to no frame")
        XCTAssertEqual(model.visible(frame: 0).map(\.x), [15, 18])
        XCTAssertEqual(model.visible(frame: 1).map(\.x), [10, 20])
        // The play axis is not part of a point's identity: store A is the same point in both years.
        XCTAssertEqual(model.points[0].selection.key, model.points[2].selection.key)
    }

    func testASelectedPointLeavesATrail() {
        let model = ScatterModel(data: sample().1)
        let a = DataPointSelection(fields: [store], values: [.string("A")])
        let trails = model.trails(through: 1, matcher: SelectionMatcher([a]))
        XCTAssertEqual(trails.count, 1)
        XCTAssertEqual(trails.first?.map(\.x), [15, 10], "2024 then 2025")
        XCTAssertTrue(model.trails(through: 0, matcher: SelectionMatcher([a])).isEmpty, "one frame is not yet a path")
        XCTAssertTrue(model.trails(through: 1, matcher: SelectionMatcher([])).isEmpty)
    }

    func testRendersWithAPlayAxisAndALegend() {
        let (spec, data) = sample()
        var context = VisualContext()
        context.isInteractive = false
        let host = NSHostingView(rootView: VisualView(spec: spec, data: data, context: context).frame(width: 480, height: 320))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)
        XCTAssertNotNil(rep)
        if let rep { host.cacheDisplay(in: host.bounds, to: rep); XCTAssertNotNil(rep.colorAt(x: 10, y: 10)) }
    }
}
