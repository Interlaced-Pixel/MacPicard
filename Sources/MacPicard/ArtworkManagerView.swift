import AppKit
import ImageIO
import PicardCoverArt
import PicardFormats
import PicardFoundation
import SwiftUI
import UniformTypeIdentifiers

struct ArtworkManagerView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ArtworkDraft
    @State private var fileID: UUID?
    @State private var imageID: UUID?
    @State private var originalComparisonID: UUID?
    @State private var scope = "selection"
    @State private var replaceScope = false
    @State private var embed: Bool
    @State private var importMode = "append"
    @State private var maximumPixels: Int
    @State private var outputFormat: String
    @State private var quality: Double
    @State private var imageURL = ""
    @State private var archiveID: String
    @State private var archiveKind = "release"
    @State private var candidates: [CoverArtImage] = []
    @State private var candidateIDs = Set<String>()
    @State private var downloadSize: CoverArtImageSize
    @State private var error: String?
    @State private var activity: String?
    @State private var task: Task<Void, Never>?
    @State private var history: [[UUID: [Artwork]]] = []
    @State private var future: [[UUID: [Artwork]]] = []
    @State private var isReviewingApply = false
    @State private var exportPlan: ArtworkExportPlan?
    @State private var exportAccess: ArtworkExportAccess?
    @State private var exportPolicy = ArtworkExportCollisionPolicy.stop
    @State private var notice: String?

    init(model: AppModel) {
        self.model = model
        let files = model.selectedFiles
        _draft = State(initialValue: ArtworkDraft(workspaceID: model.activeWorkspaceID, files: files))
        _fileID = State(initialValue: files.first?.id)
        _imageID = State(initialValue: files.first?.artwork.images.first?.id)
        _originalComparisonID = State(initialValue: files.first?.originalArtwork.images.first?.id)
        let preferences = model.configuration.editing
        _embed = State(initialValue: preferences.embedImportedArtwork)
        _maximumPixels = State(initialValue: preferences.artworkMaximumPixels)
        _outputFormat = State(initialValue: preferences.artworkOutputFormat)
        _quality = State(initialValue: preferences.artworkJPEGQuality)
        _archiveID = State(initialValue: files.first?.metadata.firstValue(for: "musicbrainz_albumid") ?? "")
        _downloadSize = State(initialValue: CoverArtImageSize(rawValue: preferences.coverArtSize) ?? .thumbnail1200)
    }

    private var focusedFile: AudioFile? { draft.baselines.first { $0.id == fileID } }
    private var images: [Artwork] { fileID.flatMap { draft.imagesByFile[$0] } ?? [] }
    private var selectedImage: Artwork? { images.first { $0.id == imageID } }
    private var originalImage: Artwork? { focusedFile?.originalArtwork.images.first { $0.id == originalComparisonID } }
    private var changed: Bool { draft.baselines.contains { draft.imagesByFile[$0.id] != $0.artwork.images } }
    private var busy: Bool { activity != nil }
    private var validationError: String? {
        do { _ = try draft.editedFiles(current: model.files, workspaceID: model.activeWorkspaceID, replaceAllWith: replaceScope ? fileID : nil, validateImageData: false); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                imageList.frame(width: 255)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        comparison
                        imageDetails
                        importControls
                        archiveControls
                        conversionControls
                        exportControls
                    }.padding(20)
                }.frame(minWidth: 450)
            }
            Divider()
            footer
        }
        .frame(minWidth: 830, idealWidth: 1020, minHeight: 650, idealHeight: 760)
        .background(.regularMaterial)
        .accessibilityIdentifier("artwork-manager")
        .onDisappear { task?.cancel() }
        .onChange(of: imageID) { _, _ in
            let originals = focusedFile?.originalArtwork.images ?? []
            originalComparisonID = originals.first { $0.id == imageID }?.id ?? originals.first { $0.type == selectedImage?.type }?.id ?? originals.first?.id
        }
        .sheet(isPresented: $isReviewingApply) { applyReview }
        .sheet(isPresented: Binding(get: { exportPlan != nil }, set: { if !$0 { exportPlan = nil; exportAccess = nil } })) { exportReview }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Manage Artwork", systemImage: "photo.on.rectangle.angled").font(.title2.weight(.semibold))
                Spacer()
                Button("Undo", systemImage: "arrow.uturn.backward") { undo() }.disabled(history.isEmpty || busy)
                Button("Redo", systemImage: "arrow.uturn.forward") { redo() }.disabled(future.isEmpty || busy)
            }
            HStack {
                Picker("Scope", selection: $scope) {
                    Text("Selection").tag("selection")
                    Text("Album").tag("album")
                    Text("Entire workspace").tag("workspace")
                }.frame(width: 270).disabled(changed || busy)
                    .onChange(of: scope) { _, value in changeScope(value) }
                Picker("Preview file", selection: $fileID) {
                    ForEach(draft.baselines) { file in Text(file.url.lastPathComponent).tag(Optional(file.id)) }
                }.onChange(of: fileID) { _, _ in imageID = images.first?.id; originalComparisonID = focusedFile?.originalArtwork.images.first?.id }
                    .disabled(busy)
            }
            HStack {
                Toggle("Replace artwork on all \(draft.baselines.count) files with the preview file’s set", isOn: $replaceScope)
                    .disabled(draft.baselines.count < 2 || busy)
                Spacer()
                Toggle("Embed on Save Tags", isOn: $embed).disabled(busy)
            }.font(.caption)
            Text(embed ? "Changes are staged only. Review and Apply, then Save Tags to write audio files." : "Export-only mode: images can be imported, edited and exported, but no artwork changes will be applied to audio files.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(18)
    }

    private var imageList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Staged images · \(images.count)").font(.headline); Spacer() }.padding(.horizontal, 12)
            if images.isEmpty {
                ContentUnavailableView("No Artwork", systemImage: "photo", description: Text("Import images or select an archive download."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).accessibilityIdentifier("artwork-empty-state")
            } else {
            List(selection: $imageID) {
                ForEach(images) { image in
                    HStack(spacing: 10) {
                        ArtworkPreview(image: image).frame(width: 44, height: 44)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(image.type.rawValue.capitalized).fontWeight(.medium)
                            Text(image.description.isEmpty ? image.mimeType : image.description).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        }
                    }.tag(image.id)
                    .contextMenu {
                        Button("Move Up") { move(image.id, by: -1) }.disabled(images.first?.id == image.id)
                        Button("Move Down") { move(image.id, by: 1) }.disabled(images.last?.id == image.id)
                        Button("Restore Original") { restore(image.id) }.disabled(focusedFile?.originalArtwork.images.contains { $0.id == image.id } != true)
                        Button("Remove", role: .destructive) { remove(image.id) }
                    }
                }
            }.accessibilityIdentifier("artwork-image-list")
            }
            HStack {
                Button("Up", systemImage: "arrow.up") { if let imageID { move(imageID, by: -1) } }.disabled(imageID == nil || images.first?.id == imageID)
                Button("Down", systemImage: "arrow.down") { if let imageID { move(imageID, by: 1) } }.disabled(imageID == nil || images.last?.id == imageID)
                Button("Remove", systemImage: "minus", role: .destructive) { if let imageID { remove(imageID) } }.disabled(imageID == nil)
            }.labelStyle(.iconOnly).padding(.horizontal, 12)
            Menu("Restore Image…") {
                ForEach(focusedFile?.originalArtwork.images ?? []) { image in
                    Button("\(image.type.rawValue.capitalized) · \(image.description.isEmpty ? String(image.id.uuidString.prefix(8)) : image.description)") { restore(image.id) }
                }
            }.disabled(focusedFile?.originalArtwork.isEmpty != false).padding(.horizontal, 12)
            Button("Restore All Original Images") {
                guard let file = focusedFile else { return }
                edit { $0[file.id] = file.originalArtwork.images }; imageID = images.first?.id
            }.disabled(focusedFile == nil).padding(.horizontal, 12)
            Text("Drop image files here. JPEG, PNG and other single-frame ImageIO formats are accepted; convert to JPEG/PNG for embedding.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }.padding(.vertical, 12).disabled(busy)
            .dropDestination(for: URL.self) { urls, _ in
                guard !busy, urls.allSatisfy(\.isFileURL), !urls.isEmpty else { return false }
                importFiles(urls); return true
            }
    }

    private var comparison: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack {
                preview(originalImage, title: "Original · last saved", missing: "No saved image").accessibilityIdentifier("original-artwork-preview")
                if let original = focusedFile?.originalArtwork.images, !original.isEmpty {
                    Picker("Compare original", selection: $originalComparisonID) {
                        ForEach(Array(original.enumerated()), id: \.element.id) { index, image in Text("\(index + 1) · \(image.type.rawValue.capitalized)").tag(Optional(image.id)) }
                    }.font(.caption)
                }
            }
            preview(selectedImage, title: "Staged", missing: "Select or import an image").accessibilityIdentifier("staged-artwork-preview")
        }
    }

    private func preview(_ image: Artwork?, title: String, missing: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            ArtworkPreview(image: image).frame(height: 190).frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            if let image {
                ArtworkInfoLabel(image: image)
            } else { Text(missing).font(.caption).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity)
    }

    @ViewBuilder private var imageDetails: some View {
        if let image = selectedImage {
            GroupBox("Image details") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Type", selection: Binding(get: { image.type }, set: { value in update(image.id) { $0.type = value } })) {
                        ForEach([ArtworkType.front, .back, .leaflet, .media, .other], id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }
                    TextField("Description", text: Binding(get: { selectedImage?.description ?? "" }, set: { value in update(image.id) { $0.description = value } }))
                    Text(sourceLabel(image.source)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Restore this image") { restore(image.id) }.disabled(focusedFile?.originalArtwork.images.contains { $0.id == image.id } != true)
                    Text("M4A supports ordered cover images only and does not store descriptions. Booklet is stored as Leaflet; Obi as Other in typed containers.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }.disabled(busy)
        }
    }

    private var importControls: some View {
        GroupBox("Import") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("When adding", selection: $importMode) {
                    Text("Append").tag("append"); Text("Replace selected image").tag("selected"); Text("Replace entire image set").tag("all")
                }
                HStack {
                    Button("Choose Image Files…", systemImage: "folder") {
                        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false
                        panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK { importFiles(panel.urls) }
                    }
                    Text("Imports affect the preview file unless batch replacement is enabled.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    TextField("https://… image URL", text: $imageURL).accessibilityLabel("HTTPS artwork URL")
                    Button("Import URL") {
                        guard let url = URL(string: imageURL.trimmingCharacters(in: .whitespacesAndNewlines)), let client = model.artworkClient else {
                            error = "Enter an HTTPS image URL and wait for the app to finish loading."; return
                        }
                        run("Downloading image…") { [client] in [try await client.download(url: url)] }
                    }.disabled(imageURL.isEmpty)
                }
            }.padding(8)
        }.disabled(busy || focusedFile == nil)
    }

    private var archiveControls: some View {
        GroupBox("Cover Art Archive · select images before downloading") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Entity", selection: $archiveKind) { Text("Release").tag("release"); Text("Release group").tag("group") }.frame(width: 175)
                    TextField("MusicBrainz identifier", text: $archiveID).accessibilityLabel("Artwork MusicBrainz identifier")
                    Button("Find Images") { findImages() }.disabled(archiveID.isEmpty)
                }
                if !candidates.isEmpty {
                    ForEach(candidates) { candidate in
                        Toggle(isOn: Binding(get: { candidateIDs.contains(candidate.id) }, set: { if $0 { candidateIDs.insert(candidate.id) } else { candidateIDs.remove(candidate.id) } })) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("\(candidate.types.map { $0.rawValue.capitalized }.joined(separator: ", ")) · \(candidate.comment.isEmpty ? candidate.id : candidate.comment)")
                                Text("\(candidate.approved ? "Approved" : "Unapproved") · \(candidate.imageURL.host ?? "Archive")").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    HStack {
                        Picker("Download size", selection: $downloadSize) {
                            ForEach(CoverArtImageSize.allCases, id: \.self) { Text($0 == .original ? "Original" : "\($0.rawValue) pixels").tag($0) }
                        }
                        Button("Download Selected Images") {
                            guard let client = model.artworkClient else { return }
                            let selected = candidates.filter { candidateIDs.contains($0.id) }, size = downloadSize
                            run("Downloading selected artwork…") {
                                var result: [Artwork] = []
                                for candidate in selected {
                                    try Task.checkCancellation(); result.append(try await client.download(candidate, size: size))
                                    try ArtworkValidation.validateCollectionSize(result)
                                }
                                return result
                            }
                        }.disabled(candidateIDs.isEmpty)
                    }
                }
            }.padding(8)
        }.disabled(busy)
    }

    private var conversionControls: some View {
        GroupBox("Resize & format · explicit conversion") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Maximum side", value: $maximumPixels, format: .number).frame(width: 110).accessibilityLabel("Artwork maximum pixel size")
                    Text("pixels, no upscaling").font(.caption).foregroundStyle(.secondary)
                    Picker("Format", selection: $outputFormat) {
                        Text("Keep format").tag("preserve"); Text("JPEG").tag("jpeg"); Text("PNG").tag("png")
                    }
                }
                HStack { Text("JPEG quality \(Int(quality * 100))%").font(.caption); Slider(value: $quality, in: 0.1...1) }
                HStack {
                    Button("Convert Selected") { convert(all: false) }.disabled(selectedImage == nil)
                    Button("Convert All Preview Images") { convert(all: true) }.disabled(images.isEmpty)
                }
                Text("Conversion fixes image orientation. JPEG makes transparent areas white. Save writes changes to audio.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }.disabled(busy)
    }

    private var exportControls: some View {
        GroupBox("Export · review destinations before writing") {
            HStack {
                Picker("Collisions", selection: $exportPolicy) {
                    Text("Stop if a name exists").tag(ArtworkExportCollisionPolicy.stop)
                    Text("Generate unique names").tag(ArtworkExportCollisionPolicy.uniqueNames)
                }
                Button("Export Selected…") { reviewExport(selectedImage.map { [$0] } ?? []) }.disabled(selectedImage == nil)
                Button("Export All…") { reviewExport(images) }.disabled(images.isEmpty)
            }.padding(8)
        }.disabled(busy)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error { Text(error).foregroundStyle(MusicBrainzTheme.error).font(.caption).textSelection(.enabled) }
            if let validationError, embed { Text(validationError).foregroundStyle(MusicBrainzTheme.orange).font(.caption) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let activity { ProgressView().controlSize(.small); Text(activity).font(.caption); Button("Stop") { task?.cancel() } }
                Spacer()
                Button(embed ? "Cancel" : "Done") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Review & Apply…") { isReviewingApply = true }
                    .buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill).disabled(!embed || busy || model.isBusy || validationError != nil || (!changed && !replaceScope))
            }
        }.padding(16)
    }

    private var applyReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review artwork changes").font(.title2.weight(.semibold))
            Text(replaceScope ? "Replace the entire artwork set on every file in this frozen scope. Tags and audio are unchanged; artwork remains staged until Save Tags." : "Apply only the per-file image edits made in this manager. Tags and audio are unchanged.")
            List(draft.baselines) { file in
                let proposed = draft.imagesByFile[replaceScope ? (fileID ?? file.id) : file.id] ?? []
                VStack(alignment: .leading) {
                    Text(file.url.lastPathComponent)
                    Text("\(file.artwork.images.count) → \(proposed.count) images · \(proposed.map { $0.type.rawValue }.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                    if FormatRegistry.format(forExtension: file.url.pathExtension) == .mp4 { Text("M4A descriptions are not stored.").font(.caption).foregroundStyle(MusicBrainzTheme.orange) }
                }
            }
            if let validationError { Text(validationError).foregroundStyle(MusicBrainzTheme.error).font(.caption) }
            if let activity { HStack { ProgressView().controlSize(.small); Text(activity).font(.caption); Button("Stop") { task?.cancel() } } }
            HStack {
                Spacer(); Button("Back") { task?.cancel(); isReviewingApply = false }.keyboardShortcut(.cancelAction)
                Button("Apply Staged Artwork") {
                    let snapshot = draft, target = replaceScope ? fileID : nil
                    activity = "Validating artwork…"
                    task = Task {
                        do { try await model.applyArtworkDraftInBackground(snapshot, replaceAllWith: target); isReviewingApply = false; dismiss() }
                        catch { if !Task.isCancelled { self.error = error.localizedDescription; isReviewingApply = false } }
                        activity = nil
                    }
                }.buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill).disabled(validationError != nil || model.isBusy || busy)
            }
        }.padding(24).frame(width: 640, height: 470)
    }

    private var exportReview: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review image export").font(.title2.weight(.semibold))
            if let plan = exportPlan {
                Text(plan.directory.path).font(.caption).textSelection(.enabled)
                Text("Export creates image files without overwriting existing files or changing audio.").font(.caption)
                List(plan.items) { item in HStack { Text(item.filename); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(item.data.count), countStyle: .file)).foregroundStyle(.secondary) } }
                HStack {
                    Spacer(); Button("Cancel") { exportPlan = nil; exportAccess = nil }.keyboardShortcut(.cancelAction)
                    Button("Export \(plan.items.count) Images") {
                        let access = exportAccess; exportAccess = nil
                        exportPlan = nil; activity = "Exporting images…"; error = nil; model.isExportingArtwork = true
                        task = Task {
                            defer { model.isExportingArtwork = false }
                            do {
                                let worker = Task.detached(priority: .utility) { [access] in
                                    defer { withExtendedLifetime(access) {} }
                                    return try ArtworkExporter.execute(plan)
                                }
                                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                                notice = "Exported \(result.count) images to \(plan.directory.path)."
                            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                            activity = nil
                        }
                    }.buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill)
                }
            }
        }.padding(24).frame(width: 580, height: 400)
    }

    private func changeScope(_ value: String) {
        let targets: [AudioFile]
        switch value {
        case "workspace": targets = model.files.filter { [.ready, .changed, .saved].contains($0.state) }
        case "album":
            let group = model.albumGroups.first { $0.fileIDs.contains(fileID ?? UUID()) }
            let ids = Set(group?.fileIDs ?? [])
            targets = model.files.filter { [.ready, .changed, .saved].contains($0.state) && ids.contains($0.id) }
        default: targets = model.selectedFiles
        }
        draft = ArtworkDraft(workspaceID: model.activeWorkspaceID, files: targets)
        fileID = targets.first?.id; imageID = targets.first?.artwork.images.first?.id
        history = []; future = []; replaceScope = false
    }

    private func edit(_ body: (inout [UUID: [Artwork]]) -> Void) {
        guard !busy else { return }
        let previous = draft.imagesByFile
        body(&draft.imagesByFile)
        if previous != draft.imagesByFile { history.append(previous); if history.count > 80 { history.removeFirst() }; future = []; error = nil }
    }
    private func undo() { guard let value = history.popLast() else { return }; future.append(draft.imagesByFile); draft.imagesByFile = value; imageID = images.first?.id }
    private func redo() { guard let value = future.popLast() else { return }; history.append(draft.imagesByFile); draft.imagesByFile = value; imageID = images.first?.id }
    private func update(_ id: UUID, _ body: (inout Artwork) -> Void) {
        guard let fileID else { return }; edit { values in guard let index = values[fileID]?.firstIndex(where: { $0.id == id }) else { return }; body(&values[fileID]![index]) }
    }
    private func remove(_ id: UUID) { guard let fileID else { return }; edit { $0[fileID]?.removeAll { $0.id == id } }; imageID = images.first?.id }
    private func restore(_ id: UUID) {
        let previous = draft.imagesByFile
        guard let fileID else { return }; draft.restore(imageID: id, fileID: fileID)
        if previous != draft.imagesByFile { history.append(previous); if history.count > 80 { history.removeFirst() }; future = [] }; imageID = id
    }
    private func move(_ id: UUID, by delta: Int) {
        guard let fileID, let index = images.firstIndex(where: { $0.id == id }), images.indices.contains(index + delta) else { return }
        edit { $0[fileID]?.swapAt(index, index + delta) }
    }
    private func add(_ newImages: [Artwork]) async throws {
        guard let fileID else { return }
        let snapshot = draft, mode = ArtworkImportMode(rawValue: importMode) ?? .append, previousSelection = imageID
        let worker = Task.detached(priority: .utility) {
            var edited = snapshot
            let selected = try edited.importImages(newImages, fileID: fileID, mode: mode, selectedID: previousSelection)
            return (edited, selected)
        }
        let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        try Task.checkCancellation(); activity = nil
        edit { $0 = result.0.imagesByFile }; imageID = result.1
    }
    private func importFiles(_ urls: [URL]) {
        guard urls.count <= ArtworkValidation.maximumImages else { error = "Choose at most 64 images."; return }
        run("Importing images…") {
            let worker = Task.detached(priority: .utility) {
                var result: [Artwork] = []
                for url in urls {
                    try Task.checkCancellation()
                    let granted = url.startAccessingSecurityScopedResource(); defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    result.append(try ArtworkProcessor.importFile(url))
                    try ArtworkValidation.validateCollectionSize(result)
                }
                return result
            }
            return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
        }
    }
    private func run(_ label: String, operation: @escaping @Sendable () async throws -> [Artwork]) {
        guard !busy else { return }; error = nil; activity = label
        task = Task {
            do { let result = try await operation(); try Task.checkCancellation(); try await add(result) }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            activity = nil
        }
    }
    private func findImages() {
        guard let client = model.artworkClient, !busy else { return }
        let identifier = archiveID, kind = archiveKind
        activity = "Finding archive images…"; error = nil; candidates = []; candidateIDs = []
        task = Task {
            do {
                let release = try await (kind == "group" ? client.releaseGroup(identifier: identifier) : client.release(identifier: identifier))
                try Task.checkCancellation(); candidates = release.images
                if candidates.isEmpty { notice = "No images are available for this identifier." }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            activity = nil
        }
    }
    private func convert(all: Bool) {
        let selected = all ? images : selectedImage.map { [$0] } ?? []
        let maximum = maximumPixels, format = ArtworkOutputFormat(rawValue: outputFormat), jpegQuality = quality
        guard let fileID, !busy else { return }; activity = "Converting artwork…"; error = nil
        task = Task {
            do {
                let worker = Task.detached(priority: .utility) {
                    try selected.map { image -> Artwork in
                        try Task.checkCancellation()
                        guard let data = image.data else { throw ArtworkValidation.Failure("Image data is missing.") }
                        let output = try ArtworkProcessor.resize(data, maximumPixelSize: maximum, format: format, quality: jpegQuality)
                        let info = try ArtworkProcessor.inspect(output)
                        var edited = image; edited.data = output; edited.mimeType = info.mimeType; edited.width = info.width; edited.height = info.height
                        return edited
                    }
                }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); activity = nil
                let replacements = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
                edit { values in values[fileID] = (values[fileID] ?? []).map { replacements[$0.id] ?? $0 } }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            activity = nil
        }
    }
    private func reviewExport(_ images: [Artwork]) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Review Export"; panel.message = "Choose the destination folder. No images are written until you confirm the reviewed filenames."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = ArtworkExportAccess(url: url)
        let policy = exportPolicy; activity = "Preparing export review…"; error = nil
        task = Task {
            do {
                let worker = Task.detached(priority: .utility) { [access] in
                    defer { withExtendedLifetime(access) {} }
                    return try ArtworkExporter.review(images, directory: url, policy: policy)
                }
                let plan = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation(); exportAccess = access; exportPlan = plan
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            activity = nil
        }
    }
    private func sourceLabel(_ source: ArtworkSource) -> String {
        switch source {
        case .embedded: return "Source: embedded in audio file"
        case .localFile(let url): return "Source: \(url.lastPathComponent)"
        case .remote(let url): return "Source: HTTPS · \(url.host ?? "remote")\(url.path)"
        case .generated: return "Source: generated"
        }
    }
}

