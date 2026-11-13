import SwiftUI
import FacetCore

/// A native code editor: syntax colouring, completion, auto-indent, bracket pairing, error underlines
/// and optional line numbers. Used for DAX, M, TMDL and script visuals.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var language: LanguageSupport
    var model: SemanticModel = SemanticModel()
    var issues: [ExpressionIssue] = []
    var fontSize: CGFloat = 13
    var showsLineNumbers = false
    var isEditable = true
    /// ⌘↩ (run / commit).
    var onCommit: (() -> Void)?
    /// Esc when no completion list is showing.
    var onCancel: (() -> Void)?
    /// Drops of one custom pasteboard type that the editor hands to its owner instead of inserting.
    var objectDrop: ObjectDrop?

    struct ObjectDrop {
        var type: NSPasteboard.PasteboardType
        /// Receives the dragged data; returns whether the drop was taken.
        var onDrop: (Data) -> Bool
        /// True while such a drag is over the editor.
        var onTargeted: (Bool) -> Void = { _ in }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = objectDrop == nil ? NSTextView.scrollableTextView() : ObjectDropTextView.scrollable()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        tv.string = text
        tv.isEditable = isEditable
        tv.setAccessibilityLabel("\(language.name) editor")
        if showsLineNumbers {
            let ruler = LineNumberRuler(textView: tv)
            scroll.verticalRulerView = ruler
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
        }
        context.coordinator.textView = tv
        if let dropView = tv as? ObjectDropTextView {
            dropView.objectDrop = { [weak coordinator = context.coordinator] in coordinator?.parent.objectDrop }
        }
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.setSelectedRange(NSRange(location: min(sel.location, (text as NSString).length), length: 0))
        }
        tv.isEditable = isEditable
        if tv.font?.pointSize != fontSize { tv.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        context.coordinator.highlight()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: NSTextView?
        private var completing = false
        init(_ parent: CodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            highlight()
            (tv.enclosingScrollView?.verticalRulerView)?.needsDisplay = true
            // Offer completions while typing an identifier.
            if !completing, let event = NSApp.currentEvent, event.type == .keyDown,
               let chars = event.characters, let c = chars.unicodeScalars.first,
               CharacterSet.letters.contains(c) || c == "[" || c == "'" {
                let r = tv.rangeForUserCompletion
                if r.length >= 2 || c == "[" || c == "'" {
                    completing = true
                    tv.complete(nil)
                    completing = false
                }
            }
        }

        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
            for t in parent.language.tokens(tv.string) where NSMaxRange(t.range) <= storage.length {
                storage.addAttribute(.foregroundColor, value: t.kind.color, range: t.range)
                if t.kind == .keyword { storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .semibold), range: t.range) }
            }
            for issue in parent.issues {
                guard let r = issue.range else { continue }
                let range = NSRange(location: min(r.lowerBound, storage.length), length: max(1, min(r.count, storage.length - min(r.lowerBound, storage.length))))
                guard NSMaxRange(range) <= storage.length, range.length > 0 else { continue }
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.thick.rawValue,
                                       .underlineColor: issue.isWarning ? NSColor.systemOrange : NSColor.systemRed,
                                       .toolTip: issue.message], range: range)
            }
            storage.endEditing()
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            index?.pointee = -1 // never insert a suggestion the user didn't pick
            let prefix = (textView.string as NSString).substring(with: charRange)
            let list = parent.language.completions(prefix, parent.model)
            var seen = Set<String>()
            return list.map(\.text).filter { seen.insert($0).inserted }.prefix(40).map { $0 }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if NSEvent.modifierFlags.contains(.command), let commit = parent.onCommit { commit(); return true }
                // Keep the current line's indentation; indent one more after an opening bracket.
                let ns = textView.string as NSString
                let loc = textView.selectedRange().location
                let line = ns.lineRange(for: NSRange(location: loc, length: 0))
                let before = ns.substring(with: NSRange(location: line.location, length: loc - line.location))
                var indent = String(before.prefix { $0 == " " || $0 == "\t" })
                if let last = before.trimmingCharacters(in: .whitespaces).last, "([{".contains(last) { indent += "    " }
                textView.insertText("\n" + indent, replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.insertTab(_:)):
                textView.insertText("    ", replacementRange: textView.selectedRange())
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                if let cancel = parent.onCancel { cancel(); return true }
                return false
            default: return false
            }
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            // Auto-close brackets and quotes when typing at the end of a token.
            guard let s = replacementString, s.count == 1, range.length == 0, !completing,
                  let close = ["(": ")", "[": "]", "{": "}", "\"": "\""][s] else { return true }
            let ns = textView.string as NSString
            let next = range.location < ns.length ? ns.substring(with: NSRange(location: range.location, length: 1)) : " "
            guard next.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || ")]},".contains(next) else { return true }
            if s == "\"" { // don't pair when closing an existing string
                let before = ns.substring(to: range.location)
                if before.filter({ $0 == "\"" }).count % 2 == 1 { return true }
            }
            completing = true
            textView.insertText(s + close, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + 1, length: 0))
            completing = false
            return false
        }
    }
}

