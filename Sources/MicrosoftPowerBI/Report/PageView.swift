import Foundation
import FacetCore

/// How the report page is scaled on the canvas: fit to page, fit to width, or a chosen zoom (actual size = 1).
enum PageView {
    enum Mode: Equatable { case fitPage, fitWidth, zoom }
    /// Space kept around the page on every side (the same margin "Fit to page" leaves).
    static let padding = CanvasFit.margin

    static func mode(fitToWindow: Bool, fitToWidth: Bool) -> Mode {
        fitToWindow ? (fitToWidth ? .fitWidth : .fitPage) : .zoom
    }

    /// The scale for a page in a viewport. Fit to page shows the whole page; fit to width fills the
    /// width and lets the page scroll vertically; zoom uses the factor as is. Fitted scales stay
    /// inside the status bar's zoom range.
    static func scale(mode: Mode, page: PageSize, viewport: CGSize, zoom: Double) -> Double {
        guard page.width > 0, page.height > 0 else { return 1 }
        switch mode {
        case .fitPage:
            return CanvasFit.scale(viewport: viewport, page: CGSize(width: page.width, height: page.height))
        case .fitWidth:
            let w = (Double(viewport.width) - padding * 2) / page.width
            let range = StatusModel.zoomRange
            return w.isFinite ? min(max(w, range.lowerBound), range.upperBound) : 1
        case .zoom:
            return zoom
        }
    }
}
