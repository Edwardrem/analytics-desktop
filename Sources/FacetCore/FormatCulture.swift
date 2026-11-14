import Foundation

/// The culture values are formatted in: a model's language (its `culture`, such as "de-DE"). It gives the
/// decimal and thousands separators that "0.00" and "#,0" stand for, the currency of the "Currency"
/// format, month and day names, and the patterns of the named date formats ("Short Date", "Long Date"…).
/// en-US keeps Power BI's own US patterns; other cultures take their patterns from macOS (CLDR), which can
/// differ in small ways from Windows'.
public struct FormatCulture: Sendable, Equatable {
    public let identifier: String
    public let decimalSeparator: String
    public let groupSeparator: String
    let locale: Locale

    public static let enUS = FormatCulture(identifier: "en-US")

    public init(identifier: String) {
        let id = identifier.trimmingCharacters(in: .whitespaces)
        self.identifier = id.isEmpty ? "en-US" : id
        locale = Locale(identifier: self.identifier.replacingOccurrences(of: "-", with: "_"))
        decimalSeparator = locale.decimalSeparator ?? "."
        groupSeparator = locale.groupingSeparator ?? ","
    }

    /// Whether this is en-US, whose formats are Power BI's built-in ones.
    public var isUS: Bool { identifier.caseInsensitiveCompare("en-US") == .orderedSame }

    /// An en-US numeric body ("-1,234.5") with this culture's separators ("-1.234,5" in de-DE).
    public func localize(_ body: String) -> String {
        guard decimalSeparator != "." || groupSeparator != "," else { return body }
        var out = ""
        for ch in body {
            switch ch {
            case ",": out += groupSeparator
            case ".": out += decimalSeparator
            default: out.append(ch)
            }
        }
        return out
    }

    /// The "Currency" format: two decimals with the culture's currency symbol and placement.
    func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .currency
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: value)) ?? localize(String(format: "%.2f", value))
    }

    /// A date pattern for a template ("ddMMyyyy", "EEEEdMMMMyyyy", "jjmmss"…) in this culture.
    func datePattern(_ template: String) -> String {
        DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: locale) ?? template
    }
}
