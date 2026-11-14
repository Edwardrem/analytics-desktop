# FacetVisuals / Components — API reference

Non-chart visual renderers: tables, single-value cards, slicers, maps, gantt, page elements and
embedded/scripted placeholders. Everything is drawn through the host (`VisualView`), which calls
`ComponentVisuals.view`. Renderers are pure views: they read `VisualSpec` + `VisualData` + `VisualContext`
and only talk back through the context callbacks.

## Public API

```swift
public enum ComponentVisuals {
    /// nil for chart types and for keyInfluencers / decompositionTree / narrative / qna
    /// (the app supplies those through VisualContext.extensionView).
    public static func view(spec: VisualSpec, data: VisualData, context: VisualContext) -> AnyView?
    public static let supportedTypes: [VisualType]
}

public enum ComponentFormatCatalog {
    /// Every format[card][key] the renderer of `type` honours — generate the Format pane from this.
    public static func properties(for type: VisualType) -> [CmpFormatProperty]
}

public struct CmpFormatProperty: Identifiable, Hashable, Sendable {
    public enum Kind { case bool, number, string, color, enumeration(options: [String]) }
    public var card, key: String          // format[card][key]
    public var label, cardLabel: String   // human-readable names
    public var kind: Kind
    public var defaultValue: JSONValue    // renderer default; .null = follows the theme
    public var id: String                 // "card.key"
}

public enum ComponentStylePresets {
    /// Named partial format bags (cards, slicers, tables, matrices, buttons/navigators).
    public static func presets(for type: VisualType) -> [(name: String, format: FormatBag)]
    /// Same, with table/matrix colours derived from `theme` (use for dark / high-contrast themes).
    public static func presets(for type: VisualType, theme: ThemeSpec) -> [(name: String, format: FormatBag)]
    /// Cards keyed by column/value name (table & matrix: columnWidths, imageColumns, sparklines, totals).
    public static func perFieldCards(for type: VisualType) -> [(card: String, label: String, kind: CmpFormatProperty.Kind)]
    /// Merge a preset into a spec (preset keys win, others are kept).
    public static func apply(_ preset: FormatBag, to spec: inout VisualSpec)
}

public enum ComponentGallery {
    /// Realistic sample spec + data for every component type (previews, visual gallery, snapshot checks).
    public static func samples() -> [(spec: VisualSpec, data: VisualData)]
}
```

Usage:

```swift
var ctx = VisualContext()
ctx.theme = report.theme
ctx.onSelect = { points, additive in model.select(points, additive: additive) }
ctx.onSlicerChange = { state in model.setSlicer(visual.id, state) }
ctx.onSpecChange = { updated in model.replaceVisual(updated) }   // sort, column widths, expansion, text edits
ctx.onAction = { action in model.perform(action) }
VisualView(spec: visual, data: data, context: ctx)               // host chrome + ComponentVisuals.view(...)

// Format pane
for p in ComponentFormatCatalog.properties(for: visual.type) { /* build a control from p.kind, write spec.setFmt(p.card, p.key, …) */ }
// Style presets menu
for preset in ComponentStylePresets.presets(for: visual.type) { /* ComponentStylePresets.apply(preset.format, to: &visual) */ }
```

Conventions shared by all components

- All format lookups go through `ResolvedFormat` (visual → theme defaults for the type → theme `"*"` → renderer default).
  Container cards (`title`, `subtitle`, `divider`, `background`, `border`, `shadow`, `padding`) are drawn by the host.
- Colours, fonts and sizes come from `ThemeSpec` unless a format key overrides them; dark and high-contrast themes are supported.
- Selection: clicking a data point calls `context.onSelect([point], additive)` (`additive` = ⌘ held); marks dim with
  `context.emphasis(_:)` and show a selected state with `context.isSelected(_:)`.
- `context.isInteractive == false` disables clicks, editing and web content (thumbnails / export).
- Display units: numeric callouts use `auto` units (≥10,000 → K, M, bn, T with up to two decimals); percentages and dates keep
  the column's format string.
- Internal helper types are prefixed `Cmp` and are module-internal, except `CmpFormatProperty`.

## Tables

`table` and `matrix` are drawn by one custom AppKit grid (`CmpTblGridContainer`, wrapped with `NSViewRepresentable`).
Only visible cells are drawn, so row count does not affect scrolling (verified with a 100,000-row sample).
The grid is six panes — header / body / totals × frozen / scrolling — kept in step with one `NSScrollView`,
which gives sticky column headers, frozen row headers (matrix) and a pinned totals row.

Entry: `ComponentVisuals.view(spec:data:context:)`. Internal entry points: `CmpTableFamily.view(_:)`,
`.properties(for:)`, `.presets(for:)` / `.presets(for:theme:)` (theme-aware colours), `.perFieldCards(for:)`, `.samples()`.

### Table (`VisualType.table`)

Data: columns in role `values` (all columns when the role is absent); hidden fields are skipped. `data.totals` feeds the totals row.

