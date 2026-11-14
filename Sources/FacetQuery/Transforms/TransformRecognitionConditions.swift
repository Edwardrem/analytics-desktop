import Foundation
import FacetCore

/// Rebuilds the row conditions of Filter Rows from the M that `FilterCondition.mExpression` emits.
enum FilterRecognizer {
    /// The condition a filter's `each` body expresses, or nil when it is not one the filter UI builds.
    static func condition(_ body: StepFragment, previous p: String) -> FilterCondition? {
        let wanted = body.key
        for c in leaves(body, previous: p) where StepFragment.key(c.mExpression(previous: p)) == wanted { return c }
        let t = body.tokens, a = t.startIndex
        if t[a].kind == .keyword, t[a].text == "not", t.count > 3, t[a + 1].text == "(", body.closing(a + 1) == t.endIndex - 1,
           let inner = condition(body.sub((a + 2)..<(t.endIndex - 1)), previous: p) {
            return .not(inner)
        }
        for word in ["and", "or"] {
            guard let parts = body.split(t.indices, at: word), parts.count > 1 else { continue }
            var conditions: [FilterCondition] = []
            for part in parts {
                let pt = part.tokens
                guard pt.count > 2, pt[pt.startIndex].text == "(", part.closing(pt.startIndex) == pt.endIndex - 1,
                      let c = condition(part.sub((pt.startIndex + 1)..<(pt.endIndex - 1)), previous: p) else { return nil }
                conditions.append(c)
            }
            return word == "and" ? .and(conditions) : .or(conditions)
        }
        return nil
    }

    /// Single conditions built from the columns, literals and numbers the text mentions.
    private static func leaves(_ s: StepFragment, previous p: String) -> [FilterCondition] {
        let literals = s.literals
        let ints = s.numbers.filter { $0 == $0.rounded() && abs($0) < 1e9 }.map { Int($0) }
        var out: [FilterCondition] = []
        for c in s.columnReferences {
            out += [.isNull(column: c), .isNotNull(column: c), .isBlank(column: c), .isNotBlank(column: c)]
            for (v, type) in literals {
                out += FilterCondition.Comparison.allCases.map { .compare(column: c, $0, v, type: type) }
                if case .string(let text) = v {
                    for m in FilterCondition.TextMatch.allCases {
                        out += [.text(column: c, m, text, ignoreCase: false), .text(column: c, m, text, ignoreCase: true)]
                    }
                }
            }
            if literals.count >= 2 {
                for i in 0..<(literals.count - 1) {
                    out.append(.between(column: c, literals[i].value, literals[i + 1].value, type: literals[i].type))
                }
            }
            if let first = literals.first { out.append(.inList(column: c, literals.map(\.value), type: first.type)) }
            var relative: [FilterCondition.RelativeDate] = [.yearToDate, .isEarliest, .isLatest, .isNotEarliest, .isNotLatest]
            for u in FilterCondition.DateUnit.allCases {
                relative += [.inCurrent(u), .inPrevious(u), .inNext(u)]
                for n in ints { relative += [.inPreviousN(n, u), .inNextN(n, u)] }
            }
            for n in ints { relative += [.year(n), .quarter(n), .month(n), .day(n)] }
            out += relative.map { .date(column: c, $0) }
        }
        return out
    }
}

/// Rebuilds Add Conditional Column clauses from the `if … then … else` chain the transform emits.
enum ConditionalRecognizer {
    /// A column `[Name]` or a literal value.
    static func operand(_ f: StepFragment) -> ConditionalClause.Operand? {
        if let c = f.fieldName { return .column(c) }
        return f.literal.map { .value($0.value) }
    }

    static func column(_ name: String, _ body: StepFragment) -> Transform? {
        let t = body.tokens
        var i = t.startIndex, clauses: [ConditionalClause] = []
        func keyword(_ word: String, from: Int) -> Int? {
            var depth = 0
            for j in from..<t.endIndex {
                let tok = t[j]
                if tok.kind == .punctuation {
                    if "([{".contains(tok.text) { depth += 1 } else if ")]}".contains(tok.text) { depth -= 1 }
                } else if depth == 0, tok.kind == .keyword, tok.text == word { return j }
            }
            return nil
        }
        while i < t.endIndex, t[i].kind == .keyword, t[i].text == "if" {
            guard let then = keyword("then", from: i + 1), let otherwise = keyword("else", from: then + 1), then > i + 1, otherwise > then + 1,
                  let clause = clause(body.sub((i + 1)..<then), body.sub((then + 1)..<otherwise)) else { return nil }
            clauses.append(clause)
            i = otherwise + 1
        }
        guard !clauses.isEmpty, i < t.endIndex, let last = operand(body.sub(i..<t.endIndex)) else { return nil }
        return .addConditionalColumn(name: name, clauses: clauses, otherwise: last)
    }

    private static func clause(_ condition: StepFragment, _ output: StepFragment) -> ConditionalClause? {
        guard let out = operand(output), let column = condition.columnReferences.first else { return nil }
        var values: [ConditionalClause.Operand] = condition.literals.map { .value($0.value) }
        values += condition.columnReferences.dropFirst().map { .column($0) }
        if values.isEmpty { values = [.value(.null)] }
        let wanted = "Table.AddColumn(x, \"n\", each if \(condition.text) then \(output.text) else null)"
        for op in ConditionalClause.Operator.allCases {
            for v in values {
                let c = ConditionalClause(column: column, op: op, value: v, output: out)
                if StepRecognizer.matches(.addConditionalColumn(name: "n", clauses: [c], otherwise: .value(.null)), "x", wanted) { return c }
            }
        }
        return nil
    }
}
