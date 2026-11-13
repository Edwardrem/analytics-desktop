import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// Relationships, roles, parameters, hierarchies, groups and bins, date tables and calendars.
@MainActor
final class ModelDialogsATests: XCTestCase {
    private func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date { DialogFixture.day(y, m, d, hour: hour) }

    // MARK: Relationships

    func testCardinalityMustMatchTheData() {
        let model = DialogFixture.model()
        var r = DialogFixture.salesToProduct()
        let u = RelationshipEditLogic.uniqueness(r, data: DialogFixture.data())
        XCTAssertEqual(u, .init(from: false, to: true))               // ProductID repeats in Sales, not in Product
        XCTAssertEqual(RelationshipEditLogic.detectedCardinality(u), .manyToOne)
        XCTAssertEqual(RelationshipEditLogic.check(r, model: model, uniqueness: u), .init(problem: nil, warnings: []))

        r.cardinality = .oneToMany                                     // Sales would be the "one" side
        XCTAssertEqual(RelationshipEditLogic.check(r, model: model, uniqueness: u).problem,
                       "Sales[ProductID] has duplicate values, so it can't be the “one” side. Choose a different cardinality.")
        r.cardinality = .oneToOne
        XCTAssertNotNil(RelationshipEditLogic.check(r, model: model, uniqueness: u).problem)
        r.cardinality = .manyToMany
        let many = RelationshipEditLogic.check(r, model: model, uniqueness: u)
        XCTAssertNil(many.problem)
        XCTAssertEqual(many.warnings.count, 1)
        // Without data nothing can be said about uniqueness, so nothing is blocked.
        r.cardinality = .oneToMany
        XCTAssertNil(RelationshipEditLogic.check(r, model: model).problem)
    }

    func testRelationshipProblems() {
        var model = DialogFixture.model()
        var r = Relationship(fromTable: "Sales", fromColumn: "Region", toTable: "Product", toColumn: "ProductID")
        XCTAssertEqual(RelationshipEditLogic.check(r, model: model).problem,
                       "Region is text and ProductID is whole number. Related columns need matching data types.")
        r = Relationship(fromTable: "Sales", fromColumn: "ProductID", toTable: "Sales", toColumn: "OrderID")
        XCTAssertEqual(RelationshipEditLogic.check(r, model: model).problem, "A relationship needs two different tables.")
        r = Relationship(fromTable: "Sales", fromColumn: "", toTable: "Product", toColumn: "ProductID")
        XCTAssertEqual(RelationshipEditLogic.check(r, model: model).problem, "Choose a column in each table.")

        let existing = DialogFixture.salesToProduct()
        model.relationships = [existing]
        XCTAssertEqual(RelationshipEditLogic.check(DialogFixture.salesToProduct(), model: model).problem, "These two columns are already related.")
        // Editing the relationship itself is not a duplicate of itself.
        XCTAssertNil(RelationshipEditLogic.check(existing, model: model).problem)
    }

    func testOnlyOneActivePathBetweenTwoTables() {
        var model = DialogFixture.model()
        model.relationships = [DialogFixture.salesToProduct()]
        var second = Relationship(fromTable: "Sales", fromColumn: "OrderID", toTable: "Product", toColumn: "ProductID")
        XCTAssertEqual(RelationshipEditLogic.check(second, model: model).problem,
                       "Sales and Product are already connected by another active path. Deactivate that relationship first, or keep this one inactive.")
        second.isActive = false
        let check = RelationshipEditLogic.check(second, model: model)
        XCTAssertNil(check.problem)
        XCTAssertEqual(check.warnings, ["Inactive: measures use it only through USERELATIONSHIP."])

        model.relationships.append(second)
        XCTAssertNotNil(RelationshipEditLogic.activationProblem(second.id, model: model))
        model.relationships[0].isActive = false
        XCTAssertNil(RelationshipEditLogic.activationProblem(second.id, model: model))
        XCTAssertNotNil(RelationshipEditLogic.activationProblem(UUID(), model: model))
    }

    func testNormalizeUpsertAndMarks() {
        var r = DialogFixture.salesToProduct()
        r.cardinality = .oneToOne
        XCTAssertEqual(RelationshipEditLogic.normalized(r).crossFilter, .both)
        r.cardinality = .manyToOne; r.crossFilter = .single; r.securityFilterBothDirections = true
        XCTAssertFalse(RelationshipEditLogic.normalized(r).securityFilterBothDirections)
        r.crossFilter = .both
        XCTAssertTrue(RelationshipEditLogic.normalized(r).securityFilterBothDirections)
        XCTAssertEqual(RelationshipEditLogic.check(r, model: DialogFixture.model()).warnings.count, 1)

        var model = DialogFixture.model()
        RelationshipEditLogic.upsert(r, into: &model)
        var edited = r; edited.isActive = false
        RelationshipEditLogic.upsert(edited, into: &model)
        XCTAssertEqual(model.relationships.count, 1)
        XCTAssertEqual(model.relationships.first?.isActive, false)

        XCTAssertEqual(RelationshipEditLogic.endMarks(.manyToOne).from, "*")
        XCTAssertEqual(RelationshipEditLogic.endMarks(.manyToOne).to, "1")
        XCTAssertEqual(RelationshipEditLogic.endMarks(.oneToMany).from, "1")
        XCTAssertEqual(RelationshipEditLogic.endMarks(.manyToMany).to, "*")
    }

