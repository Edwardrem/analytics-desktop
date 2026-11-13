# Microsoft Power BI Desktop — Complete Feature Reference

Nov 13, 2026 · @Rufaro Mutepfa

## 1. Overview and workspace

Power BI Desktop is Microsoft's free Windows authoring application for connecting to data, shaping it, building a semantic model, and designing interactive reports. Reports are then published to the Power BI service (Microsoft Fabric) or to Power BI Report Server. This reference describes the app as of the October 2026 release, the latest listed on Microsoft Learn; features Microsoft still marks as preview are labelled.

### Editions and installation

| Edition | How you get it | Notes |
| --- | --- | --- |
| Power BI Desktop (Microsoft Store) | Microsoft Store | Updates automatically in the background; no admin rights needed |
| Power BI Desktop (download) | Single .exe from the Download Center | 64-bit only; needs admin rights; supports silent install switches |
| Power BI Desktop for Report Server | Separate installer | Matches the Report Server release cadence; installs side by side with the standard version |

Microsoft ships a new release every month and supports only the latest one. Files saved in a newer release cannot be opened in an older one.

### System requirements

| Item | Requirement |
| --- | --- |
| Operating system | Windows 10 or Windows Server 2016 or later; runs natively on Windows on ARM |
| .NET | 4.7.2 or later |
| WebView2 | Microsoft Edge WebView2 Runtime |
| Memory | 2 GB available minimum; 4 GB or more recommended |
| Processor | 1 GHz 64-bit (x64) or better |
| Display | 1440x900 or 1600x900 minimum |
| Virtual desktops | Azure Virtual Desktop and Windows 365 supported; Citrix-style published apps are not |

### Views

| View | Purpose |
| --- | --- |
| Report view | The design canvas: pages, visuals, filters, formatting |
| Table view (formerly Data view) | Browse table rows, sort and filter for inspection, create calculated columns and tables |
| Model view | Relationship diagram, multiple layout tabs, Properties pane, model explorer |
| DAX query view | Write and run DAX queries against the model, define and update measures |
| TMDL view | Script and edit the whole semantic model as Tabular Model Definition Language code |

### Ribbon

- **File**: new, open, save, import, export, publish, options and settings, get data, sign in.
- **Home**: clipboard, get data, transform data, refresh, new visual, text box, new measure, quick measure, sensitivity, publish, Copilot.
- **Insert**: pages, visuals, AI visuals, Power Platform visuals, text boxes, buttons, shapes, images, sparklines.
- **Modeling**: relationships, new measure, column, table, parameter, security roles, Q&A setup, calculation groups.
- **View**: themes, page view, mobile layout, gridlines, snap to grid, lock objects, and pane toggles.
- **Optimize**: pause visuals, refresh visuals, optimization presets, Performance Analyzer, Apply all slicers button.
- **Help** and **External tools**: learning links, diagnostics, and launchers for registered third-party tools.
- Contextual tabs appear by selection: **Format**, **Data / Drill**, **Table tools**, **Column tools**, **Measure tools**.

### Panes

Build (Visualizations), Data (fields and model explorer), Format, Filters, Bookmarks, Selection, Sync slicers, Performance Analyzer, Properties (Model view), Theme, and Copilot. Panes dock on the right, can be collapsed to a switcher bar, and the window supports light, dark, and system themes.

## 2. Getting data

Power BI Desktop connects to well over a hundred data sources through Get Data, and each table in a model uses one of several storage modes that decide where queries run.

### Connector categories

| Category | Examples |
| --- | --- |
| File | Excel workbook, Text/CSV, XML, JSON, PDF, Parquet, Folder, SharePoint folder |
| Database | SQL Server, Oracle, PostgreSQL, MySQL, IBM Db2, Teradata, SAP HANA, SAP BW, Snowflake, Amazon Redshift, Google BigQuery, Access, SQL Server Analysis Services |
| Microsoft Fabric | Power BI semantic models, dataflows, lakehouses, warehouses, SQL databases, mirrored databases, KQL databases, datamarts |
| Power Platform | Dataverse, Power Platform dataflows |
| Azure | Azure SQL Database, Synapse Analytics, Analysis Services, Blob Storage, Data Lake Storage Gen2, Cosmos DB, Data Explorer, Databricks, HDInsight, Cost Management |
| Online services | SharePoint Online list, Dynamics 365, Salesforce, Google Analytics, Adobe Analytics, GitHub, Exchange Online, Outlook Mail (preview) |
| Other | Web, OData feed, ODBC, OLE DB, Spark, Hadoop (HDFS), Active Directory, R script, Python script, Blank query |

Other entry points:

