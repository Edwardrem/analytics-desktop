import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Layout aids on the report canvas: align, distribute, match size, layer order, groups, snapping, page view.
@MainActor
final class LayoutAidTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func box(_ name: String, _ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 50, z: Int = 0) -> VisualSpec {
        var v = VisualSpec(type: .shape, frame: Frame(x: x, y: y, width: w, height: h), name: name)
        v.zIndex = z
        return v
    }

    private func store(_ visuals: [VisualSpec]) -> DocumentStore {
        let store = DocumentStore(services: .live())
        store.mutate("Set Up", invalidates: .layout) { $0.report.pages[0].visuals = visuals }
        return store
    }

    private func frame(_ s: DocumentStore, _ name: String) -> Frame? { s.currentPage.visuals.first { $0.name == name }?.frame }

    func testAlignToTheSelectionOrToThePage() {
        let a = box("A", 40, 10), b = box("B", 200, 90, 60), c = box("C", 120, 300, 80)
        let s = store([a, b, c])
        s.selection = [a.id, b.id, c.id]
        s.arrange(.right)       // the selection spans x 40…260
        XCTAssertEqual(frame(s, "A")?.x, 160)
        XCTAssertEqual(frame(s, "B")?.x, 200)
        XCTAssertEqual(frame(s, "C")?.x, 180)
        s.arrange(.top)
        XCTAssertEqual(Set(s.currentPage.visuals.map(\.frame.y)), [10])
        // One visual aligns to the page (1280 × 720).
        s.selection = [a.id]
        s.arrange(.centerV)
        XCTAssertEqual(frame(s, "A")?.y, 335)
        XCTAssertEqual(s.undoName, "Arrange")
    }

    func testDistributeLeavesEqualGaps() {
        // Widths 100, 50, 100 between x 0 and 600: the gaps are (600 − 250) / 2 = 175.
        let a = box("A", 0, 0), b = box("B", 130, 0, 50), c = box("C", 500, 0)
        let s = store([c, a, b])
        s.selection = [a.id, b.id, c.id]
        s.arrange(.distributeH)
        XCTAssertEqual(frame(s, "A")?.x, 0)
        XCTAssertEqual(frame(s, "B")?.x, 275)
        XCTAssertEqual(frame(s, "C")?.x, 500)
        // Two visuals have nothing to distribute.
        s.selection = [a.id, b.id]
        s.arrange(.distributeV)
        XCTAssertEqual(s.undoName, "Arrange", "nothing new was recorded")
        XCTAssertEqual(frame(s, "B")?.y, 0)
    }

    func testMatchSizeFollowsTheFirstVisualInPageOrder() {
        let a = box("A", 0, 0, 120, 80), b = box("B", 200, 0, 60, 40)
        let s = store([a, b])
        s.selection = [a.id, b.id]
        s.arrange(.sameSize)
        XCTAssertEqual(frame(s, "B")?.width, 120)
        XCTAssertEqual(frame(s, "B")?.height, 80)
    }

    func testArrangingInThePhoneLayoutMovesThePhoneFrames() {
        var a = box("A", 600, 400), b = box("B", 900, 100)
        a.mobileFrame = Frame(x: 8, y: 8, width: 100, height: 50)
        b.mobileFrame = Frame(x: 120, y: 80, width: 100, height: 50)
        let s = store([a, b])
        s.mobileLayout = true
        s.selection = [a.id, b.id]
        s.arrange(.left)
        XCTAssertEqual(s.currentPage.visuals.compactMap(\.mobileFrame?.x), [8, 8])
        XCTAssertEqual(frame(s, "B")?.x, 900, "the desktop layout is untouched")
    }

    func testLayerOrderMovesOneStepOrToTheEnds() {
        let a = box("A", 0, 0, z: 1), b = box("B", 0, 0, z: 2), c = box("C", 0, 0, z: 3)
        let s = store([a, b, c])
        func order() -> [String] { s.currentPage.visuals.sorted { $0.zIndex < $1.zIndex }.map(\.name) }
        s.selection = [a.id]
        s.reorder(.forward)
        XCTAssertEqual(order(), ["B", "A", "C"])
        s.reorder(.front)
        XCTAssertEqual(order(), ["B", "C", "A"])
        s.selection = [c.id]
        s.reorder(.backward)
        XCTAssertEqual(order(), ["C", "B", "A"])
        s.reorder(.backward)
        XCTAssertEqual(order(), ["C", "B", "A"], "already at the back")
        AppCommands.run("format.front", s)
        XCTAssertEqual(order(), ["B", "A", "C"])
    }

    func testGroupsSelectAndUngroupTogether() {
        let a = box("A", 0, 0), b = box("B", 200, 0), c = box("C", 400, 0)
        let s = store([a, b, c])
        s.selection = [a.id, b.id]
        AppCommands.run("format.group", s)
        XCTAssertEqual(s.currentPage.groups.count, 1)
        XCTAssertEqual(s.withGroupMembers([a.id]), [a.id, b.id], "clicking one member selects the group")
        XCTAssertEqual(s.withGroupMembers([c.id]), [c.id])
        s.selection = [a.id]
        XCTAssertEqual(AppCommands.command("format.ungroup")?.isEnabled(s), true)
        AppCommands.run("format.ungroup", s)
        XCTAssertTrue(s.currentPage.groups.isEmpty)
        XCTAssertTrue(s.currentPage.visuals.allSatisfy { $0.groupID == nil })
    }

    func testSnappingPrefersEdgesThenTheGrid() {
        let page = PageSize(width: 1280, height: 720)
        let other = Frame(x: 100, y: 300, width: 100, height: 50)
        // Left edge 103 is within 5 of the other visual's left edge; top 13 snaps to the 8-point grid.
        let moved = Frame(x: 103, y: 13, width: 60, height: 40)
        let snapped = Snapping.snap(moved, others: [other], page: page, grid: 8, disabled: false)
        XCTAssertEqual(snapped.frame.x, 100)
        XCTAssertEqual(snapped.frame.y, 16)
        XCTAssertEqual(snapped.guides, [SnapGuide(vertical: true, position: 100)])
        // Without the grid nothing but edges snaps; ⌘ turns snapping off.
        XCTAssertEqual(Snapping.snap(moved, others: [other], page: page, grid: nil, disabled: false).frame.y, 13)
        XCTAssertEqual(Snapping.snap(moved, others: [other], page: page, grid: 8, disabled: true).frame, moved)
    }

    func testPageViewModes() {
        let page = PageSize(width: 1280, height: 720)
        let viewport = CGSize(width: 704, height: 1000)   // 640 × 936 inside the padding
        XCTAssertEqual(PageView.scale(mode: .fitPage, page: page, viewport: viewport, zoom: 3), 0.5)
        XCTAssertEqual(PageView.scale(mode: .fitWidth, page: page, viewport: viewport, zoom: 3), 0.5)
        XCTAssertEqual(PageView.scale(mode: .fitPage, page: page, viewport: CGSize(width: 2624, height: 424), zoom: 1), 0.5,
                       "a short window fits the height")
        XCTAssertEqual(PageView.scale(mode: .zoom, page: page, viewport: viewport, zoom: 1), 1)

        let s = store([])
        AppCommands.run("view.actualSize", s)
        XCTAssertEqual(PageView.mode(fitToWindow: s.fitToWindow, fitToWidth: s.fitToWidth), .zoom)
        XCTAssertEqual(s.zoom, 1)
        XCTAssertEqual(AppCommands.command("view.actualSize")?.isOn?(s), true)
        AppCommands.run("view.zoomIn", s)
        XCTAssertEqual(AppCommands.command("view.actualSize")?.isOn?(s), false)
        AppCommands.run("view.fit", s)
        XCTAssertEqual(AppCommands.command("view.actualSize")?.isOn?(s), false)
    }

    func testLockedObjectsAndTheLockCommand() {
        let s = store([box("A", 0, 0)])
        XCTAssertFalse(s.lockObjects)
        AppCommands.run("view.lock", s)
        XCTAssertTrue(s.lockObjects)
        XCTAssertEqual(AppCommands.command("view.lock")?.isOn?(s), true)
        AppCommands.run("view.gridlines", s)
        XCTAssertTrue(s.showGridlines)
    }
}
