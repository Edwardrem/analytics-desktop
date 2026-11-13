import XCTest
import FacetCore
@testable import FacetQuery

/// Applied Steps editing: every edit rewrites the M script, and the rewritten script must evaluate to what
/// the edit means. Also checks that no `Transform` case is left without a step name and valid M.
final class StepEditingTests: TransformTestCase {
    let base = """
    let
        Source = #table({"a", "b"}, {{1, "x"}, {2, "y"}, {3, "z"}}),
        #"Filtered Rows" = Table.SelectRows(Source, each [a] > 1),
        #"Added Custom" = Table.AddColumn(#"Filtered Rows", "c", each [a] * 2)
    in
        #"Added Custom"
    """
    private func run(_ script: String) throws -> [[String]] { try tableRows(try eval(script)) }

    func testStepsAndCanonicalScript() throws {
        let steps = MScript.steps(of: base)
        XCTAssertEqual(steps.map(\.name), ["Source", "Filtered Rows", "Added Custom"])
        XCTAssertEqual(steps[1].expression, "Table.SelectRows(Source, each [a] > 1)")
        XCTAssertEqual(MScript.resultName(of: base), "Added Custom")
        XCTAssertEqual(MScript.script(from: [MStep(name: "Source", expression: "1"), MStep(name: "Next Step", expression: "Source + 1")]),
                       "let\n    Source = 1,\n    #\"Next Step\" = Source + 1\nin\n    #\"Next Step\"")
        XCTAssertEqual(MScript.script(from: steps), base.replacingOccurrences(of: "\n    ", with: "\n    ")) // already canonical
        XCTAssertEqual(MScript.steps(of: "#table({\"a\"}, {{1}})").map(\.name), ["Source"]) // not a let: one step
        // an `in` expression that is not a step becomes a final step so that nothing is lost
        let computed = MScript.steps(of: "let a = 1, b = 2 in a + b")
        XCTAssertEqual(computed.map(\.name), ["a", "b", "Result"])
        XCTAssertEqual(computed.last?.expression, "a + b")
        XCTAssertEqual(try eval(MScript.script(from: computed)).numberValue, 3)
        XCTAssertEqual(try run(base), [["2", "y", "4"], ["3", "z", "6"]])
    }
    func testAppendGivesUniqueNamesAndChainsToTheLastStep() throws {
        var s = MScript.appending(.filterRows(.compare(column: "a", .lessThan, .int(3))), to: base)
        XCTAssertEqual(MScript.steps(of: s).map(\.name), ["Source", "Filtered Rows", "Added Custom", "Filtered Rows1"])
        XCTAssertEqual(MScript.steps(of: s).last?.expression, "Table.SelectRows(#\"Added Custom\", each [a] < 3)")
        XCTAssertEqual(try run(s), [["2", "y", "4"]])
        s = MScript.appending(.filterRows(.isNotNull(column: "a")), to: s)
        XCTAssertEqual(MScript.steps(of: s).last?.name, "Filtered Rows2")
        XCTAssertEqual(MScript.uniqueStepName("Sorted Rows", in: s), "Sorted Rows")
        XCTAssertEqual(MScript.uniqueStepName("Filtered Rows", in: s), "Filtered Rows3")
        s = MScript.appendingStep(named: "Custom1", expression: { "Table.RowCount(\($0))" }, to: s)
        XCTAssertEqual(try eval(s).numberValue, 1)
    }
    func testRenameStepUpdatesLaterReferences() throws {
        let s = MScript.renamingStep("Filtered Rows", to: "Big Rows", in: base)
        XCTAssertEqual(MScript.steps(of: s).map(\.name), ["Source", "Big Rows", "Added Custom"])
        XCTAssertEqual(MScript.steps(of: s)[2].expression, "Table.AddColumn(#\"Big Rows\", \"c\", each [a] * 2)")
        XCTAssertEqual(try run(s), try run(base))
        // renaming the last step renames the result
        let last = MScript.renamingStep("Added Custom", to: "Final", in: base)
        XCTAssertEqual(MScript.resultName(of: last), "Final")
        XCTAssertEqual(try run(last), try run(base))
        // a name that is already used, or an unknown step, changes nothing
        XCTAssertEqual(MScript.renamingStep("Filtered Rows", to: "Source", in: base), base)
        XCTAssertEqual(MScript.renamingStep("Nope", to: "X", in: base), base)
        // text, field names and record fields that happen to match the step name are left alone
        let tricky = "let a = 1, r = [a = a + 1, b = \"a\"], t = #table({\"a\"}, {{a}}), u = Table.AddColumn(t, \"n\", each [a] + r[a]) in u"
        let renamed = MScript.renamingStep("a", to: "start", in: tricky)
        XCTAssertEqual(MScript.steps(of: renamed).map(\.expression),
                       ["1", "[a = start + 1, b = \"a\"]", "#table({\"a\"}, {{start}})", "Table.AddColumn(t, \"n\", each [a] + r[a])"])
        XCTAssertEqual(try run(renamed), [["1", "3"]])
    }
    func testDeleteStepRepointsToThePredecessor() throws {
        var s = MScript.deletingStep("Filtered Rows", in: base)
        XCTAssertEqual(MScript.steps(of: s).map(\.name), ["Source", "Added Custom"])
        XCTAssertEqual(MScript.steps(of: s)[1].expression, "Table.AddColumn(Source, \"c\", each [a] * 2)")
        XCTAssertEqual(try run(s), [["1", "x", "2"], ["2", "y", "4"], ["3", "z", "6"]])
        s = MScript.deletingStep("Added Custom", in: base) // deleting the last step returns the one before
        XCTAssertEqual(MScript.resultName(of: s), "Filtered Rows")
        XCTAssertEqual(try run(s), [["2", "y"], ["3", "z"]])
        XCTAssertEqual(MScript.deletingStep("Nope", in: base), base)
        let single = "let\n    Source = 1\nin\n    Source"
        XCTAssertEqual(MScript.deletingStep("Source", in: single), single) // the only step can't be deleted
    }
    func testMoveStepKeepsTheChainLinear() throws {
        // move "Added Custom" before the filter: it now reads Source and the filter reads it
        let s = MScript.movingStep("Added Custom", to: 1, in: base)
        XCTAssertEqual(MScript.steps(of: s).map(\.name), ["Source", "Added Custom", "Filtered Rows"])
        XCTAssertEqual(MScript.steps(of: s).map(\.expression)[1...].map { $0 }, ["Table.AddColumn(Source, \"c\", each [a] * 2)", "Table.SelectRows(#\"Added Custom\", each [a] > 1)"])
        XCTAssertEqual(MScript.resultName(of: s), "Filtered Rows")
        XCTAssertEqual(try run(s), [["2", "y", "4"], ["3", "z", "6"]])
        XCTAssertEqual(MScript.movingStep("Added Custom", to: 2, in: base), base) // already there
        XCTAssertEqual(MScript.movingStep("Nope", to: 0, in: base), base)
        // moving back restores the original chain
        XCTAssertEqual(MScript.steps(of: MScript.movingStep("Added Custom", to: 2, in: s)).map(\.expression), MScript.steps(of: base).map(\.expression))
    }
    func testInsertStep() throws {
        var s = MScript.insertingStep(MStep(name: "Kept First Rows", expression: "Table.FirstN(Source, 2)"), after: "Source", in: base)
        XCTAssertEqual(MScript.steps(of: s).map(\.name), ["Source", "Kept First Rows", "Filtered Rows", "Added Custom"])
        XCTAssertEqual(MScript.steps(of: s)[2].expression, "Table.SelectRows(#\"Kept First Rows\", each [a] > 1)")
        XCTAssertEqual(try run(s), [["2", "y", "4"]]) // first two rows, then a > 1
        // inserting after the last step makes it the result; a clashing name gets a number
        s = MScript.insertingStep(MStep(name: "Filtered Rows", expression: "Table.SelectRows(#\"Added Custom\", each [c] = 6)"), after: "Added Custom", in: base)
        XCTAssertEqual(MScript.steps(of: s).last?.name, "Filtered Rows1")
        XCTAssertEqual(MScript.resultName(of: s), "Filtered Rows1")
        XCTAssertEqual(try run(s), [["3", "z", "6"]])
    }
    func testEditStepSettings() throws {
        // editing a step's settings regenerates its M from the transform, against the same previous step
        let edited = Transform.filterRows(.or([.compare(column: "a", .equals, .int(1)), .text(column: "b", .contains, "z")]))
        var s = MScript.replacingStepExpression("Filtered Rows", with: edited.expression(previous: "Source"), in: base)
        XCTAssertEqual(MScript.steps(of: s)[1].expression, "Table.SelectRows(Source, each ([a] = 1) or (Text.Contains([b], \"z\")))")
        XCTAssertEqual(try run(s), [["1", "x", "2"], ["3", "z", "6"]])
        s = MScript.replacingStepExpression("Added Custom", with: "  Table.AddColumn(#\"Filtered Rows\", \"c\", each [a] * 10)\n", in: base)
        XCTAssertEqual(try run(s), [["2", "y", "20"], ["3", "z", "30"]])
        XCTAssertEqual(MScript.replacingStepExpression("Nope", with: "1", in: base), base)
    }
    func testPreviewOfIntermediateSteps() async throws {
        XCTAssertEqual(try run(MScript.truncating(base, upToStep: 0)), [["1", "x"], ["2", "y"], ["3", "z"]])
        XCTAssertEqual(try run(MScript.truncating(base, upToStep: 1)), [["2", "y"], ["3", "z"]])
        XCTAssertEqual(MScript.truncating(base, upToStep: 2), base)
        let e = engine([("Q", base)])
        let first = try await e.evaluate("Q", upToStep: 0)
        XCTAssertEqual(first.rowCount, 3)
        let second = try await e.evaluate("Q", upToStep: 1)
        XCTAssertEqual(second.columnNames, ["a", "b"])
        XCTAssertEqual(second.column("a")?.values, [.int(2), .int(3)])
        // a later step that is broken does not stop earlier steps from previewing
        let broken = MScript.appendingStep(named: "Broken", expression: { "Table.RemoveColumns(\($0), {\"missing\"})" }, to: base)
        let ok = try await engine([("Q", broken)]).evaluate("Q", upToStep: 2)
        XCTAssertEqual(ok.rowCount, 2)
        do { _ = try await engine([("Q", broken)]).evaluate("Q"); XCTFail("expected an error") } catch {
            XCTAssertTrue(MError.wrap(error).message.contains("missing"))
        }
    }
    func testValidationFormattingAndReferences() throws {
        XCTAssertEqual(MScript.validate(base).filter { $0.severity == .error }, [])
        XCTAssertFalse(MScript.validate("let a = in a").isEmpty)
        XCTAssertFalse(MScript.validate("let a = 1, a = 2 in a").isEmpty) // duplicate step name
        XCTAssertFalse(MScript.validate("let a = Unknown + 1 in a").isEmpty)
        XCTAssertTrue(MScript.validate("let a = Other + 1 in a", knownNames: ["Other"]).isEmpty)
        let formatted = MScript.format("let a=1,b=a+1 in b")
        XCTAssertEqual(MScript.format(formatted), formatted)
        XCTAssertEqual(try eval(formatted).numberValue, 2)
        XCTAssertEqual(MScript.referencedIdentifiers(in: "let s = Sales, f = Table.SelectRows(s, each [Amount] > Threshold) in f"), ["Sales", "Threshold"])
    }
    func testQueryLevelEdits() async throws {
        var q = QueryDefinition(name: "Sales", mScript: base)
        q.group = "Staging"
        let copy = MScript.duplicateQuery(q, newName: "Sales (2)")
        XCTAssertEqual(copy.mScript, base); XCTAssertNotEqual(copy.id, q.id); XCTAssertEqual(copy.group, "Staging")
        let ref = MScript.referenceQuery(q, newName: "Sales Ref")
        XCTAssertEqual(ref.mScript, "let\n    Source = Sales\nin\n    Source")
        let e = QueryEngine(queries: [q, copy, ref], environment: env)
        let viaRef = try await e.evaluate("Sales Ref")
        XCTAssertEqual(viaRef.rowCount, 2)
        XCTAssertEqual(e.dependencies()["Sales Ref"], ["Sales"])
        XCTAssertEqual(e.dependencyGraph().dependents["Sales"], ["Sales Ref"])
        XCTAssertEqual(e.dependencyGraph().topologicalOrder().firstIndex(of: "Sales")! < e.dependencyGraph().topologicalOrder().firstIndex(of: "Sales Ref")!, true)
        // turning a query into a function of a parameter
        let fn = MScript.toFunction("let Source = Sales, f = Table.SelectRows(Source, each [a] > Limit) in f", parameters: [("limit", "number")], replacing: ["Limit": "limit"])
        let viaFn = try await QueryEngine(queries: [q, QueryDefinition(name: "F", mScript: fn), QueryDefinition(name: "Call", mScript: "F(2)")], environment: env).evaluate("Call")
        XCTAssertEqual(viaFn.column("a")?.values, [.int(3)])
        var p = QueryParameter(); p.type = .integer; p.currentValue = .int(5); p.suggestedValues = [.int(1), .int(5)]
        XCTAssertEqual(MScript.parameterScript(p), "5 meta [IsParameterQuery=true, Type=\"Number\", IsParameterQueryRequired=true, List={1, 5}]")
        XCTAssertEqual(try eval(MScript.parameterScript(p)).numberValue, 5)
        // cyclic references are reported, not looped on
        let cyc = QueryEngine(queries: [QueryDefinition(name: "A", mScript: "B"), QueryDefinition(name: "B", mScript: "A")], environment: env)
        XCTAssertNotNil(cyc.dependencyGraph().findCycle())
        do { _ = try await cyc.evaluate("A"); XCTFail("expected a cycle error") } catch { XCTAssertTrue(MError.wrap(error).message.contains("cyclic")) }
        do { _ = try await e.evaluate("Missing"); XCTFail("expected an error") } catch { XCTAssertTrue("\(MError.wrap(error))".contains("Missing")) }
    }

