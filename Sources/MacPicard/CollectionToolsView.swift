import AppKit
import PicardFoundation
import PicardScripts
import PicardSessions
import SwiftUI
import UniformTypeIdentifiers

struct CollectionToolsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @State private var draft = WorkflowDocument()
    @State private var loaded = false
    var body: some View {
        VStack(spacing: 0) {
            MusicBrainzBrandHeader()
            Picker("Collection tools", selection: $presentation.collectionToolsPage) {
                Text("Workflow").tag("operations"); Text("Scripts").tag("scripts")
                Text("Filename → Tags").tag("filenames"); Text("Profiles").tag("profiles")
            }.pickerStyle(.segmented).padding(16)
            Divider()
            if let error = model.workflowError {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    Button("Reveal Data") { if let store = model.workflowStore { NSWorkspace.shared.activateFileViewerSelecting([store.url]) } }
                    Button("Retry Load") { Task { await model.reloadWorkflows() } }.disabled(model.isBusy)
                }.padding(12)
            }
            switch presentation.collectionToolsPage {
            case "scripts": ScriptStudioView(model: model, draft: $draft, scope: $presentation.collectionToolsScope)
            case "filenames": FilenameTagsView(model: model, scope: $presentation.collectionToolsScope)
            case "profiles": WorkflowProfilesView(model: model, draft: $draft)
            default: CollectionWorkflowView(model: model, presentation: presentation, scope: $presentation.collectionToolsScope)
            }
        }.frame(minWidth: 920, minHeight: 680).background(MusicBrainzTheme.surface)
            .onAppear { if !loaded { draft = model.workflowDocument; loaded = true } }
            .onChange(of: model.workflowDocument) { old, value in if draft == old { draft = value } }
    }
}

private struct ScopePicker: View {
    @Binding var scope: CollectionScope
    let count: Int
    var body: some View {
        HStack {
            Picker("Scope", selection: $scope) { ForEach(CollectionScope.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 300)
            Text("\(count) indexed files").foregroundStyle(.secondary).font(.caption)
            Spacer()
        }
    }
}

private struct WorkflowReviewView: View {
    @ObservedObject var model: AppModel
    let review: WorkflowReview
    @State private var excluded = Set<UUID>()
    @State private var acknowledgesBlocked = false
    @State private var error: String?
    @State private var applied = false
    @State private var search = ""
    private var eligibleCount: Int { review.rows.count { $0.error == nil && !$0.changes.isEmpty && !excluded.contains($0.id) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(review.scope) · \(eligibleCount) included changes · \(excluded.count) excluded · \(review.blockedCount) blocked · \(review.rows.count - review.changedCount - review.blockedCount) unchanged").font(.caption)
                Spacer(); TextField("Search preview", text: $search).frame(width: 240)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(review.rows.filter { search.isEmpty || $0.file.url.path.localizedCaseInsensitiveContains(search) }) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Toggle(row.file.url.lastPathComponent, isOn: Binding(get: { row.error == nil && !excluded.contains(row.id) }, set: { if $0 { excluded.remove(row.id) } else { excluded.insert(row.id) } }))
                                    .disabled(row.error != nil || applied || model.isBusy)
                                Spacer(); Text(row.error == nil ? (row.changes.isEmpty ? "Unchanged" : "\(row.changes.count) fields") : "Blocked").font(.caption).foregroundStyle(.secondary)
                            }
                            if let error = row.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            ForEach(row.changes) { change in
                                Text("\(change.key): \(change.originalDeleted ? "Deleted" : change.originalValues.joined(separator: " · ")) → \(change.currentDeleted ? "Delete" : change.currentValues.joined(separator: " · "))")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                            }
                            if !row.output.isEmpty { Text(row.output).font(.caption.monospaced()).textSelection(.enabled) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.background, in: .rect(cornerRadius: 8))
                    }
                }
            }
            if review.blockedCount > 0 { Toggle("Skip the \(review.blockedCount) blocked files; apply only reviewed eligible changes", isOn: $acknowledgesBlocked).font(.caption) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text(applied ? "Applied as one staged undo transaction. Save Tags separately." : "Preview never writes audio. Excluded and blocked files remain untouched.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(applied ? "Applied" : "Stage Changes for \(eligibleCount) Files") {
                    do { try model.applyWorkflowReview(review, excluded: excluded, confirmed: true); applied = true }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.glassProminent).disabled(applied || model.isBusy || eligibleCount == 0 || (review.blockedCount > 0 && !acknowledgesBlocked))
            }
        }
    }
}

