import XCTest
import FacetCore
import FacetQuery
@testable import MicrosoftPowerBI

/// AI Insights in the Power Query Editor run on this Mac: the app installs the on-device engine, and the
/// editor's Text Analytics and Vision entries add a column through the real query engine.
@MainActor
final class AIInsightsOnDeviceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() async throws {
        Features.registerAll()
        suite = "AIInsightsOnDeviceTests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private static let reviews = """
    let
        Source = #table({"Review"}, {{"I love this wonderful product, it is excellent and works perfectly."}, {"Bonjour, je voudrais réserver une table pour deux personnes ce soir."}})
    in
        Source
    """

    private func session() async -> QueryEditorSession {
        var doc = FacetDocument()
        doc.queries = [QueryDefinition(name: "Reviews", mScript: Self.reviews)]
        let s = QueryEditorSession(store: DocumentStore(document: doc, services: .live()), security: QuerySecurity(defaults: defaults))
        s.refreshPreview()
        await s.waitForPreview()
        return s
    }

    func testTheAppInstallsTheOnDeviceEngine() {
        XCTAssertTrue(AIInsights.provider is OnDeviceAIInsights)
        let engine = OnDeviceAIInsights()
        XCTAssertEqual(engine.language("Bonjour, je voudrais réserver une table pour deux personnes ce soir.")?.code, "fr")
        XCTAssertGreaterThan(engine.sentiment("I love this wonderful product, it is excellent and works perfectly.") ?? 0, 0)
        XCTAssertThrowsError(try engine.imageTags(Data("not an image".utf8)))
    }

    func testTextAnalyticsEntriesAddAColumn() async throws {
        let s = await session()
        let sentiment = try XCTUnwrap(EditorCommands.command("pq.ai.sentiment"))
        XCTAssertEqual(sentiment.blocker(s), "Select exactly one column.")
        s.clickColumn("Review", toggle: false, range: false)
        XCTAssertNil(sentiment.blocker(s))
        sentiment.run(s)
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.columnNames, ["Review", "Sentiment"])
        let score = try XCTUnwrap(s.preview?.table.column("Sentiment")?.values.first?.asDouble)
        XCTAssertGreaterThan(score, 0.5, "a glowing review scores above neutral (0.5)")

        s.clickColumn("Review", toggle: false, range: false)
        try XCTUnwrap(EditorCommands.command("pq.ai.language")).run(s)
        await s.waitForPreview()
        XCTAssertEqual(s.preview?.table.column("Language")?.values.map(\.asString), ["English", "French"])
    }

    func testAzureMachineLearningStillSaysWhy() async {
        let s = await session()
        XCTAssertEqual(EditorCommands.command("pq.ai.ml")?.blocker(s),
                       "Needs Azure Machine Learning with a Microsoft sign-in, which the query engine cannot reach.")
    }
}
