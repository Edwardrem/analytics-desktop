import SwiftUI
import UniformTypeIdentifiers
import FacetCore
import FacetDesign
import FacetVisuals

/// Hook for visuals rendered by the app rather than FacetVisuals (AI visuals, scripted visuals).
enum VisualExtensions {
    @MainActor static var provider: ((VisualSpec, VisualData, VisualContext, DocumentStore) -> AnyView?)?
}

/// Drag payload for model fields: "kind|table|name".
enum FieldDrag {
    static func encode(_ f: FieldRef) -> String { "facet-field:\(f.kind.rawValue)|\(f.table)|\(f.name)" }
    static func decode(_ s: String) -> FieldRef? {
        guard s.hasPrefix("facet-field:") else { return nil }
        let parts = s.dropFirst("facet-field:".count).split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let kind = FieldRef.Kind(rawValue: parts[0]) else { return nil }
        return FieldRef(kind: kind, table: parts[1], name: parts[2])
    }
}

extension DocumentStore {
    /// The frame a visual occupies in the layout being edited (desktop or phone).
    func frame(of v: VisualSpec) -> Frame { mobileLayout ? (v.mobileFrame ?? v.frame) : v.frame }
    var canvasSize: PageSize { mobileLayout ? .phone : currentPage.size }

    func context(for spec: VisualSpec, interactive: Bool = true) -> VisualContext {
        var c = VisualContext()
        c.theme = theme
        c.isInteractive = interactive
        c.selection = pointSelections[spec.id] ?? []
        c.overlays = overlays[spec.id] ?? AnalyticsOverlays()
        c.pages = report.pages.filter { !$0.isHidden }.map { NavItem(id: $0.id, name: $0.name) }
        c.bookmarks = report.bookmarks.map { NavItem(id: $0.id, name: $0.name) }
        c.currentPageID = currentPageID
        c.activeBookmarkID = activeBookmarkID
        let id = spec.id
        c.onSelect = { [weak self] points, additive in self?.selectPoints(points, in: id, additive: additive) }
        c.onSlicerChange = { [weak self] state in self?.setSlicerState(state, for: id) }
        c.onAction = { [weak self] action in self?.perform(action, from: id) }
        c.onDrill = { [weak self] action in self?.drill(action, in: id) }
        c.onSpecChange = { [weak self] new in
            self?.updateVisual(id, name: "Change Visual", coalesce: "spec-\(id)") { $0 = new }
        }
        c.extensionView = { [weak self] spec, data, ctx in
            guard let self else { return nil }
            return VisualExtensions.provider?(spec, data, ctx, self)
        }
        return c
    }
}

/// The report design surface: a page, scaled to fit, with direct manipulation of visuals.
struct ReportCanvas: View {
    @EnvironmentObject var store: DocumentStore
    @State private var marquee: CGRect?
    @State private var guides: [SnapGuide] = []
    @State private var dropTargeted = false

    var body: some View {
        GeometryReader { geo in
            let size = store.canvasSize
            let scale = store.fitToWindow
                ? CanvasFit.scale(viewport: geo.size, page: CGSize(width: size.width, height: size.height))
                : store.zoom
            ScrollView([.horizontal, .vertical]) {
                page(scale: scale)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .padding(CanvasFit.margin)
                    .frame(minWidth: geo.size.width, minHeight: geo.size.height)
            }
            .background(wallpaper)
            .onChange(of: scale) { _, s in if store.fitToWindow { store.zoom = s } }
            .onAppear { if store.fitToWindow { store.zoom = scale } }
        }
    }

