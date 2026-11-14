import XCTest
import FacetCore
@testable import FacetQuery

/// Comments through step editing. Power Query keeps an applied step's description as the comment lines above the
/// step; edits keep those with their step, along with comments at the end of a step's line, inside an expression,
/// above `let` and after the last step.
final class StepCommentsTests: TransformTestCase {
    let commented = """
    // Shop numbers
    let
        Source = #table({"a"}, {{1}, {2}, {3}}),
        // Doubles a
        Added = Table.AddColumn(Source, "b", each [a] * 2), // b is a × 2
        /* Only rows
           after the first */
        Kept = Table.SelectRows(Added, each [a] > 1 /* not the first */)
        // end
    in
        Kept
    """
    private func run(_ script: String) throws -> [[String]] { try tableRows(try eval(script)) }

    func testCommentsBelongToTheirSteps() throws {
        let steps = MScript.steps(of: commented)
        XCTAssertEqual(steps.map(\.name), ["Source", "Added", "Kept"])
        XCTAssertEqual(steps.map(\.comments), [[], ["// Doubles a"], ["/* Only rows\n       after the first */"]])
        XCTAssertEqual(steps.map(\.trailingComment), [nil, "// b is a × 2", nil])
        XCTAssertEqual(steps[2].expression, "Table.SelectRows(Added, each [a] > 1 /* not the first */)")
        XCTAssertEqual(steps.map(\.description), ["", "Doubles a", "Only rows\nafter the first"])
        let parsed = MScript.parsed(commented)
        XCTAssertEqual(parsed.header, ["// Shop numbers"])
        XCTAssertEqual(parsed.footer, ["// end"])
    }

    func testRenamingKeepsEveryComment() throws {
        let renamed = MScript.renamingStep("Added", to: "Doubled", in: commented)
        XCTAssertEqual(renamed, """
        // Shop numbers
        let
            Source = #table({"a"}, {{1}, {2}, {3}}),
            // Doubles a
            Doubled = Table.AddColumn(Source, "b", each [a] * 2), // b is a × 2
            /* Only rows
               after the first */
            Kept = Table.SelectRows(Doubled, each [a] > 1 /* not the first */)
            // end
        in
            Kept
        """)
        XCTAssertEqual(try run(renamed), [["2", "4"], ["3", "6"]])
    }

    func testOtherEditsKeepTheComments() throws {
        // Deleting a step takes its own comments; the others stay.
        let deleted = MScript.deletingStep("Added", in: commented)
        XCTAssertEqual(MScript.steps(of: deleted).map(\.comments), [[], ["/* Only rows\n       after the first */"]])
        XCTAssertTrue(deleted.hasPrefix("// Shop numbers\nlet\n"), deleted)
        XCTAssertTrue(deleted.contains("    // end\nin\n"), deleted)
        XCTAssertFalse(deleted.contains("Doubles a"))
        XCTAssertEqual(try run(deleted), [["2"], ["3"]])

        // Moving, inserting, appending and editing an expression leave descriptions where they were.
        let moved = MScript.movingStep("Kept", to: 1, in: commented)
        XCTAssertEqual(MScript.steps(of: moved).map(\.name), ["Source", "Kept", "Added"])
        XCTAssertEqual(MScript.steps(of: moved).map(\.description), ["", "Only rows\nafter the first", "Doubles a"])
        XCTAssertEqual(try run(moved), [["2", "4"], ["3", "6"]])

        let inserted = MScript.insertingStep(MStep(name: "Top", expression: "Table.FirstN(Source, 2)"), after: "Source", in: commented)
        XCTAssertEqual(MScript.steps(of: inserted).map(\.description), ["", "", "Doubles a", "Only rows\nafter the first"])
        XCTAssertEqual(try run(inserted), [["2", "4"]])

        let appended = MScript.appending(.reverseRows, to: commented)
        XCTAssertEqual(MScript.steps(of: appended).map(\.description), ["", "Doubles a", "Only rows\nafter the first", ""])
        XCTAssertEqual(MScript.parsed(appended).header, ["// Shop numbers"])
        XCTAssertEqual(MScript.parsed(appended).footer, ["// end"])

        let edited = MScript.replacingStepExpression("Kept", with: "Table.SelectRows(Added, each [a] > 2)", in: commented)
        XCTAssertEqual(MScript.steps(of: edited)[2].description, "Only rows\nafter the first")
        XCTAssertEqual(MScript.steps(of: edited)[1].trailingComment, "// b is a × 2")
        XCTAssertEqual(try run(edited), [["3", "6"]])

        // Delete Until End keeps the header, footer and the remaining steps' comments.
        let truncated = MScript.truncating(commented, upToStep: 1)
        XCTAssertEqual(MScript.steps(of: truncated).map(\.description), ["", "Doubles a"])
        XCTAssertTrue(truncated.hasPrefix("// Shop numbers\n"), truncated)
    }

