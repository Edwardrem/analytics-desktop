import SwiftUI
import AppKit
import FacetCore
import FacetDesign

/// Page elements (text box, image, shape, button, navigators) and embedded / scripted visuals.
enum CmpPageFamily {
    static func view(_ env: CmpEnv) -> AnyView? {
        switch env.spec.type {
        case .textBox: return AnyView(CmpTextBoxView(env: env))
        case .image: return AnyView(CmpImageVisualView(env: env))
        case .shape: return AnyView(CmpShapeView(env: env))
        case .button: return AnyView(CmpButtonView(env: env))
        case .pageNavigator: return AnyView(CmpNavigatorView(env: env, isBookmarks: false))
        case .bookmarkNavigator: return AnyView(CmpNavigatorView(env: env, isBookmarks: true))
        case .pythonVisual, .rVisual: return AnyView(CmpScriptVisualView(env: env))
        case .paginatedReport, .powerApps, .powerAutomate, .metrics: return AnyView(CmpEmbedView(env: env))
        default: return nil
        }
    }

    // MARK: Catalog

    private static func buttonStateProperties() -> [CmpFormatProperty] {
        let button = CmpCard("button", "Button"), fill = CmpCard("fill", "Fill"), outline = CmpCard("outline", "Outline")
        let text = CmpCard("text", "Text"), icon = CmpCard("icon", "Icon")
        var out: [CmpFormatProperty] = [
            button.options("style", "Style", ["tinted", "filled", "outline", "plain", "soft"], "tinted"),
            button.options("shape", "Shape", ["roundedRectangle", "rectangle", "pill"], "roundedRectangle"),
            button.number("radius", "Corner radius", 8),
            fill.bool("show", "Show fill", true), fill.number("transparency", "Transparency %", 0),
            outline.bool("show", "Show outline", true), outline.number("width", "Width", 1),
            text.number("size", "Font size", 13), text.bool("bold", "Medium weight", true),
            text.options("alignment", "Alignment", ["left", "center", "right"], "center"),
        ]
        for state in CmpButtonState.allCases {
            let name = state == .normal ? "Default" : state.rawValue.capitalized
            out.append(fill.color(state.colorKey, "Fill — \(name)"))
            out.append(outline.color(state.colorKey, "Outline — \(name)"))
            out.append(text.color(state.colorKey, "Text — \(name)"))
            out.append(icon.color(state.colorKey, "Icon — \(name)"))
        }
        return out
    }

    static func properties(for type: VisualType) -> [CmpFormatProperty] {
        let text = CmpCard("text", "Text")
        switch type {
        case .textBox:
            return [
                text.number("size", "Font size", 13), text.color("color", "Colour"), text.color("linkColor", "Link colour"),
                text.string("fontFamily", "Font family"), text.number("lineSpacing", "Line spacing", 2),
                text.options("alignment", "Alignment", ["left", "center", "right"], "left"),
                text.options("verticalAlignment", "Vertical alignment", ["top", "middle", "bottom"], "top"),
            ]
        case .image:
            let image = CmpCard("image", "Image")
            return [
                image.options("scaling", "Scaling", ["fit", "fill", "normal", "stretch"], "fit"),
                image.number("transparency", "Transparency %", 0), image.number("radius", "Corner radius", 0),
            ]
        case .shape:
            let shape = CmpCard("shape", "Shape"), fill = CmpCard("fill", "Fill"), outline = CmpCard("outline", "Outline")
            return [
                shape.options("kind", "Shape", CmpShapeKind.allCases.map(\.rawValue), "rectangle"),
                shape.number("cornerRadius", "Corner radius", 12), shape.bool("shadow", "Shadow", false),
                shape.options("lineDirection", "Line direction", ["auto", "horizontal", "vertical", "diagonalDown", "diagonalUp"], "auto"),
                shape.options("startCap", "Line start", ["none", "arrow", "dot"], "none"),
                shape.options("endCap", "Line end", ["none", "arrow", "dot"], "none"),
                fill.bool("show", "Show fill", true), fill.color("color", "Colour"), fill.number("transparency", "Transparency %", 0),
                outline.bool("show", "Show outline", false), outline.color("color", "Colour"), outline.number("width", "Width", 1),
                outline.options("style", "Style", ["solid", "dashed", "dotted"], "solid"),
                text.string("text", "Text"), text.number("size", "Font size", 13), text.color("color", "Colour"),
                text.bool("bold", "Bold", false), text.options("alignment", "Alignment", ["left", "center", "right"], "center"),
                text.number("padding", "Padding", 8),
            ]
        case .button:
            let button = CmpCard("button", "Button"), icon = CmpCard("icon", "Icon")
            return [
                button.options("icon", "Icon", CmpButtonIcon.kinds, "blank"),
                button.bool("enabled", "Enabled", true), button.bool("selected", "Selected", false),
                text.string("text", "Text"),
                icon.number("size", "Icon size", nil), icon.options("placement", "Icon placement", ["left", "right", "above", "below"], "left"),
            ] + buttonStateProperties()
        case .pageNavigator, .bookmarkNavigator:
            let nav = CmpCard("navigator", "Layout")
            return [
                nav.options("orientation", "Orientation", ["horizontal", "vertical", "grid"], "horizontal"),
                nav.number("columns", "Grid columns", 2), nav.number("spacing", "Spacing", 6),
                nav.number("buttonHeight", "Button height (vertical)", 34),
            ] + buttonStateProperties().map { p in
                var q = p
                if p.card == "button", p.key == "style" { q.defaultValue = .string("soft") }
                return q
            }
        case .powerAutomate:
            return [text.string("text", "Button text", "Run flow")]
        default: return []
        }
    }