    private var wallpaper: some View {
        let w = store.currentPage.wallpaper
        return ZStack {
            Design.Palette.canvas
            if let c = w.color { Color(hex: c).opacity(1 - w.transparency / 100) }
            if let d = w.imageData, let img = NSImage(data: d) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).opacity(1 - w.transparency / 100)
            }
        }
        .ignoresSafeArea()
    }

    private func page(scale: Double) -> some View {
        let page = store.currentPage
        let size = store.canvasSize
        let visuals = page.visuals
            .filter { !$0.isHidden && (!store.mobileLayout || $0.mobileFrame != nil) }
            .sorted { $0.zIndex < $1.zIndex }
        return ZStack(alignment: .topLeading) {
            pageBackground(page)
                .contentShape(Rectangle())
                .gesture(marqueeGesture(scale: scale))
                .onTapGesture {
                    store.selection = []
                    store.clearPointSelections()
                    store.editInteractionsFor = nil
                }
            if store.showGridlines { GridOverlay(spacing: 24).allowsHitTesting(false) }
            if visuals.isEmpty, !store.mobileLayout { StartSurface().frame(width: size.width, height: size.height) }
            ForEach(visuals) { spec in
                VisualContainer(spec: spec, scale: scale, guides: $guides)
            }
            ForEach(guides) { g in
                Rectangle().fill(Color.accentColor)
                    .frame(width: g.vertical ? 1 / scale : size.width, height: g.vertical ? size.height : 1 / scale)
                    .offset(x: g.vertical ? g.position : 0, y: g.vertical ? 0 : g.position)
                    .allowsHitTesting(false)
            }
            if let m = marquee {
                Rectangle().fill(Color.accentColor.opacity(0.08))
                    .overlay(Rectangle().strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1 / scale))
                    .frame(width: m.width, height: m.height).offset(x: m.minX, y: m.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .shadow(color: .black.opacity(0.10), radius: 18, y: 6)
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(dropTargeted ? Color.accentColor : .clear, lineWidth: 2))
        .scaleEffect(scale, anchor: .topLeading)
        .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
        .dropDestination(for: String.self) { items, location in
            guard let field = items.compactMap(FieldDrag.decode).first else { return false }
            let p = CGPoint(x: location.x / scale, y: location.y / scale)
            if let hit = visuals.reversed().first(where: { store.frame(of: $0).cgRect.contains(p) && !$0.type.wells.isEmpty }) {
                store.addField(field, to: hit.id)
                store.selection = [hit.id]
            } else {
                store.selection = []
                store.addField(field)
                if let id = store.selection.first, let v = store.visual(id) {
                    var f = v.frame
                    f.x = max(0, min(p.x - f.width / 2, size.width - f.width))
                    f.y = max(0, min(p.y - f.height / 2, size.height - f.height))
                    store.setFrames([id: f], name: "Place Visual", coalesce: "place-\(id)")
                }
            }
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func pageBackground(_ page: Page) -> some View {
        ZStack {
            store.theme.backgroundColor
            if let c = page.background.color { Color(hex: c).opacity(1 - page.background.transparency / 100) }
            if let d = page.background.imageData, let img = NSImage(data: d) {
                Image(nsImage: img).resizable()
                    .aspectRatio(contentMode: page.background.imageFit == "fill" ? .fill : .fit)
                    .opacity(1 - page.background.transparency / 100)
            }
        }
    }

    private func marqueeGesture(scale: Double) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { g in
                let r = CGRect(x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                               width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
                marquee = r
                store.selection = Set(store.currentPage.visuals
                    .filter { !$0.isHidden && store.frame(of: $0).cgRect.intersects(r) }.map(\.id))
            }
            .onEnded { _ in marquee = nil; store.selection = store.withGroupMembers(store.selection) }
    }
}

struct SnapGuide: Identifiable, Hashable {
    var vertical: Bool
    var position: Double
    var id: String { "\(vertical)-\(position)" }
}

private struct GridOverlay: View {
    let spacing: Double
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x = spacing
            while x < size.width { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height)); x += spacing }
            var y = spacing
            while y < size.height { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y)); y += spacing }
            ctx.stroke(path, with: .color(.primary.opacity(0.06)), lineWidth: 0.5)
        }
    }
}

