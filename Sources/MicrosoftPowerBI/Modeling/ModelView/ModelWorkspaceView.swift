import SwiftUI
import FacetCore
import FacetDesign

/// The Model view workspace: the diagram with its toolbar and layout tabs, and beside it the
/// Properties panel and the model explorer.
struct ModelWorkspaceView: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject private var modeling: ModelingState
    @StateObject private var controller: ModelCanvasController

    /// Width of the Properties / explorer column.
    private static let sideWidth: CGFloat = 300

    init(store: DocumentStore) {
        _modeling = ObservedObject(wrappedValue: store.modeling)
        _controller = StateObject(wrappedValue: ModelCanvasController(store: store))
    }

    var body: some View {
        if store.model.tables.isEmpty {
            emptyState
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    Hairline()
                    ModelCanvasView(modeling: modeling, controller: controller)
                    Hairline()
                    ModelLayoutTabs(modeling: modeling)
                }
                if modeling.propertiesVisible || modeling.explorerVisible {
                    Hairline(vertical: true)
                    side.frame(width: Self.sideWidth)
                }
            }
            .background(Design.Palette.surface)
            .onAppear(perform: fixLayout)
            .onChange(of: store.model.layouts.map(\.id)) { _, _ in fixLayout() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Design.Space.m) {
            EmptyState(systemImage: "rectangle.3.group", title: "No tables yet",
                       message: "Connect to data or load the sample, then relate its tables here.")
                .frame(maxHeight: 150)
            Button("Get Data…") { AppCommands.run("data.get", store) }.buttonStyle(.borderedProminent)
            Button("Load Sample Data") { AppCommands.run("data.sample", store) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Design.Palette.surface)
    }

    /// Keeps the tab on screen pointing at a layout that exists (after undo or a deleted layout).
    private func fixLayout() {
        if let id = modeling.layoutID, !store.model.layouts.contains(where: { $0.id == id }) { modeling.layoutID = nil }
    }

    @ViewBuilder
    private var side: some View {
        if modeling.propertiesVisible, modeling.explorerVisible {
            VSplitView {
                ModelPropertiesPanel(modeling: modeling).frame(minHeight: 160)
                ModelObjectExplorer(modeling: modeling, controller: controller).frame(minHeight: 160)
            }
        } else if modeling.propertiesVisible {
            ModelPropertiesPanel(modeling: modeling)
        } else {
            ModelObjectExplorer(modeling: modeling, controller: controller)
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        let layout = ModelLayouts.current(store.model, id: modeling.layoutID)
        let addable = ModelLayouts.addable(store.model, layout: layout)
        return HStack(spacing: Design.Space.xs) {
            Button { ModelLayoutOps.autoArrange(store, layout: modeling.layoutID); controller.fit() } label: {
                Label("Auto arrange", systemImage: "rectangle.3.group")
            }
            .help("Arrange the tables as a star: fact tables in the middle, dimensions around them")
            Button { AppCommands.run("model.relationships", store) } label: { Label("Manage relationships", systemImage: "arrow.left.arrow.right") }
                .help("List, add and remove relationships")
                .disabled(store.model.tables.count < 2)
            if !layout.showsAllTables {
                Menu {
                    Button("All tables") { ModelLayoutOps.addTables(store, addable.map(\.name), layout: modeling.layoutID) }
                    Divider()
                    ForEach(addable) { t in
                        Button(t.name) { ModelLayoutOps.addTables(store, [t.name], layout: modeling.layoutID) }
                    }
                } label: {
                    Label("Add table", systemImage: "plus.rectangle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(addable.isEmpty)
                .help(addable.isEmpty ? "Every table is already on this layout" : "Add a table to this layout")
            }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, Design.Space.xs)
            IconButton("rectangle.compress.vertical", help: "Collapse all tables") { ModelLayoutOps.setAllCollapsed(store, true, layout: modeling.layoutID) }
            IconButton("rectangle.expand.vertical", help: "Expand all tables") { ModelLayoutOps.setAllCollapsed(store, false, layout: modeling.layoutID) }
            Spacer(minLength: Design.Space.s)
            IconButton("minus.magnifyingglass", help: "Zoom out") { controller.zoom(by: 1 / 1.25) }
            Button { controller.resetZoom() } label: {
                Text("\(Int((modeling.zoom * 100).rounded()))%").font(Design.Typeface.caption).monospacedDigit().frame(minWidth: 38)
            }
            .buttonStyle(.plain)
            .help("Zoom to 100%")
            IconButton("plus.magnifyingglass", help: "Zoom in") { controller.zoom(by: 1.25) }
            IconButton("arrow.up.left.and.arrow.down.right", help: "Fit the diagram to the window") { controller.fit() }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, Design.Space.xs)
            IconButton("slider.horizontal.3", help: modeling.propertiesVisible ? "Hide Properties" : "Show Properties", isOn: modeling.propertiesVisible) {
                modeling.propertiesVisible.toggle()
            }
            IconButton("list.bullet.indent", help: modeling.explorerVisible ? "Hide the model explorer" : "Show the model explorer", isOn: modeling.explorerVisible) {
                modeling.explorerVisible.toggle()
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
    }
}

/// The layout tabs under the diagram: "All tables", the user's layouts, and a button for a new one.
struct ModelLayoutTabs: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var modeling: ModelingState
    @State private var hovering: UUID?

    var body: some View {
        let tabs = ModelLayouts.tabs(store.model)
        let current = ModelLayouts.current(store.model, id: modeling.layoutID).id
        return HStack(spacing: Design.Space.xxs) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Design.Space.xxs) {
                    ForEach(tabs) { tab in self.tab(tab, active: tab.id == current) }
                }
            }
            IconButton("plus", help: "New layout") { ModelLayoutOps.addLayout(store) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Space.s)
        .frame(height: 30)
        .background(Design.Palette.surface)
    }

    private func tab(_ layout: ModelLayout, active: Bool) -> some View {
        Text(layout.name).font(Design.Typeface.caption).lineLimit(1)
            .foregroundStyle(active ? .primary : .secondary)
            .padding(.horizontal, Design.Space.m)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .fill(active ? Design.Palette.fillStrong : (hovering == layout.id ? Design.Palette.fill : .clear)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 ? layout.id : nil }
            .onTapGesture(count: 2) { if !layout.showsAllTables { rename(layout) } }
            .onTapGesture { modeling.layoutID = layout.id }
            .contextMenu {
                if layout.showsAllTables {
                    Text("“\(layout.name)” always shows every table")
                } else {
                    Button("Rename…") { rename(layout) }
                    Button("Delete", role: .destructive) { ModelLayoutOps.deleteLayout(store, id: layout.id) }
                }
            }
            .help(layout.showsAllTables ? "Every table in the model" : "\(layout.name) — double-click to rename")
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private func rename(_ layout: ModelLayout) {
        guard let name = ModelPrompt.text(title: "Rename layout", value: layout.name) else { return }
        ModelLayoutOps.renameLayout(store, id: layout.id, to: name)
    }
}