| Behaviour | Detail |
| --- | --- |
| Sorting | Click a header → sort by that field (numbers descending first, text ascending first); click again toggles. ⇧-click adds/toggles a further sort key. Written to `spec.sort` through `onSpecChange`. The table also applies `spec.sort` locally (stable) when the data is not already in that order, so it is correct whether or not the host re-queries. Header shows ↑/↓ plus the key order when multi-sorted. |
| Column resize | Drag a header's right edge; persisted as `format["columnWidths"][<column name>]` (points). Double-click the edge (or "Auto-size column" in the header menu) removes the override. |
| Totals | Pinned row from `data.totals`; sits directly under the last row when the table is short. |
| Selection | Click selects a row (`onSelect([point], false)`; clicking the only selected row clears), ⌘-click toggles (`additive: true`), ⇧-click/⇧-arrows select a range. The point holds the row's grouping (non-aggregate) fields and values. Emphasis follows `context.selection` (selected rows tinted, others dimmed). |
| Keyboard | ↑/↓, Page Up/Down, Home/End move the focused row and select it; Space toggles; ⌘A selects all; ⌘C copies; Esc clears. Focus ring on the grid, accent outline on the focused row. |
| Copy | ⌘C / menu: selected rows (all rows when nothing is selected) as TSV with a header line. |
| Context menu | Copy value, Copy selection/table, Copy row, Drill through (`onDrill(.drillthrough(point, pageID: nil))`), Include, Exclude. Include/Exclude append visual-level basic `FilterSpec`s (one per grouping field, `isInverted` for Exclude) to `spec.filters` via `onSpecChange`. |
| Tooltips | Truncated cells/headers show their full text; links show the URL. |
| Accessibility | Role table with label (alt text or name), row/column counts, and the visible rows as row elements (label "Caption: value, …", selected state). |

Conditional formatting (`spec.conditionalFormats`, matched by `appliesToKey == FieldRef.key`; `appliesToKey == nil` applies to every numeric column; `basedOn` selects the driving column):

- `background` / `fontColor`: gradient (2 or 3 stops), rules, or field value (hex). Text on a coloured background switches to a readable colour automatically.
- `dataBars`: positive bars in `maxColor`, negative in `negativeColor`, with an axis line when the range crosses zero.
- `icons`: rule icons are SF Symbol names or `"<set>:<index>"`; without rules the column is split in terciles of the set in `format["conditionalIcons"]["set"]` (`arrows`, `triangles`, `trafficLights`, `flags`, `stars`, `checks`, `signal`).
- `webURL`: the cell becomes a link to the driver column's value. Independently, text values starting with `http://`/`https://` are shown as links (`values.detectURLs`).
- `image`: the cell (or `basedOn` column) holds an http(s)/file URL or a `data:` URI and is drawn as an image. `FieldRef` has no data-category flag, so image columns are declared with this conditional format or with `format["imageColumns"][<column name>] = true`.

**Sparkline contract**: `format["sparklines"][<column name>] = { "type": "line" | "column", "by": <axis column name> }`. In a matrix, each detail row's cell is `MatrixSparkline.encode(_:)` of its value at every point of the shared axis (`"10.0||30.0"`, blank where it has none); subtotal and total cells combine the rows under them point by point with the value's `totals` aggregate.
The query must return, for that column, one delimited numeric string per row — `"1|2|3"` (also `,` `;` or spaces) — ordered along the `by` axis.
`by` is informational for the query builder; the renderer only reads the string. Cells that do not parse are shown as text.

Format keys (card → key, default):

| Card | Key | Default |
| --- | --- | --- |
| columnHeaders | show | true |
| columnHeaders | fontSize | theme header size |
| columnHeaders | bold | theme header weight is bold/semibold |
| columnHeaders | color, background | theme |
| columnHeaders | uppercase | false |
| values | fontSize | theme label size + 1 |
| values | color, background | theme |
| values | alternating | false |
| values | alternateBackground | subtle theme tint |
| values | wordWrap | false |
| values | maxWrapLines | 3 |
| values | alignment | auto (numbers right, text left) / left / center / right |
| values | detectURLs | true |
| values | imageHeight | 32 |
| grid | horizontal | true |
| grid | vertical | false |
| grid | color | theme gridline |
| grid | rowPadding | 5 |
| grid | fillWidth | true (table), false (matrix) |
| total | show | true |
| total | label | "Total" |
| total | bold | true |
| total | color, background | theme |
| dataBars | barOnly | false |
| conditionalIcons | set | arrows |
| conditionalIcons | position | left / right |
| conditionalIcons | iconOnly | false |
| columnWidths | `<column name>` | automatic |
| imageColumns | `<column name>` | false |
| sparklines | `<column name>` | none |

### Matrix (`VisualType.matrix`)

Pivots the long result: roles `rows` (hierarchy), `columns` (hierarchy), `values`. Header order follows first appearance in the data.

- **Layouts**: stepped (one indented row-header column, default) or tabular (`layout.stepped = false`, one frozen column per row field, repeated labels suppressed, "Total" rows after expanded groups).
- **Expand/collapse**: +/− on row and column headers; state in `spec.expandedPaths` as `"R\u{1F}<path>"` / `"C\u{1F}<path>"` (path values joined by `\u{1F}`), written through `onSpecChange`. `spec.expandedAllLevels` expands everything; collapsing a node while it is set materialises the remaining paths and clears the flag. Keyboard: →/← expand/collapse the focused row, Return toggles. Menu: Expand all / Collapse all.
- **Subtotals and grand totals** are computed by the renderer by aggregating the detail rows: sum by default, or per value `format["totals"][<value name>] = sum | min | max | count | distinctCount | average | none` (`none` leaves totals blank). The grand-total cell uses `data.totals` when supplied. These are aggregates of the returned rows, not re-evaluations of the measure: for non-additive measures (ratios, distinct counts) true filter-context subtotals need extra queries from the host — not implemented here.
- **Values on rows** (`layout.valuesOnRows`, needs 2+ values): each row header gets one sub-row per value and a frozen "Values" column.
- **Conditional formatting**: background (incl. heat-map), font colour, data bars and icons on value cells; totals are left unformatted. `values.heatmap = true` applies a theme `minimum → maximum` gradient without a rule. Ranges are taken from the visible non-total cells (first 400 rows × 200 columns).
- **Selection**: clicking a row header selects the row path (`rows` fields); clicking a value cell selects row path + column path; ⌘ toggles additively. Children of a selected group stay emphasised. ⌘C copies visible rows (selected ones when there is a selection) as TSV with flattened headers ("2025 / Q1 / Sales").
- Column widths: `format["columnWidths"][<row field caption>]` for row-header columns, `[<value caption>]` for all columns of that value ("Values" when values are on rows).

