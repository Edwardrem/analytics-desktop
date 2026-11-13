import SwiftUI
import FacetCore
import FacetVisuals

/// Copying formatting between visuals: the format painter, Copy / Paste Formatting, and reset.
enum FormatPainter {
    /// The format properties of `type` that are formatting rather than content. Text (titles,
    /// labels, captions) belongs to the visual it describes, so it is never painted.
    static func paintable(_ type: VisualType) -> [String: FormatProperty] {
        let all = (FormatCatalog.visualCards(for: type) + FormatCatalog.generalCards(for: type))
            .filter { $0.role == .format }.flatMap(\.properties).filter { $0.kind != .string }
        return Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// `target`'s format bag after taking `source`'s formatting: every property both visuals
    /// honour with the same control ends up as it is on the source (set, or back to default where
    /// the source has no override). Everything else on the target is kept.
    static func painted(_ target: VisualSpec, from source: VisualSpec) -> FormatBag {
        let theirs = paintable(source.type)
        var out = target
        for (id, mine) in paintable(target.type) {
            guard let other = theirs[id], other.kind == mine.kind else { continue }
            out.setFmt(mine.card, mine.key, FormatCatalog.stored(source.fmt(mine.card, mine.key), for: mine))
        }
        return out.format
    }

    /// `spec`'s format bag with every catalog property back at its default. Keys the catalog does
    /// not describe (per-column widths, sparklines) are kept.
    static func reset(_ spec: VisualSpec) -> FormatBag {
        var out = spec
        for card in FormatCatalog.visualCards(for: spec.type) + FormatCatalog.generalCards(for: spec.type) where card.role == .format {
            for key in card.resetKeys { out.setFmt(card.card, key, nil) }
        }
        return out.format
    }

    /// True when `spec` carries at least one override the catalog describes.
    static func hasOverrides(_ spec: VisualSpec) -> Bool { reset(spec) != spec.format }
}

/// The visual whose formatting Copy Formatting captured, as it was at that moment.
@MainActor
enum FormatClipboard {
    static var source: VisualSpec?
}

/// Style presets: named partial format bags a visual type offers (cards, slicers, tables, matrices…).
enum FormatPresets {
    static func presets(for type: VisualType, theme: ThemeSpec) -> [(name: String, format: FormatBag)] {
        ComponentStylePresets.presets(for: type, theme: theme)
    }

    /// The first preset whose every key the visual currently carries, if any.
    static func active(in spec: VisualSpec, theme: ThemeSpec) -> String? {
        presets(for: spec.type, theme: theme).first { preset in
            !preset.format.isEmpty && preset.format.allSatisfy { card, keys in
                keys.allSatisfy { spec.fmt(card, $0.key) == $0.value }
            }
        }?.name
    }

    /// `spec` with the named preset merged in (preset keys win; other keys are kept). Unknown names change nothing.
    static func applying(_ name: String, to spec: VisualSpec, theme: ThemeSpec) -> VisualSpec {
        guard let preset = presets(for: spec.type, theme: theme).first(where: { $0.name == name }) else { return spec }
        var out = spec
        ComponentStylePresets.apply(preset.format, to: &out)
        return out
    }
}

/// A request to open the Format pane on one card (from on-object formatting).
@MainActor
final class FormatFocus: ObservableObject {
    static let shared = FormatFocus()

    struct Request: Equatable {
        let store: ObjectIdentifier
        let card: String
        let tab: FormatCatalog.Tab
        let token = UUID()
    }
    @Published var request: Request?

    /// Shows the Format pane of `store`'s window with `card` expanded and in view.
    func open(_ card: String, tab: FormatCatalog.Tab, in store: DocumentStore) {
        request = Request(store: ObjectIdentifier(store), card: card, tab: tab)
        ShellState.of(store).show(.format)
    }
}
