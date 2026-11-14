import SwiftUI
import FacetCore
import FacetAnalytics
import FacetVisuals
import FacetDesign

/// Teach Q&A: submit a question, see how Q&A reads it, and define the words it didn't understand as a field
/// (a synonym) or a filter. Each saved term is one undoable model change, and the preview re-reads the question.
struct QnATeachView: View {
    @EnvironmentObject private var store: DocumentStore
    @Binding var question: String
    let values: [String: [Value]]

    @State private var asked = ""
    @State private var term = ""
    @State private var meaning: QnASetupLogic.Meaning = .field
    @State private var fieldKey = ""
    @State private var op: FilterOperator = .equals
    @State private var value = ""
    @State private var problem: String?
    @State private var saved: String?

    private var fields: [FieldRef] { QnASetupLogic.fields(store.model) }
    private var selectedField: FieldRef? { fields.first { $0.key == fieldKey } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Design.Space.l) {
                questionSection
                defineSection
                termsSection
            }
            .padding(Design.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { if asked.isEmpty { asked = QnASetupLogic.collapse(question) } }
        .onChange(of: fieldKey) {
            if let f = selectedField, !QnASetupLogic.operators(for: f, in: store.model).contains(op) { op = .equals }
        }
    }

    // MARK: Question

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("QUESTION").font(Design.Typeface.section).foregroundStyle(.secondary)
            HStack(spacing: Design.Space.s) {
                TextField("Type a question Q&A didn't understand", text: $question)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Submit", action: submit)
                    .disabled(QnASetupLogic.collapse(question).isEmpty)
                    .help("See how Q&A reads this question")
            }
            if !asked.isEmpty { preview(QnASetupLogic.parse(asked, model: store.model, values: values)) }
        }
    }

    private func preview(_ answer: QuestionAnswer) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text(answer.isAnswerable ? answer.interpretation : "Q&A can't answer this question yet.")
                .font(Design.Typeface.body)
                .fixedSize(horizontal: false, vertical: true)
            if answer.unrecognized.isEmpty {
                Label("Q&A understands every word in this question.", systemImage: "checkmark.circle")
                    .font(Design.Typeface.caption).foregroundStyle(Design.Palette.positive)
            } else {
                Text("Define the words Q&A didn't understand:").font(Design.Typeface.caption).foregroundStyle(.secondary)
                FlowLayout(spacing: 6, lineSpacing: 4) {
                    ForEach(answer.unrecognized, id: \.self) { word in
                        Button(word) { term = word; problem = nil; saved = nil }
                            .buttonStyle(.bordered).controlSize(.small)
                            .help("Define “\(word)”")
                    }
                }
            }
        }
        .padding(Design.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Design.Palette.fill, in: RoundedRectangle(cornerRadius: Design.Radius.control))
    }

    private func submit() {
        asked = QnASetupLogic.collapse(question)
        problem = nil
        saved = nil
    }

    // MARK: Define

    private var defineSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("DEFINE A TERM").font(Design.Typeface.section).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: Design.Space.m, verticalSpacing: Design.Space.s) {
                GridRow {
                    Text("Term").gridColumnAlignment(.trailing)
                    TextField("big orders", text: $term).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    Text("Means")
                    Picker("Means", selection: $meaning) {
                        ForEach(QnASetupLogic.Meaning.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                GridRow {
                    Text(meaning == .field ? "Field" : "Filter on")
                    Picker("Field", selection: $fieldKey) {
                        Text("Choose a field").tag("")
                        ForEach(fields, id: \.key) { f in
                            Text(QnASetupLogic.label(f) + (f.kind == .measure ? " (measure)" : "")).tag(f.key)
                        }
                    }
                    .labelsHidden().frame(maxWidth: 320)
                }
                if meaning == .filter, let field = selectedField {
                    GridRow {
                        Text("Condition")
                        HStack(spacing: Design.Space.s) {
                            Picker("Operator", selection: $op) {
                                ForEach(QnASetupLogic.operators(for: field, in: store.model), id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().frame(width: 200)
                            if op.needsValue {
                                TextField(QnASetupLogic.isNumeric(field, in: store.model) ? "30" : "North", text: $value)
                                    .textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                            }
                        }
                    }
                }
            }
            .font(Design.Typeface.body)
            HStack(spacing: Design.Space.s) {
                if let problem {
                    Text(problem).font(Design.Typeface.caption).foregroundStyle(Design.Palette.negative)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let saved {
                    Label(saved, systemImage: "checkmark.circle").font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save term", action: save)
                    .disabled(QnASetupLogic.collapse(term).isEmpty || selectedField == nil)
                    .help("Q&A uses the term from now on; Undo takes it back")
            }
        }
    }

    private func save() {
        guard let field = selectedField else { return }
        do {
            saved = try QnASetupLogic.teach(term, as: meaning, field: field, op: op, value: value, store: store)
            problem = nil
            term = ""
            value = ""
        } catch {
            problem = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            saved = nil
        }
    }

    // MARK: Terms

    private var termsSection: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Text("TERMS TAUGHT AS FILTERS").font(Design.Typeface.section).foregroundStyle(.secondary)
            let terms = store.model.qnaTerms ?? []
            if terms.isEmpty {
                Text("None yet.").font(Design.Typeface.caption).foregroundStyle(.secondary)
            }
            ForEach(terms) { t in
                HStack(spacing: Design.Space.s) {
                    Text(t.term).font(Design.Typeface.bodyStrong)
                    Text(ReportDescriber.describe(t.filter)).font(Design.Typeface.caption).foregroundStyle(.secondary)
                    Spacer()
                    IconButton("trash", help: "Forget “\(t.term)”") {
                        store.mutate("Forget Q&A Term", invalidates: .layout) { d in QnASetupLogic.removeTerm(t.id, in: &d.model) }
                    }
                }
            }
            Text("Terms taught as a field are kept as that field's synonyms, so they also appear in Modeling ▸ Synonyms.")
                .font(Design.Typeface.caption).foregroundStyle(Design.Palette.tertiaryText)
        }
    }
}
