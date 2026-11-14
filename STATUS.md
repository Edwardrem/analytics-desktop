# Analytics Desktop: feature status

This file compares Analytics Desktop, a native macOS app, with every item in `Microsoft Power BI Desktop — Complete Feature Reference.md`. It reflects branch `delegate/base` as of 14 November 2026, and was checked by reading the code.

How to read the statuses:
- **Done**: the feature is real and you can reach it in the app.
- **Partial**: it works, with the gaps given in the note.
- **Missing**: it isn't built.
- **N/A**: it is Windows-only or service-only, so it doesn't apply to a Mac authoring app.

Microsoft cloud features (sign-in, OneDrive and SharePoint, OneLake, Publish, sensitivity labels) have only been tested against local stand-in servers, never against live Microsoft services. Their rows say "not live-tested". The assistant features use the user's own Anthropic API key and have been tested only against an in-process stub. Their rows say "stub-tested".

## Summary

| Section | Done | Partial | Missing | N/A | Total |
| --- | --- | --- | --- | --- | --- |
| 1. Overview and workspace | 23 | 3 | 0 | 10 | 36 |
| 2. Getting data | 10 | 7 | 10 | 4 | 31 |
| 3. Power Query Editor | 27 | 2 | 1 | 0 | 30 |
| 4. Data modeling | 21 | 6 | 3 | 0 | 30 |
| 5. DAX and calculations | 21 | 1 | 0 | 0 | 22 |
| 6. Visualizations | 17 | 7 | 3 | 1 | 28 |
| 7. Report design and formatting | 20 | 7 | 0 | 0 | 27 |
| 8. Interactivity and navigation | 24 | 4 | 1 | 0 | 29 |
| 9. AI and Copilot | 15 | 5 | 1 | 1 | 22 |
| 10. Security and governance | 7 | 3 | 3 | 0 | 13 |
| 11. Performance and optimisation | 7 | 4 | 0 | 0 | 11 |
| 12. Developer and pro-code features | 7 | 3 | 2 | 2 | 14 |
| 13. Files, publishing, and export | 11 | 3 | 1 | 0 | 15 |
| 14. Options, settings, and preview features | 11 | 10 | 3 | 1 | 25 |
| 15. What Desktop does not do | 1 | 1 | 0 | 10 | 12 |
| **All** | **222** | **66** | **28** | **29** | **345** |

Section 15 lists what Power BI Desktop itself does not do, so N/A there is the expected result. Its Done and Partial rows are extras.

## Not possible here

These can't be built in this app, or can't be confirmed working:
- **Live Microsoft services.** Without the user's own Entra app registration and credentials, sign-in, Graph, Power BI, Fabric and Purview can't be run end to end, so those features stay "not live-tested".
- **Custom `.pbiviz` visuals.** They need Power BI's JavaScript visual host and its APIs. The app has no host for them.
- **`.mez` / `.pqx` custom connectors.** They need the Power Query SDK runtime. The M engine here can't load them.
- **Database drivers.** SQL Server, Oracle, PostgreSQL, MySQL, ODBC, OLE DB, Access and the other databases need vendor drivers or Windows providers, which the app doesn't ship. SQLite is built into macOS.
- **Direct Lake and service-only features.** Direct Lake needs Fabric capacity. The features in section 15 run in the Power BI service.
- **ArcGIS Maps.** It is a licensed Esri service and visual.

## 1. Overview and workspace

| Feature | Status | Notes |
| --- | --- | --- |
| Edition: Microsoft Store | N/A | Windows Store distribution; this is an ad-hoc-signed .app |
| Edition: download .exe | N/A | Windows installer and silent switches |
| Edition: Desktop for Report Server | N/A | Report Server is a Windows server product |
| Requirement: Windows 10 / Server 2016 / ARM | N/A | Targets macOS 15+ on Apple silicon instead |
| Requirement: .NET 4.7.2 | N/A | Native Swift, no .NET |
| Requirement: WebView2 | N/A | WKWebView is part of macOS |
| Requirement: memory | N/A | Windows sizing guidance |
| Requirement: processor | N/A | arm64 only |
| Requirement: display 1440x900 | N/A | The window opens at 1440x900 by default |
| Requirement: virtual desktops | N/A | Azure Virtual Desktop / Citrix guidance |
| Report view | Done | Canvas, pages, filters, formatting, Present mode |
| Table view | Done | View-only sort and filter, new column and table, big tables off the main thread |
| Model view | Done | Diagram, layout tabs, Properties, model explorer |
| DAX query view | Done | See §5 |
| TMDL view | Done | Script, validate, apply with diff preview |
| Ribbon: File | Partial | Open, save, PDF, PBIP, .pbit, OneDrive/SharePoint, theme; no Import of Excel workbook contents; New only on ⌘N; Options are in the Settings window |
| Ribbon: Home | Done | All groups wired; Copilot is the Assistant group, with Summarize Page and Summarize Report |
| Ribbon: Insert | Done | Pages, visuals, AI and Power Platform visuals, elements, sparklines |
| Ribbon: Modeling | Done | Relationships, calculations, parameters, roles, Q&A setup, calc groups, functions |
| Ribbon: View | Done | Themes, page view, mobile, gridlines, snap, lock, pane toggles |
| Ribbon: Optimize | Done | Pause and refresh visuals, presets, slicer buttons, Performance analyzer |
| Ribbon: Help and External tools | Partial | Learning links, About, .pbitool.json launchers; diagnostics are in Settings; %server%/%database% tools refused (no model endpoint) |
| Ribbon: contextual tabs | Partial | Format and Data/Drill work; Table, Column and Measure tools only appear in Table and Model view |
| Pane: Build (Visualizations) | Done | Wells, analytics, visual calcs, conditional formats |
| Pane: Data | Done | Search (also synonyms), folders, hierarchies, date hierarchies, context menus |
| Pane: Format | Done | See §7 |
| Pane: Filters | Done | See §8 |
| Pane: Bookmarks | Done | See §8 |
| Pane: Selection | Done | Layers, tab order, mobile tab |
| Pane: Sync slicers | Done | See §8 |
| Pane: Performance Analyzer | Done | Per-visual DAX, visual display and other time; copy query; export log |
| Pane: Properties (Model view) | Done | Multi-select editing |
| Pane: Theme | Done | Also hosts page and report settings |
| Pane: Copilot | Done | The Assistant pane; see §9 |
| Pane docking, collapse to strip | Done | Labelled strips; collapses on narrow windows |
| Window light / dark / system | Done | Settings ▸ Window theme |

