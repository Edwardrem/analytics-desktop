import Foundation
import FacetCore

/// Perspectives: named subsets of the model's tables, columns, measures and hierarchies.
enum PerspectiveLogic {
    enum Inclusion: Equatable { case none, some, all }

    /// Identifiers of everything in a table ("Table[Member]"), columns then measures then hierarchies.
    static func members(of table: ModelTable) -> [String] {
        (table.columns.map(\.name) + table.measures.map(\.name) + table.hierarchies.map(\.name))
            .map { ModelNames.identifier(table: table.name, name: $0) }
    }

    private static func has(_ members: [String], _ id: String) -> Bool { members.contains { ModelDAX.same($0, id) } }

    /// A table is fully included when it is listed itself (which includes anything added to it later)
    /// or when every one of its fields is listed.
    static func inclusion(of table: ModelTable, in members: [String]) -> Inclusion {
        if has(members, table.name) { return .all }
        let all = self.members(of: table)
        let included = all.filter { has(members, $0) }.count
        if included == 0 { return .none }
        return included == all.count ? .all : .some
    }

    static func isIncluded(_ identifier: String, in members: [String]) -> Bool {
        has(members, identifier) || has(members, ModelNames.split(identifier).table)
    }

    static func state(of identifier: String, in members: [String], model: SemanticModel) -> Inclusion {
        let (table, member) = ModelNames.split(identifier)
        if member == nil { return model.table(table).map { inclusion(of: $0, in: members) } ?? .none }
        return isIncluded(identifier, in: members) ? .all : .none
    }

    /// Includes or excludes a whole table.
    static func set(table: ModelTable, included: Bool, in members: [String]) -> [String] {
        var out = members.filter { !ModelDAX.same(ModelNames.split($0).table, table.name) }
        if included { out.append(table.name) }
        return out
    }

    /// Toggles a table (all ↔ none; a partly included table becomes fully included) or one field.
    static func toggle(_ identifier: String, in members: [String], model: SemanticModel) -> [String] {
        let (tableName, member) = ModelNames.split(identifier)
        guard let table = model.table(tableName) else { return members }
        guard member != nil else {
            return set(table: table, included: inclusion(of: table, in: members) != .all, in: members)
        }
        var out = members
        if has(out, table.name) {
            // Break the whole-table entry into its fields so one can be removed.
            out.removeAll { ModelDAX.same($0, table.name) }
            for m in self.members(of: table) where !has(out, m) { out.append(m) }
        }
        if has(out, identifier) { out.removeAll { ModelDAX.same($0, identifier) } } else { out.append(identifier) }
        return out
    }

    static func problems(_ perspectives: [Perspective]) -> [String] {
        var out: [String] = []
        for (i, p) in perspectives.enumerated() {
            let others = perspectives.enumerated().filter { $0.offset < i }.map(\.element.name)
            if let problem = ModelNames.problem(p.name, noun: "perspective", others: others), !out.contains(problem) { out.append(problem) }
        }
        return out
    }

    /// Trims names and drops members that no longer exist.
    static func cleaned(_ perspectives: [Perspective], model: SemanticModel) -> [Perspective] {
        perspectives.map { p in
            var p = p
            p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            p.members = p.members.filter { ModelNames.exists($0, in: model) }
            return p
        }
    }
}

/// Translations: cultures and per-object captions.
enum TranslationLogic {
    struct Object: Identifiable, Equatable {
        enum Kind: String { case table, column, measure, hierarchy }
        var id: String { identifier }
        var identifier: String
        var kind: Kind
        var table: String
        /// The name in the model's own language.
        var name: String
    }

    static func objects(_ model: SemanticModel) -> [Object] {
        model.tables.flatMap { t -> [Object] in
            [Object(identifier: t.name, kind: .table, table: t.name, name: t.name)]
                + t.columns.map { Object(identifier: ModelNames.identifier(table: t.name, name: $0.name), kind: .column, table: t.name, name: $0.name) }
                + t.measures.map { Object(identifier: ModelNames.identifier(table: t.name, name: $0.name), kind: .measure, table: t.name, name: $0.name) }
                + t.hierarchies.map { Object(identifier: ModelNames.identifier(table: t.name, name: $0.name), kind: .hierarchy, table: t.name, name: $0.name) }
        }
    }

