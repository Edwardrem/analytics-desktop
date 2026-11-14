import XCTest
import FacetCore
@testable import MicrosoftPowerBI

/// A five-row sales table small enough to check every expected number by hand.
///
/// | Region | Product | Channel | Amount |
/// | North  | Apple   | Web     | 10 |
/// | North  | Pear    | Store   | 20 |
/// | South  | Apple   | Web     | 30 |
/// | South  | Pear    | Web     | 40 |
/// | East   | Apple   | Store   | 50 |
enum ReportFixture {
    static let region = FieldRef.column("Sales", "Region")
    static let product = FieldRef.column("Sales", "Product")
    static let channel = FieldRef.column("Sales", "Channel")
    static let amount = FieldRef.column("Sales", "Amount", .sum)
    static let total = FieldRef.measure("Sales", "Total")
    static let destination = FieldRef.measure("Sales", "Destination")

    static func data() -> DataTable {
        DataTable(name: "Sales", columnNames: ["Region", "Product", "Channel", "Amount"], rows: [
            [.string("North"), .string("Apple"), .string("Web"), .int(10)],
            [.string("North"), .string("Pear"), .string("Store"), .int(20)],
            [.string("South"), .string("Apple"), .string("Web"), .int(30)],
            [.string("South"), .string("Pear"), .string("Web"), .int(40)],
            [.string("East"), .string("Apple"), .string("Store"), .int(50)],
        ], types: [.text, .text, .text, .integer])
    }

    static func model() -> SemanticModel {
        var model = SemanticModel()
        var sales = ModelTable(name: "Sales", columns: [
            ModelColumn(name: "Region", dataType: .text), ModelColumn(name: "Product", dataType: .text),
            ModelColumn(name: "Channel", dataType: .text), ModelColumn(name: "Amount", dataType: .integer),
        ])
        sales.measures = [Measure(name: "Total", expression: "SUM(Sales[Amount])"),
                          Measure(name: "Destination", expression: "IF(SUM(Sales[Amount]) > 100, \"Details\", \"Nowhere\")")]
        model.tables = [sales]
        return model
    }

    /// A loaded calculation engine over the fixture.
    @MainActor static func engine() -> CalculationService {
        let engine = Services.live().makeCalculation()
        var store = DataStore()
        store["Sales"] = data()
        _ = engine.load(model: model(), data: store, roles: [], userName: "")
        return engine
    }

    /// A document holding the fixture's model and data (its engine loads in the background).
    @MainActor static func store() -> DocumentStore {
        let store = DocumentStore(services: .live())
        let model = model(), table = data()
        store.mutate("Load", invalidates: .model) { d in d.model = model; d.data["Sales"] = table }
        return store
    }

    static func point(_ field: FieldRef, _ value: String) -> DataPointSelection {
        DataPointSelection(fields: [field], values: [.string(value)])
    }

    static func chart(_ name: String = "Chart", category: FieldRef = region) -> VisualSpec {
        var v = VisualSpec(type: .clusteredColumn, frame: Frame(x: 0, y: 0, width: 300, height: 200), name: name)
        v.setFields(.category, [category])
        v.setFields(.values, [amount])
        return v
    }

    static func card() -> VisualSpec {
        var v = VisualSpec(type: .card, frame: Frame(x: 0, y: 0, width: 200, height: 100), name: "Card")
        v.setFields(.values, [amount])
        return v
    }

    /// The single number a card's query returns.
    static func number(_ data: VisualData) -> Double? {
        guard data.table.rowCount == 1, let i = data.indices(.values).first else { return nil }
        return data.table[0, i].asDouble
    }
}
