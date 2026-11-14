import SwiftUI
import FacetCore

/// Button actions: whether one can run now, and how a conditional (measure-driven) action resolves.
enum ReportActions {
    /// The selected data point a drillthrough button acts on: the first selection (in page visual order)
    /// that can reach the button's destination, or any destination when the button names none.
    static func drillPoint(for action: ActionSpec, selections: [UUID: [DataPointSelection]], page: Page,
                           report: Report) -> (point: DataPointSelection, visual: UUID)? {
        for v in page.visuals {
            for point in selections[v.id] ?? [] {
                let targets = Drillthrough.targets(for: point, in: report, from: page.id)
                let reachable = action.conditionalMeasure != nil || action.pageID == nil
                    ? !targets.isEmpty : targets.contains { $0.id == action.pageID }
                if reachable { return (point, v.id) }
            }
        }
        return nil
    }

    /// A drillthrough button is active only while a selection it can drill through exists; a button
    /// with no action is inert; everything else can always run.
    static func canRun(_ action: ActionSpec, selections: [UUID: [DataPointSelection]], page: Page, report: Report) -> Bool {
        switch action.kind {
        case .drillthrough: return drillPoint(for: action, selections: selections, page: page, report: report) != nil
        default: return true
        }
    }

    enum Resolution: Equatable {
        case run(ActionSpec)
        case unresolved(String)
    }

    /// Applies a conditional measure's value to an action: the name of the destination page or
    /// bookmark, or the URL to open. A blank or unknown name resolves to nothing, with the reason.
    static func resolve(_ action: ActionSpec, measure: String, value: Value?, report: Report) -> Resolution {
        let text = (value.map { $0.isNull ? "" : $0.asString } ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .unresolved("The measure “\(measure)” returned no value, so this button has no destination.") }
        var out = action
        out.conditionalMeasure = nil
        func same(_ a: String) -> Bool { a.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        switch action.kind {
        case .pageNavigation, .drillthrough:
            guard let page = report.pages.first(where: { same($0.name) }) else {
                return .unresolved("The measure “\(measure)” returned “\(text)”, which is not the name of a page.")
            }
            out.pageID = page.id
        case .bookmark:
            guard let bookmark = report.bookmarks.first(where: { same($0.name) }) else {
                return .unresolved("The measure “\(measure)” returned “\(text)”, which is not the name of a bookmark.")
            }
            out.bookmarkID = bookmark.id
        case .webURL:
            out.url = text
        default:
            break
        }
        return .run(out)
    }
}

extension DocumentStore {
    /// Runs an action whose destination comes from a measure: evaluates the measure under the page's
    /// filters, then performs the resolved action.
    func performConditional(_ action: ActionSpec, measure: FieldRef, from visualID: UUID?) {
        let filters = (report.filters + currentPage.filters + (drillthroughFilters[currentPageID] ?? [])).filter { !$0.isEmpty }
        let expression = measure.daxReference
        Task {
            let value = await withEngine { engine in try? engine.scalar(expression, filters: filters) }
            switch ReportActions.resolve(action, measure: measure.name, value: value, report: self.report) {
            case .run(let resolved): self.perform(resolved, from: visualID)
            case .unresolved(let reason): self.status = StatusMessage(kind: .warning, text: reason)
            }
        }
    }

    /// Runs a drillthrough button: drills the selected data point through to the button's page.
    func performDrillthroughButton(_ action: ActionSpec) {
        guard let hit = ReportActions.drillPoint(for: action, selections: pointSelections, page: currentPage, report: report) else {
            status = StatusMessage(kind: .info, text: "Select a data point that has a drillthrough page first.")
            return
        }
        drillthrough(hit.point, to: action.pageID, from: hit.visual)
    }
}