- **Enter data**: type or paste a small table directly into the model.
- **OneLake catalog**: browse and connect to Fabric items you have access to, with endorsement and sensitivity labels shown.
- **Recent sources** and **Data source settings**: reuse, edit, or clear stored connections and credentials.
- **Custom connectors**: load .mez or .pqx connectors built with the Power Query SDK; certified connectors ship in the product.
- **New Get Data experience (preview)**: a redesigned flow with better source discovery, keyboard navigation, and dark mode.
- **Import** from Excel workbooks (Power Query, Power Pivot, Power View content) and from Power BI templates.

Retirements to know: the QuickBooks Online connector was retired after March 2026, and the built-in Netezza and Simba Vertica ODBC drivers are being replaced by vendor drivers you install yourself.

### Storage and connectivity modes

| Mode | Where data lives | Best for | Main trade-off |
| --- | --- | --- | --- |
| Import | Compressed in-memory copy inside the model | Fast queries, full DAX and Power Query | Data is as fresh as the last refresh |
| DirectQuery | Stays in the source; queries sent at view time | Very large or near-real-time data | Slower visuals; some transformation and DAX limits |
| Dual | Table behaves as Import or DirectQuery depending on the query | Shared dimension tables in composite models | More to manage |
| Direct Lake (on OneLake or on SQL) | Delta tables in Fabric OneLake, loaded on demand | Import-like speed on lakehouse data without refresh copies | Requires Fabric capacity |
| Live connection | Remote semantic model or Analysis Services model | Reusing a governed shared model | Model is read-only unless converted to a composite model |
| Composite model | Mix of the above, including DirectQuery to other semantic models | Extending a shared model with local tables | Cross-source relationships are limited |

Related capabilities:

- **Direct Lake authoring in Desktop**: create and live-edit Direct Lake models, including from mirrored and SQL databases; calculated columns and tables on Direct Lake on OneLake are in preview.
- **Hybrid tables**: an incremental refresh policy can add a DirectQuery partition for the latest data on top of imported history.
- **Native queries**: pass a hand-written SQL statement to the source, with optional query folding over it.
- **Dynamic M query parameters**: let slicers and filters feed parameter values into DirectQuery source queries.
- **Refresh**: refresh the whole model, a single table, or only visuals; refresh previews separately in Power Query.
- **Authentication**: Windows, database, Microsoft Entra ID (organizational account), account key, API key, anonymous, and single sign-on options depending on the connector.

## 3. Power Query Editor (transform data)

Power Query Editor is the built-in data preparation tool: every step you apply is recorded as M code and replayed on each refresh, so the source data is never altered.

### Editor layout

- **Queries pane**: all queries, grouped into folders; duplicate, reference, enable or disable load, include or exclude from report refresh.
- **Data preview**: a sample of the result at the selected step.
- **Query settings**: query name and the ordered list of Applied Steps, each of which can be renamed, reordered, edited, or deleted.
- **Formula bar** and **Advanced Editor**: read and edit the M expression for a step or the whole query.
- **New Power Query editor (preview)**: adds diagram view, schema view, and query script view on the same engine.

### Transformations

| Group | What it does |
| --- | --- |
| Rows | Keep or remove top, bottom, alternate, duplicate, blank, and error rows; filter by value, text, number, or date conditions; sort |
| Columns | Choose, remove, reorder, rename, duplicate; change data type, including with locale; detect data types automatically |
| Headers | Promote first row to headers or demote headers to a row |
| Reshape | Pivot, unpivot, transpose, reverse rows, group by with aggregations, count rows |
| Split and merge columns | Split by delimiter, number of characters, position, case change, or digit boundary; merge columns with a separator |
| Text | Format (case, trim, clean, prefix, suffix), extract (length, first, last, range, text between delimiters), parse JSON or XML |
| Number | Standard, scientific, trigonometry, rounding, statistics, information (even, odd, sign) |
| Date and time | Age, year, quarter, month, week, day, hour parts; start and end of period; earliest and latest; duration parts |
| Fill and replace | Fill down or up, replace values, replace errors |
| Add column | Custom column (M), conditional column, index column, column from examples, invoke custom function, duplicate column |
| Combine | Merge queries (left, right, full, inner, anti joins, plus fuzzy matching) and append queries; combine files from a folder |
| Structured values | Expand or aggregate record, list, and table columns |
| AI and scripts | Text Analytics, Vision, and Azure Machine Learning transforms; run R or Python scripts as a step |

### Authoring aids

