import XCTest
import FacetCore
@testable import FacetInterop

/// Every kind of model object the app supports must serialise to TMDL and parse back unchanged:
/// as files (the PBIP folder) and as a `createOrReplace` script (TMDL view). One test per kind,
/// each over the property values and the awkward names that kind can hold.
final class TMDLRoundTripTests: XCTestCase {
    /// Names that need quoting, escaping or care somewhere in the grammar.
    static let names = ["Plain", "With Space", "It's", "'Quoted'", "Sales [2024]", "a.b", "x = y", "colon: name",
                        "Größe 📈", " padded ", "table", "123", "back`tick", "semi;colon", "\"dq\"", "a/b\\c", "#hash",
                        "// comment", "/// doc", "ref", "-dash", "tab\there", "createOrReplace", "```", "true"]
    /// The same, without brackets: for names that are also used inside "Table[Member]" identifiers,
    /// which the model itself cannot tell apart from a bracket in the name.
    static let identifierNames = names.filter { !$0.contains("[") && !$0.contains("]") }

    /// Multi-line and oddly spaced text, for expressions and descriptions.
    static let texts = ["1", "", " ", " leading", "trailing ", "a\n\nb", "\tindented\n\t\tmore", "x\n", "\nx", "a\r\nb",
                        "\"quoted\" & 'single'", "```", "/// not a doc comment", "// comment", "IF(\n    [x] > 1,\n    \"a\",\n    \"b\"\n)",
                        "name: value", "a = b", "ünïcödé 📈"]

    // MARK: Harness

