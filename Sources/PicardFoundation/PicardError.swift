import Foundation

public enum PicardError: Error, LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String)
    case unsupportedConfigurationVersion(Int)
    case configurationEncoding(String)
    case configurationRead(path: String, reason: String)
    case configurationWrite(path: String, reason: String)
    case migrationFailed(from: Int, to: Int, reason: String)
    case keychain(operation: String, status: Int32)
    case securityScopedBookmark(operation: String, key: String)
    case fileSystem(path: String, operation: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message):
            return "Invalid configuration: \(message)"
        case let .unsupportedConfigurationVersion(version):
            return "Configuration schema version \(version) is newer than this application supports."
        case let .configurationEncoding(message):
            return "Configuration encoding failed: \(message)"
        case let .configurationRead(path, reason):
            return "Could not read configuration at \(path): \(reason)"
        case let .configurationWrite(path, reason):
            return "Could not write configuration at \(path): \(reason)"
        case let .migrationFailed(from, to, reason):
            return "Could not migrate configuration from schema \(from) to \(to): \(reason)"
        case let .keychain(operation, status):
            return "Keychain operation \(operation) failed with status \(status)."
        case let .securityScopedBookmark(operation, key):
            return "Security-scoped bookmark operation \(operation) failed for \(key)."
        case let .fileSystem(path, operation, reason):
            return "Filesystem operation \(operation) failed for \(path): \(reason)"
        }
    }
}
