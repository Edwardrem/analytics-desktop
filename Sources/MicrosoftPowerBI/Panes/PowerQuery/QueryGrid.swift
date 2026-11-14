import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// How a preview cell is written: raw values as Power Query shows them (no grouping, ISO dates, `null`).
enum QueryCellText {
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
    private static let date = formatter("yyyy-MM-dd")
    private static let dateTime = formatter("yyyy-MM-dd HH:mm:ss")
    private static let time = formatter("HH:mm:ss")

    static func text(_ value: Value, type: DataType) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "TRUE" : "FALSE"
        case .int(let i): return String(i)
        case .double(let d):
            if d.isNaN { return "NaN" }
            if d.isInfinite { return d > 0 ? "Infinity" : "-Infinity" }
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(d)
        case .string(let s): return s
        case .date(let d):
            switch type {
            case .date: return date.string(from: d)
            case .time: return time.string(from: d)
            default: return dateTime.string(from: d)
            }
        }
    }

    /// Spaces as middle dots, tabs as arrows and line breaks as ¶ (View ▸ Show whitespace).
    static func visibleWhitespace(_ s: String) -> String {
        var out = ""
        for ch in s {
            switch ch {
            case " ": out.append("·")
            case "\t": out.append("→")
            case "\n", "\r\n", "\r": out.append("¶")
            default: out.append(ch)
            }
        }
        return out
    }

    static func typeSymbol(_ type: DataType) -> String {
        switch type {
        case .text: return "textformat.abc"
        case .integer: return "number"
        case .decimal: return "textformat.123"
        case .currency: return "dollarsign"
        case .boolean: return "checkmark.square"
        case .date: return "calendar"
        case .dateTime: return "calendar.badge.clock"
        case .time: return "clock"
        case .duration: return "timer"
        case .binary: return "doc"
        case .any: return "questionmark.square.dashed"
        }
    }
}

/// The data preview grid of Get Data and the Power Query Editor: column headers with type glyphs, optional
/// profiling strips, column selection, cell errors and structured-cell links.
struct QueryGrid: View {
    let table: DataTable
    var cellErrors: [Int: [Int: String]] = [:]
    var structuredCells: [Int: [Int: String]] = [:]
    var selection: Set<String> = []
    var profiles: [ColumnProfile] = []
    var showQuality = false
    var showDistribution = false
    /// Column name, and whether the selection is being extended (⌘ or ⇧).
    var onSelect: ((String, _ extend: Bool, _ range: Bool) -> Void)?
    /// The header's drop-down (sort and filter), its context menu (transformations) and the type icon's menu.
    var headerMenu: ((String) -> NSMenu?)?
    var contextMenu: ((String) -> NSMenu?)?
    var typeMenu: ((String) -> NSMenu?)?
    /// A structured cell (Table, List, Record) was clicked.
    var onOpenCell: ((_ row: Int, _ column: Int) -> Void)?
    var monospaced = false
    /// Show leading/trailing spaces and line breaks as visible marks.
    var showWhitespace = false