/// One visual on the canvas: the rendered visual plus selection chrome, header, move and resize.
struct VisualContainer: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let scale: Double
    @Binding var guides: [SnapGuide]
    @State private var hovering = false
    @State private var dragOrigin: [UUID: Frame]?
    @State private var resizeOrigin: Frame?

    private var isSelected: Bool { store.selection.contains(spec.id) }
    private var locked: Bool { store.lockObjects || spec.isLocked }

    var body: some View {
        let frame = store.frame(of: spec)
        let data = store.visualData[spec.id] ?? VisualData()
        ZStack(alignment: .topLeading) {
            VisualView(spec: spec, data: data, context: store.context(for: spec))
                .frame(width: frame.width, height: frame.height)
                .rotationEffect(.degrees(frame.rotation))
                .opacity(store.editInteractionsFor != nil && store.editInteractionsFor != spec.id ? 0.92 : 1)
                // Page elements have no inner interactions, so the whole body moves them.
                .gesture(spec.type.isPageElement && spec.type != .textBox && spec.type != .button && !isNavigator
                         ? moveGesture : nil)
                .simultaneousGesture(TapGesture().onEnded { select(additive: NSEvent.modifierFlags.contains(.shift)) })

            if store.loadingVisuals.contains(spec.id) {
                ProgressView().controlSize(.small).padding(8)
                    .frame(width: frame.width, height: frame.height, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
            if store.pendingWhilePaused.contains(spec.id) {
                Label("Pending", systemImage: "pause.circle").font(Design.Typeface.caption).foregroundStyle(.secondary)
                    .padding(6).background(.regularMaterial, in: Capsule())
                    .frame(width: frame.width, height: frame.height).allowsHitTesting(false)
            }
            if let source = store.editInteractionsFor, source != spec.id {
                InteractionPicker(source: source, target: spec)
                    .frame(width: frame.width, alignment: .trailing).offset(y: -30 / scale)
            } else if (hovering || isSelected) && !store.presenting {
                VisualHeader(spec: spec, scale: scale, moveGesture: AnyGesture(moveGesture.map { _ in () }))
                    .frame(width: frame.width, alignment: .trailing)
                    .offset(y: -28 / scale)
            }
            if isSelected && !store.presenting {
                SelectionChrome(frame: frame, scale: scale, single: store.selection.count == 1, locked: locked) { handle, translation, ended in
                    resize(handle, translation, ended)
                }
                .gesture(moveGesture)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .offset(x: frame.x, y: frame.y)
        .onHover { hovering = $0 }
        .contextMenu { VisualContextMenu(spec: spec) }
        .zIndex(Double(spec.zIndex) + (isSelected ? 0.5 : 0))
    }

    private var isNavigator: Bool { spec.type == .pageNavigator || spec.type == .bookmarkNavigator }

    private func select(additive: Bool) {
        if let source = store.formatPainterSource, source != spec.id, let from = store.visual(source) {
            store.updateVisual(spec.id, name: "Paint Format", invalidates: .layout) { $0.format = FormatPainter.painted($0, from: from) }
            store.formatPainterSource = nil
            return
        }
        if additive {
            if isSelected { store.selection.remove(spec.id) } else { store.selection.insert(spec.id) }
        } else if !isSelected {
            store.selection = [spec.id]
        }
        store.selection = store.withGroupMembers(store.selection)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { g in
                guard !locked else { return }
                if dragOrigin == nil {
                    if !isSelected { store.selection = store.withGroupMembers([spec.id]) }
                    dragOrigin = Dictionary(uniqueKeysWithValues: store.selectedVisuals.map { ($0.id, store.frame(of: $0)) })
                }
                guard let origin = dragOrigin, let mine = origin[spec.id] else { return }
                var dx = g.translation.width / scale, dy = g.translation.height / scale
                if NSEvent.modifierFlags.contains(.shift) { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
                var moved = mine; moved.x += dx; moved.y += dy
                let snap = Snapping.snap(moved, others: store.currentPage.visuals.filter { origin[$0.id] == nil && !$0.isHidden }.map(store.frame(of:)),
                                         page: store.canvasSize, grid: store.snapToGrid ? 8 : nil,
                                         disabled: NSEvent.modifierFlags.contains(.command))
                guides = snap.guides
                dx += snap.frame.x - moved.x; dy += snap.frame.y - moved.y
                var frames: [UUID: Frame] = [:]
                for (id, f) in origin { var n = f; n.x += dx; n.y += dy; frames[id] = n }
                store.setFrames(frames, name: "Move", coalesce: "move")
            }
            .onEnded { _ in dragOrigin = nil; guides = [] }
    }

    private func resize(_ handle: SelectionChrome.Handle, _ t: CGSize, _ ended: Bool) {
        guard !locked else { return }
        if resizeOrigin == nil { resizeOrigin = store.frame(of: spec) }
        guard let o = resizeOrigin else { return }
        var f = o
        let dx = t.width / scale, dy = t.height / scale
        let minW = 40.0, minH = 24.0
        if handle.left { let w = max(minW, o.width - dx); f.x = o.x + o.width - w; f.width = w }
        if handle.right { f.width = max(minW, o.width + dx) }
        if handle.top { let h = max(minH, o.height - dy); f.y = o.y + o.height - h; f.height = h }
        if handle.bottom { f.height = max(minH, o.height + dy) }
        if NSEvent.modifierFlags.contains(.shift), o.height > 0, handle.isCorner {
            let ratio = o.width / o.height
            f.height = f.width / ratio
            if handle.top { f.y = o.y + o.height - f.height }
        }
        if store.snapToGrid, !NSEvent.modifierFlags.contains(.command) {
            let g = 8.0
            if handle.right { f.width = ((f.x + f.width) / g).rounded() * g - f.x }
            if handle.bottom { f.height = ((f.y + f.height) / g).rounded() * g - f.y }
            if handle.left { let r = f.x + f.width; f.x = (f.x / g).rounded() * g; f.width = r - f.x }
            if handle.top { let b = f.y + f.height; f.y = (f.y / g).rounded() * g; f.height = b - f.y }
        }
        store.setFrames([spec.id: f], name: "Resize", coalesce: "resize")
        if ended { resizeOrigin = nil }
    }
}

/// Snap a moving frame to the grid, the page, and other visuals' edges and centres.
enum Snapping {
    static func snap(_ f: Frame, others: [Frame], page: PageSize, grid: Double?, disabled: Bool) -> (frame: Frame, guides: [SnapGuide]) {
        guard !disabled else { return (f, []) }
        var out = f
        var guides: [SnapGuide] = []
        let tolerance = 5.0
        var xs: [Double] = [0, page.width / 2, page.width], ys: [Double] = [0, page.height / 2, page.height]
        for o in others { xs += [o.x, o.x + o.width / 2, o.x + o.width]; ys += [o.y, o.y + o.height / 2, o.y + o.height] }
        func best(_ anchors: [Double], _ lines: [Double]) -> (delta: Double, line: Double)? {
            var result: (Double, Double)?
            for a in anchors { for l in lines where abs(l - a) <= tolerance {
                if result == nil || abs(l - a) < abs(result!.0) { result = (l - a, l) }
            } }
            return result
        }
        if let b = best([f.x, f.x + f.width / 2, f.x + f.width], xs) {
            out.x += b.delta; guides.append(SnapGuide(vertical: true, position: b.line))
        } else if let grid { out.x = (f.x / grid).rounded() * grid }
        if let b = best([f.y, f.y + f.height / 2, f.y + f.height], ys) {
            out.y += b.delta; guides.append(SnapGuide(vertical: false, position: b.line))
        } else if let grid { out.y = (f.y / grid).rounded() * grid }
        return (out, guides)
    }
}

/// Selection outline with eight resize handles. Sizes are divided by `scale` so they stay constant on screen.
struct SelectionChrome: View {
    struct Handle: Hashable {
        var left = false, right = false, top = false, bottom = false
        var isCorner: Bool { (left || right) && (top || bottom) }
        static let all: [Handle] = [
            .init(left: true, top: true), .init(top: true), .init(right: true, top: true), .init(left: true),
            .init(right: true), .init(left: true, bottom: true), .init(bottom: true), .init(right: true, bottom: true),
        ]
    }
    let frame: Frame
    let scale: Double
    let single: Bool
    let locked: Bool
    let onResize: (Handle, CGSize, Bool) -> Void

    var body: some View {
        let s = 8 / scale
        ZStack(alignment: .topLeading) {
            // The border itself is a move target (a thin ring, so inner interactions stay live).
            Rectangle().strokeBorder(Color.accentColor, lineWidth: 1.5 / scale)
                .contentShape(Rectangle().stroke(lineWidth: 10 / scale))
            if single && !locked {
                ForEach(Handle.all, id: \.self) { h in
                    Circle().fill(.white)
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5 / scale))
                        .frame(width: s, height: s)
                        .contentShape(Rectangle().inset(by: -6 / scale))
                        .position(x: h.left ? 0 : (h.right ? frame.width : frame.width / 2),
                                  y: h.top ? 0 : (h.bottom ? frame.height : frame.height / 2))
                        .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { onResize(h, $0.translation, false) }
                            .onEnded { onResize(h, $0.translation, true) })
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
    }
}

/// The quiet strip above a visual: a grip to move it, drill controls, focus and more.
struct VisualHeader: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec
    let scale: Double
    let moveGesture: AnyGesture<Void>

    var body: some View {
        let levels = spec.fields(.category).count
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 26, height: 22).contentShape(Rectangle())
                .gesture(moveGesture).help("Drag to move")
            if levels > 1 {
                IconButton("arrow.up", help: "Drill up") { store.drill(.up, in: spec.id) }.disabled(spec.drillLevel == 0)
                IconButton("arrow.down.to.line", help: "Go to the next level") { store.drill(.down(nil), in: spec.id) }
                    .disabled(spec.drillLevel >= levels - 1)
                IconButton("arrow.triangle.branch", help: "Expand all down one level") { store.drill(.expandAll, in: spec.id) }
                    .disabled(spec.drillLevel >= levels - 1)
            }
            if !spec.type.isPageElement {
                if !(store.filters(for: spec, on: store.currentPage).isEmpty) {
                    Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).help("Filters affect this visual")
                }
                IconButton("arrow.up.left.and.arrow.down.right", help: "Focus mode") { store.focusVisualID = spec.id }
            }
            if let accessory = Features.visualHeaderAccessory?(spec, store) { accessory }
            Menu {
                VisualContextMenu(spec: spec)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium)).frame(width: 26, height: 22)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More options")
        }
        .padding(.horizontal, 3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Design.Palette.hairline))
        .scaleEffect(1 / scale, anchor: .bottomTrailing)
    }
}