struct ScriptStudioView: View {
    @ObservedObject var model: AppModel
    @Binding var draft: WorkflowDocument
    @State private var selectedID: UUID?
    @Binding var scope: CollectionScope
    @State private var review: WorkflowReview?
    @State private var namingReview: OrganizationReview?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    @State private var confirmsDelete = false
    private var selectedIndex: Int? { draft.scripts.firstIndex { $0.id == selectedID } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("Named scripts · execution order").font(.headline)
                List(selection: $selectedID) {
                    ForEach(draft.scripts) { script in
                        HStack { Image(systemName: script.enabled ? "checkmark.circle.fill" : "circle"); VStack(alignment: .leading) { Text(script.name); Text(script.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary) } }.tag(script.id)
                    }
                }
                HStack {
                    Menu("New") {
                        Button("Tagging Script") { add(.tagging) }; Button("Naming Script") { add(.naming) }
                    }
                    Button("Duplicate") { if let index = selectedIndex { var value = draft.scripts[index]; value.id = UUID(); value.name += " copy"; draft.scripts.append(value); selectedID = value.id } }.disabled(selectedIndex == nil)
                }
                HStack {
                    Button("↑") { move(-1) }.accessibilityLabel("Move script earlier")
                    Button("↓") { move(1) }.accessibilityLabel("Move script later")
                    Button("Delete…", role: .destructive) { confirmsDelete = true }.disabled(selectedIndex == nil)
                }
                Button("Save Script Library") { perform { try await model.persistWorkflows(draft) } }.disabled(model.workflowError != nil)
                if draft != model.workflowDocument {
                    Text("Unsaved library draft").font(.caption).foregroundStyle(MusicBrainzTheme.purple)
                    Button("Revert Library Draft") { draft = model.workflowDocument; selectedID = draft.scripts.first?.id }
                }
                HStack { Button("Import…") { importDocument() }; Button("Export…") { exportDocument() } }
                Text("Enabled tagging scripts run in list order on each file’s own tags. Naming scripts never stage tags.").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(minWidth: 260, idealWidth: 285, maxWidth: 330).disabled(model.isBusy || busy)
            VStack(alignment: .leading, spacing: 12) {
                ScopePicker(scope: $scope, count: model.collectionFiles(scope).count).disabled(model.isBusy || busy)
                if let index = selectedIndex {
                    HStack {
                        TextField("Script name", text: $draft.scripts[index].name)
                        Toggle("Enabled", isOn: $draft.scripts[index].enabled)
                        Text(draft.scripts[index].kind.rawValue.capitalized).font(.caption)
                    }.disabled(model.isBusy || busy)
                    TextEditor(text: $draft.scripts[index].source).font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100, maxHeight: 180).background(.background).accessibilityLabel("Managed script source").disabled(model.isBusy || busy)
                    HStack {
                        Button("Preview Enabled Tagging Scripts") { preview() }.disabled(!draft.scripts.contains { $0.kind == .tagging && $0.enabled })
                        if draft.scripts[index].kind == .naming {
                            Button("Preview Naming Paths") { previewNaming(draft.scripts[index].source) }
                            Button("Use as Naming Default") {
                                let source = draft.scripts[index].source
                                perform { var config = model.configuration; config.editing.namingPattern = source; try await model.savePreferences(config) }
                            }
                        }
                    }.disabled(model.isBusy || busy)
                } else { ContentUnavailableView("Create or select a script", systemImage: "curlybraces") }
                if let review { WorkflowReviewView(model: model, review: review).id(review.id) }
                if let namingReview {
                    Text("\(namingReview.rows.count) paths · read-only; no files move here").font(.caption)
                    ScrollView { LazyVStack(alignment: .leading) { ForEach(namingReview.rows) { row in Text("\(row.source.lastPathComponent) → \(row.destination?.path ?? row.message)").font(.caption.monospaced()).textSelection(.enabled) } } }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                if let error = model.workflowError { Text(error).foregroundStyle(.red).font(.caption) }
                if busy { HStack { ProgressView().controlSize(.small); Button("Stop") { task?.cancel() } } }
                Spacer(minLength: 0)
            }.padding(18).frame(minWidth: 580)
        }
        .onAppear { selectedID = draft.scripts.first?.id }
        .onChange(of: draft) { _, _ in review = nil; namingReview = nil }
        .onChange(of: scope) { _, _ in review = nil; namingReview = nil }
        .onDisappear { task?.cancel() }
        .alert("Delete this script?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { draft.scripts.removeAll { $0.id == selectedID }; selectedID = draft.scripts.first?.id }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This edits the draft library only. Save Script Library to persist it. Audio is not changed.") }
    }
    private func add(_ kind: ManagedScript.Kind) {
        let value = ManagedScript(name: kind == .tagging ? "New Tagging Script" : "New Naming Script", kind: kind,
                                  source: kind == .tagging ? "$set(title,$trim(%title%))" : model.configuration.editing.namingPattern)
        draft.scripts.append(value); selectedID = value.id
    }
    private func move(_ delta: Int) { guard let index = selectedIndex, draft.scripts.indices.contains(index + delta) else { return }; draft.scripts.swapAt(index, index + delta) }
    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        error = nil; busy = true
        task = Task { do { try await operation() } catch { if !Task.isCancelled { self.error = error.localizedDescription } }; busy = false }
    }
    private func preview() {
        let scripts = draft.scripts, scope = scope
        perform { review = try await model.previewWorkflow(scope: scope, scripts: scripts); namingReview = nil }
    }
    private func previewNaming(_ source: String) {
        let targets = model.collectionFiles(scope), root = model.libraryDirectory ?? model.destinationDirectory ?? FileManager.default.temporaryDirectory
        perform { namingReview = try await model.organizationCoordinator.preview(files: targets, directory: root, namingScript: source); review = nil }
    }
    private func importDocument() {
        do { if let data = try WorkflowFilePanels.importJSON() { var value = draft; try value.merge(WorkflowDocument.imported(data)); draft = value } }
        catch { self.error = error.localizedDescription }
    }
    private func exportDocument() { do { try WorkflowFilePanels.exportJSON(draft.exported(), name: "MacPicard-Workflows.json") } catch { self.error = error.localizedDescription } }
}

