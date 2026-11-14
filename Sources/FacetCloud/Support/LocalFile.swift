import Foundation

/// Local files sent to a service: only regular files (a link is followed to its target), read with a size limit,
/// so a device, pipe or folder is refused instead of blocking or being read without end.
enum LocalFile {
    /// The size of the regular file at `url`.
    static func size(of url: URL, service: String) throws -> Int64 {
        let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, let size = values?.fileSize else {
            throw CloudAPIError(service: service, kind: .badRequest, statusCode: 0, message: "“\(url.lastPathComponent)” is not a file that can be uploaded.")
        }
        return Int64(size)
    }

    /// The whole regular file at `url` (memory-mapped, so a large one isn't copied); refuses one larger than `limit`
    /// bytes, even if it grew after it was checked.
    static func read(_ url: URL, limit: Int64, service: String) throws -> Data {
        guard try size(of: url, service: service) <= limit else { throw tooLarge(url, service) }
        let data = try Data(contentsOf: url.resolvingSymlinksInPath(), options: .mappedIfSafe)
        guard data.count <= limit else { throw tooLarge(url, service) }
        return data
    }

    private static func tooLarge(_ url: URL, _ service: String) -> CloudAPIError {
        CloudAPIError(service: service, kind: .badRequest, statusCode: 0, message: "“\(url.lastPathComponent)” grew while it was being uploaded; try again.")
    }
}