## 2. Getting data

| Feature | Status | Notes |
| --- | --- | --- |
| File: Excel (.xlsx, .xlsm), Text/CSV, XML, JSON, Folder | Done | Navigator over sheets and tables, delimiter and header detection, folder combine |
| File: .xls/.xlsb, PDF, Parquet, SharePoint folder | Missing | Listed, dimmed with a reason, cannot be started; no reader or SharePoint access in the engine |
| Database: SQLite | Done | Tables and views, optional SQL statement with approval, Import or DirectQuery |
| Database: SQL Server, Oracle, PostgreSQL, MySQL, Db2, Teradata, SAP, Snowflake, Redshift, BigQuery, SSAS | Missing | Listed, dimmed: "Needs a database driver"; cannot be started |
| Database: Access | N/A | Listed, dimmed as a Windows-only provider |
| Microsoft Fabric connectors | Missing | Listed and dimmed; no Fabric connector in the engine (see OneLake catalog) |
| Power Platform (Dataverse, dataflows) | Missing | Listed, dimmed with a reason |
| Azure connectors | Missing | Listed, dimmed with a reason |
| Online services (SharePoint list, Dynamics 365, Salesforce, Google/Adobe Analytics, GitHub, Exchange, Outlook Mail) | Missing | Listed, dimmed with a reason |
| Other: Web, OData feed, Python script, R script, Blank query | Done | Web reads CSV, JSON, XML, Excel and HTML tables; scripts need permission and a local interpreter |
| Other: ODBC, Spark, HDFS, Exchange, SharePoint list (on-premises) | Missing | Listed, dimmed: driver, cluster client or service needed |
| Other: OLE DB, Active Directory | N/A | Listed, dimmed as Windows-only providers |
| Enter data | Done | Type or paste a table, types detected; from Home or the editor |
| OneLake catalog | Partial | Lists items with endorsement and sensitivity; models import as a 100,000-row snapshot; CSV, JSON, Excel lakehouse files; not live-tested |
| Recent sources | Done | Up to 20 per user; reconnects with the location filled in |
| Data source settings | Done | File and global scopes, privacy level per source, clear permissions, change source |
| Custom connectors (.mez, .pqx) | Missing | Listed, dimmed: needs the Power Query SDK runtime |
| New Get Data experience (preview) | Partial | Categories, search, available count, dark mode; no keyboard navigation of the list |
| Import Excel workbook contents / templates | Partial | .pbit opens as a new document; no Excel Power Query, Power Pivot or Power View import |
| Import mode | Done | Default; rows saved in the file |
| DirectQuery | Partial | SQLite only; the folded table is read on load and refresh (up to 1,000,000 rows) and computed locally, not one SQL query per visual |
| Dual | Partial | Selectable; behaves as Import, and the UI says so |
| Direct Lake | N/A | Needs Fabric capacity; shown read-only if a model has it |
| Live connection | Missing | Catalog models are imported, never connected live |
| Composite model | Partial | Import and SQLite DirectQuery tables mix in one model; no DirectQuery to semantic models |
| Direct Lake authoring / live edit | N/A | Fabric service only |
| Hybrid tables | Done | Saved as refreshPolicy `mode: hybrid` in TMDL and TMSL; the service makes partitions; not live-tested |
| Native queries | Done | SQLite SQL statement and `Value.NativeQuery` with EnableFolding, after approval |
| Dynamic M query parameters | Missing | The engine accepts parameter overrides; no slicer or filter binds to one |
| Refresh (model, table, visuals, previews) | Done | Refresh, Refresh table, Refresh visuals, Refresh Preview, Refresh All |
| Authentication | Partial | Anonymous only; the engine supports basic, bearer and OAuth but the app passes no credentials |

