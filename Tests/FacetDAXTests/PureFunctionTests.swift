import XCTest
import FacetCore
@testable import FacetDAX

final class PureFunctionTests: XCTestCase {
    private func call(_ name: String, _ args: Value...) throws -> Value {
        let all = [PureMath.functions, PureText.functions, PureDate.functions, PureFinancial.functions]
        guard let fn = all.compactMap({ $0[name] }).first else {
            XCTFail("\(name) is not registered"); return .null
        }
        return try fn(args)
    }
    private func num(_ name: String, _ args: Value...) throws -> Double {
        let all = [PureMath.functions, PureText.functions, PureDate.functions, PureFinancial.functions]
        guard let fn = all.compactMap({ $0[name] }).first else { XCTFail("\(name) is not registered"); return .nan }
        return try fn(args).asDouble ?? .nan
    }
    private func date(_ s: String) -> Value { .date(DateParsing.parse(s)!) }

    func testNoDuplicateRegistrations() {
        let sets = [PureMath.functions, PureText.functions, PureDate.functions, PureFinancial.functions].map { Set($0.keys) }
        for i in 0..<sets.count { for j in (i + 1)..<sets.count { XCTAssertTrue(sets[i].isDisjoint(with: sets[j])) } }
        for s in sets { for k in s { XCTAssertEqual(k, k.uppercased()) } }
    }

    func testRounding() throws {
        XCTAssertEqual(try num("ROUND", 2.675, 2), 2.68, accuracy: 1e-12)
        XCTAssertEqual(try num("ROUND", -2.5, 0), -3)
        XCTAssertEqual(try num("ROUND", 1234.5, -2), 1200)
        XCTAssertEqual(try num("ROUNDUP", 3.001, 0), 4)
        XCTAssertEqual(try num("ROUNDUP", 3.0, 0), 3)
        XCTAssertEqual(try num("ROUNDDOWN", 4.35, 2), 4.35, accuracy: 1e-12)
        XCTAssertEqual(try num("ROUNDDOWN", -3.99, 0), -3)
        XCTAssertEqual(try num("MROUND", 10, 3), 9)
        XCTAssertEqual(try num("MROUND", 1.3, 0.2), 1.4, accuracy: 1e-9)
        XCTAssertThrowsError(try call("MROUND", 5, -2))
        XCTAssertEqual(try call("INT", -3.2), .int(-4))
        XCTAssertEqual(try call("TRUNC", -3.7), .int(-3))
        XCTAssertEqual(try num("TRUNC", 3.14159, 2), 3.14, accuracy: 1e-12)
        XCTAssertEqual(try num("CEILING", 4.42, 0.05), 4.45, accuracy: 1e-9)
        XCTAssertEqual(try num("FLOOR", 4.42, 0.05), 4.40, accuracy: 1e-9)
        XCTAssertEqual(try num("FLOOR", 0.3, 0.1), 0.3, accuracy: 1e-9)
        XCTAssertEqual(try num("ISO.CEILING", 4.3), 5)
        XCTAssertEqual(try num("ISO.CEILING", -4.3), -4)
        XCTAssertTrue(try call("ROUND", .null, 0).isNull)
        XCTAssertTrue(try call("ABS", .null).isNull)
    }