    func testADescriptionIsWrittenAsCommentLines() throws {
        let described = MScript.settingStepDescription("Source", to: "Three rows\n\nof a", in: commented)
        XCTAssertTrue(described.contains("let\n    // Three rows\n    //\n    // of a\n    Source = #table("), described)
        XCTAssertEqual(MScript.steps(of: described)[0].description, "Three rows\n\nof a")
        XCTAssertEqual(try run(described), try run(commented))

        let cleared = MScript.settingStepDescription("Added", to: "  ", in: commented)
        XCTAssertEqual(MScript.steps(of: cleared)[1].comments, [])
        XCTAssertFalse(cleared.contains("Doubles a"))
        XCTAssertEqual(MScript.steps(of: cleared)[1].trailingComment, "// b is a × 2", "only the description goes")

        XCTAssertEqual(MScript.settingStepDescription("Nope", to: "x", in: commented), commented, "an unknown step changes nothing")
        XCTAssertEqual(MScript.settingStepDescription("Added", to: "Doubles a", in: commented), commented, "nor does the same description")

        var step = MStep(name: "S", expression: "1")
        step.description = "one\r\ntwo"
        XCTAssertEqual(step.comments, ["// one", "// two"])
    }

    func testALineCommentAtTheEndOfAnExpressionDoesntSwallowTheComma() throws {
        let script = MScript.replacingStepExpression("Source", with: #"#table({"a"}, {{1}, {2}}) // two rows"#, in: commented)
        XCTAssertTrue(MScript.validate(script).isEmpty, script)
        XCTAssertEqual(try run(script), [["2", "4"]])
        XCTAssertEqual(MScript.steps(of: script).map(\.name), ["Source", "Added", "Kept"])
    }

    func testCommentsAfterInFollowTheResult() throws {
        // The result is a step name: a comment after `in` is kept with the footer.
        let afterIn = "let\n    A = 1,\n    B = A + 1\nin\n    // the answer\n    B"
        XCTAssertEqual(MScript.parsed(afterIn).footer, ["// the answer"])
        XCTAssertEqual(MScript.renamingStep("A", to: "One", in: afterIn), "let\n    One = 1,\n    B = One + 1\n    // the answer\nin\n    B")
        // The result is an expression: it becomes the final step, comment included, and isn't written twice.
        let expression = "let\n    A = 1\nin\n    // plus one\n    A + 1"
        let steps = MScript.steps(of: expression)
        XCTAssertEqual(steps.last?.expression, "// plus one\n    A + 1")
        XCTAssertEqual(MScript.parsed(expression).footer, [])
        let renamed = MScript.renamingStep("A", to: "One", in: expression)
        XCTAssertEqual(renamed.components(separatedBy: "plus one").count, 2, renamed)
        guard case .number(let n) = try eval(renamed) else { return XCTFail("not a number") }
        XCTAssertEqual(n, 2)
    }

    func testScriptsWithoutCommentsAreUnchanged() throws {
        let plain = "let\n    Source = 1,\n    #\"Next Step\" = Source + 1\nin\n    #\"Next Step\""
        XCTAssertEqual(MScript.steps(of: plain).map(\.comments), [[], []])
        XCTAssertEqual(MScript.script(from: MScript.steps(of: plain)), plain)
        XCTAssertEqual(MScript.renamingStep("Source", to: "S", in: plain), "let\n    S = 1,\n    #\"Next Step\" = S + 1\nin\n    #\"Next Step\"")
    }
}
