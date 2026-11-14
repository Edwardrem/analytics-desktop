import XCTest
import FacetCore
import FacetAnalytics
import FacetInterop
@testable import MicrosoftPowerBI

/// Q&A setup: Teach Q&A defines a term as a field (a synonym) or a filter that the parser then uses, invalid terms
/// are refused, the questions asked in the file are kept for Review questions with how Q&A reads them now, and
/// both survive saving the file and TMDL.
@MainActor
final class QnASetupTests: XCTestCase {
    private typealias Logic = QnASetupLogic
    private let amount = FieldRef.column("Sales", "Amount")

    override func setUp() async throws {
        Features.registerAll()
    }

    private func parse(_ q: String, _ model: SemanticModel) -> QuestionAnswer {
        Logic.parse(q, model: model, values: ["Sales|Region": [.string("North"), .string("South"), .string("East")]])
    }

    /// The single number an answer's visual shows, computed the way the Q&A visual requests it.
    private func answered(_ spec: VisualSpec) async -> Double? {
        let store = ReportFixture.store()
        await Smoke.settle(store)
        let request = store.request(for: spec, on: store.currentPage)
        return ReportFixture.number(await store.withEngine { $0.visualData(spec: spec, request: request) })
    }

    private func keys(_ spec: VisualSpec) -> [String] { spec.wells.values.flatMap { $0.map(\.key) } }

    // MARK: Teach as a field

    func testATermTaughtAsAColumnBecomesItsSynonymAndIsUnderstood() throws {
        var model = ReportFixture.model()
        XCTAssertEqual(parse("Amount by territory", model).unrecognized, ["territory"])

        try Logic.teachField("territory", field: ReportFixture.region, in: &model)
        XCTAssertEqual(model.table("Sales")?.column("Region")?.synonyms, ["territory"])
        let answer = parse("Amount by territory", model)
        XCTAssertEqual(answer.unrecognized, [])
        XCTAssertTrue(keys(answer.spec).contains(ReportFixture.region.key), "\(answer.spec.wells)")

        try Logic.teachField("Territory", field: ReportFixture.region, in: &model)
        XCTAssertEqual(model.table("Sales")?.column("Region")?.synonyms, ["territory"], "teaching it again adds nothing")
    }

    func testATermTaughtAsAMeasureIsKeptInTheQnASynonyms() throws {
        var model = ReportFixture.model()
        try Logic.teachField("revenue", field: ReportFixture.total, in: &model)
        XCTAssertEqual(model.qnaSynonyms["Sales[Total]"], ["revenue"])
        let answer = parse("revenue by region", model)
        XCTAssertEqual(answer.unrecognized, [])
        XCTAssertTrue(keys(answer.spec).contains(ReportFixture.total.key), "\(answer.spec.wells)")
    }

    // MARK: Teach as a filter

    func testATermTaughtAsAFilterFiltersTheAnswer() async throws {
        var model = ReportFixture.model()
        try Logic.teachFilter("big orders", field: amount, op: .greaterThan, value: "30", in: &model)
        let term = try XCTUnwrap(model.qnaTerms?.first)
        XCTAssertEqual(model.qnaTerms?.count, 1)
        XCTAssertEqual(term.term, "big orders")
        XCTAssertEqual(term.filter.kind, .advanced)
        XCTAssertEqual(term.filter.conditions, [FilterCondition(op: .greaterThan, value: .int(30))])

        let answer = parse("Amount for big orders", model)
        XCTAssertEqual(answer.unrecognized, [])
        XCTAssertTrue(answer.interpretation.contains("big orders (Amount is greater than 30)"), answer.interpretation)
        XCTAssertEqual(answer.spec.filters.map(\.field.key), [amount.key])
        // 40 + 50 are the amounts above 30.
        let shown = await answered(answer.spec)
        XCTAssertEqual(shown, 90)
    }