Additional matrix format keys:

| Card | Key | Default |
| --- | --- | --- |
| layout | stepped | true |
| layout | indent | 14 |
| layout | valuesOnRows | false |
| subtotals | rows, columns | true |
| subtotals | rowGrandTotal, columnGrandTotal | true |
| subtotals | label | "Total" |
| expandButtons | show | true |
| values | heatmap | false |
| totals | `<value name>` | sum |

Shared keys honoured by the matrix: `columnHeaders.*`, `values.fontSize/color/background/alternating/alternateBackground`, `grid.*`, `total.color/background`, `conditionalIcons.set`, `columnWidths`.

### Style presets

`ComponentStylePresets.presets(for: .table / .matrix)`: Default, Minimal, Bold header, Alternating rows, Contrast, Condensed, Flashy rows (+ Heat map for matrix).
Presets carry `.null` for keys they reset to the theme. The public signature has no theme, so colours are derived from `ThemeSpec.facet`;
`CmpTableFamily.presets(for:theme:)` (internal) derives them from any theme and should be preferred for dark themes.

### Limitations

- Word wrap uses one uniform row height (lines needed by the first 200 rows, capped at `values.maxWrapLines`), not per-row heights.
- Automatic column widths are measured from the first 300 rows.
- Matrix: no click-to-sort on headers (order follows the query / `spec.sort` applied by the host); `webURL`/`image` targets are table-only.
- Exclude on a multi-field point adds one inverted filter per field (FilterSpec is single-field), which excludes more than the exact combination.
- Accessibility exposes visible rows as row elements, not individual cells.
- `heatmap` type is not handled here (Charts).
## Single values

Shared format keys (card, cardLegacy, multiRowCard, kpi, gauge):

| Key | Default | Meaning |
| --- | --- | --- |
| `callout.size` | theme callout size (17 for multi-row card) | Maximum font size; the number always shrinks to fit its box |
| `callout.color` | theme callout / foreground | |
| `callout.bold` | true | |
| `callout.displayUnits` | `auto` | `auto`, `none`, `thousands`, `millions`, `billions`, `trillions` |
| `callout.decimals` | automatic | Decimal places |
| `callout.alignment` | `left` (card), `center` (cardLegacy, kpi) | `left`, `center`, `right` |
| `label.show` / `label.size` / `label.color` | true / theme label / secondary | Field caption under the value |
| `label.position` | `below` | `below`, `above` (card, cardLegacy) |

### `card` (new card)
- Wells: `values` (one callout per field), `category` (optional), plus reference columns (below).
- No category: callouts side by side, or stacked when narrow (`layout.orientation` = `auto` / `horizontal` / `vertical`),
  hairline dividers (`layout.dividers`, default on unless the accent bar is on), gap `layout.spacing` (16).
- **Reference labels** (target-style secondary values with % difference, coloured good/bad):
  a column in the data's `target` role is attached to the callout at the same position; and/or
  `format["reference"][<callout caption>] = <caption of another column>` attaches that column (it is then not drawn as its
  own callout). Keys: `referenceLabels.show` (true), `referenceLabels.showDifference` (true),
  `referenceLabels.higherIsBetter` (true). Difference = (value − reference) / |reference|.
- Accent bar: `accentBar.show` (false; true on small-multiple tiles), `accentBar.color` (theme accent), `accentBar.width` (3).
- Image: `image.show` (true when `spec.imageData` is set), `image.url` (http(s), file or data URI), `image.size` (36), `image.radius` (6).
- **Category small multiples**: with a `category` field each data row becomes a tile (title = category value) in a grid:
  `layout.columns` (automatic), `layout.spacing`, `cards.background` (true), `cards.border` (false), `cards.radius` (8).
  Tiles select like data points (`onSelect` with the category fields; ⌘ adds; click again clears) and dim with `emphasis`.
  The grid scrolls vertically when tiles would be shorter than 58 pt.
- Limitation: one image per card (no per-category images).

### `cardLegacy`
One number (first `values` field, first row) with its caption. Shared keys only.

### `multiRowCard`
One card row per data row. The first non-aggregate column (when there is more than one column) is the row title; other
fields flow as value-over-label in aligned columns and wrap when narrow; the list scrolls.
Keys: shared keys, `categoryTitle.size` (13), `categoryTitle.color`, `accentBar.show` (true) / `.color` / `.width`, `layout.dividers` (true).

### `kpi`
- Wells: `values` (indicator), `trendAxis`, `target` (goal). Rows must arrive ordered by the trend axis; the indicator is the
  last row with a value, the goal is the target on that row.
