import CryptoKit
import Darwin
import Foundation
import PicardFormats
import PicardFoundation

public enum LibraryPaths {
    public static func relativePath(of file: URL, in directory: URL) -> String? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
        return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
    }
}

public struct LibraryImportResult: Sendable {
    public let file: AudioFile
    public let copied: Bool
}

/// Imports never move or retag the source. Only complete copies become visible.
public actor LibraryImporter {
    public static let defaultNamingScript = "$if2(%albumartist%,%artist%,Unknown Artist)/$if2(%album%,Unknown Album)/$if($gt(%totaldiscs%,1),$num(%discnumber%,1)-)$if(%tracknumber%,$num($if2(%tracknumber%,0),2) - )$if2(%title%,%filename%).%extension%"
    private let audio = AudioFileCoordinator()
    private let organizer = FileOrganizationCoordinator()

    public init() {}

    public func importFile(at source: URL, into directory: URL, existing: [AudioFile] = []) async throws -> LibraryImportResult {
        try Task.checkCancellation()
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let previous = existing.first { $0.url.resolvingSymlinksInPath().standardizedFileURL == source }
        if LibraryPaths.relativePath(of: source, in: root) != nil {
            // Importing the library itself must not duplicate or move its collection.
            if let previous, [.ready, .changed, .saved].contains(previous.state) {
                return LibraryImportResult(file: previous, copied: false)
            }
            return LibraryImportResult(file: try await audio.load(url: source, id: previous?.id ?? UUID()), copied: false)
        }
        let loaded = try await audio.load(url: source, id: previous?.id ?? UUID())
        var namingFile = loaded
        try namingFile.updateMetadata(Self.namingMetadata(loaded.metadata))
        let filename = Self.safeComponent(source.deletingPathExtension().lastPathComponent)
        try namingFile.updateURL(source.deletingLastPathComponent().appendingPathComponent(filename).appendingPathExtension(source.pathExtension))
        let plan = try await organizer.plan(files: [namingFile], destinationDirectory: root, namingScript: Self.defaultNamingScript)
        guard let destination = plan.operations.first?.destination else { throw SaveError.invalidName("No destination was produced.") }
        let storage = try LibraryImportStorage(root: root)
        let result = try storage.copy(loaded, to: destination)
        let known = existing.first { $0.url.resolvingSymlinksInPath().standardizedFileURL == result.url }
        if !result.copied, let known, [.ready, .changed, .saved].contains(known.state) {
            return LibraryImportResult(file: known, copied: false)
        }
        // A copy has a new filesystem identity. Re-read it so saves check the copy,
        // not the source's inode, and preserve pending edits on legacy linked items.
        var file = try await audio.load(url: result.url, id: known?.id ?? loaded.id)
        if let pending = known ?? previous, pending.isModified {
            try file.updateMetadata(pending.metadata)
            try file.updateArtwork(pending.artwork)
        }
        return LibraryImportResult(file: file, copied: result.copied)
    }

    static func namingMetadata(_ metadata: Metadata) -> Metadata {
        var result = metadata
        for key in ["albumartist", "artist", "album", "title"] {
            if let value = metadata.firstValue(for: key) {
                let safe = Self.safeComponent(value)
                if !safe.isEmpty { result.setValue(safe, for: key) }
                else { result.unset(key) }
            }
        }
        for (key, total) in [("tracknumber", "totaltracks"), ("discnumber", "totaldiscs")] {
            let parts = metadata.firstValue(for: key)?.split(separator: "/", omittingEmptySubsequences: false) ?? []
            if let first = parts.first, let number = Int(first), number > 0 {
                result.setValue(String(number), for: key)
            } else { result.unset(key) }
            if parts.count > 1, let count = Int(parts[1]), count > 0 { result.setValue(String(count), for: total) }
        }
        if result.firstValue(for: "discnumber") == nil { result.setValue("1", for: "discnumber") }
        let disc = Int(result.firstValue(for: "discnumber") ?? "") ?? 1
        let totalDiscs = max(Int(result.firstValue(for: "totaldiscs") ?? "") ?? 1, disc)
        result.setValue(String(totalDiscs), for: "totaldiscs")
        return result
    }

    static func safeComponent(_ value: String) -> String {
        var safe = String(String.UnicodeScalarView(value.unicodeScalars.map {
            $0.value < 0x20 || CharacterSet(charactersIn: "/\\:").contains($0) ? UnicodeScalar("_") : $0
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        if safe.hasPrefix(".") { safe = "_" + safe }
        // Leave room for track/disc prefixes, extensions and collision suffixes.
        // Bound UTF-8 bytes without splitting a composed character.
        var bounded = ""
        for character in safe {
            guard bounded.utf8.count + String(character).utf8.count <= 180 else { break }
            bounded.append(character)
        }
        return bounded.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Directory-relative descriptors prevent symlink escapes. RENAME_EXCL commits
/// without overwriting even when another importer wins the same name concurrently.
private final class LibraryImportStorage {
    private let root: URL
    private let descriptor: Int32

    init(root: URL) throws {
        self.root = root
        descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Self.failure(root.path, "open library folder") }
    }
    deinit { close(descriptor) }

    func copy(_ source: AudioFile, to destination: URL) throws -> (url: URL, copied: Bool) {
        let prefix = root.path + "/"
        guard destination.standardizedFileURL.path.hasPrefix(prefix) else {
            throw SaveError.invalidName("The destination is outside the library.")
        }
        let relative = String(destination.standardizedFileURL.path.dropFirst(prefix.count))
        let components = relative.split(separator: "/").map(String.init)
        guard let name = components.last, !name.isEmpty else { throw SaveError.invalidName("The destination name is empty.") }
        let parent = try parentDescriptor(components.dropLast())
        defer { close(parent) }
        let temporary = ".macpicard-import-\(UUID().uuidString)"
        let outputDescriptor = openat(descriptor, temporary, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard outputDescriptor >= 0 else { throw Self.failure(root.path, "create import staging file") }
        let output = FileHandle(fileDescriptor: outputDescriptor, closeOnDealloc: true)
        defer {
            try? output.close()
            // This exact, privately-created staging name is never a user file.
            unlinkat(descriptor, temporary, 0)
        }
        guard try AudioFileIdentity.capture(url: source.url).matches(source.identity) else {
            throw SaveError.externalModification(path: source.url.path)
        }
        let inputDescriptor = open(source.url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard inputDescriptor >= 0 else { throw Self.failure(source.url.path, "read import source") }
        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var attributes = stat()
        guard fstat(inputDescriptor, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG else {
            throw SaveError.sourceMissing(path: source.url.path)
        }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
            try output.write(contentsOf: data)
        }
        try Task.checkCancellation()
        guard try AudioFileIdentity.capture(url: source.url).matches(source.identity) else {
            throw SaveError.externalModification(path: source.url.path)
        }
        // The library's copy must be editable even if the source was read-only.
        guard fchmod(outputDescriptor, (attributes.st_mode & 0o777) | 0o600) == 0 else {
            throw Self.failure(root.path, "set imported file permissions")
        }
        var times = [
            timeval(tv_sec: attributes.st_atimespec.tv_sec, tv_usec: suseconds_t(attributes.st_atimespec.tv_nsec / 1_000)),
            timeval(tv_sec: attributes.st_mtimespec.tv_sec, tv_usec: suseconds_t(attributes.st_mtimespec.tv_nsec / 1_000))
        ]
        guard times.withUnsafeMutableBufferPointer({ futimes(outputDescriptor, $0.baseAddress) }) == 0 else {
            throw Self.failure(root.path, "preserve imported file timestamps")
        }
        try output.synchronize()
        let digest = Data(hash.finalize())
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        for suffix in 1...10_000 {
            try Task.checkCancellation()
            let candidate = suffix == 1 ? name : "\(base) (\(suffix)).\(ext)"
            if let existingHash = try hashExisting(candidate, in: parent, byteCount: source.identity?.byteCount),
               existingHash == digest {
                return (destination.deletingLastPathComponent().appendingPathComponent(candidate), false)
            }
            if renameatx_np(descriptor, temporary, parent, candidate, UInt32(RENAME_EXCL)) == 0 {
                return (destination.deletingLastPathComponent().appendingPathComponent(candidate), true)
            }
            if errno != EEXIST { throw Self.failure(destination.path, "commit imported file") }
            // A concurrent import may have committed the same bytes after our
            // first check. Recheck this name before choosing a suffixed duplicate.
            if let existingHash = try hashExisting(candidate, in: parent, byteCount: source.identity?.byteCount),
               existingHash == digest {
                return (destination.deletingLastPathComponent().appendingPathComponent(candidate), false)
            }
        }
        throw SaveError.collision(path: destination.path)
    }

    private func parentDescriptor(_ components: ArraySlice<String>) throws -> Int32 {
        var current = dup(descriptor)
        guard current >= 0 else { throw Self.failure(root.path, "open library directory") }
        do {
            for component in components {
                guard component != ".", component != ".." else { throw SaveError.invalidName("Path traversal is not allowed.") }
                if mkdirat(current, component, 0o755) != 0, errno != EEXIST {
                    throw Self.failure(component, "create album directory")
                }
                let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
                guard next >= 0 else { throw Self.failure(component, "open album directory without following symlinks") }
                close(current)
                current = next
            }
            return current
        } catch { close(current); throw error }
    }

    private func hashExisting(_ name: String, in parent: Int32, byteCount: Int64?) throws -> Data? {
        let fileDescriptor = openat(parent, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fileDescriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP { return nil }
            throw Self.failure(name, "check existing library file")
        }
        let file = FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else { throw Self.failure(name, "inspect existing library file") }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size == byteCount else { return nil }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return Data(hash.finalize())
    }

    private static func failure(_ path: String, _ operation: String) -> PicardError {
        PicardError.fileSystem(path: path, operation: operation, reason: String(cString: strerror(errno)))
    }
}