    func testArithmeticHelpers() throws {
        XCTAssertEqual(try call("ABS", -5), .int(5))
        XCTAssertEqual(try call("MOD", 7, 3), .int(1))
        XCTAssertEqual(try call("MOD", -7, 3), .int(2))
        XCTAssertEqual(try num("MOD", 5.5, 2), 1.5)
        XCTAssertThrowsError(try call("MOD", 1, 0))
        XCTAssertEqual(try call("QUOTIENT", 7, 2), .int(3))
        XCTAssertEqual(try call("QUOTIENT", -7, 2), .int(-3))
        XCTAssertEqual(try num("DIVIDE", 10, 4), 2.5)
        XCTAssertTrue(try call("DIVIDE", 10, 0).isNull)
        XCTAssertEqual(try call("DIVIDE", 10, 0, -1), .int(-1))
        XCTAssertTrue(try call("DIVIDE", 10, .null).isNull)
        XCTAssertTrue(try call("DIVIDE", .null, 5).isNull)
        XCTAssertEqual(try call("POWER", 2, 10), .int(1024))
        XCTAssertEqual(try num("SQRT", 16), 4)
        XCTAssertThrowsError(try call("SQRT", -1))
        XCTAssertEqual(try num("EXP", 0), 1)
        XCTAssertEqual(try num("LN", .double(M_E)), 1, accuracy: 1e-12)
        XCTAssertEqual(try num("LOG", 8, 2), 3, accuracy: 1e-12)
        XCTAssertEqual(try num("LOG", 1000), 3, accuracy: 1e-12)
        XCTAssertEqual(try num("LOG10", 100), 2, accuracy: 1e-12)
        XCTAssertEqual(try call("SIGN", -2.5), .int(-1))
        XCTAssertEqual(try num("PI"), Double.pi)
        XCTAssertEqual(try call("FACT", 5), .int(120))
        XCTAssertEqual(try call("GCD", 12, 18), .int(6))
        XCTAssertEqual(try call("LCM", 4, 6), .int(12))
        XCTAssertEqual(try call("EVEN", 1.5), .int(2))
        XCTAssertEqual(try call("EVEN", -1), .int(-2))
        XCTAssertEqual(try call("ODD", 2), .int(3))
        XCTAssertEqual(try call("ODD", 3), .int(3))
        XCTAssertEqual(try call("ISEVEN", 4), .bool(true))
        XCTAssertEqual(try call("ISODD", 4), .bool(false))
        XCTAssertEqual(try call("COMBIN", 5, 2), .int(10))
        XCTAssertEqual(try call("PERMUT", 5, 2), .int(20))
        XCTAssertEqual(try num("CURRENCY", 1.23456), 1.2346, accuracy: 1e-12)
        let r = try num("RAND")
        XCTAssertTrue(r >= 0 && r < 1)
        let rb = try num("RANDBETWEEN", 3, 5)
        XCTAssertTrue(rb >= 3 && rb <= 5)
    }

    func testTrigAndLogical() throws {
        XCTAssertEqual(try num("SIN", Value.double(.pi / 2)), 1, accuracy: 1e-12)
        XCTAssertEqual(try num("COS", 0), 1)
        XCTAssertEqual(try num("ATAN", 1), .pi / 4, accuracy: 1e-12)
        XCTAssertEqual(try num("DEGREES", Value.double(.pi)), 180, accuracy: 1e-9)
        XCTAssertEqual(try num("RADIANS", 180), .pi, accuracy: 1e-12)
        XCTAssertThrowsError(try call("ASIN", 2))
        XCTAssertEqual(try call("AND", true, false), .bool(false))
        XCTAssertEqual(try call("OR", true, false), .bool(true))
        XCTAssertEqual(try call("NOT", .null), .bool(true))
        XCTAssertEqual(try call("ISBLANK", .null), .bool(true))
        XCTAssertEqual(try call("ISNUMBER", 1.5), .bool(true))
        XCTAssertEqual(try call("ISTEXT", "a"), .bool(true))
        XCTAssertEqual(try call("ISNONTEXT", 1), .bool(true))
        XCTAssertEqual(try call("ISLOGICAL", true), .bool(true))
        XCTAssertTrue(try call("BLANK").isNull)
    }

