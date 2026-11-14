import Foundation
import FacetCore

public extension MSyntax {
    /// M source for a FacetCore value of a column type: `"text"`, `12.5`, `true`, `#date(2024, 1, 31)`, `null`…
    static func literal(_ value: Value, type: DataType) -> String { literal(MValue(value, type: type)) }
}
