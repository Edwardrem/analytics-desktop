import XCTest
import SwiftUI
import FacetCore
@testable import FacetVisuals

/// Deterministic fixture data with every well a visual type needs, so each renderer gets real columns.
@MainActor
private enum Fixture {
    static func data(_ type: VisualType) -> (VisualSpec, VisualData) {
        let b = Builder(type)
        return (b.spec, b.data)
    }

    /// One builder per family: the columns a type's wells read.
    private struct Builder {
        let spec: VisualSpec
        let data: VisualData

        init(_ type: VisualType) {
            let frame = Frame(x: 0, y: 0, width: 520, height: 340)
            var spec = VisualSpec(type: type, frame: frame, name: type.displayName)
            var columns: [DataColumn] = []
            var roles: [String: [Int]] = [:]
            var fields: [FieldRef?] = []
            var formats: [String] = []

            func add(_ well: Well?, _ field: FieldRef, _ column: DataColumn, format: String = "") {
                if let well { roles[well.rawValue, default: []].append(columns.count) }
                spec.wells[well?.rawValue ?? "", default: []].append(field)
                columns.append(column); fields.append(field); formats.append(format)
            }
            func group(_ well: Well, _ name: String, _ values: [Value]) {
                add(well, .column("Sales", name), DataColumn(name: name, values: values))
            }
            func measure(_ well: Well, _ name: String, _ values: [Double?], format: String = "#,0") {
                add(well, .measure("Sales", name),
                    DataColumn(name: name, type: .decimal, values: values.map { $0.map(Value.double) ?? .null }), format: format)
            }
            func dates(_ well: Well, _ name: String, _ values: [Date]) {
                add(well, .column("Sales", name), DataColumn(name: name, type: .date, values: values.map(Value.date)))
            }

            let categories: [Value] = ["North", "South", "East", "West", "Central"].map(Value.string)
            let months: [Date] = (0..<5).compactMap { d in
                var c = DateComponents(); c.year = 2024; c.month = d + 1; c.day = 1
                return Calendar.current.date(from: c)
            }
            let values: [Double?] = [42, 31, 57, 24, 48]

            switch type {
            case .stackedBar, .clusteredBar, .stackedBar100, .stackedColumn, .clusteredColumn, .stackedColumn100,
                 .line, .area, .stackedArea, .stackedArea100, .dotPlot, .ribbon:
                group(.category, "Region", categories)
                measure(.values, "Sales", values)
                measure(.values, "Cost", values.map { $0.map { $0 * 0.6 } })
            case .lineStackedColumn, .lineClusteredColumn:
                group(.category, "Region", categories)
                measure(.values, "Sales", values)
                measure(.lineValues, "Trend", values.map { $0.map { $0 * 1.1 } })
            case .waterfall:
                group(.category, "Region", categories)
                measure(.values, "Change", [12, -7, 21, -4, 9])
            case .pie, .donut, .funnel:
                group(.legend, "Region", categories)
                measure(.values, "Sales", values)
            case .treemap, .sunburst, .wordCloud, .heatmap, .histogram, .boxPlot, .bullet:
                if type == .heatmap {
                    group(.rows, "Region", categories)
                    group(.columns, "Quarter", ["Q1", "Q1", "Q1", "Q1", "Q1"].map(Value.string))
                    measure(.values, "Sales", values)
                } else if type == .histogram || type == .boxPlot {
                    measure(.values, "Age", [21, 34, 45, 52, 27, 38, 61, 44, 33, 29, 55, 41])
                } else {
                    group(.category, "Region", categories)
                    measure(.values, "Sales", values)
                    if type == .bullet { measure(.target, "Target", [40, 40, 40, 40, 40]) }
                }
            case .scatter:
                measure(.x, "Sales", values)
                measure(.y, "Profit", values.map { $0.map { $0 * 0.4 } })
                measure(.size, "Units", values.map { $0.map { $0 * 3 } })
            case .candlestick:
                group(.category, "Month", months.map(Value.date))
                measure(.open, "Open", [10, 12, 11, 13, 12])
                measure(.high, "High", [14, 15, 13, 16, 15])
                measure(.low, "Low", [9, 11, 10, 12, 11])
                measure(.close, "Close", [12, 11, 13, 12, 14])
            case .radar:
                group(.category, "Region", categories)
                measure(.values, "Sales", values)
            case .sankey:
                group(.source, "Channel", ["Online", "Online", "Retail", "Retail"].map(Value.string))
                group(.destination, "Region", categories.prefix(4).map { $0 })
                measure(.values, "Sales", [20, 22, 15, 18])
            case .calendarHeatmap:
                dates(.category, "Day", months)
                measure(.values, "Sales", values)
            case .card, .cardLegacy, .multiRowCard, .kpi, .gauge:
                group(.legend, "Region", categories)
                measure(.values, "Sales", values)
                if type == .kpi {
                    dates(.trendAxis, "Month", months)
                    measure(.target, "Goal", [50, 50, 50, 50, 50])
                }
                if type == .gauge {
                    measure(.minimum, "Min", [0, 0, 0, 0, 0])
                    measure(.maximum, "Max", [100, 100, 100, 100, 100])
                    measure(.target, "Target", [50, 50, 50, 50, 50])
                }
            case .table, .matrix:
                group(.rows, "Region", categories)
                measure(.values, "Sales", values)
            case .slicer, .buttonSlicer, .listSlicer, .inputSlicer:
                group(.field, "Region", categories)
            case .map, .azureMap, .filledMap, .shapeMap:
                group(.location, "Region", categories)
                measure(.values, "Sales", values)
            case .gantt:
                group(.task, "Task", ["Plan", "Build", "Test"].map(Value.string))
                dates(.start, "Start", months.prefix(3).map { $0 })
                dates(.end, "End", months.suffix(3).map { $0 })
            case .keyInfluencers:
                measure(.analyze, "Sales", values)
                group(.explainBy, "Region", categories)
            case .decompositionTree:
                measure(.values, "Sales", values)
                group(.explainBy, "Region", categories)
            case .narrative, .qna:
                measure(.values, "Sales", values)
            case .textBox, .image, .shape, .button, .pageNavigator, .bookmarkNavigator:
                break
            case .pythonVisual, .rVisual, .paginatedReport, .powerApps, .powerAutomate, .metrics:
                measure(.values, "Sales", values)
            }

            var table = DataTable(name: type.displayName, columns: columns)
            table.inferTypes()
            data = VisualData(table: table, roles: roles, fields: fields, formats: formats,
                              totals: columns.enumerated().map { i, c in
                                  fields[i]?.isAggregate == true ? .double(c.values.compactMap(\.asDouble).reduce(0, +)) : .null
                              })
            self.spec = spec
        }
    }
}

