# FacetQuery

Power Query for Analytics Desktop: an M interpreter, the standard library, file and database connectors,
the Applied Steps editor and the UI transforms. Depends only on FacetCore; links the system `sqlite3` and `z`.

## Entry points

| Type | Use |
| --- | --- |
| `QueryEngine(queries:environment:)` | `evaluate`, `evaluatePreview` (cell errors, structured cells, truncation), `evaluateValue`, `evaluateExpression`, `refreshAll` (dependency order, parallel, progress), `stepFolding`, `nativeQuery(for:upToStep:)`, `directQuery(_:)`, `diagnostics`, `nativeQueriesSent`, `traceMessages`, `dependencyGraph()`, `profile(_:upToStep:rowLimit:)`, `structuredColumn(_:of:upToStep:sampleRows:)` (kind and field names of a column of nested tables/records/lists, for Expand) |
| `QueryEnvironment` | base directory for relative paths, credentials, privacy levels + firewall switch, native query approval, script switch and interpreter paths, culture, clock, time zone, `maxSourceBytes` |
| `AccessTokenProvider` / `CredentialProvider` | Entra tokens and stored source credentials from the host app. Connectors call `QueryEnvironment.accessToken(resource:host:)` (async) or `MInterpreter.accessToken(resource:host:)` (sync, worker thread) with an `EntraResource` scope (`azureSQL`, `ossRDBMS`, `storage`, `powerBI`, `graph`, `dataverse(_:)`, `kusto(_:)`, `sharePoint(_:)`) and the exact host the token goes to; the app refuses hosts outside its allow-list |
| `MScript` | `steps(of:)`, `appending(_:to:)`, `insertingStep`, `renamingStep`, `deletingStep`, `movingStep`, `replacingStepExpression`, `settingStepDescription` (a step's description, kept as the comment lines above it; every edit keeps a script's comments), `truncating`, `validate`, `format`, `referencedIdentifiers`, `duplicateQuery`, `referenceQuery`, `parameterScript`, `toFunction`, `sourceReferences(in:)` (the data sources a script names, found without running it, recorded as the engine records them) |
| `Transform` | one case per Power Query Editor command; `stepName` and `expression(previous:)` give the step; `Transform.detectTypes(in:)` is "Detect data type"; `Transform.recognize(_:)` reads a step's M back as the transform and previous step ("Edit settings"), verified by re-emitting it |
| `ColumnFromExamples.infer(table:examples:columns:)` | the M expression that reproduces typed examples |
| `ColumnProfiler.profile(_:)` → `[ColumnProfile]` | column quality (valid / error / empty), distribution (distinct, unique, value histogram) and statistics for a `QueryPreview` or `DataTable` |
| `MInterpreter` | evaluates M text directly (`evaluate(_:)`), without queries |
| `MSyntax` | M source text: `text`, `identifier`, `field`, `textList`, `number`, `literal(_:)` for M values and `literal(_:type:)` for FacetCore values of a column type |
| `QueryEngine.dataSourcesAccessed` | the sources the latest evaluation read (kind + location), for Data source settings |

## Library areas (`Library/`)

`LibCore` (constructors, types, Value, Type, Function, Comparer), `LibRecord`, `LibList`, `LibText` + `LibSplitters`
(Text, Character, Splitter, Combiner, Replacer), `LibNumber`, `LibDateTime` (Date, DateTime, DateTimeZone, Time, Duration),
`LibTable*` (rows, columns, construction, reshape, structured columns, joins, `Table.Profile`), `LibFiles` (File, Folder,
Binary, Lines, Csv), `LibJson`, `LibXml`, `LibExcel` (+ `ZipReader`), `LibSQL` (+ `SQLiteSource`), `LibWeb`, `LibScripts`.

## Connectors

| Function | Notes |
| --- | --- |
| `File.Contents`, `Folder.Files`, `Folder.Contents` | files larger than `maxSourceBytes` are refused; folder file contents load lazily |
| `Csv.Document` | delimiter (any length), `QuoteStyle`, `Encoding` (code page; a byte-order mark wins), `Columns`; text columns `Column1…` |
| `Json.Document`, `Json.FromValue` | records keep field order; malformed input is `DataFormat.Error` with a position |
| `Xml.Tables`, `Xml.Document` | attributes become `Attribute:name` columns in name order |
| `Excel.Workbook` | .xlsx/.xlsm: sheets, tables, defined names, shared/inline strings, dates (1900 and 1904), booleans, error cells |
| `Sqlite.Database`, `Value.NativeQuery` | tables and views; read-only; parameters; folding (below) |
| `Web.Contents` | http/https with `Query`, `Headers`, `RelativePath`, `Timeout`, `Content`, `ManualStatusHandling` and stored credentials |
| `Web.Page` | tables of an HTML document (text or binary) via the system tidy parser: `Caption`, `Source`, `ClassName`, `Id`, `Data`; header rows, `colspan`/`rowspan` |
| `OData.Feed` | JSON only (v4, or v2/v3 answering `Accept: application/json`): service document → `Name`/`Data` navigation table; entity sets follow `@odata.nextLink` / `__next` |
| `Python.Execute`, `R.Execute` | need `allowScripts`; tables travel as CSV; Python needs pandas |

Every other Get Data connector (SQL Server, PostgreSQL, MySQL, Oracle, ODBC, SharePoint, Azure, Fabric, Parquet,
PDF, …) and the `AI.*` functions are registered only to fail with a `DataSource.Error` that names the connector.

## Query folding (SQLite)

`Table.SelectRows` (comparisons, `and`/`or`/`not`, null tests, `Text.StartsWith/EndsWith/Contains` with the ordinal
comparers, `List.Contains` over literals, `+ - * &`, parameters and other scalar names), `Table.SelectColumns`,
`Table.RemoveColumns`, `Table.Sort` by column, `Table.FirstN`, `Table.Skip`, `Table.Distinct` (all columns),
`Table.RowCount`, and `Value.NativeQuery` with `[EnableFolding = true]`. Equality uses SQLite's null-safe `is` so
results match M (`null <> 1` is true). Division, conditionals and other functions are not folded: from that step on
the query runs locally on the rows the folded prefix returned.

## Behaviour chosen where Power Query does not document it

- Fuzzy matching scores `1 − editDistance / longerLength` after case, white-space and transformation-table normalisation (`FuzzyMatch`).
- `Table.Pivot` returns rows ordered by the remaining key columns.
- `Combiner.CombineTextByDelimiter` treats null as empty text (the delimiter stays); `Text.Combine` skips nulls.
- `Table.TransformColumnTypes` turns blank text into null for non-text types.
- The privacy firewall compares the levels of every source one evaluation touches; unclassified sources are not checked.
