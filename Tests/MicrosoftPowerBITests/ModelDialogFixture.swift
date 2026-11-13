import Foundation
import FacetCore
@testable import MicrosoftPowerBI

/// A small star schema written by hand, shared by the modeling-dialog tests.
///
///     Sales:   OrderID 1…4 · ProductID 1,1,2,3 · Amount 10,20,30,40 · OrderDate 1–4 Jan 2024 · Region West,West,East,North
///     Product: ProductID 1,2,3 · Name Bike,Helmet,Lock · Category Bikes,Gear,Gear
///     Date:    Date 1–4 Jan 2024 · Year 2024 · Month "Jan"
enum DialogFixture {
    static func day(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = hour
        return Calendar.utc.date(from: c) ?? Date(timeIntervalSince1970: 0)
    }

    static func model() -> SemanticModel {
        var m = SemanticModel()
        var sales = ModelTable(name: "Sales", columns: [
            ModelColumn(name: "OrderID", dataType: .integer), ModelColumn(name: "ProductID", dataType: .integer),
            ModelColumn(name: "Amount", dataType: .decimal), ModelColumn(name: "OrderDate", dataType: .date),
            ModelColumn(name: "Region", dataType: .text),
        ])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])")]
        let product = ModelTable(name: "Product", columns: [
            ModelColumn(name: "ProductID", dataType: .integer), ModelColumn(name: "Name", dataType: .text),
            ModelColumn(name: "Category", dataType: .text),
        ])
        let date = ModelTable(name: "Date", columns: [
            ModelColumn(name: "Date", dataType: .date), ModelColumn(name: "Year", dataType: .integer),
            ModelColumn(name: "Month", dataType: .text),
        ])
        m.tables = [sales, product, date]
        return m
    }

    static func data() -> DataStore {
        let dates = (1...4).map { Value.date(day(2024, 1, $0)) }
        var store = DataStore()
        store["Sales"] = DataTable(name: "Sales", columns: [
            DataColumn(name: "OrderID", type: .integer, values: [.int(1), .int(2), .int(3), .int(4)]),
            DataColumn(name: "ProductID", type: .integer, values: [.int(1), .int(1), .int(2), .int(3)]),
            DataColumn(name: "Amount", type: .decimal, values: [.double(10), .double(20), .double(30), .double(40)]),
            DataColumn(name: "OrderDate", type: .date, values: dates),
            DataColumn(name: "Region", type: .text, values: [.string("West"), .string("West"), .string("East"), .string("North")]),
        ])
        store["Product"] = DataTable(name: "Product", columns: [
            DataColumn(name: "ProductID", type: .integer, values: [.int(1), .int(2), .int(3)]),
            DataColumn(name: "Name", type: .text, values: [.string("Bike"), .string("Helmet"), .string("Lock")]),
            DataColumn(name: "Category", type: .text, values: [.string("Bikes"), .string("Gear"), .string("Gear")]),
        ])
        store["Date"] = DataTable(name: "Date", columns: [
            DataColumn(name: "Date", type: .date, values: dates),
            DataColumn(name: "Year", type: .integer, values: Array(repeating: .int(2024), count: 4)),
            DataColumn(name: "Month", type: .text, values: Array(repeating: .string("Jan"), count: 4)),
        ])
        return store
    }

    static func salesToProduct() -> Relationship {
        Relationship(fromTable: "Sales", fromColumn: "ProductID", toTable: "Product", toColumn: "ProductID")
    }

    /// The real engine, loaded with a model over the fixture data.
    @MainActor
    static func engine(_ model: SemanticModel, roles: [String] = []) -> (engine: CalculationService, errors: [String: String]) {
        let engine = Services.live().makeCalculation()
        let errors = engine.load(model: model, data: data(), roles: roles, userName: "")
        return (engine, errors)
    }
}