    func testAutodetectFindsTheSharedKey() {
        let found = RelationshipLogic.autodetect(DialogFixture.model(), data: DialogFixture.data())
        XCTAssertEqual(found.map(RelationshipOps.caption), ["Sales[ProductID] → Product[ProductID]"])
        XCTAssertEqual(found.first?.cardinality, .manyToOne)
        var model = DialogFixture.model()
        model.relationships = found
        XCTAssertEqual(RelationshipLogic.autodetect(model, data: DialogFixture.data()).count, 0)
    }

    // MARK: Roles

    func testRuleBuilderWritesDAX() {
        XCTAssertEqual(RoleLogic.rule(column: "Region", type: .text, comparison: .equals, value: "West"), "[Region] = \"West\"")
        XCTAssertEqual(RoleLogic.rule(column: "Name", type: .text, comparison: .notEquals, value: "O\"Neil"), "[Name] <> \"O\"\"Neil\"")
        XCTAssertEqual(RoleLogic.rule(column: "Amount", type: .decimal, comparison: .greater, value: "100"), "[Amount] > 100")
        XCTAssertEqual(RoleLogic.rule(column: "Amount", type: .decimal, comparison: .lessOrEqual, value: " 2.5 "), "[Amount] <= 2.5")
        XCTAssertNil(RoleLogic.rule(column: "Amount", type: .decimal, comparison: .greater, value: "lots"))
        XCTAssertEqual(RoleLogic.rule(column: "OrderDate", type: .date, comparison: .greaterOrEqual, value: "2024-01-15"), "[OrderDate] >= DATE(2024, 1, 15)")
        XCTAssertEqual(RoleLogic.rule(column: "Active", type: .boolean, comparison: .equals, value: "yes"), "[Active] = TRUE()")
        XCTAssertNil(RoleLogic.rule(column: "Active", type: .boolean, comparison: .equals, value: "maybe"))
        XCTAssertEqual(RoleLogic.rule(column: "Name", type: .text, comparison: .contains, value: "bike"), "CONTAINSSTRING([Name], \"bike\")")
        XCTAssertEqual(RoleLogic.rule(column: "Name", type: .text, comparison: .startsWith, value: "Mo"), "LEFT([Name], 2) = \"Mo\"")
        XCTAssertEqual(RoleLogic.rule(column: "A]B", type: .integer, comparison: .equals, value: "1"), "[A]]B] = 1")

        XCTAssertEqual(RoleLogic.combine("", with: "[A] = 1"), "[A] = 1")
        XCTAssertEqual(RoleLogic.combine("[Region] = \"West\"", with: "[Amount] > 100"), "([Region] = \"West\") && [Amount] > 100")
        XCTAssertEqual(RoleLogic.combine("[A] = 1", with: "[A] = 2", any: true), "([A] = 1) || [A] = 2")

        XCTAssertEqual(RoleLogic.Comparison.valid(for: .text), [.equals, .notEquals, .contains, .startsWith])
        XCTAssertEqual(RoleLogic.Comparison.valid(for: .boolean), [.equals, .notEquals])
        XCTAssertFalse(RoleLogic.Comparison.valid(for: .integer).contains(.contains))
    }

    func testObjectLevelSecurity() {
        var role = SecurityRole(name: "Partners")
        RoleLogic.setColumn(table: "Sales", column: "Amount", hidden: true, in: &role)
        XCTAssertEqual(role.hiddenColumns, ["Sales[Amount]"])
        XCTAssertTrue(RoleLogic.isColumnHidden(role, table: "sales", column: "amount"))
        RoleLogic.setTable("Sales", hidden: true, in: &role)
        XCTAssertEqual(role.hiddenTables, ["Sales"])
        XCTAssertEqual(role.hiddenColumns, [], "a hidden table makes per-column entries redundant")
        RoleLogic.setColumn(table: "Sales", column: "Region", hidden: true, in: &role)
        XCTAssertEqual(role.hiddenColumns, [])
        RoleLogic.setTable("Sales", hidden: false, in: &role)
        XCTAssertFalse(RoleLogic.isTableHidden(role, "Sales"))
    }

