import XCTest
import FacetCore
@testable import FacetQuery

/// Evaluate M text with a fresh interpreter (test helper shared by all test files).
func m(_ text: String, env: QueryEnvironment = QueryEnvironment()) throws -> MValue {
    try MInterpreter(environment: env).evaluate(text)
}
func mNum(_ text: String) throws -> Double {
    guard case .number(let d) = try m(text) else { XCTFail("not a number: \(text)"); return .nan }
    return d
}
func mText(_ text: String) throws -> String {
    guard case .text(let s) = try m(text) else { XCTFail("not text: \(text)"); return "" }
    return s
}
func mBool(_ text: String) throws -> Bool {
    guard case .logical(let b) = try m(text) else { XCTFail("not logical: \(text)"); return false }
    return b
}
func mErr(_ text: String) -> String? {
    do { _ = try m(text); return nil } catch { return MError.wrap(error).message }
}

final class MLanguageTests: XCTestCase {
    func testLiteralsAndArithmetic() throws {
        XCTAssertEqual(try mNum("1 + 2 * 3"), 7)
        XCTAssertEqual(try mNum("(1 + 2) * 3"), 9)
        XCTAssertEqual(try mNum("0x10 + 1e2"), 116)
        XCTAssertEqual(try mNum("-3 - -2"), -1)
        XCTAssertEqual(try mText("\"a\"\"b\" & \"#(lf)c#(tab)#(0041)\""), "a\"b\nc\tA")
        XCTAssertTrue(try m("null + 1").isNull)
        XCTAssertTrue(try mNum("1 / 0").isInfinite)
        XCTAssertTrue(try mBool("1 < 2 and not (2 < 1) or false"))
        XCTAssertEqual(try mNum("null ?? 5"), 5)
        XCTAssertTrue(try m("null and true").isNull)
        XCTAssertFalse(try mBool("null and false"))
        XCTAssertTrue(try mBool("null = null"))
        XCTAssertTrue(try m("null < 1").isNull)
    }
    func testLetLazinessAndComments() throws {
        XCTAssertEqual(try mNum("let a = 1, /* block */ b = a + 1, unused = error \"boom\" // never forced\n in b"), 2)
        XCTAssertEqual(try mNum("let #\"my var\" = 4, r = #\"my var\" * 2 in r"), 8)
        XCTAssertEqual(try mNum("let fact = (n) => if n <= 1 then 1 else n * @fact(n - 1) in fact(10)"), 3628800)
        XCTAssertNotNil(mErr("let a = b, b = a in a"))
    }
    func testRecordsListsAccess() throws {
        XCTAssertEqual(try mNum("[a = 1, b = a + 1][b]"), 2)
        XCTAssertEqual(try mNum("[a = 1, bad = error \"x\"][a]"), 1)
        XCTAssertTrue(try m("[a = 1][z]?").isNull)
        XCTAssertNotNil(mErr("[a = 1][z]"))
        XCTAssertEqual(try mNum("{1, 2, 3}{1}"), 2)
        XCTAssertTrue(try m("{1}{5}?").isNull)
        XCTAssertEqual(try m("{1..5}").listValue?.count, 5)
        XCTAssertEqual(try m("{1, error \"x\", 3}").listValue?.count, 3)
        XCTAssertEqual(try mNum("[Order Date = 5][Order Date]"), 5)
        XCTAssertEqual(try m("[a=1,b=2,c=3][[a],[c]]").recordValue?.names, ["a", "c"])
        XCTAssertEqual(try mNum("([a = 1] & [b = 2])[b]"), 2)
        XCTAssertEqual(try m("{1} & {2, 3}").listValue?.count, 3)
        XCTAssertTrue(try mBool("[a=1,b=2] = [b=2,a=1]"))
    }
    func testFunctionsEachTry() throws {
        XCTAssertEqual(try mNum("((x as number, optional y) as number => x + (y ?? 10))(1)"), 11)
        XCTAssertEqual(try mNum("(each _ * 2)(4)"), 8)
        XCTAssertEqual(try mNum("(each [a] + 1)([a = 2])"), 3)
        XCTAssertNotNil(mErr("((x as number) => x)(\"a\")"))
        XCTAssertEqual(try mNum("try error \"x\" otherwise 7"), 7)
        XCTAssertTrue(try mBool("(try error \"x\")[HasError]"))
        XCTAssertEqual(try mText("(try error \"bad\")[Error][Message]"), "bad")
        XCTAssertEqual(try mNum("(try 5)[Value]"), 5)
        XCTAssertEqual(try mText("try error [Reason = \"R\", Message = \"M\"] catch (e) => e[Reason] & e[Message]"), "RM")
        XCTAssertEqual(try mNum("try error \"x\" catch () => 3"), 3)
        XCTAssertEqual(try mNum("if 1 > 2 then 1 else 2"), 2)
    }
    func testTypesAndConstructors() throws {
        XCTAssertTrue(try mBool("1 is number"))
        XCTAssertTrue(try mBool("null is nullable text"))
        XCTAssertFalse(try mBool("\"a\" is number"))
        XCTAssertNotNil(mErr("\"a\" as number"))
        XCTAssertTrue(try mBool("Value.Type(1) = type number"))
        XCTAssertEqual(try m("type table [a = text, b = Int64.Type]").typeValue, .table([MTypeField("a", .text), MTypeField("b", .int64)]))
        XCTAssertEqual(try m("type nullable number").typeValue, .nullable(.plainNumber))
        XCTAssertEqual(try m("type {text}").typeValue, .list(.text))
        XCTAssertTrue(try mBool("#date(2024, 1, 31) + #duration(1, 0, 0, 0) = #date(2024, 2, 1)"))
        XCTAssertTrue(try mBool("#datetime(2024, 1, 1, 12, 0, 0) - #datetime(2024, 1, 1, 0, 0, 0) = #duration(0, 12, 0, 0)"))
        XCTAssertTrue(try mBool("#date(2024,1,1) & #time(1,2,3) = #datetime(2024,1,1,1,2,3)"))
        let t = try m("#table({\"a\", \"b\"}, {{1, \"x\"}, {2, \"y\"}})").tableValue
        XCTAssertEqual(try t?.rowCount, 2)
        XCTAssertEqual(try mText("#table({\"a\", \"b\"}, {{1, \"x\"}, {2, \"y\"}}){1}[b]"), "y")
        XCTAssertEqual(try mText("#table({\"a\", \"b\"}, {{1, \"x\"}, {2, \"y\"}}){[a = 2]}[b]"), "y")
        XCTAssertEqual(try m("#table({\"a\", \"b\"}, {{1, \"x\"}})[a]").listValue?.count, 1)
        XCTAssertEqual(try m("#table(type table [a = number], {{1}})").tableValue?.columnTypes, [.plainNumber])
        XCTAssertEqual(try mNum("Expression.Evaluate(\"x + 1\", [x = 2])"), 3)
        XCTAssertEqual(try mNum("Record.Field([a = 9], \"a\")"), 9)
        XCTAssertNotNil(mErr("1 +"))
        XCTAssertEqual(try m("section S; shared a = 1; b = a + 1;").recordValue?.names, ["a", "b"])
    }
    func testConversions() throws {
        XCTAssertEqual(MConvert.parseNumber("1.234,5", culture: "de-DE"), 1234.5)
        XCTAssertEqual(MConvert.parseNumber("(1,000.50)"), -1000.5)
        XCTAssertEqual(MConvert.parseNumber("45%"), 0.45)
        XCTAssertEqual(MConvert.formatNumber(1234.567, format: "N2"), "1,234.57")
        XCTAssertEqual(MConvert.formatNumber(0.256, format: "P1"), "25.6 %")
        XCTAssertEqual(MConvert.formatNumber(42, format: "D5"), "00042")
        XCTAssertEqual(MConvert.formatNumber(1234.5, format: "#,##0.00"), "1,234.50")
        XCTAssertEqual(MConvert.formatNumber(0.5, format: "0.0%"), "50.0%")
        XCTAssertEqual(MConvert.formatNumber(255, format: "X"), "FF")
        let d = try MLibrary.makeDate(2024, 3, 5)
        XCTAssertEqual(MConvert.formatDate(d, format: "yyyy-MM-dd"), "2024-03-05")
        XCTAssertEqual(MConvert.formatDate(d, format: "ddd, d MMMM yyyy"), "Tue, 5 March 2024")
        XCTAssertEqual(MConvert.formatDate(d, format: "d"), "3/5/2024")
        XCTAssertEqual(MConvert.parseDateTime("2024-03-05T10:20:30Z")?.offsetMinutes, 0)
        XCTAssertEqual(MConvert.parseDateTime("3/5/2024")?.date, d)
        XCTAssertEqual(MConvert.parseDateTime("5/3/2024", culture: "en-GB")?.date, d)
        XCTAssertEqual(MConvert.parseDateTime("March 5, 2024")?.date, d)
        XCTAssertNil(MConvert.parseDateTime("2024-02-30"))
        XCTAssertEqual(MConvert.parseDuration("1.02:03:04"), 93784)
        XCTAssertEqual(MConvert.durationText(93784), "1.02:03:04")
        XCTAssertEqual(MSyntax.literal(.date(d)), "#date(2024, 3, 5)")
        XCTAssertEqual(MSyntax.field("Order Date"), "[Order Date]")
        XCTAssertEqual(MSyntax.field("a]b"), "[#\"a]b\"]")
        XCTAssertEqual(MSyntax.identifier("my col"), "#\"my col\"")
    }
}
