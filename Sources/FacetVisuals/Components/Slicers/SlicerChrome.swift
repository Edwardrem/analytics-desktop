import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// Shared slicer chrome: the session (direct vs. staged writes), the host with the clear affordance
// and Apply button, and the small controls every style reuses.

/// What a style view reads and writes. `write` stages in Apply-button mode, otherwise commits.
struct CmpSlSession {
    let env: CmpEnv
    let cfg: CmpSlConfig
    let state: SlicerState
    let write: (SlicerState) -> Void
    func update(_ mutate: (inout SlicerState) -> Void) {
        var s = state
        mutate(&s)
        write(s)
    }
}

/// Wraps a slicer body with the eraser (clear selections) and the optional Apply button.
struct CmpSlHost: View {
    let env: CmpEnv
    @State private var staged: SlicerState?
    @State private var hoverBody = false
    @State private var hoverEraser = false

    var body: some View {
        let cfg = CmpSlConfig(env)
        let committed = env.spec.slicerState ?? SlicerState()
        let effective = cfg.applyButton ? (staged ?? committed) : committed
        let session = CmpSlSession(env: env, cfg: cfg, state: effective) { new in
            if cfg.applyButton { staged = new } else { env.context.onSlicerChange(new) }
        }
        let pending = cfg.applyButton && staged != nil && staged != committed
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: 6) {
                CmpSlBody(session: session, size: geo.size)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if cfg.applyButton, geo.size.height > 70 {
                    applyRow(pending: pending, cfg: cfg)
                }
            }
        }
        .overlay(alignment: .topTrailing) { eraser(session, cfg: cfg) }
        .onHover { hoverBody = $0 }
        .allowsHitTesting(env.isInteractive)
        .onChange(of: env.spec.slicerState) { _, _ in staged = nil }
    }

    private var titleShown: Bool {
        env.f.bool("title", "show", true) && !(env.spec.fmt("title", "text")?.stringValue ?? VisualTitles.automatic(for: env.spec)).isEmpty
    }

    @ViewBuilder private func eraser(_ session: CmpSlSession, cfg: CmpSlConfig) -> some View {
        if cfg.clearMode != "never", session.state.isActive {
            let visible = cfg.clearMode == "always" || hoverBody || hoverEraser
            let titleSize = env.f.double("title", "size", env.theme.title.size)
            Button { session.write(SlicerState()) } label: {
                Image(systemName: "eraser")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hoverEraser ? env.fg : env.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(titleShown ? (hoverEraser ? env.subtleFill : .clear) : env.card))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoverEraser = $0 }
            .opacity(visible ? 1 : 0)
            .animation(Design.Motion.quick, value: visible)
            .offset(y: titleShown ? -(titleSize * 1.2 + Design.Space.s) - 1 : 0)
            .help("Clear selections")
            .accessibilityLabel("Clear selections")
        }
    }

    private func applyRow(pending: Bool, cfg: CmpSlConfig) -> some View {
        HStack(spacing: 8) {
            if pending {
                Text("Changes not applied").font(env.font(10)).foregroundStyle(env.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                if let s = staged { env.context.onSlicerChange(s); staged = nil }
            } label: {
                Text("Apply")
                    .font(env.font(11, .semibold))
                    .foregroundStyle(pending ? cfg.onSelected : env.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Capsule().fill(pending ? cfg.selected : env.subtleFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!pending)
            .keyboardShortcut(.return, modifiers: .command)
            .help(pending ? "Apply the staged selection" : "No changes to apply")
            .accessibilityLabel("Apply")
        }
    }
}

// MARK: - Glyphs

/// Checkbox / radio indicator drawn in theme colours (crisp at any size, legible in high contrast).
struct CmpSlGlyph: View {
    enum Kind { case checkbox, radio }
    let kind: Kind
    let check: CmpSlCheck
    let env: CmpEnv
    let cfg: CmpSlConfig
    var body: some View {
        let side: CGFloat = max(12, min(16, cfg.fontSize + 1.5))
        let on = check != .off
        ZStack {
            if kind == .radio {
                Circle().fill(on ? cfg.selected : .clear)
                Circle().strokeBorder(on ? cfg.selected : env.secondary.opacity(env.theme.isHighContrast ? 1 : 0.7), lineWidth: 1)
                if on { Circle().fill(cfg.onSelected).frame(width: side * 0.38, height: side * 0.38) }
            } else {
                RoundedRectangle(cornerRadius: side * 0.26, style: .continuous).fill(on ? cfg.selected : .clear)
                RoundedRectangle(cornerRadius: side * 0.26, style: .continuous)
                    .strokeBorder(on ? cfg.selected : env.secondary.opacity(env.theme.isHighContrast ? 1 : 0.7), lineWidth: 1)
                if check == .on {
                    Image(systemName: "checkmark").font(.system(size: side * 0.6, weight: .bold)).foregroundStyle(cfg.onSelected)
                } else if check == .mixed {
                    RoundedRectangle(cornerRadius: 1).fill(cfg.onSelected).frame(width: side * 0.5, height: 1.8)
                }
            }
        }
        .frame(width: side, height: side)
        .animation(Design.Motion.quick, value: check)
    }
}

// MARK: - Row

/// One selectable row: optional indent + disclosure, a glyph (or highlight appearance), a label.
struct CmpSlRow: View {
    enum Appearance { case check, highlight }
    let label: String
    let check: CmpSlCheck
    let appearance: Appearance
    let env: CmpEnv
    let cfg: CmpSlConfig
    var radio = false
    var indent: CGFloat = 0
    /// nil = no disclosure slot; false/true = collapsed/expanded; `hasChildren` false leaves an empty slot.
    var expanded: Bool?
    var hasChildren = false
    var isKeyFocused = false
    var bold = false
    let action: (_ additive: Bool) -> Void
    var onDisclosure: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        let selected = check == .on
        HStack(spacing: 7) {
            if expanded != nil {
                Group {
                    if hasChildren {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(expanded == true ? 90 : 0))
                            .foregroundStyle(env.secondary)
                            .frame(width: 14, height: 12)
                            .contentShape(Rectangle())
                            .onTapGesture(perform: onDisclosure)
                            .accessibilityLabel(expanded == true ? "Collapse \(label)" : "Expand \(label)")
                            .accessibilityAddTraits(.isButton)
                    } else {
                        Color.clear.frame(width: 14, height: 1)
                    }
                }
            }
            if appearance == .check {
                CmpSlGlyph(kind: radio ? .radio : .checkbox, check: check, env: env, cfg: cfg)
            }
            Text(label)
                .font(env.font(cfg.fontSize, bold || (appearance == .highlight && selected) ? .semibold : .regular))
                .foregroundStyle(cfg.text)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if appearance == .highlight, check != .off {
                Image(systemName: check == .on ? "checkmark" : "minus")
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(cfg.selected)
            }
        }
        .padding(.leading, 6 + indent).padding(.trailing, 8)
        .padding(.vertical, cfg.itemPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(appearance == .highlight && selected ? env.selectionFill : (hovering ? env.subtleFill : .clear))
        )
        .overlay {
            if isKeyFocused {
                RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(cfg.selected, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { action(NSEvent.modifierFlags.contains(.command)) }
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(check == .on ? "selected" : (check == .mixed ? "partially selected" : "not selected"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { action(false) }
    }
}

// MARK: - Fields

/// Quiet field surface: soft fill, accent ring when focused, visible edge in high contrast.
struct CmpSlFieldBackground: View {
    let env: CmpEnv
    var focused = false
    var radius: CGFloat = 6
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(env.subtleFill)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(focused ? env.accent : (env.theme.isHighContrast ? env.grid : .clear), lineWidth: focused ? 1.5 : 1)
            )
    }
}

struct CmpSlSearchField: View {
    @Binding var text: String
    let env: CmpEnv
    let cfg: CmpSlConfig
    var prompt = "Search"
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium)).foregroundStyle(env.secondary)
            TextField("", text: $text, prompt: Text(prompt).foregroundColor(env.secondary.opacity(0.8)))
                .textFieldStyle(.plain)
                .font(env.font(cfg.fontSize))
                .foregroundStyle(cfg.text)
                .focused($focused)
                .accessibilityLabel(prompt)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(env.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 7).padding(.vertical, 4)
        .background(CmpSlFieldBackground(env: env, focused: focused))
    }
}

