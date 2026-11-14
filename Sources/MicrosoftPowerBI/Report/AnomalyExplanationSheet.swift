import SwiftUI
import Charts
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

// MARK: - Store

extension DocumentStore {
    /// Opens the possible explanations of an anomaly flagged on a visual of the current page.
    func explainAnomaly(in visualID: UUID, anomaly: AnalyticsOverlays.Anomaly) {
        guard let spec = currentPage.visual(visualID), let data = visualData[visualID],
              let plan = AnomalyExplanations.plan(spec: spec, data: data, anomaly: anomaly) else {
            status = StatusMessage(kind: .info, text: "This anomaly is no longer in the visual's data. Click it again once the visual has refreshed.")
            return
        }
        let request = self.request(for: spec, on: currentPage)
        let model = self.model
        present { AnomalyExplanationSheet(session: AnomalyExplanationSession(store: self, plan: plan, request: request, model: model)) }
    }
}

@MainActor
final class AnomalyExplanationSession: ObservableObject {
    let plan: AnomalyExplanations.Plan
    @Published private(set) var explanations: [AnomalyExplanations.Explanation]?
    @Published private(set) var dimensions: [FieldRef] = []
    @Published private(set) var running = false
    private weak var store: DocumentStore?
    private let request: VisualRequest
    private let model: SemanticModel

    init(store: DocumentStore, plan: AnomalyExplanations.Plan, request: VisualRequest, model: SemanticModel) {
        self.store = store; self.plan = plan; self.request = request; self.model = model
    }

    func run() {
        guard let store, !running, explanations == nil else { return }
        let plan = plan, request = request, model = model
        running = true
        Task {
            let found = await store.withEngine { engine -> ([FieldRef], [AnomalyExplanations.Explanation]) in
                let dims = AnomalyExplanations.dimensions(for: plan, model: model, data: engine.data)
                return (dims, AnomalyExplanations.explain(plan, dimensions: dims, request: request, engine: engine))
            }
            self.dimensions = found.0
            self.explanations = found.1
            self.running = false
        }
    }
}

/// The anomaly panel: the point against its expected range, then the possible explanations, each
/// with its strength and the member's own line, the anomaly marked on it.
struct AnomalyExplanationSheet: View {
    @StateObject var session: AnomalyExplanationSession
    @Environment(\.dismiss) private var dismiss

    private var plan: AnomalyExplanations.Plan { session.plan }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text("Anomaly").font(Design.Typeface.headline)
                Text(plan.label).font(Design.Typeface.body).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Hairline()
            summary.padding(.horizontal).padding(.vertical, Design.Space.m)
            Hairline()
            content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 480, idealWidth: 560, minHeight: 420, idealHeight: 520)
        .onAppear { session.run() }
    }

    private func number(_ v: Double) -> String { ValueFormatter.format(.double(v), plan.measureFormat) }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text(number(plan.value)).font(Design.Typeface.title).monospacedDigit()
                Text(plan.measure.caption).font(Design.Typeface.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Label(plan.isHigh ? "Higher than expected" : "Lower than expected",
                      systemImage: plan.isHigh ? "arrow.up.right" : "arrow.down.right")
                    .font(Design.Typeface.captionStrong).foregroundStyle(Design.Palette.caution)
            }
            Text(AnomalyExplanations.summary(plan)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var content: some View {
        if let found = session.explanations {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    Text("POSSIBLE EXPLANATIONS").font(Design.Typeface.section).foregroundStyle(.secondary)
                    if found.isEmpty {
                        PaneNote(session.dimensions.isEmpty
                                 ? "No field can split this point. Add fields under Explain by on the Anomalies card in the Analytics pane."
                                 : "No member of the fields tried accounts for enough of the gap to explain it.")
                    }
                    ForEach(found) { e in
                        explanation(e)
                        Hairline()
                    }
                    if !session.dimensions.isEmpty {
                        PaneNote("Explained by " + session.dimensions.map(\.caption).joined(separator: ", ")
                                 + (plan.explainBy.isEmpty ? ". Choose the fields under Explain by on the Anomalies card." : "."))
                    }
                }
                .padding()
            }
        } else {
            ProgressView("Looking for possible explanations…").frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func explanation(_ e: AnomalyExplanations.Explanation) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                VStack(alignment: .leading, spacing: Design.Space.xxs) {
                    Text(e.dimension.caption).font(Design.Typeface.caption).foregroundStyle(.secondary)
                    Text(AnomalyExplanations.member(e.member)).font(Design.Typeface.bodyStrong).lineLimit(1)
                }
                Spacer(minLength: Design.Space.s)
                VStack(alignment: .trailing, spacing: Design.Space.xxs) {
                    Text("Strength").font(Design.Typeface.caption).foregroundStyle(.secondary)
                    Text("\(Int(e.strength.rounded()))%").font(Design.Typeface.bodyStrong).monospacedDigit()
                }
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Design.Palette.fill)
                    Capsule().fill(Design.Palette.accent).frame(width: geo.size.width * CGFloat(min(max(e.strength, 0), 100) / 100))
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Strength \(Int(e.strength.rounded())) percent")
            Text(AnomalyExplanations.sentence(e, high: plan.isHigh, format: plan.measureFormat))
                .font(Design.Typeface.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            trend(e).frame(height: 56)
        }
    }

    private func trend(_ e: AnomalyExplanations.Explanation) -> some View {
        Chart {
            ForEach(e.trend.indices, id: \.self) { i in
                LineMark(x: .value("Point", i), y: .value(plan.measure.caption, e.trend[i]))
                    .foregroundStyle(Color.secondary).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            if let v = e.trend[safe: plan.index] {
                PointMark(x: .value("Point", plan.index), y: .value(plan.measure.caption, v))
                    .symbol(.circle).symbolSize(40).foregroundStyle(Design.Palette.caution)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis { AxisMarks(values: .automatic(desiredCount: 2)) { _ in AxisValueLabel().font(Design.Typeface.caption) } }
        .accessibilityLabel("\(e.dimension.caption) \(AnomalyExplanations.member(e.member)) across \(plan.axisFields.map(\.caption).joined(separator: " "))")
    }
}
