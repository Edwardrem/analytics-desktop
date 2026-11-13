import SwiftUI
import AppKit
import FacetCore
import FacetDesign

// Flat-value slicer styles: vertical list (checkbox / radio / highlight), tiles, and the dropdown shell.

/// Vertical list with optional search and "Select all". Writes `SlicerState.selected`.
struct CmpSlListView: View {
    let session: CmpSlSession
    let items: [CmpSlItem]
    let appearance: CmpSlRow.Appearance
    var forceSearch = false
    @State private var query = ""
    @State private var active = 0
    @State private var keyFocused = false

    var body: some View {
        let cfg = session.cfg, env = session.env
        let shown = CmpSlLogic.filter(items, query: query)
        let selected = Set(session.state.selected)
        let showAll = cfg.selectAll && !cfg.singleSelect && query.isEmpty && !items.isEmpty
        let offset = showAll ? 1 : 0
        VStack(alignment: .leading, spacing: 5) {
            if cfg.search || forceSearch {
                CmpSlSearchField(text: $query, env: env, cfg: cfg)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if showAll {
                            CmpSlRow(label: "Select all",
                                     check: CmpSlLogic.allState(all: items.map(\.value), selected: session.state.selected),
                                     appearance: appearance, env: env, cfg: cfg,
                                     isKeyFocused: keyFocused && active == 0) { _ in toggleAll() }
                                .id(-1)
                        }
                        ForEach(Array(shown.enumerated()), id: \.element.id) { i, item in
                            CmpSlRow(label: item.label, check: selected.contains(item.value) ? .on : .off,
                                     appearance: appearance, env: env, cfg: cfg, radio: cfg.singleSelect,
                                     isKeyFocused: keyFocused && active == i + offset) { additive in
                                active = i + offset
                                activate(item, additive: additive)
                            }
                            .id(item.id)
                        }
                        if shown.isEmpty {
                            Text(items.isEmpty ? "No values" : "No matches")
                                .font(env.font(cfg.fontSize)).foregroundStyle(env.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 4)
                        }
                    }
                }
                .onChange(of: active) { _, new in
                    let id = new - offset
                    withAnimation(Design.Motion.quick) { proxy.scrollTo(id < 0 ? -1 : (shown[safe: id]?.id ?? -1)) }
                }
            }
            .modifier(CmpSlKeyNav(count: shown.count + offset, enabled: env.isInteractive, active: $active, focused: $keyFocused,
                                  activate: { i, additive in
                                      if showAll, i == 0 { toggleAll() } else if let item = shown[safe: i - offset] {
                                          // Space toggles within the set; Return behaves like a plain click.
                                          activate(item, additive: additive || !cfg.commandMulti)
                                      }
                                  },
                                  selectAll: cfg.singleSelect ? nil : { session.update { $0.selected = items.map(\.value) } }))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(session.env.caption(session.env.data.indices(.field).first ?? 0)) values")
        }
    }

    private func activate(_ item: CmpSlItem, additive: Bool) {
        let cfg = session.cfg
        let add = cfg.commandMulti ? additive : true
        session.update {
            $0.selected = CmpSlLogic.toggle(item.value, in: $0.selected, single: cfg.singleSelect, additive: add, force: cfg.forceSelection)
        }
    }
    private func toggleAll() {
        session.update { $0.selected = CmpSlLogic.toggleAll(all: items.map(\.value), selected: $0.selected) }
    }
}

/// Wrapping pill buttons. Writes `SlicerState.selected`.
struct CmpSlTileView: View {
    let session: CmpSlSession
    let items: [CmpSlItem]
    @State private var active = 0
    @State private var keyFocused = false

