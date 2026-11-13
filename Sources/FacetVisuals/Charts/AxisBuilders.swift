import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Axis mark builders shared by the simpler Swift Charts visuals (waterfall, scatter).
enum ChartAxes {
    /// Numeric axis: hairline gridlines and compact labels at the scale's ticks.
    @AxisContentBuilder
    static func numeric(_ scale: AxisScale, style: ChartStyle, card: String, format: String, position: AxisMarkPosition,
                        showLabels: Bool, gridlinesDefault: Bool = true, centered: Bool = false) -> some AxisContent {
        let f = style.format
        let units = DisplayUnits(f.string(card, "displayUnits", "auto"))
        let decimals = f.decimals(card)
        let grid = f.bool(card, "gridlines", gridlinesDefault)
        let show = showLabels && f.bool(card, "show", true)
        let fs = style.size(card)
        AxisMarks(position: position, values: scale.ticks) { v in
            if grid { AxisGridLine(stroke: StrokeStyle(lineWidth: style.gridWidth)).foregroundStyle(style.grid) }
            if show, let d = v.as(Double.self) {
                AxisValueLabel(anchor: centered ? (v.index == scale.ticks.count - 1 ? .topTrailing : (v.index == 0 ? .topLeading : .top)) : nil) {
                    Text(AxisFormatter.label(d, units: units, decimals: decimals, format: format))
                        .font(style.font(fs).monospacedDigit()).foregroundStyle(style.secondary)
                }
            }
        }
    }

    /// Category labels at integer band positions, wrapped or thinned to fit.
    @AxisContentBuilder
    static func categories(_ axis: CartesianLayout.CategoryAxis, style: ChartStyle, card: String, show: Bool) -> some AxisContent {
        let fs = style.size(card)
        AxisMarks(position: .bottom, values: axis.ticks.map(\.pos)) { v in
            if show, let t = axis.ticks[safe: v.index] {
                AxisValueLabel(anchor: .top) {
                    if axis.wraps {
                        Text(t.label).font(style.font(fs)).foregroundStyle(style.secondary)
                            .lineLimit(2).multilineTextAlignment(.center).frame(width: axis.labelWidth)
                    } else {
                        Text(t.label).font(style.font(fs)).foregroundStyle(style.secondary).lineLimit(1).fixedSize()
                    }
                }
            }
        }
    }

    /// Rotated title beside a vertical axis.
    static func verticalTitle(_ t: String, style: ChartStyle) -> some View {
        Text(t).font(style.font()).foregroundStyle(style.secondary).lineLimit(1).fixedSize()
            .rotationEffect(.degrees(-90)).frame(width: style.labelSize + 4).frame(maxHeight: .infinity)
    }
}

extension CartesianLayout {
    /// Fits horizontal labels under bands of width `band`: in full, wrapped to two lines, truncated, or every n-th.
    static func fitLabels(_ ticks: [Tick], band: CGFloat, fontSize: CGFloat, maxLabelWidth: CGFloat = 110) -> CategoryAxis {
        let full = ticks.map { ChartText.size($0.label, fontSize: fontSize).width }.max() ?? 0
        if full + 8 <= band { return CategoryAxis(ticks: ticks, labelWidth: full) }
        let wrapped = ticks.map { wrappedWidth($0.label, fontSize: fontSize) }.max() ?? 0
        if wrapped + 8 <= band || band >= 46 { return CategoryAxis(ticks: ticks, labelWidth: band - 6, wraps: true) }
        let w = min(full, maxLabelWidth)
        let step = max(1, Int(((w + 10) / max(band, 0.01)).rounded(.up)))
        return CategoryAxis(ticks: ticks.enumerated().filter { $0.offset % step == 0 }.map(\.element), labelWidth: w, dropsOverflow: true)
    }
}
