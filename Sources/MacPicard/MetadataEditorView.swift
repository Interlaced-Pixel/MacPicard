import AppKit
import PicardFoundation
import PicardFormats
import SwiftUI

struct MetadataEditorView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var changedOnly = false
    @State private var changedFirst = true
    @State private var selectedKeys = Set<String>()
    @State private var editing: TagDraft?

    private var rows: [MetadataRow] {
        model.metadataRows.filter { (!changedOnly || $0.changed) && (search.isEmpty || $0.key.localizedStandardContains(search)
            || $0.current.localizedStandardContains(search) || $0.original.localizedStandardContains(search)) }
            .sorted { changedFirst && $0.changed != $1.changed ? $0.changed : $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("All Tags & Changes").font(.title2.weight(.semibold))
                    Text("\(model.selectedFiles.count) selected files · edits remain staged until Save Tags")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            HStack {
                TextField("Search tags and values", text: $search).textFieldStyle(.roundedBorder)
                Toggle("Changed only", isOn: $changedOnly)
                Toggle("Changed first", isOn: $changedFirst)
            }.padding(.horizontal, 18).padding(.bottom, 12)
            Table(rows, selection: $selectedKeys) {
                TableColumn("Tag") { row in
                    HStack {
                        if row.changed { Image(systemName: "pencil.circle").accessibilityLabel("Changed") }
                        Text(row.key)
                    }.foregroundStyle(row.changed ? Color.orange : .primary)
                }.width(min: 130, ideal: 175)
                TableColumn("Original") { row in Text(row.original).textSelection(.enabled).help(row.original) }
                TableColumn("New") { row in
                    Button { open(row.key) } label: {
                        Text(row.current).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain).help("Edit \(row.key): \(row.current)")
                }
            }
            .contextMenu(forSelectionType: String.self) { keys in
                if let key = keys.first {
                    Button("Edit Tag…") { open(key) }.disabled(keys.count != 1 || !model.canEditSelection)
                    Button("Restore Original Values") { model.restoreTags(keys) }.disabled(!model.canEditSelection)
                    Button("Merge Original Values") { model.restoreTags(keys, merging: true) }.disabled(!model.canEditSelection)
                    Button("Preserve When Matching") { preserve(keys) }.disabled(model.isBusy)
                    Button("Copy Tags") { model.copyTags(keys) }
                    Button("Copy New Value") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.primarySelectedFile?.metadata.values(for: key).joined(separator: "; ") ?? "", forType: .string)
                    }.disabled(keys.count != 1)
                    Button("Paste Value") {
                        if let text = NSPasteboard.general.string(forType: .string) {
                            model.setTagValues(text.components(separatedBy: "; "), for: key)
                        }
                    }.disabled(keys.count != 1 || !model.canEditSelection)
                    Button("Remove Tags", role: .destructive) { model.deleteTags(keys) }.disabled(!model.canEditSelection)
                }
            } primaryAction: { keys in if let key = keys.first { open(key) } }
            Divider()
            HStack {
                Button("Add Tag…", systemImage: "plus") { open(nil) }
                Button("Copy All Tags") { model.copyTags(Set(model.metadataRows.map(\.key))) }
                Button("Paste Tag Set") { model.pasteTags() }
                Spacer()
                Button("Undo", systemImage: "arrow.uturn.backward") { model.undoMetadataEdit() }
                    .disabled(!model.editUndoManager.canUndo)
                Button("Redo", systemImage: "arrow.uturn.forward") { model.redoMetadataEdit() }
                    .disabled(!model.editUndoManager.canRedo)
            }.padding(16).disabled(!model.canEditSelection)
            Text(model.errorMessage ?? "Copy uses the first selected file's values. Custom tags and multiple values depend on the audio container; rejected writes keep edits pending.")
                .font(.caption).foregroundStyle(model.errorMessage == nil ? Color.secondary : .red)
                .padding(.horizontal, 18).padding(.bottom, 14)
        }
        .sheet(item: $editing) { draft in TagEditorSheet(model: model, draft: draft) }
        .onChange(of: model.selectedFileIDs) { selectedKeys.removeAll(); editing = nil }
    }

    private func open(_ key: String?) {
        guard model.canEditSelection else { return }
        editing = TagDraft(key: key ?? "", values: key.map { model.primarySelectedFile?.metadata.values(for: $0) ?? [] } ?? [""],
            files: model.selectedFiles, workspaceID: model.activeWorkspaceID)
    }

    private func preserve(_ keys: Set<String>) {
        var configuration = model.configuration
        configuration.editing.preservedTags = Array(Set(configuration.editing.preservedTags).union(keys)).sorted()
        Task { do { try await model.savePreferences(configuration) } catch { model.present(error) } }
    }
}

