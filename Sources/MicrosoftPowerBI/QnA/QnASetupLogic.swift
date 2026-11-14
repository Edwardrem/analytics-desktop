import Foundation
import FacetCore
import FacetAnalytics

/// Q&A setup: Teach Q&A defines a term as a field (stored as that field's synonym, so the Synonyms dialog and
/// TMDL see it) or as a filter (stored in the model's taught terms); Review questions lists what was asked in
/// this file and whether Q&A understands it now.
enum QnASetupLogic {
    static let maxTermLength = 60
    static let maxValueLength = 120

    enum Meaning: String, CaseIterable, Identifiable {
        case field = "A field", filter = "A filter"
        var id: String { rawValue }
    }

    enum TeachError: LocalizedError, Equatable {
        case emptyTerm, termTooLong, controlCharacters
        case nameInUse(String)
        case noSuchField(String)
        case valueNeeded, valueTooLong
        case notANumber(String)

        var errorDescription: String? {
            switch self {
            case .emptyTerm: return "Type the word or phrase to teach."
            case .termTooLong: return "Keep the term to \(QnASetupLogic.maxTermLength) characters or fewer."
            case .controlCharacters: return "The term and value must be on one line, without tabs or control characters."
            case .nameInUse(let owner): return "That term already means \(owner). Pick another word, or change it in Synonyms."
            case .noSuchField(let name): return "The model has no field named \(name)."
            case .valueNeeded: return "Type the value the filter compares with."
            case .valueTooLong: return "Keep the value to \(QnASetupLogic.maxValueLength) characters or fewer."
            case .notANumber(let field): return "\(field) holds numbers, so the value must be a number."
            }
        }
    }

    // MARK: Fields and operators

    /// The fields a term can mean or filter on: each visible table's visible columns, then its visible measures.
    static func fields(_ model: SemanticModel) -> [FieldRef] {
        model.tables.filter { !$0.isHidden }.flatMap { t in
            t.columns.filter { !$0.isHidden }.map { FieldRef.column(t.name, $0.name) }
                + t.measures.filter { !$0.isHidden }.map { FieldRef.measure(t.name, $0.name) }
        }
    }

    /// True when the filter compares numbers: a measure, or a numeric column.
    static func isNumeric(_ field: FieldRef, in model: SemanticModel) -> Bool {
        if field.kind == .measure { return true }
        return model.table(field.table)?.column(field.name)?.dataType.isNumeric ?? false
    }

    static func operators(for field: FieldRef, in model: SemanticModel) -> [FilterOperator] {
        isNumeric(field, in: model)
            ? [.equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .isBlank, .isNotBlank]
            : [.equals, .notEquals, .contains, .startsWith, .isBlank, .isNotBlank]
    }

    static func label(_ field: FieldRef) -> String { "\(field.table)[\(field.name)]" }

    // MARK: Validation

    /// The term with its spacing collapsed. Rejects a blank or over-long term, line breaks and control characters,
    /// and a term that already names a table, column or measure, or is another field's synonym.
    static func validTerm(_ raw: String, model: SemanticModel, allowing field: FieldRef? = nil) throws -> String {
        guard !hasControlCharacters(raw) else { throw TeachError.controlCharacters }
        let term = collapse(raw)
        guard !term.isEmpty else { throw TeachError.emptyTerm }
        guard term.count <= maxTermLength else { throw TeachError.termTooLong }
        if let owner = owner(of: term, in: model), owner.identifier != field.map(identifier) {
            throw TeachError.nameInUse(owner.label)
        }
        return term
    }

    static func hasControlCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func same(_ a: String, _ b: String) -> Bool { collapse(a).caseInsensitiveCompare(collapse(b)) == .orderedSame }

    private static func identifier(_ field: FieldRef) -> String { "\(field.table)[\(field.name)]" }

    /// The table, column or measure a term already names, by its name or as one of its synonyms.
    private static func owner(of term: String, in model: SemanticModel) -> (identifier: String, label: String)? {
        for t in model.tables {
            if same(t.name, term) || t.synonyms.contains(where: { same($0, term) }) { return (t.name, "the \(t.name) table") }
            for c in t.columns where same(c.name, term) || c.synonyms.contains(where: { same($0, term) }) {
                return ("\(t.name)[\(c.name)]", "\(t.name)[\(c.name)]")
            }
            for m in t.measures {
                let id = "\(t.name)[\(m.name)]"
                let synonyms = model.qnaSynonyms.first { same($0.key, id) || same($0.key, m.name) }?.value ?? []
                if same(m.name, term) || synonyms.contains(where: { same($0, term) }) { return (id, "the \(m.name) measure") }
            }
        }
        return nil
    }