The 72 unavailable connector entries all behave the same way:
- Each one shows "Unavailable" and its reason, dimmed, with the reason also in its tooltip and accessibility label.
- Selecting it and pressing Connect are both disabled.
- `GetDataSession.choose` rejects it, so Recent sources, the editor's New Source and `.pbids` can't start it either. A `.pbids` file that names one shows the reason instead.
- Typing its M function fails with "isn't available".

## 3. Power Query Editor

| Feature | Status | Notes |
| --- | --- | --- |
| Queries pane | Done | Groups, rename, duplicate, reference, enable load, include in refresh, delete with confirmation, error marks |
| Data preview | Done | First 1,000 rows at the selected step; lists, records, scalars, functions with Invoke |
| Query settings and Applied Steps | Done | Rename, move, delete, delete until end, insert, gear settings; step descriptions kept as M comments |
| Formula bar and Advanced Editor | Done | Advanced Editor with syntax check and Format |
| New editor views (diagram, schema, script) | Done | All three, behind a Preview toggle that is on by default |
| Rows | Done | Keep/remove top, bottom, range, alternate, duplicates, blanks, errors; filters incl. relative dates; sort |
| Columns | Done | Choose, remove, move, rename, duplicate; change type with locale; detect types |
| Headers | Done | Promote and demote |
| Reshape | Done | Pivot, unpivot (three forms), transpose, reverse, group by, count rows |
| Split and merge columns | Done | Delimiter, characters, positions, case and digit transitions; merge with separator |
| Text | Done | Format, extract, parse JSON and XML |
| Number | Done | Standard, scientific, trigonometry, rounding, statistics, information |
| Date and time | Done | Age, parts, start/end of period, earliest/latest, duration parts |
| Fill and replace | Done | Fill down/up, replace values, replace errors |
| Add column | Done | Custom, conditional, index, from examples, invoke function, duplicate |
| Combine | Done | Merge with all six join kinds and fuzzy matching; append; combine files |
| Structured values | Done | Expand and aggregate records, tables and lists |
| AI and scripts | Partial | Sentiment, key phrases, language and image tags run on the Mac; Azure ML dimmed with a reason; R/Python need permission and an interpreter |
| Column from examples | Done | From all columns or the selection; shows the inferred M |
| Table from examples (web) | Missing | Not built |
| Parameters | Done | Typed, required, suggested values; convert to/from query; Edit Parameters from the report |
| Custom functions | Done | Create Function from a query; invoke per row or from the preview |
| Data profiling | Done | Column quality, distribution and profile; top 1,000 rows or the whole dataset |
| Query dependencies | Done | Diagram of sources, queries, parameters and functions |
| Folding indicators and View native query | Done | Per-step icon and native SQL; only SQLite folds |
| Query diagnostics | Partial | Diagnose Step and Start/Stop record editor previews; refreshes are not recorded |
| Privacy levels and firewall | Done | Per-source levels enforced by the engine; global ignore option |
| Error handling | Done | Keep, remove, replace errors; `try … otherwise` in M |
| Load settings | Done | Connection only, type detection, relationship autodetect on Get Data, refresh and Close & Apply |
| Close & Apply, Apply, discard | Done | Close & Apply with its load is one undo step; asks Apply / Discard / Cancel |

## 4. Data modeling

