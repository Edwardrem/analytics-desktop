import SwiftUI
import FacetCore
import FacetDesign
import FacetVisuals

/// Report page tooltips: which page a visual shows on hover and how that page is filtered.
enum TooltipPages {
    /// Widest a tooltip page is drawn; larger pages are scaled down to this.
    static let maximumWidth = 400.0

    /// The tooltip page for a visual: the page it names, otherwise (automatic) the first tooltip page
    /// whose tooltip fields include one of the visual's fields. Nil means the default tooltip.
    static func page(for visual: VisualSpec, in report: Report) -> Page? {
        if let id = visual.tooltipPageID, let page = report.page(id), page.isTooltipPage { return page }
        guard visual.tooltipPageID == nil else { return nil }
        let used = Set(visual.allFields.map(Drillthrough.fieldKey))
        guard !used.isEmpty else { return nil }
        return report.pages.first { p in
            p.isTooltipPage && (p.tooltipFields ?? []).contains { used.contains(Drillthrough.fieldKey($0)) }
        }
    }

    /// The query for one visual on a tooltip page: its own page's context, narrowed by everything that
    /// shaped the hovered visual and by the hovered data point itself.
    static func request(base: VisualRequest, source: VisualRequest, point: DataPointSelection) -> VisualRequest {
        var r = base
        r.filters += source.filters
        r.slicers += source.slicers
        r.crossFilters += source.crossFilters + [[point]]
        r.highlights = []
        return r
    }

    /// Scale that fits a tooltip page into the maximum tooltip width (never enlarging it).
    static func scale(for size: PageSize) -> Double {
        size.width > maximumWidth ? maximumWidth / size.width : 1
    }

    static func key(page: UUID, point: DataPointSelection, source: UUID) -> String {
        "\(page.uuidString)|\(source.uuidString)|\(point.key)"
    }
}

/// A tooltip page drawn for one hovered data point. Its visuals are queried when it first appears.
struct TooltipPageView: View {
    @ObservedObject var runtime: ReportRuntime
    let store: DocumentStore
    let page: Page
    let point: DataPointSelection
    let sourceID: UUID

    var body: some View {
        let key = TooltipPages.key(page: page.id, point: point, source: sourceID)
        let data = runtime.tooltipData[key]
        let scale = TooltipPages.scale(for: page.size)
        ZStack(alignment: .topLeading) {
            store.theme.backgroundColor
            if let c = page.background.color { Color(hex: c).opacity(1 - page.background.transparency / 100) }
            ForEach(page.visuals.filter { !$0.isHidden }.sorted { $0.zIndex < $1.zIndex }) { spec in
                VisualView(spec: spec, data: data?[spec.id] ?? VisualData(), context: store.context(for: spec, interactive: false))
                    .frame(width: spec.frame.width, height: spec.frame.height)
                    .offset(x: spec.frame.x, y: spec.frame.y)
            }
            if data == nil { ProgressView().controlSize(.small).padding(Design.Space.s) }
        }
        .frame(width: page.size.width, height: page.size.height, alignment: .topLeading)
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: page.size.width * scale, height: page.size.height * scale, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).strokeBorder(Design.Palette.hairlineStrong))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
        .task(id: "\(key)#\(runtime.tooltipVersion)") { runtime.loadTooltip(page: page, point: point, sourceID: sourceID) }
        .accessibilityLabel("Tooltip page \(page.name)")
    }
}
