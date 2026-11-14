import Foundation
import FacetCore

/// A lexical environment: a chain of scopes mapping names to (possibly lazy) values.
public final class MEnv: @unchecked Sendable {
    private var name1: String?
    private var value1: MValue = .null
    private var vars: [String: MValue]?
    public let parent: MEnv?

    public init(parent: MEnv? = nil) { self.parent = parent }
    /// Single-binding scope (fast path for `each` and one-parameter functions).
    public init(parent: MEnv?, name: String, value: MValue) { self.parent = parent; name1 = name; value1 = value }
    public init(parent: MEnv?, vars: [String: MValue]) { self.parent = parent; self.vars = vars }

    public func define(_ name: String, _ value: MValue) {
        if vars == nil { vars = [:] }
        vars?[name] = value
    }
    /// The raw binding (may be `.lazy`), searching enclosing scopes.
    public func lookup(_ name: String) -> MValue? {
        var e: MEnv? = self
        while let env = e {
            if let n = env.name1, n == name { return env.value1 }
            if let v = env.vars?[name] { return v }
            e = env.parent
        }
        return nil
    }
    /// Names defined in this scope only.
    public var localNames: [String] { (name1.map { [$0] } ?? []) + (vars.map { Array($0.keys) } ?? []) }
}

/// Evaluates M expressions. One interpreter is one evaluation session: it carries the environment
/// (credentials, culture, privacy settings), resolves other queries, and records data-source access.
public final class MInterpreter: @unchecked Sendable {
    public let environment: QueryEnvironment
    public let library: MLibrary
    /// Resolves names of other queries / parameters (nil result = not a shared name).
    public var sharedResolver: ((String) throws -> MValue?)?
    /// Names available through `sharedResolver` (for `#shared`).
    public var sharedNames: () -> [String] = { [] }
    /// Messages written by `Diagnostics.Trace`.
    public private(set) var trace: [String] = []
    /// Data sources touched so far in this session: (kind, location, privacy level).
    public private(set) var accessedSources: [(kind: String, location: String, privacy: PrivacyLevel)] = []
    /// Native queries sent to sources during this session.
    public private(set) var nativeQueries: [String] = []
    private let lock = NSLock()
    private var depth = 0
    static let maxDepth = 4000

    public init(environment: QueryEnvironment = QueryEnvironment(), library: MLibrary = .shared) {
        self.environment = environment; self.library = library
    }

    public var culture: String { environment.culture }
    public func now() -> Date { environment.now() }

    // MARK: Entry points

    /// Parse and evaluate M text.
    public func evaluate(_ text: String, env: MEnv? = nil) throws -> MValue {
        let ast = try MParser.parse(text)
        return try eval(ast, env ?? MEnv()).forced()
    }

    /// Call a function value with already-evaluated arguments.
    public func call(_ f: MFunction, _ args: [MValue]) throws -> MValue {
        if args.count < f.minArgs || (f.maxArgs.map { args.count > $0 } ?? false) {
            let expected = f.maxArgs == nil ? "at least \(f.minArgs)" : (f.minArgs == f.maxArgs ? "\(f.minArgs)" : "\(f.minArgs)-\(f.maxArgs ?? 0)")
            throw MError("\(args.count) arguments were passed to \(f.name.map { "the function '\($0)'" } ?? "a function") which expects \(expected).")
        }
        switch f.implementation {
        case .native(let impl):
            return try impl(MArgs(values: args, functionName: f.name ?? "function"), self).forced()
        case .closure(let body, let env):
            depth += 1
            defer { depth -= 1 }
            if depth > MInterpreter.maxDepth { throw MError("Evaluation resulted in a stack overflow and cannot continue.") }
            let scope: MEnv
            if f.parameters.count == 1 {
                let v = args.first ?? .null
                if let t = f.parameters[0].type, !t.matches(v) { throw MError.typeMismatch(expected: t.mText, got: v) }
                scope = MEnv(parent: env, name: f.parameters[0].name, value: v)
            } else {
                var vars = [String: MValue](minimumCapacity: f.parameters.count)
                for (i, p) in f.parameters.enumerated() {
                    let v = i < args.count ? args[i] : .null
                    if let t = p.type, !(p.isOptional && v.isNull), !t.matches(v) { throw MError.typeMismatch(expected: t.mText, got: v) }
                    vars[p.name] = v
                }
                scope = MEnv(parent: env, vars: vars)
            }
            let r = try eval(body, scope).forced()
            if let rt = f.returnType, !rt.matches(r) { throw MError.typeMismatch(expected: rt.mText, got: r) }
            return r
        }
    }
    /// Call a value that must be a function.
    public func invoke(_ f: MValue, _ args: [MValue]) throws -> MValue {
        guard case .function(let fn) = try f.forced() else { throw MError.typeMismatch(expected: "function", got: f) }
        return try call(fn, args)
    }

