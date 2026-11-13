import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// MARK: - Model

/// A secondary "reference" value shown under a callout (target-style), with its difference to the callout.
struct CmpCardReference {
    var label: String
    var text: String
    /// (value − reference) / |reference|, when both are numbers and the reference is non-zero.
    var ratio: Double?
}

/// One callout: a big value with its label and optional reference labels.
struct CmpCardCallout: Identifiable {
    var id: Int
    var caption: String
    var text: String
    var fullText: String
    var references: [CmpCardReference] = []
}

/// Resolved callout / label formatting shared by all single-value visuals.
struct CmpCardStyle {
    let env: CmpEnv
    var calloutSize: Double
    var calloutColor: Color
    var weight: Font.Weight
    var nsWeight: NSFont.Weight
    var units: String
    var decimals: Int?
    var alignment: HorizontalAlignment
    var showLabel: Bool
    var labelSize: Double
    var labelColor: Color
    var labelAbove: Bool

    init(env: CmpEnv, defaultAlignment: String = "left", defaultCalloutSize: Double? = nil) {
        self.env = env
        let f = env.f, theme = env.theme
        calloutSize = f.double("callout", "size", defaultCalloutSize ?? theme.callout.size)
        calloutColor = f.color("callout", "color", theme.callout.color ?? theme.foreground)
        let bold = f.bool("callout", "bold", true)
        weight = bold ? .semibold : .regular
        nsWeight = bold ? .semibold : .regular
        units = f.string("callout", "displayUnits", "auto")
        decimals = f.decimals("callout")
        switch f.string("callout", "alignment", defaultAlignment) {
        case "center": alignment = .center
        case "right": alignment = .trailing
        default: alignment = .leading
        }
        showLabel = f.bool("label", "show", true)
        labelSize = f.double("label", "size", theme.label.size)
        labelColor = f.color("label", "color", theme.secondaryForeground)
        labelAbove = f.string("label", "position", "below") == "above"
    }

    var frameAlignment: Alignment { Alignment(horizontal: alignment, vertical: .center) }
    var textAlignment: TextAlignment { alignment == .center ? .center : (alignment == .trailing ? .trailing : .leading) }

    func text(_ v: Value, col: Int) -> String {
        if v.isNull { return "—" }
        return CmpNumber.callout(v, format: env.data.formats[safe: col] ?? "", units: units, decimals: decimals)
    }
    func fullText(_ v: Value, col: Int) -> String {
        v.isNull ? "(Blank)" : ValueFormatter.format(v, env.data.formats[safe: col] ?? "")
    }
}

enum CmpCardModel {
    /// Value columns drawn as callouts, and the reference columns attached to each.
    /// References come from (a) `format["reference"][<callout caption>] = <caption of another column>` and
    /// (b) columns in the `target` role, paired with callouts by position.
    static func callouts(_ env: CmpEnv, style: CmpCardStyle, row: Int) -> [CmpCardCallout] {
        let data = env.data
        var valueCols = data.indices(.values)
        if valueCols.isEmpty {
            valueCols = data.table.columns.indices.filter { !(data.indices(.category).contains($0)) && !(data.indices(.target).contains($0)) }
        }
        valueCols = valueCols.filter { !((data.fields[safe: $0] ?? nil)?.isHidden ?? false) }
        let refMap = env.f.spec.format["reference"] ?? env.theme.visualDefaults[env.spec.type.rawValue]?["reference"] ?? [:]
        func column(captioned c: String) -> Int? {
            data.table.columns.indices.first { env.caption($0) == c || data.table.columns[$0].name == c }
        }
        let referenceCols = Set(refMap.values.compactMap { $0.stringValue }.compactMap(column(captioned:)))
        let shown = valueCols.filter { !referenceCols.contains($0) }
        let targets = data.indices(.target)
        let hasRow = row < data.table.rowCount
        return shown.enumerated().map { k, col in
            let v: Value = hasRow ? data.table[row, col] : .null
            var refs: [CmpCardReference] = []
            var refCols: [Int] = []
            if let name = refMap[env.caption(col)]?.stringValue, let rc = column(captioned: name) { refCols.append(rc) }
            if let t = targets[safe: k], !refCols.contains(t) { refCols.append(t) }
            for rc in refCols {
                let rv: Value = hasRow ? data.table[row, rc] : .null
                var ratio: Double?
                if let a = v.asDouble, let b = rv.asDouble, v.isNumber, rv.isNumber, b != 0 { ratio = (a - b) / abs(b) }
                refs.append(CmpCardReference(label: env.caption(rc), text: style.text(rv, col: rc), ratio: ratio))
            }
            return CmpCardCallout(id: col, caption: env.caption(col), text: style.text(v, col: col),
                                  fullText: style.fullText(v, col: col), references: refs)
        }
    }
}

