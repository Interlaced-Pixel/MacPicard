import CoreServices
import Foundation

/// Events are hints, not a replacement for filesystem enumeration. A dropped
/// stream, root change or unmount invalidates every incremental assumption.
public struct LibraryChangeHint: Sendable {
    public let paths: Set<URL>
    public let requiresFullScan: Bool

    public init(paths: Set<URL>, requiresFullScan: Bool = false) {
        self.paths = paths
        self.requiresFullScan = requiresFullScan
    }
}

private final class LibraryEventSink: Sendable {
    let receive: @Sendable (LibraryChangeHint) -> Void
    init(_ receive: @escaping @Sendable (LibraryChangeHint) -> Void) { self.receive = receive }
}

/// Owns exactly one recursive FSEvents stream. The callback only sends immutable
/// hints; all debouncing, scheduling and workspace checks happen in the caller.
public final class LibraryDirectoryMonitor: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "com.interlacedpixel.MacPicard.library-events", qos: .utility)

    public init(directory: URL, receive: @escaping @Sendable (LibraryChangeHint) -> Void) throws {
        let sink = Unmanaged.passRetained(LibraryEventSink(receive))
        var context = FSEventStreamContext(
            version: 0, info: sink.toOpaque(), retain: nil,
            release: { pointer in
                if let pointer { Unmanaged<LibraryEventSink>.fromOpaque(pointer).release() }
            }, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard
            let created = FSEventStreamCreate(
                nil,
                { _, info, count, paths, flags, _ in
                    guard let info else { return }
                    let sink = Unmanaged<LibraryEventSink>.fromOpaque(info).takeUnretainedValue()
                    let strings = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as! [String]
                    let invalidating = FSEventStreamEventFlags(
                        kFSEventStreamEventFlagMustScanSubDirs
                            | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
                            | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount
                            | kFSEventStreamEventFlagMount | kFSEventStreamEventFlagEventIdsWrapped)
                    let full = (0..<count).contains { flags[$0] & invalidating != 0 }
                    // Bound storage during huge copy bursts; fall back to one full pass.
                    sink.receive(
                        LibraryChangeHint(
                            paths: Set(strings.prefix(512).map { URL(fileURLWithPath: $0) }),
                            requiresFullScan: full || count > 512))
                }, &context, [directory.resolvingSymlinksInPath().standardizedFileURL.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1, flags)
        else {
            sink.release()
            throw SaveError.session("Folder notifications could not be started. Periodic checks are still available.")
        }
        stream = created
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw SaveError.session("Folder notifications could not be started. Periodic checks are still available.")
        }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
