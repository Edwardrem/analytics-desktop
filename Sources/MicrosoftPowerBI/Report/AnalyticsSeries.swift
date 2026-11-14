import Foundation
import FacetCore
import FacetAnalytics
import FacetVisuals

/// How the Analytics pane's time-series analyses (forecast, anomalies) read a visual's result: one
/// value column, row by row along the axis, and the overlays computed from it, mapped back to the
/// rows of the result the chart draws.
enum AnalyticsSeries {
    /// Most points a forecast may add, and most trailing points it may ignore.
    static let maxForecastLength = 1000

    /// The column the series runs along: the category axis.
    static func axisColumn(_ data: VisualData) -> Int? {
        data.indices(.category).first.flatMap { $0 < data.table.columnCount ? $0 : nil }
    }

    /// The result's rows in axis order. A query returns its groups in the order it meets them, so a
    /// number or date axis is put in order of its values; any other axis keeps the query's order.
    static func axisOrder(_ data: VisualData) -> [Int] {
        let rows = Array(0..<data.table.rowCount)
        guard let c = axisColumn(data) else { return rows }
        let values = rows.map { data.table[$0, c] }
        let continuous = values.allSatisfy { v in
            switch v { case .null, .int, .double, .date: return true; default: return false }
        }
        guard continuous else { return rows }
        return rows.sorted { a, b in values[a] == values[b] ? a < b : values[a] < values[b] }
    }

    /// The numbers of one value column, in `order`; blanks and text are gaps.
    static func values(_ data: VisualData, column: Int, order: [Int]) -> [Double?] {
        order.map { r in
            let v = data.table[r, column]
            guard v.isNumber, let d = v.asDouble, d.isFinite else { return nil }
            return d
        }
    }

    /// A count from a document number, clamped to `range` (documents can hold any number).
    static func count(_ value: Double?, in range: ClosedRange<Int>, default fallback: Int) -> Int {
        FormatNumber.int(value, in: range) ?? fallback
    }

    /// The season length the forecaster is given: nil detects it, 0 forecasts without seasonality.
    static func seasonality(_ item: AnalyticsItem) -> Int? {
        guard let s = item.seasonality else { return nil }
        return s >= 2 ? s : 0
    }

    // MARK: Forecast

    /// The forecast of one value column, its line starting at the last point it was fitted to.
    static func forecast(_ item: AnalyticsItem, data: VisualData, column: Int) -> AnalyticsOverlays.Forecast? {
        let order = axisOrder(data)
        let series = values(data, column: column, order: order)
        let axis = axisColumn(data).map { c in order.map { data.table[$0, c] } } ?? []
        let horizon = count(item.value, in: 1...maxForecastLength, default: 10)
        let ignore = min(count(item.ignoreLast.map(Double.init), in: 0...maxForecastLength, default: 0), series.count)
        let confidence = (FormatNumber.clamped(item.secondaryValue, to: 1...99.99) ?? 95) / 100
        guard var fc = try? Forecaster.overlay(axis: axis, values: series, seriesColumn: column, horizon: horizon,
                                               seasonality: seasonality(item), confidence: confidence, ignoreLast: ignore) else { return nil }
        fc.ignoredRows = Array(order.suffix(ignore))
        fc.anchorRow = order.dropLast(ignore).last
        return fc
    }

    // MARK: Anomalies

    /// The sensitivity of an Anomalies item, 1…100 (70 when it has none).
    static func sensitivity(_ item: AnalyticsItem) -> Double {
        guard item.value > 0, item.value.isFinite else { return 70 }
        return min(100, item.value)
    }

    /// Anomaly detection on one value column, written into `overlays` against the result's rows.
    @discardableResult
    static func anomalies(_ item: AnalyticsItem, data: VisualData, column: Int, into overlays: inout AnalyticsOverlays) -> AnomalyResult {
        let order = axisOrder(data)
        var found = AnalyticsOverlays()
        let result = AnomalyDetector.apply(to: &found, values: values(data, column: column, order: order), seriesColumn: column,
                                           sensitivity: sensitivity(item))
        overlays.anomalies.removeAll { $0.seriesColumn == column }
        for var a in found.anomalies where order.indices.contains(a.row) {
            a.row = order[a.row]
            overlays.anomalies.append(a)
        }
        if let band = found.expectedBands[column], band.count == order.count {
            var byRow = band
            for (i, row) in order.enumerated() where byRow.indices.contains(row) { byRow[row] = band[i] }
            overlays.expectedBands[column] = byRow
        }
        return result
    }
}