- Shows the indicator, "Goal 420K ↗ +9.0%" (distance = (value − goal) / |goal|) and a trend area behind.
- Keys: `trend.show` (true), `trend.direction` (`highIsGood` | `lowIsGood`), `trend.goodColor` / `badColor` / `neutralColor`
  (theme good / bad / accent), `goal.show` (true), `goal.showDistance` (true), `goal.label` ("Goal"), `date.show` (true, latest
  trend-axis value), `indicator.colorByStatus` (false — colour the number itself by status).

### `gauge`
- Wells: `values`, `minimum`, `maximum`, `target` (first row of each). Format fallbacks `gauge.min`, `gauge.max`, `gauge.target`.
  Without a maximum the scale ends at max(2 × value, 1.25 × target).
- Half-circle arc, target needle with label, min/max labels, callout in the centre.
- Keys: `gauge.fillColor` (accent), `gauge.trackColor`, `gauge.targetColor` (foreground), `gauge.thickness` (0.2 of radius),
  `gauge.showLabels` (true), `gauge.showTarget` (true), `gauge.showCallout` (true).

Presets: card (Minimal, Accent bar, Centered, Condensed, Contrast, Outlined tiles), cardLegacy (Minimal, Label above, Contrast),
multiRowCard (Minimal, Accent bar, Condensed), kpi (Minimal, Status colour).

## Page elements

### `textBox`
`spec.content` is a Markdown subset: `#`/`##`/`###` headings, `**bold**`, `*italic*`/`_italic_`, `<u>underline</u>`,
`~~strikethrough~~`, `[text](url)` (http, https, mailto open on click), `- ` bullets and `1. ` numbered lists (two spaces of
indent per nesting level), `^superscript^`, `~subscript~`, `<br>`, backslash escapes. Markers only take effect when closed.
- **Dynamic values**: `{{Measure Name}}` or `{{=DAX}}`. The renderer looks for a column in `data` whose field caption or
  column name equals the placeholder text (case-insensitive; for `{{=expr}}` a column named `=expr` or `expr`) and shows
  row 0 formatted with the column's format string. The app is expected to query those and supply them as columns.
  Unresolved placeholders are drawn as a quiet monospaced token.
- **Editing**: double-click (when interactive) shows a formatting bar (paragraph style, bold ⌘B, italic ⌘I, underline ⌘U,
  strikethrough, bulleted/numbered list, superscript, subscript, link ⌘K, insert dynamic value) over a source editor.
  Done / ⌘↩ (or the view disappearing) writes `spec.content` back through `onSpecChange`; Esc cancels.
  The editor edits the Markdown source (not WYSIWYG).
- Keys: `text.size` (13), `text.color`, `text.linkColor` (accent), `text.fontFamily`, `text.lineSpacing` (2),
  `text.alignment` (`left`|`center`|`right`), `text.verticalAlignment` (`top`|`middle`|`bottom`). Overflow scrolls.

### `image`
Source: `spec.imageData`, else `spec.content` as an http(s) URL (loaded asynchronously), `file://` URL / absolute path, or
`data:` URI. Keys: `image.scaling` (`fit` | `fill` | `normal` | `stretch`), `image.transparency` (0–100), `image.radius` (0).
With `spec.action` (kind ≠ none) a click calls `onAction`; `action.tooltip` is the hover text; `spec.altText` is the
accessibility label.

### `shape`
`shape.kind`: rectangle, roundedRectangle, ellipse, triangle, rightTriangle, diamond, pentagon, hexagon, octagon, arrow,
chevron, speechBubble, heart, star, pill, line. Keys: `shape.cornerRadius` (12), `shape.shadow` (false), `fill.show` (true),
`fill.color` (first theme data colour), `fill.transparency`, `outline.show` (false; true for line), `outline.color`,
`outline.width` (1; 2 for line), `outline.style` (`solid`|`dashed`|`dotted`), text inside via `text.text`, `text.size`,
`text.color` (automatic contrast on the fill), `text.bold`, `text.alignment`, `text.padding`; for lines
`shape.lineDirection` (`auto`|`horizontal`|`vertical`|`diagonalDown`|`diagonalUp`), `shape.startCap` / `shape.endCap`
(`none`|`arrow`|`dot`). The shape applies `spec.frame.rotation` itself — the host must not rotate the visual a second time.
An optional `spec.action` is triggered on click.

### `button`
- `button.icon`: blank, leftArrow, rightArrow, reset, back, information, help, qna, bookmark, navigation, custom
  (`spec.imageData`), or any SF Symbol name. `text.text` is the label. `icon.placement` (`left`|`right`|`above`|`below`), `icon.size`.
- Click → `context.onAction(spec.action ?? ActionSpec())`. `button.enabled` (true): set it to false when the action is
  unavailable (e.g. drillthrough without a selection) to get disabled styling and no clicks. `button.selected` (false).
- Styling: `button.style` (`tinted` default, `filled`, `outline`, `plain`, `soft`), `button.shape`
  (`roundedRectangle`|`rectangle`|`pill`), `button.radius` (8). Per-state overrides for default / hover / pressed / selected /
  disabled on the cards `fill`, `outline`, `text`, `icon`: keys `color`, `hoverColor`, `pressedColor`, `selectedColor`,
  `disabledColor` (a state without its own key falls back to `color`, then to the style). Also `fill.show`,
  `fill.transparency`, `outline.show`, `outline.width`, `text.size`, `text.bold`, `text.alignment`.
- Keyboard: focusable, Space/Return activates, visible focus ring. The button applies `spec.frame.rotation` itself.

