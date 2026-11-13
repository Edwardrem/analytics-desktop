import SwiftUI
import FacetCore
import FacetDesign

/// Perspectives: named subsets of the model.
struct PerspectivesSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var draft: [Perspective]
    @State private var selection: UUID?

    init(model: SemanticModel) {
        _draft = State(initialValue: model.perspectives)
        _selection = State(initialValue: model.perspectives.first?.id)
    }

    private var index: Int? { draft.firstIndex { $0.id == selection } }
    private var problems: [String] { PerspectiveLogic.problems(draft) }

    var body: some View {
        ModelingSheet(title: "Perspectives",
                      subtitle: "A perspective shows report authors a focused part of a large model. It is a view, not security.",
                      width: 720, height: 520) {
            HStack(spacing: 0) {
                NamedListColumn(items: draft.map { .init(id: $0.id, name: $0.name, symbol: "eye") }, selection: $selection,
                                addHelp: "New perspective", width: 200,
                                onAdd: {
                                    let p = Perspective(name: ModelOps.uniqueName("Perspective", among: draft.map(\.name)))
                                    draft.append(p); selection = p.id
                                },
                                onDelete: { id in draft.removeAll { $0.id == id }; selection = draft.first?.id },
                                onRename: { id, name in if let i = draft.firstIndex(where: { $0.id == id }) { draft[i].name = name } },
                                emptyTitle: "No perspectives")
                Hairline(vertical: true)
                if let i = index {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Included in “\(draft[i].name)”").font(Design.Typeface.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("All") { draft[i].members = store.model.tables.map(\.name) }
                            Button("None") { draft[i].members = [] }
                        }
                        .controlSize(.small).padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
                        Hairline()
                        ModelObjectChecklist(includeHierarchies: true,
                                             state: { PerspectiveLogic.state(of: $0, in: draft[i].members, model: store.model) },
                                             toggle: { draft[i].members = PerspectiveLogic.toggle($0, in: draft[i].members, model: store.model) })
                    }
                } else {
                    EmptyState(systemImage: "eye", title: "Create a perspective", message: "Add one, then tick the tables and fields it should show.")
                }
            }
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: !problems.isEmpty) {
                guard problems.isEmpty else { return }
                let cleaned = PerspectiveLogic.cleaned(draft, model: store.model)
                store.mutate("Edit Perspectives", invalidates: .layout) { $0.model.perspectives = cleaned }
                store.dismissSheet()
            }
        }
    }
}

/// Translations: cultures and the caption each object shows in them.
struct TranslationsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var draft: [FacetCore.Translation]
    @State private var selection: UUID?
    @State private var newCulture = ""
    @State private var search = ""
    @State private var untranslatedOnly = false

    init(model: SemanticModel) {
        _draft = State(initialValue: model.translations)
        _selection = State(initialValue: model.translations.first?.id)
    }

    private var index: Int? { draft.firstIndex { $0.id == selection } }
    private var objects: [TranslationLogic.Object] { TranslationLogic.objects(store.model) }
    private var cultureProblem: String? {
        newCulture.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : TranslationLogic.cultureProblem(newCulture, existing: draft.map(\.culture), modelCulture: store.model.culture)
    }
    private var warning: String? {
        for t in draft { if let w = TranslationLogic.duplicateCaptions(t, objects: objects) { return w } }
        return nil
    }

    var body: some View {
        ModelingSheet(title: "Translations",
                      subtitle: "Captions shown to people whose language differs from the model's (\(store.model.culture)). Objects without a caption keep their name.",
                      width: 860, height: 560) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    NamedListColumn(items: draft.map { t in
                        let c = TranslationLogic.coverage(t, objects: objects)
                        return .init(id: t.id, name: t.culture, symbol: "globe", detail: "\(c.translated)/\(c.total)")
                    }, selection: $selection, width: 210,
                                    onDelete: { id in draft.removeAll { $0.id == id }; selection = draft.first?.id },
                                    emptyTitle: "No cultures")
                    Hairline()
                    HStack(spacing: Design.Space.xs) {
                        TextField("fr-FR", text: $newCulture).textFieldStyle(.roundedBorder).onSubmit(addCulture)
                        Button("Add", action: addCulture)
                            .disabled(newCulture.trimmingCharacters(in: .whitespaces).isEmpty || cultureProblem != nil)
                    }
                    .padding(Design.Space.s)
                }
                .frame(width: 210)
                Hairline(vertical: true)
                if let i = index { captions(i) } else {
                    EmptyState(systemImage: "globe", title: "Add a culture", message: "Type a language tag such as fr-FR or ja-JP, then enter captions for it.")
                }
            }
        } footer: {
            DialogProblemLine(problem: cultureProblem, warning: warning)
            ModelingSheetButtons(confirmTitle: "Save") {
                let cleaned = TranslationLogic.cleaned(draft, model: store.model)
                store.mutate("Edit Translations", invalidates: .layout) { $0.model.translations = cleaned }
                store.dismissSheet()
            }
        }
    }

    private func captions(_ i: Int) -> some View {
        let shown = objects.filter { o in
            (search.isEmpty || o.name.localizedCaseInsensitiveContains(search) || TranslationLogic.caption(o.identifier, in: draft[i]).localizedCaseInsensitiveContains(search))
                && (!untranslatedOnly || TranslationLogic.caption(o.identifier, in: draft[i]).isEmpty)
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.s) {
                Text(TranslationLogic.displayName(draft[i].culture)).font(Design.Typeface.bodyStrong)
                Spacer()
                Toggle("Untranslated only", isOn: $untranslatedOnly).toggleStyle(.checkbox)
                TextField("Search", text: $search).textFieldStyle(.roundedBorder).frame(width: 150)
            }
            .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
            Hairline()
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { o in
                        HStack(spacing: Design.Space.s) {
                            Image(systemName: symbol(o.kind)).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(o.name).font(Design.Typeface.body).lineLimit(1)
                                if o.kind != .table { Text(o.table).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1) }
                            }
                            .frame(width: 200, alignment: .leading)
                            ModelTextField(placeholder: o.name, value: TranslationLogic.caption(o.identifier, in: draft[i])) { new in
                                if let k = draft.firstIndex(where: { $0.id == selection }) { TranslationLogic.set(new, for: o.identifier, in: &draft[k]) }
                            }
                            .textFieldStyle(.roundedBorder)
                            .id("\(draft[i].id)|\(o.identifier)")
                        }
                    }
                    if shown.isEmpty { Text("Nothing matches.").font(Design.Typeface.caption).foregroundStyle(.secondary).padding(Design.Space.m) }
                }
                .padding(Design.Space.m)
            }
        }
    }

    private func symbol(_ kind: TranslationLogic.Object.Kind) -> String {
        switch kind {
        case .table: return ModelGlyph.table
        case .column: return "tablecells"
        case .measure: return ModelGlyph.measure
        case .hierarchy: return ModelGlyph.hierarchy
        }
    }

    private func addCulture() {
        guard !newCulture.trimmingCharacters(in: .whitespaces).isEmpty, cultureProblem == nil else { return }
        let t = FacetCore.Translation(culture: TranslationLogic.canonical(newCulture))
        draft.append(t)
        selection = t.id
        newCulture = ""
    }
}