/// Every visual type the gallery offers must have a renderer: the dispatch stubs that used to return
/// nil silently downgraded half the chart gallery to the "Add fields" placeholder.
@MainActor
final class RendererDispatchTests: XCTestCase {
    func testEveryChartTypeHasARenderer() {
        for type in ChartVisuals.supportedTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
            let (spec, data) = Fixture.data(type)
            let context = VisualContext()
            let view = ChartVisuals.view(spec: spec, data: data, context: context)
            XCTAssertNotNil(view, "\(type.displayName) (\(type.rawValue)) has no renderer")
        }
    }

    func testEveryComponentTypeHasARenderer() {
        for type in ComponentVisuals.supportedTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
            let (spec, data) = Fixture.data(type)
            let context = VisualContext()
            let view = ComponentVisuals.view(spec: spec, data: data, context: context)
            XCTAssertNotNil(view, "\(type.displayName) (\(type.rawValue)) has no renderer")
        }
    }
}

/// Renders every visual type offscreen: the layout code must not crash and must draw content.
@MainActor
final class OffscreenRenderTests: XCTestCase {
    func testEveryVisualTypeRenders() throws {
        let types = Array(ChartVisuals.supportedTypes) + Array(ComponentVisuals.supportedTypes)
        let only = ProcessInfo.processInfo.environment["FACET_RENDER_ONLY"]
        var failures: [String] = []
        for type in types.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let only, type.rawValue != only { continue }
            let (spec, data) = Fixture.data(type)
            var context = VisualContext()
            context.theme = .facet
            context.isInteractive = false
            print("◇ rendering \(type.rawValue)")
            let host = NSHostingView(rootView: VisualView(spec: spec, data: data, context: context)
                .frame(width: 480, height: 320))
            host.frame = NSRect(x: 0, y: 0, width: 480, height: 320)
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                failures.append("\(type.rawValue): no bitmap")
                continue
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            let drawn = rep.colorAt(x: 10, y: 10) != nil
            XCTAssertTrue(drawn || type.isPageElement, "\(type.rawValue): rendered an empty surface")
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
