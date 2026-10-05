import Foundation
import PicardFoundation
import PicardScripts

enum CollectionScope: String, CaseIterable, Identifiable {
    case selection = "Selection", album = "Album", workspace = "Entire Library"
    var id: String { rawValue }
}
struct FileSaveOutcome: Identifiable, Sendable {
    let fileID: UUID
    let filename: String
    let saved: Bool
    let message: String
    var id: UUID { fileID }
}
struct WorkflowReview: Identifiable, Sendable {
    struct Row: Identifiable, Sendable {
        let file: AudioFile
        let proposed: Metadata?
        let output: String
        let error: String?
        var id: UUID { file.id }
        var changes: [MetadataChange] { proposed?.difference(from: file.metadata).changes ?? [] }
    }
    let id: UUID
    let workspaceID: UUID?
    let scope: String
    let rows: [Row]
    var changedCount: Int { rows.count { !$0.changes.isEmpty } }
    var blockedCount: Int { rows.count { $0.error != nil } }
}

extension AppModel {
    func reloadWorkflows() async {
        guard !isBusy, let workflowStore else { return }
        isWorking = true; defer { isWorking = false }
        do { workflowDocument = try await workflowStore.load(); workflowError = nil }
        catch { workflowError = "Workflow library could not be loaded: \(error.localizedDescription). Existing data was not replaced." }
    }

    func collectionFiles(_ scope: CollectionScope) -> [AudioFile] {
        switch scope {
        case .selection: return selectedFiles
        case .workspace: return files
        case .album:
            guard let group = albumGroups.first(where: { $0.id == selectedAlbumID }) ?? primarySelectedFile.flatMap({ album(containing: $0.id) }) else { return [] }
            let ids = Set(group.fileIDs); return files.filter { ids.contains($0.id) }
        }
    }

    func persistWorkflows(_ value: WorkflowDocument) async throws {
        guard !isBusy, workflowError == nil, let workflowStore else { throw WorkflowFailure.invalid("Wait for loading/operations to finish. Resolve a workflow-load error before replacing its data.") }
        isWorking = true; defer { isWorking = false }
        try await workflowStore.save(value)
        workflowDocument = value
    }

    func activateProfile(_ profile: WorkflowProfile) async throws {
        try await savePreferences(profile.applying(to: configuration))
        statusMessage = "Activated profile \(profile.name). Only its included preferences changed."
    }

    func previewWorkflow(scope: CollectionScope, scripts: [ManagedScript], pattern: String? = nil, mappings: [FilenameFieldMapping] = []) async throws -> WorkflowReview {
        guard !isBusy else { throw WorkflowFailure.invalid("Wait for the current operation.") }
        let targets = collectionFiles(scope), workspace = activeWorkspaceID
        guard !targets.isEmpty else { throw WorkflowFailure.invalid("No files in this scope.") }
        isWorking = true; defer { isWorking = false }
        let worker = Task.detached(priority: .userInitiated) {
            let parser = try pattern.map { try FilenameTagParser(pattern: $0) }
            let evaluator = ScriptEvaluator()
            let enabled = scripts.filter { $0.enabled && $0.kind == .tagging }
            let programs = try enabled.map { (script: $0, program: try evaluator.compile($0.source)) }
            if parser == nil && enabled.isEmpty { throw WorkflowFailure.invalid("Enable at least one tagging script, or choose a naming script for path preview.") }
            let now = Date()
            let rows = try targets.map { file -> WorkflowReview.Row in
                try Task.checkCancellation()
                guard [.ready, .changed, .saved].contains(file.state) else { return .init(file: file, proposed: nil, output: "", error: "File is \(file.state.rawValue); it will be skipped.") }
                do {
                    var metadata = file.metadata, output: [String] = []
                    if let parser { metadata = try parser.metadata(for: file.url, original: metadata, mappings: mappings) }
                    else {
                        var variables: [String: [String]] = ["filename": [file.url.deletingPathExtension().lastPathComponent], "extension": [file.url.pathExtension]]
                        for item in programs {
                            let result = try evaluator.evaluate(item.program, context: ScriptContext(metadata: metadata, variables: variables, now: now))
                            metadata = result.metadata; variables = result.variables
                            if !result.output.isEmpty { output.append("\(item.script.name): \(result.output)") }
                        }
                    }
                    return .init(file: file, proposed: metadata, output: output.joined(separator: "\n"), error: nil)
                } catch { return .init(file: file, proposed: nil, output: "", error: error.localizedDescription) }
            }
            return WorkflowReview(id: UUID(), workspaceID: workspace, scope: scope.rawValue, rows: rows)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); return result
    }

    func applyWorkflowReview(_ review: WorkflowReview, excluded: Set<UUID>, confirmed: Bool) throws {
        guard confirmed, !isBusy, review.workspaceID == activeWorkspaceID else { throw WorkflowFailure.invalid("Confirm the reviewed batch in the current library.") }
        let current = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        guard review.rows.allSatisfy({ current[$0.id] == $0.file }) else { throw WorkflowFailure.invalid("Files changed after preview. Preview again; nothing was applied.") }
        var edited = files
        let indices = Dictionary(uniqueKeysWithValues: edited.enumerated().map { ($0.element.id, $0.offset) })
        for row in review.rows where !excluded.contains(row.id) && row.error == nil {
            if let metadata = row.proposed, let index = indices[row.id] { try edited[index].updateMetadata(metadata) }
        }
        commitStagedEdits(edited, action: "Apply reviewed workflow")
    }

    /// The guided move stage has an explicit eligible set, never a failed or still-pending file.
    func savedOrganizationIDs(from outcomes: [FileSaveOutcome]) -> Set<UUID> {
        Set(outcomes.filter { $0.saved }.compactMap { outcome in
            guard let file = file(id: outcome.fileID), !file.isModified, [.ready, .saved].contains(file.state) else { return nil }
            return file.id
        })
    }
}