- **Column from examples** and **table from examples** (web): type the result you want and Power Query infers the transformation.
- **Parameters**: typed, reusable values with optional suggested lists; used in sources, filters, and templates.
- **Custom functions**: turn a query into a function and invoke it per row or per file.
- **Data profiling**: column quality, column distribution, and column profile, on the first 1,000 rows or the whole dataset.
- **Query dependencies** view: a diagram of how queries feed each other and where they load.
- **Query folding indicators** and **View native query**: see which steps are pushed back to the source.
- **Query diagnostics**: record and analyse what the engine did during a preview or refresh, step by step.
- **Privacy levels and the Data Privacy Firewall**: control whether data from one source may be sent to another when queries are combined.
- **Error handling**: keep or remove errors, replace errors, and `try ... otherwise` in M.
- **Load settings**: load to model or keep as connection-only staging; relationships and data types can be auto-detected on load.

## 4. Data modeling

The semantic model is the layer of tables, relationships, and calculations that every visual queries; Desktop builds it in Model view, Table view, and TMDL view.

### Tables and columns

- **Column properties**: name, description, synonyms, data type, format string, data category (address, city, country, latitude, longitude, web URL, image URL, barcode), default summarization, sort by column, display folder, hidden, nullable, key.
- **Default format string locale**: apply a locale to date and number formats without changing the user culture.
- **Table properties**: name, description, synonyms, row label, key column, hidden, storage mode, featured table for Excel.
- **Mark as date table**: nominate a calendar table for time intelligence; **Auto date/time** can generate hidden date hierarchies instead.
- **Calendar-based time intelligence (preview)**: define one or more calendars (fiscal, retail, 13-month) on a table and use them in time intelligence functions.
- **Hierarchies**: user-defined drill paths such as Year, Quarter, Month.
- **Grouping and binning**: group discrete values into buckets or bin numbers and dates by size or count.
- **Display folders**: organise fields and measures into nested folders in the Data pane.

### Relationships

- **Cardinality**: one-to-many, one-to-one, many-to-many.
- **Cross-filter direction**: single or both; security filters can optionally apply in both directions.
- **Active and inactive relationships**: one active path between tables, others switched on in DAX with USERELATIONSHIP.
- **Assume referential integrity**: lets DirectQuery use inner joins.
- **Autodetect** on load, the **Manage relationships** dialog, drag-and-drop in the diagram, and editing in the Properties pane without running a data preview.
- **Limited relationships** across source groups in composite models.

### Model view

- Multiple **layout tabs**, each showing a chosen subset of tables.
- **Model explorer**: a tree of every object in the model, including measures, calculation groups, roles, perspectives, cultures, relationships, and functions.
- **Properties pane** with multi-select editing of many objects at once.
- Collapse and expand table cards, pin related fields to the top, search the Data pane.

### Advanced model objects

| Object | What it gives you |
| --- | --- |
| Calculation groups | Reusable calculation items (YTD, prior year, variance) applied to any measure, with dynamic format strings and precedence |
| Field parameters | Let report readers swap the measures or dimensions shown in a visual from a slicer |
| Numeric range (what-if) parameters | A generated value table with a slicer, used as an input to measures |
| Calculated tables | Tables defined by a DAX expression, evaluated at refresh |
| Aggregations | Pre-summarised tables the engine substitutes for detail tables automatically |
| Incremental refresh policies | RangeStart and RangeEnd parameters partition a table so only recent periods refresh |
| Perspectives and translations | Authored through TMDL view or external tools; consumed in reports and personalisation |
| User-context-aware calculated columns (preview) | Columns that respond to the viewing user's culture or identity |

### Editing models that live elsewhere

- **Live edit of Direct Lake and service models**: open a semantic model from a Fabric workspace and edit it in Desktop, with changes saved back to the workspace.
- **Composite models on semantic models**: convert a live connection to DirectQuery and add your own tables, measures, and relationships.
- **TMDL view**: script any object, edit several at once, find and replace across the model, and apply changes with a preview of the difference.

## 5. DAX and calculations

DAX (Data Analysis Expressions) is the formula language for everything calculated in the model, and Desktop offers five places to write it.

| Calculation type | Where it lives | Evaluated | Typical use |
| --- | --- | --- | --- |
| Measure | Model | At query time, in the filter context of each visual cell | Totals, ratios, time intelligence |
| Calculated column | Model table | At refresh, row by row | Categories, flags, keys |
| Calculated table | Model | At refresh | Date tables, summary or bridge tables |
| Visual calculation | A single visual | On the visual's own result grid | Running sums, moving averages, percent of parent |
| User-defined function | Model | Wherever it is called | Reusable, parameterised logic |

### Measures

- **Formula bar** with IntelliSense, syntax colouring, multi-line editing, and commenting.
- **Measure tools**: home table, format, decimal places, data category, display folder.
- **Dynamic format strings**: a measure's format can itself be a DAX expression, for example to switch currency symbols.
- **Quick measures**: a gallery of ready-made patterns such as year-to-date, running total, rolling average, star rating, and concatenated values.
- **Implicit measures**: drag a numeric column into a visual and choose sum, average, min, max, count, distinct count, standard deviation, variance, or median.