    func testText() throws {
        XCTAssertEqual(try call("CONCATENATE", "a", 1), "a1")
        XCTAssertEqual(try call("LEFT", "Facet", 2), "Fa")
        XCTAssertEqual(try call("LEFT", "Facet"), "F")
        XCTAssertEqual(try call("RIGHT", "Facet", 3), "cet")
        XCTAssertEqual(try call("MID", "Facet", 2, 3), "ace")
        XCTAssertEqual(try call("MID", "Facet", 10, 3), "")
        XCTAssertEqual(try call("LEN", "héllo"), .int(5))
        XCTAssertEqual(try call("LEN", .null), .int(0))
        XCTAssertEqual(try call("UPPER", "abc"), "ABC")
        XCTAssertEqual(try call("LOWER", "ABC"), "abc")
        XCTAssertEqual(try call("TRIM", "  a   b  "), "a b")
        XCTAssertEqual(try call("SUBSTITUTE", "a-b-c", "-", "+"), "a+b+c")
        XCTAssertEqual(try call("SUBSTITUTE", "a-b-c", "-", "+", 2), "a-b+c")
        XCTAssertEqual(try call("REPLACE", "abcdef", 2, 3, "X"), "aXef")
        XCTAssertEqual(try call("SEARCH", "C", "abcabc"), .int(3))
        XCTAssertEqual(try call("SEARCH", "c", "abcabc", 4), .int(6))
        XCTAssertEqual(try call("SEARCH", "b?a", "abcabc"), .int(2))
        XCTAssertEqual(try call("SEARCH", "z", "abc", 1, -1), .int(-1))
        XCTAssertThrowsError(try call("SEARCH", "z", "abc"))
        XCTAssertEqual(try call("FIND", "B", "abcABC"), .int(5))
        XCTAssertTrue(try call("FIND", "z", "abc", 1, .null).isNull)
        XCTAssertEqual(try call("FORMAT", 1234.5, "#,0.00"), "1,234.50")
        XCTAssertEqual(try call("FORMAT", 0.256, "0.0%"), "25.6%")
        XCTAssertEqual(try call("FORMAT", date("2026-03-09"), "yyyy-mm-dd"), "2026-03-09")
        XCTAssertEqual(try call("FORMAT", "hello", "0.00"), "hello")
        XCTAssertEqual(try call("FORMAT", .null, "0"), "")
        XCTAssertEqual(try call("VALUE", "42"), .int(42))
        XCTAssertEqual(try num("VALUE", "1,234.5"), 1234.5)
        XCTAssertThrowsError(try call("VALUE", "abc"))
        XCTAssertEqual(try call("FIXED", 1234.567, 2), "1,234.57")
        XCTAssertEqual(try call("FIXED", 1234.567, 1, true), "1234.6")
        XCTAssertEqual(try call("REPT", "ab", 3), "ababab")
        XCTAssertEqual(try call("EXACT", "a", "A"), .bool(false))
        XCTAssertEqual(try call("UNICHAR", 65), "A")
        XCTAssertEqual(try call("UNICODE", "A"), .int(65))
        XCTAssertEqual(try call("COMBINEVALUES", "|", "a", 1, "b"), "a|1|b")
        XCTAssertEqual(try call("CONTAINSSTRING", "Mountain Bike", "BIKE"), .bool(true))
        XCTAssertEqual(try call("CONTAINSSTRING", "Mountain Bike", "m*bike"), .bool(true))
        XCTAssertEqual(try call("CONTAINSSTRING", "Mountain Bike", "road"), .bool(false))
        XCTAssertEqual(try call("CONTAINSSTRINGEXACT", "Mountain Bike", "bike"), .bool(false))
        XCTAssertEqual(try call("CONTAINSSTRINGEXACT", "Mountain Bike", "Bike"), .bool(true))
    }