// MARK: - Callout cell

/// A value that always fits its box: big number, label, optional title and reference labels.
struct CmpCalloutCell: View {
    let env: CmpEnv
    let style: CmpCardStyle
    let callout: CmpCardCallout
    var title: String? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let showLabel = style.showLabel && h >= 38 && !callout.caption.isEmpty
            let showTitle = title != nil && h >= 38
            let refSize = max(10, style.labelSize)
            let refLine = refSize * 1.45
            let labelH = showLabel ? style.labelSize * 1.35 : 0
            let titleH = showTitle ? style.labelSize * 1.5 : 0
            let showRefs = env.f.bool("referenceLabels", "show", true) && w >= 84
            let refCount = showRefs ? max(0, min(callout.references.count, Int((h - labelH - titleH - 30) / refLine))) : 0
            let refsH = CGFloat(refCount) * refLine + (refCount > 0 ? 4 : 0)
            let valueH = max(10, h - labelH - titleH - refsH - 2)
            let size = CmpFit.fontSize(callout.text, maxSize: style.calloutSize, minSize: 8, width: w, height: valueH, weight: style.nsWeight)
            VStack(alignment: style.alignment, spacing: 0) {
                if showTitle, let title {
                    Text(title).font(env.font(style.labelSize, .semibold)).foregroundStyle(env.fg.opacity(0.8))
                        .lineLimit(1).frame(height: titleH, alignment: .top)
                }
                if showLabel && style.labelAbove { label.frame(height: labelH) }
                Text(callout.text)
                    .font(env.font(size, style.weight))
                    .foregroundStyle(style.calloutColor)
                    .lineLimit(1).fixedSize()
                    .contentTransition(.numericText())
                if showLabel && !style.labelAbove { label.frame(height: labelH) }
                if refCount > 0 {
                    VStack(alignment: style.alignment, spacing: 0) {
                        ForEach(0..<refCount, id: \.self) { i in
                            referenceLine(callout.references[i], size: refSize).frame(height: refLine)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .frame(width: w, height: h, alignment: style.frameAlignment)
        }
        .help("\(callout.caption): \(callout.fullText)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title.map { "\($0), \(callout.caption)" } ?? callout.caption)
        .accessibilityValue(accessibilityValue)
    }

    private var label: some View {
        Text(callout.caption).font(env.font(style.labelSize)).foregroundStyle(style.labelColor).lineLimit(1)
    }

    private var accessibilityValue: String {
        var s = callout.fullText
        for r in callout.references {
            s += ", \(r.label) \(r.text)"
            if let ratio = r.ratio { s += ", \(CmpNumber.signedPercent(ratio)) difference" }
        }
        return s
    }

    private func referenceLine(_ r: CmpCardReference, size: Double) -> some View {
        let higherIsBetter = env.f.bool("referenceLabels", "higherIsBetter", true)
        let showDiff = env.f.bool("referenceLabels", "showDifference", true)
        return HStack(spacing: 4) {
            Text(r.label).foregroundStyle(style.labelColor).truncationMode(.tail).layoutPriority(-1)
            Text(r.text).foregroundStyle(env.fg.opacity(0.85)).fontWeight(.medium).fixedSize()
            if showDiff, let ratio = r.ratio {
                let good = (ratio >= 0) == higherIsBetter
                let color = ratio == 0 ? Color(hex: env.theme.neutral) : Color(hex: good ? env.theme.good : env.theme.bad)
                HStack(spacing: 2) {
                    Image(systemName: ratio > 0 ? "arrow.up.right" : (ratio < 0 ? "arrow.down.right" : "minus"))
                        .font(.system(size: size * 0.72, weight: .bold))
                    Text(CmpNumber.signedPercent(ratio)).fontWeight(.medium)
                }
                .foregroundStyle(color)
                .fixedSize()
            }
        }
        .font(env.font(size))
        .lineLimit(1)
    }
}

// MARK: - Callout group (several callouts side by side / stacked)

struct CmpCalloutGroup: View {
    let env: CmpEnv
    let style: CmpCardStyle
    let callouts: [CmpCardCallout]
    var title: String? = nil
    /// Inside a small-multiple tile: the category title outranks the measure labels when space is tight.
    var isTile = false

    var body: some View {
        GeometryReader { geo in
            let n = max(1, callouts.count)
            let w = geo.size.width, h = geo.size.height
            let titleH: CGFloat = title != nil && h >= (isTile ? 30 : 52) ? style.labelSize * 1.6 : 0
            let orientation = resolvedOrientation(n: n, w: w, h: h - titleH)
            let dividers = env.f.bool("layout", "dividers", !env.f.bool("accentBar", "show", false)) && !isTile
            let gap = CGFloat(env.f.double("layout", "spacing", 16))
            VStack(alignment: .leading, spacing: 0) {
                if titleH > 0, let title {
                    Text(title).font(env.font(style.labelSize, .semibold)).foregroundStyle(env.fg.opacity(0.85))
                        .lineLimit(1).frame(maxWidth: .infinity, minHeight: titleH, maxHeight: titleH, alignment: style.frameAlignment)
                        .help(title)
                }
                if orientation == "vertical" {
                    let cellH = (h - titleH - gap * CGFloat(n - 1)) / CGFloat(n)
                    VStack(spacing: 0) {
                        ForEach(Array(callouts.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { separator(vertical: false, show: dividers).frame(height: gap) }
                            cell(c).frame(height: max(8, cellH))
                        }
                    }
                } else {
                    let cellW = (w - gap * CGFloat(n - 1)) / CGFloat(n)
                    HStack(spacing: 0) {
                        ForEach(Array(callouts.enumerated()), id: \.element.id) { i, c in
                            if i > 0 { separator(vertical: true, show: dividers).frame(width: gap) }
                            cell(c).frame(width: max(8, cellW))
                        }
                    }
                }
            }
        }
    }

    private func resolvedOrientation(n: Int, w: CGFloat, h: CGFloat) -> String {
        let o = env.f.string("layout", "orientation", "auto")
        if o == "horizontal" || o == "vertical" { return o }
        if n == 1 { return "horizontal" }
        if w / CGFloat(n) >= 92 { return "horizontal" }
        return h / CGFloat(n) >= 30 ? "vertical" : "horizontal"
    }

    @ViewBuilder private func cell(_ c: CmpCardCallout) -> some View {
        let showBar = env.f.bool("accentBar", "show", false) && !isTile
        HStack(spacing: 0) {
            if showBar {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(env.f.color("accentBar", "color", env.theme.accent))
                    .frame(width: CGFloat(env.f.double("accentBar", "width", 3)))
                    .padding(.vertical, 2).padding(.trailing, 10)
            }
            CmpCalloutCell(env: env, style: style, callout: c)
        }
    }

    @ViewBuilder private func separator(vertical: Bool, show: Bool) -> some View {
        ZStack {
            Color.clear
            if show {
                Rectangle().fill(env.grid)
                    .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
                    .padding(vertical ? .vertical : .horizontal, 2)
            }
        }
    }
}

// MARK: - Card (new)

/// The new card: several callouts with reference labels, accent bar, optional image; with a `category`
/// field it becomes a grid of small cards, one per category value, that select like data points.
struct CmpCardView: View {
    let env: CmpEnv

    var body: some View {
        let style = CmpCardStyle(env: env)
        let cats = env.data.indices(.category)
        if !cats.isEmpty, env.data.table.rowCount > 0 {
            smallMultiples(style: style, cats: cats)
        } else {
            HStack(spacing: 12) {
                CmpCardImage(env: env)
                CmpCalloutGroup(env: env, style: style, callouts: CmpCardModel.callouts(env, style: style, row: 0))
            }
        }
    }

    private func smallMultiples(style: CmpCardStyle, cats: [Int]) -> some View {
        GeometryReader { geo in
            let n = env.data.table.rowCount
            let gap: CGFloat = CGFloat(env.f.double("layout", "spacing", 8))
            let cols = min(columns(n: n, size: geo.size), max(1, Int((geo.size.width + gap) / (92 + gap))))
            let rows = Int(ceil(Double(n) / Double(cols)))
            let minTile: CGFloat = 58
            let fitH = (geo.size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let tileH = max(minTile, fitH)
            let tileW = (geo.size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let grid = VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            let i = r * cols + c
                            if i < n { tile(row: i, style: style, cats: cats).frame(width: tileW, height: tileH) }
                            else { Color.clear.frame(width: tileW, height: tileH) }
                        }
                    }
                }
            }
            if tileH > fitH + 0.5 {
                ScrollView(.vertical) { grid }
            } else { grid }
        }
    }

    private func tileStyle(_ style: CmpCardStyle) -> CmpCardStyle {
        var s = style
        s.calloutSize = env.f.double("callout", "size", min(env.theme.callout.size, 24))
        return s
    }

    private func columns(n: Int, size: CGSize) -> Int {
        if let c = FormatNumber.int(env.f.value("layout", "columns")?.doubleValue, in: 0...100), c >= 1 { return min(n, c) }
        guard size.height > 0 else { return n }
        // Aim for tiles about 1.7× wider than tall.
        let ideal = (Double(n) * Double(size.width) / Double(size.height) / 1.7).squareRoot()
        return max(1, min(n, Int(ideal.rounded())))
    }

    @ViewBuilder private func tile(row: Int, style: CmpCardStyle, cats: [Int]) -> some View {
        let title = cats.map { env.data.formatted(row: row, col: $0) }.joined(separator: " · ")
        let point = CmpSelection.point(env.data, row: row, columns: cats)
        let selected = point.map { env.context.isSelected($0) } ?? false
        let radius = CGFloat(env.f.double("cards", "radius", 8))
        let showBar = env.f.bool("accentBar", "show", true)
        let tileStyle = tileStyle(style)
        HStack(spacing: 0) {
            if showBar {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(env.f.color("accentBar", "color", env.theme.accent))
                    .frame(width: CGFloat(env.f.double("accentBar", "width", 3)))
                    .padding(.trailing, 9)
            }
            CmpCalloutGroup(env: env, style: tileStyle, callouts: CmpCardModel.callouts(env, style: tileStyle, row: row),
                            title: title.isEmpty ? "(Blank)" : title, isTile: true)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(env.f.bool("cards", "background", true) ? (selected ? env.selectionFill : env.subtleFill) : .clear))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .strokeBorder(selected ? env.accent : (env.f.bool("cards", "border", env.theme.isHighContrast) ? env.grid : .clear),
                          lineWidth: selected ? 1.5 : 1))
        .opacity(point.map { env.context.emphasis($0) } ?? 1)
        .contentShape(Rectangle())
        .onTapGesture {
            guard env.isInteractive, let point else { return }
            let additive = NSEvent.modifierFlags.contains(.command)
            if selected && !additive { env.context.onSelect([], false) } else { env.context.onSelect([point], additive) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .animation(Design.Motion.quick, value: selected)
    }
}

/// Optional card image: `spec.imageData`, or `format["image"]["url"]` (http(s), file or data URI).
struct CmpCardImage: View {
    let env: CmpEnv
    var body: some View {
        if env.f.bool("image", "show", env.spec.imageData != nil) {
            let size = CGFloat(env.f.double("image", "size", 36))
            GeometryReader { geo in
                let s = min(size, geo.size.height)
                CmpImageSource(data: env.spec.imageData, reference: env.f.string("image", "url", ""), scaling: "fit", theme: env.theme)
                    .frame(width: s, height: s)
                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(env.f.double("image", "radius", 6)), style: .continuous))
                    .frame(width: s, height: geo.size.height)
            }
            .frame(width: size)
            .accessibilityHidden(true)
        }
    }
}

// MARK: - Card (classic)

/// One big number with its label.
struct CmpCardLegacyView: View {
    let env: CmpEnv
    var body: some View {
        let style = CmpCardStyle(env: env, defaultAlignment: "center")
        let callout = CmpCardModel.callouts(env, style: style, row: 0).first
            ?? CmpCardCallout(id: 0, caption: "", text: "—", fullText: "(Blank)")
        CmpCalloutCell(env: env, style: style, callout: callout)
    }
}

// MARK: - Multi-row card

/// One "card row" per data row: an accent bar, an optional title (first grouping column) and each
/// remaining field as value-over-label, flowing left to right.
struct CmpMultiRowCardView: View {
    let env: CmpEnv

