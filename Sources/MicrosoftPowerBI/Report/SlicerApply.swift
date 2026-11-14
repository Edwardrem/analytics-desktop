import Foundation
import FacetCore

/// "Apply all slicers": on a page that has such a button, slicer selections wait until it is pressed,
/// so a reader can set several slicers and run the page's queries once.
enum SlicerApply {
    /// True when slicer changes on the page wait for an "Apply all slicers" button.
    static func defers(_ page: Page) -> Bool {
        page.visuals.contains { $0.type == .button && $0.action?.kind == .applyAllSlicers }
    }

    /// The waiting selections that differ from what the page's slicers have saved.
    static func changes(_ pending: [UUID: SlicerState], on page: Page) -> [UUID: SlicerState] {
        pending.filter { id, state in
            guard let slicer = page.visual(id), slicer.type.isSlicer else { return false }
            return (state.isActive ? state : nil) != slicer.slicerState
        }
    }

    /// Saves slicer selections into the report: each slicer, and every slicer synced with it on any page.
    static func commit(_ states: [UUID: SlicerState], to report: inout Report) {
        var byGroup: [String: SlicerState] = [:]
        for page in report.pages {
            for v in page.visuals where v.type.isSlicer {
                if let state = states[v.id], let group = v.syncGroup { byGroup[group] = state }
            }
        }
        for p in report.pages.indices {
            for v in report.pages[p].visuals.indices where report.pages[p].visuals[v].type.isSlicer {
                let slicer = report.pages[p].visuals[v]
                guard let state = states[slicer.id] ?? slicer.syncGroup.flatMap({ byGroup[$0] }) else { continue }
                report.pages[p].visuals[v].slicerState = state.isActive ? state : nil
            }
        }
    }
}

extension ReportRuntime {
    /// Selections waiting on the page that would change something when applied.
    func pendingSlicers(on page: Page) -> [UUID: SlicerState] { SlicerApply.changes(pendingSlicers, on: page) }

    func dropPendingSlicers(on page: Page) {
        let ids = Set(page.visuals.map(\.id))
        let kept = pendingSlicers.filter { !ids.contains($0.key) }
        if kept.count != pendingSlicers.count { pendingSlicers = kept }
    }
}

extension DocumentStore {
    /// A slicer's selection changed on the canvas or in the reading view: saved at once, or kept
    /// waiting when the page has an "Apply all slicers" button.
    func changeSlicer(_ state: SlicerState, for id: UUID) {
        guard SlicerApply.defers(currentPage), currentPage.visual(id) != nil else {
            setSlicerState(state, for: id)
            return
        }
        ReportRuntime.of(self).pendingSlicers[id] = state
    }

    /// Save every waiting slicer selection on this page in one step, and run the page's visuals.
    func applyAllSlicers() {
        let runtime = ReportRuntime.of(self)
        let changes = runtime.pendingSlicers(on: currentPage)
        runtime.dropPendingSlicers(on: currentPage)
        guard !changes.isEmpty else { return }
        mutate("Apply All Slicers", invalidates: .visuals(nil)) { SlicerApply.commit(changes, to: &$0.report) }
    }
}