struct FilenameTagsView: View {
    @ObservedObject var model: AppModel
    @State private var pattern = "{track} - {title}"
    @State private var mappings = [FilenameFieldMapping(token: "track", tag: "tracknumber"), FilenameFieldMapping(token: "title", tag: "title")]
    @Binding var scope: CollectionScope
    @State private var review: WorkflowReview?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var busy = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScopePicker(scope: $scope, count: model.collectionFiles(scope).count).disabled(model.isBusy || busy)
            Text("Filename → Tags").font(.title2.weight(.semibold))
            Text("Use literal separators and named captures. Paths are matched from their last components, without the audio extension. Ambiguous files stay blocked.").font(.callout).foregroundStyle(.secondary)
            TextField("Pattern", text: $pattern).font(.body.monospaced()).disabled(busy || model.isBusy)
            HStack { Button("Track — Title") { pattern = "{track} - {title}" }; Button("Artist / Album / Track — Title") { pattern = "{artist}/{album}/{track} - {title}" } }.disabled(busy || model.isBusy)
            ForEach($mappings) { $mapping in
                HStack { Toggle("{\(mapping.token)}", isOn: $mapping.enabled).frame(width: 180, alignment: .leading); Text("→"); TextField("Writable tag", text: $mapping.tag) }.disabled(busy || model.isBusy)
            }
            if let parser = try? FilenameTagParser(pattern: pattern), let first = model.collectionFiles(scope).first {
                Text("Sample: \(parser.sample(for: first.url))").font(.caption.monospaced()).textSelection(.enabled)
            }
            Button("Preview Tag Changes") {
                busy = true; error = nil; let pattern = pattern, mappings = mappings, scope = scope
                task = Task { do { review = try await model.previewWorkflow(scope: scope, scripts: [], pattern: pattern, mappings: mappings) } catch { if !Task.isCancelled { self.error = error.localizedDescription } }; busy = false }
            }.disabled(busy || model.isBusy)
            if busy { HStack { ProgressView().controlSize(.small); Button("Stop") { task?.cancel() } } }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if let review { WorkflowReviewView(model: model, review: review).id(review.id) }
            Spacer(minLength: 0)
        }.padding(20)
        .onChange(of: pattern) { _, _ in
            review = nil
            do {
                let parser = try FilenameTagParser(pattern: pattern)
                mappings = parser.tokens.map { token in mappings.first { $0.token == token } ?? FilenameFieldMapping(token: token, tag: token == "track" ? "tracknumber" : token == "disc" ? "discnumber" : token) }
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .onChange(of: mappings) { _, _ in review = nil }
        .onChange(of: scope) { _, _ in review = nil }
        .onDisappear { task?.cancel() }
    }
}

