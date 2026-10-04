import Darwin
import Foundation
import PicardFoundation

public enum ArtworkExportCollisionPolicy: String, Sendable, CaseIterable { case stop, uniqueNames }

public struct ArtworkExportPlan: Sendable {
    public struct Item: Sendable, Identifiable {
        public let id: UUID
        public let filename: String
        public let data: Data
    }
    public let directory: URL
    public let items: [Item]
    fileprivate let device: dev_t
    fileprivate let inode: ino_t
}

/// Frozen, explicitly reviewed destinations. Exclusive openat creation prevents races and symlink traversal.
public enum ArtworkExporter {
    public static func review(_ images: [Artwork], directory: URL, policy: ArtworkExportCollisionPolicy) throws -> ArtworkExportPlan {
        try ArtworkValidation.validateCollectionSize(images)
        guard !images.isEmpty, images.count <= ArtworkValidation.maximumImages, directory.isFileURL else {
            throw ArtworkValidation.Failure("Choose 1–64 images and an existing export folder.")
        }
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("The export folder cannot be opened") }
        defer { close(fd) }
        var status = stat()
        guard fstat(fd, &status) == 0 else { throw failure("The export folder cannot be inspected") }
        var occupied = Set(try FileManager.default.contentsOfDirectory(atPath: root.path).map { $0.lowercased() })
        var items: [ArtworkExportPlan.Item] = []
        for (index, image) in images.enumerated() {
            guard let data = image.data else { throw ArtworkValidation.Failure("An export image has no data.") }
            let info = try ArtworkProcessor.inspect(data)
            guard ["image/png", "image/jpeg"].contains(info.mimeType) else {
                throw ArtworkValidation.Failure("Convert artwork to PNG or JPEG before export.")
            }
            let ext = info.mimeType == "image/png" ? "png" : "jpg"
            let stem = "\(image.type.rawValue)-\(String(format: "%02d", index + 1))"
            var filename = "\(stem).\(ext)"
            var suffix = 2
            while occupied.contains(filename.lowercased()) {
                guard policy == .uniqueNames else { throw ArtworkValidation.Failure("\(filename) already exists. Choose unique names or another folder.") }
                filename = "\(stem)-\(suffix).\(ext)"; suffix += 1
            }
            occupied.insert(filename.lowercased())
            items.append(.init(id: image.id, filename: filename, data: data))
        }
        return ArtworkExportPlan(directory: root, items: items, device: status.st_dev, inode: status.st_ino)
    }

    public static func execute(_ plan: ArtworkExportPlan) throws -> [URL] {
        try Task.checkCancellation()
        let fd = open(plan.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw failure("The reviewed folder is unavailable") }
        defer { close(fd) }
        var root = stat()
        guard fstat(fd, &root) == 0, root.st_dev == plan.device, root.st_ino == plan.inode else {
            throw ArtworkValidation.Failure("The export folder changed. Review the destinations again.")
        }
        var created: [(String, ino_t)] = []
        do {
            // Recheck case-insensitive collisions on case-sensitive volumes as well.
            let names = Set(try FileManager.default.contentsOfDirectory(atPath: plan.directory.path).map { $0.lowercased() })
            guard !plan.items.contains(where: { names.contains($0.filename.lowercased()) }) else {
                throw ArtworkValidation.Failure("A reviewed export destination now exists. Review again; nothing was overwritten.")
            }
            for item in plan.items {
                try Task.checkCancellation()
                try verifyLocation(plan)
                let output = openat(fd, item.filename, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
                guard output >= 0 else { throw failure("Could not exclusively create \(item.filename)") }
                defer { close(output) }
                var info = stat()
                guard fstat(output, &info) == 0 else { throw failure("Cannot inspect the new export") }
                created.append((item.filename, info.st_ino))
                try item.data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        try Task.checkCancellation()
                        let count = Darwin.write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw failure("Could not write \(item.filename)") }
                        offset += count
                    }
                }
                guard fsync(output) == 0 else { throw failure("Could not flush \(item.filename)") }
            }
            try verifyLocation(plan)
            return plan.items.map { plan.directory.appendingPathComponent($0.filename) }
        } catch {
            // Only remove our own created inodes, never a concurrently replaced user file.
            for (name, inode) in created {
                var info = stat()
                if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_ino == inode { _ = unlinkat(fd, name, 0) }
            }
            throw error
        }
    }

    private static func verifyLocation(_ plan: ArtworkExportPlan) throws {
        var status = stat()
        guard lstat(plan.directory.path, &status) == 0, status.st_dev == plan.device, status.st_ino == plan.inode else {
            throw ArtworkValidation.Failure("The reviewed folder was renamed or replaced. Export stopped without overwriting existing files.")
        }
    }

    private static func failure(_ message: String) -> ArtworkValidation.Failure {
        ArtworkValidation.Failure("\(message): \(String(cString: strerror(errno))).")
    }
}
