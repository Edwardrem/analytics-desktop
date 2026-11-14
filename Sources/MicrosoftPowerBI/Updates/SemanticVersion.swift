import Foundation

/// A Semantic Versioning 2.0.0 version (`1.2.3`, `1.2.3-beta.2`, `1.2.3+build.7`), compared by the
/// spec's precedence rules: major, minor and patch numerically; a pre-release ranks below its release;
/// pre-release identifiers compare one by one, numbers numerically and below text, text in ASCII order,
/// and a longer list wins when all shared identifiers are equal. Build metadata is ignored.
struct SemanticVersion: Comparable, Hashable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]

    var isPrerelease: Bool { !prerelease.isEmpty }
    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major; self.minor = minor; self.patch = patch; self.prerelease = prerelease
    }

    /// Parses a version, or a release tag such as `v1.2.3`. Nil when it isn't a semantic version.
    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") {
            let build = s[s.index(after: plus)...]
            guard Self.validIdentifiers(build, numericRule: false) else { return nil }
            s = s[..<plus]
        }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let tail = s[s.index(after: dash)...]
            guard Self.validIdentifiers(tail, numericRule: true) else { return nil }
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            s = s[..<dash]
        }
        let core = s.split(separator: ".", omittingEmptySubsequences: false)
        guard core.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in core {
            guard Self.isNumeric(part), part == "0" || part.first != "0", let n = Int(part) else { return nil }
            numbers.append(n)
        }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    static func < (a: SemanticVersion, b: SemanticVersion) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (isNumeric(Substring(x)) ? Int(x) : nil, isNumeric(Substring(y)) ? Int(y) : nil) {
            case let (m?, n?): return m < n
            case (_?, nil): return true          // numeric identifiers rank below alphanumeric ones
            case (nil, _?): return false
            case (nil, nil): return x < y        // ASCII order
            }
        }
        return a.prerelease.count < b.prerelease.count
    }

    private static func isNumeric(_ s: Substring) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Dot-separated, non-empty `[0-9A-Za-z-]` identifiers; for pre-releases, numbers have no leading zero.
    private static func validIdentifiers(_ s: Substring, numericRule: Bool) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { p in
            guard !p.isEmpty, p.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
            return !numericRule || !isNumeric(p) || p == "0" || p.first != "0"
        }
    }
}