    private static func requireField(_ field: FieldRef, in model: SemanticModel) throws {
        guard QuestionParser.exists(field, in: model) else { throw TeachError.noSuchField(label(field)) }
    }

    // MARK: Teaching

    /// Teaches `raw` to mean `field`: the term joins the field's synonyms, and stops being a taught filter.
    static func teachField(_ raw: String, field: FieldRef, in model: inout SemanticModel) throws {
        try requireField(field, in: model)
        let term = try validTerm(raw, model: model, allowing: field)
        guard let ti = model.tableIndex(field.table) else { throw TeachError.noSuchField(label(field)) }
        removeTerm(matching: term, in: &model)
        if field.kind == .measure {
            let key = model.qnaSynonyms.keys.first { same($0, identifier(field)) } ?? identifier(field)
            var list = model.qnaSynonyms[key] ?? []
            if !list.contains(where: { same($0, term) }) { list.append(term) }
            model.qnaSynonyms[key] = list
        } else if let ci = model.tables[ti].columns.firstIndex(where: { $0.name.caseInsensitiveCompare(field.name) == .orderedSame }) {
            if !model.tables[ti].columns[ci].synonyms.contains(where: { same($0, term) }) {
                model.tables[ti].columns[ci].synonyms.append(term)
            }
        } else {
            throw TeachError.noSuchField(label(field))
        }
    }

    /// Teaches `raw` to mean a filter on `field`; a term taught before is redefined.
    static func teachFilter(_ raw: String, field: FieldRef, op: FilterOperator, value rawValue: String,
                            in model: inout SemanticModel) throws {
        try requireField(field, in: model)
        let term = try validTerm(raw, model: model)
        let filter = try makeFilter(field: field, op: op, value: rawValue, model: model)
        var terms = model.qnaTerms ?? []
        if let i = terms.firstIndex(where: { same($0.term, term) }) {
            terms[i].term = term
            terms[i].filter = filter
        } else {
            terms.append(QnATerm(term: term, filter: filter))
        }
        model.qnaTerms = terms
    }

    /// The filter a term stands for, built the way the question parser builds one for "<field> <op> <value>".
    static func makeFilter(field: FieldRef, op: FilterOperator, value rawValue: String, model: SemanticModel) throws -> FilterSpec {
        var f = FilterSpec(field: field, kind: op == .equals ? .basic : .advanced)
        guard op.needsValue else {
            f.kind = .advanced
            f.conditions = [FilterCondition(op: op)]
            return f
        }
        guard !hasControlCharacters(rawValue) else { throw TeachError.controlCharacters }
        let text = collapse(rawValue)
        guard !text.isEmpty else { throw TeachError.valueNeeded }
        guard text.count <= maxValueLength else { throw TeachError.valueTooLong }
        let value: Value
        if isNumeric(field, in: model) {
            guard let n = Double(text), n.isFinite else { throw TeachError.notANumber(field.name) }
            value = n == n.rounded() && abs(n) < 1e15 ? .int(Int64(n)) : .double(n)
        } else {
            value = .string(text)
        }
        if op == .equals { f.values = [value] } else { f.conditions = [FilterCondition(op: op, value: value)] }
        return f
    }

    /// Teaches a term as one undoable model change and returns the confirmation to show. Nothing changes when the
    /// term, field or value is not valid.
    @MainActor @discardableResult
    static func teach(_ term: String, as meaning: Meaning, field: FieldRef, op: FilterOperator = .equals, value: String = "",
                      store: DocumentStore) throws -> String {
        var model = store.model
        switch meaning {
        case .field: try teachField(term, field: field, in: &model)
        case .filter: try teachFilter(term, field: field, op: op, value: value, in: &model)
        }
        store.mutate("Teach Q&A", invalidates: .layout) { d in d.model = model }
        let text = collapse(term)
        let filter = model.qnaTerms?.first { same($0.term, text) }?.filter
        let meaningText = meaning == .field ? label(field) : (filter.map(ReportDescriber.describe) ?? label(field))
        return "“\(text)” now means \(meaningText)."
    }