    func testRoleValidationAndCleaning() {
        let model = DialogFixture.model()
        var a = SecurityRole(name: " West ")
        a.tableFilters = ["Sales": "[Region] = \"West\"", "Product": "   ", "Gone": "TRUE()"]
        a.hiddenTables = ["Date", "Gone"]
        a.hiddenColumns = ["Product[Name]", "Date[Year]", "Product[Missing]"]
        let cleaned = RoleLogic.cleaned([a], model: model)[0]
        XCTAssertEqual(cleaned.name, "West")
        XCTAssertEqual(cleaned.tableFilters, ["Sales": "[Region] = \"West\""])
        XCTAssertEqual(cleaned.hiddenTables, ["Date"])
        XCTAssertEqual(cleaned.hiddenColumns, ["Product[Name]"])

        XCTAssertEqual(RoleLogic.problems([SecurityRole(name: "A"), SecurityRole(name: "a")], model: model), ["Another role is already named “A”."])
        XCTAssertEqual(RoleLogic.problems([SecurityRole(name: "  ")], model: model), ["Name the role."])
        XCTAssertEqual(RoleLogic.problems([SecurityRole(name: "London,Paris")], model: model), ["Role names can't contain a comma."])
        var both = SecurityRole(name: "B")
        both.hiddenTables = ["Sales"]; both.tableFilters = ["Sales": "TRUE()"]
        XCTAssertEqual(RoleLogic.problems([both], model: model), ["“B” hides Sales, so it can't also filter its rows."])
        XCTAssertEqual(RoleLogic.problems([SecurityRole(name: "Ok")], model: model), [])
    }

    func testViewAs() {
        var model = DialogFixture.model()
        model.roles = [SecurityRole(name: "West"), SecurityRole(name: "Managers")]
        XCTAssertNil(RoleLogic.viewAsProblem(roles: ["West"], user: "", model: model))
        XCTAssertEqual(RoleLogic.viewAsProblem(roles: ["East"], user: "", model: model), "The role “East” no longer exists.")
        XCTAssertNotNil(RoleLogic.viewAsProblem(roles: [], user: "a@b.c", model: DialogFixture.model()))
        XCTAssertEqual(RoleLogic.viewAsSummary(roles: ["West", "Managers"], user: "anna@contoso.com"), "Viewing as West, Managers (anna@contoso.com)")
        XCTAssertEqual(RoleLogic.viewAsSummary(roles: [], user: "anna@contoso.com"), "Viewing as another user (anna@contoso.com)")
        XCTAssertNil(RoleLogic.viewAsSummary(roles: [], user: " "))
    }

    func testARoleFiltersRowsInTheEngine() throws {
        var model = DialogFixture.model()
        var west = SecurityRole(name: "West")
        west.tableFilters["Sales"] = try XCTUnwrap(RoleLogic.rule(column: "Region", type: .text, comparison: .equals, value: "West"))
        model.roles = [west]
        XCTAssertEqual(try DialogFixture.engine(model).engine.scalar("[Total]", filters: []).asDouble, 100)           // 10+20+30+40
        XCTAssertEqual(try DialogFixture.engine(model, roles: ["West"]).engine.scalar("[Total]", filters: []).asDouble, 30)   // the two West rows
    }

    // MARK: Parameters

    func testNumericRangeParsing() {
        guard case .parameter(let p) = ParameterLogic.parse(name: " Discount ", minimum: "0", maximum: "100", increment: "5", defaultValue: "") else {
            return XCTFail("a valid range was rejected")
        }
        XCTAssertEqual(p.name, "Discount")
        XCTAssertEqual([p.minimum, p.maximum, p.increment, p.defaultValue], [0, 100, 5, 0])
        func problem(_ n: String, _ lo: String, _ hi: String, _ inc: String, _ def: String = "") -> String? {
            if case .problem(let s) = ParameterLogic.parse(name: n, minimum: lo, maximum: hi, increment: inc, defaultValue: def) { return s }
            return nil
        }
        XCTAssertEqual(problem("", "0", "1", "1"), "Name the parameter.")
        XCTAssertEqual(problem("P", "x", "1", "1"), "Minimum must be a number.")
        XCTAssertEqual(problem("P", "5", "5", "1"), "Maximum must be greater than minimum.")
        XCTAssertEqual(problem("P", "0", "10", "0"), "Increment must be greater than zero.")
        XCTAssertEqual(problem("P", "0", "10", "11"), "Increment can't be larger than the range.")
        XCTAssertEqual(problem("P", "0", "10", "1", "11"), "Default must be between minimum and maximum.")
        XCTAssertEqual(problem("P", "0", "10", "1", "ten"), "Default must be a number.")
        XCTAssertNotNil(problem("P", "0", "10000000", "1"))            // ten million and one values
        XCTAssertNil(problem("P", "0", "10", "1", "10"))
    }

