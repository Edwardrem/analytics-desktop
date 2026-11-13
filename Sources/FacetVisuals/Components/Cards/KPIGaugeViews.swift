import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// MARK: - KPI

/// Status of an indicator against its goal.
enum CmpKPIStatus { case good, bad, neutral }

/// Pure KPI maths: latest indicator, goal, distance and status.
struct CmpKPIModel {
    var indicator: Value = .null
    var goal: Value = .null
    var series: [Double] = []
    var latestAxisLabel = ""
    /// (indicator − goal) / |goal|.
    var distance: Double?
    var status: CmpKPIStatus = .neutral

    init(data: VisualData, highIsGood: Bool) {
        let n = data.table.rowCount
        guard let vc = data.indices(.values).first ?? data.table.columns.indices.first(where: { data.table.columns[$0].type.isNumeric }), n > 0 else { return }
        // The indicator is the last row with a value (rows arrive ordered by the trend axis).
        let values = data.table.columns[vc].values
        let last = values.lastIndex { !$0.isNull } ?? n - 1
        indicator = values[last]
        series = values.compactMap { $0.isNumber ? $0.asDouble : nil }
        if let ac = data.indices(.trendAxis).first { latestAxisLabel = data.formatted(row: last, col: ac) }
        if let tc = data.indices(.target).first {
            let targets = data.table.columns[tc].values
            goal = targets[last].isNull ? (targets.last { !$0.isNull } ?? .null) : targets[last]
        }
        if let a = indicator.asDouble, let g = goal.asDouble, indicator.isNumber, goal.isNumber {
            if g != 0 { distance = (a - g) / abs(g) }
            status = a == g ? .good : ((a > g) == highIsGood ? .good : .bad)
        }
    }
}

struct CmpKPIView: View {
    let env: CmpEnv

    var body: some View {
        let f = env.f
        let highIsGood = f.string("trend", "direction", "highIsGood") != "lowIsGood"
        let model = CmpKPIModel(data: env.data, highIsGood: highIsGood)
        let style = CmpCardStyle(env: env, defaultAlignment: "center")
        let statusColor: Color = {
            switch model.status {
            case .good: return f.color("trend", "goodColor", env.theme.good)
            case .bad: return f.color("trend", "badColor", env.theme.bad)
            case .neutral: return f.color("trend", "neutralColor", env.theme.accent)
            }
        }()
        let vc = env.data.indices(.values).first ?? 0
        let text = style.text(model.indicator, col: vc)
        let goalText = model.goal.isNull ? nil : style.text(model.goal, col: env.data.indices(.target).first ?? vc)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let showGoal = f.bool("goal", "show", true) && goalText != nil && h >= 46
            let showDate = f.bool("date", "show", true) && !model.latestAxisLabel.isEmpty && h >= 84
            let lineH = style.labelSize * 1.5
            let below = (showGoal ? lineH : 0) + (showDate ? lineH : 0)
            let size = CmpFit.fontSize(text, maxSize: style.calloutSize * (h > 150 ? 1.25 : 1), minSize: 9,
                                       width: w * 0.92, height: max(12, (h - below) * 0.62), weight: style.nsWeight)
            ZStack(alignment: .bottom) {
                if f.bool("trend", "show", true), model.series.count > 1, h >= 44 {
                    CmpTrendArea(values: model.series, color: statusColor)
                        .frame(height: h * (h < 80 ? 0.8 : 0.58))
                        .padding(.horizontal, -1)
                        .accessibilityHidden(true)
                }
                VStack(alignment: style.alignment, spacing: 1) {
                    if showDate {
                        Text(model.latestAxisLabel).font(env.font(style.labelSize)).foregroundStyle(style.labelColor)
                            .lineLimit(1).frame(height: lineH)
                    }
                    Text(text)
                        .font(env.font(size, style.weight))
                        .foregroundStyle(f.bool("indicator", "colorByStatus", false) ? statusColor : style.calloutColor)
                        .lineLimit(1).fixedSize()
                    if showGoal, let goalText {
                        HStack(spacing: 5) {
                            Text("\(f.string("goal", "label", "Goal")) \(goalText)").foregroundStyle(style.labelColor)
                            if f.bool("goal", "showDistance", true), let d = model.distance {
                                HStack(spacing: 2) {
                                    Image(systemName: d > 0 ? "arrow.up.right" : (d < 0 ? "arrow.down.right" : "equal"))
                                        .font(.system(size: style.labelSize * 0.75, weight: .bold))
                                    Text(CmpNumber.signedPercent(d)).fontWeight(.semibold)
                                }
                                .foregroundStyle(statusColor)
                            }
                        }
                        .font(env.font(style.labelSize)).lineLimit(1).minimumScaleFactor(0.7)
                        .frame(height: lineH)
                    }
                }
                .padding(.horizontal, 2)
                .frame(width: w, height: h, alignment: Alignment(horizontal: style.alignment, vertical: h < 80 ? .center : .top))
                .padding(.top, h < 80 ? 0 : max(0, (h * 0.5 - size * 0.6 - (showDate ? lineH : 0)) * 0.55))
            }
            .frame(width: w, height: h)
        }
        .help(helpText(model, vc: vc))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(env.caption(vc))
        .accessibilityValue(helpText(model, vc: vc))
    }

    private func helpText(_ m: CmpKPIModel, vc: Int) -> String {
        var s = ValueFormatter.format(m.indicator, env.data.formats[safe: vc] ?? "")
        if !m.goal.isNull {
            let tc = env.data.indices(.target).first ?? vc
            s += ", goal \(ValueFormatter.format(m.goal, env.data.formats[safe: tc] ?? ""))"
            if let d = m.distance { s += " (\(CmpNumber.signedPercent(d)))" }
            s += m.status == .good ? ", on track" : (m.status == .bad ? ", behind" : "")
        }
        return s
    }
}

