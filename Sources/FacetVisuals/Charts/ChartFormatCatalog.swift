import Foundation
import FacetCore

/// One formatting property a chart honours, for generating the Format pane.
public struct FormatProperty: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case bool, number, string, color
        case options([String])
    }
    /// Card in the format bag, e.g. "legend".
    public var card: String
    /// Key within the card, e.g. "position".
    public var key: String
    /// Human-readable label for the Format pane.
    public var label: String
    public var kind: Kind
    /// Value used when the key is absent (`.null` = automatic / derived from data or theme).
    public var defaultValue: JSONValue

    public init(_ card: String, _ key: String, _ label: String, _ kind: Kind, _ defaultValue: JSONValue = .null) {
        self.card = card; self.key = key; self.label = label; self.kind = kind; self.defaultValue = defaultValue
    }
}