    var body: some View {
        let data = env.data
        let cols = Array(data.table.columns.indices).filter { !((data.fields[safe: $0] ?? nil)?.isHidden ?? false) }
        let titleCol = cols.count > 1 ? cols.first { c in (data.fields[safe: c] ?? nil).map { !$0.isAggregate } ?? false } : nil
        let fieldCols = cols.filter { $0 != titleCol }
        let style = CmpCardStyle(env: env, defaultCalloutSize: 17)
        let showBar = env.f.bool("accentBar", "show", true)
        let dividers = env.f.bool("layout", "dividers", true)
        let titleSize = env.f.double("categoryTitle", "size", 13)
        GeometryReader { geo in
            let compact = geo.size.height < 90
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<data.table.rowCount, id: \.self) { row in
                        if row > 0, dividers { Rectangle().fill(env.grid).frame(height: 1) }
                        HStack(alignment: .top, spacing: 0) {
                            if showBar {
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(env.f.color("accentBar", "color", env.theme.accent))
                                    .frame(width: CGFloat(env.f.double("accentBar", "width", 3)))
                                    .padding(.trailing, 10)
                            }
                            VStack(alignment: .leading, spacing: compact ? 3 : 6) {
                                if let titleCol {
                                    let t = data.formatted(row: row, col: titleCol)
                                    Text(t.isEmpty ? "(Blank)" : t)
                                        .font(env.font(titleSize, .semibold))
                                        .foregroundStyle(env.f.color("categoryTitle", "color", env.theme.foreground))
                                        .lineLimit(1).help(t)
                                }
                                CmpFlow(spacing: 12, lineSpacing: 6) {
                                    ForEach(fieldCols, id: \.self) { c in
                                        field(row: row, col: c, style: style, width: geo.size.width)
                                            .frame(width: fieldWidth(geo.size.width - (showBar ? 13 : 0), count: fieldCols.count), alignment: .leading)
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, compact ? 6 : 10)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    /// Equal field columns so values line up from row to row; wraps when they can't all fit.
    private func fieldWidth(_ available: CGFloat, count: Int) -> CGFloat {
        let n = CGFloat(max(1, count))
        let even = (available - 12 * (n - 1)) / n
        return even >= 68 ? min(even, 150) : max(60, min(110, (available - 12) / 2))
    }

    private func field(row: Int, col: Int, style: CmpCardStyle, width: CGFloat) -> some View {
        let v = env.data.table[row, col]
        let isNumber = v.isNumber
        let text = isNumber ? style.text(v, col: col) : (v.isNull ? "—" : env.data.formatted(row: row, col: col))
        let size = min(style.calloutSize, max(11, Double(width) / 14))
        return VStack(alignment: .leading, spacing: 1) {
            Text(text).font(env.font(size, style.weight)).foregroundStyle(style.calloutColor).lineLimit(1)
            if style.showLabel {
                Text(env.caption(col)).font(env.font(style.labelSize)).foregroundStyle(style.labelColor).lineLimit(1)
            }
        }
        .help("\(env.caption(col)): \(style.fullText(v, col: col))")
    }
}

/// Minimal left-to-right wrapping layout.
struct CmpFlow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (i, p) in result.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxX: CGFloat = 0
        var points: [CGPoint] = []
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += lineH + lineSpacing; lineH = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineH = max(lineH, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + lineH), points)
    }
}