struct WorkflowProfilesView: View {
    @ObservedObject var model: AppModel
    @Binding var draft: WorkflowDocument
    @State private var selectedID: UUID?
    @State private var error: String?
    @State private var confirmsDelete = false
    private var index: Int? { draft.profiles.firstIndex { $0.id == selectedID } }
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Configuration profiles").font(.headline)
                List(selection: $selectedID) { ForEach(draft.profiles) { Text($0.name).tag($0.id) } }
                Button("Capture Current Preferences") {
                    let value = WorkflowProfile(name: "New Profile", configuration: model.configuration)
                    draft.profiles.append(value); selectedID = value.id
                }
                HStack {
                    Button("Duplicate") { if let index { var value = draft.profiles[index]; value.id = UUID(); value.name += " copy"; draft.profiles.append(value); selectedID = value.id } }
                    Button("Delete…", role: .destructive) { confirmsDelete = true }
                }.disabled(index == nil)
                Button("Save Profile Library") { run { try await model.persistWorkflows(draft) } }
                if draft != model.workflowDocument {
                    Text("Unsaved library draft").font(.caption).foregroundStyle(MusicBrainzTheme.purple)
                    Button("Revert Library Draft") { draft = model.workflowDocument; selectedID = draft.profiles.first?.id }
                }
                HStack {
                    Button("Import…") { do { if let data = try WorkflowFilePanels.importJSON() { var value = draft; try value.merge(WorkflowDocument.imported(data)); draft = value } } catch { self.error = error.localizedDescription } }
                    Button("Export…") { do { try WorkflowFilePanels.exportJSON(draft.exported(), name: "MacPicard-Profiles-And-Scripts.json") } catch { self.error = error.localizedDescription } }
                }
                Text("Exports include named scripts and profiles only. No credentials, bookmarks, library/session documents or audio files.").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(minWidth: 260, maxWidth: 330)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let index {
                        TextField("Profile name", text: $draft.profiles[index].name).font(.title2)
                        Text("Activate changes only the checked preference groups. Other settings and pending music edits remain intact.").font(.callout).foregroundStyle(.secondary)
                        ForEach(ProfileOption.allCases) { option in
                            Toggle(option.rawValue.capitalized, isOn: Binding(get: { draft.profiles[index].included.contains(option) }, set: { if $0 { draft.profiles[index].included.insert(option) } else { draft.profiles[index].included.remove(option) } }))
                        }
                        GroupBox("Matching") {
                            VStack(alignment: .leading, spacing: 10) {
                                LabeledContent("Preferred country") { TextField("Country code", text: $draft.profiles[index].country).labelsHidden() }
                                LabeledContent("Confidence threshold") { TextField("Threshold", value: $draft.profiles[index].threshold, format: .percent).labelsHidden() }
                                LabeledContent("Preserved tags") { TextField("Comma-separated tag names", text: Binding(get: { draft.profiles[index].preservedTags.joined(separator: ", ") }, set: { draft.profiles[index].preservedTags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } })).labelsHidden() }
                            }
                        }
                        GroupBox("Naming") { TextField("Naming script", text: $draft.profiles[index].naming, axis: .vertical).font(.body.monospaced()) }
                        GroupBox("Default tagging script") { TextField("Tag script", text: $draft.profiles[index].tagging, axis: .vertical).font(.body.monospaced()) }
                        GroupBox("Artwork") {
                            VStack(alignment: .leading, spacing: 10) {
                                Toggle("Automatic artwork", isOn: $draft.profiles[index].automaticArtwork)
                                Toggle("Embed on Save Tags", isOn: $draft.profiles[index].embed)
                                Toggle("Replace front cover", isOn: $draft.profiles[index].replaceCover)
                                Picker("Download size", selection: $draft.profiles[index].artworkSize) { ForEach(["original", "250", "500", "1200"], id: \.self) { Text($0.capitalized).tag($0) } }
                                LabeledContent("Maximum image side (px)") { TextField("Maximum pixels", value: $draft.profiles[index].maximumPixels, format: .number).labelsHidden() }
                                Picker("Format", selection: $draft.profiles[index].format) { Text("Keep").tag("preserve"); Text("JPEG").tag("jpeg"); Text("PNG").tag("png") }
                                Slider(value: $draft.profiles[index].quality, in: 0.1...1) { Text("JPEG quality") }
                            }
                        }
                        Toggle("Preserve file timestamps", isOn: $draft.profiles[index].preserveTimestamps)
                        Button("Update Snapshot from Current Settings") {
                            let old = draft.profiles[index]
                            draft.profiles[index] = WorkflowProfile(id: old.id, name: old.name, included: old.included, configuration: model.configuration)
                        }
                        Button("Activate Included Preferences") { let value = draft.profiles[index]; run { try await model.activateProfile(value) } }.buttonStyle(.glassProminent)
                    } else { ContentUnavailableView("Capture or import a profile", systemImage: "slider.horizontal.3") }
                    if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if let error = model.workflowError { Text(error).font(.caption).foregroundStyle(.red) }
                }.padding(20)
            }
        }.disabled(model.isBusy)
        .onAppear { selectedID = draft.profiles.first?.id }
        .alert("Delete this profile?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { draft.profiles.removeAll { $0.id == selectedID }; selectedID = draft.profiles.first?.id }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This changes the draft only. Save Profile Library to persist deletion. Current preferences and music are untouched.") }
    }
    private func run(_ action: @escaping @MainActor () async throws -> Void) {
        error = nil; Task { do { try await action() } catch { self.error = error.localizedDescription } }
    }
}

