import SwiftUI
import FacetCore
import FacetDesign

/// The rules of the phone layout: where visuals land, how big they are, and which formatting they show.
/// The phone canvas is 360 pt wide and grows downwards as visuals are added (readers scroll it).
enum MobileLayout {
    static let width = PageSize.phone.width
    static let minimumHeight = PageSize.phone.height
    static let margin = 8.0
    static let grid = 8.0
    static let dragPrefix = "facet-visual:"

    static func dragPayload(for id: UUID) -> String { dragPrefix + id.uuidString }
    static func draggedVisual(_ payload: String) -> UUID? {
        guard payload.hasPrefix(dragPrefix) else { return nil }
        return UUID(uuidString: String(payload.dropFirst(dragPrefix.count)))
    }

    /// Visuals in the order a reader meets them on the desktop page: row by row, left to right.
    /// A visual belongs to the current row when its top is above the middle of the row's first visual.
    static func readingOrder(_ visuals: [VisualSpec]) -> [VisualSpec] {
        let byTop = visuals.sorted { ($0.frame.y, $0.frame.x) < ($1.frame.y, $1.frame.x) }
        var rows: [[VisualSpec]] = []
        for v in byTop {
            if let first = rows.last?.first, v.frame.y < first.frame.y + first.frame.height / 2 {
                rows[rows.count - 1].append(v)
            } else {
                rows.append([v])
            }
        }
        return rows.flatMap { $0.sorted { $0.frame.x < $1.frame.x } }
    }

    static func snap(_ value: Double) -> Double { (value / grid).rounded() * grid }

    /// The size a desktop visual takes on the phone: full width between the margins, height keeping the
    /// desktop aspect ratio, between 48 and 320 pt, on the grid.
    static func fittedSize(for frame: Frame) -> (width: Double, height: Double) {
        let w = width - margin * 2
        let ratio = frame.width > 0 ? frame.height / frame.width : 0.6
        return (w, min(320, max(48, snap(w * ratio))))
    }

    /// The lowest occupied edge of the phone layout (0 when it is empty).
    static func bottom(of page: Page) -> Double {
        page.visuals.compactMap { $0.mobileFrame.map { $0.y + $0.height } }.max() ?? 0
    }

    /// Height of the phone canvas: one screen, or as tall as the content plus a margin.
    static func canvasHeight(_ page: Page) -> Double { max(minimumHeight, bottom(of: page) + margin) }

    /// Frames for `ids` stacked under what is already placed, in the order given. Already placed visuals are skipped.
    static func stacked(_ ids: [UUID], on page: Page) -> [UUID: Frame] {
        var y = bottom(of: page) + margin
        var out: [UUID: Frame] = [:]
        for id in ids {
            guard out[id] == nil, let v = page.visual(id), v.mobileFrame == nil else { continue }
            let size = fittedSize(for: v.frame)
            out[id] = Frame(x: margin, y: y, width: size.width, height: size.height)
            y += size.height + margin
        }
        return out
    }

    /// Auto-create: every visible visual not yet on the phone, in reading order, stacked under the rest.
    static func autoCreate(_ page: Page) -> [UUID: Frame] {
        stacked(readingOrder(page.visuals.filter { !$0.isHidden && $0.mobileFrame == nil }).map(\.id), on: page)
    }

    /// The frame for a visual dropped with its centre at `point`: fitted size, snapped to the grid,
    /// kept inside the canvas horizontally and below its top.
    static func dropFrame(for visual: VisualSpec, at point: CGPoint) -> Frame {
        let size = fittedSize(for: visual.frame)
        let x = min(max(0, snap(point.x - size.width / 2)), max(0, width - size.width))
        // A full-width visual has one sensible x: centred between the margins.
        let fx = size.width >= width - margin * 2 ? margin : x
        return Frame(x: fx, y: max(0, snap(point.y - size.height / 2)), width: size.width, height: size.height)
    }

    /// The visual as the phone shows it: its mobile formatting layered over the desktop formatting.
    static func effectiveSpec(_ v: VisualSpec) -> VisualSpec {
        guard let overrides = v.mobileFormat, !overrides.isEmpty else { return v }
        var out = v
        for (card, properties) in overrides {
            for (key, value) in properties { out.setFmt(card, key, value) }
        }
        return out
    }

