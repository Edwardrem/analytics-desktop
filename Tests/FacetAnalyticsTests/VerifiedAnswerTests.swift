import XCTest
import FacetCore
@testable import FacetAnalytics

/// Matching a question to the verified answers an author saved: content words only, order and plurals ignored,
/// and nothing below the threshold.
final class VerifiedAnswerTests: XCTestCase {
    private func answer(_ q: String) -> VerifiedAnswer { VerifiedAnswer(question: q) }

    func testContentWordsDropQuestionWordsAndFoldPlurals() {
        XCTAssertEqual(VerifiedAnswerMatcher.terms("What are the total sales by region?"), ["total", "sale", "region"])
        XCTAssertEqual(VerifiedAnswerMatcher.terms("Show me gross margin %"), ["gross", "margin"])
        // "class" keeps its double s; three-letter words keep their s.
        XCTAssertEqual(VerifiedAnswerMatcher.terms("class bus"), ["class", "bus"])
    }

    func testSimilarityIsSharedOverAllWords() {
        // {total, sale, region} and {sale, region}: 2 shared of 3.
        XCTAssertEqual(VerifiedAnswerMatcher.similarity("total sales by region", "sales per region"), 2.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(VerifiedAnswerMatcher.similarity("Region sales", "sales by region"), 1)
        XCTAssertEqual(VerifiedAnswerMatcher.similarity("what is", "sales"), 0, "a question of only stop words matches nothing")
    }

    func testTheBestAnswerAboveTheThresholdWins() throws {
        let answers = [answer("Sales by channel"), answer("What are total sales by region?"), answer("Sales by region")]
        let m = try XCTUnwrap(VerifiedAnswerMatcher.match("show me sales by region", in: answers))
        // {sale, region} against {sale, channel} 1/3, {total, sale, region} 2/3, {sale, region} 1.
        XCTAssertEqual(m.answer.question, "Sales by region")
        XCTAssertEqual(m.score, 1)
        XCTAssertNil(VerifiedAnswerMatcher.match("profit by month", in: answers))
        XCTAssertNil(VerifiedAnswerMatcher.match("sales", in: [answer("total sales by region")]), "1 of 3 words is below 0.6")
    }

    func testTheEarlierAnswerWinsATieAndBlankQuestionsAreSkipped() throws {
        let answers = [answer("   "), answer("region sales"), answer("sales region")]
        let m = try XCTUnwrap(VerifiedAnswerMatcher.match("sales by region", in: answers))
        XCTAssertEqual(m.answer.id, answers[1].id)
    }

    func testTheModelDescriptionListsVerifiedAnswersWithTheirVisuals() {
        var model = SemanticModel()
        model.tables = [ModelTable(name: "Sales", columns: [ModelColumn(name: "Region", dataType: .text)])]
        var a = VerifiedAnswer(question: "Sales by region")
        a.answer = "South leads."
        let visual = UUID()
        a.visualID = visual
        model.verifiedAnswers = [a, VerifiedAnswer(question: "")]
        let text = ModelDescriber.schemaSummary(model: model, answerVisuals: [visual: "\"Regions\" on page \"Overview\""])
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(Array(lines.suffix(2)), ["Verified answers:",
                                                "  Q: Sales by region → A: South leads. (answered by the visual \"Regions\" on page \"Overview\")"])
    }
}
