import Foundation
import PicardFoundation

public struct LibraryTrashResult: Sendable {
    public let trashedFileIDs: Set<UUID>
    public let failures: [String]
    public let trashLocations: [UUID: URL]
}

/// Linked originals outside the library are never deleted. All disk removal
/// goes through the volume's recoverable Trash; permanent deletion is unsupported.
public actor LibraryTrashCoordinator {
    public init() {}

    public func trash(_ files: [AudioFile], in directory: URL, confirmed: Bool) throws -> LibraryTrashResult {
        guard confirmed else { throw SaveError.session("Moving library files to Trash requires confirmation.") }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SaveError.session("Reconnect the library folder before moving files to Trash.")
        }
        var trashed = Set<UUID>()
        var failures: [String] = []
        var locations: [UUID: URL] = [:]
        for file in files {
            do {
                guard LibraryPaths.relativePath(of: file.url, in: directory) != nil else {
                    throw SaveError.session("Linked files outside the library are never trashed.")
                }
                let values = try file.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw SaveError.sourceMissing(path: file.url.path)
                }
                guard try AudioFileIdentity.capture(url: file.url).matches(file.identity) else {
                    throw SaveError.externalModification(path: file.url.path)
                }
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: file.url, resultingItemURL: &trashedURL)
                if let trashedURL { locations[file.id] = trashedURL as URL }
                trashed.insert(file.id)
            } catch { failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
        }
        return LibraryTrashResult(trashedFileIDs: trashed, failures: failures, trashLocations: locations)
    }
}
