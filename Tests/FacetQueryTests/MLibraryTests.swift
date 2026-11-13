import XCTest
import FacetCore
@testable import FacetQuery

/// Numbers of an M list expression.
func mNums(_ text: String) throws -> [Double] {
    guard case .list(let l) = try m(text) else { XCTFail("not a list: \(text)"); return [] }
    return try l.map { try $0.forced().numberValue ?? .nan }
}
/// Texts of an M list expression (null → "<null>").
func mTexts(_ text: String) throws -> [String] {
    guard case .list(let l) = try m(text) else { XCTFail("not a list: \(text)"); return [] }
    return try l.map { try $0.forced().textValue ?? "<null>" }
}

/// The standard library areas the transforms are built on: List, Text, Number, Date/Time/Duration.
/// Expected values follow the Power Query M function reference.
final class MLibraryTests: XCTestCase {
    func testListAggregatesIgnoreNulls() throws {
        XCTAssertEqual(try mNum("List.Sum({1, null, 2.5})"), 3.5)
        XCTAssertTrue(try m("List.Sum({})").isNull)
        XCTAssertEqual(try mNum("List.Average({2, null, 4})"), 3)
        XCTAssertEqual(try mNum("List.Count({1, null, 3})"), 3)
        XCTAssertEqual(try mNum("List.NonNullCount({1, null, 3})"), 2)
        XCTAssertEqual(try mNum("List.Max({3, null, 7, 5})"), 7)
        XCTAssertEqual(try mNum("List.Min({3, null, 7, 5})"), 3)
        XCTAssertEqual(try mNum("List.Max({}, -1)"), -1)
        XCTAssertEqual(try mNum("List.Median({5, 1, 3})"), 3)
        XCTAssertEqual(try mNum("List.Median({4, 1, 3, 2})"), 2.5)
        // sample standard deviation of 2,4,4,4,5,5,7,9: mean 5, squared deviations sum 32, 32/7
        XCTAssertEqual(try mNum("List.StandardDeviation({2, 4, 4, 4, 5, 5, 7, 9})"), (32.0 / 7).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(try mNum("List.Product({2, 3, 4})"), 24)
        XCTAssertEqual(try mNum("List.Mode({1, 2, 2, 3, 3})"), 3) // ties: the last one
        XCTAssertEqual(try mNums("List.Modes({1, 2, 2, 3, 3})"), [2, 3])
    }
    func testListSelectionAndOrder() throws {
        XCTAssertEqual(try mNums("List.FirstN({1, 2, 3, 4}, 2)"), [1, 2])
        XCTAssertEqual(try mNums("List.FirstN({1, 2, 5, 1}, each _ < 3)"), [1, 2])
        XCTAssertEqual(try mNums("List.LastN({1, 2, 3, 4}, 3)"), [2, 3, 4])
        XCTAssertEqual(try mNums("List.Skip({1, 2, 3})"), [2, 3])
        XCTAssertEqual(try mNums("List.Range({1, 2, 3, 4, 5}, 1, 3)"), [2, 3, 4])
        XCTAssertEqual(try mNums("List.RemoveLastN({1, 2, 3}, 2)"), [1])
        XCTAssertEqual(try mNums("List.Reverse({1, 2, 3})"), [3, 2, 1])
        XCTAssertEqual(try mNums("List.Sort({3, 1, 2})"), [1, 2, 3])
        XCTAssertEqual(try mNums("List.Sort({3, 1, 2}, Order.Descending)"), [3, 2, 1])
        XCTAssertEqual(try mTexts("List.Sort({\"b\", \"A\", \"a\"}, Comparer.OrdinalIgnoreCase)"), ["A", "a", "b"])
        XCTAssertEqual(try mNums("List.Distinct({1, 2, 1, 3, 2})"), [1, 2, 3])
        XCTAssertEqual(try mTexts("List.Distinct({\"a\", \"A\", \"b\"}, Comparer.OrdinalIgnoreCase)"), ["a", "b"])
        XCTAssertEqual(try mNums("List.Select({1, 2, 3, 4}, each Number.IsEven(_))"), [2, 4])
        XCTAssertEqual(try mNums("List.Transform({1, 2}, each _ * 10)"), [10, 20])
        XCTAssertEqual(try mNum("List.Accumulate({1, 2, 3}, 10, (state, x) => state + x)"), 16)
        XCTAssertEqual(try mNum("List.PositionOf({\"a\", \"b\", \"a\"}, \"a\", Occurrence.Last)"), 2)
        XCTAssertEqual(try mNum("List.PositionOf({1, 2}, 9)"), -1)
        XCTAssertTrue(try mBool("List.Contains({1, 2, 3}, 2)"))
        XCTAssertTrue(try mBool("List.ContainsAll({1, 2, 3}, {3, 1})"))
        XCTAssertFalse(try mBool("List.ContainsAny({1, 2, 3}, {4, 5})"))
        XCTAssertEqual(try mNums("List.RemoveMatchingItems({1, 2, 3, 2}, {2})"), [1, 3])
        XCTAssertEqual(try mNums("List.Difference({1, 2, 2, 3}, {2})"), [1, 2, 3])
        XCTAssertEqual(try mNums("List.Intersect({{1, 2, 3}, {2, 3, 4}})"), [2, 3])
        XCTAssertEqual(try mNums("List.Union({{1, 2}, {2, 3}})"), [1, 2, 3])
        XCTAssertEqual(try mNums("List.Combine({{1}, {2, 3}})"), [1, 2, 3])
        XCTAssertEqual(try mNums("List.RemoveNulls({1, null, 2})"), [1, 2])
        XCTAssertNotNil(mErr("List.Single({1, 2})"))
    }
    func testListGenerators() throws {
        XCTAssertEqual(try mNums("List.Numbers(1, 4, 2)"), [1, 3, 5, 7])
        XCTAssertEqual(try mNums("List.Generate(() => 1, each _ < 20, each _ * 3)"), [1, 3, 9])
        XCTAssertEqual(try mNums("List.Transform(List.Dates(#date(2024, 2, 28), 3, #duration(1, 0, 0, 0)), Date.Day)"), [28, 29, 1])
        XCTAssertEqual(try mNum("List.Count(List.Zip({{1, 2}, {3}}))"), 2)
        XCTAssertTrue(try m("List.Zip({{1, 2}, {3}}){1}{1}").isNull)
        XCTAssertEqual(try mNums("List.Repeat({1, 2}, 2)"), [1, 2, 1, 2])
        XCTAssertEqual(try mNum("List.Count(List.Split({1, 2, 3, 4, 5}, 2))"), 3)
    }
    func testTextFunctions() throws {
        XCTAssertEqual(try mText("Text.Upper(\"aBc\")"), "ABC")
        XCTAssertEqual(try mText("Text.Lower(\"aBc\")"), "abc")
        XCTAssertEqual(try mText("Text.Proper(\"the QUICK brown fox\")"), "The Quick Brown Fox")
        XCTAssertEqual(try mText("Text.Trim(\"  a b  \")"), "a b")
        XCTAssertEqual(try mText("Text.Trim(\"xxaxx\", \"x\")"), "a")
        XCTAssertEqual(try mText("Text.TrimStart(\"  a \")"), "a ")
        XCTAssertEqual(try mText("Text.Clean(\"a#(lf)b#(tab)c\")"), "abc")
        XCTAssertEqual(try mNum("Text.Length(\"héllo\")"), 5)
        XCTAssertEqual(try mText("Text.Start(\"Hello\", 2)"), "He")
        XCTAssertEqual(try mText("Text.End(\"Hello\", 3)"), "llo")
        XCTAssertEqual(try mText("Text.Middle(\"Hello World\", 6, 3)"), "Wor")
        XCTAssertEqual(try mText("Text.Middle(\"Hello\", 9)"), "")
        XCTAssertEqual(try mText("Text.Range(\"Hello World\", 6)"), "World")
        XCTAssertNotNil(mErr("Text.Range(\"abc\", 2, 5)"))
        XCTAssertEqual(try mText("Text.At(\"abc\", 1)"), "b")
        XCTAssertTrue(try mBool("Text.Contains(\"Hello\", \"ell\")"))
        XCTAssertFalse(try mBool("Text.Contains(\"Hello\", \"ELL\")"))
        XCTAssertTrue(try mBool("Text.Contains(\"Hello\", \"ELL\", Comparer.OrdinalIgnoreCase)"))
        XCTAssertTrue(try m("Text.Contains(null, \"a\")").isNull)
        XCTAssertTrue(try mBool("Text.StartsWith(\"Hello\", \"He\")"))
        XCTAssertTrue(try mBool("Text.EndsWith(\"Hello\", \"LO\", Comparer.OrdinalIgnoreCase)"))
        XCTAssertEqual(try mNum("Text.PositionOf(\"a-b-c\", \"-\")"), 1)
        XCTAssertEqual(try mNum("Text.PositionOf(\"a-b-c\", \"-\", Occurrence.Last)"), 3)
        XCTAssertEqual(try mNum("Text.PositionOf(\"abc\", \"z\")"), -1)
        XCTAssertEqual(try mText("Text.Replace(\"a-b-c\", \"-\", \"+\")"), "a+b+c")
        XCTAssertEqual(try mText("Text.Remove(\"a1b2c3\", {\"0\"..\"9\"})"), "abc")
        XCTAssertEqual(try mText("Text.Select(\"a1b2c3\", {\"0\"..\"9\"})"), "123")
        XCTAssertEqual(try mText("Text.Insert(\"abc\", 1, \"XY\")"), "aXYbc")
        XCTAssertEqual(try mText("Text.RemoveRange(\"abcdef\", 1, 3)"), "aef")
        XCTAssertEqual(try mText("Text.ReplaceRange(\"abcdef\", 1, 3, \"-\")"), "a-ef")
        XCTAssertEqual(try mText("Text.PadStart(\"7\", 3, \"0\")"), "007")
        XCTAssertEqual(try mText("Text.PadEnd(\"7\", 3, \"*\")"), "7**")
        XCTAssertEqual(try mText("Text.Repeat(\"ab\", 3)"), "ababab")
        XCTAssertEqual(try mText("Text.Reverse(\"abc\")"), "cba")
        XCTAssertEqual(try mTexts("Text.Split(\"a,b,,c\", \",\")"), ["a", "b", "", "c"])
        XCTAssertEqual(try mTexts("Text.SplitAny(\"a,b;c\", \",;\")"), ["a", "b", "c"])
        XCTAssertEqual(try mText("Text.Combine({\"a\", null, \"b\"}, \"-\")"), "a-b")
        XCTAssertEqual(try mText("Text.Format(\"#{0} of #{1}\", {1, \"x\"})"), "1 of x")
        XCTAssertEqual(try mText("Text.Format(\"#[a]!\", [a = \"hi\"])"), "hi!")
        XCTAssertTrue(try m("Text.Upper(null)").isNull)
        XCTAssertEqual(try mText("Character.FromNumber(65)"), "A")
        XCTAssertEqual(try mNum("Character.ToNumber(\"a\")"), 97)
    }
    func testTextDelimiters() throws {
        XCTAssertEqual(try mText("Text.BeforeDelimiter(\"111-222-333\", \"-\")"), "111")
        XCTAssertEqual(try mText("Text.BeforeDelimiter(\"111-222-333\", \"-\", 1)"), "111-222")
        XCTAssertEqual(try mText("Text.BeforeDelimiter(\"111-222-333\", \"-\", {0, RelativePosition.FromEnd})"), "111-222")
        XCTAssertEqual(try mText("Text.BeforeDelimiter(\"abc\", \"-\")"), "abc")
        XCTAssertEqual(try mText("Text.AfterDelimiter(\"111-222-333\", \"-\")"), "222-333")
        XCTAssertEqual(try mText("Text.AfterDelimiter(\"111-222-333\", \"-\", 1)"), "333")
        XCTAssertEqual(try mText("Text.AfterDelimiter(\"abc\", \"-\")"), "")
        XCTAssertEqual(try mText("Text.BetweenDelimiters(\"111 (222) 333 (444)\", \"(\", \")\")"), "222")
        XCTAssertEqual(try mText("Text.BetweenDelimiters(\"111 (222) 333 (444)\", \"(\", \")\", 1, 0)"), "444")
        XCTAssertEqual(try mText("Text.BetweenDelimiters(\"abc\", \"(\", \")\")"), "")
    }
    func testSplittersAndCombiners() throws {
        XCTAssertEqual(try mTexts("Splitter.SplitTextByDelimiter(\",\")(\"a,b,c\")"), ["a", "b", "c"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByDelimiter(\",\", QuoteStyle.Csv)(\"a,\"\"b,c\"\",d\")"), ["a", "b,c", "d"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByDelimiter(\",\", QuoteStyle.None)(\"a,\"\"b,c\"\",d\")"), ["a", "\"b", "c\"", "d"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByEachDelimiter({\",\"}, QuoteStyle.Csv, false)(\"a,b,c\")"), ["a", "b,c"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByEachDelimiter({\",\"}, QuoteStyle.Csv, true)(\"a,b,c\")"), ["a,b", "c"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByAnyDelimiter({\",\", \";\"})(\"a,b;c\")"), ["a", "b", "c"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByPositions({0, 2, 4})(\"abcdef\")"), ["ab", "cd", "ef"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByRepeatedLengths(3)(\"abcdefgh\")"), ["abc", "def", "gh"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByLengths({1, 2})(\"abcdef\")"), ["a", "bc"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByRanges({{0, 2}, {3, 1}})(\"abcdef\")"), ["ab", "d"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByWhitespace()(\"a  b#(tab)c\")"), ["a", "b", "c"])
        XCTAssertEqual(try mTexts("Splitter.SplitTextByCharacterTransition({\"a\"..\"z\"}, {\"A\"..\"Z\"})(\"camelCaseText\")"), ["camel", "Case", "Text"])
        XCTAssertEqual(try mText("Combiner.CombineTextByDelimiter(\"-\")({\"a\", \"b\"})"), "a-b")
        XCTAssertEqual(try mText("Combiner.CombineTextByDelimiter(\",\", QuoteStyle.Csv)({\"a\", \"b,c\"})"), "a,\"b,c\"")
        XCTAssertEqual(try mText("Replacer.ReplaceText(\"hello\", \"l\", \"L\")"), "heLLo")
        XCTAssertEqual(try mNum("Replacer.ReplaceValue(1, 1, 5)"), 5)
        XCTAssertEqual(try mNum("Replacer.ReplaceValue(11, 1, 5)"), 11)
    }
    func testNumberFunctions() throws {
        XCTAssertEqual(try mNum("Number.Round(2.5)"), 2) // ties go to even by default
        XCTAssertEqual(try mNum("Number.Round(3.5)"), 4)
        XCTAssertEqual(try mNum("Number.Round(-2.5)"), -2)
        XCTAssertEqual(try mNum("Number.Round(2.5, 0, RoundingMode.AwayFromZero)"), 3)
        XCTAssertEqual(try mNum("Number.Round(2.5, 0, RoundingMode.Down)"), 2)
        XCTAssertEqual(try mNum("Number.Round(-2.5, 0, RoundingMode.Up)"), -2)
        XCTAssertEqual(try mNum("Number.Round(1.25, 1)"), 1.2)
        XCTAssertEqual(try mNum("Number.Round(1.2345, 2)"), 1.23)
        XCTAssertEqual(try mNum("Number.Round(1234.5, -2)"), 1200)
        XCTAssertEqual(try mNum("Number.RoundUp(1.2)"), 2)
        XCTAssertEqual(try mNum("Number.RoundUp(-1.2)"), -1)
        XCTAssertEqual(try mNum("Number.RoundDown(1.8)"), 1)
        XCTAssertEqual(try mNum("Number.RoundDown(-1.2)"), -2)
        XCTAssertEqual(try mNum("Number.RoundTowardZero(-1.8)"), -1)
        XCTAssertEqual(try mNum("Number.RoundAwayFromZero(-1.2)"), -2)
        XCTAssertEqual(try mNum("Number.RoundUp(1.234, 2)"), 1.24)
        XCTAssertEqual(try mNum("Number.IntegerDivide(7, 2)"), 3)
        XCTAssertEqual(try mNum("Number.IntegerDivide(-7, 2)"), -3)
        XCTAssertEqual(try mNum("Number.Mod(5, 3)"), 2)
        XCTAssertEqual(try mNum("Number.Mod(-5, 3)"), -2)
        XCTAssertEqual(try mNum("Number.Power(2, 10)"), 1024)
        XCTAssertEqual(try mNum("Number.Sqrt(625)"), 25)
        XCTAssertEqual(try mNum("Number.Abs(-3)"), 3)
        XCTAssertEqual(try mNum("Number.Sign(-3)"), -1)
        XCTAssertEqual(try mNum("Number.Factorial(5)"), 120)
        XCTAssertEqual(try mNum("Number.Log10(1000)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try mNum("Number.Log(8, 2)"), 3, accuracy: 1e-12)
        XCTAssertEqual(try mNum("Number.Ln(Number.E)"), 1, accuracy: 1e-12)
        XCTAssertEqual(try mNum("Number.Exp(0)"), 1)
        XCTAssertEqual(try mNum("Number.Sin(0) + Number.Cos(0)"), 1)
        XCTAssertEqual(try mNum("Number.Combinations(5, 2)"), 10)
        XCTAssertEqual(try mNum("Number.BitwiseAnd(12, 10)"), 8)
        XCTAssertTrue(try mBool("Number.IsEven(4)"))
        XCTAssertTrue(try mBool("Number.IsOdd(7)"))
        XCTAssertTrue(try mBool("Number.IsNaN(0 / 0)"))
        XCTAssertTrue(try m("Number.Abs(null)").isNull)
    }
    func testNumberConversion() throws {
        XCTAssertEqual(try mNum("Number.From(\"1,234.5\")"), 1234.5)
        XCTAssertEqual(try mNum("Number.From(\"1.234,5\", \"de-DE\")"), 1234.5)
        XCTAssertEqual(try mNum("Number.From(true)"), 1)
        XCTAssertEqual(try mNum("Number.From(\"12%\")"), 0.12, accuracy: 1e-12)
        XCTAssertEqual(try mNum("Number.From(#date(1900, 1, 1))"), 2) // OLE automation date
        XCTAssertNotNil(mErr("Number.From(\"abc\")"))
        XCTAssertEqual(try mNum("Int64.From(2.5)"), 2)
        XCTAssertEqual(try mNum("Int64.From(3.5)"), 4)
        XCTAssertEqual(try mNum("Int64.From(\"42\")"), 42)
        XCTAssertNotNil(mErr("Byte.From(300)"))
        XCTAssertEqual(try mNum("Currency.From(1.23456)"), 1.2346, accuracy: 1e-12)
        XCTAssertEqual(try mText("Number.ToText(1234.5, \"N2\")"), "1,234.50")
        XCTAssertEqual(try mText("Number.ToText(0.256, \"P1\")"), "25.6 %") // .NET puts a space before the percent sign in en-US
        XCTAssertEqual(try mText("Text.From(12)"), "12")
        XCTAssertEqual(try mText("Text.From(true)"), "true")
    }
    func testDateParts() throws {
        // 15 August 2024 is a Thursday; 2024 is a leap year.
        let d = "#date(2024, 8, 15)"
        XCTAssertEqual(try mNum("Date.Year(\(d))"), 2024)
        XCTAssertEqual(try mNum("Date.Month(\(d))"), 8)
        XCTAssertEqual(try mNum("Date.Day(\(d))"), 15)
        XCTAssertEqual(try mNum("Date.QuarterOfYear(\(d))"), 3)
        XCTAssertEqual(try mNum("Date.DayOfYear(\(d))"), 228) // 31+29+31+30+31+30+31 = 213, + 15
        XCTAssertEqual(try mNum("Date.DaysInMonth(#date(2024, 2, 1))"), 29)
        XCTAssertEqual(try mNum("Date.DaysInMonth(#date(2023, 2, 1))"), 28)
        XCTAssertTrue(try mBool("Date.IsLeapYear(\(d))"))
        XCTAssertFalse(try mBool("Date.IsLeapYear(#date(1900, 1, 1))"))
        XCTAssertEqual(try mNum("Date.DayOfWeek(\(d), Day.Sunday)"), 4)
        XCTAssertEqual(try mNum("Date.DayOfWeek(\(d), Day.Monday)"), 3)
        XCTAssertEqual(try mNum("Date.DayOfWeek(\(d))"), 4) // en-US weeks start on Sunday
        XCTAssertEqual(try mText("Date.DayOfWeekName(\(d))"), "Thursday")
        XCTAssertEqual(try mText("Date.MonthName(\(d))"), "August")
        XCTAssertEqual(try mText("Date.MonthName(\(d), \"fr-FR\")"), "août")
        // 1 Jan 2024 is a Monday: with Sunday weeks, week 1 is Jan 1-6 and Aug 15 is day 228 → (227 + 1) / 7 + 1 = 33
        XCTAssertEqual(try mNum("Date.WeekOfYear(\(d), Day.Sunday)"), 33)
        XCTAssertEqual(try mNum("Date.WeekOfYear(#date(2024, 1, 7), Day.Sunday)"), 2)
        XCTAssertEqual(try mNum("Date.WeekOfYear(#date(2024, 1, 7), Day.Monday)"), 1)
        // 1 Aug 2024 is a Thursday: Sunday weeks → Aug 1-3 week 1, 4-10 week 2, 11-17 week 3
        XCTAssertEqual(try mNum("Date.WeekOfMonth(\(d), Day.Sunday)"), 3)
        XCTAssertTrue(try m("Date.Year(null)").isNull)
    }
    func testDatePeriods() throws {
        func ymd(_ e: String) throws -> [Double] { try mNums("let d = \(e) in {Date.Year(d), Date.Month(d), Date.Day(d)}") }
        let d = "#date(2024, 8, 15)"
        XCTAssertEqual(try ymd("Date.StartOfYear(\(d))"), [2024, 1, 1])
        XCTAssertEqual(try ymd("Date.EndOfYear(\(d))"), [2024, 12, 31])
        XCTAssertEqual(try ymd("Date.StartOfQuarter(\(d))"), [2024, 7, 1])
        XCTAssertEqual(try ymd("Date.EndOfQuarter(\(d))"), [2024, 9, 30])
        XCTAssertEqual(try ymd("Date.StartOfMonth(\(d))"), [2024, 8, 1])
        XCTAssertEqual(try ymd("Date.EndOfMonth(#date(2024, 2, 10))"), [2024, 2, 29])
        XCTAssertEqual(try ymd("Date.StartOfWeek(\(d), Day.Monday)"), [2024, 8, 12])
        XCTAssertEqual(try ymd("Date.StartOfWeek(\(d), Day.Sunday)"), [2024, 8, 11])
        XCTAssertEqual(try ymd("Date.EndOfWeek(\(d), Day.Monday)"), [2024, 8, 18])
        XCTAssertEqual(try ymd("Date.AddDays(\(d), 20)"), [2024, 9, 4])
        XCTAssertEqual(try ymd("Date.AddWeeks(\(d), -1)"), [2024, 8, 8])
        XCTAssertEqual(try ymd("Date.AddMonths(#date(2024, 1, 31), 1)"), [2024, 2, 29]) // clamped to the month end
        XCTAssertEqual(try ymd("Date.AddQuarters(\(d), 2)"), [2025, 2, 15])
        XCTAssertEqual(try ymd("Date.AddYears(#date(2024, 2, 29), 1)"), [2025, 2, 28])
        XCTAssertTrue(try mBool("Date.StartOfMonth(\(d)) is date"))
        // On a datetime the result stays a datetime; the end is the last instant of the period.
        let dt = "#datetime(2024, 8, 15, 10, 30, 0)"
        XCTAssertTrue(try mBool("Date.StartOfDay(\(dt)) = #datetime(2024, 8, 15, 0, 0, 0)"))
        XCTAssertTrue(try mBool("Date.EndOfDay(\(dt)) is datetime"))
        XCTAssertTrue(try mBool("Date.EndOfDay(\(dt)) < #datetime(2024, 8, 16, 0, 0, 0) and Date.EndOfDay(\(dt)) > #datetime(2024, 8, 15, 23, 59, 59)"))
        XCTAssertEqual(try mNums("{Time.Hour(Date.EndOfMonth(\(dt))), Time.Minute(Date.EndOfMonth(\(dt))), Date.Day(Date.EndOfMonth(\(dt)))}"), [23, 59, 31])
    }
    func testRelativeDateTests() throws {
        var env = QueryEnvironment()
        env.timeZone = TimeZone(identifier: "UTC") ?? .current
        env.now = { Date(timeIntervalSince1970: 1_723_717_800) } // 2024-08-15 10:30:00 UTC, a Thursday
        func b(_ e: String) throws -> Bool { try m(e, env: env).logicalValue ?? false }
        XCTAssertTrue(try b("DateTime.LocalNow() = #datetime(2024, 8, 15, 10, 30, 0)"))
        XCTAssertTrue(try b("Date.IsInCurrentDay(#date(2024, 8, 15))"))
        XCTAssertFalse(try b("Date.IsInCurrentDay(#date(2024, 8, 14))"))
        XCTAssertTrue(try b("Date.IsInPreviousDay(#date(2024, 8, 14))"))
        XCTAssertTrue(try b("Date.IsInNextDay(#date(2024, 8, 16))"))
        XCTAssertTrue(try b("Date.IsInCurrentWeek(#date(2024, 8, 11))")) // Sunday that starts the en-US week
        XCTAssertFalse(try b("Date.IsInCurrentWeek(#date(2024, 8, 10))"))
        XCTAssertTrue(try b("Date.IsInPreviousWeek(#date(2024, 8, 10))"))
        XCTAssertTrue(try b("Date.IsInCurrentMonth(#date(2024, 8, 1))"))
        XCTAssertTrue(try b("Date.IsInPreviousMonth(#date(2024, 7, 31))"))
        XCTAssertTrue(try b("Date.IsInNextMonth(#date(2024, 9, 30))"))
        XCTAssertFalse(try b("Date.IsInNextMonth(#date(2024, 10, 1))"))
        XCTAssertTrue(try b("Date.IsInCurrentQuarter(#date(2024, 7, 1))"))
        XCTAssertTrue(try b("Date.IsInPreviousQuarter(#date(2024, 6, 30))"))
        XCTAssertTrue(try b("Date.IsInCurrentYear(#date(2024, 12, 31))"))
        XCTAssertTrue(try b("Date.IsInPreviousYear(#date(2023, 1, 1))"))
        XCTAssertTrue(try b("Date.IsInNextYear(#date(2025, 6, 1))"))
        // "previous N" excludes the current period
        XCTAssertTrue(try b("Date.IsInPreviousNDays(#date(2024, 8, 12), 3)"))
        XCTAssertFalse(try b("Date.IsInPreviousNDays(#date(2024, 8, 11), 3)"))
        XCTAssertFalse(try b("Date.IsInPreviousNDays(#date(2024, 8, 15), 3)"))
        XCTAssertTrue(try b("Date.IsInNextNMonths(#date(2024, 10, 31), 2)"))
        XCTAssertFalse(try b("Date.IsInNextNMonths(#date(2024, 8, 31), 2)"))
        XCTAssertTrue(try b("Date.IsInYearToDate(#date(2024, 8, 15))"))
        XCTAssertFalse(try b("Date.IsInYearToDate(#date(2024, 8, 16))"))
        XCTAssertFalse(try b("Date.IsInYearToDate(#date(2023, 8, 1))"))
        XCTAssertTrue(try b("DateTime.IsInCurrentHour(#datetime(2024, 8, 15, 10, 59, 59))"))
        XCTAssertTrue(try b("DateTime.IsInPreviousHour(#datetime(2024, 8, 15, 9, 0, 0))"))
    }
    func testDateTimeConversionAndDurations() throws {
        XCTAssertTrue(try mBool("Date.From(\"2024-08-15\") = #date(2024, 8, 15)"))
        XCTAssertTrue(try mBool("Date.From(#datetime(2024, 8, 15, 23, 0, 0)) = #date(2024, 8, 15)"))
        XCTAssertTrue(try mBool("Date.FromText(\"15/08/2024\", \"en-GB\") = #date(2024, 8, 15)"))
        XCTAssertTrue(try mBool("Date.FromText(\"08/15/2024\", \"en-US\") = #date(2024, 8, 15)"))
        XCTAssertTrue(try mBool("Date.FromText(\"20240815\", [Format = \"yyyyMMdd\"]) = #date(2024, 8, 15)"))
        XCTAssertEqual(try mText("Date.ToText(#date(2024, 8, 5), \"yyyy-MM-dd\")"), "2024-08-05")
        XCTAssertEqual(try mText("Date.ToText(#date(2024, 8, 5), [Format = \"dd MMM yyyy\", Culture = \"en-US\"])"), "05 Aug 2024")
        XCTAssertTrue(try mBool("DateTime.From(\"2024-08-15T10:30:00\") = #datetime(2024, 8, 15, 10, 30, 0)"))
        XCTAssertTrue(try mBool("DateTime.Date(#datetime(2024, 8, 15, 10, 30, 0)) = #date(2024, 8, 15)"))
        XCTAssertTrue(try mBool("DateTime.Time(#datetime(2024, 8, 15, 10, 30, 0)) = #time(10, 30, 0)"))
        XCTAssertEqual(try mNums("{Time.Hour(#time(13, 45, 30)), Time.Minute(#time(13, 45, 30)), Time.Second(#time(13, 45, 30))}"), [13, 45, 30])
        XCTAssertTrue(try mBool("Time.StartOfHour(#datetime(2024, 8, 15, 10, 30, 0)) = #datetime(2024, 8, 15, 10, 0, 0)"))
        XCTAssertTrue(try mBool("DateTimeZone.RemoveZone(DateTime.AddZone(#datetime(2024, 1, 1, 12, 0, 0), 2)) = #datetime(2024, 1, 1, 12, 0, 0)"))
        XCTAssertEqual(try mNum("DateTimeZone.ZoneHours(DateTimeZone.SwitchZone(#datetimezone(2024, 1, 1, 12, 0, 0, 2, 0), -5))"), -5)
        XCTAssertTrue(try mBool("DateTimeZone.RemoveZone(DateTimeZone.SwitchZone(#datetimezone(2024, 1, 1, 12, 0, 0, 2, 0), -5)) = #datetime(2024, 1, 1, 5, 0, 0)"))
        let dur = "#duration(2, 5, 30, 15)"
        XCTAssertEqual(try mNums("{Duration.Days(\(dur)), Duration.Hours(\(dur)), Duration.Minutes(\(dur)), Duration.Seconds(\(dur))}"), [2, 5, 30, 15])
        XCTAssertEqual(try mNum("Duration.TotalHours(\(dur))"), 53.5 + 15.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(try mNum("Duration.TotalDays(#date(2024, 3, 1) - #date(2024, 2, 1))"), 29)
        XCTAssertEqual(try mNum("Duration.TotalMinutes(#duration(0, 1, 30, 0))"), 90)
    }
}