private final class ArtworkExportAccess: Sendable {
    let url: URL
    let granted: Bool
    init(url: URL) { self.url = url; granted = url.startAccessingSecurityScopedResource() }
    deinit { if granted { url.stopAccessingSecurityScopedResource() } }
}

private struct ArtworkInfoLabel: View {
    let image: Artwork
    @State private var info: ArtworkImageInfo?
    @State private var invalid = false
    var body: some View {
        Group {
            if invalid { Text("Image could not be decoded safely") }
            else if let width = info?.width ?? image.width, let height = info?.height ?? image.height {
                Text("\(width) × \(height) · \(ByteCountFormatter.string(fromByteCount: Int64(image.data?.count ?? 0), countStyle: .file))")
            } else { Text("Inspecting image dimensions…") }
        }.font(.caption).foregroundStyle(.secondary)
            .task(id: image.contentHash) {
                info = nil; invalid = false
                guard let data = image.data else { invalid = true; return }
                let worker = Task.detached(priority: .utility) { try? ArtworkProcessor.inspect(data) }
                let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                if !Task.isCancelled { info = result; invalid = result == nil }
            }
    }
}

/// Aspect-fit, orientation-correct bounded decode. Never allocate a full raster merely to draw a thumbnail.
struct ArtworkPreview: View {
    let image: Artwork?
    @State private var thumbnail: NSImage?
    var body: some View {
        Group {
            if let thumbnail { Image(nsImage: thumbnail).resizable().scaledToFit() }
            else { Image(systemName: "photo").font(.largeTitle).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .accessibilityLabel(image.map { "\($0.type.rawValue) artwork preview" } ?? "No image")
        .task(id: image?.contentHash) {
            thumbnail = nil
            guard let data = image?.data else { return }
            let worker = Task.detached(priority: .utility) { () -> Data? in
                guard (try? ArtworkValidation.inspect(data)) != nil else { return nil }
                return try? ArtworkProcessor.resize(data, maximumPixelSize: 600, format: .png)
            }
            let preview = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            if !Task.isCancelled, let preview { thumbnail = NSImage(data: preview) }
        }
    }
}