    func testATextFilterTermAndRedefiningATerm() async throws {
        var model = ReportFixture.model()
        try Logic.teachFilter("northern", field: ReportFixture.region, op: .equals, value: " North ", in: &model)
        XCTAssertEqual(model.qnaTerms?.first?.filter.kind, .basic)
        XCTAssertEqual(model.qnaTerms?.first?.filter.values, [.string("North")])
        let shown = await answered(parse("Amount for northern", model).spec)
        XCTAssertEqual(shown, 30, "10 + 20 in North")

        try Logic.teachFilter("Northern", field: ReportFixture.region, op: .equals, value: "South", in: &model)
        XCTAssertEqual(model.qnaTerms?.count, 1, "the same term is redefined, not added twice")
        XCTAssertEqual(model.qnaTerms?.first?.filter.values, [.string("South")])

        // Teaching a filter term as a field moves it to the field's synonyms.
        try Logic.teachField("northern", field: ReportFixture.region, in: &model)
        XCTAssertNil(model.qnaTerms)
        XCTAssertEqual(model.table("Sales")?.column("Region")?.synonyms, ["northern"])
    }

    func testATermWhoseFieldIsGoneIsIgnoredByTheParser() throws {
        var model = ReportFixture.model()
        try Logic.teachFilter("big orders", field: amount, op: .greaterThan, value: "30", in: &model)
        model.tables[0].columns.removeAll { $0.name == "Amount" }
        XCTAssertTrue(parse("Amount for big orders", model).spec.filters.isEmpty)
    }

    // MARK: Validation

    func testInvalidTermsAndValuesAreRefused() throws {
        var model = ReportFixture.model()
        model.tables[0].columns[1].synonyms = ["item"]
        let before = model
        func refuses(_ expected: Logic.TeachError, _ body: (inout SemanticModel) throws -> Void, line: UInt = #line) {
            var copy = before
            XCTAssertThrowsError(try body(&copy), line: line) { XCTAssertEqual($0 as? Logic.TeachError, expected, line: line) }
            XCTAssertEqual(copy.qnaTerms, before.qnaTerms, line: line)
            XCTAssertEqual(copy.tables[0].columns.map(\.synonyms), before.tables[0].columns.map(\.synonyms), line: line)
        }
        refuses(.emptyTerm) { try Logic.teachField("   ", field: ReportFixture.region, in: &$0) }
        refuses(.termTooLong) { try Logic.teachField(String(repeating: "a", count: 61), field: ReportFixture.region, in: &$0) }
        refuses(.controlCharacters) { try Logic.teachField("big\norders", field: ReportFixture.region, in: &$0) }
        refuses(.controlCharacters) { try Logic.teachFilter("big\torders", field: self.amount, op: .greaterThan, value: "30", in: &$0) }
        refuses(.nameInUse("Sales[Region]")) { try Logic.teachFilter("region", field: self.amount, op: .greaterThan, value: "30", in: &$0) }
        refuses(.nameInUse("Sales[Product]")) { try Logic.teachField("Item", field: ReportFixture.region, in: &$0) }
        refuses(.nameInUse("the Total measure")) { try Logic.teachField("total", field: ReportFixture.region, in: &$0) }
        refuses(.nameInUse("the Sales table")) { try Logic.teachField("sales", field: ReportFixture.region, in: &$0) }
        refuses(.noSuchField("Sales[Country]")) { try Logic.teachField("land", field: .column("Sales", "Country"), in: &$0) }
        refuses(.valueNeeded) { try Logic.teachFilter("big orders", field: self.amount, op: .greaterThan, value: " ", in: &$0) }
        refuses(.notANumber("Amount")) { try Logic.teachFilter("big orders", field: self.amount, op: .greaterThan, value: "lots", in: &$0) }
        refuses(.valueTooLong) {
            try Logic.teachFilter("north", field: ReportFixture.region, op: .equals, value: String(repeating: "n", count: 121), in: &$0)
        }
        XCTAssertEqual(String(repeating: "a", count: 60).count, Logic.maxTermLength, "60 characters is still allowed")
        var model60 = before
        XCTAssertNoThrow(try Logic.teachField(String(repeating: "a", count: 60), field: ReportFixture.region, in: &model60))
    }