private struct TagDraft: Identifiable {
    let id = UUID()
    let key: String
    let values: [String]
    let files: [AudioFile]
    let workspaceID: UUID?
}

private struct TagEditorSheet: View {
    @ObservedObject var model: AppModel
    let draft: TagDraft
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    private struct ValueRow: Identifiable { let id = UUID(); var value: String }
    @State private var values: [ValueRow] = []
    private var isCurrent: Bool {
        model.activeWorkspaceID == draft.workspaceID && model.selectedFileIDs == Set(draft.files.map(\.id))
            && draft.files.allSatisfy { model.file(id: $0.id) == $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(draft.key.isEmpty ? "Add Tag" : "Edit \(draft.key)").font(.title2.weight(.semibold))
            TextField("Tag name", text: $key).textFieldStyle(.roundedBorder)
                .disabled(!draft.key.isEmpty)
            Text("These values replace this tag on all \(draft.files.count) selected files. Each row is a separate value; an empty row is an explicit empty value.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($values) { $row in
                        HStack {
                            TextField("Value", text: $row.value).textFieldStyle(.roundedBorder)
                            Button("Remove", systemImage: "minus.circle") { values.removeAll { $0.id == row.id } }
                        }
                    }
                }
            }.frame(minHeight: 100, maxHeight: 240)
            Button("Add Value", systemImage: "plus") { values.append(ValueRow(value: "")) }
            if !isCurrent { Text("Files changed. Close and reopen this editor before applying.").foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply Values") { model.setTagValues(values.map(\.value), for: key); dismiss() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(!isCurrent || !model.canEditSelection || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || key.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("~") || key.contains(where: { $0.isNewline || $0 == "\0" }))
            }
        }.padding(22).frame(width: 520)
        .onAppear { key = draft.key; values = draft.values.map { ValueRow(value: $0) } }
    }
}

struct AudioFileDetailsView: View {
    let file: AudioFile
    @State private var properties: FormatAudioProperties?
    @State private var format: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("File Details").font(.subheadline.weight(.semibold))
            Text(file.url.path).font(.caption).textSelection(.enabled).id(file.url)
            LabeledContent("State", value: file.state.rawValue.capitalized)
            if let identity = file.identity { LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: identity.byteCount, countStyle: .file)) }
            if let duration = file.durationInMilliseconds { LabeledContent("Duration", value: String(format: "%.2f seconds", Double(duration) / 1_000)) }
            if let format { LabeledContent("Format", value: format) }
            if let properties {
                LabeledContent("Bitrate", value: "\(properties.bitrate) kbps")
                LabeledContent("Sample rate", value: "\(properties.sampleRate) Hz")
                LabeledContent("Channels", value: String(properties.channels))
                if let bits = properties.bitsPerSample { LabeledContent("Bit depth", value: "\(bits) bits") }
            }
            if let error { Text(error).foregroundStyle(.secondary).textSelection(.enabled) }
            if let error = file.lastError { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
        }.font(.caption)
        .task(id: file.url) {
            properties = nil; format = nil; error = nil
            do {
                let result = try await FormatEngine().read(url: file.url)
                guard !Task.isCancelled else { return }
                properties = result.audioProperties; format = result.format.displayName
            } catch { if !Task.isCancelled { self.error = "Audio details unavailable: \(error.localizedDescription)" } }
        }
    }
}