    func testDates() throws {
        XCTAssertEqual(try call("DATE", 2024, 2, 29), date("2024-02-29"))
        XCTAssertEqual(try call("DATE", 2024, 14, 1), date("2025-02-01"))
        XCTAssertEqual(try call("DATE", 2024, 1, 0), date("2023-12-31"))
        XCTAssertEqual(try call("DATE", 99, 1, 1), date("1999-01-01"))
        XCTAssertEqual(try call("YEAR", date("2024-07-15")), .int(2024))
        XCTAssertEqual(try call("MONTH", date("2024-07-15")), .int(7))
        XCTAssertEqual(try call("DAY", date("2024-07-15")), .int(15))
        XCTAssertEqual(try call("QUARTER", date("2024-07-15")), .int(3))
        let dt = date("2024-07-15 13:45:30")
        XCTAssertEqual(try call("HOUR", dt), .int(13))
        XCTAssertEqual(try call("MINUTE", dt), .int(45))
        XCTAssertEqual(try call("SECOND", dt), .int(30))
        XCTAssertEqual(try num("TIME", 12, 0, 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(try call("HOUR", call("TIME", 18, 30, 0)), .int(18))
        XCTAssertEqual(try call("DATEVALUE", "2024-07-15 13:45:30"), date("2024-07-15"))
        XCTAssertEqual(try num("TIMEVALUE", "2024-07-15 06:00:00"), 0.25, accuracy: 1e-9)
        // 2024-07-15 is a Monday.
        XCTAssertEqual(try call("WEEKDAY", date("2024-07-15")), .int(2))
        XCTAssertEqual(try call("WEEKDAY", date("2024-07-15"), 2), .int(1))
        XCTAssertEqual(try call("WEEKDAY", date("2024-07-14"), 3), .int(6))
        XCTAssertEqual(try call("WEEKNUM", date("2024-01-01")), .int(1))
        XCTAssertEqual(try call("WEEKNUM", date("2024-01-07")), .int(2))
        XCTAssertEqual(try call("WEEKNUM", date("2024-01-07"), 2), .int(1))
        XCTAssertEqual(try call("WEEKNUM", date("2021-01-03"), 21), .int(53))
        XCTAssertEqual(try call("EOMONTH", date("2024-01-15"), 1), date("2024-02-29"))
        XCTAssertEqual(try call("EOMONTH", date("2024-01-15"), -1), date("2023-12-31"))
        XCTAssertEqual(try call("EDATE", date("2024-01-31"), 1), date("2024-02-29"))
        XCTAssertEqual(try call("EDATE", date("2024-03-15"), -12), date("2023-03-15"))
        XCTAssertEqual(try call("DATEDIFF", date("2023-12-31"), date("2024-01-01"), "DAY"), .int(1))
        XCTAssertEqual(try call("DATEDIFF", date("2023-12-31"), date("2024-01-01"), "MONTH"), .int(1))
        XCTAssertEqual(try call("DATEDIFF", date("2023-12-31"), date("2024-01-01"), "YEAR"), .int(1))
        XCTAssertEqual(try call("DATEDIFF", date("2024-01-01"), date("2024-12-31"), "QUARTER"), .int(3))
        XCTAssertEqual(try call("DATEDIFF", date("2021-01-01"), date("2021-01-04"), "WEEK"), .int(1))
        XCTAssertEqual(try call("DATEDIFF", date("2024-01-01 10:59:00"), date("2024-01-01 12:01:00"), "HOUR"), .int(2))
        XCTAssertEqual(try call("DATEDIFF", date("2024-03-01"), date("2024-01-01"), "MONTH"), .int(-2))
        XCTAssertThrowsError(try call("DATEDIFF", date("2024-03-01"), date("2024-01-01"), "FORTNIGHT"))
        XCTAssertEqual(try num("YEARFRAC", date("2024-01-01"), date("2024-07-01")), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try num("YEARFRAC", date("2023-01-01"), date("2023-07-02"), 3), 182.0 / 365, accuracy: 1e-12)
        XCTAssertEqual(try num("YEARFRAC", date("2023-01-01"), date("2023-07-02"), 2), 182.0 / 360, accuracy: 1e-12)
        XCTAssertEqual(try num("YEARFRAC", date("2024-01-01"), date("2024-12-31"), 1), 365.0 / 366, accuracy: 1e-12)
        // Mon 2024-07-15 … Sun 2024-07-28: 10 working days.
        XCTAssertEqual(try call("NETWORKDAYS", date("2024-07-15"), date("2024-07-28")), .int(10))
        XCTAssertEqual(try call("NETWORKDAYS", date("2024-07-15"), date("2024-07-21"), 11), .int(6))
        XCTAssertEqual(try call("NETWORKDAYS", date("2024-07-19"), date("2024-07-15")), .int(-5))
    }

    func testPinnedClock() throws {
        let saved = PureDate.now
        defer { PureDate.now = saved }
        PureDate.now = { DateParsing.parse("2025-05-06 07:08:09")! }
        XCTAssertEqual(try call("TODAY"), date("2025-05-06"))
        XCTAssertEqual(try call("UTCTODAY"), date("2025-05-06"))
        XCTAssertEqual(try call("NOW"), date("2025-05-06 07:08:09"))
        XCTAssertEqual(try call("UTCNOW"), date("2025-05-06 07:08:09"))
    }

    func testFinancial() throws {
        XCTAssertEqual(try num("PMT", .double(0.08 / 12), 10, 10000), -1037.03, accuracy: 0.01)
        XCTAssertEqual(try num("PMT", 0, 10, 1000), -100, accuracy: 1e-9)
        XCTAssertEqual(try num("PV", .double(0.08 / 12), 240, -500), 59777.15, accuracy: 0.01)
        XCTAssertEqual(try num("FV", .double(0.06 / 12), 10, -200, -500, 1), 2581.40, accuracy: 0.01)
        XCTAssertEqual(try num("NPER", .double(0.12 / 12), -100, -1000, 10000, 1), 59.67, accuracy: 0.01)
        XCTAssertEqual(try num("RATE", 48, -200, 8000), 0.0077, accuracy: 0.0001)
        XCTAssertEqual(try num("IPMT", .double(0.1 / 12), 1, 36, 8000), -66.67, accuracy: 0.01)
        XCTAssertEqual(try num("PPMT", .double(0.1 / 12), 1, 24, 2000), -75.62, accuracy: 0.01)
        XCTAssertEqual(try num("SLN", 30000, 7500, 10), 2250)
        XCTAssertEqual(try num("DB", 1_000_000, 100_000, 6, 1, 7), 186_083.33, accuracy: 0.01)
        XCTAssertEqual(try num("DB", 1_000_000, 100_000, 6, 2, 7), 259_639.42, accuracy: 0.01)
        XCTAssertEqual(try num("DDB", 2400, 300, 10, 1), 480, accuracy: 1e-9)
        XCTAssertEqual(try num("DDB", 2400, 300, 10, 10), 22.12, accuracy: 0.01)
        XCTAssertEqual(try num("EFFECT", 0.0525, 4), 0.053543, accuracy: 1e-6)
        XCTAssertEqual(try num("NOMINAL", 0.053543, 4), 0.0525, accuracy: 1e-5)
        XCTAssertEqual(try num("SYD", 30000, 7500, 10, 1), 4090.91, accuracy: 0.01)
        XCTAssertEqual(try num("CUMIPMT", .double(0.09 / 12), 360, 125000, 13, 24, 0), -11135.23, accuracy: 0.01)
        XCTAssertEqual(try num("CUMPRINC", .double(0.09 / 12), 360, 125000, 13, 24, 0), -934.11, accuracy: 0.01)
        XCTAssertEqual(try num("RRI", 96, 10000, 11000), 0.0009933, accuracy: 1e-6)
        XCTAssertEqual(try num("DOLLARDE", 1.02, 16), 1.125, accuracy: 1e-9)
        XCTAssertEqual(try num("DOLLARFR", 1.125, 16), 1.02, accuracy: 1e-9)

        let values: [Double] = [-10000, 2750, 4250, 3250, 2750]
        let dates = ["2008-01-01", "2008-03-01", "2008-10-30", "2009-02-15", "2009-04-01"].map { DateParsing.parse($0)! }
        XCTAssertEqual(PureFinancial.xnpv(rate: 0.09, values: values, dates: dates), 2086.65, accuracy: 0.01)
        XCTAssertEqual(try PureFinancial.xirr(values: values, dates: dates, guess: 0.1), 0.373362535, accuracy: 1e-6)
        XCTAssertThrowsError(try PureFinancial.xirr(values: [1, 2], dates: Array(dates.prefix(2)), guess: 0.1))
    }
}
