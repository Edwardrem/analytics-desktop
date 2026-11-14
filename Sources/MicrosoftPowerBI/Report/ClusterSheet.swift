import SwiftUI
import FacetCore
import FacetAnalytics
import FacetDesign

/// The clusters dialog's state: the name, field, description and number of clusters, and the
/// engine run that finds them.
@MainActor
final class ClusterSession: ObservableObject {
    let plan: ClusterFields.Plan
    @Published var name: String
    @Published var field: FieldRef { didSet { if field.key != oldValue.key, name == autoName { name = ClusterFields.defaultName(for: field, model: model); autoName = name } } }
    @Published var details = ""
    /// Nil finds the number of clusters automatically.
    @Published var clusters: Int?
    @Published private(set) var running = false
    @Published private(set) var failure: String?
    private weak var store: DocumentStore?
    private let request: VisualRequest
    private var autoName: String

    private var model: SemanticModel { store?.model ?? SemanticModel() }

    init(store: DocumentStore, plan: ClusterFields.Plan, request: VisualRequest) {
        self.store = store; self.plan = plan; self.request = request
        let first = plan.candidates.first ?? FieldRef.column("", "")
        field = first
        let name = ClusterFields.defaultName(for: first, model: store.model)
        self.name = name
        autoName = name
    }

    var problems: [String] { ClusterFields.problems(name: name, field: field, model: model) }

    /// Finds the clusters with the engine, then adds the field and places it on the visual.
    func run() {
        guard let store, problems.isEmpty, !running else { return }
        let field = field, measures = plan.measures, request = request, k = clusters
        let name = name, details = details, visualID = plan.visualID
        running = true
        failure = nil
        Task {
            let outcome = await store.withEngine { engine -> Result<ModelColumn, Error> in
                let found = ClusterFields.points(field: field, measures: measures, request: request, engine: engine)
                return Result {
                    let g = try ClusterFields.grouping(source: field.name, members: found.members, points: found.points, clusters: k)
                    return ClusterFields.column(name: name, description: details, grouping: g)
                }
            }
            self.running = false
            switch outcome {
            case .success(let column):
                store.addClusterField(column, source: field, visualID: visualID)
                store.dismissSheet()
            case .failure(let error):
                self.failure = (error as? LocalizedError)?.errorDescription ?? "The clusters couldn't be found."
            }
        }
    }
}

/// Automatically find clusters: name the new field, pick the field whose members are clustered and
/// how many clusters to make (or let it find the number).
struct ClusterSheet: View {
    @StateObject var session: ClusterSession

    var body: some View {
        ModelingSheet(title: "Clusters",
                      subtitle: "A new field that groups \(session.field.caption) by \(session.plan.measures.map(\.caption).joined(separator: ", ")).",
                      width: 520, height: nil) {
            VStack(alignment: .leading, spacing: Design.Space.m) {
                ModelField("Name") { TextField("Name", text: $session.name).textFieldStyle(.roundedBorder) }
                ModelField("Field") {
                    if session.plan.candidates.count > 1 {
                        Picker("Field", selection: Binding(get: { session.field.key }, set: { k in
                            if let f = session.plan.candidates.first(where: { $0.key == k }) { session.field = f }
                        })) {
                            ForEach(session.plan.candidates, id: \.key) { Text($0.caption).tag($0.key) }
                        }
                        .labelsHidden().fixedSize()
                    } else {
                        Text(session.field.caption).font(Design.Typeface.body).frame(height: 22)
                    }
                }
                ModelField("Description") { TextField("Optional", text: $session.details).textFieldStyle(.roundedBorder) }
                ModelField("Number of clusters") {
                    HStack(spacing: Design.Space.s) {
                        Picker("Number of clusters", selection: Binding(get: { session.clusters == nil }, set: { auto in
                            session.clusters = auto ? nil : (session.clusters ?? 3)
                        })) {
                            Text("Auto").tag(true)
                            Text("Fixed").tag(false)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        if let n = session.clusters {
                            Stepper(value: Binding(get: { n }, set: { session.clusters = min(max($0, 2), ClusterFields.maxClusters) }),
                                    in: 2...ClusterFields.maxClusters) {
                                Text("\(n) clusters").font(Design.Typeface.body).monospacedDigit()
                            }
                            .fixedSize()
                        }
                    }
                }
                PaneNote("Each member of \(session.field.caption) joins the cluster nearest to it. Members without every number go to “\(ClusterFields.otherGroupName)”. Edit the clusters later as groups.")
            }
            .padding(Design.Space.l)
        } footer: {
            DialogProblemLine(problem: session.failure ?? session.problems.first)
            if session.running { ProgressView().controlSize(.small) }
            ModelingSheetButtons(confirmTitle: "OK", confirmDisabled: !session.problems.isEmpty || session.running, confirm: session.run)
        }
    }
}
