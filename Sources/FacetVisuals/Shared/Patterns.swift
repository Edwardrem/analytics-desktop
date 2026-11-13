import SwiftUI
import Charts
import FacetCore
import FacetDesign

/// Fill patterns layered over coloured marks so series can be told apart without colour
/// (enabled by `format["accessibility"]["patterns"]`).
public enum ChartPattern: Int, CaseIterable, Sendable {
    case solid, diagonal, dots, horizontal, crosshatch, backDiagonal, vertical, grid

    /// Pattern for the n-th series; cycles after eight.
    public static func forSeries(_ i: Int) -> ChartPattern {
        allCases[((i % allCases.count) + allCases.count) % allCases.count]
    }

    /// Strokes the pattern inside `clip`. Use a knock-out colour (the card background at partial
    /// opacity) so the pattern reads on any series colour.
    public func draw(in context: GraphicsContext, clip: Path, color: Color, spacing: CGFloat = 5) {
        guard self != .solid else { return }
        var ctx = context
        ctx.clip(to: clip)
        let b = clip.boundingRect.insetBy(dx: -1, dy: -1)
        guard b.width > 0, b.height > 0, b.width < 20_000, b.height < 20_000 else { return }
        var p = Path()
        func diag(_ forward: Bool) {
            var x = b.minX - b.height
            while x < b.maxX {
                if forward { p.move(to: CGPoint(x: x, y: b.maxY)); p.addLine(to: CGPoint(x: x + b.height, y: b.minY)) }
                else { p.move(to: CGPoint(x: x, y: b.minY)); p.addLine(to: CGPoint(x: x + b.height, y: b.maxY)) }
                x += spacing
            }
        }
        func horizontal() {
            var y = b.minY + spacing / 2
            while y < b.maxY { p.move(to: CGPoint(x: b.minX, y: y)); p.addLine(to: CGPoint(x: b.maxX, y: y)); y += spacing }
        }
        func vertical() {
            var x = b.minX + spacing / 2
            while x < b.maxX { p.move(to: CGPoint(x: x, y: b.minY)); p.addLine(to: CGPoint(x: x, y: b.maxY)); x += spacing }
        }
        switch self {
        case .solid: return
        case .diagonal: diag(true)
        case .backDiagonal: diag(false)
        case .crosshatch: diag(true); diag(false)
        case .horizontal: horizontal()
        case .vertical: vertical()
        case .grid: horizontal(); vertical()
        case .dots:
            var y = b.minY + spacing / 2, odd = false
            while y < b.maxY {
                var x = b.minX + (odd ? spacing : spacing / 2)
                while x < b.maxX { p.addEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)); x += spacing }
                y += spacing; odd.toggle()
            }
            ctx.fill(p, with: .color(color))
            return
        }
        ctx.stroke(p, with: .color(color), lineWidth: 1)
    }
}

/// Marker shapes for lines, scatter points and legend swatches.
public enum MarkerShape: String, CaseIterable, Sendable {
    case circle, square, diamond, triangle, cross, plus, pentagon, asterisk
    /// Legend swatch for bars and areas.
    case roundedSquare

    static let cycle: [MarkerShape] = [.circle, .square, .diamond, .triangle, .cross, .plus, .pentagon, .asterisk]

    /// Marker for the n-th series; cycles after eight.
    public static func forSeries(_ i: Int) -> MarkerShape { cycle[((i % cycle.count) + cycle.count) % cycle.count] }

    /// True for shapes drawn as strokes rather than fills.
    public var isStroked: Bool { self == .cross || self == .plus || self == .asterisk }

    /// The equivalent Swift Charts symbol.
    public var symbol: BasicChartSymbolShape {
        switch self {
        case .circle: return .circle
        case .square, .roundedSquare: return .square
        case .diamond: return .diamond
        case .triangle: return .triangle
        case .cross: return .cross
        case .plus: return .plus
        case .pentagon: return .pentagon
        case .asterisk: return .asterisk
        }
    }

