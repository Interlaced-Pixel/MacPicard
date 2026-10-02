import Foundation

public struct SystemDiagnostics: Codable, Sendable, Equatable {
    public let applicationVersion: String
    public let operatingSystem: String
    public let architecture: String
    public let processorCount: Int
    public let activeProcessorCount: Int
    public let applicationSupportPath: String
    public let configurationPath: String

    public static func collect(paths: AppPaths) -> SystemDiagnostics {
        let processInfo = ProcessInfo.processInfo
        let applicationVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif

        return SystemDiagnostics(
            applicationVersion: applicationVersion,
            operatingSystem: processInfo.operatingSystemVersionString,
            architecture: architecture,
            processorCount: processInfo.processorCount,
            activeProcessorCount: processInfo.activeProcessorCount,
            applicationSupportPath: paths.applicationSupportDirectory.path,
            configurationPath: paths.configurationFile.path
        )
    }
}
