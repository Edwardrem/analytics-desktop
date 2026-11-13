import Foundation
import NaturalLanguage
import Vision

/// On-device text analytics (Apple NaturalLanguage). Backs the "AI Insights" text transforms.
public enum TextAnalytics {
    public struct LanguageResult: Sendable, Equatable {
        /// BCP-47 language code, e.g. "en", "fr".
        public var code: String
        /// English display name, e.g. "French".
        public var name: String
        public var confidence: Double
    }
    public struct Entity: Sendable, Equatable {
        public enum Kind: String, Sendable { case person, place, organization }
        public var text: String
        public var kind: Kind
    }

    /// Sentiment score from −1 (most negative) to +1 (most positive), averaged over paragraphs by length.
    /// Returns nil for empty text or when the on-device sentiment model has no score for the text's language.
    public static func sentiment(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = trimmed
        var weighted = 0.0, weight = 0.0
        tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .paragraph, scheme: .sentimentScore, options: []) { tag, range in
            if let raw = tag?.rawValue, let score = Double(raw) {
                let w = Double(trimmed[range].count)
                weighted += score * w; weight += w
            }
            return true
        }
        return weight > 0 ? max(-1, min(1, weighted / weight)) : nil
    }

    /// "positive", "negative" or "neutral" using ±`threshold` on the sentiment score; nil when no score is available.
    public static func sentimentLabel(_ text: String, threshold: Double = 0.2) -> String? {
        guard let s = sentiment(text) else { return nil }
        return s > threshold ? "positive" : (s < -threshold ? "negative" : "neutral")
    }

    /// Dominant language of the text, or nil when it cannot be determined.
    public static func language(_ text: String) -> LanguageResult? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(trimmed)
        guard let lang = recognizer.dominantLanguage, lang != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0
        let name = Locale(identifier: "en_US").localizedString(forIdentifier: lang.rawValue) ?? lang.rawValue
        return LanguageResult(code: lang.rawValue, name: name, confidence: confidence)
    }

    /// Key phrases: noun phrases (adjectives + nouns) and names, ranked by frequency and length.
    public static func keyPhrases(_ text: String, limit: Int = 10) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = trimmed
        var phrases: [[String]] = []
        var current: [(word: String, isNoun: Bool)] = []
        var lastEnd: String.Index?
        func flush() {
            // Trim trailing adjectives; a phrase must end in a noun.
            while let last = current.last, !last.isNoun { current.removeLast() }
            if !current.isEmpty { phrases.append(current.map(\.word)) }
            current = []
        }
        tagger.enumerateTags(in: trimmed.startIndex..<trimmed.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .joinNames]) { tag, range in
            let word = String(trimmed[range])
            // Punctuation or a line break between words ends the phrase.
            if let end = lastEnd, trimmed[end..<range.lowerBound].contains(where: { !$0.isWhitespace || $0.isNewline }) { flush() }
            lastEnd = range.upperBound
            switch tag {
            case .noun?, .personalName?, .placeName?, .organizationName?: current.append((word, true))
            case .adjective? where current.allSatisfy({ !$0.isNoun }): current.append((word, false))
            case .adjective?: flush(); current.append((word, false))
            default: flush()
            }
            return true
        }
        flush()
        var score: [String: Double] = [:], display: [String: String] = [:], firstSeen: [String: Int] = [:]
        for (i, p) in phrases.enumerated() {
            let shown = p.joined(separator: " ")
            let key = shown.lowercased()
            guard key.count >= 3 else { continue }
            score[key, default: 0] += 1 + 0.5 * Double(p.count - 1)
            if display[key] == nil { display[key] = shown; firstSeen[key] = i }
        }
        let ranked = score.keys.sorted { a, b in
            if score[a] != score[b] { return (score[a] ?? 0) > (score[b] ?? 0) }
            return (firstSeen[a] ?? 0) < (firstSeen[b] ?? 0)
        }
        return ranked.prefix(limit).compactMap { display[$0] }
    }

    /// Named entities (people, places, organisations) in order of appearance, without duplicates.
    public static func entities(_ text: String) -> [Entity] {
        guard !text.isEmpty else { return [] }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var out: [Entity] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let kind: Entity.Kind?
            switch tag {
            case .personalName?: kind = .person
            case .placeName?: kind = .place
            case .organizationName?: kind = .organization
            default: kind = nil
            }
            if let kind {
                let e = Entity(text: String(text[range]), kind: kind)
                if !out.contains(e) { out.append(e) }
            }
            return true
        }
        return out
    }
}

public enum ImageAnalyticsError: LocalizedError {
    case invalidImage
    case visionFailed(String)
    public var errorDescription: String? {
        switch self {
        case .invalidImage: return "The data is not an image that can be analysed (expected PNG, JPEG, HEIC, TIFF or GIF bytes)."
        case .visionFailed(let m): return "Image analysis failed: \(m)"
        }
    }
}

/// On-device image analytics (Apple Vision). Backs the "AI Insights" image transforms.
public enum ImageAnalytics {
    public struct Tag: Sendable, Equatable {
        public var label: String
        /// 0…1.
        public var confidence: Double
    }
    public struct TextLine: Sendable {
        public var text: String
        public var confidence: Double
        /// Normalised bounding box (origin bottom-left, 0…1).
        public var boundingBox: CGRect
    }

    /// Classifies an image and returns its most likely tags, most confident first.
    public static func tags(for data: Data, maxResults: Int = 10, minimumConfidence: Double = 0.1) throws -> [Tag] {
        let handler = try makeHandler(data)
        let request = VNClassifyImageRequest()
        do { try handler.perform([request]) } catch { throw ImageAnalyticsError.visionFailed(error.localizedDescription) }
        let results = request.results ?? []
        return results.filter { Double($0.confidence) >= minimumConfidence }
            .sorted { $0.confidence > $1.confidence }
            .prefix(max(0, maxResults))
            .map { Tag(label: $0.identifier.replacingOccurrences(of: "_", with: " "), confidence: Double($0.confidence)) }
    }

    /// Recognises text in an image (OCR), top line first.
    /// - Parameter languages: preferred recognition languages (BCP-47), e.g. ["en-US"]; empty uses the defaults.
    public static func recognizeTextLines(in data: Data, languages: [String] = [], accurate: Bool = true) throws -> [TextLine] {
        let handler = try makeHandler(data)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        request.usesLanguageCorrection = true
        if !languages.isEmpty { request.recognitionLanguages = languages }
        do { try handler.perform([request]) } catch { throw ImageAnalyticsError.visionFailed(error.localizedDescription) }
        let lines = (request.results ?? []).compactMap { obs -> TextLine? in
            guard let top = obs.topCandidates(1).first else { return nil }
            return TextLine(text: top.string, confidence: Double(top.confidence), boundingBox: obs.boundingBox)
        }
        // Reading order: top to bottom, then left to right.
        return lines.sorted { a, b in
            abs(a.boundingBox.midY - b.boundingBox.midY) > 0.01 ? a.boundingBox.midY > b.boundingBox.midY : a.boundingBox.minX < b.boundingBox.minX
        }
    }

    /// Recognised text of an image as one string, lines separated by newlines.
    public static func recognizeText(in data: Data, languages: [String] = []) throws -> String {
        try recognizeTextLines(in: data, languages: languages).map(\.text).joined(separator: "\n")
    }

    private static func makeHandler(_ data: Data) throws -> VNImageRequestHandler {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageAnalyticsError.invalidImage }
        return VNImageRequestHandler(cgImage: image, options: [:])
    }
}
