import SwiftUI
import AppKit
import FacetDesign

/// The right-hand panes: Filters, the switchable extra panes, Visualizations (Build and Format) and Data,
/// in that order. Each column collapses to a narrow labelled strip. The layout comes from `PaneDock`;
/// the panes themselves come from `Features.pane`, so whatever a feature registers is what shows.
struct PaneDockView: View {
    @EnvironmentObject var store: DocumentStore
    @ObservedObject var shell: ShellState
    /// Window width to the right of the view rail.
    let available: CGFloat

    var body: some View {
        let columns = shell.dock.columns(for: store.view, available: Double(available))
        HStack(spacing: 0) {
            ForEach(columns, id: \.slot) { column in
                Hairline(vertical: true)
                if column.collapsed {
                    CollapsedPaneStrip(slot: column.slot, title: title(of: column.slot), symbol: symbol(of: column.slot)) {
                        shell.dock.setCollapsed(column.slot, false)
                    }
                } else {
                    PaneColumn(slot: column.slot, width: CGFloat(column.width), shell: shell)
                }
            }
        }
        .background(Design.Palette.surface)
    }

    private func activePane(of slot: DockSlot) -> InspectorPane? {
        shell.dock.pane(in: slot, view: store.view).flatMap(InspectorPane.init(rawValue:))
    }
    private func title(of slot: DockSlot) -> String {
        slot == .extras ? (activePane(of: slot)?.title ?? slot.title) : slot.title
    }
    private func symbol(of slot: DockSlot) -> String {
        switch slot {
        case .filters: return InspectorPane.filters.symbol
        case .visualizations: return InspectorPane.build.symbol
        case .data: return InspectorPane.data.symbol
        case .extras: return activePane(of: slot)?.symbol ?? "sidebar.right"
        }
    }
}

/// One expanded column: a slim header (title, pane switcher, collapse) over the pane.
private struct PaneColumn: View {
    @EnvironmentObject var store: DocumentStore
    let slot: DockSlot
    let width: CGFloat
    @ObservedObject var shell: ShellState

    private var pane: InspectorPane? {
        shell.dock.pane(in: slot, view: store.view).flatMap(InspectorPane.init(rawValue:))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if let pane {
                Features.pane(pane, store).environmentObject(store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(pane)
            } else {
                EmptyState(systemImage: "sidebar.right", title: slot.title)
            }
        }
        .frame(width: width)
        .background(Design.Palette.surface)
        .overlay(alignment: .leading) { PaneResizeHandle(slot: slot, width: width, shell: shell) }
    }

    private var header: some View {
        HStack(spacing: Design.Space.xxs) {
            switch slot {
            case .filters, .data:
                SectionLabel(slot.title)
            case .visualizations:
                SectionLabel(slot.title)
                ForEach([InspectorPane.build, .format]) { p in
                    IconButton(p.symbol, help: p == .build ? "Build visual" : "Format visual", isOn: pane == p) {
                        shell.dock.reveal(p.rawValue)
                    }
                }
            case .extras:
                let open = shell.dock.extras(for: store.view).compactMap(InspectorPane.init(rawValue:))
                if open.count > 1 {
                    ForEach(open) { p in
                        IconButton(p.symbol, help: "\(p.title) pane", isOn: pane == p) { shell.dock.reveal(p.rawValue) }
                    }
                    Spacer(minLength: 0)
                } else {
                    SectionLabel(pane?.title ?? slot.title)
                }
                if let pane {
                    IconButton("xmark", help: "Close the \(pane.title) pane") { shell.dock.close(pane.rawValue) }
                }
            }
            IconButton("chevron.right.2", help: "Collapse the \(collapseName) pane") {
                shell.dock.setCollapsed(slot, true)
            }
        }
        .padding(.leading, Design.Space.m).padding(.trailing, Design.Space.xs)
        .frame(height: ShellMetrics.paneHeaderHeight)
    }

    private var collapseName: String { slot == .extras ? (pane?.title ?? slot.title) : slot.title }
}

/// A collapsed column: a narrow strip with the pane's icon and its name reading downwards.
private struct CollapsedPaneStrip: View {
    let slot: DockSlot
    let title: String
    let symbol: String
    let expand: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: expand) {
            VStack(spacing: Design.Space.s) {
                Image(systemName: "chevron.left.2").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(height: ShellMetrics.paneHeaderHeight - Design.Space.s)
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary)
                Text(title).font(Design.Typeface.captionStrong).foregroundStyle(.secondary).lineLimit(1)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: CGFloat(PaneDock.stripWidth), height: 132)
                Spacer(minLength: 0)
            }
            .padding(.top, Design.Space.xs)
            .frame(width: CGFloat(PaneDock.stripWidth))
            .frame(maxHeight: .infinity)
            .background(hovering ? Design.Palette.fill : Design.Palette.surface)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Expand the \(title) pane")
        .accessibilityLabel("Expand the \(title) pane")
    }
}

/// Drag the leading edge of a pane to resize it.
private struct PaneResizeHandle: View {
    let slot: DockSlot
    let width: CGFloat
    @ObservedObject var shell: ShellState
    @State private var startWidth: CGFloat?

    var body: some View {
        Color.clear
            .frame(width: Design.Space.s)
            .contentShape(Rectangle())
            .offset(x: -Design.Space.xs)
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        shell.dock.setWidth(Double(start - value.translation.width), of: slot)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize the pane")
    }
}
