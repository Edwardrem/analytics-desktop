import SwiftUI
import FacetCore
import FacetDesign

/// Composes and decomposes the format strings `ValueFormatter` understands, so the Format menu,
/// decimal-places stepper and thousands toggle all edit one string.
struct FormatComposer: Equatable {
    enum Kind: String, CaseIterable { case general, whole, decimal, currency, percentage, scientific, date, time, custom
        var title: String {
            switch self {
            case .general: return "General"
            case .whole: return "Whole number"
            case .decimal: return "Decimal number"
            case .currency: return "Currency"
            case .percentage: return "Percentage"
            case .scientific: return "Scientific"
            case .date: return "Date"
            case .time: return "Time"
            case .custom: return "Custom"
            }
        }
    }
    var kind: Kind = .general
    var symbol = "$"
    var decimals = 0
    var thousands = false
    /// The literal format for date, time and custom kinds.
    var literal = ""

    static let currencySymbols = ["$", "€", "£", "¥", "₹", "R", "CHF", "kr", "R$", "₩", "₦", "KSh", "A$", "C$"]
    static let dateFormats: [(title: String, format: String)] = [
        ("14 Mar 2026", "Medium Date"), ("3/14/2026", "Short Date"), ("Saturday, March 14, 2026", "Long Date"),
        ("2026-03-14", "yyyy-mm-dd"), ("14/03/2026", "dd/mm/yyyy"), ("03/14/2026", "mm/dd/yyyy"), ("14.03.2026", "dd.mm.yyyy"),
        ("14 March 2026", "d mmmm yyyy"), ("Mar 2026", "mmm yyyy"), ("March 2026", "mmmm yyyy"), ("Mar 14", "mmm d"),
        ("2026", "yyyy"), ("Q1 2026", "\\Qq yyyy"), ("3/14/2026 1:30:00 PM", "General Date"), ("2026-03-14 13:30:00", "yyyy-mm-dd hh:mm:ss"),
    ]
    static let timeFormats: [(title: String, format: String)] = [
        ("13:30", "Short Time"), ("1:30 PM", "Medium Time"), ("1:30:00 PM", "Long Time"), ("13:30:00", "hh:mm:ss"),
    ]