/// Synonyms: the other words people use for tables, columns and measures when they ask questions.
struct SynonymsSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var terms: [SynonymLogic.Term]
    @State private var search = ""

    init(model: SemanticModel) { _terms = State(initialValue: SynonymLogic.terms(model)) }

    private var conflicts: [(word: String, objects: [String])] { SynonymLogic.conflicts(terms) }

    var body: some View {
        ModelingSheet(title: "Synonyms",
                      subtitle: "Other names for your fields, separated by commas. Q&A and the assistant use them to match the words in a question.",
                      width: 760, height: 540) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    TextField("Search fields", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    Spacer()
                    Text("\(terms.filter { !$0.synonyms.isEmpty }.count) of \(terms.count) fields have synonyms")
                        .font(Design.Typeface.caption).foregroundStyle(.secondary)
                }
                .padding(Design.Space.m)
                Hairline()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach($terms) { $term in
                            if search.isEmpty || term.name.localizedCaseInsensitiveContains(search)
                                || term.synonyms.contains(where: { $0.localizedCaseInsensitiveContains(search) }) {
                                HStack(spacing: Design.Space.s) {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(term.name).font(term.kind == .table ? Design.Typeface.bodyStrong : Design.Typeface.body).lineLimit(1)
                                        if term.kind != .table { Text(term.table).font(Design.Typeface.caption).foregroundStyle(.tertiary).lineLimit(1) }
                                    }
                                    .frame(width: 210, alignment: .leading)
                                    ModelTextField(placeholder: "synonym, another synonym", value: term.synonyms.joined(separator: ", ")) { text in
                                        term.synonyms = SynonymLogic.parse(text, ownName: term.name)
                                    }
                                    .textFieldStyle(.roundedBorder)
                                }
                            }
                        }
                    }
                    .padding(Design.Space.m)
                }
            }
        } footer: {
            DialogProblemLine(warning: conflicts.first.map { "“\($0.word)” names \($0.objects.joined(separator: " and ")). A question using it is ambiguous." })
            ModelingSheetButtons(confirmTitle: "Save") {
                let edited = terms
                store.mutate("Edit Synonyms", invalidates: .layout) { d in
                    for t in edited { SynonymLogic.set(t.synonyms, for: t, in: &d.model) }
                    d.model.qnaSynonyms = SynonymLogic.pruned(d.model)
                }
                store.dismissSheet()
            }
        }
    }
}

