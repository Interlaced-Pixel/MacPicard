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
    @Published var errorMessage: String?
    @Published var statusMessage = "Ready"
    @Published private(set) var isLoading = false
    @Published var isWorking = false
    @Published var progress: Double?
    @Published var files: [AudioFile] = [] {
        didSet { rebuildBrowserIndex() }
    }
    @Published private(set) var albumGroups: [AlbumGroup] = []
    @Published var searchQuery = "" {
        didSet {
            rebuildBrowserMatches()
            if oldValue != searchQuery { keepSelectionInSearchResults() }
        }
    }
    @Published var browserFilter = BrowserFilter.all {
        didSet {
            rebuildBrowserMatches()
            if oldValue != browserFilter { keepSelectionInSearchResults() }
        }
    }
    @Published private(set) var matchingFileIDs = Set<UUID>()
    @Published var albumSort = AlbumSort.title
    @Published var expandedAlbumIDs = Set<String>()
    @Published var workspaces: [MusicWorkspace] = []
    @Published var activeWorkspaceID: UUID?
    @Published var isSwitchingWorkspace = false
    @Published var isScanningLibrary = false
    @Published var selectedFileIDs = Set<UUID>()
    @Published var selectedAlbumID: String?
    @Published var lookupResults: [MusicBrainzReleaseSummary] = []
    @Published var matchResults: [ReleaseMatchResult] = []
    @Published private(set) var selectedRelease: MusicBrainzRelease?
    @Published private(set) var scriptOutput = ""
    @Published var scriptSource = "$if2(%albumartist%,%artist%)/$if2(%album%,Unknown Album)/%tracknumber% %title%"
    @Published var destinationDirectory: URL?
    @Published var collisionPolicy: FileCollisionPolicy = .fail

    var runtime: PicardRuntime?
    private var audioCoordinator: AudioFileCoordinator?
    private var musicBrainzClient: MusicBrainzClient?
    private var coverArtClient: CoverArtClient?
    private var saveCoordinator: AudioSaveCoordinator?
    private var organizationCoordinator: FileOrganizationCoordinator?
    var sessionManager: SessionManager?
    var sessionCreatedAt = Date()
    var sessionSaveTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var selectedReleaseFileIDs = Set<UUID>()
    private var filesByID: [UUID: AudioFile] = [:]
    var workspaceStore: WorkspaceStore?
    let playback = PlaybackController()
    let libraryScanner = LibraryScanner()
    var workspaceAccess: ScopedURLAccess?
    var importedAccess: [ScopedURLAccess] = []
    var accessBookmarkKeys: [String] = []
    var refreshTask: Task<Void, Never>?
    var libraryScanTask: Task<Void, Never>?
    var activeLibraryScan: Task<LibraryScanResult, Error>?

    private func rebuildBrowserIndex() {
        filesByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        var grouped: [String: (title: String, artist: String, ids: [UUID])] = [:]
        for file in files {
            let title = file.metadata.firstValue(for: "album")?.trimmedNonEmpty ?? "Unmatched files"
            let artist = (file.metadata.firstValue(for: "albumartist")
                ?? file.metadata.firstValue(for: "artist"))?.trimmedNonEmpty ?? "Unknown artist"
            let key: String
            if title == "Unmatched files" {
                key = "unmatched"
            } else {
                key = "\(artist.lowercased())\u{1F}\(title.lowercased())"
            }
            grouped[key, default: (title, artist, [])].ids.append(file.id)
        }

        albumGroups = grouped.map { key, value in
            AlbumGroup(
                id: key,
                title: value.title,
                artist: value.artist,
                fileIDs: value.ids.compactMap { file(id: $0) }.sorted(by: isFileBefore).map(\.id)
            )
        }
        .sorted {
            if $0.title == $1.title { return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        rebuildBrowserMatches()
        playback.updateTracks(files)
    }

    private func rebuildBrowserMatches() {
        matchingFileIDs = Set(files.filter { matchesBrowser($0) }.map(\.id))
    }

    private func keepSelectionInSearchResults() {
        let remaining = selectedFileIDs.intersection(matchingFileIDs)
        if remaining != selectedFileIDs { selectionChanged(remaining) }
    }

    var visibleFiles: [AudioFile] {
        let candidates: [AudioFile]
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let group = albumGroups.first(where: { $0.id == selectedAlbumID }) {
            candidates = group.fileIDs.compactMap { filesByID[$0] }
        } else {
            candidates = orderedAlbumGroups.flatMap { $0.fileIDs.compactMap { filesByID[$0] } }
        }
        return candidates.filter { matchingFileIDs.contains($0.id) }
    }

    var selectedFiles: [AudioFile] {
        selectedFileIDs.compactMap { filesByID[$0] }.sorted(by: isFileBefore)
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
        if selectedRelease != nil { return true }
        let releaseIDs = Set(selectedFiles.map { $0.metadata.firstValue(for: "musicbrainz_albumid") ?? "" })
        return releaseIDs.count == 1 && releaseIDs.first?.isEmpty == false
    }

    func file(id: UUID) -> AudioFile? {
        filesByID[id]
    }

    func metadataValue(_ key: String) -> String {
        let values = selectedFiles.map { $0.metadata.firstValue(for: key) ?? "" }
        guard let first = values.first else { return "" }
        return values.dropFirst().allSatisfy { $0 == first } ? first : ""
    }

    func metadataValueIsMixed(_ key: String) -> Bool {
        let values = selectedFiles.map { $0.metadata.firstValue(for: key) ?? "" }
        return Set(values).count > 1
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
            try await restoreWorkspaces()
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
        guard let audioCoordinator, !isWorking, !isSwitchingWorkspace else { return }
        isWorking = true
        progress = 0
        errorMessage = nil
        var imported = 0
        var failures: [String] = []
        defer {
            isWorking = false
            progress = nil
        }
        let accessedRoots = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { for url in accessedRoots { url.stopAccessingSecurityScopedResource() } }
        let expandedURLs: [URL]
        do {
            expandedURLs = try await libraryScanner.expand(urls)
            try await rememberImportAccess(urls)
        } catch { present(error); return }
        let knownPaths = Set(files.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        var loadedFiles: [AudioFile] = []
        for (index, url) in expandedURLs.enumerated() {
            if knownPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) { continue }
            do {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let file = try await audioCoordinator.load(url: url)
                loadedFiles.append(file)
                imported += 1
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress = Double(index + 1) / Double(expandedURLs.count)
        }
        files.append(contentsOf: loadedFiles)
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
        searchQuery = ""
        selectedAlbumID = group.id
        selectedFileIDs = Set(group.fileIDs).intersection(matchingFileIDs)
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        scheduleSessionSave()
    }

    func selectAllVisible() {
        selectionChanged(Set(visibleFiles.map(\.id)))
    }

    func clearSelection() {
        selectedFileIDs.removeAll()
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        scheduleSessionSave()
    }

    func resetWorkspaceSelection() {
        selectedFileIDs.removeAll()
        selectedAlbumID = nil
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        lookupResults.removeAll()
        matchResults.removeAll()
        searchQuery = ""
        browserFilter = .all
        expandedAlbumIDs.removeAll()
        destinationDirectory = nil
    }

    func selectionChanged(_ ids: Set<UUID>) {
        selectedFileIDs = ids
        if ids != selectedReleaseFileIDs {
            selectedRelease = nil
            selectedReleaseFileIDs.removeAll()
        }
        scheduleSessionSave()
    }

    func setMetadata(_ key: String, value: String) {
        guard !selectedFiles.isEmpty, !isWorking else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetIDs = Set(selectedFiles.map(\.id))
        var edited = files
        for index in edited.indices where targetIDs.contains(edited[index].id) {
            var metadata = edited[index].metadata
            if trimmed.isEmpty {
                metadata.unset(key)
            } else {
                metadata.setValue(value, for: key)
            }
            do {
                try edited[index].updateMetadata(metadata)
            } catch {
                present(error)
            }
        }
        files = edited
        statusMessage = "Updated \(key) for \(selectedFiles.count) \(selectedFiles.count == 1 ? "file" : "files")."
        scheduleSessionSave()
    }

    func lookup() async {
        guard canLookupSelection else {
            statusMessage = "Select tracks from one album before looking up a release."
            return
        }
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
        guard let musicBrainzClient, !isWorking else { return }
        isWorking = true
        statusMessage = "Loading release details…"
        defer { isWorking = false }
        do {
            let targets = selectedFileIDs
            let release = try await musicBrainzClient.lookupRelease(id: result.release.id)
            guard targets == selectedFileIDs else { return }
            selectedRelease = release
            selectedReleaseFileIDs = targets
            statusMessage = "Selected \(result.release.title)."
        } catch {
            present(error)
        }
    }

    func applySelectedRelease() {
        guard let selectedRelease, !isWorking else {
            statusMessage = "Choose a MusicBrainz match first."
            return
        }

        let trackValues = selectedRelease.tracks
        let targets = selectedFiles
        var edited = files
        let indices = Dictionary(uniqueKeysWithValues: edited.enumerated().map { ($0.element.id, $0.offset) })
        for (offset, file) in targets.enumerated() {
            guard let index = indices[file.id] else { continue }
            var metadata = edited[index].metadata
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
                try edited[index].updateMetadata(metadata)
            } catch {
                present(error)
            }
        }
        files = edited
        statusMessage = "Applied MusicBrainz metadata to \(targets.count) files."
        scheduleSessionSave()
    }

    func downloadCoverArt() async {
        guard let coverArtClient, !selectedFiles.isEmpty, !isWorking else {
            statusMessage = "Choose a release before downloading cover art."
            return
        }
        let releaseIdentifier = selectedRelease?.id
            ?? primarySelectedFile?.metadata.firstValue(for: "musicbrainz_albumid")
        guard let releaseIdentifier, !releaseIdentifier.isEmpty else {
            statusMessage = "Choose a MusicBrainz release before downloading cover art."
            return
        }
        errorMessage = nil
        isWorking = true
        statusMessage = "Downloading cover art…"
        let targets = selectedFileIDs
        defer { isWorking = false }
        do {
            let release = try await coverArtClient.release(identifier: releaseIdentifier)
            guard let image = release.images.first(where: { $0.types.contains(.front) }) ?? release.images.first else {
                statusMessage = "No cover art is available for this release."
                return
            }
            let artwork = try await coverArtClient.download(image, size: .thumbnail1200)
            var edited = files
            for index in edited.indices where targets.contains(edited[index].id) {
                var collection = edited[index].artwork
                collection.remove(id: collection.first(of: .front)?.id ?? UUID())
                collection.append(artwork)
                try edited[index].updateArtwork(collection)
            }
            files = edited
            statusMessage = "Downloaded cover art for \(selectedFiles.count) files."
            scheduleSessionSave()
        } catch {
            present(error)
        }
    }

    func saveSelected() async {
        await saveFiles(selectedFiles.filter(\.isModified))
    }

    func saveAllChanges() async {
        await saveFiles(files.filter(\.isModified))
    }

    private func saveFiles(_ targets: [AudioFile]) async {
        guard let saveCoordinator, !targets.isEmpty, !isWorking else {
            statusMessage = "Select at least one changed file to save."
            return
        }
        isWorking = true
        progress = 0
        statusMessage = "Writing metadata…"
        if let playingID = playback.currentTrack?.fileID, targets.contains(where: { $0.id == playingID }) {
            playback.stop()
        }
        defer {
            isWorking = false
            progress = nil
        }
        var saved: [AudioFile] = []
        var failures: [String] = []
        for (index, file) in targets.enumerated() {
            do {
                let result = try await saveCoordinator.save(file, options: AudioSaveOptions(
                    preserveModificationDate: snapshot?.configuration.preserveFileTimestamps ?? true
                ))
                saved.append(result)
            } catch { failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
            progress = Double(index + 1) / Double(targets.count)
        }
        replaceFiles(saved)
        statusMessage = "Saved \(saved.count) \(saved.count == 1 ? "file" : "files")."
        errorMessage = failures.isEmpty ? nil : failures.prefix(3).joined(separator: "\n")
        await saveSession()
    }

    func organizeSelected() async {
        guard let organizationCoordinator, let destinationDirectory, !selectedFiles.isEmpty, !isWorking else {
            statusMessage = "Choose a destination folder and select files to organize."
            return
        }
        isWorking = true
        statusMessage = "Organizing files…"
        if let playingID = playback.currentTrack?.fileID, selectedFileIDs.contains(playingID) { playback.stop() }
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
        guard !isBusy else { return }
        guard !selectedFiles.isEmpty else {
            scriptOutput = "Select a file first."
            return
        }
        do {
            let evaluator = ScriptEvaluator()
            let targets = selectedFiles
            var edited = files
            let indices = Dictionary(uniqueKeysWithValues: edited.enumerated().map { ($0.element.id, $0.offset) })
            var outputs: [String] = []
            for file in targets {
                let evaluation = try evaluator.evaluate(scriptSource, context: ScriptContext(metadata: file.metadata))
                if outputs.count < 3 { outputs.append(evaluation.output) }
                if applying, let index = indices[file.id] { try edited[index].updateMetadata(evaluation.metadata) }
            }
            scriptOutput = outputs.joined(separator: "\n")
            if applying {
                files = edited
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
                guard let self else { return }
                let accessed = directory.startAccessingSecurityScopedResource()
                defer { if accessed { directory.stopAccessingSecurityScopedResource() } }
                do {
                    try await self.rememberImportAccess([directory])
                    await self.organizeSelected()
                } catch { self.present(error) }
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

    func restoreSession(_ loaded: LoadedSession?) {
        guard let loaded else { return }
        sessionCreatedAt = loaded.document.createdAt
        files = loaded.document.files.map(AudioFile.restore(from:))
        selectedFileIDs = Set(loaded.document.selectedFileIDs.filter { id in files.contains(where: { $0.id == id }) })
        selectedAlbumID = loaded.document.selectedAlbumKey
        accessBookmarkKeys = loaded.document.accessBookmarkKeys
        expandedAlbumIDs.removeAll()
        if loaded.source == .recovery {
            statusMessage = "Recovered an autosaved session."
        }
    }

    func makeSessionDocument() -> SessionDocument {
        SessionDocument(
            createdAt: sessionCreatedAt,
            savedAt: Date(),
            files: files.map { $0.sessionRecord() },
            selectedFileIDs: Array(selectedFileIDs),
            expandedNodeIDs: [],
            selectedAlbumKey: selectedAlbumID,
            accessBookmarkKeys: accessBookmarkKeys
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

    func scheduleSessionSave() {
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

    private func isFileBefore(_ lhs: AudioFile, _ rhs: AudioFile) -> Bool {
        let leftDisc = numericTag("discnumber", in: lhs) ?? 1
        let rightDisc = numericTag("discnumber", in: rhs) ?? 1
        if leftDisc != rightDisc { return leftDisc < rightDisc }

        let leftTrack = numericTag("tracknumber", in: lhs) ?? Int.max
        let rightTrack = numericTag("tracknumber", in: rhs) ?? Int.max
        if leftTrack != rightTrack { return leftTrack < rightTrack }

        return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
    }

    private func numericTag(_ key: String, in file: AudioFile) -> Int? {
        guard let value = file.metadata.firstValue(for: key) else { return nil }
        return Int(value.split(separator: "/", maxSplits: 1).first ?? Substring(value))
    }

    func updateSaveProgress(_ value: Double) {
        progress = value
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        statusMessage = "Action failed."
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
