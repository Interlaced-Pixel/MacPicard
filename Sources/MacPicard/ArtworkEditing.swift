import Foundation
import PicardCoverArt
import PicardFormats
import PicardFoundation

enum ArtworkImportMode: String { case append, selected, all }

/// A sheet-local draft. Cancel and network failure never mutate the workspace.
struct ArtworkDraft: Sendable {
    let workspaceID: UUID?
    let baselines: [AudioFile]
    var imagesByFile: [UUID: [Artwork]]

    init(workspaceID: UUID?, files: [AudioFile]) {
        self.workspaceID = workspaceID
        baselines = files
        imagesByFile = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.artwork.images) })
    }

    /// Replacement retains the selected image's identity so original comparison/restore still work.
    mutating func importImages(_ imported: [Artwork], fileID: UUID, mode: ArtworkImportMode, selectedID: UUID?) throws -> UUID? {
        guard !imported.isEmpty, var current = imagesByFile[fileID] else { throw ArtworkValidation.Failure("Choose images and a preview file.") }
        try ArtworkValidation.validateCollectionSize(imported)
        var incoming = try imported.map { image in
            try Task.checkCancellation()
            guard let data = image.data else { throw ArtworkValidation.Failure("An imported image has no data.") }
            let info = try ArtworkValidation.inspect(data)
            var validated = image; validated.mimeType = info.mimeType; validated.width = info.width; validated.height = info.height
            return validated
        }
        switch mode {
        case .all: current = incoming
        case .selected:
            guard let index = current.firstIndex(where: { $0.id == selectedID }) else { throw ArtworkValidation.Failure("Select an image to replace, or choose Append.") }
            let first = incoming[0]
            incoming[0] = Artwork(id: current[index].id, type: first.type, mimeType: first.mimeType, description: first.description,
                                  width: first.width, height: first.height, source: first.source, data: first.data)
            current.replaceSubrange(index...index, with: incoming)
        case .append: current.append(contentsOf: incoming)
        }
        try ArtworkValidation.validateCollectionSize(current)
        imagesByFile[fileID] = current
        return incoming.first?.id
    }

    mutating func restore(imageID: UUID, fileID: UUID) {
        guard let baseline = baselines.first(where: { $0.id == fileID }),
              let originalIndex = baseline.originalArtwork.images.firstIndex(where: { $0.id == imageID }) else { return }
        let original = baseline.originalArtwork.images[originalIndex]
        var images = imagesByFile[fileID] ?? []
        if let index = images.firstIndex(where: { $0.id == imageID }) { images[index] = original }
        else { images.insert(original, at: min(originalIndex, images.count)) }
        imagesByFile[fileID] = images
    }

    func editedFiles(current: [AudioFile], workspaceID: UUID?, replaceAllWith fileID: UUID? = nil, validateImageData: Bool = true) throws -> [AudioFile] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        guard self.workspaceID == workspaceID,
              baselines.allSatisfy({ baseline in currentByID[baseline.id] == baseline }) else {
            throw ArtworkValidation.Failure("The library or files changed. Reopen Manage Artwork before applying edits.")
        }
        var result = current
        let indices = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) })
        var validated: [AudioFormat: [ArtworkCollection]] = [:]
        for baseline in baselines {
            try Task.checkCancellation()
            guard let index = indices[baseline.id] else { continue }
            let images = imagesByFile[fileID ?? baseline.id] ?? []
            var collection = ArtworkCollection(images: images)
            if collection == baseline.artwork { continue }
            if let format = FormatRegistry.format(forExtension: baseline.url.pathExtension) {
                if !(validated[format] ?? []).contains(collection) {
                    try format.validateArtwork(collection, validateImageData: validateImageData)
                    validated[format, default: []].append(collection)
                }
                collection = format.artworkForStorage(collection)
            }
            else { throw ArtworkValidation.Failure("An artwork target has an unsupported audio format.") }
            try result[index].updateArtwork(collection)
        }
        return result
    }
}

extension AppModel {
    var artworkClient: CoverArtClient? { coverArtClient }

    func applyArtworkDraft(_ draft: ArtworkDraft, replaceAllWith fileID: UUID? = nil) throws {
        guard !isBusy else { throw ArtworkValidation.Failure("Wait for the current operation before applying artwork.") }
        let edited = try draft.editedFiles(current: files, workspaceID: activeWorkspaceID, replaceAllWith: fileID)
        commitStagedEdits(edited, action: "Edit artwork")
    }

    func applyArtworkDraftInBackground(_ draft: ArtworkDraft, replaceAllWith fileID: UUID? = nil) async throws {
        try Task.checkCancellation()
        guard !isBusy else { throw ArtworkValidation.Failure("Wait for the current operation before applying artwork.") }
        let current = files, workspaceID = activeWorkspaceID
        isWorking = true
        defer { isWorking = false }
        let worker = Task.detached(priority: .utility) { try draft.editedFiles(current: current, workspaceID: workspaceID, replaceAllWith: fileID) }
        let edited = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation()
        guard files == current, activeWorkspaceID == workspaceID else { throw ArtworkValidation.Failure("The library changed during validation. Reopen Manage Artwork.") }
        commitStagedEdits(edited, action: "Edit artwork")
    }
}
