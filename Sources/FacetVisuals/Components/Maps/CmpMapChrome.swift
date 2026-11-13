import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// Small pieces shared by the map, choropleth and gantt renderers: tooltip card, legends, hint pill.

/// Content of a hover tooltip: a title and label/value rows.
struct CmpMapTooltipContent: Equatable {
    var title: String
    var rows: [[String]] = []   // [label, value]

    /// Title from `titleColumn`, one row per other visible column of the data row.
    static func forRow(_ row: Int, env: CmpEnv, titleColumn: Int?, skip: Set<Int> = []) -> CmpMapTooltipContent {
        let data = env.data
        var rows: [[String]] = []
        for c in data.table.columns.indices where c != titleColumn && !skip.contains(c) {
            if let f = data.fields[safe: c] ?? nil, f.isHidden { continue }
            let text = data.formatted(row: row, col: c)
            if !text.isEmpty { rows.append([env.caption(c), text]) }
        }
        let title = titleColumn.map { data.formatted(row: row, col: $0) } ?? ""
        return CmpMapTooltipContent(title: title, rows: rows)
    }

    /// Plain-text form for AppKit `toolTip`s and accessibility values.
    var plainText: String {
        ([title] + rows.map { "\($0[0]): \($0[1])" }).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Quiet tooltip card that follows the pointer.
struct CmpMapTooltip: View {
    let content: CmpMapTooltipContent
    let theme: ThemeSpec

    static func estimatedSize(_ c: CmpMapTooltipContent) -> CGSize {
        let titleW = CmpFit.width(c.title, font: .systemFont(ofSize: 12, weight: .semibold))
        let rowW = c.rows.map {
            CmpFit.width($0[0], font: .systemFont(ofSize: 11)) + CmpFit.width($0[1], font: .systemFont(ofSize: 11, weight: .medium)) + 22
        }.max() ?? 0
        let w = min(300, max(titleW, rowW) + 26)
        let h = CGFloat(16 + (c.title.isEmpty ? 0 : 17) + c.rows.count * 16 + (c.rows.isEmpty || c.title.isEmpty ? 0 : 4))
        return CGSize(width: max(60, w), height: h)
    }

    /// Top-left origin that keeps the card near `point` but inside `bounds`.
    static func origin(for c: CmpMapTooltipContent, near point: CGPoint, in bounds: CGRect) -> CGPoint {
        let s = estimatedSize(c)
        var x = point.x + 14, y = point.y + 14
        if x + s.width > bounds.maxX - 2 { x = point.x - s.width - 10 }
        if y + s.height > bounds.maxY - 2 { y = point.y - s.height - 10 }
        return CGPoint(x: max(bounds.minX + 2, min(x, bounds.maxX - s.width - 2)), y: max(bounds.minY + 2, min(y, bounds.maxY - s.height - 2)))
    }

    var body: some View {
        let size = CmpMapTooltip.estimatedSize(content)
        VStack(alignment: .leading, spacing: 4) {
            if !content.title.isEmpty {
                Text(content.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.foregroundColor).lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(content.rows.enumerated()), id: \.offset) { _, r in
                    HStack(spacing: 8) {
                        Text(r[0]).foregroundStyle(theme.secondaryColor).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(r[1]).fontWeight(.medium).foregroundStyle(theme.foregroundColor).lineLimit(1)
                    }
                    .font(.system(size: 11))
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(width: size.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardColor))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(theme.isHighContrast ? theme.foregroundColor : theme.foregroundColor.opacity(0.14), lineWidth: theme.isHighContrast ? 1 : 0.5))
        .shadow(color: .black.opacity(theme.isDark ? 0.45 : 0.14), radius: 8, y: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Categorical legend: swatch + label per entry, single line, truncating.
struct CmpMapCategoryLegend: View {
    let title: String
    let entries: [(label: String, color: Color)]
    let theme: ThemeSpec
    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(showTitle: true)
            row(showTitle: false)
            // Too many entries for the width: keep whole labels and clip the overflow.
            row(showTitle: false).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 14)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: " + entries.map(\.label).joined(separator: ", "))
    }

    private func row(showTitle: Bool) -> some View {
        HStack(spacing: 10) {
            if showTitle, !title.isEmpty {
                Text(title).font(.system(size: theme.label.size, weight: .medium)).foregroundStyle(theme.secondaryColor)
            }
            ForEach(Array(entries.prefix(12).enumerated()), id: \.offset) { _, e in
                HStack(spacing: 4) {
                    Circle().fill(e.color).frame(width: 7, height: 7)
                        .overlay(Circle().strokeBorder(theme.foregroundColor, lineWidth: theme.isHighContrast ? 0.5 : 0))
                    Text(e.label).font(.system(size: theme.label.size)).foregroundStyle(theme.secondaryColor)
                }
            }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// Gradient legend for choropleths: caption, min label, colour ramp, max label.
struct CmpMapGradientLegend: View {
    let title: String
    let minLabel: String
    let maxLabel: String
    let stops: [Color]
    let theme: ThemeSpec
    var body: some View {
        HStack(spacing: 6) {
            if !title.isEmpty {
                Text(title).font(.system(size: theme.label.size, weight: .medium)).foregroundStyle(theme.secondaryColor).lineLimit(1)
                    .fixedSize()
            }
            Text(minLabel).font(.system(size: theme.label.size)).monospacedDigit().foregroundStyle(theme.secondaryColor).lineLimit(1)
                .fixedSize()
            Capsule().fill(LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing))
                .frame(minWidth: 24, maxWidth: 140).frame(height: 6)
                .overlay(Capsule().strokeBorder(theme.foregroundColor.opacity(theme.isHighContrast ? 1 : 0.1), lineWidth: 0.5))
            Text(maxLabel).font(.system(size: theme.label.size)).monospacedDigit().foregroundStyle(theme.secondaryColor).lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .frame(height: 14)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) legend from \(minLabel) to \(maxLabel)")
    }
}

/// Discreet pill used for hints and progress on top of maps.
struct CmpMapPill<Leading: View>: View {
    let text: String
    let theme: ThemeSpec
    @ViewBuilder var leading: () -> Leading
    var body: some View {
        HStack(spacing: 6) {
            leading()
            Text(text).font(.system(size: 11)).foregroundStyle(theme.secondaryColor).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(theme.cardColor.opacity(0.92)))
        .overlay(Capsule().strokeBorder(theme.foregroundColor.opacity(theme.isHighContrast ? 1 : 0.12), lineWidth: 0.5))
        .help(text)
    }
}

/// Borderless 24-pt tool button for map / gantt overlays.
struct CmpMapToolButton: View {
    let systemImage: String
    let help: String
    var isOn = false
    let theme: ThemeSpec
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isOn ? theme.accentColor : theme.foregroundColor.opacity(0.8))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isOn ? theme.accentColor.opacity(0.16) : (hovering ? theme.foregroundColor.opacity(0.1) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// Groups tool buttons on a small card.
struct CmpMapToolbar<Content: View>: View {
    let theme: ThemeSpec
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 1) { content() }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(theme.cardColor.opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.foregroundColor.opacity(theme.isHighContrast ? 1 : 0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

/// Focus rings are drawn only when focus arrived from the keyboard (Tab), not from a click.
enum CmpMapChromeFocus {
    static var arrivedByKeyboard: Bool { NSApp.currentEvent?.type == .keyDown }
}
