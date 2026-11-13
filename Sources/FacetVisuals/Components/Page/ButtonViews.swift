import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// MARK: - State-based look

enum CmpButtonState: String, CaseIterable {
    case normal, hover, pressed, selected, disabled
    /// Format key for a per-state colour: "color", "hoverColor", "pressedColor", "selectedColor", "disabledColor".
    var colorKey: String { self == .normal ? "color" : rawValue + "Color" }
}

struct CmpButtonLook {
    var fill: Color
    var outline: Color
    var outlineWidth: CGFloat
    var text: Color
    var icon: Color
}

/// Resolves fill / outline / text / icon colours for each button state: explicit per-state format keys
/// first, then the state-less key, then the defaults of the chosen `button.style`.
struct CmpButtonResolver {
    let env: CmpEnv
    /// "tinted" | "filled" | "outline" | "plain" | "soft"
    let style: String

    init(env: CmpEnv, defaultStyle: String) {
        self.env = env
        self.style = env.f.string("button", "style", defaultStyle)
    }

    static func state(hover: Bool, pressed: Bool, selected: Bool, enabled: Bool) -> CmpButtonState {
        if !enabled { return .disabled }
        if pressed { return .pressed }
        if selected { return .selected }
        return hover ? .hover : .normal
    }

    func look(_ state: CmpButtonState) -> CmpButtonLook {
        let f = env.f, theme = env.theme
        let accent = theme.accentColor, fg = theme.foregroundColor
        let onAccent = Color(hex: CmpColor.readableText(on: theme.accent))
        var fill: Color = .clear, outline: Color = .clear, text: Color = fg
        switch style {
        case "filled":
            text = onAccent
            switch state {
            case .normal: fill = accent
            case .hover: fill = accent.opacity(0.86)
            case .pressed: fill = accent.opacity(0.72)
            case .selected: fill = accent; outline = fg.opacity(0.55)
            case .disabled: fill = fg.opacity(0.08); text = fg.opacity(0.35)
            }
        case "outline":
            outline = theme.isHighContrast ? fg : fg.opacity(0.22)
            switch state {
            case .normal: break
            case .hover: fill = fg.opacity(0.05)
            case .pressed: fill = fg.opacity(0.11)
            case .selected: fill = accent.opacity(0.14); outline = accent; text = theme.isHighContrast ? fg : accent
            case .disabled: outline = fg.opacity(0.1); text = fg.opacity(0.35)
            }
        case "plain":
            switch state {
            case .normal: break
            case .hover: fill = fg.opacity(0.06)
            case .pressed: fill = fg.opacity(0.12)
            case .selected: fill = accent.opacity(0.14); text = theme.isHighContrast ? fg : accent
            case .disabled: text = fg.opacity(0.35)
            }
        case "soft":
            switch state {
            case .normal: fill = fg.opacity(theme.isDark ? 0.09 : 0.055)
            case .hover: fill = fg.opacity(theme.isDark ? 0.14 : 0.09)
            case .pressed: fill = fg.opacity(theme.isDark ? 0.2 : 0.14)
            case .selected: fill = accent; text = onAccent
            case .disabled: fill = fg.opacity(0.04); text = fg.opacity(0.35)
            }
            if theme.isHighContrast, state != .selected { outline = fg }
        default: // tinted
            text = theme.isHighContrast ? fg : accent
            switch state {
            case .normal: fill = accent.opacity(0.12)
            case .hover: fill = accent.opacity(0.2)
            case .pressed: fill = accent.opacity(0.3)
            case .selected: fill = accent; text = onAccent
            case .disabled: fill = fg.opacity(0.06); text = fg.opacity(0.35)
            }
            if theme.isHighContrast, state != .selected { outline = fg }
        }
        func custom(_ card: String) -> Color? {
            (f.value(card, state.colorKey) ?? f.value(card, "color"))?.stringValue.map { Color(hex: $0) }
        }
        let dim = state == .disabled ? 0.45 : 1.0
        if f.value("fill", "show")?.boolValue == false { fill = .clear }
        else if let c = custom("fill") { fill = c.opacity((1 - f.double("fill", "transparency", 0) / 100) * dim) }
        if f.value("outline", "show")?.boolValue == false { outline = .clear }
        else if let c = custom("outline"), f.bool("outline", "show", true) { outline = c.opacity(dim) }
        if let c = custom("text") { text = c.opacity(dim) }
        let icon = custom("icon")?.opacity(dim) ?? text
        let width = CGFloat(f.double("outline", "width", state == .selected && style == "filled" ? 2 : 1))
        return CmpButtonLook(fill: fill, outline: outline, outlineWidth: width, text: text, icon: icon)
    }
}

