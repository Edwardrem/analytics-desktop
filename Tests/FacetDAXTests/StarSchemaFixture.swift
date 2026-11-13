import XCTest
import FacetCore
@testable import FacetDAX

/// Star-schema fixture shared by the context, relationship and iterator tests.
///
/// Tables:
/// - `Date` (6 rows): Jan 1–3 of 2024 and 2025.
/// - `Product` (5): Widget/Gadget (Tools, Red/Blue), Gizmo/Doohickey (Toys, Red/Blue), Thing (Office, Red).
/// - `Customer` (4): Ann/Ben (US), Cal/Dee (UK).
/// - `Store` (3): North/South/East.
/// - `Sales` (11 rows): fact with DateKey, ProductKey, CustomerKey, StoreKey, ShipDateKey, Qty, Amount.
///   Row 11 references ProductKey 99, which matches no product, so `Product` has a virtual blank row.
///
/// Relationships:
/// - Sales[DateKey] → Date[DateKey]: active, single.
/// - Sales[ShipDateKey] → Date[DateKey]: inactive, single.
/// - Sales[ProductKey] → Product[ProductKey]: active, single.
/// - Sales[CustomerKey] → Customer[CustomerKey]: active, single.
/// - Sales[StoreKey] → Store[StoreKey]: active, bidirectional.
///
/// Measures: `Total Amount`, `Total Qty`, `Sales Rows`, `Shipped Amount` (USERELATIONSHIP),
/// `Amount Per Unit` (DIVIDE).
///
/// Hand-computed aggregates over the 11 sales rows (Amount 700, Qty 23):
/// - By order date: 2024 → 220 (6 rows), 2025 → 480 (5). By ship date (only dates present in the
///   Date dimension match; Jan 4–6 join the blank date row): 2024 → 70, 2025 → 380.
/// - By category: Tools 140, Toys 230, Office 300, blank product 30.
/// - By colour: Red 490 (7 rows), Blue 180 (4), blank 30.
/// - By customer: Ann 410, Ben 30, Cal 90, Dee 170. By country: US 440, UK 260.
/// - By store: North 130, South 250, East 320.
/// - Product totals: Widget 40 (3 rows), Gadget 100 (2), Gizmo 150 (2), Doohickey 80 (1), Thing 300 (2), blank 30 (1).
enum StarSchema {

    /// A UTC date value for fixture literals, failing loudly on a bad format.
    static func day(_ s: String) -> Value {
        guard let d = DateParsing.parse(s) else { fatalError("Bad fixture date \(s)") }
        return .date(d)
    }

    static func model() -> SemanticModel {
        var date = ModelTable(name: "Date", columns: [
            ModelColumn(name: "DateKey", dataType: .integer),
            ModelColumn(name: "Date", dataType: .date),
            ModelColumn(name: "Year", dataType: .integer),
            ModelColumn(name: "Month", dataType: .integer),
        ])
        date.dateColumn = "Date"
        let product = ModelTable(name: "Product", columns: [
            ModelColumn(name: "ProductKey", dataType: .integer),
            ModelColumn(name: "Product", dataType: .text),
            ModelColumn(name: "Category", dataType: .text),
            ModelColumn(name: "Color", dataType: .text),
            ModelColumn(name: "Price", dataType: .integer),
        ])
        let customer = ModelTable(name: "Customer", columns: [
            ModelColumn(name: "CustomerKey", dataType: .integer),
            ModelColumn(name: "Customer", dataType: .text),
            ModelColumn(name: "Country", dataType: .text),
        ])
        let store = ModelTable(name: "Store", columns: [
            ModelColumn(name: "StoreKey", dataType: .integer),
            ModelColumn(name: "Store", dataType: .text),
        ])
        var sales = ModelTable(name: "Sales", columns: [
            ModelColumn(name: "DateKey", dataType: .integer),
            ModelColumn(name: "ProductKey", dataType: .integer),
            ModelColumn(name: "CustomerKey", dataType: .integer),
            ModelColumn(name: "StoreKey", dataType: .integer),
            ModelColumn(name: "ShipDateKey", dataType: .integer),
            ModelColumn(name: "Qty", dataType: .integer),
            ModelColumn(name: "Amount", dataType: .integer),
        ])
        sales.measures = [
            Measure(name: "Total Amount", expression: "SUM(Sales[Amount])"),
            Measure(name: "Total Qty", expression: "SUM(Sales[Qty])"),
            Measure(name: "Sales Rows", expression: "COUNTROWS(Sales)"),
            Measure(name: "Shipped Amount", expression: "CALCULATE(SUM(Sales[Amount]), USERELATIONSHIP(Sales[ShipDateKey], Date[DateKey]))"),
            Measure(name: "Amount Per Unit", expression: "DIVIDE(SUM(Sales[Amount]), SUM(Sales[Qty]))"),
        ]

        var model = SemanticModel()
        model.tables = [date, product, customer, store, sales]
        model.relationships = [
            Relationship(fromTable: "Sales", fromColumn: "DateKey", toTable: "Date", toColumn: "DateKey"),
            Relationship(fromTable: "Sales", fromColumn: "ShipDateKey", toTable: "Date", toColumn: "DateKey"),
            Relationship(fromTable: "Sales", fromColumn: "ProductKey", toTable: "Product", toColumn: "ProductKey"),
            Relationship(fromTable: "Sales", fromColumn: "CustomerKey", toTable: "Customer", toColumn: "CustomerKey"),
            Relationship(fromTable: "Sales", fromColumn: "StoreKey", toTable: "Store", toColumn: "StoreKey"),
        ]
        model.relationships[1].isActive = false
        model.relationships[4].crossFilter = .both
        return model
    }