    static func presets(for type: VisualType) -> [(name: String, format: FormatBag)] {
        switch type {
        case .button, .pageNavigator, .bookmarkNavigator:
            return [
                ("Tinted", ["button": ["style": .string("tinted")]]),
                ("Filled", ["button": ["style": .string("filled")]]),
                ("Outline", ["button": ["style": .string("outline")]]),
                ("Plain", ["button": ["style": .string("plain")]]),
                ("Soft pill", ["button": ["style": .string("soft"), "shape": .string("pill")]]),
            ]
        default: return []
        }
    }

    // MARK: Samples

    /// A small generated picture (soft gradient with circles) so image samples need no file or network.
    static func sampleImageData(width: Int = 480, height: Int = 320, hue: CGFloat = 0.58) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.55, brightness: 0.95, alpha: 1),
                   ending: NSColor(hue: hue + 0.12, saturation: 0.7, brightness: 0.55, alpha: 1))?.draw(in: rect, angle: -50)
        for (i, r) in [0.42, 0.28, 0.16].enumerated() {
            NSColor.white.withAlphaComponent(0.12 + 0.06 * CGFloat(i)).setFill()
            let d = CGFloat(height) * CGFloat(r) * 2
            NSBezierPath(ovalIn: NSRect(x: CGFloat(width) * 0.62 - d / 2, y: CGFloat(height) * 0.42 - d / 2, width: d, height: d)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    static func samples() -> [(spec: VisualSpec, data: VisualData)] {
        var out: [(spec: VisualSpec, data: VisualData)] = []
        out.append(CmpSample.make(.textBox, name: "TextBox rich", size: (440, 300), columns: [
            CmpCol("Total Sales", .values, measure: true, format: "$#,0"),
            CmpCol("Top Region", .values),
        ], rows: [[.double(12_483_902), "North America"]]) { s in
            s.content = """
            # Quarterly review
            Sales reached **{{Total Sales}}** this quarter, led by *{{Top Region}}* — a <u>record</u> for the team, \
            well above the ~~previous~~ forecast of {{=[Forecast]}}.

            ## Highlights
            - Revenue per m^2^ of floor space rose **8.4%**
            - CO~2~ emissions per order fell for the third quarter
              - mostly from consolidated shipping
            1. Read the [full report](https://example.com/report)
            2. Share feedback by Friday
            """
        })
        out.append(CmpSample.make(.textBox, name: "TextBox centered", size: (300, 90)) { s in
            s.content = "## Sales overview\nFiscal year 2026 · *updated daily*"
            s.setFmt("text", "alignment", .string("center")); s.setFmt("text", "verticalAlignment", .string("middle"))
        })
        out.append(CmpSample.make(.textBox, name: "TextBox empty", size: (240, 120)))
        out.append(CmpSample.make(.image, name: "Image fit", size: (280, 160)) { s in
            s.imageData = sampleImageData(); s.altText = "Abstract blue artwork"
        })
        out.append(CmpSample.make(.image, name: "Image fill", size: (200, 200)) { s in
            s.imageData = sampleImageData(hue: 0.08); s.setFmt("image", "scaling", .string("fill")); s.setFmt("image", "radius", .number(16))
        })
        out.append(CmpSample.make(.image, name: "Image empty", size: (200, 120)))
        let kinds: [CmpShapeKind] = [.rectangle, .roundedRectangle, .ellipse, .triangle, .pentagon, .hexagon, .arrow, .line,
                                      .chevron, .speechBubble, .heart, .star]
        for (i, kind) in kinds.enumerated() {
            out.append(CmpSample.make(.shape, name: "Shape \(kind.rawValue)", size: (170, 120)) { s in
                s.setFmt("shape", "kind", .string(kind.rawValue))
                s.setFmt("fill", "color", .string(ThemeSpec.facet.dataColors[i % 6]))
                if kind == .speechBubble { s.setFmt("text", "text", .string("New this month")) }
                if kind == .roundedRectangle { s.setFmt("text", "text", .string("Phase 1")); s.setFmt("shape", "shadow", .bool(true)) }
                if kind == .ellipse { s.setFmt("fill", "show", .bool(false)); s.setFmt("outline", "show", .bool(true)); s.setFmt("outline", "width", .number(2)); s.setFmt("outline", "style", .string("dashed")); s.setFmt("outline", "color", .string("#5E5CE6")) }
                if kind == .line { s.setFmt("shape", "endCap", .string("arrow")); s.setFmt("shape", "startCap", .string("dot")) }
                if kind == .arrow { s.frame.rotation = -20 }
            })
        }
        func button(_ name: String, w: Double = 150, h: Double = 40, _ configure: @escaping (inout VisualSpec) -> Void) {
            out.append(CmpSample.make(.button, name: name, size: (w, h), configure: configure))
        }
        button("Button back") { s in
            s.setFmt("button", "icon", .string("back")); s.setFmt("text", "text", .string("Back"))
            var a = ActionSpec(); a.kind = .back; a.tooltip = "Go back to the previous page"; s.action = a
        }
        button("Button filled") { s in
            s.setFmt("button", "style", .string("filled")); s.setFmt("text", "text", .string("Apply all slicers"))
            var a = ActionSpec(); a.kind = .applyAllSlicers; s.action = a
        }
        button("Button outline") { s in
            s.setFmt("button", "style", .string("outline")); s.setFmt("button", "icon", .string("reset")); s.setFmt("text", "text", .string("Clear filters"))
            s.setFmt("button", "shape", .string("pill"))
        }
        button("Button disabled drillthrough", w: 170) { s in
            s.setFmt("button", "icon", .string("rightArrow")); s.setFmt("icon", "placement", .string("right"))
            s.setFmt("text", "text", .string("See details")); s.setFmt("button", "enabled", .bool(false))
            var a = ActionSpec(); a.kind = .drillthrough; s.action = a
        }
        button("Button selected") { s in
            s.setFmt("button", "icon", .string("bookmark")); s.setFmt("text", "text", .string("This year")); s.setFmt("button", "selected", .bool(true))
        }
        button("Button icon only", w: 40) { s in s.setFmt("button", "icon", .string("help")); s.setFmt("button", "style", .string("plain")) }
        button("Button custom colours", w: 160, h: 56) { s in
            s.setFmt("button", "icon", .string("qna")); s.setFmt("icon", "placement", .string("above")); s.setFmt("text", "text", .string("Ask a question"))
            s.setFmt("fill", "color", .string("#1D1D1F")); s.setFmt("text", "color", .string("#FFFFFF")); s.setFmt("outline", "show", .bool(false))
        }
        out.append(CmpSample.make(.pageNavigator, name: "PageNavigator horizontal", size: (420, 36)))
        out.append(CmpSample.make(.pageNavigator, name: "PageNavigator vertical", size: (150, 130)) { s in
            s.setFmt("navigator", "orientation", .string("vertical")); s.setFmt("button", "style", .string("plain"))
        })
        out.append(CmpSample.make(.bookmarkNavigator, name: "BookmarkNavigator grid", size: (260, 40)) { s in
            s.setFmt("navigator", "orientation", .string("grid")); s.setFmt("button", "style", .string("outline")); s.setFmt("button", "shape", .string("pill"))
        })
        out.append(CmpSample.make(.pythonVisual, name: "PythonVisual placeholder", size: (360, 220)))
        out.append(CmpSample.make(.rVisual, name: "RVisual rendered", size: (300, 200)) { s in
            s.imageData = sampleImageData(hue: 0.35); s.content = "plot(dataset)"
        })
        out.append(CmpSample.make(.paginatedReport, name: "PaginatedReport placeholder", size: (320, 200)))
        out.append(CmpSample.make(.powerApps, name: "PowerApps placeholder", size: (320, 200)))
        out.append(CmpSample.make(.powerAutomate, name: "PowerAutomate run button", size: (240, 80)) { s in
            var a = ActionSpec(); a.kind = .dataFunction; a.functionName = "approve order"; s.action = a
        })
        out.append(CmpSample.make(.metrics, name: "Metrics placeholder", size: (320, 200)))
        return out
    }
}