### `pageNavigator`, `bookmarkNavigator`
Buttons generated from `context.pages` / `context.bookmarks`; the item matching `context.currentPageID` /
`context.activeBookmarkID` is selected. Click → `onAction` with `kind = .pageNavigation, pageID` / `kind = .bookmark, bookmarkID`.
Keys: `navigator.orientation` (`horizontal`|`vertical`|`grid`; default by aspect ratio), `navigator.columns` (2, grid),
`navigator.spacing` (6), `navigator.buttonHeight` (34, vertical) and all button styling keys (default style `soft`).
Strips that don't fit scroll. Bookmark groups are not shown separately (the host passes a flat list).

## Scripted and embedded visuals

- `pythonVisual`, `rVisual`: if `spec.imageData` holds a rendered plot it is shown (aspect fit); otherwise a placeholder
  explains script visuals. This module never executes scripts — the app runs them and stores the output image in `imageData`.
- `paginatedReport`, `powerApps`, `metrics`: when `spec.content` is an https URL (`EmbedAddress.httpsURL`) and the
  context is interactive, a `WKWebView` shows it (loading bar, readable failure state); non-interactive contexts show a
  static card with the host name. Any other scheme, http included, is refused. Without a source the placeholder says what
  the visual needs, with a "Set up…" button when the host sets `VisualContext.onSetUp`. Sign-in to the services happens
  inside the web view.
- `powerAutomate`: with an https flow URL in `spec.content` a "Run flow" button (`text.text` overrides the label) calls
  `VisualContext.onRunFlow` (disabled when nil); the host posts the visual's data. With no URL and a `spec.action`
  (kind ≠ none) the button calls `onAction` instead.
- `keyInfluencers`, `decompositionTree`, `narrative`, `qna`: `ComponentVisuals.view` returns nil (app-supplied).

## Slicers

Types: `slicer`, `buttonSlicer`, `listSlicer`, `inputSlicer` (files in `Components/Slicers/`). Values come from
the `data` column(s) in role `field` (distinct, first-seen order, formatted with the column format; nulls show as
"(Blank)"). The current state is read from `spec.slicerState`; every change is sent as a complete new
`SlicerState` through `context.onSlicerChange`. With no field a placeholder is shown. Nothing is interactive when
`context.isInteractive` is false. The host (`VisualView`) draws the title; the slicer draws only the body.

### Styles and what each writes

| Type / `format["slicer"]["style"]` | UI | `SlicerState` fields written |
| --- | --- | --- |
| `slicer` `list` (default) | Checkbox list (radio when `singleSelect`), optional search and "Select all" | `selected` |
| `slicer` `dropdown` | Closed field with summary ("All", up to 3 labels, "n selected"); popover with the list + search | `selected` |
| `slicer` `tile` | Wrapping pills | `selected` |
| `slicer` `list`/`dropdown`/`hierarchy` with 2+ fields | Expandable tree, tri-state checks, search keeps ancestors/descendants | `hierarchyPaths` |
| `slicer` `between` | Two inputs + two-thumb slider (numbers), two date fields with calendar popover + slider (dates) | `rangeLow`, `rangeHigh` |
| `slicer` `before` | One input + slider | `rangeHigh` (`rangeLow = .null`) |
| `slicer` `after` | One input + slider | `rangeLow` (`rangeHigh = .null`) |
| `slicer` `relativeDate` | Last/This/Next · N · days, weeks, calendar weeks, months, calendar months, years, calendar years; "Include today"; resolved range shown | `relative` |
| `slicer` `relativeTime` | Last/This/Next · N · minutes, hours | `relative` |
| `buttonSlicer` | Grid of rounded buttons, optional images, scroll or pagination | `selected` |
| `listSlicer` | Compact list with highlight + checkmark; tree with 2+ fields; `dropdown` mode | `selected` or `hierarchyPaths` |
| `inputSlicer` | Operator menu + text field + chips | `selected` (applied values) and `text` (same values joined by "\n") |

Details the host's filter engine needs:

- **`selected`** holds the raw `Value`s of the field column. Empty = no filter.
- **`hierarchyPaths`**: each entry is a level-path. A path shorter than the hierarchy depth selects that whole
  subtree. The set is kept normalised (when all children of a node are selected, only the parent path is stored).
  Deselecting a node under a selected ancestor replaces the ancestor path with the remaining sibling paths.
- **Ranges** are inclusive. Values have the column's kind: `.date` for date columns, `.int` for whole-number
  columns, otherwise `.double`. An unset bound is `.null`. Dates snap to whole UTC days; decimals to ~3 significant
  steps of the data range. Slider bounds are the min/max of the field column in `data` (fallback 0…100, or the last
  year for dates, when the column is empty). A drag commits once on release, not on every tick.
- **Relative**: a `RelativeDateFilter` (direction, count ≥ 1, unit, includeToday). Until the reader changes
  something, `relative` stays nil and the body shows "No filter applied". The displayed range is computed by
  `CmpSlRelative.range(_:now:)` (internal, UTC calendar, Sunday week start): rolling units count back/forward from
  today (with/without today), calendar units are whole periods before/after the current one, "this" is the current
  period. The host should apply the same definition; it is not exported as public API.
