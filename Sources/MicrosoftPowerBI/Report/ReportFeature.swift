import SwiftUI
import FacetCore
import FacetDesign

/// Report-view features that live on the canvas: mobile layout, page view, tooltips, drillthrough,
/// reading-mode tools. Registers their commands.
@MainActor
enum ReportFeature {
    static func register() {
        AppCommands.register(commands)
    }

    static func commands() -> [AppCommand] {
        var c: [AppCommand] = []
        let inReport: @MainActor (DocumentStore) -> Bool = { $0.view == .report }
        c.append(AppCommand(id: "view.fitWidth", title: "Fit to Width", menu: .view, symbol: "arrow.left.and.right",
                            isEnabled: inReport, isOn: { $0.fitToWindow && $0.fitToWidth }) {
            $0.fitToWidth = true; $0.fitToWindow = true
        })
        c.append(AppCommand(id: "view.mobileAutoCreate", title: "Auto-create Mobile Layout", menu: .view, symbol: "wand.and.stars",
                            isEnabled: { $0.view == .report && !$0.currentPage.visuals.isEmpty }) { s in
            s.mobileLayout = true
            s.selection = []
            s.autoCreateMobileLayout()
        })
        c.append(AppCommand(id: "view.mobileClear", title: "Clear Mobile Layout", menu: .view,
                            isEnabled: { $0.view == .report && $0.currentPage.hasMobileLayout }) { s in
            s.removeFromMobileLayout(s.currentPage.visuals.map(\.id))
        })
        c.append(AppCommand(id: "insert.sparkline", title: "Add a Sparkline…", menu: .insert, symbol: "waveform.path.ecg",
                            separatorBefore: true, help: "A small line or column chart in every row of a table or matrix.",
                            isEnabled: { $0.sparklineTarget != nil }) { s in
            guard let table = s.sparklineTarget else { return }
            s.present { SparklineSheet(visualID: table.id) }
        })
        c.append(AppCommand(id: "filters.clearAll", title: "Clear All Filters", menu: .data, symbol: "line.3.horizontal.decrease.circle",
                            separatorBefore: true, isEnabled: inReport) { $0.clearAllFilters() })
        c.append(AppCommand(id: "filters.apply", title: "Apply Filters", menu: .data, symbol: "checkmark.circle",
                            isEnabled: { $0.view == .report && $0.report.settings.filterPaneApplyButton && ReportRuntime.of($0).filtersPending }) {
            $0.applyPendingFilters()
        })
        c.append(AppCommand(id: "filters.applyButton", title: "Add an Apply Button to the Filters Pane", menu: .data,
                            isOn: { $0.report.settings.filterPaneApplyButton }) { s in
            let on = !s.report.settings.filterPaneApplyButton
            s.mutate(on ? "Add Filter Apply Button" : "Remove Filter Apply Button", invalidates: .layout) { $0.report.settings.filterPaneApplyButton = on }
            if !on { s.applyPendingFilters() }
        })
        return c
    }
}