    func testSeriesValueCount() {
        XCTAssertEqual(ParameterLogic.valueCount(minimum: 0, maximum: 100, increment: 5), 21)
        XCTAssertEqual(ParameterLogic.valueCount(minimum: 0, maximum: 10, increment: 3), 4)       // 0, 3, 6, 9
        XCTAssertEqual(ParameterLogic.valueCount(minimum: 0, maximum: 1, increment: 0.1), 11)     // 0.0 … 1.0
        XCTAssertEqual(ParameterLogic.valueCount(minimum: -1, maximum: 1, increment: 0.5), 5)
    }

    func testNumericRangeGeneratesATableAndMeasure() throws {
        let p = WhatIfParameter(name: "Discount", minimum: 0, maximum: 100, increment: 5, defaultValue: 10)
        XCTAssertEqual(ParameterLogic.seriesExpression(p), "SELECTCOLUMNS(GENERATESERIES(0, 100, 5), \"Discount\", [Value])")
        XCTAssertEqual(ParameterLogic.valueMeasureExpression(p), "SELECTEDVALUE('Discount'[Discount], 10)")
        let half = WhatIfParameter(name: "Rate", minimum: 0, maximum: 1, increment: 0.25, defaultValue: 0.5)
        XCTAssertEqual(ParameterLogic.seriesExpression(half), "SELECTCOLUMNS(GENERATESERIES(0, 1, 0.25), \"Rate\", [Value])")

        var model = DialogFixture.model()
        XCTAssertNil(ParameterLogic.problem(p, model: model))
        ParameterLogic.install(p, into: &model)
        let table = try XCTUnwrap(model.table("Discount"))
        XCTAssertTrue(table.isCalculated)
        XCTAssertEqual(table.columns.map(\.name), ["Discount"])
        XCTAssertEqual(table.columns.first?.dataType, .integer)
        XCTAssertEqual(table.measures.map(\.name), ["Discount Value"])
        XCTAssertEqual(model.whatIfParameters.count, 1)
        XCTAssertEqual(ParameterLogic.problem(WhatIfParameter(name: "Discount", minimum: 0, maximum: 1, increment: 1, defaultValue: 0), model: model),
                       "A table named “Discount” already exists.")
        XCTAssertEqual(ParameterLogic.problem(WhatIfParameter(name: "Sales", minimum: 0, maximum: 1, increment: 1, defaultValue: 0), model: model),
                       "A table named “Sales” already exists.")

        // The real engine evaluates what was generated.
        let (engine, errors) = DialogFixture.engine(model)
        XCTAssertEqual(errors, [:])
        XCTAssertEqual(engine.data["Discount"]?.column("Discount")?.values.count, 21)
        XCTAssertEqual(engine.data["Discount"]?.column("Discount")?.values.last?.asDouble, 100)
        XCTAssertEqual(try engine.scalar("[Discount Value]", filters: []).asDouble, 10, "no single selection → the default")

        // Editing keeps the id, renames the table and drops the old one.
        var renamed = WhatIfParameter(name: "Markdown", minimum: 0, maximum: 1, increment: 0.5, defaultValue: 0)
        renamed.id = UUID()
        let id = try XCTUnwrap(model.whatIfParameters.first?.id)
        XCTAssertNil(ParameterLogic.problem(renamed, replacing: id, model: model))
        ParameterLogic.install(renamed, replacing: id, into: &model)
        XCTAssertNil(model.table("Discount"))
        XCTAssertEqual(model.table("Markdown")?.columns.first?.dataType, .decimal)
        XCTAssertEqual(model.whatIfParameters.map(\.id), [id])
        ParameterLogic.remove(parameter: id, from: &model)
        XCTAssertNil(model.table("Markdown"))
        XCTAssertEqual(model.whatIfParameters.count, 0)
        XCTAssertEqual(model.tables.map(\.name), ["Sales", "Product", "Date"])
    }

