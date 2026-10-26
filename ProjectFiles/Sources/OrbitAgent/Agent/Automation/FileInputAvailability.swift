import Darwin
import Foundation

/// Metadata-only preflight. Neither this probe nor its callers request a cloud
/// download. Unknown/unsupported provider metadata preserves normal POSIX errors.
enum FileInputAvailability {
    typealias DownloadStatusReader = (URL) throws -> URLUbiquitousItemDownloadingStatus?

    static func downloadStatus(_ url: URL) throws -> URLUbiquitousItemDownloadingStatus? {
        // Use a fresh URL so earlier inspection cannot supply cached cloud state.
        let fresh = URL(fileURLWithPath: url.path)
        return try fresh.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]).ubiquitousItemDownloadingStatus
    }

    static func requireLocal(flags: UInt32, downloadStatus: URLUbiquitousItemDownloadingStatus? = nil) throws {
        // SF_DATALESS also covers non-iCloud File Providers on APFS. It is a
        // read-only flag; tests inject metadata instead of changing real providers.
        if flags & UInt32(SF_DATALESS) != 0 || downloadStatus == .notDownloaded {
            throw TaskToolError.fileContentsNotLocal
        }
    }
}