struct CollectionWorkflowView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @Environment(\.openWindow) private var openWindow
    @Binding var scope: CollectionScope
    @State private var saveReview: [AudioFile] = []
    @State private var saveWorkspace: UUID?
    @State private var reviewingSave = false
    @State private var error: String?
    @State private var job: Task<Void, Never>?
    @State private var savedScopeIDs = Set<UUID>()
    @State private var savedScopeWorkspace: UUID?
    @State private var savedBaselines: [UUID: AudioFile] = [:]
    private var targets: [AudioFile] { model.collectionFiles(scope) }
    private var changed: [AudioFile] { targets.filter(\.isModified) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ScopePicker(scope: $scope, count: targets.count).disabled(model.isBusy)
                Text("Collection Workflow").font(.title2.weight(.semibold))
                Text("Each step stops for your review. Matching and tools stage edits; Save writes tags; Organize moves only explicitly reviewed files.").foregroundStyle(.secondary)
                GroupBox("1 · Identify and review") {
                    HStack {
                        Text("\(targets.count) files in \(scope.rawValue.lowercased())").font(.callout); Spacer()
                        Button("Match Metadata…") {
                            openWindow(id: "workspace")
                            if scope == .workspace { model.startLibraryMatch(threshold: model.configuration.editing.matchThreshold); presentation.isShowingLibraryMatch = true }
                            else { model.selectionChanged(Set(targets.map(\.id))); presentation.showsMatchComparison = true; Task { await model.lookup() } }
                        }.disabled(targets.isEmpty || model.isBusy || (scope == .workspace ? model.activeWorkspace?.kind != .library : !model.canLookUp(Set(targets.map(\.id)))))
                        Button("Scan Audio…") { model.startFingerprintScan(scope: .items(Set(targets.map(\.id)))); openWindow(id: "workspace"); presentation.isShowingFingerprints = true }.disabled(targets.isEmpty || model.isBusy)
                    }.padding(10)
                }
                GroupBox("2 · Stage edits and inspect changes") {
                    HStack {
                        Button("Scripts") { presentation.collectionToolsPage = "scripts" }
                        Button("Filename → Tags") { presentation.collectionToolsPage = "filenames" }
                        Button("Metadata…") { model.selectionChanged(Set(targets.filter { [.ready, .changed, .saved].contains($0.state) }.map(\.id))); openWindow(id: "workspace"); presentation.isShowingMetadataEditor = true }.disabled(targets.isEmpty || model.isBusy)
                        Button("Artwork…") { model.selectionChanged(Set(targets.filter { [.ready, .changed, .saved].contains($0.state) }.map(\.id))); openWindow(id: "workspace"); presentation.isShowingArtwork = true }.disabled(targets.isEmpty || model.isBusy)
                        Spacer()
                    }.padding(10)
                }
                GroupBox("3 · Review and save changed files") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(changed.count) files with pending edits · \(targets.count { ![.ready, .changed, .saved].contains($0.state) }) unavailable/blocked").font(.caption)
                        Button("Review Save Tags…") { saveReview = changed; saveWorkspace = model.activeWorkspaceID; reviewingSave = true; error = nil }.disabled(changed.isEmpty || model.isBusy)
                        if reviewingSave {
                            ScrollView { LazyVStack(alignment: .leading) { ForEach(saveReview) { file in
                                Text("\(file.url.lastPathComponent) · \(file.metadata.difference(from: file.originalMetadata).changedKeys.joined(separator: ", "))\(file.artwork != file.originalArtwork ? " · artwork" : "")").font(.caption.monospaced())
                            } } }.frame(maxHeight: 180)
                            HStack {
                                Button("Cancel Review") { reviewingSave = false }
                                Button("Write Tags to \(saveReview.count) Files") { save() }.buttonStyle(.glassProminent).disabled(model.isBusy)
                            }
                        }
                        if model.isWorking { HStack { ProgressView().controlSize(.small); Button("Stop after current file") { job?.cancel() } } }
                        ScrollView { LazyVStack(alignment: .leading) { ForEach(model.lastSaveOutcomes) { outcome in
                            Label("\(outcome.filename): \(outcome.message)", systemImage: outcome.saved ? "checkmark.circle" : "exclamationmark.triangle").font(.caption).textSelection(.enabled)
                        } } }.frame(maxHeight: 160)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("4 · Review organization, then confirm moves") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Guided organization excludes failed, cancelled, unavailable, still-pending or changed-since-save files. It never starts automatically.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Review Saved/Clean Files…") {
                                guard savedScopeWorkspace == model.activeWorkspaceID else { error = "Save/review this workspace before the guided move step."; return }
                                let eligible = Set(savedScopeIDs.filter { id in model.file(id: id).map { !$0.isModified && [.ready, .saved].contains($0.state) && savedBaselines[id] == $0 } == true })
                                guard !eligible.isEmpty else { error = "No unchanged saved files are eligible. Save and review again."; return }
                                model.requestOrganizationReview(ids: eligible, label: "Guided saved/clean files"); openWindow(id: "workspace"); presentation.isShowingOrganization = true
                            }.disabled(model.isBusy || savedScopeIDs.isEmpty)
                            Button("Organize Scope Independently…") {
                                if scope == .workspace && model.activeWorkspace?.kind == .library { model.requestOrganizationReview(entireLibrary: true) }
                                else { model.requestOrganizationReview(ids: Set(targets.map(\.id)), label: scope.rawValue) }
                                openWindow(id: "workspace"); presentation.isShowingOrganization = true
                            }.disabled(targets.isEmpty || model.isBusy)
                        }
                        Button("Review Already-Clean Scope") {
                            let clean = targets.filter { !$0.isModified && [.ready, .saved].contains($0.state) }
                            savedScopeIDs = Set(clean.map(\.id)); savedScopeWorkspace = model.activeWorkspaceID
                            savedBaselines = Dictionary(uniqueKeysWithValues: clean.map { ($0.id, $0) })
                        }.disabled(model.isBusy)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.padding(24)
        }.onDisappear { job?.cancel() }
        .onChange(of: scope) { _, _ in reviewingSave = false; savedScopeIDs = [] }
    }
    private func save() {
        guard saveWorkspace == model.activeWorkspaceID, saveReview.allSatisfy({ model.file(id: $0.id) == $0 }) else { error = "Workspace/files changed after review. Review again before writing."; return }
        let scopeFiles = targets, changes = saveReview, workspace = saveWorkspace
        reviewingSave = false
        job = Task {
            await model.saveFiles(changes)
            guard workspace == model.activeWorkspaceID else { return }
            var eligible = model.savedOrganizationIDs(from: model.lastSaveOutcomes)
            eligible.formUnion(scopeFiles.filter { !$0.isModified && [.ready, .saved].contains($0.state) && model.file(id: $0.id) == $0 }.map(\.id))
            savedScopeIDs = eligible; savedScopeWorkspace = workspace
            savedBaselines = Dictionary(uniqueKeysWithValues: model.files.filter { eligible.contains($0.id) }.map { ($0.id, $0) })
        }
    }
}

@MainActor private enum WorkflowFilePanels {
    static func importJSON() throws -> Data? {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        return try handle.read(upToCount: 2 * 1024 * 1024 + 1)
    }
    static func exportJSON(_ data: Data, name: String) throws {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
        try data.write(to: url, options: .atomic)
    }
}
