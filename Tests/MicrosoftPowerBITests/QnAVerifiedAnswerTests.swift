import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// The Q&A visual answers a question that matches a verified answer with the author's visual and text,
/// before trying its own interpretation.
@MainActor
final class QnAVerifiedAnswerTests: XCTestCase {
    private func store(answer text: String = "", linked: Bool = true) -> (DocumentStore, VisualSpec) {
        let store = ReportFixture.store()
        let chart = ReportFixture.chart("Amount by region")
        let page = store.pageIndex
        store.mutate("Add Chart", invalidates: .layout) { $0.report.pages[page].visuals.append(chart) }
        store.addPage(named: "Questions")
        store.mutate("Verify", invalidates: .layout) { d in
            var a = VerifiedAnswer(question: "What is the amount by region?")
            a.answer = text
            if linked { a.visualID = chart.id }
            d.model.verifiedAnswers = [a]
        }
        return (store, chart)
    }

    func testAMatchingQuestionGetsTheVerifiedVisualFromItsPage() throws {
        let (store, chart) = store(answer: "South sells the most.")
        let result = try XCTUnwrap(QnAVerifiedResult.find("amount by region", store: store))
        XCTAssertEqual(result.visual?.id, chart.id)
        XCTAssertEqual(result.pageName, "Page 1", "found on its own page while the Q&A visual is elsewhere")
        XCTAssertEqual(result.answer.answer, "South sells the most.")
    }

    func testOtherQuestionsAreLeftToTheParser() {
        let (store, _) = store()
        XCTAssertNil(QnAVerifiedResult.find("count of channels", store: store))
    }

    func testAnAnswerWithNoVisualLeftAndNoTextIsSkipped() {
        let (store, _) = store(linked: false)
        XCTAssertNil(QnAVerifiedResult.find("amount by region", store: store), "nothing to show")
        let (withText, _) = self.store(answer: "Ask the sales team.", linked: false)
        XCTAssertEqual(QnAVerifiedResult.find("amount by region", store: withText)?.answer.answer, "Ask the sales team.")
    }
}