    func testAnOperatorWithoutAValueNeedsNone() throws {
        var model = ReportFixture.model()
        try Logic.teachFilter("unlabelled", field: ReportFixture.region, op: .isBlank, value: "", in: &model)
        XCTAssertEqual(model.qnaTerms?.first?.filter.conditions, [FilterCondition(op: .isBlank)])
        XCTAssertEqual(Logic.operators(for: amount, in: model).first, .equals)
        XCTAssertTrue(Logic.operators(for: ReportFixture.region, in: model).contains(.contains))
        XCTAssertFalse(Logic.operators(for: amount, in: model).contains(.contains))
    }

    // MARK: Store, undo and the question log

    func testTeachingThroughTheStoreIsOneUndoStep() throws {
        let store = ReportFixture.store()
        let message = try Logic.teach("big orders", as: .filter, field: amount, op: .greaterThan, value: "30", store: store)
        XCTAssertEqual(message, "“big orders” now means Amount is greater than 30.")
        XCTAssertEqual(store.undoName, "Teach Q&A")
        XCTAssertEqual(store.model.qnaTerms?.count, 1)
        store.undo()
        XCTAssertNil(store.model.qnaTerms)

        XCTAssertThrowsError(try Logic.teach("region", as: .field, field: ReportFixture.product, store: store))
        XCTAssertNotEqual(store.undoName, "Teach Q&A", "a refused term changes nothing")
    }

    func testAskingInAQnAVisualKeepsTheQuestionInTheSameUndoStep() throws {
        let store = ReportFixture.store()
        let qna = VisualSpec(type: .qna, frame: Frame(x: 0, y: 0, width: 400, height: 300))
        let page = store.pageIndex
        store.mutate("Add Q&A", invalidates: .layout) { $0.report.pages[page].visuals.append(qna) }

        Logic.ask("Amount by territory", visual: qna.id, store: store)
        XCTAssertEqual(store.visual(qna.id)?.content, "Amount by territory")
        XCTAssertEqual(store.model.qnaQuestions?.map(\.question), ["Amount by territory"])
        store.undo()
        XCTAssertEqual(store.visual(qna.id)?.content, "")
        XCTAssertNil(store.model.qnaQuestions)
    }

    func testTheQuestionLogMovesRepeatsToTheTopAndIsBounded() {
        var model = SemanticModel()
        let t0 = Date(timeIntervalSince1970: 1_000), t1 = Date(timeIntervalSince1970: 2_000)
        model.recordQuestion("Total by region", at: t0)
        model.recordQuestion("count of products", at: t0)
        model.recordQuestion("  total   BY region ", at: t1)
        XCTAssertEqual(model.qnaQuestions?.map(\.question), ["total BY region", "count of products"])
        XCTAssertEqual(model.qnaQuestions?.first?.timesAsked, 2)
        XCTAssertEqual(model.qnaQuestions?.first?.lastAsked, t1)
        model.recordQuestion("   ", at: t1)
        XCTAssertEqual(model.qnaQuestions?.count, 2, "a blank question is not kept")

        for n in 0..<(SemanticModel.qnaQuestionLimit + 5) { model.recordQuestion("question \(n)", at: t1) }
        XCTAssertEqual(model.qnaQuestions?.count, SemanticModel.qnaQuestionLimit)
        XCTAssertEqual(model.qnaQuestions?.first?.question, "question \(SemanticModel.qnaQuestionLimit + 4)")
        XCTAssertFalse(model.qnaQuestions?.contains { $0.question == "count of products" } ?? true, "the oldest go first")
    }

