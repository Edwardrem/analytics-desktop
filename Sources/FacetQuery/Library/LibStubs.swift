import Foundation

// Placeholder registrars so the target builds while library areas are being written.
// Each area author deletes their line here when the real implementation is added.
extension MLibrary {
    static func registerTable(_ lib: MLibrary) {}
    static func registerList(_ lib: MLibrary) {}
    static func registerText(_ lib: MLibrary) {}
    static func registerNumber(_ lib: MLibrary) {}
    static func registerDateTime(_ lib: MLibrary) {}
    static func registerFiles(_ lib: MLibrary) {}
    static func registerSQL(_ lib: MLibrary) {}
    static func registerWeb(_ lib: MLibrary) {}
    static func registerScripts(_ lib: MLibrary) {}
    static func registerAI(_ lib: MLibrary) {}
}
