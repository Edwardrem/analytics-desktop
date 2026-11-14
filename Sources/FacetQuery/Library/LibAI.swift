import Foundation
import FacetCore

/// The analysis behind the AI Insights functions (`AI.Sentiment`, `AI.KeyPhrases`, `AI.DetectLanguage`,
/// `AI.TagImage`). The query engine cannot depend on the analytics module, so the app installs an on-device
/// implementation (Apple NaturalLanguage and Vision) at launch through `AIInsights.provider`.
public protocol AIInsightsProvider: Sendable {
    /// −1 (most negative) … +1 (most positive); nil when the text has no score (empty, or a language without a model).
    func sentiment(_ text: String) -> Double?
    /// Key phrases, most important first.
    func keyPhrases(_ text: String) -> [String]
    /// The dominant language: BCP-47 code, English name and confidence 0…1; nil when undetermined.
    func language(_ text: String) -> AIInsights.Language?
    /// Tags for image bytes, most confident first.
    func imageTags(_ data: Data) throws -> [AIInsights.Tag]
}

public enum AIInsights {
    public struct Language: Sendable, Equatable {
        public var code: String, name: String, confidence: Double
        public init(code: String, name: String, confidence: Double) { self.code = code; self.name = name; self.confidence = confidence }
    }
    public struct Tag: Sendable, Equatable {
        public var name: String, confidence: Double
        public init(name: String, confidence: Double) { self.name = name; self.confidence = confidence }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _provider: (any AIInsightsProvider)?

    /// The engine the AI Insights functions use; nil until the app installs one.
    public static var provider: (any AIInsightsProvider)? {
        get { lock.lock(); defer { lock.unlock() }; return _provider }
        set { lock.lock(); _provider = newValue; lock.unlock() }
    }

    static func required(_ function: String) throws -> any AIInsightsProvider {
        guard let p = provider else {
            throw MError.dataSource("\(function) runs on the Mac's on-device language and image models, which this query engine was started without.")
        }
        return p
    }
}

extension MLibrary {
    /// AI Insights: on-device text analytics and image tagging. Each function takes the value and returns null
    /// for null, so a column with gaps still evaluates. Azure Machine Learning and the AI Insights catalog
    /// need Azure and say so.
    static func registerAI(_ lib: MLibrary) {
        lib.fn("AI.Sentiment", 1...2) { a, _ in
            guard a.has(0) else { return .null }
            let p = try AIInsights.required("AI.Sentiment")
            // 0 (negative) … 1 (positive), as Power BI's sentiment score.
            return .optNumber(p.sentiment(try a.text(0)).map { (($0 + 1) / 2 * 1000).rounded() / 1000 })
        }
        lib.fn("AI.KeyPhrases", 1...2) { a, _ in
            guard a.has(0) else { return .null }
            let p = try AIInsights.required("AI.KeyPhrases")
            return .list(p.keyPhrases(try a.text(0)).map(MValue.text))
        }
        lib.fn("AI.DetectLanguage", 1...2) { a, _ in
            guard a.has(0) else { return .null }
            let p = try AIInsights.required("AI.DetectLanguage")
            guard let l = p.language(try a.text(0)) else {
                return .record(MRecord([("Language", .null), ("ISO Code", .null), ("Confidence", .null)]))
            }
            return .record(MRecord([("Language", .text(l.name)), ("ISO Code", .text(l.code)), ("Confidence", .number(l.confidence))]))
        }
        lib.fn("AI.TagImage", 1...2) { a, _ in
            guard a.has(0) else { return .null }
            let p = try AIInsights.required("AI.TagImage")
            let data: Data
            switch a[0] {
            case .binary(let d): data = d
            // Images often arrive as base64 text from a web or database source.
            case .text(let s):
                guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else {
                    throw MError.dataFormat("AI.TagImage needs image bytes (binary, or base64 text).")
                }
                data = d
            default: throw MError.dataFormat("AI.TagImage needs image bytes (binary, or base64 text).")
            }
            let tags: [AIInsights.Tag]
            do { tags = try p.imageTags(data) } catch { throw MError.dataFormat((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) }
            return .table(MTable(names: ["Tag", "Confidence"], types: [.text, .number(.double)],
                                 rows: tags.map { [.text($0.name), .number($0.confidence)] }))
        }
        for name in ["AIInsights.Contents", "AzureML.Contents"] {
            lib.fn(name, 0...3) { _, _ in
                throw MError.dataSource("\(name) needs Azure (Cognitive Services or Azure Machine Learning), which this version of \(AppIdentity.name) can't connect to. The text and image functions (AI.Sentiment, AI.KeyPhrases, AI.DetectLanguage, AI.TagImage) run on this Mac.")
            }
        }
    }
}