- **Input slicer**: the operator is a spec setting, `format["slicer"]["operator"]`, written through
  `context.onSpecChange` when the reader changes it. Values: `contains`, `startsWith`, `endsWith`, `equals`,
  `notContains`, `notEquals`, `greaterThan`, `greaterOrEqual`, `lessThan`, `lessOrEqual`. Typed text is applied on
  Return; a paste containing line breaks or tabs is applied immediately. Text is split on newline, tab, comma and
  semicolon (double quotes keep separators inside one value), trimmed and de-duplicated. On numeric columns terms
  that parse become numbers. Comparison operators keep one value (the latest). Matching semantics are public:

```swift
public enum CmpSlInputMatcher {
    /// Positive ops: any term matches. Negative ops: no term matches. Comparisons: first term.
    /// Case-insensitive; `*` and `?` are wildcards in equals / notEquals.
    public static func matches(_ value: Value, terms: [Value], op: String) -> Bool
}
// host: rows.filter { CmpSlInputMatcher.matches($0[col], terms: state.selected, op: spec.fmtString("slicer", "operator", "contains")) }
```

- **Button slicer images**: add a second field to the `field` well whose values are image URLs (`http(s)://…png|jpg|…`)
  or `data:image/…;base64,` URIs; it is used as the picture for the first field's value. Remote images load with
  `AsyncImage`.

### Shared behaviour

- **Clear selections**: an eraser button appears in the title row on hover whenever the state is active and writes
  an empty `SlicerState()`. `format["slicer"]["showClear"]` = `hover` | `always` | `never`.
- **Apply button** (`format["slicer"]["applyButton"] = true`): changes (including clear) are staged inside the view
  and only sent through `onSlicerChange` when Apply is clicked (⌘Return). The button is disabled with no pending
  change; staged changes are dropped if `spec.slicerState` changes from outside. The staged state is view-local, so
  it is lost if the host recreates the view.
- **Selection rules**: `singleSelect` (radio, at most one); `multiSelectWithCommand` (plain click replaces, ⌘-click
  toggles); `forceSelection` (the last value cannot be deselected). Not applied to hierarchy trees except
  `singleSelect`.
- **Keyboard**: each list / tree / tile set / button grid is one focus stop. ↑↓ (and ←→ in grids and tiles) move,
  Space toggles, Return acts as a plain click, ⌘A selects all, Home/End jump; in trees → expands and ← collapses or
  moves to the parent. Dropdowns open with Space/Return/↓. Slider thumbs are focusable and move with arrow keys
  (⇧ = ×10). Text fields, menus and search are standard controls. Focus rings are drawn only for keyboard focus.
- **Accessibility**: rows, tiles and buttons expose label, selected/partially selected value, button + selected
  traits and a default action; slider thumbs are adjustable elements; fields and menus are labelled.
- **Tooltips**: every row, tile, button and chip shows its full text on hover; thumbs show their value.

### Format keys

Card `slicer`:

| Key | Kind | Default | Applies to |
| --- | --- | --- | --- |
| `style` | list, dropdown, tile, between, before, after, relativeDate, relativeTime, hierarchy | `list` | slicer |
| `dropdown` | bool | false | listSlicer |
| `singleSelect` | bool | false | list, dropdown, tile, hierarchy, buttonSlicer, listSlicer |
| `multiSelectWithCommand` | bool | false | flat selection styles |
| `forceSelection` | bool | false | flat selection styles |
| `selectAll` | bool | false | list, dropdown, hierarchy, listSlicer |
| `search` | bool | false (true in dropdown) | list, dropdown, hierarchy, listSlicer |
| `slider` | bool | true | between, before, after |
| `applyButton` | bool | false | all |
| `showClear` | hover, always, never | `hover` | all |
| `fontSize` | number | theme label size + 1 | all |
| `itemPadding` | number | 4 | all |
| `color` | colour | theme foreground | all |
| `selectedColor` | colour | theme accent | all |
| `operator` | see above | `contains` | inputSlicer |
| `showOperator` | bool | true | inputSlicer |
| `placeholder` | string | "Type or paste values" | inputSlicer |

Card `buttons` (buttonSlicer): `columns` (0 = automatic from `minWidth`), `rows` (0 = automatic; a fixed row count
stretches buttons to fill the height), `overflow` (`scroll` | `pagination`), `spacing` 8, `radius` 8, `minWidth` 88,
`height` (0 = automatic), `fill` (colour), `border` true, `showImages` true, `imageSize` 28. Columns are reduced
automatically so a button is never narrower than 60 pt.

The host cards `title`, `divider`, `border`, `padding` are used by presets. All of this is exposed through
`ComponentFormatCatalog.properties(for:)`; presets through `ComponentStylePresets.presets(for:)`: Minimal, Bold
header, Condensed, Contrast for all four types, plus Pills and Searchable list (`slicer`), Rounded and Square
outline (`buttonSlicer`).

### Limitations

- Distinct values and the hierarchy tree are rebuilt from `data` on each view update (no caching); fine for
  typical slicer cardinalities, not tuned for hundreds of thousands of distinct values.
- Popover content (dropdown list, calendar) uses the system popover chrome; the content is themed but the popover
  arrow follows the app appearance.
- Relative slicers anchor on the current clock time at render; there is no custom anchor date setting.
- Hover and pressed states are fixed (derived from the theme); there are no per-state colour keys for button
  slicers beyond `fill` and `selectedColor`.
- The input slicer only edits state; filtering is done by the host (use `CmpSlInputMatcher`).
## Maps and Gantt

