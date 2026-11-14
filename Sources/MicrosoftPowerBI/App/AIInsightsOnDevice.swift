import Foundation
import FacetQuery
import FacetAnalytics

/// AI Insights on this Mac: the query engine's `AI.Sentiment`, `AI.KeyPhrases`, `AI.DetectLanguage` and
/// `AI.TagImage` run on Apple's NaturalLanguage and Vision models through `TextAnalytics` and `ImageAnalytics`.
/// Nothing leaves the machine. Installed by `AIFeature.register()`.
struct OnDeviceAIInsights: AIInsightsProvider {
    func sentiment(_ text: String) -> Double? { TextAnalytics.sentiment(text) }

    func keyPhrases(_ text: String) -> [String] { TextAnalytics.keyPhrases(text) }

    func language(_ text: String) -> AIInsights.Language? {
        TextAnalytics.language(text).map { AIInsights.Language(code: $0.code, name: $0.name, confidence: $0.confidence) }
    }

    func imageTags(_ data: Data) throws -> [AIInsights.Tag] {
        try ImageAnalytics.tags(for: data).map { AIInsights.Tag(name: $0.label, confidence: $0.confidence) }
    }
}
