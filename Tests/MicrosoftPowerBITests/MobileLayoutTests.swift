import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// The phone layout: reading order, fitted sizes, stacking, drops, phone-only formatting, and the page view scale.
@MainActor
final class MobileLayoutTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Features.registerAll()
    }

    private func visual(_ name: String, _ x: Double, _ y: Double, _ w: Double, _ h: Double) -> VisualSpec {
        VisualSpec(type: .clusteredColumn, frame: Frame(x: x, y: y, width: w, height: h), name: name)
    }

    func testReadingOrderGoesRowByRowThenLeftToRight() {
        // D starts at y 40, above the middle (50) of row-starter A, so it sits in A's row between A and B.
        let a = visual("A", 0, 0, 100, 100), b = visual("B", 200, 10, 100, 100)
        let c = visual("C", 0, 150, 100, 100), d = visual("D", 120, 40, 60, 100)
        XCTAssertEqual(MobileLayout.readingOrder([c, b, d, a]).map(\.name), ["A", "D", "B", "C"])
    }

    func testFittedSizeKeepsAspectRatioWithinLimits() {
        // Width is always 360 − 2 × 8 = 344. 344 × 200/400 = 172 → nearest 8 is 176.
        var size = MobileLayout.fittedSize(for: Frame(x: 0, y: 0, width: 400, height: 200))
        XCTAssertEqual(size.width, 344); XCTAssertEqual(size.height, 176)
        // A tall visual is capped at 320, a thin strip is raised to 48.
        size = MobileLayout.fittedSize(for: Frame(x: 0, y: 0, width: 100, height: 400))
        XCTAssertEqual(size.height, 320)
        size = MobileLayout.fittedSize(for: Frame(x: 0, y: 0, width: 800, height: 50))
        XCTAssertEqual(size.height, 48)
    }

    func testStackingStartsUnderWhatIsPlaced() {
        var page = Page(name: "P")
        let a = visual("A", 0, 0, 400, 200), b = visual("B", 500, 0, 344, 86)
        page.visuals = [a, b]
        let frames = MobileLayout.stacked([a.id, b.id], on: page)
        XCTAssertEqual(frames[a.id], Frame(x: 8, y: 8, width: 344, height: 176))
        // 8 + 176 + 8 = 192; 86 snaps to 88.
        XCTAssertEqual(frames[b.id], Frame(x: 8, y: 192, width: 344, height: 88))
        // With A already placed lower down, B goes under it and A is not moved.
        page.visuals[0].mobileFrame = Frame(x: 8, y: 400, width: 344, height: 100)
        let next = MobileLayout.stacked([a.id, b.id], on: page)
        XCTAssertNil(next[a.id])
        XCTAssertEqual(next[b.id]?.y, 508)
    }

    func testAutoCreateSkipsHiddenAndPlacedVisuals() {
        var page = Page(name: "P")
        var hidden = visual("Hidden", 0, 0, 100, 100); hidden.isHidden = true
        var placed = visual("Placed", 0, 200, 100, 100); placed.mobileFrame = Frame(x: 8, y: 8, width: 344, height: 80)
        let right = visual("Right", 300, 400, 200, 100), left = visual("Left", 0, 400, 200, 100)
        page.visuals = [hidden, placed, right, left]
        let frames = MobileLayout.autoCreate(page)
        XCTAssertEqual(Set(frames.keys), [right.id, left.id])
        // Left reads before Right; both are 344 × 172→176 tall; the stack starts at 8 + 80 + 8 = 96.
        XCTAssertEqual(frames[left.id]?.y, 96)
        XCTAssertEqual(frames[right.id]?.y, 96 + 176 + 8)
    }

    func testCanvasGrowsWithContent() {
        var page = Page(name: "P")
        XCTAssertEqual(MobileLayout.canvasHeight(page), 640)
        var v = visual("A", 0, 0, 100, 100); v.mobileFrame = Frame(x: 8, y: 600, width: 344, height: 100)
        page.visuals = [v]
        XCTAssertEqual(MobileLayout.canvasHeight(page), 708)
    }

    func testDropCentresOnThePointerAndSnaps() {
        // 344 × 176; top = 300 − 88 = 212 → snaps to 216. A full-width visual sits on the left margin.
        let f = MobileLayout.dropFrame(for: visual("A", 0, 0, 400, 200), at: CGPoint(x: 180, y: 300))
        XCTAssertEqual(f, Frame(x: 8, y: 216, width: 344, height: 176))
        // Dropped near the top edge it stays on the canvas.
        XCTAssertEqual(MobileLayout.dropFrame(for: visual("A", 0, 0, 400, 200), at: CGPoint(x: 10, y: 10)).y, 0)
    }

    func testDragPayloadRoundTrips() {
        let id = UUID()
        XCTAssertEqual(MobileLayout.draggedVisual(MobileLayout.dragPayload(for: id)), id)
        XCTAssertNil(MobileLayout.draggedVisual("facet-field:column|Sales|Amount"))
    }

    func testMobileFormattingLayersOverDesktopFormatting() {
        var v = visual("A", 0, 0, 100, 100)
        v.setFmt("title", "show", .bool(true))
        v.setFmt("title", "size", .number(14))
        XCTAssertEqual(MobileLayout.effectiveSpec(v), v)
        v.mobileFormat = MobileLayout.setting(nil, "title", "show", .bool(false))
        let phone = MobileLayout.effectiveSpec(v)
        XCTAssertEqual(phone.fmt("title", "show"), .bool(false))
        XCTAssertEqual(phone.fmt("title", "size"), .number(14))
        XCTAssertEqual(v.fmt("title", "show"), .bool(true), "the desktop formatting is untouched")
        // Clearing the only override leaves no mobile formatting at all.
        XCTAssertNil(MobileLayout.setting(v.mobileFormat, "title", "show", nil))
    }

    func testStorePlacesRemovesAndUndoes() {
        let store = DocumentStore(services: .live())
        let a = store.addVisual(.clusteredColumn), b = store.addVisual(.card)
        XCTAssertFalse(store.currentPage.hasMobileLayout)
        AppCommands.run("view.mobileAutoCreate", store)
        XCTAssertTrue(store.mobileLayout)
        XCTAssertTrue(store.currentPage.hasMobileLayout)
        XCTAssertNotNil(store.visual(a)?.mobileFrame)
        XCTAssertNotNil(store.visual(b)?.mobileFrame)
        store.removeFromMobileLayout([a])
        XCTAssertNil(store.visual(a)?.mobileFrame)
        XCTAssertTrue(store.currentPage.hasMobileLayout)
        store.removeFromMobileLayout([b])
        XCTAssertFalse(store.currentPage.hasMobileLayout)
        store.undo()
        XCTAssertNotNil(store.visual(b)?.mobileFrame)
        XCTAssertTrue(store.currentPage.hasMobileLayout)
        // Moving a visual in mobile layout changes only its phone frame.
        let desktop = store.visual(b)?.frame
        store.setFrames([b: Frame(x: 16, y: 320, width: 200, height: 96)])
        XCTAssertEqual(store.visual(b)?.frame, desktop)
        XCTAssertEqual(store.visual(b)?.mobileFrame, Frame(x: 16, y: 320, width: 200, height: 96))
        store.setMobileFormat(b, "title", "show", .bool(false))
        XCTAssertEqual(store.visual(b)?.mobileFormat?["title"]?["show"], .bool(false))
        store.resetMobileFormat(b)
        XCTAssertNil(store.visual(b)?.mobileFormat)
    }

    func testMobileFieldsSurviveSaving() throws {
        var v = visual("A", 0, 0, 100, 100)
        v.mobileFrame = Frame(x: 8, y: 8, width: 344, height: 96)
        v.mobileFormat = ["legend": ["show": .bool(false)]]
        let back = try JSONDecoder().decode(VisualSpec.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(back, v)
    }

    // MARK: Page view

    func testPageViewScales() {
        let page = PageSize.widescreen   // 1280 × 720, 32 pt kept free on every side
        // Width-bound viewport: (1000 − 64) / 1280 = 0.73125 either way.
        XCTAssertEqual(PageView.scale(mode: .fitPage, page: page, viewport: CGSize(width: 1000, height: 800), zoom: 2), 0.73125, accuracy: 1e-9)
        XCTAssertEqual(PageView.scale(mode: .fitWidth, page: page, viewport: CGSize(width: 1000, height: 800), zoom: 2), 0.73125, accuracy: 1e-9)
        // Short viewport: fit to page is bound by height (336 / 720), fit to width fills the width (1280 / 1280).
        XCTAssertEqual(PageView.scale(mode: .fitPage, page: page, viewport: CGSize(width: 1344, height: 400), zoom: 2), 336.0 / 720.0, accuracy: 1e-9)
        XCTAssertEqual(PageView.scale(mode: .fitWidth, page: page, viewport: CGSize(width: 1344, height: 400), zoom: 2), 1, accuracy: 1e-9)
        XCTAssertEqual(PageView.scale(mode: .zoom, page: page, viewport: CGSize(width: 1344, height: 400), zoom: 2), 2)
        // A viewport smaller than the padding never produces a zero or negative scale.
        XCTAssertEqual(PageView.scale(mode: .fitPage, page: page, viewport: CGSize(width: 10, height: 10), zoom: 1), 0.1)
    }

    func testPageViewCommands() {
        let store = DocumentStore(services: .live())
        XCTAssertEqual(PageView.mode(fitToWindow: store.fitToWindow, fitToWidth: store.fitToWidth), .fitPage)
        AppCommands.run("view.fitWidth", store)
        XCTAssertEqual(PageView.mode(fitToWindow: store.fitToWindow, fitToWidth: store.fitToWidth), .fitWidth)
        XCTAssertEqual(AppCommands.command("view.fitWidth")?.isOn?(store), true)
        XCTAssertEqual(AppCommands.command("view.fit")?.isOn?(store), false)
        AppCommands.run("view.actualSize", store)
        XCTAssertEqual(PageView.mode(fitToWindow: store.fitToWindow, fitToWidth: store.fitToWidth), .zoom)
        XCTAssertEqual(store.zoom, 1)
        XCTAssertEqual(AppCommands.command("view.fitWidth")?.isOn?(store), false)
        AppCommands.run("view.fit", store)
        XCTAssertEqual(PageView.mode(fitToWindow: store.fitToWindow, fitToWidth: store.fitToWidth), .fitPage)
    }
}