    /// A culture is a language tag: a 2–3 letter language, optionally followed by script and region ("fr", "pt-BR", "zh-Hans-CN").
    static func isCultureTag(_ tag: String) -> Bool {
        let parts = tag.split(separator: "-", omittingEmptySubsequences: false)
        guard let language = parts.first, (2...3).contains(language.count), language.allSatisfy({ $0.isASCII && $0.isLetter }) else { return false }
        return parts.dropFirst().allSatisfy { p in (2...8).contains(p.count) && p.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    }

    /// Canonical casing: language lower, 4-letter script title-case, region upper ("PT-br" → "pt-BR").
    static func canonical(_ tag: String) -> String {
        let parts = tag.trimmingCharacters(in: .whitespaces).split(separator: "-").map(String.init)
        return parts.enumerated().map { i, p in
            if i == 0 { return p.lowercased() }
            if p.count == 4, p.allSatisfy(\.isLetter) { return p.prefix(1).uppercased() + p.dropFirst().lowercased() }
            return p.count <= 3 ? p.uppercased() : p.lowercased()
        }.joined(separator: "-")
    }

    static func cultureProblem(_ tag: String, existing: [String], modelCulture: String) -> String? {
        let t = canonical(tag)
        if t.isEmpty { return "Enter a culture such as fr-FR." }
        if !isCultureTag(t) { return "“\(tag)” isn't a culture. Use a language tag such as fr-FR or pt-BR." }
        if existing.contains(where: { ModelDAX.same($0, t) }) { return "\(t) has already been added." }
        if ModelDAX.same(modelCulture, t) { return "\(t) is the model's own language; its names are the captions." }
        return nil
    }

    static func displayName(_ culture: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: culture.replacingOccurrences(of: "-", with: "_")) ?? culture
    }

    static func caption(_ identifier: String, in t: Translation) -> String {
        t.captions.first { ModelDAX.same($0.key, identifier) }?.value ?? ""
    }
    /// Sets a caption; an empty caption removes the entry so the object falls back to its name.
    static func set(_ caption: String, for identifier: String, in t: inout Translation) {
        for key in t.captions.keys where ModelDAX.same(key, identifier) { t.captions[key] = nil }
        let c = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if !c.isEmpty { t.captions[identifier] = c }
    }

    static func coverage(_ t: Translation, objects: [Object]) -> (translated: Int, total: Int) {
        (objects.filter { !caption($0.identifier, in: t).isEmpty }.count, objects.count)
    }

    /// Drops blank captions and captions for objects that no longer exist.
    static func cleaned(_ translations: [Translation], model: SemanticModel) -> [Translation] {
        translations.map { t in
            var t = t
            t.culture = canonical(t.culture)
            t.captions = t.captions.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty && ModelNames.exists($0.key, in: model) }
            return t
        }
    }

    /// Two objects of one table that would show the same caption in a culture.
    static func duplicateCaptions(_ t: Translation, objects: [Object]) -> String? {
        var seen: [String: String] = [:]
        for o in objects where o.kind != .table {
            let c = caption(o.identifier, in: t)
            guard !c.isEmpty else { continue }
            let key = o.table.lowercased() + "|" + c.lowercased()
            if let other = seen[key] { return "In \(t.culture), “\(other)” and “\(o.name)” in \(o.table) would both be shown as “\(c)”." }
            seen[key] = o.name
        }
        return nil
    }
}

/// Synonyms (the linguistic schema): other words people use for tables, columns and measures.
enum SynonymLogic {
    struct Term: Identifiable, Equatable {
        var id: String { identifier }
        var identifier: String
        var kind: TranslationLogic.Object.Kind
        var table: String
        var name: String
        var synonyms: [String]
    }

