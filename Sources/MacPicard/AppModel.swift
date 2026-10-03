import Foundation
import PicardCoverArt
import PicardFingerprint
import PicardFormats
import PicardFoundation
import PicardMusicBrainz
import PicardScripts
import PicardSessions
import UniformTypeIdentifiers

@MainActor
final class AppModel: ObservableObject {
    struct AlbumGroup: Identifiable, Hashable {
        let id: String
        let title: String
        let artist: String
        let fileIDs: [UUID]

        var subtitle: String {
            "\(artist) · \(fileIDs.count) \(fileIDs.count == 1 ? "track" : "tracks")"
        }
    }

    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var statusMessage = "Ready"
    @Published private(set) var isLoading = false
    @Published private(set) var isWorking = false
    @Published private(set) var progress: Double?
    @Published var files: [AudioFile] = []
    @Published var selectedFileIDs = Set<UUID>()
    @Published var selectedAlbumID: String?
    @Published var lookupResults: [MusicBrainzReleaseSummary] = []
    @Published var matchResults: [ReleaseMatchResult] = []
    @Published private(set) var selectedRelease: MusicBrainzRelease?
    @Published private(set) var scriptOutput = ""
    @Published var scriptSource = "$if2(%albumartist%,%artist%)/$if2(%album%,Unknown Album)/%tracknumber% %title%"
    @Published var destinationDirectory: URL?
    @Published var collisionPolicy: FileCollisionPolicy = .fail

    private var runtime: PicardRuntime?
    private var audioCoordinator: AudioFileCoordinator?
    private var musicBrainzClient: MusicBrainzClient?
    private var coverArtClient: CoverArtClient?
    private var saveCoordinator: AudioSaveCoordinator?
    private var organizationCoordinator: FileOrganizationCoordinator?
    private var sessionManager: SessionManager?
    private var sessionCreatedAt = Date()
    private var sessionSaveTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var selectedReleaseFileIDs = Set<UUID>()

