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
  Parquet, folders, SQLite, web pages, OData, Python and R scripts, entered data and `.pbids`. It also has column
  profiling and the privacy-level firewall.
- **Database connectors (beta).** SQL Server, Azure SQL, Azure Synapse and Fabric warehouses over the app's own
  TDS client, and PostgreSQL, Azure Database for PostgreSQL, Amazon Redshift, MySQL, Azure Database for MySQL and
  MariaDB over their own protocol clients. No drivers are needed. All of them, like SQLite, offer query folding,
  DirectQuery and approved native queries. SQL Server signs in with a database user or a Microsoft account, is
  always encrypted, and can trust a server's certificate per host.
- **Cloud connectors (beta).** SharePoint folders and Online lists, OneDrive and SharePoint files, Dataverse and
  Dynamics 365, Azure Blob Storage and ADLS Gen2, Fabric lakehouses (OneLake Files), Azure Data Explorer, and Power
  BI semantic models (imported as a snapshot).
- **Data source credentials (beta).** Anonymous, Basic, Web API key, Organizational account, and account key or SAS
  for Azure Storage, kept in the Keychain. Edit them in Data source settings ▸ Edit Permissions, or enter them when
  a source refuses during Get Data.
- **Modeling and DAX.** Table and Model views, relationships, and a DAX engine with filter context, CALCULATE,
  time intelligence, window functions, calculation groups, user-defined functions, row-level security and
  visual calculations. Also a DAX query view and a TMDL view.
- **Analytics.** Forecasting, anomaly detection, clustering, key influencers, decomposition trees, smart
  narratives and Q&A, all computed on the Mac. An optional assistant uses your own Anthropic API key.
- **Files.** The native `.facet` package. Opens and saves PBIP (PBIR + TMDL), `.pbit` and theme JSON. Opens
  `.pbix` (pages and queries only) and `.pbids`. Exports to PDF, CSV and Excel.
- **Microsoft account (optional, beta).** OneDrive and SharePoint files, the OneLake catalog, Publish, sensitivity
  labels and the cloud data sources. Sign-in uses the app's own Entra registration or one you enter in Settings ▸
  Microsoft account. Each service gets its own token, with consent asked the first time, and each token goes only
  to that service's allowed hosts. Tokens are kept in the Keychain.
- **Updates.** Checks GitHub Releases, shows what's new, and installs updates only when their Ed25519
  signature matches the key built into the app.

### Known limitations
- `.pbix` import brings pages and queries but not data or measures: the `DataModel` stream can't be decoded.
  Use `.pbit` or PBIP to bring the model.
- The Microsoft service features and cloud connectors have been tested only against local stand-in servers,
  never against live Microsoft services.
- SQL Server has been tested only against a stand-in server, and MySQL and MariaDB never against a real server.
  Not supported: Windows authentication, browsing a server's databases in the SQL Server form, RSA key exchange
  for MySQL over an unencrypted connection, Redshift's SHA-256 sign-in and MariaDB's ed25519 sign-in.
- Dataverse lookups load as `_x_value` ids. Lakehouses read OneLake Files, not Delta tables. Semantic models
  import at most 100,000 rows per table or query. KQL databases and `SharePoint.Contents` aren't available.
- DirectQuery reads the folded table and computes visuals on the Mac, rather than sending one query per visual.
- Connectors that need a vendor driver or an online service the app doesn't include (Oracle, Snowflake, ODBC, PDF,
  dataflows and others) are listed but unavailable.
- Sensitivity labels are stored and shown, but nothing is encrypted.
- Settings and Keychain items from earlier builds (bundle id `com.facet.app`) move to the new bundle id
  (`io.github.edwardrem.AnalyticsDesktop`) on first launch. macOS may ask once to let the app read each moved
  Keychain item.

`STATUS.md` lists every feature of the reference as done, partial or missing.