    func testFieldParameter() throws {
        let fields: [FieldRef] = [.column("Product", "Category"), .measure("Sales", "Total")]
        XCTAssertEqual(ParameterLogic.fieldParameterExpression(name: "Axis", fields: fields), """
        SELECTCOLUMNS(
          {
            ("Category", NAMEOF('Product'[Category]), 0),
            ("Total", NAMEOF([Total]), 1)
          },
          "Axis", [Value1],
          "Axis Fields", [Value2],
          "Axis Order", [Value3]
        )
        """)
        var model = DialogFixture.model()
        XCTAssertEqual(ParameterLogic.fieldParameterProblem(name: "Axis", fields: [], model: model), "Add at least one field.")
        XCTAssertEqual(ParameterLogic.fieldParameterProblem(name: "", fields: fields, model: model), "Name the parameter.")
        XCTAssertEqual(ParameterLogic.fieldParameterProblem(name: "Product", fields: fields, model: model), "A table named “Product” already exists.")
        XCTAssertEqual(ParameterLogic.fieldParameterProblem(name: "Axis", fields: [.column("Product", "Colour")], model: model), "“Colour” is no longer in the model.")
        XCTAssertNil(ParameterLogic.fieldParameterProblem(name: "Axis", fields: fields, model: model))

        ParameterLogic.install(fieldParameter: "Axis", fields: fields, into: &model)
        let table = try XCTUnwrap(model.table("Axis"))
        XCTAssertEqual(table.columns.map(\.name), ["Axis", "Axis Fields", "Axis Order"])
        XCTAssertEqual(table.columns.map(\.isHidden), [false, true, true])
        XCTAssertEqual(table.columns.first?.sortByColumn, "Axis Order")
        XCTAssertEqual(model.fieldParameters.first?.fields.map(\.name), ["Category", "Total"])

        let (engine, errors) = DialogFixture.engine(model)
        XCTAssertEqual(errors, [:])
        XCTAssertEqual(engine.data["Axis"]?.column("Axis")?.values, [.string("Category"), .string("Total")])
        XCTAssertEqual(engine.data["Axis"]?.column("Axis Order")?.values.map(\.asInt), [0, 1])
        XCTAssertEqual(engine.data["Axis"]?.column("Axis Fields")?.values.count, 2)
    }

    // MARK: Hierarchies

    func testHierarchies() throws {
        var table = try XCTUnwrap(DialogFixture.model().table("Product"))
        let first = HierarchyLogic.make(from: ["Category"], in: table)
        XCTAssertEqual(first.name, "Category Hierarchy")
        XCTAssertEqual(first.levels, ["Category"])
        table.hierarchies = [first]
        XCTAssertEqual(HierarchyLogic.make(from: ["Category", "Missing", "Category", "Name"], in: table).name, "Category Hierarchy 2")
        XCTAssertEqual(HierarchyLogic.make(from: ["Category", "Missing", "Category", "Name"], in: table).levels, ["Category", "Name"])
        XCTAssertEqual(HierarchyLogic.make(from: [], in: table).name, "Hierarchy")

        XCTAssertEqual(HierarchyLogic.move(["Y", "Q", "M"], from: 2, to: 0), ["M", "Y", "Q"])
        XCTAssertEqual(HierarchyLogic.move(["Y", "Q", "M"], from: 0, to: 1), ["Q", "Y", "M"])
        XCTAssertEqual(HierarchyLogic.move(["Y", "Q", "M"], from: 0, to: 3), ["Y", "Q", "M"])
        XCTAssertEqual(HierarchyLogic.adding("name", to: ["Category", "Name"]), ["Category", "Name"])
        XCTAssertEqual(HierarchyLogic.adding("Name", to: ["Category"]), ["Category", "Name"])

        XCTAssertEqual(HierarchyLogic.problems([first], table: table), [])
        XCTAssertEqual(HierarchyLogic.problems([Hierarchy(name: "", levels: ["Name"])], table: table), ["Name the hierarchy."])
        XCTAssertEqual(HierarchyLogic.problems([first, Hierarchy(name: "category hierarchy", levels: ["Name"])], table: table),
                       ["Another hierarchy is already named “Category Hierarchy”."])
        XCTAssertEqual(HierarchyLogic.problems([Hierarchy(name: "Name", levels: ["Name"])], table: table), ["“Name” is already a column in Product."])
        XCTAssertEqual(HierarchyLogic.problems([Hierarchy(name: "H", levels: [])], table: table), ["“H” needs at least one level."])
        XCTAssertEqual(HierarchyLogic.problems([Hierarchy(name: "H", levels: ["Colour"])], table: table), ["“H” uses “Colour”, which is not a column of Product."])
        XCTAssertEqual(HierarchyLogic.problems([Hierarchy(name: "H", levels: ["Name", "name"])], table: table), ["“H” lists “name” twice."])
    }

    // MARK: Groups and bins

