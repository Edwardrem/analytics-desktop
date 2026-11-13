import Foundation
import FacetCore

/// How the report page is scaled on the canvas: fit to page, fit to width, or a chosen zoom (actual size = 1).
enum PageView {
    enum Mode: Equatable { case fitPage, fitWidth, zoom }
    /// Space kept around the page on every side.
    static let padding = 32.0
    static let minimumScale = 0.1

    static func mode(fitToWindow: Bool, fitToWidth: Bool) -> Mode {
        fitToWindow ? (fitToWidth ? .fitWidth : .fitPage) : .zoom
    }

    /// The scale for a page in a viewport. Fit to page shows the whole page; fit to width fills the
    /// width and lets the page scroll vertically; zoom uses the factor as is.
    static func scale(mode: Mode, page: PageSize, viewport: CGSize, zoom: Double) -> Double {
        guard page.width > 0, page.height > 0 else { return 1 }
        let w = (Double(viewport.width) - padding * 2) / page.width
        let h = (Double(viewport.height) - padding * 2) / page.height
        switch mode {
        case .fitPage: return max(minimumScale, min(w, h))
        case .fitWidth: return max(minimumScale, w)
        case .zoom: return zoom
        }
    }
}
