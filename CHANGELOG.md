# Changelog

Each release's section below becomes its GitHub release notes and its page in the app's What's New window.
Versions follow [Semantic Versioning](https://semver.org); headings are `## [X.Y.Z] - YYYY-MM-DD`.

## [0.9.0] - 2026-11-14

**Beta.** The first public build of Analytics Desktop, a native macOS app (macOS 15 or later, Apple silicon) for
building business-intelligence reports. Its layout follows Power BI Desktop for Windows. It is not a Microsoft
product and is not affiliated with Microsoft. It is ad-hoc signed, not notarised: see the README for how to open
it the first time.

### What's in it
- **Report view.** A ribbon, a report canvas with page tabs, the Filters, Visualizations and Data panes, and a
  Format pane with Visual and General tabs. Includes cross-filtering and highlighting, slicers, drill,
  drillthrough, bookmarks, report page tooltips, a mobile layout and Present mode.
- **Get data and Power Query.** A Power Query (M) engine and editor that read Excel (.xlsx), CSV, XML, JSON,
  folders, SQLite (with query folding and DirectQuery), web pages, OData, Python and R scripts, entered data and
  `.pbids`. It also has column profiling and the privacy-level firewall.
- **Modeling and DAX.** Table and Model views, relationships, and a DAX engine with filter context, CALCULATE,
  time intelligence, window functions, calculation groups, user-defined functions, row-level security and
  visual calculations. Also a DAX query view and a TMDL view.
- **Analytics.** Forecasting, anomaly detection, clustering, key influencers, decomposition trees, smart
  narratives and Q&A, all computed on the Mac. An optional assistant uses your own Anthropic API key.
- **Files.** The native `.facet` package. Opens and saves PBIP (PBIR + TMDL), `.pbit` and theme JSON. Opens
  `.pbix` (pages and queries only) and `.pbids`. Exports to PDF, CSV and Excel.
- **Microsoft account (optional).** OneDrive and SharePoint files, the OneLake catalog, Publish and sensitivity
  labels, through your own Entra app registration. Tokens are kept in the Keychain.
- **Updates.** Checks GitHub Releases, shows what's new, and installs updates only when their Ed25519
  signature matches the key built into the app.

### Known limitations
- `.pbix` import brings pages and queries but not data or measures: the `DataModel` stream can't be decoded.
  Use `.pbit` or PBIP to bring the model.
- The Microsoft service features have been tested only against local stand-in servers, never against live
  Microsoft services.
- Connectors that need a database driver or an online service the app doesn't include (SQL Server, Oracle,
  PostgreSQL, MySQL, ODBC, Parquet, PDF and others) are listed but unavailable.
- Sensitivity labels are stored and shown, but nothing is encrypted.
- Settings and Keychain items from earlier builds (bundle id `com.facet.app`) move to the new bundle id
  (`io.github.edwardrem.AnalyticsDesktop`) on first launch. macOS may ask once to let the app read each moved
  Keychain item.

`STATUS.md` lists every feature of the reference as done, partial or missing.
