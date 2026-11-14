import Foundation
import FacetCore

extension CartesianOptions {
    /// The format properties `CartesianOptions.init`, `CartesianVisual` and the scaffold read for
    /// a cartesian chart of `kind`. Defaults repeat the fallbacks in `CartesianOptions.init`.
    /// Horizontal charts read their category axis from "yAxis" and their value axis from "xAxis".
    static func formatProperties(for kind: CartesianKind) -> [FormatProperty] {
        let fonts = SharedFormatCards.fontSizes
        func axis(_ card: String) -> FormatCard { FormatCard(card, card == "xAxis" ? "X axis" : "Y axis") }
        let cat = axis(kind.horizontal ? "yAxis" : "xAxis"), val = axis(kind.horizontal ? "xAxis" : "yAxis")

        let category: [FormatProperty] = [
            cat.bool("show", "Show axis", true),
            cat.bool("showTitle", "Show title", false),
            cat.string("title", "Title", ""),
            cat.options("type", "Type", ["categorical", "continuous"], nil),
            cat.number("labelRotation", "Label rotation", 0, -90...90),
            cat.bool("concatenateLabels", "Concatenate labels", true),
            cat.bool("reverse", "Reverse order", false),
            cat.bool("gridlines", "Gridlines", false),
            cat.number("size", "Font size", nil, fonts),
        ]
        var value: [FormatProperty] = [
            val.bool("show", "Show axis", true),
            val.bool("showTitle", "Show title", false),
            val.string("title", "Title", ""),
            val.number("min", "Minimum", nil, -1e15...1e15),
            val.number("max", "Maximum", nil, -1e15...1e15),
            val.options("displayUnits", "Display units", SharedFormatCards.displayUnits, "auto"),
            val.number("decimals", "Decimal places", nil, 0...10),
        ]
        // A 100% axis is never logarithmic.
        if kind.stacking != .percent { value.append(val.bool("logScale", "Logarithmic scale", false)) }
        value += [val.bool("reverse", "Reverse order", false),
                  val.bool("gridlines", "Gridlines", true),
                  val.number("size", "Font size", nil, fonts)]

        // X axis first, whichever role it plays.
        var out = kind.horizontal ? value + category : category + value
        if kind.isCombo {
            let y2 = FormatCard("y2Axis", "Secondary y-axis")
            out += [y2.bool("show", "Show axis", true),
                    y2.bool("showTitle", "Show title", false),
                    y2.string("title", "Title", "")]
        }
        out += SharedFormatCards.legend()
        out += SmallMultiplesLayout.formatProperties()
        out.append(FormatCard("zoomSlider", "Zoom slider").bool("show", "Show zoom slider", false))
        if kind.drawsBars {
            let bars = FormatCard("bars", kind.horizontal ? "Bars" : "Columns")
            out += [bars.number("innerPadding", "Inner padding %", kind.stacking == .none ? 26 : 34, 0...90),
                    bars.number("outerPadding", "Outer padding %", 0, 0...200),
                    bars.number("cornerRadius", "Corner radius", 2.5, 0...100)]
        }
        let lines = FormatCard("lines", kind.drawsDots ? "Markers" : "Lines")
        if kind.drawsDots {
            out += [lines.number("markerSize", "Marker size", 9, 1...60),
                    lines.options("markerShape", "Marker shape", ["auto"] + MarkerShape.cycle.map(\.rawValue), "auto")]
        } else if !kind.drawsBars || kind.isCombo {
            out += [lines.number("width", "Line width", 2, 0.25...20),
                    lines.options("style", "Line style", ["solid", "dashed", "dotted"], "solid"),
                    lines.options("interpolation", "Shape", ["smooth", "linear", "step"], "smooth"),
                    lines.bool("shadeArea", "Shade area", false),
                    lines.bool("seriesLabels", "Show series labels", false),
                    lines.bool("showMarkers", "Show markers", false),
                    lines.number("markerSize", "Marker size", 5, 1...60),
                    lines.options("markerShape", "Marker shape", ["auto"] + MarkerShape.cycle.map(\.rawValue), "auto")]
        }
        out += SharedFormatCards.dataLabels(show: false, position: true, detail: true)
        if kind.drawsBars {
            let totals = FormatCard("totalLabels", "Total labels")
            out += [totals.bool("show", "Show total labels", false),
                    totals.options("displayUnits", "Display units", SharedFormatCards.displayUnits, "auto"),
                    totals.color("color", "Text colour", .foreground)]
        }
        out += SharedFormatCards.plotArea(transparency: true)
        out += SharedFormatCards.accessibility()
        return out
    }
}
