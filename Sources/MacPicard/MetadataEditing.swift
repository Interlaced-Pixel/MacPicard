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
        let keys = Set(selectedFiles.flatMap { $0.metadata.keys + $0.originalMetadata.keys + Array($0.metadata.deletedTagKeys) })
        return keys.sorted().map { key in
            MetadataRow(key: key, original: tagSummary(key, original: true), current: tagSummary(key, original: false),
                changed: selectedFiles.contains { $0.metadata.values(for: key) != $0.originalMetadata.values(for: key)
                    || $0.metadata.contains(key) != $0.originalMetadata.contains(key)
                    || $0.metadata.isDeleted(key) != $0.originalMetadata.isDeleted(key) })
        }
    }

    private func tagSummary(_ key: String, original: Bool) -> String {
        let selections = selectedFiles.map { original ? $0.originalMetadata : $0.metadata }
        guard let tags = selections.first else { return "Absent" }
        guard selections.allSatisfy({ $0.values(for: key) == tags.values(for: key)
            && $0.contains(key) == tags.contains(key) && $0.isDeleted(key) == tags.isDeleted(key) }) else {
            return "Multiple values"
        }
        if tags.isDeleted(key) { return "Deleted" }
        if !tags.contains(key) { return "Absent" }
        return tags.values(for: key).map { $0.isEmpty ? "Empty value" : $0 }.joined(separator: "; ")
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
            for index in edited.indices where ids.contains(edited[index].id) {
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
            commitStagedEdits(edited, action: merging ? "Merge original tags" : "Restore tags")
        } catch { present(error) }
    }

    private func mutateSelectedTags(action: String, _ mutation: (inout Metadata) -> Void) {
        guard canEditSelection else { return }
        let ids = selectedFileIDs
        var edited = files
        do {
            for index in edited.indices where ids.contains(edited[index].id) {
                var tags = edited[index].metadata
                mutation(&tags)
                try edited[index].updateMetadata(tags)
            }
            commitStagedEdits(edited, action: action)
        } catch { present(error) }
    }

    func commitStagedEdits(_ edited: [AudioFile], action: String) {
        let oldByID = Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0) })
        // Match tags and artwork; snapshots retain baselines but never restore locations.
        let after = edited.filter { item in
            guard let old = oldByID[item.id] else { return false }
            return old.metadata != item.metadata || old.artwork != item.artwork
        }
        guard !after.isEmpty else { return }
        let before = after.compactMap { oldByID[$0.id] }
        registerEditUndo(restoring: before, expecting: after, workspaceID: activeWorkspaceID, action: action)
        files = edited
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
