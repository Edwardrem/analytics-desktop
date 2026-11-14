import Foundation

/// High-density sampling for scatter charts. Above `limit` points the chart draws one point for
/// each occupied cell of a grid over the plot (one per legend series in a cell), as coarse a grid
/// as it takes to come in under the limit, plus the points at the extremes of X and Y and every
/// selected point. Overlapping points collapse into one, so the shape of the data, its outliers and
/// the selection all still show, and every point drawn can be hovered and clicked.
enum ScatterSampling {
    static let limit = 4_000
    /// The finest grid tried: 126 × 126 cells, then three quarters as many each way until it fits.
    static let startResolution = 126

    private struct Cell: Hashable { let column: Int, row: Int, series: Int }

    /// The points to draw, in their original order: all of them up to `limit`, otherwise the
    /// sample described above. `keep` marks points that must stay (the selected ones).
    static func sample(_ points: [ScatterModel.Point], limit: Int = limit,
                       keep: (ScatterModel.Point) -> Bool = { _ in false }) -> [ScatterModel.Point] {
        guard limit > 0, points.count > limit,
              let x0 = points.map(\.x).min(), let x1 = points.map(\.x).max(),
              let y0 = points.map(\.y).min(), let y1 = points.map(\.y).max() else { return points }

        var n = startResolution
        var picked: [Int] = []
        while true {
            var seen = Set<Cell>()
            picked.removeAll(keepingCapacity: true)
            for (i, p) in points.enumerated() {
                let cell = Cell(column: slot(p.x, x0, x1, n), row: slot(p.y, y0, y1, n), series: p.series)
                if seen.insert(cell).inserted {
                    picked.append(i)
                    if picked.count > limit { break }
                }
            }
            if picked.count <= limit || n == 1 { break }
            n = max(1, n * 3 / 4)
        }

        var chosen = Set(picked)
        // The first point at each extreme, so the outliers that set the axes are always drawn.
        for i in [first(points, \.x, x0), first(points, \.x, x1), first(points, \.y, y0), first(points, \.y, y1)] {
            if let i { chosen.insert(i) }
        }
        for (i, p) in points.enumerated() where keep(p) { chosen.insert(i) }
        return chosen.sorted().map { points[$0] }
    }

    /// The grid cell (0..<n) a value falls in across lo...hi.
    static func slot(_ v: Double, _ lo: Double, _ hi: Double, _ n: Int) -> Int {
        guard hi > lo, n > 1 else { return 0 }
        return min(n - 1, max(0, Int((v - lo) / (hi - lo) * Double(n))))
    }

    private static func first(_ points: [ScatterModel.Point], _ value: KeyPath<ScatterModel.Point, Double>, _ target: Double) -> Int? {
        points.firstIndex { $0[keyPath: value] == target }
    }

    /// The note on a sampled chart, e.g. "Showing 2,706 of 10,000 points".
    static func note(shown: Int, of total: Int) -> String {
        "Showing \(shown.formatted()) of \(total.formatted()) points"
    }
}