/// A text view that takes drops of one custom pasteboard type itself and passes them to a handler,
/// so they are never inserted as text. Every other drag behaves as in any text view.
final class ObjectDropTextView: NSTextView {
    /// The current drop handling, read when a drag arrives.
    var objectDrop: () -> CodeEditor.ObjectDrop? = { nil }
    private var targeted = false

    /// A scroll view around a new text view, laid out like `NSTextView.scrollableTextView()`.
    static func scrollable() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        let tv = ObjectDropTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        return scroll
    }

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + (objectDrop().map { [$0.type] } ?? [])
    }

    private func drop(for sender: NSDraggingInfo) -> CodeEditor.ObjectDrop? {
        guard let drop = objectDrop(), sender.draggingPasteboard.availableType(from: [drop.type]) != nil else { return nil }
        return drop
    }

    private func setTargeted(_ on: Bool) {
        guard on != targeted else { return }
        targeted = on
        objectDrop()?.onTargeted(on)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard drop(for: sender) != nil else { return super.draggingEntered(sender) }
        setTargeted(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        drop(for: sender) != nil ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if targeted { setTargeted(false) } else { super.draggingExited(sender) }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setTargeted(false)
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        drop(for: sender) != nil ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let drop = drop(for: sender) else { return super.performDragOperation(sender) }
        setTargeted(false)
        guard let data = sender.draggingPasteboard.data(forType: drop.type) else { return false }
        return drop.onDrop(data)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, drop(for: sender) != nil { return }
        super.concludeDragOperation(sender)
    }
}

/// Line numbers in the gutter.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: textView.enclosingScrollView?.contentView)
        textView.enclosingScrollView?.contentView.postsBoundsChangedNotifications = true
    }
    @available(*, unavailable) required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    @objc private func refresh() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
        let ns = tv.string as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
        let visible = lm.glyphRange(forBoundingRect: tv.visibleRect, in: container)
        let firstChar = lm.characterIndexForGlyph(at: visible.location)
        var line = 1
        ns.substring(to: firstChar).forEach { if $0 == "\n" { line += 1 } }
        var index = ns.lineRange(for: NSRange(location: firstChar, length: 0)).location
        let inset = tv.textContainerInset.height
        while index <= ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let glyphs = lm.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: max(lineRange.length, 0)), actualCharacterRange: nil)
            var r = lm.boundingRect(forGlyphRange: glyphs, in: container)
            if lineRange.length == 0 { r = lm.extraLineFragmentRect }
            let y = r.minY + inset - tv.visibleRect.minY
            if y > rect.maxY + 20 { break }
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: ruleThickness - size.width - 6, y: y + 1), withAttributes: attrs)
            line += 1
            if NSMaxRange(lineRange) >= ns.length { if lineRange.length > 0, ns.character(at: ns.length - 1) == 10, index != ns.length { index = ns.length; continue }; break }
            index = NSMaxRange(lineRange)
        }
    }
}
