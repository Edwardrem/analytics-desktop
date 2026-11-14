import XCTest
import FacetCore
import SwiftUI
import FacetDesign
@testable import MicrosoftPowerBI

/// Fitting the ribbon into the window: groups size to their content and give way from the right,
/// captions first, then whole groups. Widths below are worked by hand with a 7-pt-per-character
/// caption and the default metrics: a small button is 4 + 16 + 4 (icon box) + 4 (gap) + caption + 2
/// (slack) = 30 + 7n, 12 more with a menu chevron, and 24 icon-only; a large button is 68; a group
/// adds 8 of padding each side and 2 between columns; a row adds 1 per hairline and 4 each side.
@MainActor
final class RibbonFitTests: XCTestCase {
    private let fit = RibbonFit(textWidth: { Double($0.count) * 7 })

    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func button(_ label: String, _ size: RibbonItem.Size) -> RibbonItem {
        RibbonItem(control: .button(RibbonCommand(id: "x." + label, label: label, symbol: "circle")), size: size)
    }
    private func menu(_ label: String, _ size: RibbonItem.Size, _ ids: [String]) -> RibbonItem {
        RibbonItem(control: .menu(label: label, symbol: "square", entries: ids.map {
            .command(RibbonCommand(id: $0, label: $0, symbol: ""))
        }), size: size)
    }
    /// One large button, then a stack of "abcd" (58), "ab" (44) and a menu "abc" (63).
    private var group: RibbonGroup {
        RibbonGroup(title: "G", items: [button("big", .large), button("abcd", .small), button("ab", .small), menu("abc", .small, ["m.one"])])
    }

    func testSmallButtonWidths() {
        XCTAssertEqual(fit.smallWidth(button("abcd", .small), compact: false), 58)
        XCTAssertEqual(fit.smallWidth(menu("abc", .small, []), compact: false), 63)
        XCTAssertEqual(fit.smallWidth(button("abcd", .small), compact: true), 24)
        XCTAssertEqual(fit.smallWidth(menu("abc", .small, []), compact: true), 24)
    }

    func testAGroupIsAsWideAsItsContent() {
        // The stack is as wide as its widest button, so no caption can run into the next column.
        XCTAssertEqual(fit.fit(group, mode: .full), RibbonGroupFit(mode: .full, columnWidths: [68, 63], width: 68 + 2 + 63 + 16))
        XCTAssertEqual(fit.fit(group, mode: .compact), RibbonGroupFit(mode: .compact, columnWidths: [68, 24], width: 68 + 2 + 24 + 16))
        XCTAssertEqual(fit.fit(group, mode: .collapsed), RibbonGroupFit(mode: .collapsed, columnWidths: [], width: 84))
        // Four small buttons make two columns: "abcd", "ab", "abcdef" (72) and then "a" (37).
        let two = RibbonGroup(title: "G", items: ["abcd", "ab", "abcdef", "a"].map { button($0, .small) })
        XCTAssertEqual(fit.fit(two, mode: .full).columnWidths, [72, 37])
        XCTAssertEqual(fit.fit(two, mode: .full).width, 72 + 2 + 37 + 16)
        XCTAssertEqual(fit.rowWidth([fit.fit(group, mode: .full), fit.fit(group, mode: .full)]), 149 + 149 + 1 + 8)
    }

    func testGroupsGiveWayFromTheRightCaptionsFirst() {
        let groups = [group, group]
        func modes(_ available: Double) -> [RibbonGroupMode] { fit.fit(groups, available: available).map(\.mode) }
        XCTAssertEqual(modes(.infinity), [.full, .full])
        XCTAssertEqual(modes(307), [.full, .full])                  // 149 + 149 + 9
        XCTAssertEqual(modes(306), [.full, .compact])               // 149 + 110 + 9 = 268
        XCTAssertEqual(modes(268), [.full, .compact])
        XCTAssertEqual(modes(267), [.compact, .compact])            // 110 + 110 + 9 = 229
        XCTAssertEqual(modes(228), [.compact, .collapsed])          // 110 + 84 + 9 = 203
        XCTAssertEqual(modes(202), [.collapsed, .collapsed])        // 84 + 84 + 9 = 177
        // Narrower than everything collapsed: the narrowest row, and the ribbon scrolls.
        XCTAssertEqual(modes(100), [.collapsed, .collapsed])
        XCTAssertEqual(modes(.nan), [.full, .full])
    }

