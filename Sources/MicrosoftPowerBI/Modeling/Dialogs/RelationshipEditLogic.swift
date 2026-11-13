import Foundation
import FacetCore

/// Validation for the relationship editor: what stops a relationship being saved, and what the
/// author should know about it.
enum RelationshipEditLogic {
    struct Check: Equatable {
        var problem: String?
        var warnings: [String] = []
    }

    /// Whether each end's column holds unique values; nil when there is no data to tell.
    struct Uniqueness: Equatable {
        var from: Bool?
        var to: Bool?
    }

    static func uniqueness(_ r: Relationship, data: DataStore) -> Uniqueness {
        func unique(_ table: String, _ column: String) -> Bool? {
            guard let key = data.tables.keys.first(where: { ModelDAX.same($0, table) }),
                  let values = data.tables[key]?.column(column)?.values else { return nil }
            return RelationshipLogic.isUnique(values)
        }
        return Uniqueness(from: unique(r.fromTable, r.fromColumn), to: unique(r.toTable, r.toColumn))
    }

    /// One-to-one relationships always filter both ways; the security filter option only applies to both-direction filters.
    static func normalized(_ r: Relationship) -> Relationship {
        var r = r
        if r.cardinality == .oneToOne { r.crossFilter = .both }
        if r.crossFilter == .single { r.securityFilterBothDirections = false }
        return r
    }

    static func check(_ relationship: Relationship, model: SemanticModel, uniqueness: Uniqueness = Uniqueness()) -> Check {
        let r = normalized(relationship)
        if let problem = RelationshipLogic.problem(r, model: model) { return Check(problem: problem) }
        // A "one" side must hold unique values.
        let fromOne = r.cardinality == .oneToMany || r.cardinality == .oneToOne
        let toOne = r.cardinality == .manyToOne || r.cardinality == .oneToOne
        if fromOne, uniqueness.from == false {
            return Check(problem: "\(r.fromTable)[\(r.fromColumn)] has duplicate values, so it can't be the “one” side. Choose a different cardinality.")
        }
        if toOne, uniqueness.to == false {
            return Check(problem: "\(r.toTable)[\(r.toColumn)] has duplicate values, so it can't be the “one” side. Choose a different cardinality.")
        }
        if r.isActive, RelationshipLogic.hasActivePath(model, from: r.fromTable, to: r.toTable, excluding: r.id) {
            return Check(problem: "\(r.fromTable) and \(r.toTable) are already connected by another active path. Deactivate that relationship first, or keep this one inactive.")
        }
        var warnings: [String] = []
        if r.cardinality == .manyToMany {
            warnings.append("Many-to-many: neither column is treated as unique, so totals can count a row more than once.")
        }
        if r.crossFilter == .both, r.cardinality != .oneToOne {
            warnings.append("Filtering in both directions can make results ambiguous and slower. Use it only when you need it.")
        }
        if !r.isActive { warnings.append("Inactive: measures use it only through USERELATIONSHIP.") }
        return Check(problem: nil, warnings: warnings)
    }

    /// The cardinality the data implies for the chosen columns, when it can be told.
    static func detectedCardinality(_ u: Uniqueness) -> Cardinality? {
        guard let from = u.from, let to = u.to else { return nil }
        return RelationshipLogic.cardinality(fromUnique: from, toUnique: to)
    }

    /// Inserts or replaces a relationship by id.
    static func upsert(_ r: Relationship, into model: inout SemanticModel) {
        let r = normalized(r)
        if let i = model.relationships.firstIndex(where: { $0.id == r.id }) { model.relationships[i] = r }
        else { model.relationships.append(r) }
    }

    /// Why a relationship can't be switched on; nil when it can.
    static func activationProblem(_ id: UUID, model: SemanticModel) -> String? {
        guard let r = model.relationships.first(where: { $0.id == id }) else { return "That relationship no longer exists." }
        if RelationshipLogic.hasActivePath(model, from: r.fromTable, to: r.toTable, excluding: r.id) {
            return "\(r.fromTable) and \(r.toTable) are already connected by another active path. Deactivate that relationship first."
        }
        return nil
    }

    /// "1", "*" marks for each end of a relationship.
    static func endMarks(_ c: Cardinality) -> (from: String, to: String) {
        switch c {
        case .manyToOne: return ("*", "1")
        case .oneToMany: return ("1", "*")
        case .oneToOne: return ("1", "1")
        case .manyToMany: return ("*", "*")
        }
    }
}