/// Pull-down menu styled as a quiet field.
struct CmpSlMenu: View {
    let title: String
    let options: [(id: String, label: String)]
    let env: CmpEnv
    let cfg: CmpSlConfig
    var accessibility: String
    let pick: (String) -> Void
    var body: some View {
        Menu {
            ForEach(options, id: \.id) { o in
                Button(o.label) { pick(o.id) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title).font(env.font(cfg.fontSize)).foregroundStyle(cfg.text).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(env.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(CmpSlFieldBackground(env: env))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(accessibility)
        .accessibilityValue(title)
    }
}

// MARK: - Keyboard navigation

enum CmpSlFocus {
    /// True when the event being handled is a key press — focus rings are only drawn for keyboard focus.
    static var viaKeyboard: Bool { NSApp.currentEvent?.type == .keyDown }
}

/// Makes a container a single focus stop with arrow-key navigation over `count` items.
/// Space toggles (additive), Return activates (plain click), ⌘A selects all, Home/End jump.
struct CmpSlKeyNav: ViewModifier {
    let count: Int
    var columns = 1
    let enabled: Bool
    @Binding var active: Int
    @Binding var focused: Bool
    let activate: (_ index: Int, _ additive: Bool) -> Void
    var selectAll: (() -> Void)?
    /// Left/right handler for trees (index, isRight) → handled.
    var horizontal: ((Int, Bool) -> Bool)?
    @FocusState private var focus: Bool

    func body(content: Content) -> some View {
        content
            .focusable(enabled)
            .focused($focus)
            .focusEffectDisabled()
            .onChange(of: focus) { _, new in focused = new && CmpSlFocus.viaKeyboard }
            .onKeyPress(phases: [.down, .repeat]) { press in
                guard count > 0 else { return .ignored }
                if press.key != .tab, !focused { focused = true }
                let cur = min(max(active, 0), count - 1)
                switch press.key {
                case .upArrow: active = max(0, cur - columns)
                case .downArrow: active = min(count - 1, cur + columns)
                case .leftArrow:
                    if let horizontal { return horizontal(cur, false) ? .handled : .ignored }
                    if columns > 1 { active = max(0, cur - 1) } else { return .ignored }
                case .rightArrow:
                    if let horizontal { return horizontal(cur, true) ? .handled : .ignored }
                    if columns > 1 { active = min(count - 1, cur + 1) } else { return .ignored }
                case .home: active = 0
                case .end: active = count - 1
                case .space: activate(cur, true)
                case .return: activate(cur, false)
                default:
                    if press.modifiers.contains(.command), press.characters == "a", let selectAll { selectAll(); return .handled }
                    return .ignored
                }
                return .handled
            }
    }
}

// MARK: - Flow layout

/// Wrapping left-to-right layout for tiles and chips.
struct CmpSlFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let a = arrange(bounds.width, subviews)
        for (i, p) in a.points.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), anchor: .topLeading,
                              proposal: ProposedViewSize(width: min(a.sizes[i].width, bounds.width), height: a.sizes[i].height))
        }
    }
    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (points: [CGPoint], sizes: [CGSize], width: CGFloat, height: CGFloat) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxW: CGFloat = 0
        var pts: [CGPoint] = [], sizes: [CGSize] = []
        for s in subviews {
            var size = s.sizeThatFits(.unspecified)
            size.width = min(size.width, width)
            if x > 0, x + size.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y)); sizes.append(size)
            x += size.width + spacing
            rowH = max(rowH, size.height)
            maxW = max(maxW, x - spacing)
        }
        return (pts, sizes, maxW, y + rowH)
    }
}

// MARK: - Images

enum CmpSlImage {
    /// Decodes a `data:image/...;base64,` URI.
    static func dataURI(_ s: String) -> NSImage? {
        guard s.hasPrefix("data:"), let comma = s.firstIndex(of: ","),
              let data = Data(base64Encoded: String(s[s.index(after: comma)...]), options: .ignoreUnknownCharacters) else { return nil }
        return NSImage(data: data)
    }
    static func looksLikeImage(_ s: String) -> Bool {
        s.hasPrefix("data:image") || ((s.hasPrefix("http://") || s.hasPrefix("https://")) &&
            [".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".heic"].contains { s.lowercased().contains($0) })
    }
}

struct CmpSlImageView: View {
    let source: String
    let size: CGFloat
    var body: some View {
        Group {
            if let img = CmpSlImage.dataURI(source) {
                Image(nsImage: img).resizable().scaledToFit()
            } else if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFit() }
                    else { RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)) }
                }
            } else {
                Image(systemName: "photo").font(.system(size: size * 0.6, weight: .light)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