    /// The first few places two encodable values differ, as "path: got … expected …" (empty when equal).
    private func differences<T: Encodable>(_ got: T, _ expected: T) -> String {
        func object(_ v: T) -> Any {
            (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(v), options: [.fragmentsAllowed])) ?? NSNull()
        }
        var out: [String] = []
        func show(_ v: Any?) -> String {
            guard let v else { return "nothing" }
            if let s = v as? String { return s.debugDescription }
            let data = (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys])) ?? Data()
            return String(String(decoding: data, as: UTF8.self).prefix(160))
        }
        func walk(_ a: Any?, _ b: Any?, _ path: String) {
            guard out.count < 4 else { return }
            if let x = a as? [String: Any], let y = b as? [String: Any] {
                for k in Set(x.keys).union(y.keys).sorted() { walk(x[k], y[k], path + "." + k) }
            } else if let x = a as? [Any], let y = b as? [Any] {
                if x.count != y.count { out.append("\(path): \(x.count) items, expected \(y.count)") }
                for i in 0..<min(x.count, y.count) { walk(x[i], y[i], path + "[\(i)]") }
            } else if let x = a as? NSObject, let y = b as? NSObject, x == y {
                return
            } else {
                out.append("\(path): got \(show(a)), expected \(show(b))")
            }
        }
        walk(object(got), object(expected), "")
        return out.joined(separator: "\n")
    }

    /// Files: serialise, parse, compare; then serialise again and expect the same bytes.
    private func assertFilesRoundTrip(_ model: SemanticModel, _ queries: [QueryDefinition] = [],
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let files = TMDL.serialize(model: model, queries: queries)
        let result = try TMDL.parseDetailed(files: files)
        XCTAssertEqual(differences(result.model, model), "", "model", file: file, line: line)
        XCTAssertEqual(differences(result.queries, queries), "", "queries", file: file, line: line)
        XCTAssertTrue(result.warnings.isEmpty, "\(result.warnings)", file: file, line: line)
        XCTAssertEqual(TMDL.serialize(model: result.model, queries: result.queries), files, "second serialisation", file: file, line: line)
    }

    /// Script: scripting `ref` and applying it to the same model changes nothing; applying it to
    /// `stripped` (the model without that object, which must be the last of its kind) restores the model.
    private func assertScriptRoundTrips(_ ref: TMDLObjectRef, in model: SemanticModel, _ queries: [QueryDefinition] = [],
                                        stripped: SemanticModel, strippedQueries: [QueryDefinition]? = nil,
                                        file: StaticString = #filePath, line: UInt = #line) throws {
        let script = try TMDL.script(for: ref, in: model, queries: queries)
        let same = try TMDL.apply(script: script, to: model, queries: queries)
        XCTAssertTrue(same.summary.isEmpty, "\(ref): \(same.summary.text)", file: file, line: line)
        XCTAssertEqual(differences(same.model, model), "", "\(ref) onto itself", file: file, line: line)
        XCTAssertEqual(differences(same.queries, queries), "", "\(ref) onto itself", file: file, line: line)

        let restored = try TMDL.apply(script: script, to: stripped, queries: strippedQueries ?? queries)
        XCTAssertEqual(differences(restored.model, model), "", "\(ref) onto a model without it", file: file, line: line)
        XCTAssertEqual(differences(restored.queries, queries), "", "\(ref) onto a model without it", file: file, line: line)
        XCTAssertFalse(restored.summary.isEmpty, "\(ref): restoring must be reported as a change", file: file, line: line)
    }

    private func model(_ tables: [ModelTable]) -> SemanticModel {
        var m = SemanticModel()
        m.tables = tables
        return m
    }

    // MARK: Model

    func testModelProperties() throws {
        for (i, text) in Self.texts.enumerated() {
            var m = SemanticModel()
            m.name = Self.names[i % Self.names.count]
            m.culture = i % 2 == 0 ? "en-GB" : "pt-BR"
            m.autoDateTime = i % 2 == 0
            m.aiInstructions = text
            m.aiExcludedFields = ["Sales[Cost]", "It's[a.b]", text]
            m.qnaSynonyms = ["revenue": ["sales", "turn, over", text], "": ["x"]]
            m.qnaSynonyms[text + " term"] = []
            var answer = VerifiedAnswer(question: text)
            answer.answer = text
            answer.visualID = i % 2 == 0 ? UUID() : nil
            m.verifiedAnswers = [answer, VerifiedAnswer(question: "plain?")]
            var layout = ModelLayout(name: Self.names[(i + 3) % Self.names.count])
            var card = ModelLayout.Card(x: -10.5, y: 1e6)
            card.width = 300.25; card.height = 0; card.collapsed = true
            layout.cards = ["Sales": card, "It's [x]": ModelLayout.Card(x: 0, y: 0)]
            m.layouts.append(layout)
            m.fieldParameters = [FieldParameter(name: text.isEmpty ? "P" : m.name,
                                                fields: [.measure("Sales", "Total"), .column("It's", "a.b", .average)])]
            m.whatIfParameters = [WhatIfParameter(name: "Rate", minimum: -1.5, maximum: 1e9, increment: 0.001, defaultValue: 0)]
            m.aggregations = Aggregation.allCases.map {
                AggregationMapping(aggTable: "Agg " + m.name, aggColumn: "c", summarization: $0, detailTable: "Sales", detailColumn: "It's")
            }
            try assertFilesRoundTrip(m)

            var plain = SemanticModel()
            plain.name = m.name                 // the model's name is the file set's identity, not a scripted property
            plain.layouts = [m.layouts[0]]
            try assertScriptRoundTrips(.modelProperties, in: m, stripped: plain)
        }
        try assertFilesRoundTrip(SemanticModel())
    }

    // MARK: Tables

    func testTables() throws {
        var tables: [ModelTable] = []
        for (i, name) in Self.names.enumerated() {
            var t = ModelTable(name: name, columns: [ModelColumn(name: "Key", dataType: .integer), ModelColumn(name: "When", dataType: .date)])
            t.description = Self.texts[i % Self.texts.count]
            t.synonyms = i % 3 == 0 ? [] : ["one", "two words", name]
            t.isHidden = i % 2 == 0
            t.isFeatured = i % 3 == 0
            t.storageMode = StorageMode.allCases[i % StorageMode.allCases.count]
            t.rowLabelColumn = i % 2 == 0 ? "Key" : nil
            t.keyColumn = i % 3 == 0 ? "Key" : nil
            t.dateColumn = i % 4 == 0 ? "When" : nil
            if i % 5 == 1 { t.expression = Self.texts[(i + 2) % Self.texts.count] }
            if i % 5 == 2 { t.sourceQuery = "Source of " + name }
            if i % 4 == 3 {
                var policy = IncrementalRefreshPolicy(dateColumn: "When")
                policy.archiveCount = i; policy.archiveUnit = "quarter"; policy.refreshCount = 2; policy.refreshUnit = "month"
                policy.detectChangesColumn = i % 8 == 3 ? "Key" : nil
                policy.onlyCompletePeriods = true; policy.realTimeDirectQuery = i % 8 == 7
                t.incrementalRefresh = policy
            }
            if i % 6 == 0 {
                var cal = CalendarDefinition(name: "Fiscal " + name, columnsByUnit: ["year": "Key", "date": "When"])
                cal.fiscalYearStartMonth = 1 + i % 12
                t.calendars = [cal, CalendarDefinition(name: "Empty", columnsByUnit: [:])]
            }
            tables.append(t)
        }
        let queries = tables.compactMap(\.sourceQuery).map { QueryDefinition(name: $0, mScript: "#table({\"Key\"}, {{1}})") }
        let m = model(tables)
        try assertFilesRoundTrip(m, queries)
        for t in tables {
            // One table at a time, so that it is the last of its kind and scripting restores it in place.
            var single = m, none = m
            single.tables = [t]
            none.tables = []
            let q = queries.filter { $0.name == t.sourceQuery }
            try assertScriptRoundTrips(.table(t.name), in: single, q, stripped: none, strippedQueries: [])
        }
        try assertFilesRoundTrip(model([ModelTable(name: "Empty")]))
    }

    // MARK: Columns

    func testColumns() throws {
        var columns: [ModelColumn] = []
        for (i, name) in Self.names.enumerated() {
            var c = ModelColumn(name: name, dataType: DataType.allCases[i % DataType.allCases.count])
            c.formatString = ["", "#,0.00", "0.0%;-0.0%;\"zero\"", " spaced ", "dd/MM/yyyy", "\"q\"", "$#,0"][i % 7]
            c.formatLocale = i % 3 == 0 ? "en-GB" : ""
            c.dataCategory = DataCategory.allCases[i % DataCategory.allCases.count]
            c.summarizeBy = Aggregation.allCases[i % Aggregation.allCases.count]
            c.sortByColumn = i % 4 == 1 ? Self.names[0] : nil
            c.displayFolder = ["", "Folder", "A\\B", " padded ", "It's; two"][i % 5]
            c.isHidden = i % 2 == 0
            c.isKey = i == 1
            c.isNullable = i % 3 != 0
            c.description = Self.texts[i % Self.texts.count]
            c.synonyms = i % 4 == 0 ? ["alias", "two words", "comma, inside"] : []
            if i % 5 == 3 { c.expression = Self.texts[(i + 1) % Self.texts.count] }
            columns.append(c)
        }
        // Every data type with every default, untouched.
        for type in DataType.allCases { columns.append(ModelColumn(name: "default \(type.rawValue)", dataType: type)) }
        // Every summarisation and category on a numeric column.
        for a in Aggregation.allCases {
            var c = ModelColumn(name: "agg \(a.rawValue)", dataType: .decimal)
            c.summarizeBy = a
            columns.append(c)
        }
        for cat in DataCategory.allCases {
            var c = ModelColumn(name: "cat \(cat.rawValue)", dataType: .text)
            c.dataCategory = cat
            columns.append(c)
        }
        // Grouped and binned columns.
        var list = ModelColumn(name: "Region (groups)", dataType: .text)
        var g = ColumnGrouping(kind: .list, sourceColumn: "Plain")
        g.groups = ["North": [.string("NO"), .string("It's"), .string("")], "Numbers, mixed": [.int(1), .double(2.5), .bool(true), .null],
                    "": [.string("a\nb")], " padded ": []]
        g.otherGroupName = "Other; rest"
        list.grouping = g
        var bins = ModelColumn(name: "Amount (bins)", dataType: .decimal)
        var b = ColumnGrouping(kind: .binSize, sourceColumn: "Sales [2024]")
        b.binValue = 0.125
        bins.grouping = b
        var count = ModelColumn(name: "Amount (bin count)", dataType: .integer)
        var n = ColumnGrouping(kind: .binCount, sourceColumn: "It's")
        n.binValue = 12
        count.grouping = n
        var noOther = ModelColumn(name: "No other", dataType: .text)
        noOther.grouping = ColumnGrouping(kind: .list, sourceColumn: "a.b")
        columns += [list, bins, count, noOther]

        let m = model([ModelTable(name: "T's [x]", columns: columns)])
        try assertFilesRoundTrip(m)
        for c in columns {
            var whole = m, without = m
            without.tables[0].columns = columns.filter { $0.id != c.id }
            whole.tables[0].columns = without.tables[0].columns + [c]
            try assertScriptRoundTrips(.column(table: "T's [x]", name: c.name), in: whole, stripped: without)
        }
    }

    // MARK: Measures

    func testMeasures() throws {
        var measures: [Measure] = []
        for (i, name) in Self.names.enumerated() {
            var m = Measure(name: name, expression: Self.texts[i % Self.texts.count])
            m.formatString = ["", "#,0", "0.0%", " odd \"q\" ", "$#,0;($#,0)"][i % 5]
            m.formatExpression = i % 3 == 0 ? Self.texts[(i + 5) % Self.texts.count] : nil
            m.displayFolder = ["", "KPIs", "A\\B\\C", "It's"][i % 4]
            m.description = Self.texts[(i + 7) % Self.texts.count]
            m.isHidden = i % 2 == 1
            m.dataCategory = DataCategory.allCases[i % DataCategory.allCases.count]
            measures.append(m)
        }
        for (i, text) in Self.texts.enumerated() {
            var m = Measure(name: "expr \(i)", expression: text)
            m.formatExpression = text
            m.description = text
            measures.append(m)
        }
        var table = ModelTable(name: "Sales [2024]", columns: [ModelColumn(name: "Amount", dataType: .decimal)])
        table.measures = measures
        let base = model([table])
        try assertFilesRoundTrip(base)
        for m in measures {
            var whole = base, without = base
            without.tables[0].measures = measures.filter { $0.id != m.id }
            whole.tables[0].measures = without.tables[0].measures + [m]
            try assertScriptRoundTrips(.measure(table: table.name, name: m.name), in: whole, stripped: without)
        }
    }

    // MARK: Hierarchies

    func testHierarchies() throws {
        var table = ModelTable(name: "Geo's", columns: Self.names.map { ModelColumn(name: $0, dataType: .text) })
        var hierarchies: [Hierarchy] = []
        for (i, name) in Self.names.enumerated() {
            var h = Hierarchy(name: name + " h", levels: Array(Self.names[(i % 5)...].prefix(1 + i % 4)))
            h.isHidden = i % 2 == 0
            hierarchies.append(h)
        }
        hierarchies.append(Hierarchy(name: "All levels", levels: Self.names))
        hierarchies.append(Hierarchy(name: "One level", levels: ["Plain"]))
        table.hierarchies = hierarchies
        let base = model([table])
        try assertFilesRoundTrip(base)
        for h in hierarchies {
            var whole = base, without = base
            without.tables[0].hierarchies = hierarchies.filter { $0.id != h.id }
            whole.tables[0].hierarchies = without.tables[0].hierarchies + [h]
            try assertScriptRoundTrips(.hierarchy(table: table.name, name: h.name), in: whole, stripped: without)
        }
    }

    // MARK: Relationships

    func testRelationships() throws {
        let tables = Self.names.map { ModelTable(name: $0, columns: Self.names.map { ModelColumn(name: $0, dataType: .integer) }) }
        var relationships: [Relationship] = []
        var i = 0
        for cardinality in Cardinality.allCases {
            for filter in CrossFilterDirection.allCases {
                for flags in 0..<8 {
                    let from = Self.names[i % Self.names.count], to = Self.names[(i + 7) % Self.names.count]
                    // Each pair of ends is used once: a model has one relationship between two columns.
                    var r = Relationship(fromTable: from, fromColumn: Self.names[(i + 3) % Self.names.count],
                                         toTable: to, toColumn: Self.names[(i + 11 + 2 * (i / Self.names.count)) % Self.names.count])
                    r.cardinality = cardinality
                    r.crossFilter = filter
                    r.isActive = flags & 1 == 0
                    r.assumeReferentialIntegrity = flags & 2 != 0
                    r.securityFilterBothDirections = flags & 4 != 0
                    relationships.append(r)
                    i += 1
                }
            }
        }
        var m = model(tables)
        m.relationships = relationships
        try assertFilesRoundTrip(m)
        for r in relationships {
            var whole = m, without = m
            whole.tables = tables.filter { [r.fromTable, r.toTable, relationships[0].fromTable, relationships[0].toTable].contains($0.name) }
            without.tables = whole.tables
            whole.relationships = r.id == relationships[0].id ? [r] : [relationships[0], r]
            without.relationships = whole.relationships.filter { $0.id != r.id }
            try assertScriptRoundTrips(.relationship(r.id), in: whole, stripped: without)
        }
        var none = m
        none.relationships = []
        try assertScriptRoundTrips(.relationships, in: m, stripped: none)
    }

    // MARK: Calculation groups

    func testCalculationGroups() throws {
        var groups: [CalculationGroup] = []
        for (i, name) in Self.names.enumerated() {
            var g = CalculationGroup(name: name)
            g.columnName = Self.names[(i + 1) % Self.names.count]
            g.precedence = i - 3
            for (j, item) in Self.names.prefix(i % 6).enumerated() {
                var it = CalculationItem(name: item, expression: Self.texts[(i + j) % Self.texts.count])
                it.ordinal = i % 2 == 0 ? j : 10 - j
                it.formatExpression = j % 2 == 0 ? Self.texts[(i + j + 3) % Self.texts.count] : nil
                g.items.append(it)
            }
            groups.append(g)
        }
        var m = SemanticModel()
        m.calculationGroups = groups
        try assertFilesRoundTrip(m)
        for g in groups {
            var single = m, none = m
            single.calculationGroups = [g]
            none.calculationGroups = []
            try assertScriptRoundTrips(.calculationGroup(g.name), in: single, stripped: none)
            // A calculation group is a table in TMDL, so it also scripts as one.
            try assertScriptRoundTrips(.table(g.name), in: single, stripped: none)
        }
    }

    // MARK: Functions

    func testFunctions() throws {
        var functions: [UserFunction] = []
        let types = ["anyval", "scalar", "table", "anyref", "int64", "string", "datetime"], modes = ["val", "expr"]
        for (i, text) in Self.texts.enumerated() where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var params: [FunctionParameter] = []
            for j in 0..<(i % 4) {
                var p = FunctionParameter(name: "p\(j)")
                p.type = types[(i + j) % types.count]
                p.mode = modes[(i + j) % modes.count]
                p.defaultExpression = j == 2 ? "1 + \(i)" : nil
                params.append(p)
            }
            var f = UserFunction(name: "Fn\(i)", parameters: params, expression: text)
            f.description = Self.texts[(i + 4) % Self.texts.count]
            functions.append(f)
        }
        functions.append(UserFunction(name: "Contoso.Tax.Add", parameters: [FunctionParameter(name: "x")], expression: "x => x"))
        var m = SemanticModel()
        m.functions = functions
        try assertFilesRoundTrip(m)
        for f in functions {
            var single = m, none = m
            single.functions = [f]
            none.functions = []
            try assertScriptRoundTrips(.function(f.name), in: single, stripped: none)
        }
    }

    // MARK: Roles

    func testRoles() throws {
        let tables = Self.identifierNames.map { ModelTable(name: $0, columns: Self.identifierNames.map { ModelColumn(name: $0, dataType: .text) }) }
        var roles: [SecurityRole] = []
        for (i, name) in Self.names.enumerated() {
            var r = SecurityRole(name: name)
            r.description = Self.texts[i % Self.texts.count]
            let ids = Self.identifierNames
            for j in 0..<(i % 4) {
                r.tableFilters[ids[(i + j) % ids.count]] = Self.texts[(i + j + 2) % Self.texts.count]
            }
            r.hiddenTables = i % 3 == 0 ? [ids[(i + 5) % ids.count], ids[(i + 6) % ids.count]] : []
            r.hiddenColumns = i % 2 == 0 ? ["\(ids[(i + 1) % ids.count])[\(ids[(i + 2) % ids.count])]", "\(ids[i % ids.count])[\(ids[(i + 9) % ids.count])]"] : []
            roles.append(r)
        }
        var m = model(tables)
        m.roles = roles
        try assertFilesRoundTrip(m)
        for r in roles {
            var single = m, none = m
            single.roles = [r]
            none.roles = []
            try assertScriptRoundTrips(.role(r.name), in: single, stripped: none)
        }
    }

    // MARK: Perspectives

    func testPerspectives() throws {
        let ids = Self.identifierNames
        var tables = ids.map { ModelTable(name: $0, columns: ids.map { ModelColumn(name: $0, dataType: .text) }) }
        tables[0].measures = [Measure(name: "Total m", expression: "1")]
        tables[0].hierarchies = [Hierarchy(name: "Geo h", levels: ["Plain"])]
        var perspectives: [Perspective] = []
        for (i, name) in Self.names.enumerated() {
            var p = Perspective(name: name)
            switch i % 5 {
            case 0: p.members = []
            case 1: p.members = [ids[i % ids.count]]                                           // a whole table
            case 2: p.members = ["\(ids[i % ids.count])[\(ids[(i + 1) % ids.count])]", "\(ids[i % ids.count])[\(ids[(i + 2) % ids.count])]"]
            case 3: p.members = ["Plain[Total m]", "Plain[Geo h]", "Plain[\(ids[i % ids.count])]", ids[(i + 3) % ids.count]]
            default: p.members = ["\(ids[(i + 4) % ids.count])[\(ids[i % ids.count])]", ids[i % ids.count], "\(ids[(i + 2) % ids.count])[Plain]"]
            }
            perspectives.append(p)
        }
        var m = model(tables)
        m.perspectives = perspectives
        try assertFilesRoundTrip(m)
        for p in perspectives {
            var single = m, none = m
            single.perspectives = [p]
            none.perspectives = []
            try assertScriptRoundTrips(.perspective(p.name), in: single, stripped: none)
        }
    }

    // MARK: Cultures

    func testCultures() throws {
        let ids = Self.identifierNames
        var tables = ids.map { ModelTable(name: $0, columns: ids.map { ModelColumn(name: $0, dataType: .text) }) }
        tables[0].measures = [Measure(name: "Total m", expression: "1")]
        tables[0].hierarchies = [Hierarchy(name: "Geo h", levels: ["Plain"])]
        var cultures: [FacetCore.Translation] = []
        for (i, code) in ["fr-FR", "de-DE", "ja-JP", "pt-BR", "zh-Hans", "en"].enumerated() {
            var t = Translation(culture: code)
            for (j, name) in ids.enumerated() where (i + j) % 3 == 0 {
                t.captions[name] = Self.names[(i + j) % Self.names.count]
                t.captions["\(name)[\(ids[(i + j + 1) % ids.count])]"] = Self.texts[(i + j) % Self.texts.count]
            }
            if i % 2 == 0 {
                t.captions["Plain[Total m]"] = "Total traduit"
                t.captions["Plain[Geo h]"] = " padded "
                t.captions["not in the model"] = "kept"
            }
            cultures.append(t)
        }
        cultures.append(Translation(culture: "it-IT"))                                          // no captions yet
        var m = model(tables)
        m.translations = cultures
        try assertFilesRoundTrip(m)
        for c in cultures {
            var single = m, none = m
            single.translations = [c]
            none.translations = []
            try assertScriptRoundTrips(.culture(c.culture), in: single, stripped: none)
        }
    }

    // MARK: Expressions (Power Query)

    func testExpressions() throws {
        var queries: [QueryDefinition] = []
        for (i, name) in Self.names.enumerated() {
            var q = QueryDefinition(name: name, mScript: ["let\n    Source = 1\nin\n    Source", "\"text\"", "{1, 2, 3}", "42",
                                                          "(x as number) as number =>\n    x + 1", "#table({\"a\"}, {{1}})",
                                                          "let\n    #\"Odd step\" = \"a\" & \"b\" // note\nin\n    #\"Odd step\""][i % 7])
            q.kind = QueryDefinition.Kind.allCasesForTests[i % QueryDefinition.Kind.allCasesForTests.count]
            if q.kind == .parameter { q.kind = .value }                                         // parameters are covered below
            q.group = ["", "Facts", "Helpers\\Nested", "It's"][i % 4]
            q.loadEnabled = i % 2 == 0
            q.includeInRefresh = i % 3 != 0
            q.description = Self.texts[i % Self.texts.count]
            queries.append(q)
        }
        // Parameters of every type, with current, default and suggested values.
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let values: [(DataType, Value, [Value])] = [
            (.text, .string("/data/"), [.string("/data/"), .string("It's \"here\"")]),
            (.integer, .int(42), [.int(-1), .int(42)]),
            (.decimal, .double(0.25), [.double(0.25), .double(1e-3)]),
            (.boolean, .bool(true), []),
            (.dateTime, .date(day), [.date(day)]),
            (.any, .null, []),
        ]
        for (i, (type, value, suggested)) in values.enumerated() {
            var p = QueryParameter()
            p.type = type
            p.currentValue = value
            p.defaultValue = i % 2 == 0 ? value : .null
            p.suggestedValues = suggested
            p.isRequired = i % 2 == 0
            var q = QueryDefinition(name: "Param \(type.rawValue)", mScript: MScript.parameterScript(p))
            q.kind = .parameter
            q.loadEnabled = false
            q.parameter = p
            queries.append(q)
        }
        let bare = SemanticModel()
        try assertFilesRoundTrip(bare, queries)
        for q in queries {
            try assertScriptRoundTrips(.expression(q.name), in: bare, [q], stripped: bare, strippedQueries: [])
        }
        // A query that loads a table is that table's partition, and comes back as the same query.
        var loaded = ModelTable(name: "Loaded's", columns: [ModelColumn(name: "a", dataType: .integer)])
        loaded.sourceQuery = "Loaded source"
        var source = QueryDefinition(name: "Loaded source", mScript: "#table({\"a\"}, {{1}})")
        source.description = "Loads it"
        source.group = "Facts"
        var sameName = ModelTable(name: "Same", columns: [ModelColumn(name: "a", dataType: .integer)])
        sameName.sourceQuery = "Same"
        let same = QueryDefinition(name: "Same", mScript: "#table({\"a\"}, {{2}})")
        try assertFilesRoundTrip(model([loaded, sameName]), [source, same, queries[0]])
    }

    // MARK: Line ends

    func testCarriageReturnsAreDataInLFFilesAndLineEndsInCRLFFiles() throws {
        // A file saved with CRLF line ends, starting with a description, reads like its LF twin.
        let crlf = "/// Fact table\r\n/// Second line\r\ntable Sales\r\n\tcolumn Amount\r\n\t\tdataType: double\r\n\t\tformatString: #,0.00\r\n"
        let fromCRLF = try TMDL.parse(files: [TMDLFile(path: "tables/Sales.tmdl", text: crlf)]).0
        XCTAssertEqual(fromCRLF.tables.map(\.name), ["Sales"])
        XCTAssertEqual(fromCRLF.tables.first?.description, "Fact table\nSecond line")
        XCTAssertEqual(fromCRLF.tables.first?.columns.map(\.name), ["Amount"])
        XCTAssertEqual(fromCRLF.tables.first?.columns.first?.dataType, .decimal)
        XCTAssertEqual(fromCRLF.tables.first?.columns.first?.formatString, "#,0.00")

        // In an LF file a carriage return belongs to the text it is in, even on the first line.
        let lf = "/// a\r\n/// b\ntable T\n\tcolumn c\n\t\tdataType: string\n\t\tdisplayFolder: \"x\r\ny\"\n"
        let fromLF = try TMDL.parse(files: [TMDLFile(path: "tables/T.tmdl", text: lf)]).0
        XCTAssertEqual(fromLF.tables.first?.description, "a\r\nb")
        XCTAssertEqual(fromLF.tables.first?.columns.first?.displayFolder, "x\r\ny")

        // Written out, text with CRLF inside is quoted or fenced, never left to break a line.
        var t = ModelTable(name: "T", columns: [ModelColumn(name: "c", dataType: .text)])
        t.description = "a\r\nb"
        t.columns[0].displayFolder = "x\r\ny"
        t.columns[0].formatString = "end\r"
        t.measures = [Measure(name: "m", expression: "1 +\r\n2")]
        var fr = FacetCore.Translation(culture: "fr-FR")
        fr.captions = ["T": "un\r\ndeux", "T[c]": "plain"]
        var m = model([t])
        m.translations = [fr]
        try assertFilesRoundTrip(m)
        let text = TMDL.serialize(model: m, queries: []).first { $0.path == "tables/T.tmdl" }?.text ?? ""
        XCTAssertTrue(text.contains("\t\tdisplayFolder: \"x\r\ny\"\n"), text)
        XCTAssertTrue(text.contains("\t\tformatString: \"end\r\"\n"), text)
    }

    // MARK: The whole model

    func testWholeModelScriptRestoresEverything() throws {
        let (m, q) = Fixtures.richModel()
        var empty = SemanticModel()
        empty.name = m.name
        empty.layouts = m.layouts
        let script = try TMDL.script(for: .model, in: m, queries: q)
        let restored = try TMDL.apply(script: script, to: empty, queries: [])
        XCTAssertEqual(differences(restored.model, m), "")
        XCTAssertEqual(Set(restored.queries.map { json($0) }), Set(q.map { json($0) }))
    }
}

private extension QueryDefinition.Kind {
    static let allCasesForTests: [QueryDefinition.Kind] = [.table, .parameter, .function, .list, .value]
}
