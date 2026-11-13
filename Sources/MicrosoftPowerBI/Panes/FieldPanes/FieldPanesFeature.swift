import SwiftUI
import FacetCore

/// The object a Data-pane context-menu command applies to.
///
/// Contract with the modeling feature: before running a `model.*` command from a context menu the
/// Data pane sets `table` (always, for table-, column- and measure-level commands) and `field`
/// (for column and measure commands; nil for table commands). The command reads them when it runs.
@MainActor
enum FieldPaneContext {
    static var table: String?
    static var field: FieldRef?

    /// Set the target, then run a command owned by another feature.
    static func run(_ id: String, table: String?, field: FieldRef? = nil, _ store: DocumentStore) {
        self.table = table
        self.field = field
        // The target is for this one command; a later ribbon or menu command must not inherit it.
        defer { self.table = nil; self.field = nil }
        AppCommands.run(id, store)
    }
}

/// Data, Build and Filters panes.
@MainActor
enum FieldPanesFeature {
    static func register() {
        Features.paneBuilders[.data] = { _ in AnyView(DataPane()) }
        Features.paneBuilders[.build] = { _ in AnyView(BuildPane()) }
        Features.paneBuilders[.filters] = { _ in AnyView(FiltersPane()) }
    }
}
