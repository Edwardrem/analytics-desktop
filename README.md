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
                               # (--version X.Y.Z and --build N set the bundle's version)
```
To see the app with data straight away, use **Data ▸ Load Sample Data**.

## Install
1. Download `AnalyticsDesktop-<version>.zip` from the
   [releases page](https://github.com/Edwardrem/analytics-desktop/releases), unzip it, and move
   **Analytics Desktop.app** to your Applications folder.
2. Open it. Releases are ad-hoc signed, not notarised (there is no Apple Developer ID), so the first time macOS
   says it can't check the app and won't open it. On macOS 15 and later, Control-click ▸ Open no longer gets
   past this. Do one of these instead:
   - Open **System Settings ▸ Privacy & Security**, scroll to the message about Analytics Desktop, click
     **Open Anyway**, and confirm.
   - Or, in Terminal, remove the download's quarantine flag and open the app normally:
     `xattr -dr com.apple.quarantine "/Applications/Analytics Desktop.app"`

You only do this once. Updates the app installs itself open without it (see below).

## Updates
Analytics Desktop updates itself from this repository's GitHub releases.
- **Checking.** It checks a minute after it opens, then once a day. You can turn this off, or opt in to beta
  releases, in **Settings ▸ Updates**. **Help ▸ Check for Updates…** checks at once. A check is one
  unauthenticated request to GitHub's public release list. It sends nothing beyond the request itself: no
  identifier, no usage data, nothing about your documents.
- **What's New.** When a newer version is out, a What's New window shows its release notes and those of every
  version you skipped. Its buttons are **Install and Relaunch**, **Remind Me Later** (asks again tomorrow) and
  **Skip This Version**. The window opens again after an update installs, and from **Help ▸ What's New**.
- **Installing.** The app downloads `AnalyticsDesktop-<version>.zip` and `AnalyticsDesktop-<version>.zip.sig`.
  It checks the Ed25519 signature against the public key built into the app (`Resources/UpdatePublicKey.txt`)
  and refuses the update on any mismatch. Only then does it unpack the zip and check that it is this app, at the
  offered version, newer than yours. It then quits. A small helper swaps the new copy in, keeps the old one
  until the new one has launched, and puts the old one back if it doesn't launch. The app's folder must be
  writable by you, so keep the app in Applications (or `~/Applications`), not on a disk image or in Downloads.
- **Publishing a release** (owner). Run `Scripts/make-update-key.sh` once to make the signing key and commit
  `Resources/UpdatePublicKey.txt`. Then add a `## [X.Y.Z] - YYYY-MM-DD` section to `CHANGELOG.md` and push a
  tag `vX.Y.Z`. `.github/workflows/release.yml` tests, builds, signs with the `UPDATE_SIGNING_KEY` secret, and
  publishes the zip, its `.sig` and `latest.json`. `Scripts/release.sh <version>` does the same locally into
  `dist/`.

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
- **Signing.** Releases are ad-hoc signed and not notarised, so the first open needs the step under Install.
  Updates are authenticated by the app's own Ed25519 signature check instead.

`STATUS.md` lists every item in `Microsoft Power BI Desktop — Complete Feature Reference.md` as done,
partial or missing.
