import AppKit
import PicardFoundation

struct MetadataRow: Identifiable {
    let key: String
    let original: String
    let current: String
    let changed: Bool
    var id: String { key }
}

struct TagClipboard: Codable {
    struct Value: Codable { let values: [String]; let deleted: Bool }
    let tags: [String: Value]
}

extension AppModel {
    static let readOnlyTags: Set<String> = ["~length", "~format", "~bitrate", "~filesize", "~filename", "~sample_rate", "~channels"]

    var metadataRows: [MetadataRow] {
        let cache = browserDerivedCache
        if cache.metadataRevision == fileRevision, cache.metadataIDs == selectedFileIDs { return cache.metadataRows }
        let selection = selectedFiles
        var keys = Set<String>()
        for file in selection {
            keys.formUnion(file.metadata.rawFields().keys)
            keys.formUnion(file.originalMetadata.rawFields().keys)
            keys.formUnion(file.metadata.deletedTagKeys)
        }
        let rows = keys.sorted().map { key in
            MetadataRow(key: key, original: tagSummary(key, files: selection, original: true), current: tagSummary(key, files: selection, original: false),
                changed: selection.contains { $0.metadata.rawFields()[key] != $0.originalMetadata.rawFields()[key]
                    || $0.metadata.deletedTagKeys.contains(key) != $0.originalMetadata.deletedTagKeys.contains(key) })
        }
        cache.metadataRows = rows; cache.metadataRevision = fileRevision; cache.metadataIDs = selectedFileIDs
        return rows
    }

    private func tagSummary(_ key: String, files: [AudioFile], original: Bool) -> String {
        guard let first = files.first else { return "Absent" }
        let tags = original ? first.originalMetadata : first.metadata
        let values = tags.rawFields()[key], deleted = tags.deletedTagKeys.contains(key)
        for file in files.dropFirst() {
            let other = original ? file.originalMetadata : file.metadata
            if other.rawFields()[key] != values || other.deletedTagKeys.contains(key) != deleted { return "Multiple values" }
        }
        if deleted { return "Deleted" }
        guard let values else { return "Absent" }
        return values.map { $0.isEmpty ? "Empty value" : $0 }.joined(separator: "; ")
    }

    func setTagValues(_ values: [String], for rawKey: String) {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, !key.contains(where: { $0.isNewline || $0 == "\0" }), !key.hasPrefix("~"), !Self.readOnlyTags.contains(key) else {
            statusMessage = "Choose a writable tag name."; return
        }
        mutateSelectedTags(action: "Edit \(key)") { $0.setValues(values, for: key) }
    }

    func deleteTag(_ key: String) {
        deleteTags([key])
    }

    func deleteTags(_ keys: Set<String>) {
        let writable = keys.filter { !$0.hasPrefix("~") }
        guard !writable.isEmpty else { return }
        mutateSelectedTags(action: "Remove tags") { tags in
            for key in writable { tags.delete(key) }
        }
    }

    func restoreTag(_ key: String, merging: Bool = false) {
        restoreTags([key], merging: merging)
    }

    func restoreTags(_ keys: Set<String>, merging: Bool = false) {
        guard canEditSelection else { return }
        let ids = selectedFileIDs
        var edited = files
        do {
            for index in ids.compactMap({ position(of: $0) }) {
                var tags = edited[index].metadata
                let original = edited[index].originalMetadata
                for key in keys where !key.hasPrefix("~") {
                    if merging {
                        for value in original.values(for: key) { tags.appendUniqueValue(value, for: key) }
                    } else if original.isDeleted(key) { tags.delete(key) }
                    else if original.contains(key) { tags.setValues(original.values(for: key), for: key) }
                    else { tags.unset(key) }
                }
                try edited[index].updateMetadata(tags)
            }
            commitStagedEdits(edited, action: merging ? "Merge original tags" : "Restore tags", changedIDs: ids)
        } catch { present(error) }
    }

    private func mutateSelectedTags(action: String, _ mutation: (inout Metadata) -> Void) {
        guard canEditSelection else { return }
        let ids = selectedFileIDs
        var edited = files
        do {
            for index in ids.compactMap({ position(of: $0) }) {
                var tags = edited[index].metadata
                mutation(&tags)
                try edited[index].updateMetadata(tags)
            }
            commitStagedEdits(edited, action: action, changedIDs: ids)
        } catch { present(error) }
    }

    func commitStagedEdits(_ edited: [AudioFile], action: String, changedIDs: Set<UUID>? = nil) {
        // Match tags and artwork; snapshots retain baselines but never restore locations.
        let candidates = changedIDs.map { ids in ids.compactMap { position(of: $0).map { edited[$0] } } } ?? edited
        let after = candidates.filter { item in
            guard let old = file(id: item.id) else { return false }
            return old.metadata != item.metadata || old.artwork != item.artwork
        }
        guard !after.isEmpty else { return }
        let before = after.compactMap { file(id: $0.id) }
        registerEditUndo(restoring: before, expecting: after, workspaceID: activeWorkspaceID, action: action)
        publishFileEdits(edited, changedIDs: Set(after.map(\.id)))
        editHistoryRevision += 1
        statusMessage = "\(action) · \(after.count) files changed"
        scheduleSessionSave()
    }