Source: `Sources/FacetVisuals/Components/Maps/`. Entry point `CmpMapFamily.view(_:)` (reached through
`ComponentVisuals.view`). Types handled: `map`, `azureMap`, `filledMap`, `shapeMap`, `gantt`.
Format keys are listed by `ComponentFormatCatalog.properties(for:)`; presets by
`ComponentStylePresets.presets(for:)` (map/azureMap: Bubbles, Muted, Heat map, Route, Satellite;
gantt: Standard, Condensed, Minimal, Progress).

### `map` and `azureMap` (MapKit)

Both types render identically. Wells: `location` (text, geocoded) **or** `latitude` + `longitude`
(used when both are present; rows with out-of-range values are skipped), `size` (bubble radius,
area-proportional: `r = minSize + (size − minSize)·√(|v| / max|v|)`), `legend` (categorical colour from
`theme.dataColors`, one legend entry per distinct value), `tooltips` (extra rows in the tooltip).

- **Layers** (any combination): bubble (screen-sized annotation views that do not scale with zoom),
  heat map (density grid rendered at ¼ resolution with a quartic kernel, colour-mapped
  `theme.center → good → neutral → bad`, scaled up bilinearly; re-rendered when the visible region
  changes; weighted by `size`), path (one `MKPolyline` per legend group connecting points in data-row order).
- **Selection**: click a bubble → `context.onSelect([point], additive)` (⌘ = additive); click the map
  background clears; the toolbar (top-left) switches between pan, rectangle select and lasso select
  (drag; ⌘ adds), plus zoom-to-fit. The selection point uses the `location` + `legend` fields
  (or all grouping columns when there is no `location`). Emphasis via `context.emphasis`; selected
  bubbles get an accent ring.
- **Keyboard**: Tab focuses the map; arrow keys step through points (shows the tooltip card),
  Space/Return selects, Esc clears. Bubbles expose accessibility label/value/selected.
- **Tooltips**: AppKit tooltips on bubbles (title = location or legend value, one line per other column).
- **Geocoding** (`CmpGeocoder.shared`, used only when there is no latitude/longitude pair):
  `CLGeocoder.geocodeAddressString`, one request at a time, 1.1 s apart; network/rate-limit errors
  back off 20 s and retry twice (not cached); "no result" is cached as a miss. Cache file:
  `~/Library/Application Support/Facet/GeocodeCache.json`
  (`{ "<normalised query>": {"lat":…, "lon":…} | {"miss": true} }`), saved every 10 lookups and when the
  queue drains. A pill shows "Locating n of N…", service errors, and "n locations not found".

| Card | Key | Default | Meaning |
| --- | --- | --- | --- |
| `map` | `style` | `standard` | `standard` \| `satellite` \| `hybrid` \| `muted` |
| `map` | `autoZoom` | `true` | Fit the view to the data whenever the plotted points change |
| `map` | `showControls` | `true` | MapKit zoom controls and compass |
| `map` | `selectionTools` | `true` | Pan / rectangle / lasso / fit toolbar |
| `layers` | `bubble` / `heatmap` / `path` | `true` / `false` / `false` | Layer switches |
| `bubbles` | `size` | `22` | Largest bubble radius (pt) |
| `bubbles` | `minSize` | `4` | Smallest bubble radius (pt) |
| `bubbles` | `transparency` | `25` | Percent |
| `bubbles` | `color` | first theme data colour | Colour when there is no legend |
| `bubbles` | `outline` | `true` | 1-pt card-coloured ring |
| `heatmap` | `radius` / `intensity` / `transparency` | `28` / `1` / `30` | Kernel radius (pt), gain, percent |
| `path` | `width` / `color` | `2` / legend colour | Line style |
| `legend` | `show` / `position` | `true` / `top` | `top` \| `bottom` |
| `tooltips` | `show` | `true` | |

A `dataPointColor` conditional format on the `size` field colours bubbles when there is no legend.

### `filledMap` and `shapeMap` (choropleth)

Wells: `location` (matched to shape features), `values` (first value field drives the colour ramp),
`legend` (categorical colours when there is no `values` field), `tooltips`.

**Shape-file contract.** Supply GeoJSON or TopoJSON text in `spec.content`, or in
`format["shape"]["geojson"]` (a JSON string, or an inline JSON object). Accepted: GeoJSON
`FeatureCollection`, `Feature` or a bare geometry (Point, MultiPoint, LineString, MultiLineString,
Polygon with holes, MultiPolygon, GeometryCollection); TopoJSON `Topology` — quantized
(`transform.scale/translate`, delta-encoded arcs) or unquantized, negative arc indices (`~i`, reversed),
Polygon / MultiPolygon / LineString / MultiLineString / Point / MultiPoint / GeometryCollection objects
(a nested collection that carries its own `id`/`properties` becomes one feature). Parse errors are
`CmpGeoError` (`LocalizedError`) and are shown in the visual. Parsed files are cached (last 8).

**Matching.** Location text is compared case-, whitespace- and diacritic-insensitively against, in
priority order: the feature `id`; the properties `name`, `NAME`, `Name`, `admin`, `ADMIN`, `name_long`,
`NAME_LONG`, `NAME_1`, `name_en`, `NAME_EN`, `nom`, `title`, `label`; then every other string/number
property. Set `format["shape"]["matchProperty"]` to restrict matching to one property (plus `id`).
Unmatched locations are counted in the legend row ("n unmatched", names in its tooltip).