### Visual calculations

Generally available since May 2026. They are written directly on a visual, refer to its columns by name, and never touch the model.

- Templates for running sum, moving average, percent of parent, percent of grand total, average of children, versus previous, versus next, versus first, and versus last.
- Dedicated functions including RUNNINGSUM, MOVINGAVERAGE, PREVIOUS, NEXT, FIRST, LAST, COLLAPSE, EXPAND, RANGE, and LOOKUP, with an axis argument for rows or columns.
- Fields can be hidden from the visual while still feeding a calculation.
- **Custom totals**: set a table or matrix total to sum, min, max, count, distinct count, average, or none.

### User-defined functions

Generally available since June 2026. Functions take typed parameters, can declare optional parameters with default expressions, accept up to 256 parameters, carry documentation comments, and can be called from measures, calculated columns, visual calculations, and other functions.

### DAX query view

- Run EVALUATE queries against the model and see results in a grid that can be sorted and filtered.
- **Quick queries** from the Data pane: show top 100 rows, column statistics, or define a measure with its references.
- **DEFINE MEASURE** to test changes, then **update the model** from the editor in one click, for one or many measures.
- Add measure descriptions with `///` comments above a definition.
- **INFO** functions expose model metadata (tables, columns, measures, relationships, functions) as queryable tables.
- Multiple query tabs saved with the file; Copilot can write and explain queries.

### Language coverage

DAX in Desktop includes aggregation, iterator, filter, time intelligence, table manipulation, relationship, text, logical, information, and financial functions. It also includes window functions (OFFSET, INDEX, WINDOW, RANK, ROWNUMBER), variables, and newer additions such as TABLEOF, NAMEOF, and APPROXIMATEDISTINCTCOUNT.

## 6. Visualizations

Desktop ships with around forty built-in (core) visuals, and thousands more can be added from AppSource or built with the custom visuals SDK.

### Built-in visuals

| Family | Visuals | Notable capabilities |
| --- | --- | --- |
| Bar and column | Stacked, clustered, and 100% stacked bar and column | Small multiples, error bars, reference lines, total labels, rounded axis range, outer padding, plot area background |
| Line and area | Line, area, stacked area, 100% stacked area | Forecast, anomaly detection, trend line, step and smooth lines, series labels with leader lines, markers, shaded regions |
| Combo | Line and stacked column, line and clustered column | Dual axes, shared or separate scales |
| Ribbon and waterfall | Ribbon chart, waterfall chart | Rank changes over time; breakdown of what moved a total |
| Part to whole | Pie, donut, treemap, funnel | Detail labels, donut centre value, conditional colours |
| Scatter | Scatter, bubble, dot plot | Play axis animation, clustering, symmetry shading, ratio lines, auto-fit markers, high-density sampling |
| Maps | Azure Maps, Map, Filled map, Shape map, ArcGIS Maps for Power BI | Bubble, heat map, filled, path, and reference layers; lasso and drive-time selection; custom TopoJSON or GeoJSON shapes |
| Single values | Card (new), Card (legacy), Multi-row card, KPI, Gauge | Multiple callouts, reference labels, images with hover states, category interactivity, targets and trend |
| Tables | Table, Matrix | Conditional formatting, sparklines, images and URLs, stepped layout, expand and collapse, frozen row headers, fixed column widths, custom totals |
| Slicers | Slicer (list, dropdown, between, relative date and time), Button slicer, List slicer, Input slicer | Single or multi-select, search, hierarchy, date picker, paste a list of values, numeric operators and wildcards |
| AI | Key influencers, Decomposition tree, Narrative, Q&A | See section 9 |
| Scheduling | Gantt chart (preview) | Task durations, progress, and milestones on a time axis |
| Scripted | R script visual, Python visual | Render any plot from a local R or Python installation |
| Embedded content | Paginated report visual, Power Apps, Power Automate, Metrics (scorecard) | Run an app, flow, or paginated report inside a report page |
| Page elements | Text box, Image, Shapes, Buttons, Page navigator, Bookmark navigator | Rich text and lists, state-based formatting, actions |

Microsoft is moving mapping from the Bing-based Map and Filled map visuals to Azure Maps, so new work should use Azure Maps.

### Capabilities shared across visuals

- **Analytics pane**: constant, min, max, average, median, and percentile lines; trend line; forecast; error bars; anomaly detection, depending on the visual.
- **Small multiples**: split one chart into a grid of charts by a category.
- **Sparklines**: tiny trend charts inside table and matrix cells.
- **Data labels and total labels** with custom content, position, and detail fields.
- **Hierarchy axes** with drill, expand, and concatenated or nested labels.
- **Sorting** by any field, including multi-column sort in tables.
- **Top N, relative date, and advanced filters** per visual.
- **Show as a table**, **Show data point as a table**, and **Copy visual** or **Copy value**.
- **Personalize visuals**: let readers change fields and chart types without editing the report.