| Feature | Status | Notes |
| --- | --- | --- |
| Column properties | Partial | All listed properties editable, several columns at once; Image URL category alone does not show images in tables |
| Default format string locale | Missing | Per-column `formatLocale` only round-trips through TMDL; values use the model language |
| Table properties | Done | Name, description, synonyms, row label, key, hidden, featured, storage mode |
| Mark as date table | Done | |
| Auto date/time | Done | Follows the file and new-file settings; Year › Quarter › Month › Day hierarchy in the Data pane |
| Calendar-based time intelligence | Partial | Date column and fiscal start (WEEK too); mapped period columns ignored, so retail and 13-period years don't work |
| Hierarchies | Done | Adding one puts every level on the axis |
| Grouping and binning | Done | List groups, bin by size (date units too) or count |
| Display folders | Done | Nested with `\`, several with `;` |
| Relationship cardinality | Done | 1:*, 1:1, *:* |
| Cross-filter direction | Done | Security filter in both directions honoured by RLS |
| Active / inactive, USERELATIONSHIP | Done | CROSSFILTER too |
| Assume referential integrity | Partial | Saved to TMDL and TMSL; has no effect because DirectQuery joins run in the local engine |
| Autodetect, Manage dialog, drag-and-drop, Properties edit | Done | Autodetect after loading new tables, with global and per-file options |
| Limited relationships | Missing | No source groups |
| Model view layout tabs | Done | Add, rename, add related tables, auto-arrange |
| Model explorer | Done | All listed objects plus parameters and aggregations |
| Properties pane multi-select | Done | Shows "Mixed" for differing values |
| Collapse cards, pin related fields, search | Partial | Collapse, expand and search; no "pin related fields to top" |
| Calculation groups | Done | Items, precedence, dynamic format strings |
| Field parameters | Done | Slicer selection swaps the visual's fields at query time |
| Numeric range (what-if) parameters | Done | Table, value measure, optional slicer |
| Calculated tables | Done | |
| Aggregations | Done | Engine answers from the aggregation table; written as `alternateOf` |
| Incremental refresh policies | Done | Policy, RangeStart/RangeEnd; written as TMDL/TMSL `refreshPolicy`; partitions are a service job |
| Perspectives and translations | Done | Dedicated dialogs as well as TMDL |
| User-context-aware calculated columns | Partial | Recompute under the View as user; USERCULTURE follows the model language; no per-column opt-in |
| Live edit of Direct Lake / service models | Missing | Catalog imports a snapshot; `updateSemanticModelDefinition` is used only by the self-check |
| Composite models on semantic models | Partial | The imported snapshot can be extended; no DirectQuery link to the source; not live-tested |
| TMDL view | Done | Script object or model, tabs, find and replace, apply with per-file diff |

## 5. DAX and calculations

| Feature | Status | Notes |
| --- | --- | --- |
| Measures | Done | |
| Calculated columns | Done | |
| Calculated tables | Done | |
| Visual calculations | Done | Evaluated on the visual's grid with real subtotals |
| User-defined functions (type) | Done | |
| Formula bar | Done | Completion, colouring, multi-line, live validation; toggle-comment only in DAX query view |
| Measure tools | Done | Home table, format (with Dynamic…), decimals; category and folder in Properties |
| Dynamic format strings | Done | Format ▸ Dynamic… with a DAX editor and preview; evaluated per data point |
| Quick measures | Done | 26 patterns incl. star rating and concatenated list |
| Implicit measures | Done | Every listed aggregation, plus Show value as |
| Visual calc templates | Done | All nine |
| Visual calc functions with axis | Done | Plus COLLAPSEALL, EXPANDALL, ISATLEVEL, LOOKUPWITHTOTALS |
| Hidden fields feeding calculations | Done | Fields and calcs can both be hidden |
| Custom totals | Partial | Matrix only; the table total row cannot be changed |
| User-defined functions (features) | Done | Typed params, val/expr mode, defaults, description, 256 cap |
| DAX query: run EVALUATE, sortable/filterable grid | Done | |
| DAX query: quick queries | Done | From the DAX view's model list, not the Report-view Data pane |
| DAX query: DEFINE MEASURE and update model | Done | One or many measures |
| DAX query: `///` descriptions | Done | |
| DAX query: INFO functions | Done | INFO.* and INFO.VIEW.* |
| DAX query: tabs saved; Copilot write/explain | Done | Tabs saved; Explain, Ask assistant and Fix with a diff; needs an API key; stub-tested |
| Language coverage | Done | 320 functions incl. window functions, TABLEOF, NAMEOF, APPROXIMATEDISTINCTCOUNT, financial |

## 6. Visualizations

| Feature | Status | Notes |
| --- | --- | --- |
| Bar and column | Partial | Small multiples, error bars, reference lines, total labels, padding, plot area; no rounded axis range |
| Line and area | Done | Forecast, anomalies, trend, smooth/step, markers, shading, series labels |
| Combo | Done | Secondary axis on = separate scale, off = shared |
| Ribbon and waterfall | Done | Ribbon also as small multiples; waterfall breakdown well |
| Part to whole | Done | Donut centre value, data-point colour rules |
| Scatter, bubble, dot plot | Partial | Play axis, clusters, symmetry shading, ratio line, density sampling, error bars, zoom; no auto-fit markers |
| Maps | Partial | MapKit bubble, heat and path layers, lasso; filled/shape maps need pasted GeoJSON; no reference layers, drive-time or ArcGIS |
| Single values | Partial | Callouts, reference labels, category tiles, KPI, gauge, card image from a URL; no hover states |
| Tables and matrix | Partial | Stepped, expand/collapse, frozen headers, widths, sparklines; URL/image cells table-only; custom totals matrix-only |
| Slicers | Done | All styles; button, list and input slicers |
| AI visuals | Done | All four render; see §9 |
| Gantt chart | Done | Durations, progress, milestones |
| R and Python visuals | Done | Script editor under the canvas; runs on the visual's fields; needs an interpreter and scripts allowed |
| Embedded content (paginated, Power Apps, Automate, Metrics) | Partial | Set up from an ID or https link; Power Apps gets no report data; not live-tested |
| Page elements | Partial | Text box values resolve; buttons can't use a custom image; images only from a file at insert |
| Analytics pane | Done | Lines, trend, forecast, error bars, anomalies per visual type |
| Small multiples | Done | Cartesian and ribbon charts, shared or own axis |
| Sparklines | Done | Table and matrix cells; matrix subtotals combined point by point |
| Data labels and total labels | Done | Position, units, decimals, detail field |
| Hierarchy axes | Done | Drill, expand, concatenate labels |
| Sorting | Done | Sort menu; ⇧-click multi-column sort in tables |
| Per-visual Top N, relative date, advanced filters | Done | |
| Show as table, data point as table, copy | Done | See records, copy value, copy visual, copy as image |
| Personalize visuals | Done | In Present view, saved per reader |
| Custom visuals: AppSource, org store, .pbiviz | Missing | No custom-visual host; Settings states this |
| Certified visuals | N/A | Certification is a service programme |
| Pin favourite visuals | Missing | |
| Visuals SDK and developer visual | Missing | No TypeScript visual runtime |

