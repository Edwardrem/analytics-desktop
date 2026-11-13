import SwiftUI
import FacetCore
import FacetDesign

/// Grid of small-multiple panels with a quiet title above each. Honours `format["smallMultiples"]`:
/// `columns`, `rows` (0 = automatic) and `padding`. When rows × columns cannot hold every panel the
/// grid scrolls vertically.
public struct SmallMultiplesGrid<Cell: View>: View {
    let partitions: [SeriesModel.Partition]
    let style: ChartStyle
    let cell: (_ partition: SeriesModel.Partition, _ column: Int) -> Cell

    public init(partitions: [SeriesModel.Partition], style: ChartStyle, @ViewBuilder cell: @escaping (_ partition: SeriesModel.Partition, _ column: Int) -> Cell) {
        self.partitions = partitions; self.style = style; self.cell = cell
    }

    public var body: some View {
        GeometryReader { geo in
            let n = partitions.count
            let f = style.format
            let pad = CGFloat(f.double("smallMultiples", "padding", 14))
            let autoCols = SmallMultiplesLayout.columns(count: n, size: geo.size)
            let cols = max(1, min(n, Int(f.double("smallMultiples", "columns", 0)) > 0 ? Int(f.double("smallMultiples", "columns", 0)) : autoCols))
            let needed = Int(ceil(Double(n) / Double(cols)))
            let wanted = Int(f.double("smallMultiples", "rows", 0))
            let rows = wanted > 0 ? min(wanted, needed) : needed
            let cellH = max(60, (geo.size.height - pad * CGFloat(rows - 1)) / CGFloat(rows))
            let grid = Grid(horizontalSpacing: pad, verticalSpacing: pad) {
                ForEach(0..<needed, id: \.self) { r in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < n {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(partitions[i].title).font(style.font(weight: .medium)).foregroundStyle(style.secondary).lineLimit(1)
                                    cell(partitions[i], c)
                                }
                                .frame(height: cellH)
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel(partitions[i].title)
                            } else { Color.clear.frame(height: cellH) }
                        }
                    }
                }
            }
            if rows < needed { ScrollView(.vertical) { grid } } else { grid }
        }
    }
}

enum SmallMultiplesLayout {
    /// Column count whose panels come closest to a 3:2 aspect ratio, penalising empty cells.
    static func columns(count n: Int, size: CGSize) -> Int {
        guard n > 1, size.width > 0, size.height > 0 else { return 1 }
        var best = 1, bestScore = Double.infinity
        for cols in 1...n {
            let rows = Int(ceil(Double(n) / Double(cols)))
            let w = Double(size.width) / Double(cols), h = Double(size.height) / Double(rows)
            guard w >= 110 || cols == 1 else { continue }
            let score = abs(log((w / max(h, 1)) / 1.5)) + Double(rows * cols - n) * 0.25
            if score < bestScore { bestScore = score; best = cols }
        }
        return best
    }
}
