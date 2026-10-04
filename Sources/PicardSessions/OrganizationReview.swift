import Foundation
import PicardFoundation

public enum OrganizationConflictPolicy: String, CaseIterable, Sendable, Hashable {
    case stop = "Stop on conflicts"
    case skip = "Skip conflicting files"
    case numbered = "Add numbered suffixes"
}

public enum OrganizationRowStatus: String, Sendable {
    case move = "Ready to move"
    case unchanged = "Already organized"
    case skipped = "Skipped conflict"
    case excluded = "Excluded"
    case blocked = "Needs attention"
}

public struct OrganizationReviewRow: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let source: URL
    public var destination: URL?
    public var status: OrganizationRowStatus
    public var message: String
    public let identity: AudioFileIdentity?
}

/// Immutable filesystem snapshot: preview is read-only and execution uses these exact paths.
public struct OrganizationReview: Sendable, Equatable {
    public let id: UUID
    public let files: [AudioFile]
    public let directory: URL
    public let resolvedDirectory: URL
    public let directoryIdentifier: String?
    public let namingScript: String
    public let policy: OrganizationConflictPolicy
    public let excludedIDs: Set<UUID>
    public let rows: [OrganizationReviewRow]
    public var moveCount: Int { rows.count { $0.status == .move } }
    public var blockedCount: Int { rows.count { $0.status == .blocked } }
    public var canExecute: Bool { moveCount > 0 && blockedCount == 0 }
    public var plan: FileMovePlan {
        FileMovePlan(operations: rows.compactMap { row in
            guard row.status == .move, let destination = row.destination else { return nil }
            return FileMoveOperation(fileID: row.id, source: row.source, destination: destination, expectedIdentity: row.identity)
        })
    }
}

public struct OrganizationResult: Sendable {
    public let files: [AudioFile]
    public let report: FileMoveReport
    public let warnings: [String]
}

