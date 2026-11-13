import SwiftUI
import AppKit
import FacetCore

/// Gallery samples for every slicer type and style, with selections pre-set so states are visible.
enum CmpSlGallery {
    private static let regions = ["Africa", "Asia Pacific", "Europe", "Latin America", "Middle East", "North America", "Nordics", "Oceania"]
    private static let hierarchy: [(String, String, [String])] = [
        ("Accessories", "Bags", ["Daypack", "Messenger", "Tote"]),
        ("Accessories", "Helmets", ["Road", "Trail"]),
        ("Bikes", "Mountain", ["Summit 200", "Summit 400", "Ridge Pro"]),
        ("Bikes", "Road", ["Aero 1", "Aero 2"]),
        ("Bikes", "Touring", ["Voyager"]),
        ("Clothing", "Jerseys", ["Classic", "Thermal"]),
        ("Clothing", "Gloves", ["Full finger", "Half finger"]),
    ]

    static func samples() -> [(spec: VisualSpec, data: VisualData)] {
        let regionRows = regions.map { [Value.string($0)] }
        func flat(_ type: VisualType, _ name: String, _ size: (Double, Double), field: String = "Region",
                  rows: [[Value]]? = nil, _ configure: @escaping (inout VisualSpec) -> Void) -> (spec: VisualSpec, data: VisualData) {
            CmpSample.make(type, name: name, size: (size.0, size.1), columns: [CmpCol(field, .field)], rows: rows ?? regionRows, configure: configure)
        }
        func state(_ m: (inout SlicerState) -> Void) -> SlicerState { var s = SlicerState(); m(&s); return s }
        let hierarchyCols = [CmpCol("Category", .field), CmpCol("Subcategory", .field), CmpCol("Product", .field)]
        let hierarchyRows: [[Value]] = hierarchy.flatMap { c, s, ps in ps.map { [Value.string(c), .string(s), .string($0)] } }
        let hierarchyState = state {
            $0.hierarchyPaths = [["Bikes", "Mountain"], ["Bikes", "Road", "Aero 2"], ["Clothing"]]
        }
        let prices: [[Value]] = [49, 120, 185, 240, 320, 415, 560, 640, 799, 950].map { [Value.int($0)] }
        func day(_ s: String) -> Value { DateParsing.parse(s).map(Value.date) ?? .null }
        let dates: [[Value]] = ["2026-01-01", "2026-02-14", "2026-04-02", "2026-06-30", "2026-09-15", "2026-12-31"].map { [day($0)] }
        let brands: [(String, String)] = [("Aurora", "#0A84FF"), ("Borealis", "#5E5CE6"), ("Cascade", "#30B0C7"), ("Dune", "#FF9F0A"),
                                          ("Ember", "#FF375F"), ("Fjord", "#34C759"), ("Glacier", "#64D2FF"), ("Harbor", "#AC8E68"),
                                          ("Isle", "#BF5AF2"), ("Juniper", "#2D6A4F")]

        return [
            flat(.slicer, "Slicer List", (200, 256)) {
                $0.setFmt("slicer", "search", .bool(true)); $0.setFmt("slicer", "selectAll", .bool(true))
                $0.setFmt("slicer", "showClear", .string("always"))
                $0.slicerState = state { $0.selected = ["Europe", "Nordics", "North America"] }
            },
            flat(.slicer, "Slicer List Single", (180, 200), rows: Array(regionRows.prefix(6))) {
                $0.setFmt("slicer", "singleSelect", .bool(true))
                $0.slicerState = state { $0.selected = ["Europe"] }
            },
            flat(.slicer, "Slicer Dropdown", (230, 84)) {
                $0.setFmt("slicer", "style", .string("dropdown"))
                $0.slicerState = state { $0.selected = ["Asia Pacific", "Europe"] }
            },
            flat(.slicer, "Slicer Tile", (330, 116)) {
                $0.setFmt("slicer", "style", .string("tile"))
                $0.slicerState = state { $0.selected = ["Asia Pacific", "Latin America"] }
            },
            flat(.slicer, "Slicer Between Number", (280, 132), field: "Unit Price", rows: prices) {
                $0.setFmt("slicer", "style", .string("between"))
                $0.slicerState = state { $0.rangeLow = 185; $0.rangeHigh = 640 }
            },
            flat(.slicer, "Slicer Between Date", (300, 132), field: "Order Date", rows: dates) {
                $0.setFmt("slicer", "style", .string("between"))
                $0.slicerState = state { $0.rangeLow = day("2026-03-01"); $0.rangeHigh = day("2026-09-30") }
            },
            flat(.slicer, "Slicer Before", (270, 124), field: "Ship Date", rows: dates) {
                $0.setFmt("slicer", "style", .string("before"))
                $0.slicerState = state { $0.rangeHigh = day("2026-06-30") }
            },
            flat(.slicer, "Slicer After", (270, 124), field: "Quantity", rows: prices) {
                $0.setFmt("slicer", "style", .string("after"))
                $0.slicerState = state { $0.rangeLow = 320 }
            },
            flat(.slicer, "Slicer Relative Date", (300, 132), field: "Order Date", rows: dates) {
                $0.setFmt("slicer", "style", .string("relativeDate"))
                $0.slicerState = state { var r = RelativeDateFilter(); r.count = 30; $0.relative = r }
            },
            flat(.slicer, "Slicer Relative Time", (300, 104), field: "Event Time", rows: dates) {
                $0.setFmt("slicer", "style", .string("relativeTime"))
                $0.slicerState = state { var r = RelativeDateFilter(); r.count = 6; r.unit = .hours; $0.relative = r }
            },
            CmpSample.make(.slicer, name: "Slicer Hierarchy", size: (236, 330), columns: hierarchyCols, rows: hierarchyRows) {
                $0.setFmt("slicer", "style", .string("hierarchy")); $0.setFmt("slicer", "search", .bool(true))
                $0.setFmt("slicer", "selectAll", .bool(true))
                $0.slicerState = hierarchyState
            },
            flat(.slicer, "Slicer Apply", (200, 250)) {
                $0.setFmt("slicer", "applyButton", .bool(true))
                $0.slicerState = state { $0.selected = ["Africa", "Middle East"] }
            },
            flat(.buttonSlicer, "ButtonSlicer Grid", (380, 170)) {
                $0.setFmt("buttons", "columns", .number(3))
                $0.slicerState = state { $0.selected = ["Europe", "Nordics"] }
            },
            CmpSample.make(.buttonSlicer, name: "ButtonSlicer Images", size: (400, 220),
                           columns: [CmpCol("Brand", .field), CmpCol("Logo", .field)],
                           rows: brands.map { [Value.string($0.0), .string(swatch($0.0, $0.1))] }) {
                $0.setFmt("buttons", "columns", .number(4)); $0.setFmt("buttons", "rows", .number(2))
                $0.setFmt("buttons", "overflow", .string("pagination"))
                $0.setFmt("slicer", "singleSelect", .bool(true))
                $0.slicerState = state { $0.selected = ["Cascade"] }
            },
            flat(.listSlicer, "ListSlicer", (190, 236)) {
                $0.slicerState = state { $0.selected = ["Asia Pacific", "Middle East"] }
            },
            CmpSample.make(.listSlicer, name: "ListSlicer Hierarchy", size: (220, 280), columns: hierarchyCols, rows: hierarchyRows) {
                $0.slicerState = hierarchyState
            },
            flat(.listSlicer, "ListSlicer Dropdown", (230, 84)) {
                $0.setFmt("slicer", "dropdown", .bool(true))
                $0.slicerState = state { $0.selected = ["Oceania"] }
            },
            flat(.inputSlicer, "InputSlicer", (330, 136), field: "Product") {
                $0.setFmt("slicer", "operator", .string("startsWith"))
                $0.slicerState = state {
                    $0.selected = ["Summit", "Aero", "Ridge Pro", "Voyager", "Trail"]
                    $0.text = "Summit\nAero\nRidge Pro\nVoyager\nTrail"
                }
            },
            flat(.inputSlicer, "InputSlicer Empty", (300, 84), field: "Order ID") { _ in },
            CmpSample.make(.slicer, name: "Slicer No Field", size: (220, 150)) { _ in },
        ]
    }

    /// A small generated logo (rounded square with an initial) as a PNG data URI.
    private static func swatch(_ name: String, _ hex: String) -> String {
        let side = 56
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return "" }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        CmpColor.ns(hex).setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: 14, yRadius: 14).fill()
        let text = String(name.prefix(1)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30, weight: .semibold), .foregroundColor: NSColor.white]
        let s = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: (CGFloat(side) - s.width) / 2, y: (CGFloat(side) - s.height) / 2), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return "data:image/png;base64," + png.base64EncodedString()
    }
}