/// Filter / highlight / none chooser shown on every other visual while editing interactions.
struct InteractionPicker: View {
    @EnvironmentObject var store: DocumentStore
    let source: UUID
    let target: VisualSpec

    var body: some View {
        let current = store.interaction(from: source, to: target, on: store.currentPage)
        HStack(spacing: 2) {
            button(.filter, "line.3.horizontal.decrease.circle", "Filter", current)
            if DocumentStore.highlightable.contains(target.type) {
                button(.highlight, "chart.bar.fill", "Highlight", current)
            }
            button(.none, "nosign", "None", current)
        }
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
    private func button(_ mode: InteractionMode, _ symbol: String, _ help: String, _ current: InteractionMode) -> some View {
        IconButton(symbol, help: help, isOn: current == mode) {
            store.updatePage(name: "Edit Interactions", invalidates: .visuals(nil)) { p in
                var m = p.interactions[source] ?? [:]
                m[target.id] = mode
                p.interactions[source] = m
            }
        }
    }
}

struct VisualContextMenu: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        Button("Copy") { ensureSelected(); store.copySelection() }
        Button("Cut") { ensureSelected(); store.cutSelection() }
        Button("Duplicate") { ensureSelected(); store.duplicateSelection() }
        Button("Delete", role: .destructive) { ensureSelected(); store.deleteSelection() }
        Divider()
        if !spec.type.isPageElement {
            Button("Focus Mode") { store.focusVisualID = spec.id }
            Button("Show as a Table") { store.showAsTableID = spec.id }
            Button("Copy Visual as Image") { VisualExport.copyImage(of: spec, store: store) }
            Menu("Export Data") {
                Button("CSV…") { VisualExport.exportData(of: spec, store: store, format: "csv") }
                Button("Excel…") { VisualExport.exportData(of: spec, store: store, format: "xlsx") }
                Button("JSON…") { VisualExport.exportData(of: spec, store: store, format: "json") }
            }
            Button(store.editInteractionsFor == spec.id ? "Done Editing Interactions" : "Edit Interactions") {
                store.editInteractionsFor = store.editInteractionsFor == spec.id ? nil : spec.id
            }
            Divider()
        }
        Button("Format Painter") { store.formatPainterSource = spec.id }
        Menu("Arrange") {
            Button("Bring to Front") { ensureSelected(); store.reorder(.front) }
            Button("Bring Forward") { ensureSelected(); store.reorder(.forward) }
            Button("Send Backward") { ensureSelected(); store.reorder(.backward) }
            Button("Send to Back") { ensureSelected(); store.reorder(.back) }
        }
        if store.selection.count > 1 { Button("Group") { store.groupSelection() } }
        if spec.groupID != nil { Button("Ungroup") { ensureSelected(); store.ungroupSelection() } }
        Button(spec.isLocked ? "Unlock" : "Lock") {
            store.updateVisual(spec.id, name: "Lock", invalidates: .layout) { $0.isLocked.toggle() }
        }
        Button("Hide") { store.updateVisual(spec.id, name: "Hide Visual", invalidates: .layout) { $0.isHidden = true } }
    }
    private func ensureSelected() {
        if !store.selection.contains(spec.id) { store.selection = store.withGroupMembers([spec.id]) }
    }
}

/// Shown on an empty page: what to do first, said once, quietly.
struct StartSurface: View {
    @EnvironmentObject var store: DocumentStore
    var body: some View {
        let hasData = !store.model.tables.isEmpty
        VStack(spacing: Design.Space.l) {
            Image(systemName: hasData ? "square.grid.2x2" : "cylinder.split.1x2")
                .font(.system(size: 40, weight: .ultraLight)).foregroundStyle(.tertiary)
            Text(hasData ? "Build a visual" : "Add data to begin")
                .font(.system(size: 22, weight: .semibold)).foregroundStyle(store.theme.foregroundColor)
            Text(hasData ? "Drag a field here, or choose a visual from the toolbar."
                         : "Connect to a file, a database, or your Microsoft account.")
                .font(Design.Typeface.body).foregroundStyle(store.theme.secondaryColor)
            if !hasData {
                HStack(spacing: Design.Space.m) {
                    Button("Get Data…") { AppCommands.run("data.get", store) }.buttonStyle(.borderedProminent)
                    Button("Try Sample Data") { AppCommands.run("data.sample", store) }
                    Button("Open…") { AppCommands.run("file.open", store) }
                }
                .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
