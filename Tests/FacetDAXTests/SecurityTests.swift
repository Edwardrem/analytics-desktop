import XCTest
import FacetCore
@testable import FacetDAX

/// Row-level and object-level security over the star schema (roles from `StarSchema.addRoles`).
/// Expected values are hand-computed: Ann 410, Ben 30, Cal 90, Dee 170; US 440, UK 260; Red 490.
final class SecurityTests: StarSchemaTestCase {
    /// Loads the star schema viewed as the given roles.
    private func view(as roles: String..., user: String = "", upn: String = "", bothDirections: Bool = false) {
        engine = StarSchema.makeEngine(roles: roles, userName: user, userPrincipalName: upn) { model, _ in
            StarSchema.addRoles(&model)
            // Sales → Store is the bidirectional relationship of the fixture.
            if bothDirections { model.relationships[4].securityFilterBothDirections = true }
        }
    }

    // MARK: Role filters

    func testNoRoleMeansNoRestriction() throws {
        view()
        XCTAssertEqual(try num("[Total Amount]"), 700)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 4)
    }

    func testDimensionFilterRestrictsTheDimensionAndTheFact() throws {
        view(as: "US")
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 2)
        XCTAssertEqual(try num("[Total Amount]"), 440)
        XCTAssertEqual(try num("[Sales Rows]"), 6)
        XCTAssertEqual(Set(try column("EVALUATE VALUES(Customer[Customer])", name: "Customer[Customer]")), ["Ann", "Ben"])
        // Ordinary filters work inside what the role allows: red products sold to US customers
        // (rows 1, 3, 6, 7, 10) = 20 + 90 + 250 + 10 + 50.
        XCTAssertEqual(try num("[Total Amount]", filters: [filter("Product", "Color", "Red")]), 420)
        // A filter on a customer the role hides finds nothing.
        XCTAssertTrue(try scalar("[Total Amount]", filters: [filter("Customer", "Customer", "Dee")]).isNull)
    }

    func testSecurityCannotBeRemovedByDAX() throws {
        view(as: "US")
        XCTAssertEqual(try num("CALCULATE([Total Amount], ALL(Customer))"), 440)
        XCTAssertEqual(try num("CALCULATE([Total Amount], ALL())"), 440)
        XCTAssertEqual(try num("CALCULATE([Total Amount], REMOVEFILTERS())"), 440)
        XCTAssertEqual(try num("CALCULATE([Total Amount], ALL(Sales))"), 440)
        XCTAssertEqual(try num("COUNTROWS(ALL(Customer))"), 2)
        XCTAssertEqual(try num("COUNTROWS(ALL(Customer[Country]))"), 1)
        XCTAssertEqual(try num("SUMX(ALL(Sales), Sales[Amount])"), 440)
        XCTAssertTrue(try scalar("CALCULATE([Total Amount], Customer[Country] = \"UK\")").isNull)
    }

    func testFactFilterDoesNotRestrictDimensions() throws {
        // Amount > 50: rows 3, 5, 6, 8, 9 → 90 + 80 + 250 + 80 + 60.
        view(as: "Big Sales")
        XCTAssertEqual(try num("[Total Amount]"), 560)
        XCTAssertEqual(try num("[Sales Rows]"), 5)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 4)
        XCTAssertEqual(try num("COUNTROWS(Product)"), 6)
        // RELATED works in a row filter: UK sales are rows 4, 5, 8, 9, 11.
        view(as: "UK Sales")
        XCTAssertEqual(try num("[Total Amount]"), 260)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 4)
        // FALSE() hides every row of the table, and only of that table.
        view(as: "Nothing")
        XCTAssertTrue(try scalar("[Total Amount]").isNull)
        XCTAssertTrue(try scalar("COUNTROWS(Sales)").isNull)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 4)
    }

    // MARK: Propagation

    func testSecurityFiltersTravelOneToManyOnly() throws {
        // Ben's sales (rows 2 and 7) are both in the North store. An ordinary filter reaches Store
        // through the bidirectional relationship …
        view()
        XCTAssertEqual(try num("COUNTROWS(Store)", filters: [filter("Customer", "Customer", "Ben")]), 1)
        // … but a security filter does not, unless the relationship says so.
        view(as: "Ben")
        XCTAssertEqual(try num("[Total Amount]"), 30)
        XCTAssertEqual(try num("COUNTROWS(Store)"), 3)
        XCTAssertEqual(try num("COUNTROWS(Product)"), 6)
        view(as: "Ben", bothDirections: true)
        XCTAssertEqual(try num("[Total Amount]"), 30)
        XCTAssertEqual(try num("COUNTROWS(Store)"), 1)
        // Sales → Product is single-direction, so Product stays whole either way.
        XCTAssertEqual(try num("COUNTROWS(Product)"), 6)
    }

    func testFiltersOfOneRoleCombine() throws {
        // US customers and toys: only row 3 (Ann, Gizmo, 90).
        view(as: "US Toys")
        XCTAssertEqual(try num("[Total Amount]"), 90)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 2)
        // Toys: Gizmo and Doohickey; no blank member is visible because the orphan sale is hidden.
        XCTAssertEqual(try num("COUNTROWS(VALUES(Product[Product]))"), 2)
    }

    func testSeveralRolesAreAdditive() throws {
        // US ∪ Dee: Ann, Ben, Dee → 410 + 30 + 170.
        view(as: "US", "Dee")
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 3)
        XCTAssertEqual(try num("[Total Amount]"), 610)
        // Roles on different tables: sales to US customers (440) plus red products sold to
        // anyone else (rows 4 and 9: 10 + 60). Each dimension is whole, because the other role
        // does not restrict it.
        view(as: "US", "Red")
        XCTAssertEqual(try num("[Total Amount]"), 510)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 4)
        XCTAssertEqual(try num("COUNTROWS(Product)"), 6)
        // (US ∧ Toys) ∪ Dee: row 3 plus Dee's rows 5, 9, 11 → 90 + 170.
        view(as: "US Toys", "Dee")
        XCTAssertEqual(try num("[Total Amount]"), 260)
        // A role without row filters grants everything.
        view(as: "US", "No Prices")
        XCTAssertEqual(try num("[Total Amount]"), 700)
    }

    // MARK: USERNAME / USERPRINCIPALNAME

    func testDynamicSecurityByUserName() throws {
        view(as: "Self", user: "Ann")
        XCTAssertEqual(try scalar("USERNAME()"), .string("Ann"))
        XCTAssertEqual(try num("[Total Amount]"), 410)
        XCTAssertEqual(try num("COUNTROWS(Customer)"), 1)
        view(as: "Self", user: "Cal")
        XCTAssertEqual(try num("[Total Amount]"), 90)
        // Nobody by that name: no rows.
        view(as: "Self", user: "Zed")
        XCTAssertTrue(try scalar("[Total Amount]").isNull)
    }

    func testUserPrincipalName() throws {
        view(as: "SelfUPN", user: "CONTOSO\\dee", upn: "dee@contoso.com")
        XCTAssertEqual(try scalar("USERNAME()"), .string("CONTOSO\\dee"))
        XCTAssertEqual(try scalar("USERPRINCIPALNAME()"), .string("dee@contoso.com"))
        XCTAssertEqual(try num("[Total Amount]"), 170)
        // Without a separate principal name it is the user name.
        view(as: "SelfUPN", user: "cal@contoso.com")
        XCTAssertEqual(try scalar("USERPRINCIPALNAME()"), .string("cal@contoso.com"))
        XCTAssertEqual(try num("[Total Amount]"), 90)
    }

    // MARK: Calculated objects and object-level security

    func testCalculatedColumnsIgnoreSecurity() throws {
        // Calculated columns are computed at refresh, before any role applies.
        engine = StarSchema.makeEngine(roles: ["US"]) { model, _ in
            StarSchema.addRoles(&model)
            var all = ModelColumn(name: "All Sales", dataType: .integer)
            all.expression = "CALCULATE(SUM(Sales[Amount]), ALL(Customer))"
            model.tables[2].columns.append(all)
        }
        XCTAssertEqual(try num("MAX(Customer[All Sales])"), 700)
        XCTAssertEqual(try num("[Total Amount]"), 440)
    }

    func testObjectLevelSecurity() throws {
        view(as: "No Prices")
        XCTAssertThrowsError(try scalar("SUM(Product[Price])"))
        XCTAssertThrowsError(try scalar("CALCULATE([Total Amount], Product[Price] > 10)"))
        XCTAssertEqual(try num("[Total Amount]"), 700)
        XCTAssertEqual(try num("COUNTROWS(VALUES(Product[Color]))"), 3)
        view(as: "No Stores")
        XCTAssertThrowsError(try scalar("COUNTROWS(Store)"))
        XCTAssertThrowsError(try scalar("CALCULATE([Total Amount], Store[Store] = \"North\")"))
        XCTAssertEqual(try num("[Total Amount]"), 700)
    }

    // MARK: Problems

    func testBrokenRoleFilterIsReportedAndHidesTheTable() throws {
        var model = StarSchema.model()
        StarSchema.addRoles(&model)
        let engine = DAXEngine()
        let errors = engine.load(model: model, data: StarSchema.data(), roles: ["Broken"])
        XCTAssertEqual(errors.count, 1, "\(errors)")
        XCTAssertTrue(errors.values.first?.contains("NoSuchColumn") ?? false, "\(errors)")
        // The table whose filter failed shows nothing rather than everything.
        XCTAssertTrue(try engine.scalar("COUNTROWS(Customer)").isNull)
        XCTAssertTrue(try engine.scalar("[Total Amount]").isNull)
    }

    func testUnknownRoleGrantsNothing() throws {
        var model = StarSchema.model()
        StarSchema.addRoles(&model)
        let engine = DAXEngine()
        let errors = engine.load(model: model, data: StarSchema.data(), roles: ["No Such Role"])
        XCTAssertEqual(errors.count, 1, "\(errors)")
        XCTAssertTrue(errors.values.first?.contains("No Such Role") ?? false, "\(errors)")
        // A role that does not exist denies access instead of lifting every restriction.
        XCTAssertTrue(try engine.scalar("[Total Amount]").isNull)
        XCTAssertTrue(try engine.scalar("COUNTROWS(Customer)").isNull)
        XCTAssertTrue(try engine.scalar("COUNTROWS(Product)").isNull)
        XCTAssertEqual(try engine.query("EVALUATE Sales").first?.rowCount, 0)
        // Alongside a real role, the real role is what the user has.
        let mixed = DAXEngine()
        let mixedErrors = mixed.load(model: model, data: StarSchema.data(), roles: ["US", "No Such Role"])
        XCTAssertEqual(mixedErrors.count, 1, "\(mixedErrors)")
        XCTAssertEqual(try mixed.scalar("[Total Amount]").asDouble, 440)
    }

    // MARK: Object-level security in table expressions

    func testHiddenColumnIsAbsentFromTableExpressions() throws {
        view(as: "No Prices")
        let visible = ["Product[ProductKey]", "Product[Product]", "Product[Category]", "Product[Color]"]
        XCTAssertEqual(try table("EVALUATE Product").columnNames, visible)
        XCTAssertEqual(try table("EVALUATE Product").rowCount, 6)
        XCTAssertEqual(try table("EVALUATE FILTER(Product, Product[Color] = \"Red\")").columnNames, visible)
        XCTAssertEqual(try table("EVALUATE ALL(Product)").columnNames, visible)
        XCTAssertEqual(try table("EVALUATE CALCULATETABLE(Product, Product[Category] = \"Toys\")").columnNames, visible)
        XCTAssertEqual(try table("EVALUATE TOPN(2, Product, Product[Product])").columnNames, visible)
        XCTAssertEqual(try table("EVALUATE UNION(Product, Product)").columnNames.count, 4)
        XCTAssertEqual(try table("EVALUATE ADDCOLUMNS(Product, \"One\", 1)").columnNames, visible + ["One"])
        XCTAssertEqual(try table("EVALUATE VAR T = Product RETURN T").columnNames, visible)
        XCTAssertEqual(try table("EVALUATE DISTINCT(Product)").columnNames, visible)
        // Nothing of the column leaks through text dumps either.
        let csv = try scalar("TOCSV(Product, -1)").asString
        XCTAssertFalse(csv.contains("Price"), csv)
        XCTAssertTrue(csv.contains("Widget"), csv)
        XCTAssertFalse(try scalar("TOJSON(Product, -1)").asString.contains("Price"))
        // Every way of naming the column is an error, as if it did not exist.
        XCTAssertThrowsError(try scalar("SUMX(Product, Product[Price])"))
        XCTAssertThrowsError(try scalar("SUMX(Product, [Price])"))
        XCTAssertThrowsError(try table("EVALUATE SELECTCOLUMNS(Product, \"P\", [Price])"))
        XCTAssertThrowsError(try table("EVALUATE SUMMARIZECOLUMNS(Product[Price])"))
        XCTAssertThrowsError(try table("EVALUATE VALUES(Product[Price])"))
        XCTAssertThrowsError(try scalar("SUMX(Sales, RELATED(Product[Price]))"))
        XCTAssertThrowsError(try scalar("LOOKUPVALUE(Product[Price], Product[Product], \"Widget\")"))
        XCTAssertThrowsError(try scalar("[Total Amount]", filters: [filter("Product", "Price", 10)]))
        XCTAssertEqual(engine.distinctValues(field: .column("Product", "Price"), filters: []), [])
        XCTAssertEqual(engine.distinctValues(field: .column("Product", "Color"), filters: []).count, 3)
        // The rest of the table works as before.
        XCTAssertEqual(try num("COUNTROWS(Product)"), 6)
        XCTAssertEqual(try num("SUMX(Product, [Total Amount])"), 700)
    }

    func testHiddenColumnOnTheFactTable() throws {
        engine = StarSchema.makeEngine(roles: ["No Qty"]) { model, _ in
            var role = SecurityRole(name: "No Qty")
            role.hiddenColumns = ["Sales[Qty]"]
            model.roles.append(role)
        }
        XCTAssertEqual(try table("EVALUATE Sales").columnNames,
                       ["Sales[DateKey]", "Sales[ProductKey]", "Sales[CustomerKey]", "Sales[StoreKey]", "Sales[ShipDateKey]", "Sales[Amount]"])
        XCTAssertEqual(try num("COUNTROWS(Sales)"), 11)
        // Measures over the hidden column fail; the others, RELATED and context transition still work.
        XCTAssertThrowsError(try scalar("[Total Qty]"))
        XCTAssertThrowsError(try scalar("[Amount Per Unit]"))
        XCTAssertEqual(try num("[Total Amount]"), 700)
        // Price of the product of each sale: 10 + 20 + 30 + 10 + 40 + 50 + 10 + 20 + 30 + 50 (the orphan row has none).
        XCTAssertEqual(try num("SUMX(Sales, RELATED(Product[Price]))"), 270)
        XCTAssertEqual(try num("SUMX(Sales, CALCULATE(SUM(Sales[Amount])))"), 20 + 20 + 90 + 10 + 80 + 250 + 10 + 80 + 60 + 50 + 30)
        XCTAssertEqual(try num("SUMX(FILTER(Sales, Sales[Amount] > 50), Sales[Amount])"), 560)
    }

    func testHiddenTableIsAbsent() throws {
        view(as: "No Stores")
        XCTAssertThrowsError(try table("EVALUATE Store"))
        XCTAssertThrowsError(try table("EVALUATE ALL(Store)"))
        XCTAssertThrowsError(try table("EVALUATE VALUES(Store[Store])"))
        XCTAssertThrowsError(try scalar("SUMX(Sales, RELATED(Store[StoreKey]))"))
        XCTAssertEqual(engine.distinctValues(field: .column("Store", "Store"), filters: []), [])
        // The key on the fact table is still there.
        XCTAssertTrue(try table("EVALUATE Sales").columnNames.contains("Sales[StoreKey]"))
        XCTAssertEqual(try num("COUNTROWS(VALUES(Sales[StoreKey]))"), 3)
    }

    func testCalculatedObjectsMayUseHiddenColumnsAndRoleFiltersMayUseCalculatedColumns() throws {
        func configure(_ model: inout SemanticModel) {
            StarSchema.addRoles(&model)
            var double = ModelColumn(name: "Double Price", dataType: .integer)
            double.expression = "Product[Price] * 2"
            model.tables[1].columns.append(double)
            var pricey = SecurityRole(name: "Pricey")
            pricey.tableFilters = ["Product": "Product[Double Price] > 50"]
            model.roles.append(pricey)
            var hideComputed = SecurityRole(name: "No Double")
            hideComputed.hiddenColumns = ["Product[Double Price]"]
            model.roles.append(hideComputed)
        }
        // The calculated column is computed from the hidden column; the role sees only the result.
        engine = StarSchema.makeEngine(roles: ["No Prices"]) { model, _ in configure(&model) }
        XCTAssertEqual(try num("MAX(Product[Double Price])"), 100)
        XCTAssertThrowsError(try scalar("MAX(Product[Price])"))
        // A role filter on a calculated column: prices above 25 are Gizmo, Doohickey and Thing.
        engine = StarSchema.makeEngine(roles: ["Pricey"]) { model, _ in configure(&model) }
        XCTAssertEqual(try num("[Total Amount]"), 150 + 80 + 300)
        XCTAssertEqual(try num("COUNTROWS(Product)"), 3)
        // A calculated column can be hidden too.
        engine = StarSchema.makeEngine(roles: ["No Double"]) { model, _ in configure(&model) }
        XCTAssertThrowsError(try scalar("MAX(Product[Double Price])"))
        XCTAssertFalse(try table("EVALUATE Product").columnNames.contains("Product[Double Price]"))
        XCTAssertEqual(try num("MAX(Product[Price])"), 50)
        // Recomputing the calculated objects keeps the role in force.
        XCTAssertTrue(engine.refreshCalculatedObjects().isEmpty)
        XCTAssertThrowsError(try scalar("MAX(Product[Double Price])"))
        XCTAssertFalse(try table("EVALUATE Product").columnNames.contains("Product[Double Price]"))
    }
}