    // MARK: Services for library functions

    /// Resolve a file path (absolute, `~`, `file://`, or relative to `environment.baseDirectory`).
    public func resolvePath(_ path: String) -> URL {
        if path.hasPrefix("file://"), let u = URL(string: path) { return u }
        let expanded = (path as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        if let base = environment.baseDirectory { return base.appendingPathComponent(expanded) }
        return URL(fileURLWithPath: expanded)
    }

    /// Record that a data source is being read, enforcing the privacy firewall.
    /// Call this from every data-access function before touching the source.
    public func noteDataSource(kind: String, location: String) throws {
        let level = environment.privacyLevel(kind: kind, location: location)
        lock.lock(); defer { lock.unlock() }
        if accessedSources.contains(where: { $0.kind == kind && $0.location == location }) { return }
        if environment.enforcePrivacyFirewall {
            for other in accessedSources where !MInterpreter.compatible(level, other.privacy) {
                throw MError.firewall("Query references other queries or steps, so it may not directly access a data source. "
                    + "The \(MInterpreter.describe(level)) source '\(location)' cannot be combined with the \(MInterpreter.describe(other.privacy)) source '\(other.location)'. "
                    + "Change the privacy levels in Data source settings or disable the privacy firewall.")
            }
        }
        accessedSources.append((kind, location, level))
    }
    private static func describe(_ l: PrivacyLevel) -> String {
        switch l { case .none: return "unclassified"; case .public: return "Public"; case .organizational: return "Organizational"; case .private: return "Private" }
    }
    /// Privacy compatibility: Private combines with nothing else; Organizational not with Public; None is ignored.
    static func compatible(_ a: PrivacyLevel, _ b: PrivacyLevel) -> Bool {
        if a == .none || b == .none { return true }
        if a == .private || b == .private { return false }
        return a == b
    }

    /// Record (and, when the environment requires it, ask approval for) a hand-written native query.
    public func approveNativeQuery(_ query: String, kind: String, location: String) throws {
        if environment.requireNativeQueryApproval {
            let ok = environment.approveNativeQuery?(NativeQueryRequest(query: query, sourceKind: kind, sourceLocation: location)) ?? false
            if !ok {
                throw MError.dataSource("Permission is required to run this native database query against '\(location)'. Approve the query to continue.")
            }
        }
        noteNativeQuery(query)
    }
    /// Record a native query that was sent to a source (folded or hand-written).
    public func noteNativeQuery(_ query: String) {
        lock.lock(); nativeQueries.append(query); lock.unlock()
    }
    public func credential(kind: String, location: String) -> SourceCredential? {
        environment.credentials?.credential(kind: kind, location: location)
    }
    /// Synchronously obtain an Entra access token for `resource`, to be sent only to `host`
    /// (`QueryEnvironment.accessToken(resource:host:)`). Must not be called on the main thread
    /// (evaluation always runs on the engine's worker thread). The token is never traced.
    public func accessToken(resource: String, host: String) throws -> String {
        guard let provider = environment.credentials else {
            throw MError.dataSource("Sign in with a Microsoft account to access '\(host)'; no credential provider is configured.")
        }
        let sem = DispatchSemaphore(value: 0)
        let box = TokenBox()
        Task.detached {
            do { box.result = .success(try await provider.accessToken(resource: resource, host: host)) } catch { box.result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        do { return try box.result.get() } catch {
            throw MError.dataSource("Couldn't sign in to '\(host)': \(MError.wrap(error).message)")
        }
    }
    private final class TokenBox: @unchecked Sendable {
        var result: Result<String, Error> = .failure(MError.dataSource("No access token was returned."))
    }
    public func addTrace(_ message: String) { lock.lock(); trace.append(message); lock.unlock() }

    // MARK: Evaluation

    /// Evaluate an expression. The result may still be `.lazy`; call `forced()` when a concrete value is needed.
    public func eval(_ e: MExpr, _ env: MEnv) throws -> MValue {
        switch e {
        case .literal(let v): return v
        case .identifier(let name, _): return try lookup(name, env)
        case .fieldAccess(let target, let name, let optional):
            let t = try target.map { try eval($0, env).forced() } ?? lookup("_", env)
            return try fieldAccess(t, name, optional: optional)
        case .invoke(let fe, let argExprs):
            let f = try eval(fe, env).forced()
            guard case .function(let fn) = f else { throw MError.typeMismatch(expected: "function", got: f) }
            var args: [MValue] = []
            args.reserveCapacity(argExprs.count)
            for a in argExprs { args.append(try eval(a, env).forced()) }
            return try call(fn, args)
        case .binary(let op, let l, let r):
            return try evalBinary(op, l, r, env)
        case .unary(let op, let x):
            let v = try eval(x, env).forced()
            return try MOps.unary(op, v)
        case .ifThenElse(let c, let a, let b):
            let cond = try eval(c, env).forced()
            guard case .logical(let flag) = cond else { throw MError.typeMismatch(expected: "logical", got: cond) }
            return try eval(flag ? a : b, env)
        case .each(let body):
            return .function(MFunction(parameters: [MParameter("_")], body: body, env: env, isEach: true))
        case .function(let params, let ret, let body):
            let ps = try params.map { MParameter($0.name, type: try $0.type.map { try evalType($0, env) }, optional: $0.isOptional) }
            return .function(MFunction(parameters: ps, returnType: try ret.map { try evalType($0, env) }, body: body, env: env))
        case .letIn(let bindings, let body):
            return try eval(body, letScope(bindings, parent: env))
        case .list(let items):
            var out: [MValue] = []
            out.reserveCapacity(items.count)
            for item in items {
                if case .range(let a, let b) = item {
                    let lo = try eval(a, env).forced(), hi = try eval(b, env).forced()
                    if case .text(let ta) = lo, case .text(let tb) = hi,
                       ta.unicodeScalars.count == 1, tb.unicodeScalars.count == 1,
                       let ua = ta.unicodeScalars.first?.value, let ub = tb.unicodeScalars.first?.value {
                        if ub >= ua { for code in ua...ub { if let sc = Unicode.Scalar(code) { out.append(.text(String(Character(sc)))) } } }
                        continue
                    }
                    guard case .number(let x) = lo, case .number(let y) = hi else {
                        throw MError("List ranges need number or single-character text bounds.")
                    }
                    if y >= x {
                        guard y - x < 50_000_000 else { throw MError("The list range is too large.") }
                        var k = x
                        while k <= y { out.append(.number(k)); k += 1 }
                    }
                } else {
                    out.append(MValue.capturing { try self.eval(item, env) })
                }
            }
            return .list(out)
        case .range: throw MError("A range is only valid inside a list.")
        case .record(let fields):
            let scope = MEnv(parent: env)
            var names: [String] = [], values: [MValue] = []
            names.reserveCapacity(fields.count); values.reserveCapacity(fields.count)
            for (name, expr) in fields {
                let v: MValue
                if case .literal(let lit) = expr { v = lit }
                else { v = .lazy(MThunk { try self.eval(expr, scope) }) }
                if names.contains(name) { throw MError("The field '\(name)' is defined more than once in the record.") }
                names.append(name); values.append(v)
                scope.define(name, v)
            }
            return .record(MRecord(names: names, values: values))
        case .itemAccess(let target, let index, let optional):
            let t = try eval(target, env).forced()
            let i = try eval(index, env).forced()
            return try itemAccess(t, i, optional: optional)
        case .projection(let target, let names, let optional):
            let t = try target.map { try eval($0, env).forced() } ?? lookup("_", env)
            return try projection(t, names, optional: optional)
        case .tryOtherwise(let body, let handler):
            do {
                let v = try eval(body, env).forced()
                if handler != nil { return v }
                return .record(MRecord(names: ["HasError", "Value"], values: [.logical(false), v]))
            } catch {
                if let h = handler { return try eval(h, env) }
                return .record(MRecord(names: ["HasError", "Error"], values: [.logical(true), .record(MError.wrap(error).record)]))
            }
        case .tryCatch(let body, let param, let handler):
            do { return try eval(body, env).forced() } catch {
                let scope = param.map { MEnv(parent: env, name: $0, value: .record(MError.wrap(error).record)) } ?? env
                return try eval(handler, scope)
            }
        case .raise(let x):
            throw MInterpreter.error(from: try eval(x, env).forced())
        case .asType(let x, let te):
            let v = try eval(x, env).forced()
            let t = try evalType(te, env)
            guard t.matches(v) else { throw MError.typeMismatch(expected: t.mText, got: v) }
            return v
        case .isType(let x, let te):
            let v = try eval(x, env).forced()
            return .logical(try evalType(te, env).matches(v))
        case .typeValue(let te): return .type(try evalType(te, env))
        case .meta(let x, let m):
            let v = try eval(x, env).forced()
            guard case .record(let mr) = try eval(m, env).forced() else { throw MError("Metadata must be a record.") }
            return MInterpreter.attach(meta: mr, to: v)
        case .notImplemented: throw MError("Value was not specified.", reason: "Expression.Error")
        case .section(let members):
            let scope = letScope(members, parent: env)
            return .record(MRecord(names: members.map(\.name), values: members.map { scope.lookup($0.name) ?? .null }))
        }
    }

    /// Build the scope for `let` bindings: each binding is a thunk evaluated on first use.
    /// `observe` (used by the query engine for step diagnostics) is called once per binding when it is first forced.
    public func letScope(_ bindings: [MBinding], parent: MEnv,
                         observe: ((_ name: String, _ seconds: Double, _ result: Result<MValue, Error>) -> Void)? = nil) -> MEnv {
        let scope = MEnv(parent: parent)
        for b in bindings {
            if case .literal(let lit) = b.expr, observe == nil { scope.define(b.name, lit); continue }
            let expr = b.expr, name = b.name
            scope.define(name, .lazy(MThunk {
                guard let observe else { return try self.eval(expr, scope) }
                let start = Date()
                do {
                    let v = try self.eval(expr, scope).forced()
                    observe(name, Date().timeIntervalSince(start), .success(v))
                    return v
                } catch {
                    observe(name, Date().timeIntervalSince(start), .failure(error))
                    throw error
                }
            }))
        }
        return scope
    }

    private func lookup(_ name: String, _ env: MEnv) throws -> MValue {
        if let v = env.lookup(name) { return try v.forced() }
        if let v = try sharedResolver?(name) { return try v.forced() }
        if let v = library.values[name] { return v }
        if name == "#shared" {
            var names = library.values.keys.sorted()
            var values = names.map { library.values[$0] ?? .null }
            for n in sharedNames() {
                names.append(n)
                values.append(.lazy(MThunk { try self.sharedResolver?(n) ?? .null }))
            }
            return .record(MRecord(names: names, values: values))
        }
        if name == "_" { throw MError("The implicit field access '[…]' or '_' can only be used inside 'each' or a function with a '_' parameter.") }
        throw MError("The name '\(name)' wasn't recognized. Make sure it's spelled correctly.", detail: .text(name))
    }

    private func evalBinary(_ op: MBinaryOp, _ l: MExpr, _ r: MExpr, _ env: MEnv) throws -> MValue {
        switch op {
        case .and:
            let a = try eval(l, env).forced()
            if case .logical(false) = a { return .logical(false) }
            let b = try eval(r, env).forced()
            return try MOps.and(a, b)
        case .or:
            let a = try eval(l, env).forced()
            if case .logical(true) = a { return .logical(true) }
            let b = try eval(r, env).forced()
            return try MOps.or(a, b)
        case .coalesce:
            let a = try eval(l, env).forced()
            return a.isNull ? try eval(r, env) : a
        default:
            return try MOps.binary(op, try eval(l, env).forced(), try eval(r, env).forced())
        }
    }

    // MARK: Access

    public func fieldAccess(_ target: MValue, _ name: String, optional: Bool) throws -> MValue {
        switch target {
        case .record(let r):
            if let i = r.fields.index[name] { return try r.value(at: i) }
            if optional { return .null }
            throw MError("The field '\(name)' of the record wasn't found.", detail: target)
        case .table(let t):
            if let i = t.columnIndex(name) { return .list(try t.columns[i]) }
            if optional { return .null }
            throw MError("The column '\(name)' of the table wasn't found.", detail: .text(name))
        case .null where optional: return .null
        default:
            throw MError("We cannot apply field access to the type \(target.typeName.capitalized).", detail: target.isStructured ? nil : target)
        }
    }

    public func itemAccess(_ target: MValue, _ index: MValue, optional: Bool) throws -> MValue {
        switch target {
        case .list(let l):
            guard case .number(let d) = index, d == d.rounded() else { throw MError.typeMismatch(expected: "number", got: index) }
            if d < 0 { throw MError("The index cannot be negative.") }
            if Int(d) >= l.count {
                if optional { return .null }
                throw MError("There weren't enough elements in the enumeration to complete the operation.")
            }
            return try l[Int(d)].forced()
        case .table(let t):
            if case .number(let d) = index, d == d.rounded() {
                if d < 0 { throw MError("The index cannot be negative.") }
                if !optional, t.isLazy, let limited = t.folded(.firstN(Int(d) + 1), self) {
                    // fetch only the rows needed from a folded source
                    let n = try limited.rowCount
                    if Int(d) >= n { throw MError("There weren't enough elements in the enumeration to complete the operation.") }
                    return .record(try limited.record(Int(d)))
                }
                if Int(d) >= (try t.rowCount) {
                    if optional { return .null }
                    throw MError("There weren't enough elements in the enumeration to complete the operation.")
                }
                return .record(try t.record(Int(d)))
            }
            if case .record(let key) = index {
                let cols = try t.columns
                var keyCols: [(Int, MValue)] = []
                for (i, n) in key.names.enumerated() { keyCols.append((try t.requireColumn(n), try key.value(at: i))) }
                var found: Int?
                for row in 0..<(try t.rowCount) {
                    var match = true
                    for (c, v) in keyCols where !MValue.equals(cols[c][row].forcedCell(), v) { match = false; break }
                    if match {
                        if found != nil { throw MError("The key matched more than one row in the table.", detail: index) }
                        found = row
                    }
                }
                if let f = found { return .record(try t.record(f)) }
                if optional { return .null }
                throw MError("The key didn't match any rows in the table.", detail: index)
            }
            throw MError.typeMismatch(expected: "number", got: index)
        case .null where optional: return .null
        default:
            throw MError("We cannot apply item access to the type \(target.typeName.capitalized).")
        }
    }

    public func projection(_ target: MValue, _ names: [String], optional: Bool) throws -> MValue {
        switch target {
        case .record(let r):
            var vals: [MValue] = []
            for n in names {
                if let i = r.fields.index[n] { vals.append(r.values[i]) }
                else if optional { vals.append(.null) }
                else { throw MError("The field '\(n)' of the record wasn't found.") }
            }
            return .record(MRecord(names: names, values: vals))
        case .table(let t):
            if let f = t.folded(.selectColumns(names), self), names.allSatisfy({ t.columnIndex($0) != nil }) { return .table(f) }
            let cols = try t.columns, count = try t.rowCount
            var outCols: [[MValue]] = [], types: [MType] = []
            for n in names {
                if let i = t.columnIndex(n) { outCols.append(cols[i]); types.append(t.columnTypes[i]) }
                else if optional { outCols.append([MValue](repeating: .null, count: count)); types.append(.any) }
                else { throw MError("The column '\(n)' of the table wasn't found.", detail: .text(n)) }
            }
            return .table(MTable(names: names, types: types, columns: outCols, rowCount: count))
        default:
            throw MError("We cannot apply field access to the type \(target.typeName.capitalized).")
        }
    }

    // MARK: Types, errors, metadata

    public func evalType(_ te: MTypeExpr, _ env: MEnv) throws -> MType {
        switch te {
        case .primitive(let t): return t
        case .nullable(let inner): return try evalType(inner, env).asNullable
        case .list(let item): return .list(try evalType(item, env))
        case .record(let fields, let open):
            return .record(try fields.map { MTypeField($0.name, try $0.type.map { try evalType($0, env) } ?? .any, optional: $0.optional) }, open: open)
        case .table(let row):
            let r = try evalType(row, env)
            guard case .record(let f, _) = r else { throw MError("A table type needs a record row type.") }
            return .table(f)
        case .function: return .function
        case .expr(let e):
            let v = try eval(e, env).forced()
            guard case .type(let t) = v else { throw MError.typeMismatch(expected: "type", got: v) }
            return t
        }
    }

    /// Build an `MError` from the operand of `error …` (text or an error record).
    public static func error(from v: MValue) -> MError {
        switch v {
        case .text(let s): return MError(s)
        case .record(let r):
            let reason = (try? r.get("Reason"))??.textValue ?? "Expression.Error"
            let message = (try? r.get("Message"))??.textValue ?? ""
            let detail = (try? r.get("Detail")) ?? nil
            return MError(message, reason: reason, detail: (detail?.isNull ?? true) ? nil : detail)
        default: return MError("An error was raised.", detail: v)
        }
    }

    /// Attach metadata (only tables, records and functions can carry it; other values pass through).
    public static func attach(meta: MRecord, to v: MValue) -> MValue {
        switch v {
        case .record(let r):
            let c = MRecord(fields: r.fields, values: r.values); c.meta = r.meta.map { $0.merging(meta) } ?? meta
            return .record(c)
        case .table(let t):
            guard let cols = try? t.columns, let n = try? t.rowCount else { return v }
            let c = MTable(names: t.columnNames, types: t.columnTypes, columns: cols, rowCount: n)
            c.meta = t.meta.map { $0.merging(meta) } ?? meta
            return .table(c)
        case .function(let f): f.meta = f.meta.map { $0.merging(meta) } ?? meta; return v
        default: return v
        }
    }
    public static func metadata(of v: MValue) -> MRecord {
        switch v {
        case .record(let r): return r.meta ?? .empty
        case .table(let t): return t.meta ?? .empty
        case .function(let f): return f.meta ?? .empty
        default: return .empty
        }
    }
}