/// Built-in button icon kinds (`format["button"]["icon"]`) → SF Symbols. Unknown names are used as SF Symbol names.
enum CmpButtonIcon {
    static let kinds = ["blank", "leftArrow", "rightArrow", "reset", "back", "information", "help", "qna", "bookmark", "navigation", "custom"]
    static func symbol(_ kind: String) -> String? {
        switch kind {
        case "", "blank", "custom": return nil
        case "leftArrow": return "arrow.left"
        case "rightArrow": return "arrow.right"
        case "reset": return "arrow.counterclockwise"
        case "back": return "arrow.backward.circle"
        case "information": return "info.circle"
        case "help": return "questionmark.circle"
        case "qna": return "text.bubble"
        case "bookmark": return "bookmark"
        case "navigation": return "arrow.up.forward.app"
        default: return kind
        }
    }
    static func defaultName(_ kind: String) -> String {
        switch kind {
        case "leftArrow": return "Previous"
        case "rightArrow": return "Next"
        case "reset": return "Reset"
        case "back": return "Back"
        case "information": return "Information"
        case "help": return "Help"
        case "qna": return "Q&A"
        case "bookmark": return "Bookmark"
        case "navigation": return "Navigate"
        default: return "Button"
        }
    }
}

// MARK: - Button face

/// One state-styled button: used by the button visual and by both navigators.
struct CmpButtonFace: View {
    let env: CmpEnv
    let resolver: CmpButtonResolver
    var title: String
    var symbol: String?
    var customImage: NSImage?
    var isSelected = false
    var isEnabled = true
    var help = ""
    var accessibilityName = ""
    let action: () -> Void

    @State private var hovering = false
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: { if isEnabled && env.isInteractive { action() } }) { EmptyView() }
            .buttonStyle(CmpButtonChrome(face: self, hovering: hovering, focused: focused))
            .focused($focused)
            .focusEffectDisabled()
            .disabled(!isEnabled)
            .onHover { hovering = $0 }
            .help(help.isEmpty ? title : help)
            .accessibilityLabel(accessibilityName.isEmpty ? (title.isEmpty ? "Button" : title) : accessibilityName)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private struct CmpButtonChrome: ButtonStyle {
    let face: CmpButtonFace
    let hovering: Bool
    let focused: Bool

    func makeBody(configuration: Configuration) -> some View {
        let env = face.env, f = env.f
        let state = CmpButtonResolver.state(hover: hovering, pressed: configuration.isPressed, selected: face.isSelected, enabled: face.isEnabled)
        let look = face.resolver.look(state)
        let shapeKind = f.string("button", "shape", "roundedRectangle")
        return GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let radius: CGFloat = shapeKind == "pill" ? min(w, h) / 2 : (shapeKind == "rectangle" ? 0 : min(CGFloat(f.double("button", "radius", 8)), min(w, h) / 2))
            let shape = RoundedRectangle(cornerRadius: radius, style: shapeKind == "pill" ? .circular : .continuous)
            let textSize = min(f.double("text", "size", 13), max(8, Double(h) * 0.5))
            let iconSize = min(f.double("icon", "size", textSize + 2), max(8, Double(h) * 0.56))
            let placement = f.string("icon", "placement", "left")
            let hasIcon = face.symbol != nil || face.customImage != nil
            let titleFits = !face.title.isEmpty && (!hasIcon || w >= 64)
            let vertical = (placement == "above" || placement == "below") && h >= 44
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 4)) : AnyLayout(HStackLayout(spacing: 6))
            let iconFirst = placement == "left" || placement == "above"
            ZStack {
                shape.fill(look.fill)
                shape.strokeBorder(look.outline, lineWidth: look.outlineWidth)
                layout {
                    if hasIcon, iconFirst { icon(size: iconSize, color: look.icon) }
                    if titleFits {
                        Text(face.title)
                            .font(env.font(textSize, f.bool("text", "bold", true) ? .medium : .regular))
                            .foregroundStyle(look.text)
                            .lineLimit(vertical || h < 40 ? 1 : 2).multilineTextAlignment(.center)
                            .minimumScaleFactor(0.75)
                    }
                    if hasIcon, !iconFirst { icon(size: iconSize, color: look.icon) }
                }
                .padding(.horizontal, min(10, w * 0.08))
                .frame(width: w, height: h, alignment: alignment(f.string("text", "alignment", "center")))
                if focused {
                    shape.inset(by: -2.5).stroke(env.accent.opacity(0.6), lineWidth: 2.5)
                }
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(Design.Motion.quick, value: state)
            .contentShape(shape)
        }
    }

    @ViewBuilder private func icon(size: Double, color: Color) -> some View {
        if let img = face.customImage {
            Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(width: size * 1.25, height: size * 1.25)
        } else if let s = face.symbol {
            Image(systemName: s).font(.system(size: size, weight: .medium)).foregroundStyle(color)
        }
    }
    private func alignment(_ s: String) -> Alignment { s == "left" ? .leading : (s == "right" ? .trailing : .center) }
}

