import Foundation

public struct AppPaths: Sendable, Equatable {
    public let applicationSupportDirectory: URL
    public let cacheDirectory: URL
    public let logsDirectory: URL
    public let configurationFile: URL
    public let bookmarksFile: URL
    public let sessionFile: URL
    public let recoverySessionFile: URL

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
        self.cacheDirectory = applicationSupportDirectory.appendingPathComponent("Cache", isDirectory: true)
        self.logsDirectory = applicationSupportDirectory.appendingPathComponent("Logs", isDirectory: true)
        self.configurationFile = applicationSupportDirectory.appendingPathComponent("configuration.json")
        self.bookmarksFile = applicationSupportDirectory.appendingPathComponent("security-scoped-bookmarks.json")
        self.sessionFile = applicationSupportDirectory.appendingPathComponent("session.json")
        self.recoverySessionFile = applicationSupportDirectory.appendingPathComponent("session-recovery.json")
    }

    public static func live(appName: String = "MacPicard") throws -> AppPaths {
        guard let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PicardError.fileSystem(
                path: "",
                operation: "locate application support directory",
                reason: "The user application support directory is unavailable."
            )
        }

        return AppPaths(applicationSupportDirectory: root.appendingPathComponent(appName, isDirectory: true))
    }

    public func prepare() throws {
        let directories = [applicationSupportDirectory, cacheDirectory, logsDirectory]

        for directory in directories {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                throw PicardError.fileSystem(
                    path: directory.path,
                    operation: "create directory",
                    reason: error.localizedDescription
                )
            }
        }
    }
}