**Rendering.** Polygons are projected (Mercator for lon/lat files, y-flipped identity for pre-projected
files; override with `shape.projection`), fitted to the visual and filled in a SwiftUI `Canvas`
(even-odd, so holes work). Colour: `dataPointColor`/`background` conditional format on the value field
if present, else a gradient `fill.minColor → (fill.midColor) → fill.maxColor` over the value range.
Gradient legend with min/max, hover tooltip card, click to select (⌘ additive, click empty clears),
pinch to zoom and drag to pan when zoomed (zoom-to-fit button appears), arrow keys step through regions
with data, Space/Return selects, Esc clears. Lines are stroked, points drawn as dots.

| Card | Key | Default | Meaning |
| --- | --- | --- | --- |
| `shape` | `geojson` | — | Shape file when `spec.content` is empty |
| `shape` | `projection` | `auto` | `auto` \| `mercator` \| `equirectangular` \| `identity` (y up) \| `screen` (y down) |
| `shape` | `matchProperty` | `""` | Restrict name matching to this property |
| `shape` | `showUnmatched` | `true` | Draw regions that have no data (in `fill.emptyColor`) |
| `shape` | `labels` | `false` | Region name labels (hidden unless ≥ 60 % of them fit) |
| `shape` | `outlineColor` / `outlineWidth` | card colour / `0.75` | |
| `fill` | `minColor` / `midColor` / `maxColor` | `theme.minimum` / none / `theme.maximum` | Ramp |
| `fill` | `emptyColor` | faint foreground tint | Regions without data |
| `legend` | `show` / `position` | `true` / `bottom` | |
| `tooltips` | `show` | `true` | |

**Limitation — no built-in boundaries.** Facet ships no country/state boundary data. Without a shape
file these two types fall back to the MapKit bubble map: locations are geocoded and drawn as bubbles
sized and gradient-coloured by `values`, with the hint "Add a GeoJSON shape file for filled regions".
The `map.*` and `bubbles.size/minSize/transparency` keys apply to this fallback (`bubbles.size` defaults
to 18). The choropleth has no rectangle/lasso selection (those are on the MapKit maps only).

### `gantt`

Wells: `task` (row label), `start`, `end` (dates, serial numbers or date strings; missing end or
`start == end` → milestone diamond), `progress` (0…1, or 0…100 when the column maximum exceeds 1.5),
`legend` (bar colour + legend), `tooltips`. Rows are drawn in data order; rows without a valid start
are skipped.

- Time axis adapts to pixel density: day cells (≥ 16 pt/day, weekends shaded), weeks (Monday start),
  months, quarters, years — with a grouping tier above (month over day/week, year over month/quarter)
  whose label stays pinned to the left edge while scrolling. Labels are thinned so they never overlap.
- Bars: rounded; with a progress field the bar is a 30 % tint with the completed part solid; optional
  "40%" labels. Today line (`theme.bad` by default). Date-only end dates include that whole day
  (`gantt.inclusiveEnd`).
- Rows shrink to 14 pt before the chart scrolls vertically; rows are drawn in lazy 150-row chunks.
  Label column hides below 240 pt width; the legend hides in small visuals.
- Zoom: `+`/`−`/`0` keys, pinch, or the hover toolbar; the timeline scrolls horizontally when zoomed and
  the header stays in sync. Zoom is persisted to `format["gantt"]["zoom"]` through `context.onSpecChange`.
- Selection: click a bar/milestone or a task label → `context.onSelect` with the `task` + `legend`
  values (⌘ additive; click empty space clears); emphasis dims other tasks; selected rows are tinted and
  ringed. Keyboard: ↑/↓ move the focus row (scrolls into view), Space/Return selects, Esc clears.
  Task labels are accessibility buttons with a "start to end, n% complete" value.
- Tooltip card on bar hover: task, every other column, plus computed Duration.

| Card | Key | Default | Meaning |
| --- | --- | --- | --- |
| `gantt` | `rowHeight` | `28` | Preferred row height (pt) |
| `gantt` | `barRadius` | `4` | Bar corner radius |
| `gantt` | `barColor` | first theme data colour | Bar colour without a legend |
| `gantt` | `milestoneColor` | task colour | |
| `gantt` | `showLabels` | `true` | Task label column |
| `gantt` | `labelWidth` | `0` (automatic, ≤ 34 % of width) | |
| `gantt` | `progressLabels` | `false` | Percent label after each bar |
| `gantt` | `gridlines` | `true` | |
| `gantt` | `weekends` | `true` | Weekend shading at day scale |
| `gantt` | `todayLine` / `todayColor` | `true` / `theme.bad` | |
| `gantt` | `inclusiveEnd` | `true` | Midnight end dates extend to the end of that day |
| `gantt` | `zoom` | `1` | 1 = whole schedule fits; up to 60 |
| `legend` | `show` | `true` | |
| `tooltips` | `show` | `true` | |

### Limitations

- MapKit views (base tiles, bubbles, path) cannot be captured by the offscreen snapshot harness, so
  `map`/`azureMap` and the no-shape fallback were verified by compile and by logic assertions only
  (annotation/overlay counts, auto-zoom fit, bubble styling, selection callback, heat-map image), not by
  looking at a rendered map. They need a look in the running app.
- Bubble tooltips on the MapKit maps are plain AppKit tooltips, not the themed tooltip card.
- The heat-map overlay sits above bubbles when both layers are on.
- No drive-time selection, no reference layers, no clustering; base-map tiles need a network connection.
- Geocoding depends on Apple's service and its rate limits; large location lists resolve at ~1/s on
  first use (then come from the cache).
- Gantt: no dependency arrows, no grouping/collapsing of rows, time zone is UTC throughout.