    func testReviewShowsHowEachQuestionIsReadNowAndTeachingFixesIt() throws {
        var model = ReportFixture.model()
        var verified = VerifiedAnswer(question: "What are our best channels?")
        verified.answer = "Web, then Store."
        model.verifiedAnswers = [verified]
        let t = Date(timeIntervalSince1970: 0)
        for q in ["xyzzy plugh", "Amount by territory", "Amount for North", "What are our best channels?"] { model.recordQuestion(q, at: t) }
        let values: [String: [Value]] = ["Sales|Region": [.string("North")]]

        let before = Logic.review(model, values: values)
        XCTAssertEqual(before.map(\.record.question), ["What are our best channels?", "Amount for North", "Amount by territory", "xyzzy plugh"])
        XCTAssertEqual(before[0].status, .verified)
        guard case .understood = before[1].status else { return XCTFail("\(before[1].status)") }
        XCTAssertEqual(before[2].status, .partly(["territory"]))
        XCTAssertEqual(before[3].status, .notUnderstood(["xyzzy", "plugh"]))
        XCTAssertEqual(before.filter(\.status.needsTeaching).count, 2)

        try Logic.teachField("territory", field: ReportFixture.region, in: &model)
        guard case .understood = Logic.review(model, values: values)[2].status else { return XCTFail("taught, so understood") }

        let id = try XCTUnwrap(model.qnaQuestions?.last?.id)
        Logic.removeQuestion(id, in: &model)
        XCTAssertEqual(model.qnaQuestions?.count, 3)
    }

    // MARK: Persistence

    func testTermsAndQuestionsSurviveSavingTheFile() throws {
        var doc = FacetDocument()
        doc.model = ReportFixture.model()
        try Logic.teachFilter("big orders", field: amount, op: .greaterThan, value: "30", in: &doc.model)
        doc.model.recordQuestion("Amount for big orders", at: Date(timeIntervalSince1970: 86_400))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("qna-\(UUID().uuidString).facet")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentPackage.write(doc, to: url)
        let back = try DocumentPackage.read(from: url)
        XCTAssertEqual(back.model.qnaTerms, doc.model.qnaTerms)
        XCTAssertEqual(back.model.qnaQuestions, doc.model.qnaQuestions)
    }

    func testAModelSavedBeforeQnASetupStillOpens() throws {
        let data = try JSONEncoder().encode(ReportFixture.model())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["qnaTerms"] = nil
        object["qnaQuestions"] = nil
        let old = try JSONSerialization.data(withJSONObject: object)
        let model = try JSONDecoder().decode(SemanticModel.self, from: old)
        XCTAssertNil(model.qnaTerms)
        XCTAssertNil(model.qnaQuestions)
    }

    func testTaughtFilterTermsRoundTripThroughTMDL() throws {
        var model = ReportFixture.model()
        try Logic.teachFilter("big orders", field: amount, op: .greaterThan, value: "30", in: &model)
        try Logic.teachField("territory", field: ReportFixture.region, in: &model)
        let back = try TMDL.parseDetailed(files: TMDL.serialize(model: model)).model
        XCTAssertEqual(back.qnaTerms, model.qnaTerms)
        XCTAssertEqual(back.table("Sales")?.column("Region")?.synonyms, ["territory"])
        XCTAssertNil(try TMDL.parseDetailed(files: TMDL.serialize(model: ReportFixture.model())).model.qnaTerms)
    }

    // MARK: Registration

    func testTheSetupCommandIsRegisteredAndOpensTheDialog() throws {
        let command = try XCTUnwrap(AppCommands.command(AIFeature.qnaSetupID))
        XCTAssertEqual(command.menu, .modeling)
        let store = ReportFixture.store()
        XCTAssertTrue(command.isEnabled(store))
        XCTAssertFalse(command.isEnabled(DocumentStore(services: .live())), "no tables, nothing to teach")
        AppCommands.perform(command, store)
        XCTAssertNotNil(store.sheet)
    }
}
