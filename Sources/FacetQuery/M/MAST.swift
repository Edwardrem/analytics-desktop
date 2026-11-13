import Foundation

/// A `name = expression` binding of a `let` (or a section member), with source ranges (UTF-16 offsets).
public struct MBinding {
    public var name: String
    public var expr: MExpr
    /// Range of the name token and of the expression text in the parsed source.
    public var nameRange: Range<Int>
    public var exprRange: Range<Int>
}

/// A declared function parameter in the AST.
public struct MParamDecl {
    public var name: String
    public var type: MTypeExpr?
    public var isOptional: Bool
}

/// Type syntax (after `type`, `as`, `is`).
public indirect enum MTypeExpr {
    case primitive(MType)
    case nullable(MTypeExpr)
    case list(MTypeExpr)
    case record(fields: [(name: String, type: MTypeExpr?, optional: Bool)], open: Bool)
    case table(MTypeExpr)
    case function(params: [MParamDecl], returns: MTypeExpr?)
    /// An arbitrary expression evaluating to a type value (e.g. `Int64.Type`).
    case expr(MExpr)
}

public enum MBinaryOp: String, Sendable {
    case add = "+", subtract = "-", multiply = "*", divide = "/", concat = "&"
    case equal = "=", notEqual = "<>", less = "<", lessEqual = "<=", greater = ">", greaterEqual = ">="
    case and, or, coalesce = "??"
}
public enum MUnaryOp: String, Sendable { case plus = "+", minus = "-", not }

/// The M abstract syntax tree.
public indirect enum MExpr {
    case literal(MValue)
    /// `inclusive` is the `@name` form.
    case identifier(String, inclusive: Bool)
    /// List items; a `.range` item expands to consecutive numbers.
    case list([MExpr])
    case range(MExpr, MExpr)
    case record([(name: String, value: MExpr)])
    /// `target[name]` / `target[name]?`; nil target is the implicit `_`.
    case fieldAccess(MExpr?, String, optional: Bool)
    /// `target[[a],[b]]`.
    case projection(MExpr?, [String], optional: Bool)
    /// `target{index}` / `target{index}?`.
    case itemAccess(MExpr, MExpr, optional: Bool)
    case invoke(MExpr, [MExpr])
    case function(params: [MParamDecl], returns: MTypeExpr?, body: MExpr)
    case each(MExpr)
    case letIn([MBinding], MExpr)
    case ifThenElse(MExpr, MExpr, MExpr)
    /// `try e` (no handler → error record) or `try e otherwise h`.
    case tryOtherwise(MExpr, MExpr?)
    /// `try e catch (x) => h` (param nil for `catch () => h`).
    case tryCatch(MExpr, param: String?, handler: MExpr)
    case raise(MExpr)
    case unary(MUnaryOp, MExpr)
    case binary(MBinaryOp, MExpr, MExpr)
    case asType(MExpr, MTypeExpr)
    case isType(MExpr, MTypeExpr)
    case typeValue(MTypeExpr)
    case meta(MExpr, MExpr)
    /// `...`
    case notImplemented
    /// `[section]!name` is not supported; a section document evaluates to a record of its members.
    case section([MBinding])
}
