import AppKit
import Foundation
import PicardFoundation
import PicardFormats
import PicardScripts
import PicardSessions
import SwiftUI
import XCTest
@testable import MacPicard

final class WorkflowModelTests: XCTestCase {
    @MainActor func testWholeCollectionScriptsAreOrderedPerFileAndOneStagedUndo() async throws {
        let first = try file("  First  ", number: "1"), second = try file("Second", number: "2")
        let model = AppModel(); model.files = [first, second]; model.selectedFileIDs = [first.id]; model.searchQuery = "First"
        defer { model.sessionSaveTask?.cancel(); model.searchTask?.cancel() }
        let scripts = [ManagedScript(name: "Trim", source: "$set(title,$trim(%title%))"), ManagedScript(name: "Upper", source: "$set(title,$upper(%title%))"), ManagedScript(name: "Disabled", enabled: false, source: "$set(tracknumber,99)"), ManagedScript(name: "Naming", kind: .naming, source: "%title%.%extension%")]
        let review = try await model.previewWorkflow(scope: .workspace, scripts: scripts)
        XCTAssertEqual(model.files, [first, second]); XCTAssertEqual(review.rows.count, 2)
        XCTAssertEqual(review.rows.map { $0.proposed?.firstValue(for: "title") }, ["FIRST", "SECOND"])
        XCTAssertEqual(review.rows.map { $0.proposed?.firstValue(for: "tracknumber") }, ["1", "2"])
        try model.applyWorkflowReview(review, excluded: [], confirmed: true)
        model.undoMetadataEdit(); XCTAssertEqual(model.files, [first, second])
        model.redoMetadataEdit(); XCTAssertEqual(model.files[1].metadata.firstValue(for: "title"), "SECOND")
        XCTAssertEqual(model.files.map(\.url), [first.url, second.url])
    }
    @MainActor func testFilenameReviewBlocksAmbiguityAndPreservesExcludedOrStaleFiles() async throws {
        let first = try file("Original", number: "1", filename: "Artist - Song.mp3")
        let second = try file("Keep", number: "2", filename: "Artist - Song - Remix.mp3")
        let model = AppModel(); model.files = [first, second]
        defer { model.sessionSaveTask?.cancel() }
        let review = try await model.previewWorkflow(scope: .workspace, scripts: [], pattern: "{artist} - {title}", mappings: [FilenameFieldMapping(token: "artist", tag: "artist"), FilenameFieldMapping(token: "title", tag: "title")])
        XCTAssertEqual(review.blockedCount, 1); XCTAssertEqual(model.files, [first, second])
        XCTAssertThrowsError(try model.applyWorkflowReview(review, excluded: [], confirmed: false))
        try model.applyWorkflowReview(review, excluded: [first.id], confirmed: true)
        XCTAssertEqual(model.files, [first, second])
        try model.applyWorkflowReview(review, excluded: [], confirmed: true)
        XCTAssertEqual(model.files[0].metadata.firstValue(for: "title"), "Song"); XCTAssertEqual(model.files[1], second)
        XCTAssertThrowsError(try model.applyWorkflowReview(review, excluded: [], confirmed: true))
        model.activeWorkspaceID = UUID(); XCTAssertThrowsError(try model.applyWorkflowReview(review, excluded: [], confirmed: true))
    }
    @MainActor func testCancelledWorkflowAndUnknownFunctionNeverPartiallyStage() async throws {
        let first = try file("Original", number: "1"), model = AppModel(); model.files = [first]
        let scripts = [ManagedScript(name: "Broken", source: "$unknown(%title%)")]
        let review = try await model.previewWorkflow(scope: .workspace, scripts: scripts)
        XCTAssertEqual(review.blockedCount, 1); XCTAssertTrue(review.rows[0].error?.contains("1:") == true)
        XCTAssertEqual(model.files, [first])
        let job = Task { try await model.previewWorkflow(scope: .workspace, scripts: scripts) }; job.cancel()
        do { _ = try await job.value; XCTFail("Cancelled job returned a usable preview") } catch is CancellationError {} catch { XCTFail("Unexpected: \(error)") }
        XCTAssertEqual(model.files, [first]); XCTAssertFalse(model.isWorking)
    }
    @MainActor func testGuidedOrganizationRejectsFailedOrStillPendingFilesAndExplicitScopeSurvivesSelection() async throws {
        let first = try file("Saved", number: "1"), second = try file("Failed", number: "2"), third = try file("Pending", number: "3")
        let model = AppModel(); model.files = [first, second, third]
        var edited = third; var tags = edited.metadata; tags.setValue("New", for: "title"); try edited.updateMetadata(tags); model.files[2] = edited
        let outcomes = [FileSaveOutcome(fileID: first.id, filename: "1", saved: true, message: "Saved"), FileSaveOutcome(fileID: second.id, filename: "2", saved: false, message: "Failed"), FileSaveOutcome(fileID: third.id, filename: "3", saved: true, message: "Saved")]
        XCTAssertEqual(model.savedOrganizationIDs(from: outcomes), [first.id])
        model.requestOrganizationReview(ids: [first.id], label: "Guided save results")
        model.beginOrganizationReview(); XCTAssertEqual(model.organizationFiles.map(\.id), [first.id])
        XCTAssertEqual(model.organizationRequestedIDs, [first.id])
        model.cancelOrganizationReview(); XCTAssertNil(model.organizationRequestedIDs)
    }
    @MainActor func testEntireLibraryOrganizationIncludesUnavailableReviewRows() async throws {
        let first = try file("Ready", number: "1")
        var missing = try file("Missing", number: "2"); missing.markRemoved()
        let model = AppModel(); model.files = [first, missing]
        let workspace = MusicWorkspace(name: "Fixture Library", kind: .library, directory: URL(fileURLWithPath: "/tmp"))
        model.workspaces = [workspace]; model.activeWorkspaceID = workspace.id; model.selectedFileIDs = [first.id]
        XCTAssertTrue(model.canPerform(.organize, scope: .library))
        model.beginOrganizationReview(entireLibrary: true)
        XCTAssertEqual(model.organizationFiles.map(\.id), [first.id, missing.id])
    }
    @MainActor func testCollectionToolsNativeRendering() async throws {
        let model = AppModel(); model.files = [try file("Track", number: "1")]
        let presentation = AppPresentation()
        model.workflowDocument.scripts = [ManagedScript(name: "Trim titles", source: "$set(title,$trim(%title%))")]
        model.workflowDocument.profiles = [WorkflowProfile(name: "Collection preset", configuration: model.configuration)]
        for page in ["operations", "scripts", "filenames", "profiles"] {
        for dark in [false, true] {
        presentation.collectionToolsPage = page
        let view = NSHostingView(rootView: CollectionToolsView(model: model, presentation: presentation).tint(MusicBrainzTheme.purple).preferredColorScheme(dark ? .dark : .light))
        let size = NSSize(width: 1100, height: 780)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; view.frame = NSRect(origin: .zero, size: size)
        try await Task.sleep(for: .milliseconds(200)); view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds)); view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:])); XCTAssertGreaterThan(png.count, 5000)
        if let path = ProcessInfo.processInfo.environment["MACPICARD_WORKFLOW_RENDER_OUTPUT"] { try png.write(to: URL(fileURLWithPath: "\(path)-\(page)-\(dark ? "dark" : "light").png"), options: .atomic) }
        window.contentView = nil
        }
        }
    }
    @MainActor func testActualPartialSaveKeepsFailurePendingAndCancelledSaveWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Workflow-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let path = ProcessInfo.processInfo.environment["MACPICARD_WORKFLOW_AUDIO"] else { throw XCTSkip("Set MACPICARD_WORKFLOW_AUDIO to an isolated valid FLAC fixture") }
        let fixture = URL(fileURLWithPath: path)
        let firstURL = root.appendingPathComponent("first.flac"), secondURL = root.appendingPathComponent("second.flac")
        try FileManager.default.copyItem(at: fixture, to: firstURL); try FileManager.default.copyItem(at: fixture, to: secondURL)
        var first = try await AudioFileCoordinator().load(url: firstURL), second = try await AudioFileCoordinator().load(url: secondURL)
        var tags = first.metadata; tags.setValue("Saved title", for: "title"); try first.updateMetadata(tags)
        tags = second.metadata; tags.setValue("Failed title", for: "title"); try second.updateMetadata(tags)
        try FileManager.default.removeItem(at: secondURL)
        let model = AppModel(); model.files = [first, second]; model.saveCoordinator = AudioSaveCoordinator()
        await model.saveFiles(model.files)
        XCTAssertEqual(model.lastSaveOutcomes.map(\.saved), [true, false]); XCTAssertFalse(model.files[0].isModified); XCTAssertTrue(model.files[1].isModified)
        XCTAssertEqual(model.savedOrganizationIDs(from: model.lastSaveOutcomes), [first.id])
        let written = try Data(contentsOf: firstURL)
        var pending = model.files[0]; tags = pending.metadata; tags.setValue("Cancelled", for: "title"); try pending.updateMetadata(tags); model.files[0] = pending
        let job = Task { await model.saveFiles([pending]) }; job.cancel(); await job.value
        XCTAssertEqual(try Data(contentsOf: firstURL), written); XCTAssertTrue(model.files[0].isModified); XCTAssertTrue(model.lastSaveOutcomes.isEmpty)
    }
    private func file(_ title: String, number: String, filename: String? = nil) throws -> AudioFile {
        var value = AudioFile(url: URL(fileURLWithPath: "/tmp/Workflow-\(UUID())/\(filename ?? "\(number) - \(title).mp3")"))
        try value.beginLoading(); try value.finishLoading(metadata: Metadata(fields: ["title": [title], "album": ["Album"], "artist": ["Artist"], "tracknumber": [number]]), artwork: ArtworkCollection(), identity: AudioFileIdentity(resourceIdentifier: nil, byteCount: 1, modificationDate: Date(timeIntervalSince1970: 1), prefixHash: "fixture"))
        return value
    }
}
