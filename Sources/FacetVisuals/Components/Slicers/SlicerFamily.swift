import SwiftUI
import FacetCore
import FacetDesign

/// Slicer family entry point: `slicer` (list, dropdown, tile, between, before, after, relativeDate,
/// relativeTime, hierarchy), `buttonSlicer`, `listSlicer`, `inputSlicer`.
enum CmpSlicerFamily {
    static func view(_ env: CmpEnv) -> AnyView? {
        guard env.spec.type.isSlicer else { return nil }
        if env.spec.fields(.field).isEmpty, env.data.indices(.field).isEmpty {
            return AnyView(CmpPlaceholder(systemImage: "line.3.horizontal.decrease.circle", title: "Add a field",
                                          message: "Drag a field here to filter the page with this slicer.", theme: env.theme))
        }
        return AnyView(CmpSlHost(env: env))
    }

    // MARK: Format catalog

    static func properties(for type: VisualType) -> [CmpFormatProperty] {
        guard type.isSlicer else { return [] }
        let s = CmpCard("slicer", "Slicer settings")
        let common: [CmpFormatProperty] = [
            s.bool("applyButton", "Apply button", false),
            s.options("showClear", "Clear selections button", ["hover", "always", "never"], "hover"),
            s.number("fontSize", "Text size", nil),
            s.number("itemPadding", "Item padding", 4),
            s.color("color", "Text colour"),
            s.color("selectedColor", "Selection colour"),
        ]
        let selection: [CmpFormatProperty] = [
            s.bool("singleSelect", "Single select", false),
            s.bool("multiSelectWithCommand", "Multi-select with ⌘", false),
            s.bool("forceSelection", "Force selection", false),
        ]
        switch type {
        case .slicer:
            return [s.options("style", "Style", ["list", "dropdown", "tile", "between", "before", "after",
                                                   "relativeDate", "relativeTime", "hierarchy"], "list")]
                + selection
                + [s.bool("selectAll", "Show \"Select all\"", false),
                   s.bool("search", "Search box", false),
                   s.bool("slider", "Range slider", true)]
                + common
        case .listSlicer:
            return [s.bool("dropdown", "Dropdown mode", false)] + selection
                + [s.bool("selectAll", "Show \"Select all\"", false), s.bool("search", "Search box", false)] + common
        case .buttonSlicer:
            let b = CmpCard("buttons", "Buttons")
            return selection + common + [
                b.number("columns", "Columns (0 = automatic)", 0),
                b.number("rows", "Rows (0 = automatic)", 0),
                b.options("overflow", "Overflow", ["scroll", "pagination"], "scroll"),
                b.number("spacing", "Spacing", 8),
                b.number("radius", "Corner radius", 8),
                b.number("minWidth", "Minimum button width", 88),
                b.number("height", "Button height (0 = automatic)", 0),
                b.color("fill", "Fill colour"),
                b.bool("border", "Border", true),
                b.bool("showImages", "Show images", true),
                b.number("imageSize", "Image size", 28),
            ]
        case .inputSlicer:
            return [s.options("operator", "Operator", CmpSlLogic.inputOperators.map(\.id), "contains"),
                    s.bool("showOperator", "Show operator menu", true),
                    s.string("placeholder", "Placeholder", "Type or paste values")] + common
        default:
            return []
        }
    }

    // MARK: Style presets

    static func presets(for type: VisualType) -> [(name: String, format: FormatBag)] {
        guard type.isSlicer else { return [] }
        var out: [(name: String, format: FormatBag)] = [
            ("Minimal", ["slicer": ["fontSize": .number(12), "itemPadding": .number(4)],
                         "title": ["bold": .bool(false)], "divider": ["show": .bool(false)], "border": ["show": .bool(false)]]),
            ("Bold header", ["title": ["bold": .bool(true), "size": .number(15)], "divider": ["show": .bool(true)]]),
            ("Condensed", ["slicer": ["fontSize": .number(11), "itemPadding": .number(1.5)], "padding": ["all": .number(8)]]),
            ("Contrast", ["slicer": ["selectedColor": .string("#1D1D1F"), "fontSize": .number(13)],
                          "border": ["show": .bool(true)], "title": ["bold": .bool(true)]]),
        ]
        switch type {
        case .slicer:
            out.append(("Pills", ["slicer": ["style": .string("tile"), "itemPadding": .number(4)]]))
            out.append(("Searchable list", ["slicer": ["style": .string("list"), "search": .bool(true), "selectAll": .bool(true)]]))
        case .buttonSlicer:
            out.append(("Rounded", ["buttons": ["radius": .number(100), "border": .bool(false)]]))
            out.append(("Square outline", ["buttons": ["radius": .number(2), "border": .bool(true), "fill": .string("#00000000")]]))
        default: break
        }
        return out
    }

    static func samples() -> [(spec: VisualSpec, data: VisualData)] { CmpSlGallery.samples() }
}

/// Chooses the style view for a slicer.
struct CmpSlBody: View {
    let session: CmpSlSession
    let size: CGSize

    var body: some View {
        let env = session.env, cfg = session.cfg
        let cols = env.data.indices(.field)
        let first = cols.first ?? 0
        switch env.spec.type {
        case .buttonSlicer:
            let imageCol = cols.dropFirst().first { c in
                env.data.table.columns[safe: c]?.values.first { !$0.isNull }.map { CmpSlImage.looksLikeImage($0.asString) } ?? false
            }
            CmpSlButtonGrid(session: session, items: CmpSlLogic.items(env.data, column: first, imageColumn: imageCol), size: size)
        case .inputSlicer:
            CmpSlInputView(session: session, size: size)
        case .listSlicer:
            selection(cols, appearance: .highlight, dropdown: cfg.style == "dropdown")
        default:
            switch cfg.style {
            case "between", "before", "after":
                CmpSlRangeView(session: session, column: first, mode: cfg.style, size: size)
            case "relativeDate":
                CmpSlRelativeView(session: session, isTime: false, size: size)
            case "relativeTime":
                CmpSlRelativeView(session: session, isTime: true, size: size)
            case "tile":
                CmpSlTileView(session: session, items: CmpSlLogic.items(env.data, column: first))
            default:
                selection(cols, appearance: .check, dropdown: cfg.style == "dropdown")
            }
        }
    }

    /// List or tree (several fields ⇒ hierarchy), inline or inside a dropdown.
    @ViewBuilder
    private func selection(_ cols: [Int], appearance: CmpSlRow.Appearance, dropdown: Bool) -> some View {
        if cols.count > 1 {
            let roots = CmpSlLogic.tree(session.env.data, columns: cols)
            if dropdown {
                CmpSlDropdown(session: session,
                              summary: CmpSlDropdown<EmptyView>.summary(labels: CmpSlTreeView.summaryLabels(roots, paths: session.state.hierarchyPaths))) {
                    CmpSlTreeView(session: session, roots: roots, appearance: appearance)
                }
            } else {
                CmpSlTreeView(session: session, roots: roots, appearance: appearance)
            }
        } else {
            let items = CmpSlLogic.items(session.env.data, column: cols.first ?? 0)
            if dropdown {
                let chosen = Set(session.state.selected)
                CmpSlDropdown(session: session,
                              summary: CmpSlDropdown<EmptyView>.summary(labels: items.filter { chosen.contains($0.value) }.map(\.label))) {
                    CmpSlListView(session: session, items: items, appearance: appearance)
                }
            } else {
                CmpSlListView(session: session, items: items, appearance: appearance)
            }
        }
    }
}