    static let columnWidth: CGFloat = 150
    static let indexWidth: CGFloat = 44

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(0..<table.rowCount, id: \.self) { row in rowView(row) }
                } header: {
                    header
                }
            }
        }
        .background(Design.Palette.elevated)
    }

    private var header: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.indexWidth)
            ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                headerCell(index, column)
            }
        }
        .background(Design.Palette.surface)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder
    private func headerCell(_ index: Int, _ column: DataColumn) -> some View {
        let selected = selection.contains(column.name)
        VStack(alignment: .leading, spacing: Design.Space.xxs) {
            HStack(spacing: Design.Space.xs) {
                if let typeMenu {
                    Button { if let m = typeMenu(column.name) { EditorMenus.popUp(m) } } label: { typeGlyph(column) }
                        .buttonStyle(.plain)
                        .help("\(column.type.displayName): click to change the type")
                } else {
                    typeGlyph(column).help(column.type.displayName)
                }
                Text(column.name).font(Design.Typeface.bodyStrong).lineLimit(1).help(column.name)
                Spacer(minLength: 0)
                if let headerMenu {
                    Button { if let m = headerMenu(column.name) { EditorMenus.popUp(m) } } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .help("Sort or filter this column")
                }
            }
            if let profile = profiles[safe: index] {
                if showQuality { ColumnQualityStrip(profile: profile) }
                if showDistribution { ColumnDistributionStrip(profile: profile) }
            }
        }
        .padding(.horizontal, Design.Space.s).padding(.vertical, Design.Space.xs)
        .frame(width: Self.columnWidth, alignment: .leading)
        .background(selected ? Design.Palette.accent.opacity(0.18) : Color.clear)
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
        .contentShape(Rectangle())
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            onSelect?(column.name, flags.contains(.command), flags.contains(.shift))
        }
        .overlay { if let contextMenu { ContextMenuCatcher { contextMenu(column.name) } } }
    }

    private func typeGlyph(_ column: DataColumn) -> some View {
        Image(systemName: QueryCellText.typeSymbol(column.type))
            .font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
    }

    private func rowView(_ row: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(row + 1)").font(Design.Typeface.caption).foregroundStyle(.tertiary)
                .frame(width: Self.indexWidth - Design.Space.s, alignment: .trailing).padding(.trailing, Design.Space.s)
            ForEach(Array(table.columns.enumerated()), id: \.offset) { index, column in
                cell(row, index, column)
            }
        }
        .frame(height: 22)
        .overlay(alignment: .bottom) { Hairline() }
    }

    @ViewBuilder
    private func cell(_ row: Int, _ index: Int, _ column: DataColumn) -> some View {
        let value = column.values[safe: row] ?? .null
        let numeric = column.type.isNumeric
        Group {
            if let message = cellErrors[index]?[row] {
                Text("Error").foregroundStyle(Design.Palette.negative).help(message)
            } else if let kind = structuredCells[index]?[row] {
                if let onOpenCell, kind != "Function", kind != "Binary" {
                    Button(kind) { onOpenCell(row, index) }.buttonStyle(.link).help("Drill down into this \(kind.lowercased())")
                } else {
                    Text(kind).foregroundStyle(Design.Palette.accent)
                }
            } else if value.isNull {
                Text("null").italic().foregroundStyle(.tertiary)
            } else {
                Text(showWhitespace ? QueryCellText.visibleWhitespace(QueryCellText.text(value, type: column.type)) : QueryCellText.text(value, type: column.type))
            }
        }
        .font(monospaced ? Design.Typeface.mono : Design.Typeface.body).lineLimit(1)
        .padding(.horizontal, Design.Space.s)
        .frame(width: Self.columnWidth, alignment: numeric ? .trailing : .leading)
        .frame(maxHeight: .infinity)
        .background(selection.contains(column.name) ? Design.Palette.accent.opacity(0.07) : Color.clear)
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
    }
}

/// Column quality: a valid / error / empty bar with the three percentages.
struct ColumnQualityStrip: View {
    let profile: ColumnProfile

    var body: some View {
        let shown = profile.qualityPercentages
        VStack(alignment: .leading, spacing: 1) {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Design.Palette.positive.frame(width: geo.size.width * profile.quality.valid)
                    Design.Palette.negative.frame(width: geo.size.width * profile.quality.error)
                    Color.primary.opacity(0.35).frame(width: geo.size.width * profile.quality.empty)
                }
            }
            .frame(height: 3)
            line("Valid", shown.valid, Design.Palette.positive)
            line("Error", shown.error, Design.Palette.negative)
            line("Empty", shown.empty, Color.primary.opacity(0.35))
        }
        .help("\(profile.validCount) valid, \(profile.errorCount) error, \(profile.emptyCount) empty of \(profile.count) rows")
    }

    private func line(_ label: String, _ percent: Int, _ color: Color) -> some View {
        HStack(spacing: Design.Space.xs) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(percent)%").monospacedDigit()
        }
        .font(.system(size: 10))
    }
}

/// Column distribution: a small histogram of value frequencies with the distinct and unique counts.
struct ColumnDistributionStrip: View {
    let profile: ColumnProfile
    static let maxBars = 24

    var body: some View {
        let bars = Array(profile.distribution.prefix(Self.maxBars))
        let top = max(bars.map(\.count).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                    Design.Palette.accent.opacity(0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: max(1, 22 * CGFloat(bar.count) / CGFloat(top)))
                }
            }
            .frame(height: 22, alignment: .bottom)
            Text("\(profile.distinctCount) distinct, \(profile.uniqueCount) unique")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .help("\(profile.distinctCount) distinct values, \(profile.uniqueCount) of them occur once")
    }
}