    /// One formatting property the phone layout can override.
    struct Option: Identifiable {
        enum Kind { case toggle, number(ClosedRange<Double>) }
        var card: String, key: String, label: String, kind: Kind
        var id: String { "\(card).\(key)" }
    }
    static let options: [Option] = [
        Option(card: "title", key: "show", label: "Title", kind: .toggle),
        Option(card: "title", key: "size", label: "Title size", kind: .number(8...40)),
        Option(card: "legend", key: "show", label: "Legend", kind: .toggle),
        Option(card: "dataLabels", key: "show", label: "Data labels", kind: .toggle),
        Option(card: "background", key: "show", label: "Background", kind: .toggle),
        Option(card: "border", key: "show", label: "Border", kind: .toggle),
        Option(card: "padding", key: "all", label: "Padding", kind: .number(0...40)),
    ]

    /// `bag` with one override set (or removed when `value` is nil); nil when nothing is left.
    static func setting(_ bag: FormatBag?, _ card: String, _ key: String, _ value: JSONValue?) -> FormatBag? {
        var out = bag ?? [:]
        var c = out[card] ?? [:]
        c[key] = value
        out[card] = c.isEmpty ? nil : c
        return out.isEmpty ? nil : out
    }
}

extension DocumentStore {
    /// Place visuals on the phone canvas, stacked under what is already there.
    func addToMobileLayout(_ ids: [UUID]) {
        let frames = MobileLayout.stacked(ids, on: currentPage)
        guard !frames.isEmpty else { return }
        applyMobileFrames(frames, name: frames.count == 1 ? "Add to Mobile Layout" : "Add All to Mobile Layout")
    }
    /// Place every visible visual that is not on the phone yet, in reading order.
    func autoCreateMobileLayout() {
        let frames = MobileLayout.autoCreate(currentPage)
        guard !frames.isEmpty else {
            status = StatusMessage(kind: .info, text: "Every visible visual is already in the mobile layout.")
            return
        }
        applyMobileFrames(frames, name: "Auto-create Mobile Layout")
    }
    /// Place one visual where it was dropped on the phone canvas (moves it when already placed).
    func placeOnMobileLayout(_ id: UUID, at point: CGPoint) {
        guard let v = currentPage.visual(id) else { return }
        applyMobileFrames([id: MobileLayout.dropFrame(for: v, at: point)], name: "Add to Mobile Layout")
        selection = [id]
    }
    private func applyMobileFrames(_ frames: [UUID: Frame], name: String) {
        updatePage(name: name) { p in
            for i in p.visuals.indices {
                if let f = frames[p.visuals[i].id] { p.visuals[i].mobileFrame = f }
            }
            p.hasMobileLayout = p.visuals.contains { $0.mobileFrame != nil }
        }
    }
    func removeFromMobileLayout(_ ids: [UUID]) {
        let set = Set(ids)
        guard currentPage.visuals.contains(where: { set.contains($0.id) && $0.mobileFrame != nil }) else { return }
        updatePage(name: "Remove from Mobile Layout") { p in
            for i in p.visuals.indices where set.contains(p.visuals[i].id) { p.visuals[i].mobileFrame = nil }
            p.hasMobileLayout = p.visuals.contains { $0.mobileFrame != nil }
        }
        selection.subtract(set)
    }
    /// Set or clear (nil) one phone-only formatting override.
    func setMobileFormat(_ id: UUID, _ card: String, _ key: String, _ value: JSONValue?) {
        updateVisual(id, name: "Mobile Formatting", coalesce: "mobile-format-\(id)-\(card).\(key)", invalidates: .layout) {
            $0.mobileFormat = MobileLayout.setting($0.mobileFormat, card, key, value)
        }
    }
    func resetMobileFormat(_ id: UUID) {
        guard visual(id)?.mobileFormat != nil else { return }
        updateVisual(id, name: "Reset Mobile Formatting", invalidates: .layout) { $0.mobileFormat = nil }
    }
}

/// The "Page visuals" list beside the phone canvas: drag a visual onto the canvas (or press +) to
/// place it, remove it again, auto-create the layout, and format the selected visual for phones.
struct MobileVisualsPanel: View {
    @EnvironmentObject var store: DocumentStore

