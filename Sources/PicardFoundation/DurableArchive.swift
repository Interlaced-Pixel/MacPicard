import Darwin
import Foundation

/// Atomic replacement plus durability barriers for archive files and their
/// directory entries. Callers stop before touching audio if a barrier fails.
public enum DurableArchive {
    public static func replace(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
        try synchronizeDirectory(url.deletingLastPathComponent().deletingLastPathComponent())
    }
    public static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
