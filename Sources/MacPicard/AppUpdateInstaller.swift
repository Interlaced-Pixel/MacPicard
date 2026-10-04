import Foundation
import PicardFoundation

enum AppUpdateInstaller {
    static func install(
        archiveURL: URL,
        expectedVersion: AppVersion,
        progress: @escaping @Sendable (AppUpdateProgress) -> Void
    ) throws -> URL {
        let fileManager = FileManager.default
        let root = archiveURL.deletingLastPathComponent().appendingPathComponent("staged", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try runDitto(arguments: ["-x", "-k", archiveURL.path, root.path])
        guard let extractedApp = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])
            .first(where: { $0.pathExtension == "app" }) else {
            throw AppUpdateError.invalidRelease("the archive does not contain an application bundle")
        }
        let info = Bundle(url: extractedApp)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw AppUpdateError.invalidRelease("the application identifier does not match MacPicard")
        }
        guard let versionString = info?["CFBundleShortVersionString"] as? String,
              let bundleVersion = try? AppVersion(versionString), bundleVersion == expectedVersion else {
            throw AppUpdateError.invalidRelease("the bundle version does not match the release metadata")
        }

        let stagedApp = root.appendingPathComponent("MacPicard.app", isDirectory: true)
        let total = try byteCount(of: extractedApp)
        var completed: Int64 = 0
        try copyTree(from: extractedApp, to: stagedApp) { bytes in
            completed += bytes
            progress(AppUpdateProgress(phase: .staging, completedBytes: completed, totalBytes: total))
        }
        progress(AppUpdateProgress(phase: .installing, completedBytes: total, totalBytes: total))

        let currentApp = Bundle.main.bundleURL.standardizedFileURL
        let backupName = ".MacPicard-backup-\(UUID().uuidString).app"
        _ = try fileManager.replaceItemAt(currentApp, withItemAt: stagedApp, backupItemName: backupName, options: .usingNewMetadataOnly)
        try? fileManager.removeItem(at: currentApp.deletingLastPathComponent().appendingPathComponent(backupName))
        return currentApp
    }

    private static func runDitto(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "archive extraction failed"
            throw AppUpdateError.invalidRelease(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func byteCount(of root: URL) throws -> Int64 {
        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]) else { return 0 }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw AppUpdateError.invalidRelease("the archive contains a symbolic link") }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        return total
    }

    private static func copyTree(from source: URL, to destination: URL, onBytes: (Int64) throws -> Void) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard let enumerator = fileManager.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else { return }
        for case let item as URL in enumerator {
            let relative = item.path.replacingOccurrences(of: source.path + "/", with: "")
            let target = destination.appendingPathComponent(relative)
            let values = try item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { throw AppUpdateError.invalidRelease("the archive contains a symbolic link") }
            if values.isDirectory == true {
                try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
            } else if values.isRegularFile == true {
                try copyFile(from: item, to: target, onBytes: onBytes)
            }
        }
    }

    private static func copyFile(from source: URL, to destination: URL, onBytes: (Int64) throws -> Void) throws {
        let fileManager = FileManager.default
        fileManager.createFile(atPath: destination.path, contents: nil)
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? input.close(); try? output.close() }
        while true {
            let data = try input.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            try output.write(contentsOf: data)
            try onBytes(Int64(data.count))
        }
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        if let permissions = attributes[.posixPermissions] {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: destination.path)
        }
    }
}