## 7. Report design and formatting

| Feature | Status | Notes |
| --- | --- | --- |
| Pages: add, duplicate, rename, reorder, hide, delete, landing page | Done | Drag to reorder; landing page opens first |
| Page size and page view | Done | 16:9, 4:3, Letter, Tooltip, custom; fit page/width, actual size |
| Page background and wallpaper | Done | Colour, image, fit, transparency |
| Layout aids | Done | Gridlines, snap, smart guides, align, distribute, match size, lock |
| Selection pane | Done | Layers, show/hide, rename, groups, tab order |
| Grouping | Done | Named groups move and bookmark as one |
| Mobile layout view | Done | Own frames and formatting, auto-create, page icon |
| Modern visual defaults | Done | Own base theme with padding and smooth lines, not Fluent 2 |
| Theme pane | Done | Built-in themes, text styles, import/export |
| Customize current theme | Partial | Colours, text, visual defaults, page size; no filter-pane styling |
| Theme JSON | Partial | Colours, text classes, visualStyles; style presets ignored with a warning |
| Accessible and high-contrast themes, reset | Done | |
| Format pane | Done | Tabs, search, expand all, per-card reset; several visuals at once |
| On-object interaction | Partial | Header button lists elements; no click-on-element formatting or floating build menu |
| Common containers | Done | Title, subtitle, divider, background, border, shadow, padding, header, alt text |
| Style presets | Done | Cards, slicers, tables, matrices, buttons, page elements, maps |
| Format painter | Done | |
| Text boxes | Done | Rich text, lists, links, super/subscript; `{{Measure}}` and `{{=DAX}}` values in the page's filter context |
| Images and shapes | Partial | Image from a file only (no URL, replace or data-bound); shapes have no hover or pressed styling |
| CF: table and matrix cells | Partial | Background, font, bars, icons, URL, image, column width by rule; URL/image cells table-only |
| CF: chart data points | Done | |
| CF: text and titles | Done | Titles, subtitles, button and shape text from a measure |
| CF: other properties (fx) | Partial | fx on every colour, subtitle, button/shape text, alt text, action tooltip, column width; other numeric properties not covered |
| CF rule types | Done | Gradient 2/3 stops, rules, field value |
| Alt text | Done | Static or from a measure; used as the VoiceOver label |
| Tab order and keyboard navigation | Partial | Tab order editable in the Selection pane but not used by the canvas or reading view |
| Screen reader, high contrast, patterns, accessible table | Done | VoiceOver labels, high-contrast theme, series patterns |

## 8. Interactivity and navigation

| Feature | Status | Notes |
| --- | --- | --- |
| Filters pane scopes | Done | Visual, page, all pages, drillthrough |
| Filter types | Done | Basic, advanced, Top N, relative date, relative time |
| Author filter controls and Apply button | Partial | Lock, hide, rename, reorder, single select, Apply, search, filter cards; no pane restyling |
| Slicer forms | Done | List, dropdown, tile, between, before, after, relative, hierarchy |
| Sync slicers | Done | Groups, per-page visibility, field sync, add and sync to all pages |
| Apply all / Clear all slicers buttons | Done | |
| Input slicer | Done | Operators, wildcards, pasted lists |
| Persistent filters | Done | Saved to PBIR; takes effect in the service, as in Power BI |
| Edit interactions | Done | Filter / highlight / none per pair |
| Multi-select, rectangle/lasso, table selection | Done | ⌘-click; rectangle select on charts; lasso on maps |
| Report default highlight or filter | Done | |
| Drill down and up | Done | Per data point or next level |
| Expand all down one level | Done | |
| Drillthrough | Done | Keep all filters; cross-report flag saved for the service |
| Drillthrough buttons | Done | Enabled only with a valid selection |
| Matrix expand and collapse | Done | |
| Decomposition tree | Done | Any order, high/low value splits |
| Default tooltips with extra fields | Done | Tooltips-well fields queried with their summarization |
| Report page tooltips | Done | Matched by tooltip fields, filtered to the hovered point |
| Modern visual tooltips | Done | Drill and drillthrough footer, themed |
| Visual header tooltips | Done | Author help text icon |
| Bookmarks | Done | Data, display, current page, all or selected visuals |
| Bookmark groups and View mode | Done | Slideshow with auto-advance |
| Buttons and states | Partial | Built-in icons, five states; no UI to choose a custom icon image |
| Button actions | Partial | Back, bookmark, drillthrough, page, URL, slicers, Q&A; data function only shows a warning |
| Page and bookmark navigators | Partial | Generated and kept in step; can't be limited to a bookmark group |
| Conditional actions | Done | Page, bookmark, drillthrough or URL from a measure; tooltip text through fx |
| Translytical task flows | Missing | Data function action says Fabric user data functions can't be called yet |
| Reader-side options | Done | Header icons, export permission, personalize, sort; filter-type setting saved for the service |

