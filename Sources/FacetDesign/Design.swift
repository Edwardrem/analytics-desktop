import SwiftUI
import FacetCore

/// Facet's design system.
///
/// Principles (after Dieter Rams and Jony Ive): the content is the interface; chrome recedes.
/// One accent colour. One type family at a few deliberate sizes. A 4-point spacing grid.
/// Materials and hairlines instead of boxes and borders. Nothing decorative that isn't also useful.
public enum Design {
    // MARK: Spacing (4-pt grid)
    public enum Space {
        public static let xxs: CGFloat = 2
        public static let xs: CGFloat = 4
        public static let s: CGFloat = 8
        public static let m: CGFloat = 12
        public static let l: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }
    // MARK: Radii
    public enum Radius {
        public static let control: CGFloat = 6
        public static let card: CGFloat = 10
        public static let panel: CGFloat = 14
    }
    // MARK: Type
    public enum Typeface {
        public static let caption = Font.system(size: 11)
        public static let captionStrong = Font.system(size: 11, weight: .semibold)
        public static let body = Font.system(size: 13)
        public static let bodyStrong = Font.system(size: 13, weight: .medium)
        public static let headline = Font.system(size: 15, weight: .semibold)
        public static let title = Font.system(size: 20, weight: .semibold)
        public static let display = Font.system(size: 28, weight: .semibold)
        public static let mono = Font.system(size: 12, design: .monospaced)
        /// Small-caps section label used above groups of controls.
        public static let section = Font.system(size: 10, weight: .semibold)
    }
    // MARK: Colour
    public enum Palette {
        public static let accent = Color.accentColor
        public static let hairline = Color.primary.opacity(0.08)
        public static let hairlineStrong = Color.primary.opacity(0.14)
        public static let fill = Color.primary.opacity(0.05)
        public static let fillStrong = Color.primary.opacity(0.09)
        public static let canvas = Color(nsColor: .underPageBackgroundColor)
        public static let surface = Color(nsColor: .windowBackgroundColor)
        public static let elevated = Color(nsColor: .controlBackgroundColor)
        public static let secondaryText = Color.secondary
        public static let tertiaryText = Color.primary.opacity(0.35)
        public static let positive = Color(hex: "#34C759")
        public static let caution = Color(hex: "#FF9F0A")
        public static let negative = Color(hex: "#FF453A")
    }
    // MARK: Motion
    public enum Motion {
        public static let quick = Animation.easeOut(duration: 0.16)
        public static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)
        public static let gentle = Animation.spring(response: 0.5, dampingFraction: 0.9)
    }
}

public extension Color {
    /// "#RGB", "#RRGGBB" or "#RRGGBBAA". Falls back to clear on malformed input.
    init(hex: String) {
        if let c = HexColor.rgb(hex) { self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
        else { self = .clear }
    }
    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return HexColor.hex(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
    }
}

public extension ThemeSpec {
    func dataColor(_ i: Int) -> Color {
        dataColors.isEmpty ? .accentColor : Color(hex: dataColors[((i % dataColors.count) + dataColors.count) % dataColors.count])
    }
    var foregroundColor: Color { Color(hex: foreground) }
    var secondaryColor: Color { Color(hex: secondaryForeground) }
    var backgroundColor: Color { Color(hex: background) }
    var cardColor: Color { Color(hex: cardBackground) }
    var gridlineColor: Color { Color(hex: gridline) }
    var accentColor: Color { Color(hex: accent) }
}

public extension TextStyle {
    var font: Font {
        let w: Font.Weight
        switch weight { case "bold": w = .bold; case "semibold": w = .semibold; case "medium": w = .medium; case "light": w = .light; default: w = .regular }
        return fontFamily.isEmpty ? .system(size: size, weight: w) : .custom(fontFamily, size: size).weight(w)
    }
}

// MARK: - Components

/// Uppercase, letter-spaced label that introduces a group of controls.
public struct SectionLabel: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased())
            .font(Design.Typeface.section)
            .kerning(0.6)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A single-pixel separator that respects display scale.
public struct Hairline: View {
    let vertical: Bool
    public init(vertical: Bool = false) { self.vertical = vertical }
    public var body: some View {
        Rectangle().fill(Design.Palette.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// Collapsible inspector section with a quiet header.
public struct InspectorSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    let content: Content
    public init(_ title: String, expanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title; self._expanded = State(initialValue: expanded); self.content = content()
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(Design.Motion.quick) { expanded.toggle() } } label: {
                HStack(spacing: Design.Space.xs) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(title).font(Design.Typeface.bodyStrong)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, Design.Space.s)
            }
            .buttonStyle(.plain)
            if expanded {
                VStack(alignment: .leading, spacing: Design.Space.s) { content }
                    .padding(.leading, 14)
                    .padding(.bottom, Design.Space.m)
            }
            Hairline()
        }
        .padding(.horizontal, Design.Space.m)
    }
}

/// Label on the left, control on the right — the basic row of every inspector.
public struct PropertyRow<Content: View>: View {
    let label: String
    let content: Content
    public init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
            Text(label).font(Design.Typeface.caption).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Borderless icon button with a soft hover state.
public struct IconButton: View {
    let systemName: String
    let help: String
    var isOn: Bool
    let action: () -> Void
    @State private var hovering = false
    public init(_ systemName: String, help: String, isOn: Bool = false, action: @escaping () -> Void) {
        self.systemName = systemName; self.help = help; self.isOn = isOn; self.action = action
    }
    public var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(isOn ? Color.accentColor : .primary.opacity(0.8))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(isOn ? Color.accentColor.opacity(0.14) : (hovering ? Design.Palette.fillStrong : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Quiet, pill-shaped chip for fields and tags.
public struct Chip: View {
    let text: String
    var systemImage: String?
    var tint: Color
    public init(_ text: String, systemImage: String? = nil, tint: Color = .primary) {
        self.text = text; self.systemImage = systemImage; self.tint = tint
    }
    public var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .medium)) }
            Text(text).font(Design.Typeface.caption).lineLimit(1)
        }
        .foregroundStyle(tint.opacity(0.85))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.08)))
    }
}

/// Centered placeholder for empty panes and visuals.
public struct EmptyState: View {
    let systemImage: String
    let title: String
    let message: String
    public init(systemImage: String, title: String, message: String = "") {
        self.systemImage = systemImage; self.title = title; self.message = message
    }
    public var body: some View {
        VStack(spacing: Design.Space.s) {
            Image(systemName: systemImage).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary)
            Text(title).font(Design.Typeface.bodyStrong).foregroundStyle(.secondary)
            if !message.isEmpty {
                Text(message).font(Design.Typeface.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center).frame(maxWidth: 260)
            }
        }
        .padding(Design.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

public extension View {
    /// Elevated surface: continuous corners, hairline edge, the faintest shadow.
    func facetCard(radius: CGFloat = Design.Radius.card) -> some View {
        self.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Design.Palette.elevated))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Design.Palette.hairline))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }
}
