import XCTest
import FacetCore
@testable import FacetVisuals

/// Measure-driven format values are drawn in place of the stored ones and never written back.
final class FormatOverridesTests: XCTestCase {
    private func stored() -> VisualSpec {
        var spec = VisualSpec(type: .table, frame: Frame(x: 0, y: 0, width: 300, height: 200))
        spec.setFmt("subtitle", "text", .string("Static"))
        spec.setFmt("columnWidths", "A", .number(100))
        spec.setFmt("columnWidths", "B", .number(120))
        spec.altText = "Alt"
        for (card, key) in [("subtitle", "text"), ("columnWidths", "A"), (FormatBinding.altTextCard, "text"), (FormatBinding.actionCard, "tooltip")] {
            spec.setFormatBinding(card, key, FormatBinding(card: card, key: key, kind: .text))
        }
        return spec
    }

    private let overrides: FormatBag = [
        "subtitle": ["text": .string("Live")],
        "columnWidths": ["A": .number(200)],
        FormatBinding.altTextCard: ["text": .string("Live alt")],
        FormatBinding.actionCard: ["tooltip": .string("Tip")],
    ]

    func testOverridesAreDrawnOverTheStoredFormat() {
        let shown = stored().applyingFormatOverrides(overrides)
        XCTAssertEqual(shown.fmt("subtitle", "text"), .string("Live"))
        XCTAssertEqual(shown.fmt("columnWidths", "A"), .number(200))
        XCTAssertEqual(shown.fmt("columnWidths", "B"), .number(120))
        XCTAssertEqual(shown.altText, "Live alt")
        // A visual with no action gets one that only carries the tooltip.
        XCTAssertEqual(shown.action?.tooltip, "Tip")
        XCTAssertEqual(shown.action?.kind, ActionSpec.Kind.none)
    }

    func testRestoringPutsBackWhatTheRendererLeftAlone() {
        let spec = stored()
        var edited = spec.applyingFormatOverrides(overrides)
        edited.setFmt("columnWidths", "B", .number(150))   // the reader resized B
        let back = edited.restoringFormatOverrides(overrides, from: spec)
        XCTAssertEqual(back.fmt("subtitle", "text"), .string("Static"))
        XCTAssertEqual(back.fmt("columnWidths", "A"), .number(100))
        XCTAssertEqual(back.fmt("columnWidths", "B"), .number(150))
        XCTAssertEqual(back.altText, "Alt")
        XCTAssertNil(back.action)

        // A column the reader resized keeps the new width even though a binding drives it.
        var resized = spec.applyingFormatOverrides(overrides)
        resized.setFmt("columnWidths", "A", .number(250))
        XCTAssertEqual(resized.restoringFormatOverrides(overrides, from: spec).fmt("columnWidths", "A"), .number(250))

        // A stored action keeps its kind and gets its own tooltip back.
        var withAction = spec
        var back2 = ActionSpec(); back2.kind = .back; back2.tooltip = "Back"
        withAction.action = back2
        let restored = withAction.applyingFormatOverrides(overrides).restoringFormatOverrides(overrides, from: withAction)
        XCTAssertEqual(restored.action, back2)
    }

    func testOnlyBoundPropertiesAreDrawn() {
        var spec = stored()
        spec.formatBindings = [FormatBinding(card: "subtitle", key: "text", kind: .text)]
        XCTAssertEqual(spec.boundFormatOverrides(overrides), ["subtitle": ["text": .string("Live")]])
        spec.formatBindings = nil
        XCTAssertTrue(spec.boundFormatOverrides(overrides).isEmpty)
    }

    func testVisualViewDrawsOverridesAndReportsStoredValues() throws {
        let spec = stored()
        var data = VisualData()
        data.formatOverrides = overrides
        var reported: VisualSpec?
        var context = VisualContext()
        context.onSpecChange = { reported = $0 }
        let view = VisualView(spec: spec, data: data, context: context)
        XCTAssertEqual(view.spec.fmt("subtitle", "text"), .string("Live"))
        XCTAssertEqual(view.spec.altText, "Live alt")

        var edited = view.spec
        edited.content = "edited"
        view.context.onSpecChange(edited)
        let out = try XCTUnwrap(reported)
        XCTAssertEqual(out.content, "edited")
        XCTAssertEqual(out.fmt("subtitle", "text"), .string("Static"))
        XCTAssertEqual(out.altText, "Alt")
        XCTAssertEqual(out.fmt("columnWidths", "A"), .number(100))

        // Without overrides the view draws the spec as stored.
        XCTAssertEqual(VisualView(spec: spec, data: VisualData(), context: context).spec, spec)
    }
}