    func testAGroupThatWouldNotGetNarrowerIsLeftAlone() {
        let single = RibbonGroup(title: "One", items: [button("big", .large)])
        let larges = RibbonGroup(title: "Two", items: [button("a", .large), button("b", .large)])
        // A lone large button is already as narrow as a collapsed group; two large ones can only collapse.
        XCTAssertEqual(fit.fit([group, single], available: 150).map(\.mode), [.collapsed, .full])
        XCTAssertEqual(fit.fit([larges, single], available: 200).map(\.mode), [.collapsed, .full])
        XCTAssertEqual(fit.fit([larges, single], available: 10).map(\.mode), [.collapsed, .full])
    }

    func testCollapsedGroupListsEveryCommand() {
        let g = RibbonGroup(title: "G", items: [
            button("a", .large), menu("M", .large, ["m.one", "m.two"]), button("b", .small),
            RibbonItem(control: .visualGallery(label: "New visual", symbol: "chart.bar"), size: .large),
        ])
        let entries = RibbonFit.collapsedEntries(g)
        let ids = entries.map { entry -> String in if case .command(let c) = entry { return c.id } else { return "-" } }
        let visuals = VisualType.allCases.filter { !$0.isPageElement }.map { "insert.visual." + $0.rawValue }
        XCTAssertEqual(ids, ["x.a", "-", "m.one", "m.two", "-", "x.b", "-"] + visuals)
        XCTAssertEqual(RibbonFit.collapsedSymbol(g), "circle")
        XCTAssertEqual(RibbonFit.collapsedSymbol(RibbonGroup(title: "E", items: [])), RibbonLayout.fallbackSymbol)
    }

    // MARK: The real ribbon

    private var everyTab: [RibbonTab] { RibbonRegistry.resolved }

    /// The defect this replaces: in the Home tab's Data group "Enter data", "OneLake catalog" and
    /// "Recent sources" were drawn over each other. Every small button now has a column at least as
    /// wide as its own icon and caption in the real caption font.
    func testNoSmallCaptionIsWiderThanItsColumn() {
        let real = RibbonFit.standard
        for tab in everyTab {
            for group in tab.groups {
                let widths = real.fit(group, mode: .full).columnWidths
                for (column, width) in zip(RibbonLayout.columns(group), widths) {
                    guard case .stack(let items) = column else { continue }
                    for item in items {
                        let needed = 24 + 4 + RibbonText.width(RibbonFit.label(of: item))
                        XCTAssertGreaterThanOrEqual(width, needed, "\(tab.title) ▸ \(group.title) ▸ \(RibbonFit.label(of: item))")
                    }
                }
            }
        }
    }

