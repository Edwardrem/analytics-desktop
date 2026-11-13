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
        return c
    }
}
