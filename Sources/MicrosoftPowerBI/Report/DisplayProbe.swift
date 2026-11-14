import SwiftUI
import AppKit

/// Measures the Performance analyzer's "Visual display" time: sits behind a visual while recording
/// and reports when the visual is first drawn after a recorded refresh delivered its results.
struct DisplayProbe: NSViewRepresentable {
    /// The recorded event waiting for the visual to be drawn.
    let token: UUID
    let onDrawn: (UUID, CFAbsoluteTime) -> Void

    func makeNSView(context: Context) -> DisplayProbeView { DisplayProbeView() }

    func updateNSView(_ view: DisplayProbeView, context: Context) {
        view.onDrawn = onDrawn
        view.arm(token)
    }
}

/// A transparent view that asks to be drawn when armed and reports the first draw that follows,
/// once per token. It draws nothing and takes no clicks.
final class DisplayProbeView: NSView {
    var onDrawn: ((UUID, CFAbsoluteTime) -> Void)?
    private(set) var armed: UUID?
    private var reported: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    /// Waits for the next draw to report `token`, unless it was already reported.
    func arm(_ token: UUID) {
        guard token != armed, token != reported else { return }
        armed = token
        needsDisplay = true
    }

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let token = armed else { return }
        armed = nil
        reported = token
        let time = CFAbsoluteTimeGetCurrent()
        // Report after the display pass, not from inside it.
        let callback = onDrawn
        DispatchQueue.main.async { callback?(token, time) }
    }
}
