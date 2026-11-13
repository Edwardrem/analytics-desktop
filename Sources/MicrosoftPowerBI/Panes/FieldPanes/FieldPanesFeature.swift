import SwiftUI
import FacetCore

/// The object a Data-pane context-menu command applies to.
///
/// Contract with the modeling feature: before running a `model.*` command from a context menu the
/// Data pane sets `table` (always, for table-, column- and measure-level commands) and `field`
/// (for column and measure commands; nil for table commands). The command reads them while it
/// runs, through `ModelingTarget`. The context belongs to one document and lasts only for that
/// command: it is cleared when the command returns, so a command that opens a dialog must take
/// its target when it runs, not later.
@MainActor
enum FieldPaneContext {
    static var table: String?
    static var field: FieldRef?
    private(set) static weak var store: DocumentStore?

    /// Set the target, run a command owned by another feature, then clear the target.
    static func run(_ id: String, table: String?, field: FieldRef? = nil, _ store: DocumentStore) {
        self.table = table
        self.field = field
        // The target is for this one command in this document; a later ribbon or menu command must not inherit it.
        self.store = store
        defer { self.table = nil; self.field = nil; self.store = nil }
        AppCommands.run(id, store)
    }

    /// The table in context for `store`, when a command from its Data pane is running.
    static func table(for store: DocumentStore) -> String? { self.store === store ? table : nil }
    static func field(for store: DocumentStore) -> FieldRef? { self.store === store ? field : nil }
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
