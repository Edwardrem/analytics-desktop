import Foundation
import FacetCore

/// Finds the verified answer (Prep data for AI) a question asks for, so the assistant and the Q&A visual
/// answer it with the visual the model author approved instead of improvising one.
///
/// Questions are compared by their content words: lowercased, punctuation and common question words
/// ("what", "show me", "the", "by"…) removed, and a trailing plural "s" folded. The score is the Jaccard
/// similarity of the two word sets (shared words ÷ all words), so word order does not matter.
public enum VerifiedAnswerMatcher {
    public struct Match: Sendable, Equatable {
        public var answer: VerifiedAnswer
        /// 0…1; 1 when both questions have the same content words.
        public var score: Double
    }

    /// Words that carry no meaning for matching a question.
    static let stopWords: Set<String> = [
        "a", "an", "the", "of", "for", "by", "in", "on", "to", "at", "per", "with", "and", "or", "from",
        "what", "which", "who", "whom", "how", "many", "much", "is", "are", "was", "were", "be", "been",
        "do", "does", "did", "have", "has", "had", "me", "my", "our", "we", "i", "us", "you", "your",
        "show", "tell", "give", "list", "display", "please", "can", "could", "would", "this", "that", "these", "those", "there",
    ]

    /// The content words of a question.
    public static func terms(_ text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            var word = String(raw)
            guard !stopWords.contains(word) else { continue }
            if word.count > 3, word.hasSuffix("s"), !word.hasSuffix("ss") { word.removeLast() }
            out.insert(word)
        }
        return out
    }

    /// Jaccard similarity of the content words of two questions (0 when either has none).
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = terms(a), y = terms(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// The best verified answer for `question` scoring at least `threshold`; the earlier answer wins a tie.
    public static func match(_ question: String, in answers: [VerifiedAnswer], threshold: Double = 0.6) -> Match? {
        var best: Match?
        for a in answers where !a.question.trimmingCharacters(in: .whitespaces).isEmpty {
            let s = similarity(question, a.question)
            if s >= threshold, s > (best?.score ?? 0) { best = Match(answer: a, score: s) }
        }
        return best
    }
}