    var body: some View {
        let cfg = session.cfg, env = session.env
        let selected = Set(session.state.selected)
        ScrollView(.vertical) {
            CmpSlFlow(spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                    CmpSlTile(label: item.label, selected: selected.contains(item.value), env: env, cfg: cfg,
                              isKeyFocused: keyFocused && active == i) { additive in
                        active = i
                        activate(item, additive: additive)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(1)
        }
        .modifier(CmpSlKeyNav(count: items.count, enabled: env.isInteractive, active: $active, focused: $keyFocused,
                              activate: { i, additive in
                                  if let item = items[safe: i] { activate(item, additive: additive || !cfg.commandMulti) }
                              },
                              selectAll: cfg.singleSelect ? nil : { session.update { $0.selected = items.map(\.value) } },
                              horizontal: { cur, right in
                                  active = right ? min(items.count - 1, cur + 1) : max(0, cur - 1)
                                  return true
                              }))
    }

    private func activate(_ item: CmpSlItem, additive: Bool) {
        let cfg = session.cfg
        session.update {
            $0.selected = CmpSlLogic.toggle(item.value, in: $0.selected, single: cfg.singleSelect,
                                            additive: cfg.commandMulti ? additive : true, force: cfg.forceSelection)
        }
    }
}

struct CmpSlTile: View {
    let label: String
    let selected: Bool
    let env: CmpEnv
    let cfg: CmpSlConfig
    var isKeyFocused = false
    let action: (Bool) -> Void
    @State private var hovering = false
    @GestureState private var pressed = false

    var body: some View {
        Text(label)
            .font(env.font(cfg.fontSize, selected ? .semibold : .regular))
            .foregroundStyle(selected ? cfg.onSelected : cfg.text)
            .lineLimit(1)
            .padding(.horizontal, 11).padding(.vertical, cfg.itemPadding + 1.5)
            .background(Capsule().fill(selected ? cfg.selected : (hovering ? env.subtleFill : .clear)))
            .overlay(Capsule().strokeBorder(selected ? .clear : env.grid, lineWidth: 1))
            .overlay { if isKeyFocused { Capsule().strokeBorder(cfg.selected, lineWidth: 2).padding(-2.5) } }
            .opacity(pressed ? 0.7 : 1)
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).updating($pressed) { _, s, _ in s = true }
                .onEnded { v in
                    if abs(v.translation.width) < 8, abs(v.translation.height) < 8 { action(NSEvent.modifierFlags.contains(.command)) }
                })
            .onHover { hovering = $0 }
            .animation(Design.Motion.quick, value: selected)
            .help(label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { action(false) }
    }
}

/// Closed dropdown field; the content (list or tree) opens in a popover.
struct CmpSlDropdown<Content: View>: View {
    let session: CmpSlSession
    let summary: String
    @ViewBuilder let content: () -> Content
    @State private var open = false
    @State private var width: CGFloat = 220
    @State private var hovering = false
    @FocusState private var focused: Bool
    @State private var ring = false

    var body: some View {
        let env = session.env, cfg = session.cfg
        HStack(spacing: 6) {
            Text(summary)
                .font(env.font(cfg.fontSize))
                .foregroundStyle(session.state.isActive ? cfg.text : env.secondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(env.secondary)
                .rotationEffect(.degrees(open ? 180 : 0))
        }
        .padding(.horizontal, 9).padding(.vertical, 6)
        .background(CmpSlFieldBackground(env: env, focused: (focused && ring) || open))
        .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w } })
        .opacity(hovering ? 0.92 : 1)
        .contentShape(Rectangle())
        .onTapGesture { open.toggle() }
        .onHover { hovering = $0 }
        .focusable(env.isInteractive)
        .focused($focused)
        .focusEffectDisabled()
        .onChange(of: focused) { _, new in ring = new && CmpSlFocus.viaKeyboard }
        .onKeyPress(keys: [.space, .return, .downArrow]) { _ in open = true; return .handled }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            content()
                .padding(8)
                .frame(width: max(200, width), height: 280)
                .background(env.card)
                .environment(\.colorScheme, env.theme.isDark ? .dark : .light)
        }
        .help(summary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(VisualTitles.automatic(for: env.spec)) dropdown")
        .accessibilityValue(summary)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open.toggle() }
    }

    static func summary(labels: [String]) -> String {
        switch labels.count {
        case 0: return "All"
        case 1...3: return labels.joined(separator: ", ")
        default: return "\(labels.count) selected"
        }
    }
}