## 9. AI and Copilot

| Feature | Status | Notes |
| --- | --- | --- |
| Copilot pane (chat about the data) | Done | Runs DAX, describes the page or report, summaries, suggested questions; stub-tested |
| Report page creation | Partial | Builds a page of bound visuals in a grid, or single visuals; can't modify what it made (Undo only) |
| Summary shortcuts (ribbon, visual header) | Done | Home ▸ Summarize Page / Report; Summarize in each data visual's header |
| Narrative visual (Copilot) | Done | Custom and suggested prompts, page or report scope; Update offered on change, auto-rewrite opt-in; stub-tested |
| DAX help (write/explain/fix, measure descriptions) | Done | Explain, Write (checked against the model), Fix with a diff; Generate description; stub-tested |
| Prep data for AI (schema, instructions, verified answers) | Done | Excluded fields and instructions reach the assistant; verified answers used with a link to their visual |
| Copilot requirements (sign-in, Fabric capacity, tenant) | N/A | Service licensing; the app uses the user's Anthropic API key from the Keychain |
| Power BI Desktop Bridge (preview) | Partial | Local MCP server, off by default, token: documents, outline, DAX, approved add visual/page; can't edit existing visuals |
| Power BI Modeling MCP server | Partial | Approved, undoable edits to measures, calc columns, relationships, names, visibility, descriptions, formats; no tables, roles, calc groups or queries |
| Skills for Fabric | Missing | No agent skill packages; agents use the MCP tools |
| Key influencers | Done | Influencers and top segments, increase or decrease |
| Decomposition tree | Done | Manual expand plus high/low value AI splits; one split rule |
| Anomaly detection | Done | Flags line-chart points; clicking one lists explanations by strength |
| Forecasting | Done | Length, confidence, seasonality (detect, set, off), ignore last points |
| Analyze: explain the increase/decrease | Done | Right-click a line or column point, or Data/Drill ▸ Analyze; results can't be added as visuals |
| Find where this distribution is different | Done | Data/Drill ▸ Analyze; needs two or more category fields |
| Clustering | Done | Scatter charts and tables; clusters become a model field; from the visual menu, not the ribbon |
| Smart narrative | Partial | On-device summary of the page or its Values fields; that summary is not editable |
| Q&A visual and Q&A setup | Done | Parser, suggestions; Q&A setup with Teach Q&A (saved in TMDL) and Review questions |
| AI Insights in Power Query | Partial | Text and image functions run on the Mac; Azure ML dimmed with its reason |
| Column from examples | Done | Add Column ▸ Column From Examples |
| Fuzzy merge | Done | Merge dialog with fuzzy matching options |

## 10. Security and governance

| Feature | Status | Notes |
| --- | --- | --- |
| Row-level security (RLS) | Done | DAX editor and rule builder; the engine enforces roles |
| Dynamic RLS | Done | USERNAME/USERPRINCIPALNAME come from the View as user |
| View as | Done | One or more roles, or another user |
| Object-level security (OLS) | Done | Checklist per role; the engine hides the objects |
| Sensitivity labels | Partial | Purview labels listed, saved, carried to .pbit and PBIP; no encryption; not live-tested |
| Privacy levels | Done | Set per source in Data source settings; firewall on unless privacy levels are ignored |
| Native query approval | Done | On by default; Get Data and the editor ask; approvals remembered per source |
| Custom connector trust | Missing | No custom connectors can run; Settings states this |
| Certificate revocation checks | Missing | No revocation policy set; macOS default TLS trust only |
| Script and visual warnings | Partial | Scripts off until allowed, blocked steps say how to allow them; no per-run prompt; no custom visuals |
| Group policy and registry controls | Partial | A configuration profile can lock any Settings option; no keys to disable sign-in, export or updates |
| Entra ID sign-in incl. sovereign clouds | Done | PKCE and device code; Public, US Government and China; not live-tested |
| Encrypted data-source credentials | Missing | No credentials reach the query engine; the Keychain store is used only by the self-check |

## 11. Performance and optimisation

