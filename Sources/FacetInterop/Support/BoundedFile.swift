import Foundation

/// Reads files from projects and packages with a size limit, so a damaged or hostile project cannot exhaust memory.
public enum BoundedFile {
    /// Largest JSON / TMDL / theme text file read.
    public static let textLimit = 64 * 1024 * 1024
    /// Largest cached table read from a project's data cache.
    public static let dataLimit = 1024 * 1024 * 1024
    /// Most files read from one project folder.
    public static let maxProjectFiles = 20_000

    /// The file's bytes. Throws when it is not a regular file or holds more than `limit` bytes.
    public static func read(_ url: URL, limit: Int = textLimit) throws -> Data {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else {
            throw InteropError.io("“\(url.lastPathComponent)” is not a file that can be read.")
        }
        if let size = values?.fileSize, size > limit { throw tooLarge(url, limit) }
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) }
        catch { throw InteropError.io("Couldn't read “\(url.lastPathComponent)”: \(error.localizedDescription)") }
        defer { try? handle.close() }
        // Read one byte past the limit so a file that grew after the size check is still refused.
        let data = (try handle.read(upToCount: limit + 1)) ?? Data()
        guard data.count <= limit else { throw tooLarge(url, limit) }
        return data
    }

    /// The file's bytes, or nil when it is missing, unreadable or too large.
    public static func readIfPresent(_ url: URL, limit: Int = textLimit) -> Data? { try? read(url, limit: limit) }

    private static func tooLarge(_ url: URL, _ limit: Int) -> InteropError {
        .invalidFormat("“\(url.lastPathComponent)” is larger than \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)) and was not read.")
    }

    /// Whether a file name taken from a document (a theme or image resource) stays inside its folder.
    public static func isSafeResourceName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != "..", name.count <= 255 else { return false }
        return !name.unicodeScalars.contains { $0 == "/" || $0 == "\\" || $0 == "\0" }
    }
}