    /// Puts a new question in a Q&A visual and keeps it for Review questions, as one undo step.
    @MainActor
    static func ask(_ question: String, visual id: UUID, store: DocumentStore) {
        store.mutate("Ask a Question", invalidates: .visuals([id])) { d in
            for p in d.report.pages.indices {
                if let i = d.report.pages[p].visuals.firstIndex(where: { $0.id == id }) { d.report.pages[p].visuals[i].content = question }
            }
            d.model.recordQuestion(question, at: Date())
        }
    }

    static func removeTerm(_ id: UUID, in model: inout SemanticModel) {
        guard var terms = model.qnaTerms else { return }
        terms.removeAll { $0.id == id }
        model.qnaTerms = terms.isEmpty ? nil : terms
    }

    private static func removeTerm(matching term: String, in model: inout SemanticModel) {
        guard var terms = model.qnaTerms else { return }
        terms.removeAll { same($0.term, term) }
        model.qnaTerms = terms.isEmpty ? nil : terms
    }

    static func removeQuestion(_ id: UUID, in model: inout SemanticModel) {
        guard var log = model.qnaQuestions else { return }
        log.removeAll { $0.id == id }
        model.qnaQuestions = log.isEmpty ? nil : log
    }

    // MARK: Review

    enum Status: Equatable {
        /// A verified answer covers the question.
        case verified
        /// The parser understands every word; the text is its interpretation.
        case understood(String)
        /// The parser answers, but these words meant nothing to it.
        case partly([String])
        /// Nothing in the question matched the model.
        case notUnderstood([String])

        var needsTeaching: Bool {
            switch self { case .verified, .understood: return false; case .partly, .notUnderstood: return true }
        }
    }

    struct Review: Identifiable, Equatable {
        var record: QnAQuestionRecord
        var status: Status
        var id: UUID { record.id }
    }

    /// Parses `question` as Q&A would, with the model's synonyms and taught terms and the preloaded column values.
    static func parse(_ question: String, model: SemanticModel, values: [String: [Value]]) -> QuestionAnswer {
        QuestionParser(model: model, synonyms: model.qnaSynonyms, distinctValues: { values[valueKey($0)] ?? [] }).parse(question)
    }

    static func status(of question: String, model: SemanticModel, values: [String: [Value]]) -> Status {
        if VerifiedAnswerMatcher.match(question, in: model.verifiedAnswers) != nil { return .verified }
        let answer = parse(question, model: model, values: values)
        if !answer.isAnswerable { return .notUnderstood(answer.unrecognized) }
        return answer.unrecognized.isEmpty ? .understood(answer.interpretation) : .partly(answer.unrecognized)
    }

    /// The questions asked in this file, most recent first, each with how Q&A answers it today.
    static func review(_ model: SemanticModel, values: [String: [Value]]) -> [Review] {
        (model.qnaQuestions ?? []).map { Review(record: $0, status: status(of: $0.question, model: model, values: values)) }
    }

    /// The key the question parser's value lookup uses for a column.
    static func valueKey(_ field: FieldRef) -> String { "\(field.table)|\(field.name)" }

    /// The text columns whose values Q&A recognises in questions ("for North"): the first 12 visible ones.
    static func valueColumns(_ model: SemanticModel) -> [FieldRef] {
        var fields: [FieldRef] = []
        for t in model.tables where !t.isHidden {
            for c in t.columns where !c.isHidden && c.dataType == .text && fields.count < 12 {
                fields.append(.column(t.name, c.name))
            }
        }
        return fields
    }

    /// Loads the distinct values of `valueColumns` from the engine, so filter values are recognised.
    @MainActor
    static func loadValues(_ store: DocumentStore) async -> [String: [Value]] {
        let fields = valueColumns(store.model)
        guard !fields.isEmpty else { return [:] }
        return await store.withEngine { engine in
            var d: [String: [Value]] = [:]
            for f in fields { d[valueKey(f)] = engine.distinctValues(field: f, filters: [], limit: 100) }
            return d
        }
    }
}