// MARK: - Button visual

struct CmpButtonView: View {
    let env: CmpEnv

    var body: some View {
        let f = env.f
        let kind = f.string("button", "icon", "blank")
        let action = env.spec.action ?? ActionSpec()
        let text = f.string("text", "text", f.string("button", "text", ""))
        let custom = (kind == "custom" || CmpButtonIcon.symbol(kind) == nil) ? env.spec.imageData.flatMap(NSImage.init(data:)) : nil
        CmpButtonFace(env: env, resolver: CmpButtonResolver(env: env, defaultStyle: "tinted"),
                      title: text, symbol: CmpButtonIcon.symbol(kind), customImage: custom,
                      isSelected: f.bool("button", "selected", false),
                      isEnabled: f.bool("button", "enabled", true),
                      help: action.tooltip.isEmpty ? (text.isEmpty ? CmpButtonIcon.defaultName(kind) : text) : action.tooltip,
                      accessibilityName: env.spec.altText.isEmpty ? (text.isEmpty ? CmpButtonIcon.defaultName(kind) : text) : env.spec.altText) {
            env.context.onAction(action)
        }
        .rotationEffect(.degrees(env.spec.frame.rotation))
    }
}

// MARK: - Navigators

/// Auto-generated strip of buttons for pages or bookmarks.
struct CmpNavigatorView: View {
    let env: CmpEnv
    let isBookmarks: Bool

    var body: some View {
        let items = isBookmarks ? env.context.bookmarks : env.context.pages
        let selected = isBookmarks ? env.context.activeBookmarkID : env.context.currentPageID
        if items.isEmpty {
            CmpPlaceholder(systemImage: isBookmarks ? "bookmark" : "rectangle.stack",
                           title: isBookmarks ? "No bookmarks yet" : "No pages",
                           message: isBookmarks ? "Bookmarks you add appear here as buttons." : "", theme: env.theme)
        } else {
            GeometryReader { geo in layout(items: items, selected: selected, size: geo.size) }
                .accessibilityElement(children: .contain)
                .accessibilityLabel(isBookmarks ? "Bookmark navigator" : "Page navigator")
        }
    }

    @ViewBuilder private func layout(items: [NavItem], selected: UUID?, size: CGSize) -> some View {
        let f = env.f
        let gap = CGFloat(f.double("navigator", "spacing", 6))
        let n = CGFloat(items.count)
        let orientation = f.string("navigator", "orientation", size.height > size.width * 1.2 ? "vertical" : "horizontal")
        switch orientation {
        case "vertical":
            let fit = (size.height - gap * (n - 1)) / n
            let h = min(CGFloat(f.double("navigator", "buttonHeight", 34)), max(24, fit))
            let stack = VStack(spacing: gap) { ForEach(items) { button($0, selected).frame(height: h) } }
            if fit < 24 { ScrollView(.vertical) { stack } } else { stack.frame(maxHeight: .infinity, alignment: .top) }
        case "grid":
            let cols = f.int("navigator", "columns", 2, in: 1...100)
            let rows = Int(ceil(Double(items.count) / Double(cols)))
            let w = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
            let fit = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let h = max(24, fit)
            let grid = VStack(spacing: gap) {
                ForEach(0..<rows, id: \.self) { r in
                    HStack(spacing: gap) {
                        ForEach(0..<cols, id: \.self) { c in
                            if let item = items[safe: r * cols + c] { button(item, selected).frame(width: w, height: h) }
                            else { Color.clear.frame(width: w, height: h) }
                        }
                    }
                }
            }
            if fit < 24 { ScrollView(.vertical) { grid } } else { grid }
        default:
            let fit = (size.width - gap * (n - 1)) / n
            if fit < 64 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: gap) { ForEach(items) { button($0, selected).frame(width: 96) } }.frame(height: size.height)
                }
            } else {
                HStack(spacing: gap) { ForEach(items) { button($0, selected).frame(width: fit) } }
            }
        }
    }

    private func button(_ item: NavItem, _ selected: UUID?) -> some View {
        CmpButtonFace(env: env, resolver: CmpButtonResolver(env: env, defaultStyle: "soft"),
                      title: item.name, symbol: nil, isSelected: item.id == selected,
                      help: item.name, accessibilityName: item.name) {
            var a = ActionSpec()
            if isBookmarks { a.kind = .bookmark; a.bookmarkID = item.id } else { a.kind = .pageNavigation; a.pageID = item.id }
            env.context.onAction(a)
        }
    }
}