    func testListGrouping() throws {
        let table = try XCTUnwrap(DialogFixture.model().table("Sales"))
        let region = try XCTUnwrap(table.column("Region"))
        var d = GroupingLogic.draft(source: region, table: table)
        XCTAssertEqual(d.name, "Region (groups)")
        XCTAssertEqual(d.mode, .list)
        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .text), ["Create at least one group."])

        let all: [Value] = [.string("East"), .string("North"), .string("West")]
        let first = try XCTUnwrap(GroupingLogic.group([.string("East"), .string("North")], in: &d))
        XCTAssertEqual(d.groups.map(\.name), ["East & North"])
        XCTAssertEqual(GroupingLogic.ungrouped(all, draft: d), [.string("West")])
        // Grouping a value that is already grouped moves it; the emptied group disappears.
        GroupingLogic.group([.string("North"), .string("West")], in: &d)
        XCTAssertEqual(d.groups.map(\.name), ["East & North", "North & West"])
        XCTAssertEqual(d.groups.map(\.members), [[.string("East")], [.string("North"), .string("West")]])
        GroupingLogic.add([.string("West")], to: first, in: &d)
        XCTAssertEqual(d.groups.map(\.members), [[.string("East"), .string("West")], [.string("North")]])
        GroupingLogic.ungroup(value: .string("North"), in: &d)
        XCTAssertEqual(d.groups.count, 1)
        XCTAssertEqual(GroupingLogic.ungrouped(all, draft: d), [.string("North")])

        d.groups[0].name = "Coasts"
        d.includeOther = true
        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .text), [])
        let g = GroupingLogic.grouping(from: d)
        XCTAssertEqual(g.kind, .list)
        XCTAssertEqual(g.groups, ["Coasts": [.string("East"), .string("West")]])
        XCTAssertEqual(g.otherGroupName, "Other")
        let column = GroupingLogic.column(from: d, sourceType: .text)
        XCTAssertEqual(column.dataType, .text)
        XCTAssertEqual(column.summarizeBy, Aggregation.none)

        d.otherName = "coasts"
        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .text), ["Two groups are named “coasts”."])
        d.includeOther = false; d.name = "Region"
        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .text), ["A column named “Region” already exists in Sales."])
        XCTAssertEqual(GroupingLogic.problems(d, table: table, editing: "Region", sourceType: .text), [])

        // The engine fills the column: grouped rows get the group name, the rest "Other".
        var model = DialogFixture.model()
        d.name = "Region (groups)"; d.includeOther = true; d.otherName = "Other"
        model.tables[0].columns.append(GroupingLogic.column(from: d, sourceType: .text))
        let (engine, errors) = DialogFixture.engine(model)
        XCTAssertEqual(errors, [:])
        XCTAssertEqual(engine.data["Sales"]?.column("Region (groups)")?.values,
                       [.string("Coasts"), .string("Coasts"), .string("Coasts"), .string("Other")])   // West, West, East, North

        // Re-opening the saved column gives the same draft back.
        let reopened = GroupingLogic.draft(source: region, existing: model.tables[0].columns.last, table: model.tables[0])
        XCTAssertEqual(reopened.groups.map(\.name), ["Coasts"])
        XCTAssertTrue(reopened.includeOther)
    }

    func testBinDrafts() throws {
        let table = try XCTUnwrap(DialogFixture.model().table("Sales"))
        let amount = try XCTUnwrap(table.column("Amount"))
        var d = GroupingLogic.draft(source: amount, table: table, range: (0, 100))
        XCTAssertEqual(d.name, "Amount (bins)")
        XCTAssertEqual(d.mode, .bins)
        XCTAssertEqual(d.binSize, 10)
        XCTAssertEqual(GroupingLogic.suggestedSize(minimum: 0, maximum: 37), 5)       // 3.7 per bin rounds to 5
        XCTAssertEqual(GroupingLogic.suggestedSize(minimum: 0, maximum: 2500), 200)   // 250 per bin rounds to 200
        XCTAssertEqual(GroupingLogic.suggestedSize(minimum: 4, maximum: 4), 1)
        XCTAssertEqual(GroupingLogic.binCount(size: 10, minimum: 3, maximum: 47), 5)  // bins 0, 10, 20, 30, 40
        XCTAssertEqual(GroupingLogic.binSize(count: 4, minimum: 0, maximum: 100), 25)

        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .decimal), [])
        d.binSize = 0
        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .decimal), ["Bin size must be greater than zero."])
        d.bySize = false; d.binCount = 0
        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .decimal), ["The number of bins must be at least 1."])
        d.binCount = 4.9
        let g = GroupingLogic.grouping(from: d)
        XCTAssertEqual(g.kind, .binCount)
        XCTAssertEqual(g.binValue, 4)
        XCTAssertEqual(GroupingLogic.column(from: d, sourceType: .integer).dataType, .decimal)
        XCTAssertEqual(GroupingLogic.column(from: d, sourceType: .date).dataType, .date)
        XCTAssertEqual(GroupingLogic.problems(d, table: table, sourceType: .text).count, 1)

        let date = try XCTUnwrap(table.column("OrderDate"))
        let dd = GroupingLogic.draft(source: date, table: table)
        XCTAssertEqual(dd.unit, .month)
        XCTAssertEqual(dd.binSize, 1)
    }

    func testBinning() {
        var size = ColumnGrouping(kind: .binSize, sourceColumn: "Amount")
        size.binValue = 10
        XCTAssertEqual(size.bin(.double(37), minimum: 3, maximum: 47), .double(30))
        XCTAssertEqual(size.bin(.int(40), minimum: 3, maximum: 47), .double(40))
        XCTAssertEqual(size.bin(.double(-5), minimum: -5, maximum: 47), .double(-10))
        XCTAssertEqual(size.bin(.null, minimum: 0, maximum: 1), .null)
        XCTAssertEqual(size.bin(.string("37"), minimum: 0, maximum: 1), .null)
        size.binValue = 0.1
        XCTAssertEqual(size.bin(.double(0.3), minimum: 0, maximum: 1), .double(0.3), "0.3 / 0.1 is just under 3 in floating point")

        var count = ColumnGrouping(kind: .binCount, sourceColumn: "Amount")
        count.binValue = 4                                             // 0–25, 25–50, 50–75, 75–100
        XCTAssertEqual(count.bin(.double(24.9), minimum: 0, maximum: 100), .double(0))
        XCTAssertEqual(count.bin(.double(25), minimum: 0, maximum: 100), .double(25))
        XCTAssertEqual(count.bin(.double(100), minimum: 0, maximum: 100), .double(75), "the maximum belongs to the last bin")
        XCTAssertEqual(count.bin(.double(7), minimum: 7, maximum: 7), .double(7))

        let date = Value.date(day(2024, 3, 14))
        var months = ColumnGrouping(kind: .binSize, sourceColumn: "OrderDate")
        months.binUnit = .month; months.binValue = 1
        XCTAssertEqual(months.bin(date, minimum: 0, maximum: 0), .date(day(2024, 3, 1)))
        months.binValue = 3                                            // quarters: Jan–Mar starts 1 Jan
        XCTAssertEqual(months.bin(date, minimum: 0, maximum: 0), .date(day(2024, 1, 1)))
        XCTAssertEqual(months.bin(.date(day(2024, 12, 31)), minimum: 0, maximum: 0), .date(day(2024, 10, 1)))
        var years = months
        years.binUnit = .year; years.binValue = 1
        XCTAssertEqual(years.bin(date, minimum: 0, maximum: 0), .date(day(2024, 1, 1)))
        var weeks = months
        weeks.binUnit = .day; weeks.binValue = 7                       // serial 45365 → 45360, which is 9 March
        XCTAssertEqual(weeks.bin(date, minimum: 0, maximum: 0), .date(day(2024, 3, 9)))
        var hours = months
        hours.binUnit = .hour; hours.binValue = 12
        XCTAssertEqual(hours.bin(.date(day(2024, 3, 14, hour: 17)), minimum: 0, maximum: 0), .date(day(2024, 3, 14, hour: 12)))
    }

    func testTheEngineBinsAColumn() throws {
        var model = DialogFixture.model()
        var d = GroupingLogic.draft(source: try XCTUnwrap(model.tables[0].column("Amount")), table: model.tables[0])
        d.binSize = 25
        model.tables[0].columns.append(GroupingLogic.column(from: d, sourceType: .decimal))
        let (engine, errors) = DialogFixture.engine(model)
        XCTAssertEqual(errors, [:])
        XCTAssertEqual(engine.data["Sales"]?.column("Amount (bins)")?.values.map(\.asDouble), [0, 0, 25, 25])   // 10, 20, 30, 40
    }

    // MARK: Date tables and calendars

    func testDateTableValidation() {
        let days = (1...4).map { Value.date(day(2024, 1, $0)) }
        let ok = DateTableLogic.validate(days, type: .date, column: "Date")
        XCTAssertTrue(ok.isValid)
        XCTAssertEqual(ok.first, day(2024, 1, 1))
        XCTAssertEqual(ok.last, day(2024, 1, 4))
        XCTAssertEqual(DateTableLogic.summary(ok), "4 contiguous dates, 2024-01-01 to 2024-01-04.")
        // Order does not matter.
        XCTAssertTrue(DateTableLogic.validate(days.reversed(), type: .dateTime).isValid)

        XCTAssertEqual(DateTableLogic.validate(days + [.null], type: .date, column: "Date").problems,
                       ["Date has 1 blank value. Every row needs a date."])
        XCTAssertEqual(DateTableLogic.validate(days + [days[0], days[1]], type: .date, column: "Date").problems,
                       ["Date repeats 2 dates. Each date may appear only once."])
        let gap = [days[0], days[1], .date(day(2024, 1, 6))]           // the 3rd, 4th and 5th are missing
        XCTAssertEqual(DateTableLogic.validate(gap, type: .date, column: "Date").problems,
                       ["Date is missing 3 days between its first and last date, starting with 2024-01-03. Dates must be contiguous."])
        XCTAssertEqual(DateTableLogic.validate([.int(1)], type: .integer, column: "Year").problems,
                       ["Year is whole number. A date table needs a Date or Date/Time column."])
        XCTAssertEqual(DateTableLogic.validate([], type: .date, column: "Date").problems, ["Date has no rows."])
        XCTAssertEqual(DateTableLogic.validate([.null, .null], type: .date, column: "Date").problems.count, 1)

        // Date/Time columns must carry one time of day throughout.
        let noon = (1...3).map { Value.date(day(2024, 1, $0, hour: 12)) }
        XCTAssertTrue(DateTableLogic.validate(noon, type: .dateTime).isValid)
        let mixed = [Value.date(day(2024, 1, 1)), .date(day(2024, 1, 2, hour: 9)), .date(day(2024, 1, 3))]
        XCTAssertEqual(DateTableLogic.validate(mixed, type: .dateTime, column: "Stamp").problems,
                       ["Stamp has 2 different times of day. A Date/Time column must carry the same time on every row."])

        XCTAssertEqual(DateTableLogic.candidates(DialogFixture.model().tables[2]).map(\.name), ["Date"])
        XCTAssertEqual(DateTableLogic.candidates(DialogFixture.model().tables[1]).map(\.name), [])
    }

    func testCalendars() throws {
        var model = DialogFixture.model()
        let table = model.tables[2]
        let made = CalendarLogic.make(in: table, model: model, alongside: [])
        XCTAssertEqual(made.name, "Calendar")
        XCTAssertEqual(made.columnsByUnit, ["date": "Date", "year": "Year", "month": "Month"])
        XCTAssertEqual(CalendarLogic.make(in: table, model: model, alongside: [made]).name, "Calendar 2")
        XCTAssertEqual(CalendarLogic.problems([made], table: table, model: model), [])

        var c = made
        c.name = "Date"
        XCTAssertEqual(CalendarLogic.problems([c], table: table, model: model).count, 1, "a calendar can't share a table's name")
        c = made; c.columnsByUnit["quarter"] = "Month"
        XCTAssertEqual(CalendarLogic.problems([c], table: table, model: model), ["“Calendar” maps “Month” to more than one unit."])
        c = made; c.columnsByUnit["date"] = "Year"
        XCTAssertEqual(CalendarLogic.problems([c], table: table, model: model).first,
                       "“Calendar” needs a Date or Date/Time column for Date; Year is whole number.")
        c = made; c.columnsByUnit["date"] = nil
        XCTAssertEqual(CalendarLogic.problems([c], table: table, model: model), ["Map the Date unit in “Calendar”, or mark Date as a date table."])
        model.tables[2].dateColumn = "Date"
        XCTAssertEqual(CalendarLogic.problems([c], table: model.tables[2], model: model), [])
        c = made; c.columnsByUnit = [:]
        XCTAssertEqual(CalendarLogic.problems([c], table: table, model: model), ["Map at least one column in “Calendar”."])
        c = made; c.columnsByUnit["week"] = "Gone"
        XCTAssertEqual(CalendarLogic.problems([c], table: table, model: model), ["“Calendar” maps Week to “Gone”, which is not a column of Date."])
        // Calendar names are unique across the whole model.
        model.tables[0].calendars = [CalendarDefinition(name: "Fiscal", columnsByUnit: ["date": "OrderDate"])]
        c = made; c.name = "fiscal"
        XCTAssertEqual(CalendarLogic.problems([c], table: table, model: model), ["Another calendar is already named “Fiscal”."])
        c = made; c.columnsByUnit["week"] = ""; c.name = " Retail "
        XCTAssertEqual(CalendarLogic.cleaned([c]).first?.name, "Retail")
        XCTAssertNil(CalendarLogic.cleaned([c]).first?.columnsByUnit["week"])

        var fiscal = CalendarDefinition(name: "F", columnsByUnit: [:])
        XCTAssertEqual(fiscal.fiscalYearEndMonth, 12)                  // a January start ends in December
        fiscal.fiscalYearStartMonth = 7
        XCTAssertEqual(fiscal.fiscalYearEndMonth, 6)
        fiscal.fiscalYearStartMonth = 12
        XCTAssertEqual(fiscal.fiscalYearEndMonth, 11)
    }

    func testACalendarDrivesYearToDate() throws {
        // Sales on 1–4 Jan 2024 are 10, 20, 30, 40. With a calendar year the year-to-date on 3 Jan is 60.
        var model = DialogFixture.model()
        model.relationships = [Relationship(fromTable: "Sales", fromColumn: "OrderDate", toTable: "Date", toColumn: "Date")]
        model.tables[2].dateColumn = "Date"
        model.tables[2].calendars = [CalendarLogic.make(in: model.tables[2], model: model, alongside: [])]
        model.tables[0].measures.append(Measure(name: "YTD", expression: "TOTALYTD([Total], Calendar)"))
        let (engine, errors) = DialogFixture.engine(model)
        XCTAssertEqual(errors, [:])
        let result = try engine.query("EVALUATE ROW(\"v\", CALCULATE([YTD], 'Date'[Date] = DATE(2024, 1, 3)))")
        XCTAssertEqual(result.first?.columns.first?.values.first?.asDouble, 60)
    }
}