    // MARK: Every Transform case

    /// One sample per `Transform` case. `name(of:)` has no default branch, so a new case fails to compile until it is listed.
    static let samples: [Transform] = [
        .keepTopRows(1), .keepBottomRows(1), .keepRangeOfRows(first: 1, count: 1), .removeTopRows(1), .removeBottomRows(1),
        .removeAlternateRows(firstToRemove: 1, numberToRemove: 1, numberToKeep: 1), .removeDuplicates(columns: ["a"]), .keepDuplicates(columns: ["a"]),
        .removeBlankRows, .removeErrors(columns: ["a"]), .keepErrors(columns: ["a"]), .filterRows(.isNull(column: "a")), .sortRows([("a", true)]),
        .chooseColumns(["a"]), .removeColumns(["a"]), .removeOtherColumns(keeping: ["a"]), .reorderColumns(["b", "a"]), .renameColumns([("a", "z")]),
        .duplicateColumn("a", newName: "a2"), .changeType([("a", .text)], culture: nil), .promoteHeaders, .demoteHeaders,
        .pivotColumn(column: "b", valueColumn: "a", aggregation: .sum), .unpivotColumns(["a"]), .unpivotOtherColumns(keeping: ["a"]), .transpose, .reverseRows,
        .groupBy(keys: ["b"], aggregations: [("n", .countRows)]), .countRows,
        .splitByDelimiter(column: "b", delimiter: ",", at: .each, into: .columns(2)), .splitByLength(column: "b", length: 1, repeated: true, into: .rows),
        .splitByPositions(column: "b", positions: [0, 1], into: .columns(2)), .splitByTransition(column: "b", .lowerToUpper, into: .columns(2)),
        .mergeColumns(["a", "b"], separator: "", newName: "ab"), .formatText(columns: ["b"], .trim), .addPrefix(columns: ["b"], "p"), .addSuffix(columns: ["b"], "s"),
        .extractText(column: "b", .length, newColumn: nil), .parse(column: "b", .json), .number(columns: ["a"], .absolute, newColumn: nil), .statistic(column: "a", .sum),
        .date(columns: ["a"], .year, newColumn: "y"), .earliest(column: "a"), .latest(column: "a"), .fillDown(["a"]), .fillUp(["a"]),
        .replaceValues(columns: ["a"], find: .int(1), replaceWith: .int(2), matchEntireCell: true), .replaceErrors(columns: ["a"], with: .null),
        .addCustomColumn(name: "c", expression: "1", type: nil), .addConditionalColumn(name: "c", clauses: [], otherwise: .value(.null)),
        .addIndexColumn(name: "i", start: 0, increment: 1), .invokeCustomFunction(name: "c", function: "F", arguments: []),
        .addColumnFromExamples(name: "c", expression: "[a]"),
        .mergeQueries(other: "O", leftKeys: ["a"], rightKeys: ["a"], kind: .inner, newColumn: "o", fuzzy: nil), .appendQueries(["O"]), .combineFiles(.json),
        .expandRecordColumn(column: "a", fields: ["x"], newNames: nil), .expandTableColumn(column: "a", columns: ["x"], newNames: nil), .expandListColumn(column: "a"),
        .extractListValues(column: "a", delimiter: ","), .aggregateTableColumn(column: "a", aggregations: [("x", .sum, "s")]),
        .aiSentiment(column: "b", newColumn: "s"), .aiKeyPhrases(column: "b", newColumn: "s"), .aiDetectLanguage(column: "b", newColumn: "s"),
        .aiTagImage(column: "b", newColumn: "s"), .runPythonScript("x = 1"), .runRScript("x <- 1"),
    ]
    static func name(of t: Transform) -> String {
        switch t {
        case .keepTopRows: return "keepTopRows"; case .keepBottomRows: return "keepBottomRows"; case .keepRangeOfRows: return "keepRangeOfRows"
        case .removeTopRows: return "removeTopRows"; case .removeBottomRows: return "removeBottomRows"; case .removeAlternateRows: return "removeAlternateRows"
        case .removeDuplicates: return "removeDuplicates"; case .keepDuplicates: return "keepDuplicates"; case .removeBlankRows: return "removeBlankRows"
        case .removeErrors: return "removeErrors"; case .keepErrors: return "keepErrors"; case .filterRows: return "filterRows"; case .sortRows: return "sortRows"
        case .chooseColumns: return "chooseColumns"; case .removeColumns: return "removeColumns"; case .removeOtherColumns: return "removeOtherColumns"
        case .reorderColumns: return "reorderColumns"; case .renameColumns: return "renameColumns"; case .duplicateColumn: return "duplicateColumn"
        case .changeType: return "changeType"; case .promoteHeaders: return "promoteHeaders"; case .demoteHeaders: return "demoteHeaders"
        case .pivotColumn: return "pivotColumn"; case .unpivotColumns: return "unpivotColumns"; case .unpivotOtherColumns: return "unpivotOtherColumns"
        case .transpose: return "transpose"; case .reverseRows: return "reverseRows"; case .groupBy: return "groupBy"; case .countRows: return "countRows"
        case .splitByDelimiter: return "splitByDelimiter"; case .splitByLength: return "splitByLength"; case .splitByPositions: return "splitByPositions"
        case .splitByTransition: return "splitByTransition"; case .mergeColumns: return "mergeColumns"; case .formatText: return "formatText"
        case .addPrefix: return "addPrefix"; case .addSuffix: return "addSuffix"; case .extractText: return "extractText"; case .parse: return "parse"
        case .number: return "number"; case .statistic: return "statistic"; case .date: return "date"; case .earliest: return "earliest"; case .latest: return "latest"
        case .fillDown: return "fillDown"; case .fillUp: return "fillUp"; case .replaceValues: return "replaceValues"; case .replaceErrors: return "replaceErrors"
        case .addCustomColumn: return "addCustomColumn"; case .addConditionalColumn: return "addConditionalColumn"; case .addIndexColumn: return "addIndexColumn"
        case .invokeCustomFunction: return "invokeCustomFunction"; case .addColumnFromExamples: return "addColumnFromExamples"
        case .mergeQueries: return "mergeQueries"; case .appendQueries: return "appendQueries"; case .combineFiles: return "combineFiles"
        case .expandRecordColumn: return "expandRecordColumn"; case .expandTableColumn: return "expandTableColumn"; case .expandListColumn: return "expandListColumn"
        case .extractListValues: return "extractListValues"; case .aggregateTableColumn: return "aggregateTableColumn"
        case .aiSentiment: return "aiSentiment"; case .aiKeyPhrases: return "aiKeyPhrases"; case .aiDetectLanguage: return "aiDetectLanguage"
        case .aiTagImage: return "aiTagImage"; case .runPythonScript: return "runPythonScript"; case .runRScript: return "runRScript"
        }
    }
    func testEveryTransformCaseHasAStepNameAndValidMUsingOnlyKnownFunctions() throws {
        XCTAssertEqual(Set(Self.samples.map(Self.name)).count, 67, "one sample per Transform case")
        XCTAssertEqual(Self.samples.count, 67)
        let library = Set(MLibrary.shared.names)
        for t in Self.samples {
            XCTAssertFalse(t.stepName.isEmpty, Self.name(of: t))
            let s = MScript.appending(t, to: "let\n    Source = #table({\"a\", \"b\"}, {})\nin\n    Source")
            XCTAssertNoThrow(try MParser.parse(s), "\(Self.name(of: t)): \(s)")
            let steps = MScript.steps(of: s)
            XCTAssertEqual(steps.count, 2, Self.name(of: t))
            XCTAssertEqual(steps.last?.name, t.stepName)
            // every library function the generated M calls exists in the engine
            let unknown = MScript.referencedIdentifiers(in: s, excludingLibrary: false).filter { $0.contains(".") && !library.contains($0) }
            XCTAssertEqual(unknown, [], Self.name(of: t))
        }
    }
}
