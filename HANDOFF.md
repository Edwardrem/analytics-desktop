# Handoff — finish the macOS BI app

You are taking over a native macOS (Apple silicon, arm64) business-intelligence authoring app written in
Swift/SwiftUI as a SwiftPM package. Goal: cover every feature in
`Microsoft Power BI Desktop — Complete Feature Reference.md` (repo root), go beyond it, follow Jony Ive /
Dieter Rams design principles, and let the user add their Microsoft account to reach their files.

## Verified state (13 Nov 2026)
- `swift build` → **Build complete**. `swift test` → **all suites pass** (about 110 tests, 0 failures).
- `Scripts/build-app.sh [--open]` builds `dist/Microsoft Power BI.app` (release, arm64, ad-hoc signed).
- No third-party dependencies. macOS 15+, Swift 5 language mode.

| Target | What it is | Lines |
| --- | --- | --- |
| `FacetCore` | Value/DataTable, semantic model, report/visual/filter/bookmark/theme types, `.facet` package I/O, formatting | 2.0k |
| `FacetDesign` | Design tokens + small components (`Design.Space/Typeface/Palette`, `InspectorSection`, `IconButton`…) | 0.2k |
| `FacetDAX` | DAX lexer/parser/evaluator, catalog, formatter, visual query layer | 8.5k |
| `FacetQuery` | Power Query M interpreter, connectors, transforms (see `Sources/FacetQuery/API.md`) | 5.6k |
| `FacetAnalytics` | Forecast, anomalies, clustering, key influencers, narrative, Q&A parser, statistics | 5.1k |
| `FacetCloud` | Microsoft sign-in (OAuth PKCE loopback + device code), Keychain, Graph/OneDrive, Power BI + Fabric REST, assistant LLM client | 6.9k |
| `FacetInterop` | ZIP, TMDL, PBIP/PBIR, PBIX/PBIT import, themes, xlsx/csv export, MCP server | 5.0k |
| `FacetVisuals` | Chart + component renderers (`Components/API.md`), host `VisualView` | 16.2k |
| `MicrosoftPowerBI` | The app: store, canvas, shell, panes, DAX query view, Power Query editor, account, assistant | 20.4k |

Architecture to respect: all document writes go through `DocumentStore.mutate(...)` (undo + invalidation);
features plug in via `App/Features.swift` builders and `AppCommands.register`, wired in
`App/FeatureRegistration.swift`; engines are reached through `Services/Services.swift` + `Bridge/LiveServices.swift`.

## Remaining work, in priority order
1. **Launch and smoke-test the real app.** Run `Scripts/build-app.sh --open`, load the sample data
   (Data ▸ Load Sample Data), and fix whatever is broken: visuals rendering, cross-filter/highlight, slicers,
   drill, undo/redo, save/open of `.facet`, PDF export. Nobody has driven the running app end to end yet.
2. **Format pane** — `InspectorPane.format` has no builder (shows a placeholder). Build it in
   `Sources/MicrosoftPowerBI/Panes/FormatPane/`: Visual and General tabs, search, per-card reset, generated from the
   format catalogs in `FacetVisuals` (`ComponentFormatCatalog`, the chart equivalent), style presets, on-object basics.
   Writes go through `store.updateVisual(id, invalidates: .layout) { $0.setFmt(card, key, value) }`.
3. **Table view and Model view** — `WorkspaceView.table` and `.model` have no workspace builder. `Modeling/` has the
   grid (`TableView/DataGrid.swift`), `FormulaBar`, ops, selection and some dialogs, but `ModelingFeature.register()`
   only registers commands. Build and register: Table view (grid + column/measure/table tools), Model view
   (diagram with draggable table cards, relationship lines, drag-to-create, layout tabs, properties panel, model
   explorer), and the missing dialogs: manage relationships (+autodetect), roles (RLS/OLS) + View as, parameters,
   calculation groups, UDFs, hierarchies, groups/bins, mark as date table, calendars, incremental refresh,
   aggregations, perspectives, translations, synonyms, prep data for AI. Verify every `model.*` command id used in
   `Shell/DocumentWindow.swift` and the Data pane is registered and works.
4. **TMDL view** — `WorkspaceView.tmdl` has no builder. Use `FacetInterop` TMDL serialize/parse/apply with a
   `CodeEditor` (`LanguageSupport.tmdl`), object tree, apply with diff preview.
5. **Engine test depth.** `Tests/FacetDAXTests` covers only pure functions/catalog/formatter; add a star-schema
   fixture and test filter context, CALCULATE, context transition, relationships, time intelligence, RANKX/TOPN,
   window functions, calc groups, UDFs, RLS, visual calculations and `visualData` (Top N, relative date, highlight
   baseline, drill, totals). `Tests/FacetQueryTests` covers only the M language; add connectors (CSV, JSON, XLSX,
   SQLite + folding), every `Transform`, step editing, privacy firewall, column-from-examples, fuzzy merge.
   Fix what the new tests expose.
6. **Feature-reference audit.** Walk sections 1–14 of the reference and list each item as done / partial / missing
   in `STATUS.md`; then close gaps (Get Data catalog coverage, Power Query editor transforms + profiling +
   dependencies view, mobile layout, report page tooltips, drillthrough buttons, personalize visuals, publish to
   Power BI, OneDrive open/save UI, OneLake catalog, sensitivity labels, external tools, MCP server toggle,
   auto-recovery, PBIP save + instant reload, .pbit/.pbids).
7. **Microsoft account end to end.** Code exists in `FacetCloud` + `Account/AccountFeature.swift` but has never
   run against live Microsoft services. It needs the user's own Entra app registration client ID (Settings ▸
   Microsoft account): redirect URI `http://localhost`, public client flows enabled, Graph `User.Read
   Files.ReadWrite.All Sites.Read.All offline_access` and Power BI delegated permissions. Do not hard-code any
   client ID or secret; tokens stay in the Keychain.
8. Remove leftovers once unused: `Services/ShellStubs.swift` (`FACET_SHELL_ONLY`), the `.build-*` scratch dirs.
   Write a short `README.md` (build, run, architecture, limitations).

## Rules
- Work only inside this repository. Do not `git push`, do not delete anything outside it, do not commit unless asked.
- Keep `swift build` and `swift test` green after every step; report failures honestly with their output.
- Real implementations only — no fake data, no dead buttons. If something needs an external service or driver,
  wire the real integration and fail with a clear, actionable message.
- Design: calm, native macOS; `FacetDesign` tokens only; hairlines and whitespace, not boxes; every icon button has
  `.help`; light and dark mode; works at the 300 pt inspector width.
- Known limit to state plainly, not work around: the `DataModel` stream inside `.pbix` is a compressed binary that
  cannot be decoded, so `.pbix` import brings pages and queries but not data or measures (`.pbit`/`.pbip` bring the model).
- Open question for the owner (do not decide alone): the product is currently named "Microsoft Power BI" with
  bundle id `com.facet.app`. It is not a Microsoft product, so it cannot be distributed under that name.
