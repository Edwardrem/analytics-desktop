import XCTest
import AppKit
import SwiftUI
import FacetCore
@testable import MicrosoftPowerBI

/// The Filters pane's cards, as Power BI draws them: a title and what the filter keeps; clear, lock
/// and hide on hover; and a search over every card.
@MainActor
final class FilterCardsTests: XCTestCase {
    private let city = FieldRef.column("Geography", "City")
    private let revenue = FieldRef.measure("Sales", "Revenue")

    private func basic(_ values: [Value] = []) -> FilterSpec {
        var f = FilterSpec(field: city)
        f.values = values
        return f
    }

    func testTheCardSaysWhatTheFilterKeeps() {
        XCTAssertEqual(FilterTools.summary(basic()), "is (All)")
        XCTAssertEqual(FilterTools.summary(basic([.string("Seattle")])), "is Seattle")
        var top = FilterSpec(field: city, kind: .topN)
        top.topN.count = 3
        top.topN.by = revenue
        XCTAssertEqual(FilterTools.summary(top), "Top 3 by Revenue")
        var named = basic()
        XCTAssertEqual(FilterCardLogic.title(named), "City")
        named.displayName = "Where"
        XCTAssertEqual(FilterCardLogic.title(named), "Where")
    }

    func testHoverShowsClearLockAndHideAndOnlyStatesThatAreOnStay() {
        let active = basic([.string("Seattle")])
        XCTAssertEqual(FilterCardLogic.controls(active, hovering: true), [.clear, .lock, .hide])
        XCTAssertEqual(FilterCardLogic.controls(basic(), hovering: true), [.lock, .hide], "nothing to clear")
        XCTAssertEqual(FilterCardLogic.controls(active, hovering: false), [])
        var locked = active
        locked.isLocked = true
        XCTAssertEqual(FilterCardLogic.controls(locked, hovering: false), [.lock])
        var hidden = active
        hidden.isHidden = true
        XCTAssertEqual(FilterCardLogic.controls(hidden, hovering: false), [.hide])
        // Each control says what it does in its help, and its symbol shows its state.
        XCTAssertEqual(FilterCardLogic.symbol(.lock, locked), "lock.fill")
        XCTAssertEqual(FilterCardLogic.symbol(.lock, active), "lock.open")
        XCTAssertEqual(FilterCardLogic.symbol(.hide, hidden), "eye.slash")
        XCTAssertEqual(FilterCardLogic.symbol(.clear, active), "eraser")
        XCTAssertEqual(FilterCardLogic.help(.clear, active), "Clear filter")
        XCTAssertEqual(FilterCardLogic.help(.lock, locked), "Unlock filter, so readers can change it")
        XCTAssertEqual(FilterCardLogic.help(.hide, active), "Hide filter from readers")
    }

    func testSearchMatchesTitlesFieldsAndTablesWordByWord() {
        var named = basic()
        named.displayName = "Café towns"
        XCTAssertTrue(FilterCardLogic.matches(basic(), query: "city"))
        XCTAssertTrue(FilterCardLogic.matches(basic(), query: "GEO"), "the table")
        XCTAssertTrue(FilterCardLogic.matches(basic(), query: "geo cit"), "every word, anywhere")
        XCTAssertFalse(FilterCardLogic.matches(basic(), query: "geo region"))
        XCTAssertTrue(FilterCardLogic.matches(named, query: "cafe"), "accents don't matter")
        XCTAssertTrue(FilterCardLogic.matches(named, query: "city"), "a renamed card still finds its field")
        XCTAssertTrue(FilterCardLogic.matches(basic(), query: "  "), "an empty search lists everything")
        // Listed cards keep their place among all of the section's, so moving one moves it there.
        var region = FilterSpec(field: .column("Geography", "Region"))
        region.values = [.string("West")]
        let listed = FilterCardLogic.listed([region, basic(), basic([.string("Seattle")])], query: "city")
        XCTAssertEqual(listed.map(\.position), [1, 2])
    }

    func testThePaneDrawsItsCardsInAPaneWidth() throws {
        var doc = FacetDocument()
        var page = Page(name: "Page 1")
        page.filters = [basic([.string("Seattle")])]
        doc.report.pages = [page]
        var all = FilterSpec(field: city, kind: .topN)
        all.topN.by = revenue
        all.isLocked = true
        doc.report.filters = [all]
        let store = DocumentStore(document: doc, services: .live())
        let size = CGSize(width: 300, height: 480)
        let host = NSHostingView(rootView: FiltersPane().environmentObject(store).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        XCTAssertNotNil(rep.colorAt(x: 5, y: 5))
        window.contentView = nil
        window.close()
    }
}
