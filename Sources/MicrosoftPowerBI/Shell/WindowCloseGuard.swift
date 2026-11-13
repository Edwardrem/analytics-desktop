import SwiftUI
import AppKit

/// Asks to save before a document window closes, and releases its store afterwards.
struct WindowCloseGuard: NSViewRepresentable {
    let store: DocumentStore
    let handleID: UUID

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { context.coordinator.attach(to: v.window) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isDocumentEdited = store.isDirty
        if context.coordinator.window == nil { DispatchQueue.main.async { context.coordinator.attach(to: nsView.window) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(store: store, handleID: handleID) }

    final class Coordinator: NSObject, NSWindowDelegate {
        let store: DocumentStore
        let handleID: UUID
        weak var window: NSWindow?
        weak var original: NSWindowDelegate?
        init(store: DocumentStore, handleID: UUID) { self.store = store; self.handleID = handleID }

        func attach(to window: NSWindow?) {
            guard let window, self.window == nil else { return }
            self.window = window
            original = window.delegate
            window.delegate = self
        }
        // Forward everything we don't handle to SwiftUI's own delegate.
        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (original?.responds(to: aSelector) ?? false)
        }
        override func forwardingTarget(for aSelector: Selector!) -> Any? { original }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard MainActor.assumeIsolated({ FileOperations.confirmClose(store) }) else { return false }
            return original?.windowShouldClose?(sender) ?? true
        }
        func windowWillClose(_ notification: Notification) {
            original?.windowWillClose?(notification)
            MainActor.assumeIsolated { StoreRegistry.shared.remove(handleID) }
        }
    }
}