extension FileOrganizationCoordinator {
    public func preview(files: [AudioFile], directory: URL, namingScript: String,
                        policy: OrganizationConflictPolicy = .stop, excludedIDs: Set<UUID> = []) throws -> OrganizationReview {
        guard Set(files.map(\.id)).count == files.count,
              Set(files.map { Self.pathKey($0.url) }).count == files.count else {
            throw SaveError.invalidName("Select each source file only once.")
        }
        guard try directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SaveError.invalidName("Choose an existing destination folder.")
        }
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let rootIdentifier = try Self.directoryIdentifier(root)
        var rows: [OrganizationReviewRow] = []
        for file in files {
            try Task.checkCancellation()
            if excludedIDs.contains(file.id) {
                rows.append(.init(id: file.id, source: file.url, destination: nil, status: .excluded,
                                  message: "This file will stay where it is.", identity: nil))
                continue
            }
            var destination: URL?
            var identity: AudioFileIdentity?
            do {
                guard [.ready, .changed, .saved].contains(file.state) else {
                    throw SaveError.invalidName("This file is not available for organization.")
                }
                guard try file.url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw SaveError.invalidName("Symbolic-link sources must be imported as regular files first.")
                }
                let captured = try AudioFileIdentity.capture(url: file.url)
                if let expected = file.identity, !expected.matches(captured) {
                    throw SaveError.externalModification(path: file.url.path)
                }
                identity = captured
                var namingFile = file
                try namingFile.updateMetadata(LibraryImporter.namingMetadata(file.metadata))
                let filename = LibraryImporter.safeComponent(file.url.deletingPathExtension().lastPathComponent)
                try namingFile.updateURL(file.url.deletingLastPathComponent().appendingPathComponent(filename).appendingPathExtension(file.url.pathExtension))
                destination = try plan(files: [namingFile], destinationDirectory: root, namingScript: namingScript).operations.first?.destination
                guard let destination else { throw SaveError.invalidName("The naming script produced no path.") }
                guard destination.pathExtension.caseInsensitiveCompare(file.url.pathExtension) == .orderedSame else {
                    throw SaveError.invalidName("The pattern changes the audio extension. Organize does not convert audio; use %extension% in the filename.")
                }
                try Self.validateDestination(destination, root: root)
                let unchanged = file.url.standardizedFileURL == destination.standardizedFileURL
                rows.append(.init(id: file.id, source: file.url, destination: destination,
                                  status: unchanged ? .unchanged : .move,
                                  message: unchanged ? "No rename or move is needed." : "", identity: identity))
            } catch is CancellationError { throw CancellationError() }
            catch {
                rows.append(.init(id: file.id, source: file.url, destination: destination, status: .blocked,
                                  message: error.localizedDescription, identity: identity))
            }
        }
        let counts = Dictionary(rows.compactMap { $0.destination.map { (Self.pathKey($0), 1) } }, uniquingKeysWith: +)
        // Conservatively treat case/Unicode-equivalent targets as the same path, even on case-sensitive volumes.
        var reserved = Set(rows.filter { $0.status == .unchanged }.compactMap { $0.destination.map(Self.pathKey) })
        for index in rows.indices where rows[index].status == .move {
            guard let destination = rows[index].destination else { continue }
            let key = Self.pathKey(destination)
            let existing = Self.itemExists(destination)
            let duplicate = counts[key, default: 0] > 1 || reserved.contains(key)
            if existing || duplicate {
                switch policy {
                case .stop, .skip:
                    rows[index].status = policy == .stop ? .blocked : .skipped
                    rows[index].message = existing ? "An item already occupies this destination. It will not be overwritten."
                        : "Multiple selected files resolve to the same destination."
                case .numbered:
                    do {
                        var candidate = destination
                        var suffix = 2
                        while Self.itemExists(candidate) || reserved.contains(Self.pathKey(candidate)) {
                            guard suffix <= 10_000 else { throw SaveError.invalidName("Too many numbered filename collisions.") }
                            candidate = destination.deletingLastPathComponent()
                                .appendingPathComponent(destination.deletingPathExtension().lastPathComponent + " (\(suffix))")
                                .appendingPathExtension(destination.pathExtension)
                            suffix += 1
                        }
                        try Self.validateDestination(candidate, root: root)
                        rows[index].destination = candidate
                        rows[index].message = "A safe filename was chosen; existing files stay untouched."
                    } catch {
                        rows[index].status = .blocked
                        rows[index].message = error.localizedDescription
                    }
                }
            }
            if rows[index].status == .move, let destination = rows[index].destination { reserved.insert(Self.pathKey(destination)) }
        }
        return OrganizationReview(id: UUID(), files: files, directory: directory, resolvedDirectory: root, directoryIdentifier: rootIdentifier,
                                  namingScript: namingScript, policy: policy, excludedIDs: excludedIDs, rows: rows)
    }

    public func executeReview(_ review: OrganizationReview) throws -> OrganizationResult {
        guard review.canExecute else { throw SaveError.invalidName("Resolve conflicts and preview at least one move first.") }
        guard review.directory.resolvingSymlinksInPath().standardizedFileURL == review.resolvedDirectory,
              try Self.directoryIdentifier(review.directory) == review.directoryIdentifier,
              try review.directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw SaveError.invalidName("The destination folder changed. Update the preview.")
        }
        // Complete preflight before the first move, including destination changes since preview.
        for operation in review.plan.operations {
            try Task.checkCancellation()
            try Self.validateDestination(operation.destination, root: review.resolvedDirectory)
            guard !Self.itemExists(operation.destination) else { throw SaveError.collision(path: operation.destination.path) }
            guard let expected = operation.expectedIdentity,
                  expected.matches(try AudioFileIdentity.capture(url: operation.source)),
                  try operation.source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                throw SaveError.externalModification(path: operation.source.path)
            }
        }
        // Never overwrite. A late collision aborts and invokes the coordinator's rollback.
        let report = try execute(review.plan, collisionPolicy: .fail)
        var warnings: [String] = []
        let updated = try review.files.map { file in
            guard let destination = report.destinations[file.id] else { return file }
            var relocated = file
            let identity: AudioFileIdentity?
            do { identity = try AudioFileIdentity.capture(url: destination) }
            catch { identity = nil; warnings.append("\(destination.lastPathComponent) moved, but its identity could not be read. Refresh before saving tags.") }
            try relocated.updateURL(destination, identity: identity)
            return relocated
        }
        return OrganizationResult(files: updated, report: report, warnings: warnings)
    }

    private static func pathKey(_ url: URL) -> String {
        url.standardizedFileURL.path.precomposedStringWithCanonicalMapping.lowercased()
    }
    private static func itemExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
    private static func directoryIdentifier(_ url: URL) throws -> String? {
        (try url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject)?.description
    }
    private static func validateDestination(_ url: URL, root: URL) throws {
        guard LibraryPaths.relativePath(of: url, in: root) != nil else {
            throw SaveError.invalidName("The path escapes the chosen folder through a symbolic link.")
        }
        let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
        guard relative.split(separator: "/").allSatisfy({ $0.utf8.count <= 255 }) else {
            throw SaveError.invalidName("A folder or filename exceeds the filesystem's length limit.")
        }
        var parent = url.deletingLastPathComponent()
        while parent.path.count > root.path.count {
            if Self.itemExists(parent), (try? parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
                throw SaveError.invalidName("A file occupies a required destination folder: \(parent.path)")
            }
            parent.deleteLastPathComponent()
        }
    }
}
