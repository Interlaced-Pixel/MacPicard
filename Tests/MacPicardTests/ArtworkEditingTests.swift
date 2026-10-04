import Foundation
import AppKit
import PicardCoverArt
import PicardFormats
import PicardFoundation
import XCTest
import SwiftUI
@testable import MacPicard

final class ArtworkEditingTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    @MainActor func testArtworkManagerNativeRendering() async throws {
        let model = AppModel()
        var first = try file("First"), second = try file("Second")
        if let path = ProcessInfo.processInfo.environment["MACPICARD_ARTWORK_RENDER_IMAGE"] {
            let front = try ArtworkProcessor.importFile(URL(fileURLWithPath: path))
            var back = front; back = Artwork(type: .back, mimeType: front.mimeType, description: "Back", width: front.width, height: front.height, source: front.source, data: front.data)
            try first.updateArtwork(ArtworkCollection(images: [front, back]))
            try second.updateArtwork(ArtworkCollection(images: [front]))
        }
        model.files = [first, second]; model.selectedFileIDs = [first.id, second.id]
        defer { model.sessionSaveTask?.cancel() }
        let view = NSHostingView(rootView: ArtworkManagerView(model: model))
        let size = NSSize(width: 1020, height: 760)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; view.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(350))
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(data.count, 5000)
        if let path = ProcessInfo.processInfo.environment["MACPICARD_ARTWORK_RENDER_OUTPUT"] { try data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        window.contentView = nil
    }

    @MainActor func testBatchApplyIsOneUndoAndPreservesTagsAndLocations() throws {
        let first = try file("First"), second = try file("Second")
        let model = AppModel(); model.files = [first, second]; model.selectedFileIDs = [first.id, second.id]
        defer { model.sessionSaveTask?.cancel() }
        var draft = ArtworkDraft(workspaceID: nil, files: model.files)
        let back = Artwork(type: .back, mimeType: "image/png", width: 1, height: 1, source: .generated, data: png)
        draft.imagesByFile[first.id] = [back, first.artwork.images[0]]
        try model.applyArtworkDraft(draft, replaceAllWith: first.id)
        XCTAssertEqual(model.files.map { $0.artwork.images.map(\.type) }, [[.back, .front], [.back, .front]])
        XCTAssertEqual(model.files.map(\.metadata), [first.metadata, second.metadata])
        XCTAssertEqual(model.files.map(\.url), [first.url, second.url])
        model.undoMetadataEdit(); XCTAssertEqual(model.files, [first, second])
        model.redoMetadataEdit(); XCTAssertEqual(model.files[1].artwork.images.count, 2)
    }

    func testDraftImportReplacementIdentityRestoreAndFailureAreAtomic() throws {
        let file = try file("Original")
        var draft = ArtworkDraft(workspaceID: nil, files: [file])
        let originalID = try XCTUnwrap(file.artwork.images.first?.id)
        let replacement = Artwork(type: .back, mimeType: "image/jpeg", source: .generated, data: png)
        let selected = try draft.importImages([replacement], fileID: file.id, mode: .selected, selectedID: originalID)
        XCTAssertEqual(selected, originalID)
        XCTAssertEqual(draft.imagesByFile[file.id]?.first?.type, .back)
        XCTAssertEqual(draft.imagesByFile[file.id]?.first?.mimeType, "image/png")
        XCTAssertEqual(draft.imagesByFile[file.id]?.first?.width, 1)
        draft.restore(imageID: originalID, fileID: file.id)
        XCTAssertEqual(draft.imagesByFile[file.id], file.originalArtwork.images)
        _ = try draft.importImages([replacement], fileID: file.id, mode: .append, selectedID: nil)
        XCTAssertEqual(draft.imagesByFile[file.id]?.count, 2)
        let before = draft.imagesByFile
        XCTAssertThrowsError(try draft.importImages([Artwork(mimeType: "image/png", source: .generated, data: Data("invalid".utf8))], fileID: file.id, mode: .all, selectedID: nil))
        XCTAssertEqual(draft.imagesByFile, before)
        XCTAssertThrowsError(try draft.importImages(Array(repeating: replacement, count: 64), fileID: file.id, mode: .append, selectedID: nil))
        XCTAssertEqual(draft.imagesByFile, before)
        _ = try draft.importImages([replacement], fileID: file.id, mode: .all, selectedID: nil)
        XCTAssertEqual(draft.imagesByFile[file.id]?.count, 1)
    }

    @MainActor func testCancelRestoreAndPersistenceKeepOriginalBaseline() throws {
        let original = try file("Original")
        let model = AppModel(); model.files = [original]
        defer { model.sessionSaveTask?.cancel() }
        var draft = ArtworkDraft(workspaceID: nil, files: [original])
        draft.imagesByFile[original.id] = []
        XCTAssertEqual(model.files[0], original, "Editing/cancelling the sheet draft must not touch the model")
        draft.restore(imageID: original.artwork.images[0].id, fileID: original.id)
        XCTAssertEqual(draft.imagesByFile[original.id], original.originalArtwork.images)
        draft.imagesByFile[original.id] = [Artwork(type: .other, mimeType: "image/png", source: .generated, data: png)]
        try model.applyArtworkDraft(draft)
        let encoded = try JSONEncoder().encode(model.files[0].sessionRecord())
        let record = try JSONDecoder().decode(AudioFileSessionRecord.self, from: encoded)
        let restored = AudioFile.restore(from: record)
        XCTAssertEqual(restored.artwork, model.files[0].artwork)
        XCTAssertEqual(restored.originalArtwork, original.artwork)
        var discarded = restored; try discarded.discardChanges(); XCTAssertEqual(discarded.artwork, original.artwork)
    }

    @MainActor func testBackgroundValidationApplyAndCancelledJobDoNotPartiallyStage() async throws {
        let original = try file("Original")
        let model = AppModel(); model.files = [original]
        defer { model.sessionSaveTask?.cancel() }
        var draft = ArtworkDraft(workspaceID: nil, files: [original])
        draft.imagesByFile[original.id] = []
        let frozen = draft
        let job = Task { try await model.applyArtworkDraftInBackground(frozen) }
        job.cancel()
        do { try await job.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(model.files, [original]); XCTAssertFalse(model.isWorking)
        try await model.applyArtworkDraftInBackground(draft)
        XCTAssertTrue(model.files[0].artwork.isEmpty); XCTAssertFalse(model.isWorking)
        model.undoMetadataEdit(); XCTAssertEqual(model.files, [original])
    }

    @MainActor func testStaleDraftAndMixedContainerBatchFailWithoutPartialEdits() throws {
        let first = try file("First"), second = try file("Second", ext: "m4a")
        let model = AppModel(); model.files = [first, second]
        defer { model.sessionSaveTask?.cancel() }
        var draft = ArtworkDraft(workspaceID: nil, files: model.files)
        draft.imagesByFile[first.id] = [Artwork(type: .back, mimeType: "image/png", source: .generated, data: png)]
        XCTAssertThrowsError(try model.applyArtworkDraft(draft, replaceAllWith: first.id))
        XCTAssertEqual(model.files, [first, second])
        var changed = first; var tags = changed.metadata; tags.setValue("Changed", for: "title"); try changed.updateMetadata(tags)
        model.files[0] = changed
        XCTAssertThrowsError(try model.applyArtworkDraft(draft))
        XCTAssertEqual(model.files[0], changed)
        model.activeWorkspaceID = UUID()
        XCTAssertThrowsError(try model.applyArtworkDraft(draft))
    }

    private func file(_ title: String, ext: String = "flac") throws -> AudioFile {
        var file = AudioFile(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).\(ext)"))
        try file.beginLoading()
        try file.finishLoading(metadata: Metadata(fields: ["title": [title]]), artwork: ArtworkCollection(images: [Artwork(mimeType: "image/png", width: 1, height: 1, source: .generated, data: png)]), identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: Date(timeIntervalSince1970: 1), prefixHash: "test"))
        return file
    }
}
