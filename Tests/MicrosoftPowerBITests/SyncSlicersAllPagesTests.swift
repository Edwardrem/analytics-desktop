import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// "Add and sync with all pages" in the Sync slicers pane: the slicer is synced with, and shown
/// on, every page that isn't a tooltip page, as one undo step.
@MainActor
final class SyncSlicersAllPagesTests: XCTestCase {
    /// Overview holds the Region slicer; Detail has its own hidden Region slicer that isn't synced;
    /// Trends has none; Tip is a tooltip page.
    private func report() -> (store: DocumentStore, slicer: VisualSpec, detailSlicer: VisualSpec) {
        let store = ReportFixture.store()
        var slicer = VisualSpec(type: .slicer, frame: Frame(x: 20, y: 20, width: 200, height: 120), name: "Region")
        slicer.setFields(.field, [ReportFixture.region])
        var detailSlicer = VisualSpec(type: .slicer, frame: Frame(x: 40, y: 40, width: 200, height: 120), name: "Region on Detail")
        detailSlicer.setFields(.field, [ReportFixture.region])
        detailSlicer.isHidden = true
        var overview = Page(name: "Overview"); overview.visuals = [slicer]
        var detail = Page(name: "Detail"); detail.visuals = [detailSlicer, ReportFixture.chart()]
        let trends = Page(name: "Trends")
        var tip = Page(name: "Tip"); tip.isTooltipPage = true
        store.mutate("Pages", invalidates: .visuals(nil)) { d in d.report.pages = [overview, detail, trends, tip] }
        return (store, slicer, detailSlicer)
    }

    func testSyncsAndShowsTheSlicerOnEveryPageButTooltipPages() throws {
        let (store, slicer, detailSlicer) = report()
        // Overview (no group yet), Detail (hidden, not in a group) and Trends (no slicer) remain.
        XCTAssertEqual(DocumentStore.pagesToSync(slicer, in: store.report), 3)

        store.syncSlicerWithAllPages(slicer.id)
        let pages = store.report.pages
        XCTAssertEqual(store.undoName, "Add and Sync with All Pages")

        // The group is named after the field, and filter changes sync, so syncGroup is set too.
        let source = try XCTUnwrap(pages[0].visual(slicer.id))
        XCTAssertEqual(SlicerSync.group(source), "Region")
        XCTAssertEqual(source.syncGroup, "Region")
        XCTAssertFalse(source.isHidden)

        // Detail's own slicer joins the group and is shown; no copy is added beside it.
        XCTAssertEqual(pages[1].visuals.count, 2)
        let detail = try XCTUnwrap(pages[1].visual(detailSlicer.id))
        XCTAssertEqual(SlicerSync.group(detail), "Region")
        XCTAssertFalse(detail.isHidden)

        // Trends gets a visible copy at the same place.
        XCTAssertEqual(pages[2].visuals.count, 1)
        let copy = try XCTUnwrap(pages[2].visuals.first)
        XCTAssertNotEqual(copy.id, slicer.id)
        XCTAssertEqual(SlicerSync.group(copy), "Region")
        XCTAssertTrue(SlicerSync.isCopy(copy))
        XCTAssertFalse(copy.isHidden)
        XCTAssertEqual(copy.frame, slicer.frame)

        // The tooltip page is left alone, and nothing remains to sync.
        XCTAssertTrue(pages[3].visuals.isEmpty)
        XCTAssertEqual(DocumentStore.pagesToSync(source, in: store.report), 0)
    }

    func testOneUndoStepPutsEveryPageBack() throws {
        let (store, slicer, detailSlicer) = report()
        let before = store.report.pages
        store.syncSlicerWithAllPages(slicer.id)
        store.undo()
        XCTAssertEqual(store.report.pages, before)
        XCTAssertEqual(store.undoName, "Pages")
        let detail = try XCTUnwrap(store.report.pages[1].visual(detailSlicer.id))
        XCTAssertTrue(detail.isHidden)
        XCTAssertNil(SlicerSync.group(detail))
    }

    func testTheSyncColumnStillAddsAHiddenCopy() throws {
        let (store, slicer, _) = report()
        let trends = store.report.pages[2].id
        store.setSlicerSync(slicer.id, pageID: trends, synced: true)
        let copy = try XCTUnwrap(store.report.pages[2].visuals.first)
        XCTAssertEqual(SlicerSync.group(copy), "Region")
        XCTAssertTrue(copy.isHidden)
        // Overview is now synced; Detail (not in the group) and Trends (hidden) remain.
        let source = try XCTUnwrap(store.report.pages[0].visual(slicer.id))
        XCTAssertEqual(DocumentStore.pagesToSync(source, in: store.report), 2)
    }
}
