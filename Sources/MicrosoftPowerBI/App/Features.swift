import SwiftUI
import FacetCore
import FacetDesign

/// The seam between the shell and feature areas. Each feature registers its commands, visuals
/// and file handlers here; the shell asks `Features` for the views it hosts.
@MainActor
enum Features {
    /// View builders, replaced by feature registration. Defaults are quiet placeholders.
    static var queryEditorBuilder: (DocumentStore) -> AnyView = { _ in
        AnyView(EmptyState(systemImage: "wand.and.stars", title: "Power Query Editor"))
    }
    static var settingsBuilder: () -> AnyView = { AnyView(EmptyState(systemImage: "gearshape", title: "Settings").frame(width: 520, height: 320)) }
    static var workspaceBuilders: [WorkspaceView: (DocumentStore) -> AnyView] = [:]
    static var paneBuilders: [InspectorPane: (DocumentStore) -> AnyView] = [:]
    /// Trailing toolbar content (account avatar, share…).
    static var toolbarAccessory: (DocumentStore) -> AnyView = { _ in AnyView(EmptyView()) }
    /// Extra controls in the header of a visual on the canvas (on-object formatting).
    static var visualHeaderAccessory: ((VisualSpec, DocumentStore) -> AnyView)?
    private static var registered = false

    static func registerAll() {
        guard !registered else { return }
        registered = true
        FeatureRegistration.register()
    }

    static func queryEditor(_ store: DocumentStore) -> AnyView { queryEditorBuilder(store) }
    static func settings() -> AnyView { settingsBuilder() }
    static func workspace(_ view: WorkspaceView, _ store: DocumentStore) -> AnyView {
        workspaceBuilders[view]?(store)
            ?? AnyView(EmptyState(systemImage: view.symbol, title: "\(view.title) view"))
    }
    static func pane(_ pane: InspectorPane, _ store: DocumentStore) -> AnyView {
        paneBuilders[pane]?(store) ?? AnyView(EmptyState(systemImage: pane.symbol, title: pane.title))
    }
}