    static func data() -> DataStore {
        var date = DataTable(name: "Date", columnNames: ["DateKey", "Date", "Year", "Month"], rows: [
            [20240101, day("2024-01-01"), 2024, 1],
            [20240102, day("2024-01-02"), 2024, 1],
            [20240103, day("2024-01-03"), 2024, 1],
            [20250101, day("2025-01-01"), 2025, 1],
            [20250102, day("2025-01-02"), 2025, 1],
            [20250103, day("2025-01-03"), 2025, 1],
        ])
        date.inferTypes()
        var product = DataTable(name: "Product", columnNames: ["ProductKey", "Product", "Category", "Color", "Price"], rows: [
            [1, "Widget", "Tools", "Red", 10],
            [2, "Gadget", "Tools", "Blue", 20],
            [3, "Gizmo", "Toys", "Red", 30],
            [4, "Doohickey", "Toys", "Blue", 40],
            [5, "Thing", "Office", "Red", 50],
        ])
        product.inferTypes()
        var customer = DataTable(name: "Customer", columnNames: ["CustomerKey", "Customer", "Country"], rows: [
            [1, "Ann", "US"],
            [2, "Ben", "US"],
            [3, "Cal", "UK"],
            [4, "Dee", "UK"],
        ])
        customer.inferTypes()
        var store = DataTable(name: "Store", columnNames: ["StoreKey", "Store"], rows: [
            [1, "North"],
            [2, "South"],
            [3, "East"],
        ])
        store.inferTypes()
        // Row 11 (index 10) references ProductKey 99: no matching product → virtual blank row.
        var sales = DataTable(name: "Sales", columnNames: ["DateKey", "ProductKey", "CustomerKey", "StoreKey", "ShipDateKey", "Qty", "Amount"], rows: [
            [20240101, 1, 1, 1, 20240102, 2, 20],
            [20240102, 2, 2, 1, 20240103, 1, 20],
            [20240103, 3, 1, 2, 20240104, 3, 90],
            [20240103, 1, 3, 3, 20240105, 1, 10],
            [20250101, 4, 4, 2, 20250102, 2, 80],
            [20250102, 5, 1, 3, 20250103, 5, 250],
            [20250102, 1, 2, 1, 20250104, 1, 10],
            [20250103, 2, 3, 2, 20250105, 4, 80],
            [20250103, 3, 4, 3, 20250106, 2, 60],
            [20240102, 5, 1, 1, 20250101, 1, 50],
            [20240103, 99, 4, 1, 20240103, 1, 30],
        ])
        sales.inferTypes()
        return DataStore(tables: [date.name: date, product.name: product, customer.name: customer,
                                  store.name: store, sales.name: sales])
    }

    /// A fresh engine with the star schema loaded; fails the test when loading reports errors.
    static func makeEngine() -> DAXEngine {
        let engine = DAXEngine()
        let errors = engine.load(model: model(), data: data())
        if !errors.isEmpty { XCTFail("fixture failed to load: \(errors)") }
        return engine
    }
}
