import SwiftUI
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

// MARK: - Smart narrative

struct NarrativeView: View {
    let spec: VisualSpec
    let data: VisualData
    let context: VisualContext
    let store: DocumentStore

    var body: some View {
        let narrative = build()
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if narrative.isEmpty {
                    Text("Add visuals with data to this page and the summary is written here.")
                        .font(Design.Typeface.body).foregroundStyle(.secondary)
                } else {
                    // One flowing paragraph, with the figures picked out.
                    narrative.segments.reduce(Text("")) { $0 + segment($1) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func segment(_ s: Narrative.Segment) -> Text {
        switch s {
        case .text(let t): return Text(t).font(Design.Typeface.body)
        case .value(let v, _): return Text(v).font(Design.Typeface.bodyStrong).foregroundColor(Color.accentColor)
        }
    }

    private func build() -> Narrative {
        // A narrative with fields summarises its own data; otherwise it summarises the page.
        if !spec.fields(.values).isEmpty, data.table.rowCount > 0, data.error == nil {
            return SmartNarrative.summarize(data: data, spec: spec)
        }
        let page = store.currentPage.visuals.compactMap { v -> (VisualSpec, VisualData)? in
            guard v.id != spec.id, !v.type.isPageElement, !v.type.isSlicer,
                  let d = store.visualData[v.id], !d.isEmpty, d.error == nil else { return nil }
            return (v, d)
        }
        return SmartNarrative.summarize(page: page)
    }
}
