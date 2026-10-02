import Foundation

public final class ScopedURLAccess: @unchecked Sendable {
    public let url: URL

    private let lock = NSLock()
    private var isAccessing = true

    fileprivate init(url: URL) {
        self.url = url
    }

    public func stopAccessing() {
        lock.lock()
        defer { lock.unlock() }

        guard isAccessing else {
            return
        }

        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit {
        stopAccessing()
    }
}

public actor SecurityScopedBookmarkStore {
    private let fileURL: URL
    private var bookmarks: [String: Data] = [:]
    private var hasLoaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func save(url: URL, for key: String, readOnly: Bool = true) throws {
        try loadIfNeeded()

        var options: URL.BookmarkCreationOptions = [.withSecurityScope]
        if readOnly {
            options.insert(.securityScopeAllowOnlyReadAccess)
        }

        do {
            bookmarks[key] = try url.bookmarkData(
                options: options,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            try persist()
        } catch {
            throw PicardError.securityScopedBookmark(operation: "save", key: key)
        }
    }

    public func resolve(key: String) throws -> ScopedURLAccess {
        try loadIfNeeded()

        guard let bookmarkData = bookmarks[key] else {
            throw PicardError.securityScopedBookmark(operation: "resolve missing bookmark", key: key)
        }

        var isStale = false
        let resolvedURL: URL

        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw PicardError.securityScopedBookmark(operation: "resolve", key: key)
        }

        guard resolvedURL.startAccessingSecurityScopedResource() else {
            throw PicardError.securityScopedBookmark(operation: "start access", key: key)
        }

        if isStale {
            do {
                bookmarks[key] = try resolvedURL.bookmarkData(
                    options: [.withSecurityScope],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                try persist()
            } catch {
                resolvedURL.stopAccessingSecurityScopedResource()
                throw PicardError.securityScopedBookmark(operation: "refresh stale bookmark", key: key)
            }
        }

        return ScopedURLAccess(url: resolvedURL)
    }

    public func remove(key: String) throws {
        try loadIfNeeded()
        bookmarks.removeValue(forKey: key)
        try persist()
    }

    private func loadIfNeeded() throws {
        guard !hasLoaded else {
            return
        }

        hasLoaded = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            bookmarks = try JSONDecoder().decode([String: Data].self, from: data)
        } catch {
            throw PicardError.securityScopedBookmark(operation: "load", key: fileURL.path)
        }
    }

    private func persist() throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(bookmarks)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw PicardError.securityScopedBookmark(operation: "persist", key: fileURL.path)
        }
    }
}