### Custom visuals

- Import from **AppSource**, from an organisation's approved visuals store, or from a .pbiviz file.
- **Certified** visuals have passed Microsoft code review and work in export and email subscriptions.
- Pin favourites to the Visualizations pane.
- Build your own with the Power BI visuals SDK (TypeScript) and debug with the developer visual.

## 7. Report design and formatting

Report view gives pixel-level control over page layout and a consistent formatting model shared by every visual.

### Pages and canvas

- **Pages**: add, duplicate, rename, reorder, hide, and delete; set one as the **landing page** readers always open first.
- **Page size**: 16:9, 4:3, Letter, Tooltip, or custom pixel dimensions; page view of fit to page, fit to width, or actual size.
- **Page background and wallpaper**: colour, image, and transparency for the page and the area around it.
- **Layout aids**: gridlines, snap to grid, smart guides, align, distribute, match size, and lock objects.
- **Selection pane**: layer order, show or hide, rename, and group objects; set tab order for keyboard users.
- **Grouping**: combine visuals into a group that moves, resizes, and bookmarks as one.
- **Mobile layout view**: build a separate phone layout per page with its own visual sizes and formatting; pages with a mobile layout are flagged with an icon.

### Themes

- **Modern visual defaults**: new reports start on a Fluent 2 base theme with subtitles, uniform padding, and smooth lines.
- **Theme pane**: switch base themes and palettes, set text styles, and import or export custom themes.
- **Customize current theme**: edit colours, text, visual defaults, page size, and filter pane styling through a dialog.
- **Theme JSON**: full control of every visual's defaults, structural colours, default page size, and style presets.
- Built-in accessible and high-contrast themes; reset to default at any time.

### Formatting visuals

- **Format pane**: Visual and General tabs, search, expand all, and granular reset to default per card.
- **On-object interaction**: click chart elements directly to format them, and build visuals from a floating menu next to the visual.
- **Common containers**: title, subtitle, divider, background, border, shadow, padding, tooltips, header icons, alt text.
- **Style presets** for cards, slicers, tables, and matrices.
- **Format painter**: copy formatting from one visual to another.
- **Text boxes**: rich text, bullet and numbered lists, links, dynamic values, superscript and subscript.
- **Images and shapes**: upload, URL, or data-bound images; fill, outline, rotation, and state-based styling.

### Conditional formatting

| Target | Options |
| --- | --- |
| Table and matrix cells | Background colour, font colour, data bars, icons, web URL, image, fixed column width by rule |
| Chart data points | Colour by rules, gradient, or field value for bar, column, line, pie, donut, scatter, and more |
| Text and titles | Dynamic titles, subtitles, labels, and button text from a measure |
| Other properties | Most colour and many numeric properties accept an expression through the fx button |

Rule types are gradient (two or three colours), rules (ranges and conditions), and field value (a measure or column returning a colour or value).

### Accessibility

Alt text (static or dynamic), tab order, keyboard navigation and shortcuts, screen reader support, high-contrast themes, markers and patterns to avoid relying on colour, and accessible Show as a table.

## 8. Interactivity and navigation

Power BI reports are interactive by default: selecting a data point in one visual filters or highlights the others, and authors can layer filters, drill paths, and navigation on top.

### Filtering

- **Filters pane**: visual-level, page-level, and report-level filters, plus drillthrough filters.
- **Filter types**: basic (list), advanced (conditions), Top N, relative date, and relative time.
- **Filter controls for authors**: lock, hide, rename, reorder, require single selection, and restyle the pane; add an **Apply** button so filters run only on demand.
- **Slicers**: on-canvas filters in list, dropdown, tile, between, before, after, relative date, and hierarchy forms.
- **Sync slicers**: keep a slicer's selection in step across chosen pages, and control where it is visible.
- **Apply all slicers** and **Clear all slicers** buttons.
- **Input slicer**: type text or numbers, with contains, starts with, exact match, ranges, comparison operators, and wildcards.
- **Persistent filters**: readers' filter states can be remembered or disabled per report.

### Cross-filtering and highlighting

- **Edit interactions**: choose per pair of visuals whether a selection filters, highlights, or does nothing.
- Multi-select with Ctrl, rectangle (lasso) select on charts and maps, and data point selection in tables.
- Report-level default of cross-highlight or cross-filter.

### Drill

