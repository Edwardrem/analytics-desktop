# Analytics Desktop

A native macOS app for building business-intelligence reports: get and shape data with Power Query (M),
model it with DAX, and design interactive report pages. The layout follows Power BI Desktop for Windows:
ribbon, report canvas with page tabs, Filters / Visualizations / Data panes, and Report, Table, Model,
DAX query and TMDL views. It reads and writes Power BI's open formats (PBIP, PBIR, TMDL, `.pbit`, `.pbids`,
theme JSON).

Analytics Desktop is not a Microsoft product and is not affiliated with Microsoft.

## Requirements
- macOS 15 or later on Apple silicon (arm64)
- Xcode 16 or a Swift 5.10+ toolchain. There are no third-party dependencies.

## Build and run
```sh
swift build                    # debug build of every target
swift test                     # all test bundles
Scripts/build-app.sh --open    # release build → dist/Analytics Desktop.app (ad-hoc signed), then open it
```
To see the app with data straight away, use **Data ▸ Load Sample Data**.

## Microsoft account (optional)
OneDrive, SharePoint, the OneLake catalog, Publish and sensitivity labels need your own Microsoft Entra app
registration. No client id is built in.
1. Register an app in Entra ID. Set the redirect URI to `http://localhost` (Mobile and desktop
   applications) and turn **Allow public client flows** on.
2. Add these delegated permissions:
   - Microsoft Graph: `User.Read`, `Files.ReadWrite.All`, `Sites.Read.All`, `offline_access`;
   - Power BI Service and Fabric: the permissions for what you use (workspaces, datasets, reports, items).
3. In **Settings ▸ Microsoft account**, enter the client id and tenant, then sign in. Sign-in works through the
   browser (PKCE) or with a device code.

Refresh tokens are stored in the macOS Keychain only. Tokens are sent only to Microsoft's sign-in, Graph,
Power BI, Fabric and OneLake hosts.

## Architecture
SwiftPM package: one app target on top of eight library targets.

| Target | Responsibility |
| --- | --- |
| `FacetCore` | Values and tables, the semantic model, report / visual / filter / bookmark / theme types, `.facet` package I/O, formatting |
| `FacetDesign` | Design tokens and small shared components |
| `FacetDAX` | DAX lexer, parser, evaluator, function catalog, formatter, and the visual query layer |
| `FacetQuery` | Power Query M interpreter, standard library, connectors, query folding for SQLite, privacy firewall (see `Sources/FacetQuery/API.md`) |
| `FacetAnalytics` | Forecasting, anomalies, clustering, key influencers, smart narrative, Q&A parsing, statistics |
| `FacetCloud` | Microsoft sign-in (PKCE loopback, device code), Keychain, Graph / OneDrive / SharePoint, Power BI and Fabric REST |
| `FacetInterop` | ZIP, TMDL, PBIP / PBIR, `.pbix` / `.pbit` / `.pbids`, themes, Excel / CSV export, the local MCP server |
| `FacetVisuals` | Chart and component renderers, and the `VisualView` host (see `Sources/FacetVisuals/Components/API.md`) |
| `MicrosoftPowerBI` | The app: document store, shell and ribbon, panes, canvas, modeling views, DAX query view, Power Query Editor, account, files |

Rules the code follows:
- **One write path.** Every document change goes through `DocumentStore.mutate(...)` (or
  `updateVisual` / `updateVisuals`). That one path gives undo / redo and tells the engines what to recompute.
- **Features plug in through registration.**
  - Features register views and panes through the builders in `App/Features.swift`, and commands through
    `AppCommands.register`.
  - All of it is wired in `App/FeatureRegistration.swift`.
  - The ribbon is the table in `Shell/RibbonLayout.swift`.
- **Engines behind protocols.** The app reaches the engines through `Services/Services.swift`, and the live
  implementations live in `Bridge/LiveServices.swift`.

Tests: one bundle per library, plus `MicrosoftPowerBITests`. That bundle includes a headless end-to-end
smoke suite that drives the real store and services. It:
- adds and renders every visual type;
- runs every command;
- hosts every view and pane;
- round-trips save / open;
- exports to PDF, CSV and Excel.

## Native format and Power BI files
| Format | Open | Save | What it covers |
| --- | --- | --- | --- |
| `.facet` | Yes | Yes | The native package: the model, the data, the report |
| PBIP (PBIR + TMDL) | Yes | Yes | The model and the report, without data. An open project reloads when its files change on disk. |
| `.pbit` | Yes | Yes | The model and the report, without data |
| `.pbix` | Yes | No | Pages and queries only (see limitations) |
| `.pbids` | Yes | No | Opens a new document with its connection in the Power Query Editor |
| Theme JSON | Yes | Yes | Power BI theme files |

## Known limitations
- **`.pbix` model.** The `DataModel` stream inside a `.pbix` is a compressed binary that cannot be decoded.
  Importing one brings its pages and queries, but not its data or measures. Use `.pbit` or PBIP to bring the model.
- **Untested against Microsoft.** The Microsoft service features have only been tested against local stand-in
  servers, never against live Microsoft services. These are sign-in, Graph, Power BI, Fabric and Purview labels.
- **Publishing.** The Power BI service cannot read `.facet`. Publish therefore uploads the model as TMDL and the
  report as PBIR, without data. The sheet lists the sources that will not refresh in the service.
- **Connectors.** Get Data reads Excel (.xlsx), CSV, XML, JSON, folders, SQLite, web pages and URLs,
  OData, Python and R scripts, entered data and `.pbids`. Connectors that need a database driver or an online
  service this app does not include (SQL Server, Oracle, PostgreSQL, MySQL, ODBC, Parquet, PDF, .xls / .xlsb,
  SharePoint lists, Azure and Fabric sources, custom `.mez` connectors) are listed but marked unavailable,
  with the reason.
- **Sensitivity labels.** Labels are stored and shown, but nothing is encrypted.
- **PBIP safety rules.** A project's report and model folders must be inside the folder that holds its `.pbip`,
  so a thin report bound to a model in another project folder won't open. A project that contains symbolic
  links can't be saved in place; use Save As.
- **Bundle id.** The app's bundle id is still `com.facet.app`.

`STATUS.md` lists every item in `Microsoft Power BI Desktop — Complete Feature Reference.md` as done,
partial or missing.