    private var numberBody: String {
        (thousands ? "#,0" : "0") + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "")
    }
    /// The format string for the current settings.
    var formatString: String {
        switch kind {
        case .general: return ""
        case .whole: return thousands ? "#,0" : "0"
        case .decimal: return numberBody
        case .currency: return (symbol.count > 1 ? "\"\(symbol)\" " : symbol) + numberBody
        case .percentage: return (thousands ? "#,0" : "0") + (decimals > 0 ? "." + String(repeating: "0", count: decimals) : "") + "%"
        case .scientific: return "Scientific"
        case .date, .time, .custom: return literal
        }
    }
    var supportsDecimals: Bool { kind == .decimal || kind == .currency || kind == .percentage }
    var supportsThousands: Bool { kind == .whole || kind == .decimal || kind == .currency || kind == .percentage }

    init() {}
    /// Decomposes an existing format string (best effort; anything unrecognised is `custom`).
    init(_ format: String) {
        let f = format.trimmingCharacters(in: .whitespaces)
        let lower = f.lowercased()
        literal = f
        if f.isEmpty || lower == "general" || lower == "general number" { kind = .general; return }
        if lower == "scientific" { kind = .scientific; return }
        if lower == "currency" { kind = .currency; decimals = 2; thousands = true; return }
        if lower == "percent" { kind = .percentage; decimals = 2; return }
        if lower == "standard" { kind = .decimal; decimals = 2; thousands = true; return }
        if lower == "fixed" { kind = .decimal; decimals = 2; return }
        if FormatComposer.dateFormats.contains(where: { $0.format.lowercased() == lower }) { kind = .date; return }
        if FormatComposer.timeFormats.contains(where: { $0.format.lowercased() == lower }) { kind = .time; return }
        // Numeric patterns: optional symbol, #,0 or 0, optional decimals, optional %.
        var body = f
        var sym: String?
        if body.hasPrefix("\""), let end = body.dropFirst().firstIndex(of: "\"") {
            sym = String(body[body.index(after: body.startIndex)..<end])
            body = String(body[body.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        } else if let s = FormatComposer.currencySymbols.filter({ $0.count == 1 }).first(where: { body.hasPrefix($0) }) {
            sym = s; body.removeFirst(s.count)
        }
        let percent = body.hasSuffix("%")
        if percent { body.removeLast() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let intPart = parts.first ?? ""
        let fracPart = parts.count > 1 ? parts[1] : ""
        let validInt = intPart == "0" || intPart == "#,0" || intPart == "#,##0"
        let validFrac = parts.count <= 2 && fracPart.allSatisfy { $0 == "0" }
        guard validInt, validFrac else {
            let isDate = lower.contains("yy") || lower.contains("mm") || lower.contains("dd")
            kind = isDate ? .date : (lower.contains("hh") ? .time : .custom)
            return
        }
        thousands = intPart != "0"
        decimals = fracPart.count
        if let sym { kind = .currency; symbol = sym }
        else if percent { kind = .percentage }
        else { kind = decimals == 0 ? .whole : .decimal }
    }
}

/// Format preset menu + decimal places + thousands separator, editing a single format string.
struct FormatControls: View {
    /// Current format; nil shows a mixed state (multi-select with different formats).
    let format: String?
    var dataType: DataType = .any
    var compact = true
    let apply: (String) -> Void
    @State private var customText = ""
    @State private var showingCustom = false

    private var composer: FormatComposer { FormatComposer(format ?? "") }
    private var sample: Value {
        dataType.isTemporal ? .date(Date(timeIntervalSince1970: 1_773_495_000)) : .double(12345.678)
    }

    var body: some View {
        HStack(spacing: Design.Space.s) {
            Menu {
                let c = composer
                Button("General") { apply("") }
                Divider()
                Button("Whole number") { set { $0.kind = .whole; $0.decimals = 0 } }
                Button("Decimal number") { set { $0.kind = .decimal; $0.decimals = max(2, c.decimals) } }
                Menu("Currency") {
                    ForEach(FormatComposer.currencySymbols, id: \.self) { s in
                        Button(s) { set { $0.kind = .currency; $0.symbol = s; $0.thousands = true; $0.decimals = c.kind == .currency ? c.decimals : 2 } }
                    }
                }
                Button("Percentage") { set { $0.kind = .percentage; $0.decimals = c.kind == .percentage ? c.decimals : 1 } }
                Button("Scientific") { apply("Scientific") }
                Divider()
                Menu("Date") {
                    ForEach(FormatComposer.dateFormats, id: \.format) { f in Button(f.title) { apply(f.format) } }
                }
                Menu("Time") {
                    ForEach(FormatComposer.timeFormats, id: \.format) { f in Button(f.title) { apply(f.format) } }
                }
                Divider()
                Button("Custom…") { customText = format ?? ""; showingCustom = true }
            } label: {
                Text(title).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Format")
            .popover(isPresented: $showingCustom, arrowEdge: .bottom) { customEditor }

            if format != nil, composer.supportsDecimals || composer.kind == .whole {
                Stepper(value: Binding(get: { composer.decimals }, set: { v in
                    set { $0.decimals = max(0, min(10, v)); if $0.kind == .whole, v > 0 { $0.kind = .decimal } else if $0.kind == .decimal, v == 0 { $0.kind = .whole } }
                }), in: 0...10) {
                    Text("\(composer.decimals)").font(Design.Typeface.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .help("Decimal places")
                .accessibilityLabel("Decimal places")
            }
            if format != nil, composer.supportsThousands {
                Toggle(isOn: Binding(get: { composer.thousands }, set: { v in set { $0.thousands = v } })) {
                    Image(systemName: "textformat.123")
                }
                .toggleStyle(.button)
                .help("Thousands separator")
                .accessibilityLabel("Thousands separator")
            }
        }
        .controlSize(.small)
    }

    private var title: String {
        guard let format else { return "Mixed" }
        let c = composer
        switch c.kind {
        case .currency: return "Currency (\(c.symbol))"
        case .date: return FormatComposer.dateFormats.first { $0.format.lowercased() == format.lowercased() }?.title ?? format
        case .time: return FormatComposer.timeFormats.first { $0.format.lowercased() == format.lowercased() }?.title ?? format
        case .custom: return format
        default: return c.kind.title
        }
    }

    private func set(_ change: (inout FormatComposer) -> Void) {
        var c = composer
        change(&c)
        apply(c.formatString)
    }

    private var customEditor: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            SectionLabel("Custom format")
            TextField("#,0.00", text: $customText)
                .textFieldStyle(.roundedBorder)
                .font(Design.Typeface.mono)
                .frame(width: 220)
                .onSubmit { apply(customText); showingCustom = false }
            Text(customText.isEmpty ? " " : ValueFormatter.format(sample, customText))
                .font(Design.Typeface.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Apply") { apply(customText); showingCustom = false }.keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.small)
        .padding(Design.Space.m)
    }
}