    private func registerEditUndo(restoring previous: [AudioFile], expecting expected: [AudioFile], workspaceID: UUID?, action: String) {
        let grouped = !editUndoManager.isUndoing && !editUndoManager.isRedoing
        if grouped { editUndoManager.beginUndoGrouping() }
        editUndoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restoreStagedEdit(previous, expected: expected, workspaceID: workspaceID, action: action)
            }
        }
        editUndoManager.setActionName(action)
        if grouped { editUndoManager.endUndoGrouping() }
    }

    private func restoreStagedEdit(_ previous: [AudioFile], expected: [AudioFile], workspaceID: UUID?, action: String) {
        guard !isBusy, workspaceID == activeWorkspaceID, expected.allSatisfy({ snapshot in
            guard let current = file(id: snapshot.id) else { return false }
            return [.ready, .changed, .saved].contains(current.state)
                && current.metadata == snapshot.metadata && current.artwork == snapshot.artwork
                && current.originalMetadata == snapshot.originalMetadata && current.originalArtwork == snapshot.originalArtwork
                && current.identity == snapshot.identity && current.url == snapshot.url
        }) else {
            clearEditHistory(); statusMessage = "Undo history reset because the files or library changed."; return
        }
        let versions = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        var edited = files
        do {
            for index in edited.indices {
                guard let version = versions[edited[index].id] else { continue }
                try edited[index].updateMetadata(version.metadata)
                try edited[index].updateArtwork(version.artwork)
            }
            registerEditUndo(restoring: expected, expecting: previous, workspaceID: workspaceID, action: action)
            files = edited
            editHistoryRevision += 1
            cancelMatchReview()
            scheduleSessionSave()
        } catch { clearEditHistory(); present(error) }
    }

    func undoMetadataEdit() {
        guard !isBusy else { return }
        editUndoManager.undo()
        if editHistoryNeedsReset { clearEditHistory() }
        editHistoryRevision += 1
    }
    func redoMetadataEdit() {
        guard !isBusy else { return }
        editUndoManager.redo()
        if editHistoryNeedsReset { clearEditHistory() }
        editHistoryRevision += 1
    }
    func clearEditHistory() {
        // NSUndoManager must finish dispatching its current group before removal.
        if editUndoManager.isUndoing || editUndoManager.isRedoing { editHistoryNeedsReset = true; return }
        editUndoManager.removeAllActions()
        editHistoryNeedsReset = false
        editHistoryRevision += 1
    }

    private var textUndoManager: UndoManager? { (NSApp?.keyWindow?.firstResponder as? NSTextView)?.undoManager }
    var canUndoUserEdit: Bool { textUndoManager?.canUndo == true || editUndoManager.canUndo }
    var canRedoUserEdit: Bool { textUndoManager?.canRedo == true || editUndoManager.canRedo }
    func undoUserEdit() {
        if let manager = textUndoManager, manager.canUndo { manager.undo() }
        else { undoMetadataEdit() }
    }
    func redoUserEdit() {
        if let manager = textUndoManager, manager.canRedo { manager.redo() }
        else { redoMetadataEdit() }
    }

    func copyTags(_ keys: Set<String>) {
        guard let file = primarySelectedFile else { return }
        let tags = Dictionary(uniqueKeysWithValues: keys.map { ($0, TagClipboard.Value(values: file.metadata.values(for: $0), deleted: file.metadata.isDeleted($0))) })
        guard let data = try? JSONEncoder().encode(TagClipboard(tags: tags)) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: NSPasteboard.PasteboardType("com.interlacedpixel.macpicard.tags"))
        let text = keys.sorted().map { "\($0)\t\(file.originalMetadata.values(for: $0).joined(separator: "; "))\t\(file.metadata.values(for: $0).joined(separator: "; "))" }.joined(separator: "\n")
        NSPasteboard.general.setString(text, forType: .string)
    }

    func pasteTags() {
        guard let data = NSPasteboard.general.data(forType: NSPasteboard.PasteboardType("com.interlacedpixel.macpicard.tags")) else {
            statusMessage = "Copy tags from the metadata table before pasting a tag set."; return
        }
        do { try applyTagClipboard(JSONDecoder().decode(TagClipboard.self, from: data)) }
        catch { present(error) }
    }

    func applyTagClipboard(_ clipboard: TagClipboard) throws {
        guard clipboard.tags.count <= 1_000 else { throw PicardError.invalidConfiguration("Too many pasted tags.") }
        guard clipboard.tags.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.contains(where: { $0.isNewline || $0 == "\0" }) }) else {
            throw PicardError.invalidConfiguration("A pasted tag name is invalid.")
        }
        mutateSelectedTags(action: "Paste tags") { tags in
            for (rawKey, value) in clipboard.tags {
                let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard !key.hasPrefix("~"), !Self.readOnlyTags.contains(key) else { continue }
                if value.deleted { tags.delete(key) } else { tags.setValues(value.values, for: key) }
            }
        }
    }
}
