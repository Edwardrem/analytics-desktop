import SwiftUI
import FacetCore
import FacetDesign
import FacetQuery

/// Query Settings: the query's name and properties, and its Applied Steps with settings gears, folding
/// indicators and the step context menu.
struct QuerySettingsPane: View {
    @ObservedObject var session: QueryEditorSession
    @State private var name = ""
    @State private var renaming: Int?
    @State private var stepName = ""
    @State private var deleting: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Query Settings").font(Design.Typeface.headline).padding(Design.Space.m)
            Hairline()
            if let q = session.selectedQuery {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    SectionLabel("Properties")
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                        .onSubmit { if session.renameQuery(q.id, to: name) != nil { name = q.name } }
                    Button("All Properties") { session.dialog = .queryProperties(q.id) }.buttonStyle(.link).font(Design.Typeface.caption)
                }
                .padding(Design.Space.m)
                .onAppear { name = q.name }
                .onChange(of: q.name) { _, new in name = new }
                Hairline()
                if q.kind != .parameter { steps }
            } else {
                EmptyState(systemImage: "list.bullet.rectangle", title: "No query selected")
            }
            Spacer(minLength: 0)
        }
        .confirmationDialog("Delete step?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { i in
            Button("Delete", role: .destructive) { session.deleteStep(at: i) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Steps after it that use its result may stop working.")
        }
    }

    private var steps: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Applied Steps").padding(.horizontal, Design.Space.m).padding(.top, Design.Space.m).padding(.bottom, Design.Space.xs)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    let all = session.steps
                    ForEach(Array(all.enumerated()), id: \.offset) { i, step in row(i, step, count: all.count) }
                }
            }
        }
    }

    private func row(_ i: Int, _ step: MStep, count: Int) -> some View {
        let selected = session.currentStepIndex == i
        let settings = StepSettings.dialog(forStep: i, in: session)
        return HStack(spacing: Design.Space.xs) {
            if renaming == i {
                TextField("Step name", text: $stepName).textFieldStyle(.roundedBorder)
                    .onSubmit { session.renameStep(at: i, to: stepName); renaming = nil }
                    .onExitCommand { renaming = nil }
            } else {
                Text(step.name).lineLimit(1).truncationMode(.middle).help(step.name)
            }
            Spacer(minLength: 0)
            let description = step.description
            if !description.isEmpty {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.secondary).help(description)
            }
            if let settings {
                Button { session.selectStep(i); session.dialog = settings } label: { Image(systemName: "gearshape").font(.system(size: 11)) }
                    .buttonStyle(.plain).help("Edit the settings of “\(step.name)”")
            }
            foldingIcon(step.name)
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, 4)
        .background(selected ? Design.Palette.accent.opacity(0.16) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { stepName = step.name; renaming = i }
        .onTapGesture { session.selectStep(i) }
        .contextMenu {
            Button("Edit Settings") { if let settings { session.selectStep(i); session.dialog = settings } }.disabled(settings == nil)
            Button("Rename") { stepName = step.name; renaming = i }
            Button("Delete") { if i == count - 1 { session.deleteStep(at: i) } else { deleting = i } }.disabled(count <= 1)
            Button("Delete Until End") { session.deleteUntilEnd(from: i) }.disabled(i == 0)
            Button("Insert Step After") { session.selectStep(i); session.insertCustomStep() }
            Divider()
            Button("Properties…") { session.dialog = .stepProperties(index: i) }
            Divider()
            Button("Move Before") { session.moveStep(at: i, by: -1) }.disabled(i == 0)
            Button("Move After") { session.moveStep(at: i, by: 1) }.disabled(i >= count - 1)
            Divider()
            Button("View Native Query") {
                if let q = session.folding[step.name]?.nativeQuery { session.dialog = .nativeQuery(q) }
            }
            .disabled(session.folding[step.name]?.nativeQuery == nil)
            Button("Diagnose") { session.selectStep(i); session.diagnoseStep() }
        }
    }

    @ViewBuilder
    private func foldingIcon(_ step: String) -> some View {
        if let info = session.folding[step] {
            switch info.indicator {
            case .folded:
                Image(systemName: "cylinder.split.1x2.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor)
                    .help("Folded: the data source evaluates this step")
            case .notFolded:
                Image(systemName: "cylinder.split.1x2").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help("Not folded: this step runs on this Mac on the rows the source returned")
            case .notEvaluated:
                Image(systemName: "questionmark.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help("Not evaluated: the result does not need this step")
            case .notApplicable:
                EmptyView()
            }
        }
    }
}