| Feature | What the reader does |
| --- | --- |
| Drill down and up | Move through a hierarchy on a chart axis, one level or one data point at a time |
| Expand all down one level | Show the next level for every category at once |
| Drillthrough | Right-click a data point to open a detail page filtered to it; supports keeping all filters and cross-report drillthrough |
| Drillthrough buttons | A button that becomes active when a valid selection is made |
| Matrix expand and collapse | Open and close row and column headers with +/- icons |
| Decomposition tree | Break a measure down by any dimension in any order |

### Tooltips

- **Default tooltips** with extra fields and sentence-style text options.
- **Report page tooltips**: design a small page that appears on hover, filtered to the hovered data point.
- **Modern visual tooltips**: include drill down, drill up, and drillthrough actions in the tooltip footer and follow the theme.
- **Visual header tooltips**: an information icon with author-written help.

### Bookmarks, buttons, and navigation

- **Bookmarks**: capture filters, slicers, drill state, sort order, and visibility; choose whether each bookmark applies data, display, and current page, and all or selected visuals.
- **Bookmark groups** and **View** mode to play bookmarks as a slideshow.
- **Buttons**: built-in icons or custom images with default, hover, pressed, selected, and disabled styling.
- **Button actions**: back, bookmark, drillthrough, page navigation, Q&A, web URL, apply or clear all slicers, and data function.
- **Page navigator** and **bookmark navigator**: auto-generated button sets that stay in step with pages and bookmarks.
- **Conditional actions**: destination page, URL, and tooltip text can be driven by a measure.
- **Translytical task flows**: a button calls a Fabric user data function so readers can write back, update records, or trigger workflows from the report.

### Reader-side options authors control

Visual header icons (focus mode, filter icon, more options), export data permissions, personalize visuals, sort options, and whether readers can change filter types.

## 9. AI and Copilot

Desktop has two generations of AI features: Copilot, which needs a Fabric capacity and tenant enablement, and built-in analytical AI that works on any model.

### Copilot in Power BI Desktop

- **Copilot pane**: chat alongside the report to ask questions about the data, summarise a page or the whole report, and get suggested content.
- **Report page creation**: describe a page and Copilot builds it, choosing visuals, fields, and layout; it can then modify what it made.
- **Summary shortcuts**: one-click summaries from the report ribbon and from a visual's header.
- **Narrative visual**: an on-page text summary generated by Copilot, with custom prompts and automatic refresh when slicers change.
- **DAX help**: write, explain, and fix DAX queries in DAX query view, and generate measure descriptions.
- **Prep data for AI**: mark which fields Copilot may use (AI data schema), add AI instructions, and define verified answers tied to visuals.
- **Requirements**: sign in, select a workspace on a supported Fabric or Premium capacity, and have Copilot enabled by the tenant administrator.

### Agentic authoring

- **Power BI Desktop Bridge (preview)**: lets AI agents and tools work with a running Desktop session.
- **Power BI Modeling MCP server**: a local Model Context Protocol server that lets agents read and change semantic models.
- **Skills for Fabric**: agent skills that author reports and models, including adding and formatting supported custom visuals.

### Built-in AI visuals and analytics

| Feature | What it does |
| --- | --- |
| Key influencers | Ranks the factors that drive a metric up or down and finds top segments |
| Decomposition tree | Ad hoc root-cause breakdown, with AI splits that pick the next highest or lowest contributor |
| Anomaly detection | Flags unexpected points on a line chart and offers possible explanations |
| Forecasting | Projects a time series forward with confidence bands and seasonality settings |
| Analyze: explain the increase or decrease | Right-click a data point to generate visuals explaining a change |
| Find where this distribution is different | Finds categories whose distribution differs from the overall pattern |
| Clustering | Automatically finds clusters in a scatter chart or table |
| Smart narrative | Rule-based text summary of a page or visual, editable with dynamic values |
| Q&A visual and Q&A setup | Type a question in natural language and get a visual; teach synonyms and terms |

Microsoft is retiring Q&A and Q&A setup in favour of Copilot. The retirement was announced for December 2026, and at least one later report says Microsoft Learn now lists February 2027, so check the current date before planning around it. New reports should not depend on Q&A.

### AI in data preparation

- **AI Insights** in Power Query: sentiment scoring, key phrase extraction, language detection, image tagging, and calls to Azure Machine Learning models.
- **Column from examples** and fuzzy merge, which infer transformations and matches.

## 10. Security and governance

Desktop is where data-level security is defined; the service is where users are assigned to it and where it is enforced for readers.