    var albumGroups: [AlbumGroup] {
        var grouped: [String: (title: String, artist: String, ids: [UUID])] = [:]
        for file in files {
            let title = file.metadata.firstValue(for: "album")?.trimmedNonEmpty ?? "Unmatched files"
            let artist = (file.metadata.firstValue(for: "albumartist")
                ?? file.metadata.firstValue(for: "artist"))?.trimmedNonEmpty ?? "Unknown artist"
            let key: String
            if title == "Unmatched files" {
                key = "unmatched-\(file.id.uuidString)"
            } else {
                key = "\(artist.lowercased())\u{1F}\(title.lowercased())"
            }
            grouped[key, default: (title, artist, [])].ids.append(file.id)
        }

        return grouped.map { key, value in
            AlbumGroup(id: key, title: value.title, artist: value.artist, fileIDs: value.ids)
        }
        .sorted {
            if $0.title == $1.title { return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var visibleFiles: [AudioFile] {
        guard let selectedAlbumID,
              let group = albumGroups.first(where: { $0.id == selectedAlbumID }) else {
            return files
        }
        let ids = Set(group.fileIDs)
        return files.filter { ids.contains($0.id) }
    }

    var selectedFiles: [AudioFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    var primarySelectedFile: AudioFile? {
        selectedFiles.first
    }

    var hasUnsavedChanges: Bool {
        files.contains(where: \.isModified)
    }

    var selectedModifiedCount: Int {
        selectedFiles.count(where: \.isModified)
    }

    var selectedFormatSummary: String {
        let formats = Set(
            selectedFiles.compactMap { file in
                FormatRegistry.format(forExtension: file.url.pathExtension)?.displayName
            }
        )
        if formats.isEmpty { return "No format selected" }
        return formats.sorted().joined(separator: " · ")
    }

    var canDownloadCoverArt: Bool {
        guard !selectedFiles.isEmpty else { return false }
        return selectedRelease != nil
            || primarySelectedFile?.metadata.firstValue(for: "musicbrainz_albumid") != nil
    }

    func file(id: UUID) -> AudioFile? {
        files.first(where: { $0.id == id })
    }

    func metadataValue(_ key: String) -> String {
        primarySelectedFile?.metadata.firstValue(for: key) ?? ""
    }

    func bootstrap() async {
        guard snapshot == nil, !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let runtime = try PicardRuntime.live()
            let snapshot = try await runtime.start()
            let cache = MusicBrainzResponseCache(
                directory: snapshot.paths.cacheDirectory.appendingPathComponent("MusicBrainz", isDirectory: true)
            )
            let musicBrainz = MusicBrainzClient(
                userAgent: snapshot.configuration.requestUserAgent,
                cache: cache
            )
            let coverArt = CoverArtClient(
                userAgent: snapshot.configuration.requestUserAgent,
                cacheDirectory: snapshot.paths.cacheDirectory.appendingPathComponent("CoverArt", isDirectory: true)
            )
            let audio = AudioFileCoordinator()

            self.runtime = runtime
            self.snapshot = snapshot
            self.audioCoordinator = audio
            self.musicBrainzClient = musicBrainz
            self.coverArtClient = coverArt
            self.saveCoordinator = AudioSaveCoordinator(coordinator: audio)
            self.organizationCoordinator = FileOrganizationCoordinator()
            let sessionStore = await runtime.sessionStore
            self.sessionManager = SessionManager(store: sessionStore)

            try await restoreSession()
            if snapshot.configuration.autosaveEnabled {
                startAutosave(interval: max(15, snapshot.configuration.autosaveIntervalSeconds))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importResult(_ result: Result<[URL], Error>) async {
        do {
            let urls = try result.get()
            await importURLs(expanding: urls)
        } catch {
            present(error)
        }
    }

    func importDroppedProviders(_ providers: [NSItemProvider]) {
        Task { @MainActor [weak self] in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.url(from: provider) {
                    urls.append(url)
                }
            }
            await self?.importURLs(expanding: urls)
        }
    }

    func importURLs(expanding urls: [URL]) async {
        guard let audioCoordinator else { return }
        let expandedURLs = Self.expand(urls: urls)
        guard !expandedURLs.isEmpty else {
            statusMessage = "No supported audio files were found."
            return
        }

        isWorking = true
        progress = 0
        errorMessage = nil
        var imported = 0
        var failures: [String] = []
        defer {
            isWorking = false
            progress = nil
        }

        for (index, url) in expandedURLs.enumerated() {
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let file = try await audioCoordinator.load(url: url)
                files.append(file)
                imported += 1
                if let runtime {
                    try? await runtime.bookmarks.save(url: url, for: file.id.uuidString, readOnly: false)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress = Double(index + 1) / Double(expandedURLs.count)
        }

        if selectedAlbumID == nil {
            selectedAlbumID = albumGroups.first?.id
        }
        if selectedFileIDs.isEmpty {
            selectedFileIDs = Set(visibleFiles.prefix(1).map(\.id))
        }
        statusMessage = failures.isEmpty
            ? "Imported \(imported) \(imported == 1 ? "file" : "files")."
            : "Imported \(imported); skipped \(failures.count)."
        if !failures.isEmpty {
            errorMessage = failures.prefix(3).joined(separator: "\n")
        }
        await saveSession()
    }

    func selectAlbum(_ group: AlbumGroup) {
        selectedAlbumID = group.id
        selectedFileIDs = Set(group.fileIDs)
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        scheduleSessionSave()
    }

    func selectAllVisible() {
        selectedFileIDs = Set(visibleFiles.map(\.id))
    }

    func clearSelection() {
        selectedFileIDs.removeAll()
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        scheduleSessionSave()
    }

    func selectionChanged(_ ids: Set<UUID>) {
        selectedFileIDs = ids
        if let firstID = ids.first,
           let group = albumGroups.first(where: { $0.fileIDs.contains(firstID) }) {
            selectedAlbumID = group.id
        }
        if ids != selectedReleaseFileIDs {
            selectedRelease = nil
            selectedReleaseFileIDs.removeAll()
        }
        scheduleSessionSave()
    }

    func setMetadata(_ key: String, value: String) {
        guard !selectedFiles.isEmpty else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetIDs = Set(selectedFiles.map(\.id))
        for index in files.indices where targetIDs.contains(files[index].id) {
            var metadata = files[index].metadata
            if trimmed.isEmpty {
                metadata.unset(key)
            } else {
                metadata.setValue(value, for: key)
            }
            do {
                try files[index].updateMetadata(metadata)
            } catch {
                present(error)
            }
        }
        statusMessage = "Updated \(key) for \(selectedFiles.count) \(selectedFiles.count == 1 ? "file" : "files")."
        scheduleSessionSave()
    }

    func lookup() async {
        guard let musicBrainzClient, let primary = primarySelectedFile else {
            statusMessage = "Select an album or track before looking up releases."
            return
        }

        let local = LocalAlbumCandidate(
            metadata: primary.metadata,
            tracks: selectedFiles.map { LocalTrackCandidate(metadata: $0.metadata, id: $0.id) }
        )
        guard local.albumTitle != nil || local.albumArtist != nil || local.barcode != nil else {
            statusMessage = "Add an album, artist, or barcode before searching MusicBrainz."
            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = "Searching MusicBrainz…"
        defer { isWorking = false }
        do {
            let results = try await musicBrainzClient.searchReleases(for: local)
            lookupResults = results
            matchResults = ReleaseMatcher().rank(local: local, candidates: results)
            statusMessage = results.isEmpty ? "No matching releases found." : "Found \(results.count) releases."
        } catch {
            present(error)
        }
    }

    func chooseMatch(_ result: ReleaseMatchResult) async {
        guard let musicBrainzClient else { return }
        isWorking = true
        statusMessage = "Loading release details…"
        defer { isWorking = false }
        do {
            selectedRelease = try await musicBrainzClient.lookupRelease(id: result.release.id)
            selectedReleaseFileIDs = Set(selectedFiles.map(\.id))
            statusMessage = "Selected \(result.release.title)."
        } catch {
            present(error)
        }
    }

    func applySelectedRelease() {
        guard let selectedRelease else {
            statusMessage = "Choose a MusicBrainz match first."
            return
        }

        let trackValues = selectedRelease.tracks
        let targets = selectedFiles
        for (offset, file) in targets.enumerated() {
            guard let index = files.firstIndex(where: { $0.id == file.id }) else { continue }
            var metadata = files[index].metadata
            metadata.setValue(selectedRelease.title, for: "album")
            metadata.setValue(selectedRelease.artistCredit, for: "albumartist")
            if let date = selectedRelease.date { metadata.setValue(date, for: "date") }
            if let barcode = selectedRelease.barcode { metadata.setValue(barcode, for: "barcode") }
            if let releaseGroupID = selectedRelease.releaseGroupID {
                metadata.setValue(releaseGroupID, for: "musicbrainz_releasegroupid")
            }
            metadata.setValue(selectedRelease.id, for: "musicbrainz_albumid")
            if let label = selectedRelease.labelNames.first { metadata.setValue(label, for: "label") }
            if let catalog = selectedRelease.catalogNumbers.first { metadata.setValue(catalog, for: "catalognumber") }
            if offset < trackValues.count {
                let track = trackValues[offset]
                metadata.setValue(track.title, for: "title")
                metadata.setValue(track.artistCredit, for: "artist")
                metadata.setValue(track.number, for: "tracknumber")
                metadata.setValue(track.id, for: "musicbrainz_trackid")
                if let recordingID = track.recordingID {
                    metadata.setValue(recordingID, for: "musicbrainz_recordingid")
                }
                if !track.isrcs.isEmpty { metadata.setValues(track.isrcs, for: "isrc") }
            }
            do {
                try files[index].updateMetadata(metadata)
            } catch {
                present(error)
            }
        }
        statusMessage = "Applied MusicBrainz metadata to \(targets.count) files."
        scheduleSessionSave()
    }

    func downloadCoverArt() async {
        guard let coverArtClient, !selectedFiles.isEmpty else {
            statusMessage = "Choose a release before downloading cover art."
            return
        }
        let releaseIdentifier = selectedRelease?.id
            ?? primarySelectedFile?.metadata.firstValue(for: "musicbrainz_albumid")
        guard let releaseIdentifier, !releaseIdentifier.isEmpty else {
            statusMessage = "Choose a MusicBrainz release before downloading cover art."
            return
        }
        isWorking = true
        statusMessage = "Downloading cover art…"
        defer { isWorking = false }
        do {
            let release = try await coverArtClient.release(identifier: releaseIdentifier)
            guard let image = release.images.first(where: { $0.types.contains(.front) }) ?? release.images.first else {
                statusMessage = "No cover art is available for this release."
                return
            }
            let artwork = try await coverArtClient.download(image, size: .thumbnail1200)
            for index in files.indices where selectedFiles.contains(where: { $0.id == files[index].id }) {
                var collection = files[index].artwork
                collection.remove(id: collection.first(of: .front)?.id ?? UUID())
                collection.append(artwork)
                try files[index].updateArtwork(collection)
            }
            statusMessage = "Downloaded cover art for \(selectedFiles.count) files."
            scheduleSessionSave()
        } catch {
            present(error)
        }
    }

    func saveSelected() async {
        guard let saveCoordinator, !selectedFiles.isEmpty else {
            statusMessage = "Select at least one changed file to save."
            return
        }
        isWorking = true
        progress = 0
        statusMessage = "Writing metadata…"
        defer {
            isWorking = false
            progress = nil
        }
        do {
            let saved = try await saveCoordinator.saveAll(
                selectedFiles,
                options: AudioSaveOptions(
                    preserveModificationDate: snapshot?.configuration.preserveFileTimestamps ?? true
                ),
                progress: { [weak self] value in
                    await self?.updateSaveProgress(value)
                }
            )
            replaceFiles(saved)
            statusMessage = "Saved \(saved.count) \(saved.count == 1 ? "file" : "files")."
            await saveSession()
        } catch {
            present(error)
        }
    }

    func organizeSelected() async {
        guard let organizationCoordinator, let destinationDirectory, !selectedFiles.isEmpty else {
            statusMessage = "Choose a destination folder and select files to organize."
            return
        }
        isWorking = true
        statusMessage = "Organizing files…"
        defer { isWorking = false }
        do {
            let organized = try await organizationCoordinator.organize(
                files: selectedFiles,
                destinationDirectory: destinationDirectory,
                namingScript: scriptSource,
                collisionPolicy: collisionPolicy
            )
            replaceFiles(organized)
            statusMessage = "Organized \(organized.count) files."
            await saveSession()
        } catch {
            present(error)
        }
    }

    func runScript(applying: Bool) {
        guard let primary = primarySelectedFile else {
            scriptOutput = "Select a file first."
            return
        }
        do {
            let evaluation = try ScriptEvaluator().evaluate(
                scriptSource,
                context: ScriptContext(metadata: primary.metadata)
            )
            scriptOutput = evaluation.output
            if applying {
                let targetIDs = Set(selectedFiles.map(\.id))
                for index in files.indices where targetIDs.contains(files[index].id) {
                    try files[index].updateMetadata(evaluation.metadata)
                }
                statusMessage = "Applied script output to \(selectedFiles.count) files."
                scheduleSessionSave()
            } else {
                statusMessage = "Script evaluated successfully."
            }
        } catch {
            scriptOutput = error.localizedDescription
            present(error)
        }
    }

    func chooseDestination(_ result: Result<[URL], Error>) {
        do {
            guard let directory = try result.get().first else {
                statusMessage = "No destination selected."
                return
            }
            destinationDirectory = directory
            Task { @MainActor [weak self] in
                await self?.organizeSelected()
            }
        } catch {
            present(error)
        }
    }

    func saveSession() async {
        guard let sessionManager else { return }
        do {
            try await sessionManager.save(makeSessionDocument())
        } catch {
            present(error)
        }
    }

    func acceptRecoveryIfNeeded() async {
        guard let sessionManager else { return }
        do {
            if let loaded = try await sessionManager.loadBestAvailable(), loaded.source == .recovery {
                try await sessionManager.acceptRecovery()
            }
        } catch {
            present(error)
        }
    }

    private func restoreSession() async throws {
        guard let sessionManager else { return }
        guard let loaded = try await sessionManager.loadBestAvailable() else { return }
        sessionCreatedAt = loaded.document.createdAt
        files = loaded.document.files.map(AudioFile.restore(from:))
        selectedFileIDs = Set(loaded.document.selectedFileIDs.filter { id in files.contains(where: { $0.id == id }) })
        selectedAlbumID = albumGroups.first(where: { Set($0.fileIDs).isSuperset(of: selectedFileIDs) })?.id ?? albumGroups.first?.id
        if loaded.source == .recovery {
            statusMessage = "Recovered an autosaved session."
        }
    }

    private func makeSessionDocument() -> SessionDocument {
        SessionDocument(
            createdAt: sessionCreatedAt,
            savedAt: Date(),
            files: files.map { $0.sessionRecord() },
            selectedFileIDs: Array(selectedFileIDs),
            expandedNodeIDs: selectedAlbumID
                .flatMap { selectedID in albumGroups.first(where: { $0.id == selectedID })?.fileIDs.first }
                .map { [$0] } ?? []
        )
    }

    private func startAutosave(interval seconds: Int) {
        autosaveTask?.cancel()
        autosaveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, let self else { return }
                await self.saveRecovery()
            }
        }
    }

    private func saveRecovery() async {
        guard let sessionManager else { return }
        try? await sessionManager.saveRecovery(makeSessionDocument())
    }

    private func scheduleSessionSave() {
        sessionSaveTask?.cancel()
        sessionSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await self?.saveSession()
        }
    }

    private func replaceFiles(_ replacements: [AudioFile]) {
        let replacementByID = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
        files = files.map { replacementByID[$0.id] ?? $0 }
    }

    private func updateSaveProgress(_ value: Double) {
        progress = value
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "Action failed."
    }

    private static func expand(urls: [URL]) -> [URL] {
        let fileManager = FileManager.default
        var result: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let enumerator = fileManager.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for case let child as URL in enumerator {
                    if child.pathExtension.isEmpty { continue }
                    result.append(child)
                }
            } else {
                result.append(url)
            }
        }
        return result.filter { FormatRegistry().detectIfSupported(url: $0) }.uniquedURLs()
    }

    private static func url(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}

private extension FormatRegistry {
    func detectIfSupported(url: URL) -> Bool {
        (try? detect(url: url)) != nil
    }
}

private extension Array where Element == URL {
    func uniquedURLs() -> [URL] {
        var seen = Set<URL>()
        return filter { seen.insert($0.standardizedFileURL).inserted }
    }
}