/// Quiet area sparkline used behind the KPI indicator.
struct CmpTrendArea: View {
    let values: [Double]
    let color: Color

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = hi - lo
            let top: CGFloat = 4, bottom: CGFloat = 1
            func point(_ i: Int) -> CGPoint {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let t = span > 0 ? (values[i] - lo) / span : 0.5
                // Keep the lowest point a little above the floor so the area never collapses to nothing.
                let y = top + (size.height - top - bottom) * (1 - CGFloat(0.12 + 0.88 * t))
                return CGPoint(x: x, y: y)
            }
            var line = Path()
            line.move(to: point(0))
            for i in 1..<values.count { line.addLine(to: point(i)) }
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.26), color.opacity(0.03)]),
                                                 startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            ctx.stroke(line, with: .color(color.opacity(0.9)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Gauge

/// Pure gauge maths: resolved scale, fill fraction and target fraction.
struct CmpGaugeModel {
    var value: Double?
    var min: Double = 0
    var max: Double = 1
    var target: Double?
    var fraction: Double { fraction(of: value ?? min) }
    var targetFraction: Double? { target.map(fraction(of:)) }

    func fraction(of x: Double) -> Double { max > min ? Swift.max(0, Swift.min(1, (x - min) / (max - min))) : 0 }

    /// Wells win over format constants; without a maximum the scale ends at twice the value (or the target).
    init(data: VisualData, formatMin: Double?, formatMax: Double?, formatTarget: Double?) {
        func first(_ well: Well) -> Double? {
            guard let c = data.indices(well).first, data.table.rowCount > 0 else { return nil }
            let v = data.table[0, c]
            return v.isNumber ? v.asDouble : nil
        }
        value = first(.values)
        target = first(.target) ?? formatTarget
        min = first(.minimum) ?? formatMin ?? Swift.min(0, value ?? 0)
        let reference = Swift.max(abs(value ?? 0), abs(target ?? 0))
        let auto = (value ?? 0) >= 0 ? (reference > 0 ? Swift.max((value ?? 0) * 2, (target ?? 0) * 1.25) : 1) : 0
        max = first(.maximum) ?? formatMax ?? auto
        if max <= min { max = min + 1 }
    }
}

struct CmpGaugeView: View {
    let env: CmpEnv

    var body: some View {
        let f = env.f
        let model = CmpGaugeModel(data: env.data,
                                  formatMin: f.value("gauge", "min")?.doubleValue,
                                  formatMax: f.value("gauge", "max")?.doubleValue,
                                  formatTarget: f.value("gauge", "target")?.doubleValue)
        let style = CmpCardStyle(env: env, defaultAlignment: "center")
        let vc = env.data.indices(.values).first ?? 0
        let fmt = env.data.formats[safe: vc] ?? ""
        let short: (Double) -> String = { CmpNumber.callout(.double($0), format: fmt, units: style.units, decimals: style.decimals) }
        let valueText = model.value.map(short) ?? "—"
        let fillColor = f.color("gauge", "fillColor", env.theme.accent)
        let trackColor = f.value("gauge", "trackColor")?.stringValue.map { Color(hex: $0) } ?? env.fg.opacity(env.theme.isDark ? 0.14 : 0.08)
        let targetColor = f.color("gauge", "targetColor", env.theme.foreground)
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let showLabels = f.bool("gauge", "showLabels", true) && h >= 70 && w >= 110
            let labelH: CGFloat = showLabels ? style.labelSize * 1.5 : 0
            let showTarget = f.bool("gauge", "showTarget", true) && model.targetFraction != nil
            let targetText = model.target.map(short) ?? ""
            let targetLabel = showTarget && h >= 96 && w >= 150
            let targetW = CmpFit.width(targetText, font: env.nsFont(style.labelSize, .medium))
            let topPad: CGFloat = targetLabel ? style.labelSize * 1.5 : 2
            let sidePad: CGFloat = targetLabel ? targetW + 8 : 2
            let radius = max(8, min(w / 2 - sidePad, h - labelH - topPad))
            let thickness = max(4, min(30, radius * CGFloat(f.double("gauge", "thickness", 0.2))))
            let mid = radius - thickness / 2
            let cx = w / 2
            let cy = topPad + radius + max(0, (h - labelH - topPad - radius) / 2)
            ZStack {
                arc(1, radius: mid, lineWidth: thickness, color: trackColor).position(x: cx, y: cy)
                arc(model.fraction, radius: mid, lineWidth: thickness, color: fillColor).position(x: cx, y: cy)
                    .animation(Design.Motion.standard, value: model.fraction)
                if showTarget, let tf = model.targetFraction {
                    let angle = Double.pi * (1 - tf) // π at min (left) … 0 at max (right)
                    let inner = radius - thickness - 3, outer = radius + 3
                    Path { p in
                        p.move(to: CGPoint(x: cx + cos(angle) * inner, y: cy - sin(angle) * inner))
                        p.addLine(to: CGPoint(x: cx + cos(angle) * outer, y: cy - sin(angle) * outer))
                    }
                    .stroke(targetColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    if targetLabel {
                        // Push the label out along the needle so it never touches the arc.
                        let lr = radius + 6
                        Text(targetText).font(env.font(style.labelSize, .medium)).foregroundStyle(env.fg.opacity(0.8))
                            .fixedSize()
                            .position(x: cx + cos(angle) * (lr + targetW / 2 * abs(cos(angle)) + 2),
                                      y: cy - sin(angle) * (lr + style.labelSize * 0.6))
                    }
                }
                if f.bool("gauge", "showCallout", true) {
                    let boxW = max(10, (radius - thickness) * 1.5), boxH = max(10, (radius - thickness) * 0.62)
                    let size = CmpFit.fontSize(valueText, maxSize: style.calloutSize, minSize: 8, width: boxW, height: boxH, weight: style.nsWeight)
                    Text(valueText).font(env.font(size, style.weight)).foregroundStyle(style.calloutColor)
                        .lineLimit(1).fixedSize()
                        .position(x: cx, y: cy - size * 0.52)
                }
                if showLabels {
                    Text(short(model.min)).font(env.font(style.labelSize)).foregroundStyle(style.labelColor).fixedSize()
                        .position(x: cx - mid, y: cy + labelH * 0.62)
                    Text(short(model.max)).font(env.font(style.labelSize)).foregroundStyle(style.labelColor).fixedSize()
                        .position(x: cx + mid, y: cy + labelH * 0.62)
                }
            }
            .frame(width: w, height: h)
        }
        .help(accessibilityValue(model, fmt: fmt))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(env.caption(vc))
        .accessibilityValue(accessibilityValue(model, fmt: fmt))
    }

    /// Upper half-circle stroke from the left end, filled to `fraction`.
    private func arc(_ fraction: Double, radius: CGFloat, lineWidth: CGFloat, color: Color) -> some View {
        Circle().trim(from: 0.5, to: 0.5 + 0.5 * max(0.0001, fraction))
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .butt))
            .frame(width: radius * 2, height: radius * 2)
    }

    private func accessibilityValue(_ m: CmpGaugeModel, fmt: String) -> String {
        func full(_ d: Double) -> String { ValueFormatter.format(.double(d), fmt) }
        var s = m.value.map(full) ?? "(Blank)"
        s += ", scale \(full(m.min)) to \(full(m.max))"
        if let t = m.target { s += ", target \(full(t))" }
        return s
    }
}