| Feature | Status | Notes |
| --- | --- | --- |
| Performance Analyzer | Done | DAX, visual display and other time per visual; copy query, open in DAX view, JSON export |
| Optimize ribbon | Done | Pause, refresh visuals, Query reduction / Full interactivity presets |
| Query reduction settings | Done | Cross-highlight off; Apply buttons on slicers and Filters pane; also per file |
| Automatic page refresh | Done | Fixed interval or change-detection measure |
| DirectQuery options | Done | Max connections and skip relationship validation are read; no restricted-measures mode exists to lift |
| Aggregations and Dual storage mode | Partial | Engine answers from aggregation tables; SQLite DirectQuery reads the table and aggregates locally; Dual acts as Import |
| Incremental refresh | Done | Written as TMDL/TMSL `refreshPolicy` and sent on Publish; not live-tested |
| Data load options | Partial | Parallel table loading works; no background-preview or cache-size options |
| Model size controls | Done | Auto date/time per file and for new files, disable load, remove columns, change types |
| Query folding indicators and Query diagnostics | Partial | Folding icons and View Native Query (SQLite); diagnostics record editor previews only |
| String indexing and full-text search | Partial | TEXTSEARCH behind a Preview toggle scans each row; the word index is built but not used |

## 12. Developer and pro-code features

| Feature | Status | Notes |
| --- | --- | --- |
| Power BI Project (PBIP) | Done | Open folder or .pbip, save as project; writes only changed files |
| TMDL | Done | TMDL view: script, validate, apply with diff preview |
| PBIR | Done | JSON per page, visual and bookmark, read and write; date levels as Power BI hierarchy levels |
| Git workflow | Done | Project files work with any Git client; Fabric Git is service-side |
| Instant reload and Open in VS Code | Done | Watcher reloads, asks first if there are unsaved changes; Open Project in Visual Studio Code |
| TMDL VS Code extension | N/A | Separate Microsoft extension; TMDL view has its own highlighting |
| External tools | Partial | .pbitool.json tools launch with %file%; %server%/%database% tools refused (no model endpoint) |
| Power BI Desktop Bridge | Partial | As in §9: read, DAX, approved add visual or page |
| Power BI Modeling MCP server | Partial | As in §9: approved model edits; no tables, roles, calc groups or queries |
| R and Python integration | Done | Data source, Power Query step and visual, once scripts are allowed and an interpreter is set |
| Custom connectors (.mez/.pqx) | Missing | Listed as unavailable with the reason; nothing loads them |
| Custom visuals (SDK, developer visual) | Missing | No .pbiviz host or TypeScript runtime |
| Silent installation | N/A | Drag-install .app; no installer switches on macOS |
| Diagnostics (tracing, crash dumps, traces folder) | Done | Version details, tracing to a Traces folder, open Traces and macOS crash reports, self-check |

## 13. Files, publishing, and export

