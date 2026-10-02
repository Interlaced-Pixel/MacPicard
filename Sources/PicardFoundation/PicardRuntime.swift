import Foundation

public struct RuntimeSnapshot: Sendable, Equatable {
    public let paths: AppPaths
    public let configuration: AppConfiguration
    public let diagnostics: SystemDiagnostics

    public init(paths: AppPaths, configuration: AppConfiguration, diagnostics: SystemDiagnostics) {
        self.paths = paths
        self.configuration = configuration
        self.diagnostics = diagnostics
    }
}

public actor PicardRuntime {
    public let paths: AppPaths
    public let configurationStore: ConfigurationStore
    public let sessionStore: SessionStore
    public let keychain: KeychainStore
    public let bookmarks: SecurityScopedBookmarkStore

    private var hasStarted = false

    public init(paths: AppPaths) {
        self.paths = paths
        self.configurationStore = ConfigurationStore(fileURL: paths.configurationFile)
        self.sessionStore = SessionStore(
            sessionURL: paths.sessionFile,
            recoveryURL: paths.recoverySessionFile
        )
        self.keychain = KeychainStore()
        self.bookmarks = SecurityScopedBookmarkStore(fileURL: paths.bookmarksFile)
    }

    public static func live() throws -> PicardRuntime {
        try PicardRuntime(paths: AppPaths.live())
    }

    public func start() async throws -> RuntimeSnapshot {
        if hasStarted {
            let configuration = try await configurationStore.load()
            return makeSnapshot(configuration: configuration)
        }

        try paths.prepare()
        let configuration = try await configurationStore.load()
        hasStarted = true

        PicardLogger.info("MacPicard foundation started")
        PicardLogger.diagnostics.debug("Configuration path: \(self.paths.configurationFile.path, privacy: .public)")

        return makeSnapshot(configuration: configuration)
    }

    private func makeSnapshot(configuration: AppConfiguration) -> RuntimeSnapshot {
        RuntimeSnapshot(
            paths: paths,
            configuration: configuration,
            diagnostics: SystemDiagnostics.collect(paths: paths)
        )
    }
}