    /// Splits "rev, turnover; Revenue" into distinct terms, dropping blanks, repeats and the object's own name.
    static func parse(_ text: String, ownName: String = "") -> [String] {
        var out: [String] = []
        for part in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == "\n" }) {
            let term = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if term.isEmpty || ModelDAX.same(term, ownName) || out.contains(where: { ModelDAX.same($0, term) }) { continue }
            out.append(term)
        }
        return out
    }

    static func terms(_ model: SemanticModel) -> [Term] {
        model.tables.flatMap { t -> [Term] in
            [Term(identifier: t.name, kind: .table, table: t.name, name: t.name, synonyms: t.synonyms)]
                + t.columns.map { Term(identifier: ModelNames.identifier(table: t.name, name: $0.name), kind: .column, table: t.name, name: $0.name, synonyms: $0.synonyms) }
                + t.measures.map { m in
                    let id = ModelNames.identifier(table: t.name, name: m.name)
                    let stored = model.qnaSynonyms.first { ModelDAX.same($0.key, id) }?.value ?? []
                    return Term(identifier: id, kind: .measure, table: t.name, name: m.name, synonyms: stored)
                }
        }
    }

    /// Writes one object's synonyms: tables and columns hold their own; measures are kept in the model's Q&A synonyms.
    static func set(_ synonyms: [String], for term: Term, in model: inout SemanticModel) {
        guard let ti = model.tableIndex(term.table) else { return }
        switch term.kind {
        case .table: model.tables[ti].synonyms = synonyms
        case .column:
            if let ci = model.tables[ti].columns.firstIndex(where: { ModelDAX.same($0.name, term.name) }) { model.tables[ti].columns[ci].synonyms = synonyms }
        case .measure, .hierarchy:
            for key in model.qnaSynonyms.keys where ModelDAX.same(key, term.identifier) { model.qnaSynonyms[key] = nil }
            if !synonyms.isEmpty { model.qnaSynonyms[term.identifier] = synonyms }
        }
    }

    /// Words that name more than one object (as a synonym or as the object's own name): a question using them is ambiguous.
    static func conflicts(_ terms: [Term]) -> [(word: String, objects: [String])] {
        var owners: [String: [String]] = [:]
        var spelling: [String: String] = [:]
        for t in terms {
            for word in [t.name] + t.synonyms {
                let key = word.lowercased()
                if owners[key]?.contains(t.identifier) == true { continue }
                owners[key, default: []].append(t.identifier)
                if spelling[key] == nil || t.synonyms.contains(word) { spelling[key] = word }
            }
        }
        let synonymWords = Set(terms.flatMap { $0.synonyms.map { $0.lowercased() } })
        return owners.filter { $0.value.count > 1 && synonymWords.contains($0.key) }
            .map { (word: spelling[$0.key] ?? $0.key, objects: $0.value) }
            .sorted { $0.word.lowercased() < $1.word.lowercased() }
    }

    /// Removes Q&A synonym entries whose measure is gone.
    static func pruned(_ model: SemanticModel) -> [String: [String]] {
        model.qnaSynonyms.filter { ModelNames.exists($0.key, in: model) && !$0.value.isEmpty }
    }
}

/// Prep data for AI: the AI data schema, verified answers and AI instructions.
enum AIPrepLogic {
    /// The longest instructions the assistant accepts.
    static let maximumInstructionLength = 10_000

    /// A field is in the AI data schema unless it, or its whole table, is excluded.
    static func isIncluded(_ identifier: String, excluded: [String]) -> Bool {
        !PerspectiveLogic.isIncluded(identifier, in: excluded)
    }
    /// The checklist state of an object, in terms of what the assistant may use.
    static func state(of identifier: String, excluded: [String], model: SemanticModel) -> PerspectiveLogic.Inclusion {
        switch PerspectiveLogic.state(of: identifier, in: excluded, model: model) {
        case .all: return .none
        case .some: return .some
        case .none: return .all
        }
    }
    /// Toggles whether the assistant may use a table or field. A partly excluded table becomes fully included.
    static func toggle(_ identifier: String, excluded: [String], model: SemanticModel) -> [String] {
        let (tableName, member) = ModelNames.split(identifier)
        if member == nil, let table = model.table(tableName) {
            let state = PerspectiveLogic.inclusion(of: table, in: excluded)
            return PerspectiveLogic.set(table: table, included: state == .none, in: excluded)
        }
        return PerspectiveLogic.toggle(identifier, in: excluded, model: model)
    }

    static func instructionsProblem(_ text: String) -> String? {
        text.count > maximumInstructionLength
            ? "AI instructions are limited to \(maximumInstructionLength.formatted()) characters; this is \(text.count.formatted())."
            : nil
    }

    static func problems(_ answers: [VerifiedAnswer], visualIDs: Set<UUID>) -> [String] {
        var out: [String] = []
        for a in answers {
            let q = a.question.trimmingCharacters(in: .whitespacesAndNewlines)
            if q.isEmpty { out.append("Every verified answer needs a question."); break }
        }
        if let dup = ModelNames.firstDuplicate(answers.map(\.question).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            out.append("Two verified answers use the question “\(dup)”.")
        }
        for a in answers where !a.question.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let id = a.visualID else { out.append("Choose the visual that answers “\(a.question)”."); continue }
            if !visualIDs.contains(id) { out.append("The visual that answered “\(a.question)” was deleted. Choose another.") }
        }
        return out
    }

    static func cleaned(_ answers: [VerifiedAnswer]) -> [VerifiedAnswer] {
        answers.map { a in
            var a = a
            a.question = a.question.trimmingCharacters(in: .whitespacesAndNewlines)
            a.answer = a.answer.trimmingCharacters(in: .whitespacesAndNewlines)
            return a
        }
    }
}
