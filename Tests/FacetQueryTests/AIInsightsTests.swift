import XCTest
import FacetCore
@testable import FacetQuery

/// The AI Insights functions with an analysis engine installed: scores, phrases, languages and image tags come
/// from the engine, shaped as the editor's generated M expects; nulls pass through; Azure-only functions say why.
final class AIInsightsTests: XCTestCase {
    /// A predictable engine: "good" scores +0.5 and "bad" −1, words longer than four letters are key phrases,
    /// "Bonjour…" is French, and only bytes starting 0x89 are an image (a cat).
    private struct StubEngine: AIInsightsProvider {
        struct NotAnImage: LocalizedError { var errorDescription: String? { "not an image" } }
        func sentiment(_ text: String) -> Double? { text.contains("good") ? 0.5 : (text.contains("bad") ? -1 : nil) }
        func keyPhrases(_ text: String) -> [String] { text.split(separator: " ").filter { $0.count > 4 }.map(String.init) }
        func language(_ text: String) -> AIInsights.Language? {
            text.hasPrefix("Bonjour") ? AIInsights.Language(code: "fr", name: "French", confidence: 0.9) : nil
        }
        func imageTags(_ data: Data) throws -> [AIInsights.Tag] {
            guard data.first == 0x89 else { throw NotAnImage() }
            return [AIInsights.Tag(name: "cat", confidence: 0.8), AIInsights.Tag(name: "animal", confidence: 0.6)]
        }
    }

    private var installed: (any AIInsightsProvider)?

    override func setUp() {
        installed = AIInsights.provider
        AIInsights.provider = StubEngine()
    }

    override func tearDown() {
        AIInsights.provider = installed
    }

    func testSentimentIsScaledToZeroToOne() throws {
        XCTAssertEqual(try mNum("AI.Sentiment(\"a good day\")"), 0.75, "(0.5 + 1) / 2")
        XCTAssertEqual(try mNum("AI.Sentiment(\"bad\")"), 0)
        XCTAssertTrue(try m("AI.Sentiment(\"so-so\")").isNull, "no score is null, not an error")
        XCTAssertTrue(try m("AI.Sentiment(null)").isNull)
    }

    func testSentimentColumnAsTheEditorWritesIt() throws {
        let v = try m("""
        let t = #table({"Review"}, {{"good service"}, {"bad food"}, {null}}),
            s = Table.AddColumn(t, "Sentiment", each AI.Sentiment([Review]), type number)
        in s[Sentiment]
        """)
        guard case .list(let values) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(values.map { $0.isNull ? "null" : ((try? MConvert.text($0)) ?? "?") }, ["0.75", "0", "null"])
    }

    func testKeyPhrasesAndLanguage() throws {
        XCTAssertEqual(try mText("Text.Combine(AI.KeyPhrases(\"quarterly revenue grew strongly\"), \", \")"), "quarterly, revenue, strongly")
        XCTAssertEqual(try mText("AI.DetectLanguage(\"Bonjour tout le monde\")[Language]"), "French")
        XCTAssertEqual(try mText("AI.DetectLanguage(\"Bonjour tout le monde\")[ISO Code]"), "fr")
        XCTAssertTrue(try m("AI.DetectLanguage(\"zzz\")[Language]").isNull, "undetermined is null")
    }

    func testImageTagsFromBinaryOrBase64() throws {
        // "iVA=" is the base64 of the bytes 0x89 0x50.
        XCTAssertEqual(try mText("Text.Combine(AI.TagImage(\"iVA=\")[Tag], \", \")"), "cat, animal")
        XCTAssertEqual(try mText("Text.Combine(AI.TagImage(Binary.FromText(\"iVA=\", BinaryEncoding.Base64))[Tag], \", \")"), "cat, animal")
        XCTAssertEqual(mErr("AI.TagImage(\"AAAA\")"), "not an image")
        XCTAssertNotNil(mErr("AI.TagImage(42)"))
    }

    func testAzureOnlyFunctionsSayWhy() {
        let text = mErr("AzureML.Contents(\"https://example.azureml.net\")") ?? ""
        XCTAssertTrue(text.contains("needs Azure"), text)
        XCTAssertTrue(text.contains("run on this Mac"), "points to the functions that do work")
    }
}
