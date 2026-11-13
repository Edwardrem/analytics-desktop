# FacetQuery

Power Query for Analytics Desktop: an M interpreter, the standard library, file and database connectors,
the Applied Steps editor and the UI transforms. Depends only on FacetCore; links the system `sqlite3` and `z`.

## Entry points

| Type | Use |
| --- | --- |
| `QueryEngine(queries:environment:)` | `evaluate`, `evaluatePreview` (cell errors, structured cells, truncation), `evaluateValue`, `evaluateExpression`, `refreshAll` (dependency order, parallel, progress), `stepFolding`, `nativeQuery(for:upToStep:)`, `directQuery(_:)`, `diagnostics`, `nativeQueriesSent`, `traceMessages`, `dependencyGraph()` |
| `QueryEnvironment` | base directory for relative paths, credentials, privacy levels + firewall switch, native query approval, script switch and interpreter paths, culture, clock, time zone, `maxSourceBytes` |
| `MScript` | `steps(of:)`, `appending(_:to:)`, `insertingStep`, `renamingStep`, `deletingStep`, `movingStep`, `replacingStepExpression`, `truncating`, `validate`, `format`, `referencedIdentifiers`, `duplicateQuery`, `referenceQuery`, `parameterScript`, `toFunction` |
| `Transform` | one case per Power Query Editor command; `stepName` and `expression(previous:)` give the step; `Transform.detectTypes(in:)` is "Detect data type" |
| `ColumnFromExamples.infer(table:examples:columns:)` | the M expression that reproduces typed examples |
| `MInterpreter` | evaluates M text directly (`evaluate(_:)`), without queries |

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
| `Python.Execute`, `R.Execute` | need `allowScripts`; tables travel as CSV; Python needs pandas |

Every other Get Data connector (SQL Server, PostgreSQL, MySQL, Oracle, ODBC, OData, SharePoint, Azure, Fabric, Parquet,
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