| Feature | What it does in Desktop |
| --- | --- |
| Row-level security (RLS) | Define roles and table filters in the Manage roles editor, either with a rule builder or DAX |
| Dynamic RLS | Filter rows by the signed-in user with USERPRINCIPALNAME or USERNAME and a mapping table |
| View as | Test the report as one or more roles, or as a specific user |
| Object-level security (OLS) | Hide whole tables or columns from a role; authored through TMDL view or external tools |
| Sensitivity labels | Apply Microsoft Purview labels to a file; protected files are encrypted and labels travel with exports |
| Privacy levels | Mark sources Public, Organizational, or Private to control data combining |
| Native query approval | Require user approval before a hand-written database query runs |
| Custom connector trust | Allow only certified connectors, or permit uncertified extensions |
| Certificate revocation checks | Validate certificates for connections and web previews |
| Script and visual warnings | Prompts before running R or Python scripts and before loading uncertified custom visuals |
| Group policy and registry controls | Administrators can disable sign-in, update notifications, custom visuals, or export options |

Sign-in supports Microsoft Entra ID work accounts, including sovereign and national clouds, and data source credentials are stored encrypted per Windows user.

## 11. Performance and optimisation

Desktop includes tools to measure where time goes and to reduce the number and cost of queries a report sends.

- **Performance Analyzer**: record interactions and see, per visual, the time spent on the DAX query, visual rendering, and waiting; copy the query, open it in DAX query view, or export the log as JSON.
- **Optimize ribbon**: pause visuals while you build, refresh visuals on demand, and apply optimisation presets for query reduction or full interactivity.
- **Query reduction settings**: turn off cross-highlighting by default and add Apply buttons to slicers and the Filters pane.
- **Automatic page refresh**: for DirectQuery pages, refresh on a fixed interval or when a change-detection measure changes.
- **DirectQuery options**: maximum connections per data source, and editing relationships without running validation queries.
- **Aggregations** and **Dual** storage mode: answer summary queries from memory and detail queries from the source.
- **Incremental refresh**: refresh only recent partitions after publishing.
- **Data load options**: parallel loading of tables, background data previews, and data cache management with a size limit.
- **Model size controls**: disable Auto date/time, disable load for staging queries, remove unused columns, and choose appropriate data types.
- **Query folding indicators** and **Query diagnostics** in Power Query to find steps that stop folding.
- **String indexing and full-text search (preview, rolling out)**: faster text search in models and new text-matching DAX functions.

## 12. Developer and pro-code features

Desktop now supports a code-first workflow, with reports and models stored as text that can be versioned, reviewed, and automated.

| Feature | What it does | Status |
| --- | --- | --- |
| Power BI Project (PBIP) | Saves the report and semantic model as folders of text files instead of one binary file | Generally available |
| TMDL | Human-readable format for the semantic model definition, used in PBIP and in TMDL view | Generally available |
| PBIR (enhanced report format) | One JSON file per page, visual, and bookmark, with public schemas; becoming the default report format | Rolling out as default |
| Git workflow | PBIP folders work with any Git client and with Fabric Git integration for workspaces | Generally available |
| Instant reload and Open in VS Code | Desktop detects external edits to project files and can open the project in Visual Studio Code | Available |
| TMDL Visual Studio Code extension | Syntax highlighting, formatting, and DAX and Power Query support for TMDL files | Generally available |
| External tools | Register tools on the External tools ribbon; they connect to the local model engine for read and write | Generally available |
| Power BI Desktop Bridge | Programmatic access to a running Desktop session for agents and tools | Preview |
| Power BI Modeling MCP server | Lets AI agents inspect and modify a semantic model | Preview |
| R and Python integration | Use scripts as a data source, a Power Query step, or a visual, with a local R or Python installation | Generally available |
| Custom connectors | Build connectors with the Power Query SDK and load them as .mez or .pqx | Generally available |
| Custom visuals | Build visuals in TypeScript with the visuals SDK and test with the developer visual | Generally available |
| Silent installation | Command-line switches for unattended deployment and language selection | Generally available |

Commonly registered external tools include Tabular Editor, DAX Studio, ALM Toolkit, and Bravo. Desktop also provides diagnostics for support: enable tracing, collect crash dumps, and open the traces folder from Options.

## 13. Files, publishing, and export

### File formats

| Format | Contents | Use |
| --- | --- | --- |
| .pbix | Report, model, and imported data in one file | Everyday authoring and sharing |
| .pbit | Report and model definition without data, with parameter prompts | Reusable templates |
| .pbip | Project folder of text files for the report and model | Source control and team development |
| .pbids | A small file that opens Desktop pre-pointed at a data source | Giving colleagues a starting connection |
| .pbiviz | A packaged custom visual | Importing visuals |
| .json theme | Report theme definition | Importing and exporting themes |

### Saving and sharing

- Save locally, or to OneDrive and SharePoint with the built-in file picker, then share a link from inside Desktop. Releases from March 2026 or earlier can no longer save to OneDrive and SharePoint.
- **Auto recovery**: periodic recovery copies of open files, restored after a crash.
- **Publish**: send the report and semantic model to a Power BI workspace, replacing or creating items; Report Server edition saves to a report server instead.
- **Import**: bring in an existing .pbix, a template, Excel workbook contents, or a custom visual.

