import Foundation

// MARK: - Q&A setup
// What the author teaches Q&A, and the questions asked of the file, kept with the model.

/// A word or phrase taught to Q&A (Q&A setup ▸ Teach Q&A) that stands for a filter, such as "big orders" for
/// Sales[Amount] greater than 30. A term taught to stand for a field is that field's synonym instead.
public struct QnATerm: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var term: String
    public var filter: FilterSpec
    public init(term: String, filter: FilterSpec) { self.term = term; self.filter = filter }
}

/// A question asked of this file's Q&A, kept for Q&A setup ▸ Review questions.
public struct QnAQuestionRecord: Codable, Identifiable, Hashable, Sendable {
    public var id = UUID()
    public var question: String
    public var lastAsked: Date
    public var timesAsked = 1
    public init(question: String, lastAsked: Date) { self.question = question; self.lastAsked = lastAsked }
}

public extension SemanticModel {
    /// Most questions Review questions keeps; the least recently asked go first.
    static let qnaQuestionLimit = 200

    /// Notes that `question` was asked: a repeat (ignoring case and spacing) moves to the top with its count raised.
    mutating func recordQuestion(_ question: String, at date: Date) {
        let text = question.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return }
        var log = qnaQuestions ?? []
        if let i = log.firstIndex(where: { $0.question.caseInsensitiveCompare(text) == .orderedSame }) {
            var record = log.remove(at: i)
            record.question = text
            record.lastAsked = date
            record.timesAsked += 1
            log.insert(record, at: 0)
        } else {
            log.insert(QnAQuestionRecord(question: text, lastAsked: date), at: 0)
        }
        if log.count > Self.qnaQuestionLimit { log.removeLast(log.count - Self.qnaQuestionLimit) }
        qnaQuestions = log
    }
}
