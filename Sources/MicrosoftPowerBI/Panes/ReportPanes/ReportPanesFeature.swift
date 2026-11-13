import SwiftUI
import FacetCore
import FacetDesign

/// Bookmarks, Selection, Sync slicers, Performance and Theme panes.
@MainActor
enum ReportPanesFeature {
    static func register() {
        Features.paneBuilders[.bookmarks] = { store in
            AnyView(BookmarksPane(player: ReportPaneRuntime.of(store).player))
        }
        Features.paneBuilders[.selection] = { store in
            _ = ReportPaneRuntime.of(store)
            return AnyView(SelectionPane())
        }
        Features.paneBuilders[.syncSlicers] = { store in
            _ = ReportPaneRuntime.of(store)
            return AnyView(SyncSlicersPane())
        }
        Features.paneBuilders[.performance] = { store in
            AnyView(PerformancePane(autoRefresh: ReportPaneRuntime.of(store).autoRefresh))
        }
        Features.paneBuilders[.theme] = { store in
            AnyView(ThemePane(runtime: ReportPaneRuntime.of(store)).controlSize(.small))
        }
        AppCommands.register(commands)
    }

    /// Menus ask every command whether it is enabled for the frontmost document, which makes this the one
    /// place in this lane that sees each document soon after it opens. Use it to attach the per-document
    /// runtime, so page auto refresh starts for documents saved with it on — even if no pane here is ever shown.
    private static func attached(_ store: DocumentStore) -> Bool {
        _ = ReportPaneRuntime.of(store)
        return true
    }

    static func commands() -> [AppCommand] {
        [
            AppCommand(id: "bookmarks.add", title: "Add Bookmark", menu: .insert, symbol: "bookmark",
                       shortcut: .init("b", modifiers: [.command, .shift]), separatorBefore: true,
                       isEnabled: { attached($0) && $0.view == .report }) { store in
                let id = store.addBookmark()
                store.activeBookmarkID = id
                store.inspector = .bookmarks
                store.inspectorVisible = true
                let name = store.report.bookmarks.first { $0.id == id }?.name ?? "Bookmark"
                store.status = StatusMessage(kind: .success, text: "Added “\(name)”.")
            },
            AppCommand(id: "bookmarks.view", title: "Play Bookmarks", menu: .view, symbol: "play",
                       isEnabled: { !$0.report.bookmarks.isEmpty }, isOn: { ReportPaneRuntime.of($0).player.isActive }) { store in
                let player = ReportPaneRuntime.of(store).player
                if player.isActive { player.stop(); return }
                store.view = .report
                store.inspector = .bookmarks
                store.inspectorVisible = true
                player.start(BookmarkEntry.displayOrder(store.report.bookmarks).map(\.id), startingAt: store.activeBookmarkID)
            },
            AppCommand(id: "page.settings", title: "Page Settings…", menu: .format, symbol: "doc.badge.gearshape", separatorBefore: true,
                       isEnabled: { $0.view == .report }) { store in
                showTheme(store, focus: .page)
            },
            AppCommand(id: "report.settings", title: "Report Settings…", menu: .file, symbol: "gearshape", separatorBefore: true) { store in
                showTheme(store, focus: .reportSettings)
            },
            AppCommand(id: "theme.import", title: "Import Theme…", menu: .file, symbol: "square.and.arrow.down") { ThemeIO.runImport($0) },
            AppCommand(id: "theme.export", title: "Export Theme…", menu: .file, symbol: "square.and.arrow.up") { ThemeIO.runExport($0) },
        ]
    }

    private static func showTheme(_ store: DocumentStore, focus: ReportPaneRuntime.ThemeFocus) {
        store.view = .report
        store.presenting = false
        store.inspector = .theme
        store.inspectorVisible = true
        ReportPaneRuntime.of(store).themeFocus = focus
    }
}