    var body: some View {
        let page = store.currentPage
        let ordered = MobileLayout.readingOrder(page.visuals.filter { !$0.isHidden })
        let placed = ordered.filter { $0.mobileFrame != nil }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Design.Space.xs) {
                Text("Page visuals").font(Design.Typeface.headline)
                Text("\(placed.count)/\(ordered.count)").font(Design.Typeface.caption).foregroundStyle(.secondary).monospacedDigit()
                Spacer(minLength: 0)
                IconButton("wand.and.stars", help: "Auto-create: add every visual in reading order") { store.autoCreateMobileLayout() }
                    .disabled(placed.count == ordered.count)
                IconButton("trash", help: "Remove every visual from the mobile layout") {
                    store.removeFromMobileLayout(placed.map(\.id))
                }
                .disabled(placed.isEmpty)
            }
            .padding(.horizontal, Design.Space.m).frame(height: 40)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if ordered.isEmpty {
                        PaneNote("This page has no visuals yet. Switch off Mobile layout to build the page first.")
                            .padding(Design.Space.m)
                    }
                    ForEach(ordered) { v in row(v) }
                    if let v = store.selectedVisual, v.mobileFrame != nil {
                        MobileFormatSection(spec: v)
                    }
                }
            }
        }
        .frame(width: 240)
        .background(Design.Palette.surface)
    }

    private func row(_ v: VisualSpec) -> some View {
        let isPlaced = v.mobileFrame != nil
        return HStack(spacing: Design.Space.s) {
            Image(systemName: VisualCatalog.symbol(for: v.type)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(v.name).font(Design.Typeface.body).lineLimit(1)
                .foregroundStyle(isPlaced ? .secondary : .primary)
            Spacer(minLength: 0)
            if isPlaced {
                IconButton("minus.circle", help: "Remove \(v.name) from the mobile layout") { store.removeFromMobileLayout([v.id]) }
            } else {
                IconButton("plus.circle", help: "Add \(v.name) to the mobile layout") { store.addToMobileLayout([v.id]) }
            }
        }
        .padding(.horizontal, Design.Space.m).frame(height: 28)
        .background(store.selection.contains(v.id) ? Design.Palette.fillStrong : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if isPlaced { store.selection = [v.id] } }
        .draggable(MobileLayout.dragPayload(for: v.id))
        .help(isPlaced ? "\(v.name) is in the mobile layout" : "Drag \(v.name) onto the phone")
        .accessibilityLabel("\(v.name), \(isPlaced ? "in the mobile layout" : "not in the mobile layout")")
    }
}

/// Phone-only formatting for one visual. Each property follows the desktop formatting until overridden.
private struct MobileFormatSection: View {
    @EnvironmentObject var store: DocumentStore
    let spec: VisualSpec

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            Hairline()
            HStack {
                Text("Mobile formatting").font(Design.Typeface.bodyStrong)
                Spacer(minLength: 0)
                Button("Reset") { store.resetMobileFormat(spec.id) }
                    .controlSize(.small).buttonStyle(.link).disabled(spec.mobileFormat == nil)
                    .help("Use the desktop formatting on phones")
            }
            ForEach(MobileLayout.options) { option in
                PropertyRow(option.label) { control(option) }
            }
            PaneNote("Changes here apply to the phone layout only. Everything else follows the desktop formatting.")
        }
        .padding(.horizontal, Design.Space.m).padding(.vertical, Design.Space.s)
    }

    @ViewBuilder private func control(_ option: MobileLayout.Option) -> some View {
        let current = spec.mobileFormat?[option.card]?[option.key]
        switch option.kind {
        case .toggle:
            Picker(option.label, selection: Binding(get: { current?.boolValue.map { $0 ? "on" : "off" } ?? "" }, set: { choice in
                store.setMobileFormat(spec.id, option.card, option.key, choice.isEmpty ? nil : .bool(choice == "on"))
            })) {
                Text("As desktop").tag("")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            .labelsHidden().controlSize(.small)
        case .number(let range):
            CommitTextField("As desktop", text: current?.doubleValue.map { String(format: "%g", $0) } ?? "") { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                let value = Double(trimmed).map { min(range.upperBound, max(range.lowerBound, $0)) }
                store.setMobileFormat(spec.id, option.card, option.key, value.map(JSONValue.number))
            }
            .help("\(Int(range.lowerBound))–\(Int(range.upperBound)); leave empty to follow the desktop")
        }
    }
}