    /// The fit measures captions with AppKit; the ribbon draws them with SwiftUI. Every small
    /// caption, drawn as `RibbonButton` draws it (with the drop-down chevron on menus), must be no
    /// wider than the room the fit leaves it, or it would be clipped.
    func testDrawnCaptionsFitTheMeasuredRoom() {
        let real = RibbonFit.standard
        var checked = 0
        for tab in everyTab {
            for group in tab.groups {
                for case .stack(let items) in RibbonLayout.columns(group) {
                    for item in items {
                        let label = RibbonFit.label(of: item)
                        var caption = Text(label).font(Design.Typeface.caption)
                        if RibbonFit.isMenu(item) {
                            caption = caption + Text(" ") + Text(Image(systemName: "chevron.down")).font(.system(size: 7, weight: .semibold))
                        }
                        let drawn = NSHostingView(rootView: caption.lineLimit(1).fixedSize()).fittingSize.width
                        let room = real.smallWidth(item, compact: false) - (real.metrics.smallPadding * 2 + real.metrics.smallIcon + real.metrics.smallSpacing)
                        XCTAssertLessThanOrEqual(Double(drawn), room, "\(tab.title) ▸ \(group.title) ▸ \(label) is drawn wider than its room")
                        checked += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 20)
    }

    /// From the 1000-pt minimum window up, every tab fits without scrolling, and a wider window
    /// never shows less than a narrower one.
    func testEveryTabFitsFromTheMinimumWindowWidthUp() {
        let real = RibbonFit.standard
        func rank(_ m: RibbonGroupMode) -> Int { m == .full ? 0 : m == .compact ? 1 : 2 }
        for tab in everyTab {
            var previous: [Int]?
            for width in stride(from: Double(ShellMetrics.minimumWindow.width), through: 2600, by: 20) {
                let fits = real.fit(tab.groups, available: width)
                XCTAssertEqual(fits.count, tab.groups.count)
                XCTAssertLessThanOrEqual(real.rowWidth(fits), width, "\(tab.title) overflows a \(Int(width))-pt window")
                let ranks = fits.map { rank($0.mode) }
                if let previous {
                    for (now, before) in zip(ranks, previous) {
                        XCTAssertLessThanOrEqual(now, before, "\(tab.title) shows less at \(Int(width)) pt than in a narrower window")
                    }
                }
                previous = ranks
            }
        }
    }

    /// At the default window size (1440 pt) nothing on the Home tab is collapsed into a menu.
    func testHomeTabKeepsEveryGroupOpenAtTheDefaultWindowSize() throws {
        let home = try XCTUnwrap(everyTab.first { $0.id == .home })
        XCTAssertFalse(RibbonFit.standard.fit(home.groups, available: 1440).contains { $0.mode == .collapsed })
    }

    // MARK: Canvas

    func testFilterPaneStartsAsAStripInAWindowUnderAbout1300Points() {
        var dock = PaneDock()
        // Default panes are 260 + 300 + 270 = 830; 420 of canvas needs 1250 right of the 48-pt rail.
        XCTAssertEqual(dock.columns(for: .report, available: 1250).map(\.collapsed), [false, false, false])
        var columns = dock.columns(for: .report, available: 1249)
        XCTAssertEqual(columns.map(\.collapsed), [true, false, false])
        XCTAssertEqual(columns.first?.automatic, true)
        XCTAssertTrue(dock.collapsed.isEmpty, "the layout must not write into the user's choices")
        // The 1120-pt window the defect was seen in: 1072 right of the rail leaves 472 for the page.
        columns = dock.columns(for: .report, available: 1072)
        XCTAssertEqual(1072 - columns.reduce(0) { $0 + $1.width }, 472)
        // With Data closed there is room, so Filters stays open.
        var noData = PaneDock()
        noData.close(InspectorPane.data.rawValue)
        XCTAssertEqual(noData.columns(for: .report, available: 1072).map(\.collapsed), [false, false])
        // Once the user opens Filters it stays open while the canvas keeps its minimum.
        dock.setCollapsed(.filters, false)
        XCTAssertEqual(dock.columns(for: .report, available: 1249).map(\.collapsed), [false, false, false])
        // Dragging a pane wider does not fold Filters away.
        var wide = PaneDock()
        wide.setWidth(400, of: .data)
        XCTAssertEqual(wide.columns(for: .report, available: 1320).map(\.collapsed), [false, false, false])
    }

    func testFitToPageUsesTheCanvasLessASmallMargin() {
        let page = CGSize(width: 1280, height: 720)
        XCTAssertEqual(CanvasFit.margin, 16)
        XCTAssertEqual(CanvasFit.scale(viewport: CGSize(width: 1312, height: 752), page: page), 1, accuracy: 1e-9)
        XCTAssertEqual(CanvasFit.scale(viewport: CGSize(width: 672, height: 2000), page: page), 0.5, accuracy: 1e-9)
        XCTAssertEqual(CanvasFit.scale(viewport: CGSize(width: 3000, height: 392), page: page), 0.5, accuracy: 1e-9)
        // The page in the 1120-pt window: 472 pt of canvas shows it at 440 / 1280.
        XCTAssertEqual(CanvasFit.scale(viewport: CGSize(width: 472, height: 600), page: page), 440.0 / 1280, accuracy: 1e-9)
        XCTAssertEqual(CanvasFit.scale(viewport: CGSize(width: 20, height: 20), page: page), 0.1)
        XCTAssertEqual(CanvasFit.scale(viewport: CGSize(width: 100_000, height: 100_000), page: page), 4)
        XCTAssertEqual(CanvasFit.scale(viewport: CGSize(width: 800, height: 600), page: .zero), 1)
    }
}