    public func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), w = r.width / 2, h = r.height / 2
        var p = Path()
        switch self {
        case .circle: p.addEllipse(in: r)
        case .square: p.addRect(r.insetBy(dx: r.width * 0.07, dy: r.height * 0.07))
        case .roundedSquare: p.addRoundedRect(in: r, cornerSize: CGSize(width: r.width * 0.28, height: r.width * 0.28), style: .continuous)
        case .diamond:
            p.move(to: CGPoint(x: c.x, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: c.y))
            p.addLine(to: CGPoint(x: c.x, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: c.y)); p.closeSubpath()
        case .triangle:
            p.move(to: CGPoint(x: c.x, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath()
        case .pentagon:
            for i in 0..<5 {
                let a = -Double.pi / 2 + Double(i) * 2 * .pi / 5
                let pt = CGPoint(x: c.x + w * cos(a), y: c.y + h * sin(a))
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        case .cross:
            p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.move(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        case .plus:
            p.move(to: CGPoint(x: c.x, y: r.minY)); p.addLine(to: CGPoint(x: c.x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: c.y)); p.addLine(to: CGPoint(x: r.maxX, y: c.y))
        case .asterisk:
            for i in 0..<3 {
                let a = Double(i) * .pi / 3 + .pi / 2
                p.move(to: CGPoint(x: c.x + w * cos(a), y: c.y + h * sin(a)))
                p.addLine(to: CGPoint(x: c.x - w * cos(a), y: c.y - h * sin(a)))
            }
        }
        return p
    }

    /// Draws the marker centred at `center` into a canvas.
    public func draw(in ctx: GraphicsContext, center: CGPoint, size: CGFloat, color: Color) {
        let p = path(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
        if isStroked { ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: max(1.5, size / 5), lineCap: .round)) }
        else { ctx.fill(p, with: .color(color)) }
    }
}

/// A marker as a SwiftUI view (legend swatches, tooltips).
public struct MarkerView: View {
    let shape: MarkerShape
    let color: Color
    let size: CGFloat
    public init(shape: MarkerShape, color: Color, size: CGFloat = 8) { self.shape = shape; self.color = color; self.size = size }
    public var body: some View {
        Canvas { ctx, sz in
            shape.draw(in: ctx, center: CGPoint(x: sz.width / 2, y: sz.height / 2), size: min(sz.width, sz.height), color: color)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Data labels

/// One label ready to draw: its text, frame and optional leader line back to the mark.
public struct PlacedLabel {
    public var text: String
    public var rect: CGRect
    public var color: Color
    public var leader: (from: CGPoint, to: CGPoint)?
}

/// Greedy collision-avoiding label placement. Offer each label a list of candidate centres in order
/// of preference; the first that fits inside `bounds` without touching an earlier label wins.
public struct DataLabelPlacer {
    public let bounds: CGRect
    public let fontSize: CGFloat
    public var weight: NSFont.Weight = .regular
    public private(set) var placed: [PlacedLabel] = []
    private var occupied: [CGRect] = []

    public init(bounds: CGRect, fontSize: CGFloat, weight: NSFont.Weight = .regular) {
        self.bounds = bounds; self.fontSize = fontSize; self.weight = weight
    }

    /// Reserve an area labels must avoid (e.g. a legend or another mark).
    public mutating func reserve(_ r: CGRect) { occupied.append(r) }

    /// Tries each candidate centre; returns the frame used, or nil when none fits (the label is dropped).
    @discardableResult
    public mutating func place(_ text: String, color: Color, candidates: [CGPoint], leaderFrom: CGPoint? = nil, padding: CGFloat = 2) -> CGRect? {
        guard !text.isEmpty else { return nil }
        let sz = ChartText.size(text, fontSize: fontSize, weight: weight)
        for c in candidates {
            let r = CGRect(x: c.x - sz.width / 2, y: c.y - sz.height / 2, width: sz.width, height: sz.height)
            let padded = r.insetBy(dx: -padding, dy: -padding / 2)
            guard bounds.insetBy(dx: -0.5, dy: -0.5).contains(r), !occupied.contains(where: { $0.intersects(padded) }) else { continue }
            occupied.append(padded)
            placed.append(PlacedLabel(text: text, rect: r, color: color, leader: leaderFrom.map { ($0, CGPoint(x: r.midX, y: r.midY)) }))
            return r
        }
        return nil
    }

    /// Draws every placed label (and leader lines) into a canvas.
    public func draw(in ctx: GraphicsContext, leaderColor: Color) {
        for l in placed {
            if let ld = l.leader {
                var p = Path()
                p.move(to: ld.from)
                // Stop the leader at the label's edge.
                let target = CGPoint(x: min(max(ld.from.x, l.rect.minX), l.rect.maxX), y: min(max(ld.from.y, l.rect.minY), l.rect.maxY))
                p.addLine(to: target)
                ctx.stroke(p, with: .color(leaderColor), lineWidth: 0.5)
            }
            let t = Text(l.text).font(.system(size: fontSize, weight: weight == .regular ? .regular : .medium)).foregroundColor(l.color)
            ctx.draw(t, at: CGPoint(x: l.rect.midX, y: l.rect.midY), anchor: .center)
        }
    }
}

/// Positions for a label relative to a bar-like rectangle.
public enum DataLabelPosition: String, CaseIterable, Sendable {
    case auto, outsideEnd, insideEnd, insideCenter, insideBase

    /// Candidate centres for a label of `size` on `bar`. `end` is the edge the value grows towards.
    public func candidates(bar: CGRect, size: CGSize, end: Edge, gap: CGFloat = 3) -> [CGPoint] {
        func outside() -> CGPoint {
            switch end {
            case .top: return CGPoint(x: bar.midX, y: bar.minY - gap - size.height / 2)
            case .bottom: return CGPoint(x: bar.midX, y: bar.maxY + gap + size.height / 2)
            case .trailing: return CGPoint(x: bar.maxX + gap + size.width / 2, y: bar.midY)
            case .leading: return CGPoint(x: bar.minX - gap - size.width / 2, y: bar.midY)
            }
        }
        let vertical = end == .top || end == .bottom
        let fits = vertical ? (bar.height >= size.height + 4 && bar.width >= size.width - 2) : (bar.width >= size.width + 6 && bar.height >= size.height - 2)
        func inside(_ t: CGFloat) -> CGPoint? {
            guard fits else { return nil }
            switch end {
            case .top: return CGPoint(x: bar.midX, y: bar.minY + gap + size.height / 2 + t * (bar.height - size.height - 2 * gap))
            case .bottom: return CGPoint(x: bar.midX, y: bar.maxY - gap - size.height / 2 - t * (bar.height - size.height - 2 * gap))
            case .trailing: return CGPoint(x: bar.maxX - gap - size.width / 2 - t * (bar.width - size.width - 2 * gap), y: bar.midY)
            case .leading: return CGPoint(x: bar.minX + gap + size.width / 2 + t * (bar.width - size.width - 2 * gap), y: bar.midY)
            }
        }
        switch self {
        case .auto, .outsideEnd: return [outside()] + [inside(0)].compactMap { $0 }
        case .insideEnd: return [inside(0)].compactMap { $0 }
        case .insideCenter: return [inside(0.5)].compactMap { $0 }
        case .insideBase: return [inside(1)].compactMap { $0 }
        }
    }
}
