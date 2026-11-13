import Foundation
import FacetCore

// Fitting a ribbon tab into the window, as data. Every group sizes to its content; when the tab is
// wider than the window its groups give way progressively, right to left, the way the Windows
// ribbon does: first the small buttons drop their captions (icon only, with tooltips), then whole
// groups collapse into one drop-down button. `Ribbon.swift` draws exactly the widths computed here,
// so controls can never overlap or run into each other.

/// How a group is drawn at the width it was given.
enum RibbonGroupMode: Equatable {
    /// Every control with its caption.
    case full
    /// Small buttons are icon-only; large ones are unchanged.
    case compact
    /// One drop-down button that lists the group's commands.
    case collapsed
}

/// The sizes the fit works with, in points. `Ribbon.swift` supplies the design tokens.
struct RibbonMetrics: Equatable {
    /// Width of a large button (and of a collapsed group's button).
    var largeWidth: Double = 68
    /// Width of a small button's icon box.
    var smallIcon: Double = 16
    /// Padding on each side of a small button.
    var smallPadding: Double = 4
    /// Gap between a small button's icon and its caption.
    var smallSpacing: Double = 4
    /// Extra caption width for the chevron of a small menu button.
    var menuChevron: Double = 12
    /// Gap between two columns of a group.
    var columnSpacing: Double = 2
    /// Padding on each side of a group.
    var groupPadding: Double = 8
    /// Width of the hairline between two groups.
    var separator: Double = 1
    /// Padding on each side of the whole row.
    var edgePadding: Double = 4
    /// Rounding slack added to every measured caption.
    var slack: Double = 2
}

/// One group as it is to be drawn.
struct RibbonGroupFit: Equatable {
    var mode: RibbonGroupMode
    /// Width of each column of `RibbonLayout.columns(group)`; empty when collapsed.
    var columnWidths: [Double]
    /// Width of the whole group, padding included.
    var width: Double
}

struct RibbonFit {
    var metrics = RibbonMetrics()
    /// Width of a caption in the ribbon's caption font.
    var textWidth: (String) -> Double

    // MARK: Measuring

    static func label(of item: RibbonItem) -> String {
        switch item.control {
        case .button(let c): return c.label
        case .menu(let label, _, _), .visualGallery(let label, _), .overflow(let label, _): return label
        case .registered: return ""
        }
    }
    static func isMenu(_ item: RibbonItem) -> Bool {
        switch item.control {
        case .menu, .visualGallery, .overflow: return true
        case .button, .registered: return false
        }
    }

    /// Width of one small button.
    func smallWidth(_ item: RibbonItem, compact: Bool) -> Double {
        let box = metrics.smallPadding * 2 + metrics.smallIcon
        if compact { return box }
        let caption = textWidth(Self.label(of: item)).rounded(.up) + (Self.isMenu(item) ? metrics.menuChevron : 0)
        return box + metrics.smallSpacing + caption + metrics.slack
    }

    /// Width of each column of a group: a large control, or the widest of a stack of small ones.
    func columnWidths(_ group: RibbonGroup, compact: Bool) -> [Double] {
        RibbonLayout.columns(group).map { column in
            switch column {
            case .large: return metrics.largeWidth
            case .stack(let items): return items.map { smallWidth($0, compact: compact) }.max() ?? 0
            }
        }
    }

    func fit(_ group: RibbonGroup, mode: RibbonGroupMode) -> RibbonGroupFit {
        if mode == .collapsed {
            return RibbonGroupFit(mode: .collapsed, columnWidths: [], width: metrics.largeWidth + metrics.groupPadding * 2)
        }
        let widths = columnWidths(group, compact: mode == .compact)
        let content = widths.reduce(0, +) + metrics.columnSpacing * Double(max(0, widths.count - 1))
        return RibbonGroupFit(mode: mode, columnWidths: widths, width: content + metrics.groupPadding * 2)
    }

    /// Width of a row of groups, with the hairlines between them and the row's own padding.
    func rowWidth(_ fits: [RibbonGroupFit]) -> Double {
        fits.reduce(0) { $0 + $1.width } + metrics.separator * Double(max(0, fits.count - 1)) + metrics.edgePadding * 2
    }

    // MARK: Fitting

    /// The groups of a tab at `available` points. Groups give way from the right: captions of small
    /// buttons first, then whole groups. A group that would not get narrower is left alone. If even
    /// that is too wide (a window narrower than the app allows), the result is the narrowest row and
    /// the ribbon scrolls.
    func fit(_ groups: [RibbonGroup], available: Double) -> [RibbonGroupFit] {
        var fits = groups.map { fit($0, mode: .full) }
        guard available.isFinite, rowWidth(fits) > available else { return fits }
        for mode in [RibbonGroupMode.compact, .collapsed] {
            for i in groups.indices.reversed() {
                let narrower = fit(groups[i], mode: mode)
                guard narrower.width < fits[i].width else { continue }
                fits[i] = narrower
                if rowWidth(fits) <= available { return fits }
            }
        }
        return fits
    }

    // MARK: A collapsed group

    /// The menu a collapsed group drops: its commands in order, nested menus set off by dividers,
    /// and the visual gallery as one entry per visual type.
    static func collapsedEntries(_ group: RibbonGroup) -> [RibbonMenuEntry] {
        var out: [RibbonMenuEntry] = []
        func section(_ entries: [RibbonMenuEntry]) {
            guard !entries.isEmpty else { return }
            if !out.isEmpty, out.last != .divider { out.append(.divider) }
            out += entries
            out.append(.divider)
        }
        for item in group.items {
            switch item.control {
            case .button(let c): out.append(.command(c))
            case .menu(_, _, let entries): section(entries)
            case .visualGallery:
                section(VisualType.allCases.filter { !$0.isPageElement }.map {
                    .command(RibbonCommand(id: RibbonLayout.visualPrefix + $0.rawValue, label: $0.displayName, symbol: ""))
                })
            case .registered, .overflow: break
            }
        }
        while out.last == .divider { out.removeLast() }
        return out
    }

    /// The icon of a collapsed group's button: that of its first control.
    static func collapsedSymbol(_ group: RibbonGroup) -> String {
        for item in group.items {
            switch item.control {
            case .button(let c): if !c.symbol.isEmpty { return c.symbol }
            case .menu(_, let symbol, _), .visualGallery(_, let symbol): if !symbol.isEmpty { return symbol }
            case .registered, .overflow: break
            }
        }
        return RibbonLayout.fallbackSymbol
    }
}