/// Prep data for AI: which fields the assistant may use, instructions for it, and verified answers.
struct AIPrepSheet: View {
    @EnvironmentObject private var store: DocumentStore
    @State private var page = 0
    @State private var excluded: [String]
    @State private var instructions: String
    @State private var answers: [VerifiedAnswer]
    @State private var selection: UUID?

    init(model: SemanticModel) {
        _excluded = State(initialValue: model.aiExcludedFields)
        _instructions = State(initialValue: model.aiInstructions)
        _answers = State(initialValue: model.verifiedAnswers)
        _selection = State(initialValue: model.verifiedAnswers.first?.id)
    }

    private var visuals: [(id: UUID, label: String)] {
        store.report.pages.flatMap { p in p.visuals.map { (id: $0.id, label: "\(p.name) — \($0.name)") } }
    }
    private var problems: [String] {
        (AIPrepLogic.instructionsProblem(instructions).map { [$0] } ?? []) + AIPrepLogic.problems(answers, visualIDs: Set(visuals.map(\.id)))
    }

    var body: some View {
        ModelingSheet(title: "Prep data for AI",
                      subtitle: "Shape what the assistant knows about this model: the fields it may use, how it should behave, and answers you have checked.",
                      width: 780, height: 560) {
            VStack(alignment: .leading, spacing: 0) {
                Picker("Section", selection: $page) {
                    Text("AI data schema").tag(0)
                    Text("Verified answers").tag(1)
                    Text("AI instructions").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 420).padding(Design.Space.m)
                Hairline()
                switch page {
                case 0: schema
                case 1: verified
                default: instructionsEditor
                }
            }
        } footer: {
            DialogProblemLine(problem: problems.first)
            ModelingSheetButtons(confirmTitle: "Save", confirmDisabled: !problems.isEmpty) {
                guard problems.isEmpty else { return }
                let model = store.model
                let keep = excluded.filter { ModelNames.exists($0, in: model) }
                let text = instructions, cleaned = AIPrepLogic.cleaned(answers)
                store.mutate("Prep Data for AI", invalidates: .layout) { d in
                    d.model.aiExcludedFields = keep
                    d.model.aiInstructions = text
                    d.model.verifiedAnswers = cleaned
                }
                store.dismissSheet()
            }
        }
    }

    private var schema: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Ticked tables and fields are available to the assistant. Untick anything it should ignore.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
                .padding(.horizontal, Design.Space.m).padding(.top, Design.Space.s)
            ModelObjectChecklist(state: { AIPrepLogic.state(of: $0, excluded: excluded, model: store.model) },
                                 toggle: { excluded = AIPrepLogic.toggle($0, excluded: excluded, model: store.model) })
        }
    }

    private var verified: some View {
        HStack(spacing: 0) {
            NamedListColumn(items: answers.map { .init(id: $0.id, name: $0.question.isEmpty ? "New question" : $0.question, symbol: "checkmark.seal") },
                            selection: $selection, addHelp: "New verified answer", width: 260,
                            onAdd: {
                                var a = VerifiedAnswer(question: "")
                                a.visualID = store.selectedVisual?.id
                                answers.append(a); selection = a.id
                            },
                            onDelete: { id in answers.removeAll { $0.id == id }; selection = answers.first?.id },
                            emptyTitle: "No verified answers")
            Hairline(vertical: true)
            if let i = answers.firstIndex(where: { $0.id == selection }) {
                VStack(alignment: .leading, spacing: Design.Space.m) {
                    ModelField("When someone asks") {
                        TextField("What were sales last quarter?", text: $answers[i].question).textFieldStyle(.roundedBorder)
                    }
                    ModelField("Answer with this visual") {
                        Picker("Visual", selection: $answers[i].visualID) {
                            Text("—").tag(UUID?.none)
                            ForEach(visuals, id: \.id) { v in Text(v.label).tag(UUID?.some(v.id)) }
                        }.labelsHidden().frame(width: 320)
                    }
                    ModelField("Note shown with the answer (optional)") {
                        TextField("How this number is defined", text: $answers[i].answer, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(3...6)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Design.Space.m)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                EmptyState(systemImage: "checkmark.seal", title: "Add a verified answer", message: "Tie a common question to the visual that answers it correctly.")
            }
        }
    }

    private var instructionsEditor: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            Text("Business context, terminology and rules the assistant should follow when it works with this model.")
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
            TextEditor(text: $instructions)
                .font(Design.Typeface.body)
                .scrollContentBackground(.hidden)
                .padding(Design.Space.xs)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).fill(Design.Palette.elevated))
                .overlay(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous).strokeBorder(Design.Palette.hairlineStrong))
                .accessibilityLabel("AI instructions")
            Text("\(instructions.count.formatted()) of \(AIPrepLogic.maximumInstructionLength.formatted()) characters")
                .font(Design.Typeface.caption)
                .foregroundStyle(instructions.count > AIPrepLogic.maximumInstructionLength ? Design.Palette.negative : Color.secondary)
        }
        .padding(Design.Space.m)
    }
}