### Export

- **Export to PDF**: all visible pages of the report.
- **Export data from a visual**: summarised or underlying data to CSV, subject to the report's export settings.
- **Copy table**, **Copy value**, and **Copy selection** from Table view and from visuals; **Copy visual** as an image.
- **Export as template** (.pbit) and **export theme** (.json).
- **Export query results** from DAX query view by copying the grid, and export Performance Analyzer logs.

## 14. Options, settings, and preview features

File > Options and settings > Options splits settings into Global (all files on this machine) and Current file.

| Group | Scope | What you control |
| --- | --- | --- |
| Data Load | Global and file | Type detection, relationship autodetect, Auto date/time, background data, parallel table loading, cache size |
| Power Query Editor | Global | Layout, formula bar, parameters, column profiling defaults |
| DirectQuery | Global and file | Connection limits, unrestricted measures, relationship validation |
| R scripting and Python scripting | Global | Home directory and IDE for each language |
| Security | Global | Native query approval, certificate checks, connector trust level, web preview and ArcGIS consent |
| Privacy | Global and file | Whether and how privacy levels are enforced |
| Regional Settings | Global and file | Application language, model language, locale for import |
| Updates and Usage Data | Global | Update notifications and telemetry |
| Diagnostics | Global | Version details, tracing, crash dumps |
| Preview features | Global | Tick boxes that switch on features still in preview |
| Auto recovery | Global and file | Recovery interval and location |
| Report settings | Global and file | Persistent filters, visual options, export data, filtering experience, cross-report drillthrough, personalize visuals, modern tooltips |
| Query reduction | File | Cross-highlighting and Apply buttons |
| Published semantic model settings | File | Server settings applied after publishing |

### Features in preview as of the October 2026 release

| Feature | Area |
| --- | --- |
| Gantt chart visual | Visuals |
| List slicer dropdown mode | Visuals |
| New Power Query editor (diagram, schema, and script views) | Data preparation |
| New Get Data experience | Data connectivity |
| Microsoft Outlook Mail connector | Data connectivity |
| Direct Lake calculated columns and tables | Modeling |
| User-context-aware calculated columns | Modeling |
| Calendar-based time intelligence | Modeling |
| String indexing and full-text search functions | Modeling |
| Power BI Desktop Bridge and Modeling MCP server | Developer |

Most preview features are switched on under Options > Preview features and need a restart. Preview status changes monthly, so confirm against the latest release notes before relying on one.

## 15. What Desktop does not do

Desktop is an authoring tool only; distribution, scheduling, and collaboration happen in the Power BI service, and a few neighbouring jobs belong to other tools.

| Capability | Where it lives |
| --- | --- |
| Dashboards (pinned tiles), apps, and workspaces | Power BI service |
| Sharing, permissions, and assigning users to RLS roles | Power BI service |
| Scheduled refresh and on-premises data gateways | Power BI service and gateway |
| Email subscriptions and data alerts | Power BI service |
| Deployment pipelines and workspace Git integration | Power BI service (Fabric) |
| Comments, personal bookmarks, and usage metrics | Power BI service |
| Analyze in Excel and export to PowerPoint | Power BI service |
| Embedding and Publish to web | Power BI service and embedded analytics |
| Dataflows and other Fabric items | Fabric workspaces |
| Paginated (pixel-perfect) report authoring | Power BI Report Builder |
| Scorecards and metrics authoring | Power BI service |
| Running on macOS or Linux | Not supported; use Windows, a Windows virtual desktop, or web authoring |

## Sources

- [What's new in Power BI (October 2026)](https://learn.microsoft.com/en-us/power-bi/fundamentals/whats-new), Microsoft Learn
- [Power BI monthly updates archive](https://learn.microsoft.com/en-us/power-bi/fundamentals/desktop-latest-update-archive), Microsoft Learn; read for November 2025 to September 2026
- [Get Power BI Desktop](https://learn.microsoft.com/en-us/power-bi/fundamentals/desktop-get-the-desktop), Microsoft Learn; system requirements and install options
- [Deprecating Power BI Q&A](https://powerbi.microsoft.com/blog/deprecating-power-bi-qa), Microsoft Power BI blog (via search summary)
- [Power Platform retirement deadlines](https://www.2tolead.com/insights/power-platform-retirement-deadlines), 2toLead; the report of a February 2027 Q&A date (via search summary)

Recent and preview features come from the release notes above. Descriptions of long-standing features (Power Query transformations, visuals, formatting, filters, security, options) are written from general product knowledge rather than a page-by-page check, so exact menu names can differ slightly between monthly releases.