| Feature | Status | Notes |
| --- | --- | --- |
| .pbix | Partial | Opens pages and queries only (DataModel can't be decoded); can't save as .pbix |
| .pbit | Partial | Open and Export template; no parameter prompts on open (Edit Parameters afterwards) |
| .pbip | Done | Open and save; reloads after external edits |
| .pbids | Done | New document at the Get Data navigator; unavailable connectors refused with the reason |
| .pbiviz | Missing | No custom visual import |
| .json theme | Done | Import and export of Power BI theme JSON |
| Save locally / OneDrive / SharePoint + share link | Done | Cloud open/save, conflict choices, Copy Sharing Link (view-only); not live-tested |
| Auto recovery | Done | Interval and location from Settings; restore offered at launch |
| Publish | Done | Create or replace model (TMDL) and report (PBIR), no data; My workspace refused; not live-tested |
| Import (.pbix, template, Excel contents, custom visual) | Partial | .pbix and .pbit open as new documents; no Excel Power Query/Pivot import; no custom visuals |
| Export to PDF | Done | All visible pages, queried first, vector PDF |
| Export data from a visual | Done | CSV, xlsx and JSON; honours the export setting; underlying data via See records |
| Copy table / value / selection; Copy visual as image | Done | Table view and table/matrix visuals; image copy |
| Export as template (.pbit) and theme (.json) | Done | |
| Export DAX query results; Performance Analyzer log | Done | Grid copy and CSV; performance log as JSON |

## 14. Options, settings, and preview features

Settings no longer offers these toggles: background data, cache size, unrestricted measures, certificate check, connector trust, uncertified-visual warning, update notifications and telemetry. Each was replaced by a note. Every remaining option is read outside the Settings window. The one exception is the Privacy option "Always ask per file", which is described in the table.

| Feature | Status | Notes |
| --- | --- | --- |
| Global vs Current file split | Done | Current File tab: auto date/time, autodetect, model language, query reduction, each undoable |
| Data Load | Partial | Type detection, autodetect, auto date/time for new files, parallel loading; no background-data or cache options |
| Power Query Editor | Done | Formula bar, profiling, whole-dataset profiling and monospace read when the editor opens |
| DirectQuery | Done | Max connections and skip validation read; note explains the absent unrestricted-measures option |
| R scripting and Python scripting | Partial | Interpreter paths and the allow toggle reach steps and visuals; no IDE option |
| Security | Partial | Native query approval works; no web-preview or ArcGIS consent; others replaced by notes |
| Privacy | Partial | Combine and Ignore work; "Always ask per file" behaves like Combine and never asks |
| Regional Settings | Partial | Model language and import locale applied; app is English only, no app-language option |
| Updates and Usage Data | Missing | No updater, no telemetry; Settings states both |
| Diagnostics | Done | Version details, tracing (timings and row counts, never values), Traces and crash reports folders |
| Preview features | Done | Five toggles, each gating its feature |
| Auto recovery | Done | Toggle, interval and location applied; global only |
| Report settings | Done | Persistent filters, export, personalize, filter types, modern tooltips, cross-report drillthrough; saved to PBIR |
| Query reduction | Done | Per file, in Current File and the Performance pane |
| Published semantic model settings | Missing | None |
| Preview: Gantt chart visual | Done | The toggle adds or removes it from the gallery and Insert menu |
| Preview: List slicer dropdown mode | Done | "Dropdown" format option |
| Preview: New Power Query editor | Done | Diagram, schema and query script views behind the toggle |
| Preview: New Get Data experience | Partial | Categories, search, availability count, dark mode; no keyboard navigation |
| Preview: Microsoft Outlook Mail connector | Missing | Listed as unavailable: needs the online service and sign-in |
| Preview: Direct Lake calculated columns and tables | N/A | Needs Fabric Direct Lake; Direct Lake tables are read-only here |
| Preview: User-context-aware calculated columns | Partial | Behind a toggle; calculated objects see the View as user; no per-query evaluation |
| Preview: Calendar-based time intelligence | Partial | Calendars dialog behind the toggle; retail and 13-period mappings ignored (see §4) |
| Preview: String indexing and full-text search | Partial | TEXTSEARCH only, scanning rows; the index is unused |
| Preview: Desktop Bridge and Modeling MCP server | Partial | One local MCP server (Settings ▸ Developer); reads plus approved, undoable edits; see §9 |

## 15. What Desktop does not do

Power BI Desktop doesn't do any of these. N/A means this app doesn't either. "(extra)" marks something this app does anyway.

| Feature | Status | Notes |
| --- | --- | --- |
| Dashboards, apps, workspaces | N/A | Workspaces are only listed to browse, import or publish |
| Sharing, permissions, RLS assignment | Partial (extra) | Copies a view-only OneDrive/SharePoint link; no permissions or RLS assignment; not live-tested |
| Scheduled refresh, on-premises gateways | N/A | Only page auto refresh while the window is open |
| Email subscriptions, data alerts | N/A | |
| Deployment pipelines, workspace Git | N/A | PBIP text works with a local Git client |
| Comments, personal bookmarks, usage metrics | N/A | Reading view offers local visual personalisation |
| Analyze in Excel, export to PowerPoint | N/A | Only visual data to .xlsx |
| Embedding, Publish to web | N/A | |
| Dataflows and other Fabric items | N/A | Dataflow and Fabric connectors listed as unavailable |
| Paginated report authoring | N/A | The Paginated report visual embeds one from an ID or URL |
| Scorecards and metrics authoring | N/A | The Metrics visual embeds one from an ID or URL |
| Running on macOS or Linux | Done (extra) | Native macOS 15+ arm64 app; no Linux |

## Known limits

1. **DirectQuery and live connections.** DirectQuery works only for SQLite, and it isn't real pushdown: the folded table is read once, then the local engine computes every visual. Dual behaves as Import. There is no live connection, and no DirectQuery link to a semantic model.
2. **Data source authentication is anonymous only.** The engine supports basic, bearer and OAuth credentials, but the app never gives it any.
3. **`.pbix` gives pages and queries only.** Its DataModel stream can't be decoded, and the app can't save `.pbix`.
4. **Microsoft cloud features are not live-tested.** Sign-in, OneDrive, SharePoint, OneLake, Publish and labels have only run against stand-in servers. The assistant has only been tested against a stub.
5. **Sensitivity labels are stored and shown, but nothing is encrypted.**
6. **Maps.** Filled and shape maps need GeoJSON or TopoJSON pasted into a text field. There are no built-in boundaries, reference layers or drive-time selection.
7. **Tables and matrix differ.** URL and image cells work in tables only, and custom totals work in matrices only.
8. **Agent tools are limited.** The MCP server can't edit or delete existing visuals, and can't create tables, roles, calculation groups or queries.
9. **Calendars ignore their mapped period columns.** Retail and 13-period years don't work, although the dialog mentions retail years.
10. **"Always ask per file" does nothing.** This Privacy setting behaves like Combine and never asks.
11. **Keyboard navigation ignores the tab order.** It can be edited in the Selection pane but isn't used on the canvas or in reading view.
12. **Images and buttons.**
    - Images come only from a file at insert time, though the empty image visual mentions a URL that can't be entered.
    - Buttons can't be given a custom icon image.
    - Shapes have no hover or pressed states.
