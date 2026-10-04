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
    struct AlbumGroup: Identifiable, Hashable, Codable, Sendable {
        let id: String
        let title: String
        let artist: String
        let fileIDs: [UUID]

        var subtitle: String {
            "\(artist) · \(fileIDs.count) \(fileIDs.count == 1 ? "track" : "tracks")"
        }
    }

    enum LibraryMatchProposalStatus: String, Sendable, Codable {
        case matched
        case review
        case noMatch
        case failed
        case rejected
        case applied

        var title: String {
            switch self {
            case .matched: "High confidence"
            case .review: "Review recommended"
            case .noMatch: "No match"
            case .failed: "Lookup failed"
            case .rejected: "Rejected by user"
            case .applied: "Applied"
            }
        }
    }

    struct LibraryMatchProposal: Identifiable, Sendable, Codable {
        let id: String
        let albumTitle: String
        let artist: String
        let fileIDs: [UUID]
        let result: ReleaseMatchResult?
        let release: MusicBrainzRelease?
        var status: LibraryMatchProposalStatus
        let errorMessage: String?
        var baselines: [ReviewFileBaseline] = []

        var score: Double { result?.score.total ?? 0 }
        var trackMatchCount: Int { result?.trackMatches.count(where: { $0.releaseTrackID != nil }) ?? 0 }
        var ambiguousTrackCount: Int { result?.trackMatches.count(where: { $0.decision == .ambiguous }) ?? 0 }
    }

    struct LibraryMatchRun: Sendable, Codable {
        var proposals: [LibraryMatchProposal]
        let autoApplyThreshold: Double
        let completedAt: Date

        var highConfidence: [LibraryMatchProposal] { proposals.filter { $0.status == .matched } }
        var needsReview: [LibraryMatchProposal] { proposals.filter { $0.status == .review } }
        var unresolved: [LibraryMatchProposal] {
            proposals.filter { $0.status == .noMatch || $0.status == .failed }
        }
    }

    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var configuration = AppConfiguration()
    @Published var errorMessage: String? { didSet { if let errorMessage { recordActivity(errorMessage) } } }
    @Published var statusMessage = "Ready" { didSet { recordActivity(statusMessage) } }
    @Published var monitoringMessage: String? { didSet { if let monitoringMessage { recordActivity(monitoringMessage, background: true) } } }
    @Published var editHistoryRevision = 0
    let editUndoManager = UndoManager()
    var editHistoryNeedsReset = false
    @Published private(set) var isLoading = false
    @Published var isWorking = false
    @Published var isExportingArtwork = false
    @Published var progress: Double?
    @Published var files: [AudioFile] = [] {
        didSet { rebuildBrowserIndex() }
    }
    @Published private(set) var albumGroups: [AlbumGroup] = []
    @Published var searchQuery = "" {
        didSet {
            searchTask?.cancel()
            searchTask = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                guard let self else { return }
                self.applyBrowserSearch()
            }
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
    @Published var selectedArtist: String?
    @Published var groupsByArtist = false
    @Published var activity: [ActivityEntry] = []
    @Published var browserPreferences = BrowserPreferences()
    var browserPreferencesURL: URL?
    var searchTask: Task<Void, Never>?
    var appliedSearchQuery = ""
    var browserIndexUpdates = 0
    @Published var lookupResults: [MusicBrainzReleaseSummary] = []
    @Published var matchResults: [ReleaseMatchResult] = []
    @Published private(set) var selectedRelease: MusicBrainzRelease?
    @Published private(set) var matchReview: ReleaseMatchReview?
    @Published var libraryMatchRun: LibraryMatchRun?
    var libraryMatchTask: Task<Void, Never>?
    var reviewCheckpointTask: Task<Void, Never>?
    var reviewCheckpointURL: URL?
    var currentLibraryReviewID: String?
    @Published var fingerprintRun: FingerprintRun?
    @Published var fingerprintSubmissionReview: FingerprintSubmissionReview?
    @Published var fingerprintSubmissionOutcomes: [UUID: String] = [:]
    @Published var fingerprintReviewScores: [UUID: Double] = [:]
    var verifiedRecordingMappings: [UUID: String] = [:]
    var fingerprintTask: Task<Void, Never>?
    @Published var fingerprintJobIsScheduled = false
    var fingerprintProviderOverride: (any AudioFingerprintProviding)?
    var acoustIDClientOverride: AcoustIDClient?
    var fingerprintCacheDirectory: URL?
    var fingerprintLedgerURL: URL?
    var submissionTokenOverride: String?
    @Published private(set) var scriptOutput = ""
    @Published var scriptSource = ""
    @Published var destinationDirectory: URL?
    @Published var organizationReview: OrganizationReview?
    @Published var organizationDirectory: URL?
    @Published var organizationNamingScript = LibraryImporter.defaultNamingScript
    @Published var organizationConflictPolicy = OrganizationConflictPolicy.stop
    @Published var organizationExcludedIDs = Set<UUID>()
    @Published var organizationError: String?
    @Published var isPreparingOrganization = false
    @Published var isExecutingOrganization = false
    var organizationFiles: [AudioFile] = []
    var organizationTargetsEntireLibrary = false
    var organizationEntireLibraryRequested = false
    var organizationWorkspaceID: UUID?
    var organizationLibraryRoot: URL?
    var organizationGeneration = UUID()

    var runtime: PicardRuntime?
    private var audioCoordinator: AudioFileCoordinator?
    var musicBrainzClient: MusicBrainzClient?
    var coverArtClient: CoverArtClient?
    private var saveCoordinator: AudioSaveCoordinator?
    let organizationCoordinator = FileOrganizationCoordinator()
    var sessionManager: SessionManager?
    var sessionCreatedAt = Date()
    var sessionSaveTask: Task<Void, Never>?
    private var autosaveTask: Task<Void, Never>?
    private var selectedReleaseFileIDs = Set<UUID>()
    private var reviewFiles: [AudioFile] = []
    private var lookupGeneration = UUID()
    private let lookupAudioEngine = FormatEngine()
    private var filesByID: [UUID: AudioFile] = [:]
    private var browserEntries: [UUID: BrowserEntry] = [:]
    var workspaceStore: WorkspaceStore?
    let playback = PlaybackController()
    let libraryScanner = LibraryScanner()
    let libraryImporter = LibraryImporter()
    var workspaceAccess: ScopedURLAccess?
    var importedAccess: [ScopedURLAccess] = []
    var accessBookmarkKeys: [String] = []
    var refreshTask: Task<Void, Never>?
    var libraryScanTask: Task<Void, Never>?
    var activeLibraryScan: Task<LibraryScanResult, Error>?

    init(musicBrainzClient: MusicBrainzClient? = nil, coverArtClient: CoverArtClient? = nil, audioCoordinator: AudioFileCoordinator? = nil) {
        self.musicBrainzClient = musicBrainzClient
        self.coverArtClient = coverArtClient
        self.audioCoordinator = audioCoordinator
        editUndoManager.groupsByEvent = false
        editUndoManager.levelsOfUndo = 80
    }

    private func rebuildBrowserIndex() {
        let changed = files.filter { filesByID[$0.id] != $0 }
        let incomingIDs = Set(files.map(\.id))
        let removed = Set(filesByID.keys).subtracting(incomingIDs)
        guard !changed.isEmpty || !removed.isEmpty else { return }
        let regroup = !removed.isEmpty || changed.contains { browserEntries[$0.id]?.grouping != BrowserEntry($0).grouping }
        filesByID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for id in removed { browserEntries.removeValue(forKey: id); matchingFileIDs.remove(id) }
        for file in changed { browserEntries[file.id] = BrowserEntry(file) }
        browserIndexUpdates += changed.count
        if regroup {
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
        }
        var matches = matchingFileIDs
        for file in changed {
            if matchesBrowser(file) { matches.insert(file.id) } else { matches.remove(file.id) }
        }
        if matches != matchingFileIDs { matchingFileIDs = matches }
        playback.updateTracks(files)
    }

    private func rebuildBrowserMatches() {
        matchingFileIDs = Set(files.filter { matchesBrowser($0) }.map(\.id))
    }

    func applyBrowserSearch() {
        appliedSearchQuery = searchQuery
        rebuildBrowserMatches()
        keepSelectionInSearchResults()
    }

    func indexedSearchMatches(_ id: UUID) -> Bool {
        let tokens = appliedSearchQuery.split(whereSeparator: \.isWhitespace).map(String.init)
        return tokens.allSatisfy { browserEntries[id]?.searchText.localizedStandardContains($0) == true }
    }

    private func keepSelectionInSearchResults() {
        let remaining = selectedFileIDs.intersection(matchingFileIDs)
        if remaining != selectedFileIDs { selectionChanged(remaining) }
    }

    var visibleFiles: [AudioFile] {
        let candidates: [AudioFile]
        if appliedSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let group = albumGroups.first(where: { $0.id == selectedAlbumID }) {
            candidates = group.fileIDs.compactMap { filesByID[$0] }
        } else {
            candidates = orderedAlbumGroups.flatMap { $0.fileIDs.compactMap { filesByID[$0] } }
        }
        return candidates.filter { matchingFileIDs.contains($0.id) && (selectedArtist == nil || BrowserEntry($0).artist == selectedArtist) }
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
        if matchReview != nil { return false }
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
        guard let first = selectedFiles.first?.metadata else { return false }
        return selectedFiles.contains {
            $0.metadata.values(for: key) != first.values(for: key)
                || $0.metadata.contains(key) != first.contains(key)
                || $0.metadata.isDeleted(key) != first.isDeleted(key)
        }
    }

    func bootstrap() async {
        guard snapshot == nil, !isLoading else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let runtime: PicardRuntime
            if let directory = ProcessInfo.processInfo.environment["MACPICARD_DATA_DIRECTORY"], directory.hasPrefix("/") {
                // Isolated runtime validation and portable development workspaces.
                runtime = PicardRuntime(paths: AppPaths(applicationSupportDirectory: URL(fileURLWithPath: directory, isDirectory: true)))
            } else { runtime = try PicardRuntime.live() }
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
            browserPreferencesURL = snapshot.paths.applicationSupportDirectory.appendingPathComponent("browser.json")
            loadBrowserPreferences()
            installConfiguration(snapshot.configuration)
            self.audioCoordinator = audio
            self.musicBrainzClient = musicBrainz
            self.coverArtClient = coverArt
            self.saveCoordinator = AudioSaveCoordinator(coordinator: audio)
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
        guard let audioCoordinator, !isBusy else { return }
        let isLibrary = activeWorkspace?.kind == .library
        let libraryRoot = libraryDirectory
        if isLibrary && libraryRoot == nil {
            errorMessage = "Reconnect the library folder before importing files."
            return
        }
        isWorking = true
        progress = 0
        errorMessage = nil
        var imported = 0
        var copied = 0
        var alreadyPresent = 0
        var cancelled = false
        var restoredPaths = Set<String>()
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
            if !isLibrary { try await rememberImportAccess(urls) }
        } catch { present(error); return }
        var knownPaths = Set(files.map { $0.url.resolvingSymlinksInPath().standardizedFileURL.path })
        var loadedFiles: [AudioFile] = []
        for (index, url) in expandedURLs.enumerated() {
            do {
                try Task.checkCancellation()
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let file: AudioFile
                if let libraryRoot {
                    statusMessage = "Copying and organizing \(url.lastPathComponent)…"
                    let result = try await libraryImporter.importFile(at: url, into: libraryRoot, existing: files + loadedFiles)
                    file = result.file
                    if result.copied { copied += 1 } else { alreadyPresent += 1 }
                    if let path = LibraryPaths.relativePath(of: file.url, in: libraryRoot) { restoredPaths.insert(path) }
                } else {
                    if knownPaths.contains(url.resolvingSymlinksInPath().standardizedFileURL.path) { continue }
                    statusMessage = "Importing \(url.lastPathComponent)…"
                    file = try await audioCoordinator.load(url: url)
                }
                if let existingIndex = files.firstIndex(where: { $0.id == file.id }) {
                    if files[existingIndex].url != file.url { imported += 1 }
                    files[existingIndex] = file
                } else if knownPaths.insert(file.url.resolvingSymlinksInPath().standardizedFileURL.path).inserted {
                    loadedFiles.append(file)
                    imported += 1
                }
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            progress = Double(index + 1) / Double(expandedURLs.count)
        }
        files.append(contentsOf: loadedFiles)
        if var workspace = activeWorkspace, isLibrary, !restoredPaths.isDisjoint(with: workspace.excludedRelativePaths) {
            workspace.excludedRelativePaths.subtract(restoredPaths)
            do {
                if let workspaceStore { workspaces = try await workspaceStore.update(workspace).workspaces }
            } catch { failures.append("Could not restore library items: \(error.localizedDescription)") }
        }
        if selectedAlbumID == nil {
            selectedAlbumID = albumGroups.first?.id
        }
        if selectedFileIDs.isEmpty {
            selectedFileIDs = Set(visibleFiles.prefix(1).map(\.id))
        }
        statusMessage = isLibrary
            ? "Copied \(copied) \(copied == 1 ? "file" : "files") into \(activeWorkspace?.name ?? "the library")."
            : "Imported \(imported) \(imported == 1 ? "file" : "files")."
        if alreadyPresent > 0 { statusMessage += " \(alreadyPresent) already in the library." }
        if !failures.isEmpty { statusMessage += " \(failures.count) failed." }
        if cancelled { statusMessage = "Import cancelled. " + statusMessage }
        if !failures.isEmpty {
            errorMessage = failures.prefix(3).joined(separator: "\n")
        }
        await saveSession()
    }

    func selectAlbum(_ group: AlbumGroup) {
        currentLibraryReviewID = nil
        searchQuery = ""
        applyBrowserSearch()
        selectedArtist = nil
        selectedAlbumID = group.id
        selectedFileIDs = Set(group.fileIDs).intersection(matchingFileIDs)
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        matchReview = nil
        reviewFiles.removeAll()
        lookupGeneration = UUID()
        scheduleSessionSave()
    }

    func selectAllVisible() {
        selectionChanged(Set(visibleFiles.map(\.id)))
    }

    func clearSelection() {
        selectedFileIDs.removeAll()
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        matchReview = nil
        reviewFiles.removeAll()
        lookupGeneration = UUID()
        scheduleSessionSave()
    }

    func resetWorkspaceSelection() {
        fingerprintTask?.cancel()
        fingerprintRun = nil; fingerprintSubmissionReview = nil; verifiedRecordingMappings.removeAll(); fingerprintReviewScores.removeAll()
        libraryMatchTask?.cancel()
        currentLibraryReviewID = nil
        cancelOrganizationReview()
        selectedFileIDs.removeAll()
        selectedAlbumID = nil
        selectedArtist = nil
        selectedRelease = nil
        selectedReleaseFileIDs.removeAll()
        matchReview = nil
        reviewFiles.removeAll()
        lookupGeneration = UUID()
        lookupResults.removeAll()
        matchResults.removeAll()
        searchQuery = ""
        browserFilter = .all
        expandedAlbumIDs.removeAll()
        destinationDirectory = nil
        libraryMatchRun = nil
    }

    /// Searches, resolves, and scores every album in the active library. The
    /// operation only creates proposals; it never changes metadata. The normal
    /// MusicBrainz client rate limiter and response cache remain in the path.
    func matchEntireLibrary(autoApplyThreshold requestedThreshold: Double? = nil) async {
        await runLibraryMatch(threshold: requestedThreshold ?? configuration.editing.matchThreshold)
    }

    func prepareLibraryProposalForReview(_ proposal: LibraryMatchProposal) {
        currentLibraryReviewID = proposal.id
        selectionChanged(Set(proposal.fileIDs))
        selectedAlbumID = proposal.id
        searchQuery = ""
    }

    @discardableResult
    func applyLibraryMatches(_ proposals: [LibraryMatchProposal]) -> Int {
        guard !isBusy else { return 0 }
        var edited = files
        let indices = Dictionary(uniqueKeysWithValues: edited.enumerated().map { ($0.element.id, $0.offset) })
        var applied = 0
        var verified: [UUID: String] = [:]
        do {
            for proposal in proposals {
                guard isEligibleLibraryProposal(proposal), let release = proposal.release, let result = proposal.result else { continue }
                let matches = result.trackMatches.filter { $0.decision != .ambiguous && $0.releaseTrackID != nil }
                for match in matches {
                    guard let fileIndex = indices[match.localTrackID],
                          let track = release.tracks.first(where: { $0.id == match.releaseTrackID }) else { continue }
                    guard let metadata = metadata(for: edited[fileIndex], release: release, track: track) else { continue }
                    try edited[fileIndex].updateMetadata(metadata)
                    if let recording = track.recordingID { verified[edited[fileIndex].id] = recording }
                    applied += 1
                }
            }
            commitStagedEdits(edited, action: "Apply library matches")
            verifiedRecordingMappings.merge(verified) { _, new in new }
            for proposal in proposals where isEligibleLibraryProposal(proposal, validateBaseline: false) { setProposalStatus(proposal.id, .applied) }
            statusMessage = "Applied metadata proposals to \(applied) files. Save Tags to write changes to disk."
            errorMessage = nil
            scheduleSessionSave()
        } catch {
            present(error)
        }
        return applied
    }

    func selectionChanged(_ ids: Set<UUID>) {
        if let currentLibraryReviewID, let proposal = libraryMatchRun?.proposals.first(where: { $0.id == currentLibraryReviewID }), Set(proposal.fileIDs) != ids { self.currentLibraryReviewID = nil }
        selectedFileIDs = ids
        if ids != selectedReleaseFileIDs {
            selectedRelease = nil
            selectedReleaseFileIDs.removeAll()
            matchReview = nil
            reviewFiles.removeAll()
            lookupGeneration = UUID()
        }
        scheduleSessionSave()
    }

    func setMetadata(_ key: String, value: String) { setTagValues([value], for: key) }

    func lookup(albumTitle: String? = nil, albumArtist: String? = nil) async {
        guard canLookupSelection else {
            statusMessage = "Select tracks from one album before looking up a release."
            return
        }
        guard let musicBrainzClient, let primary = primarySelectedFile else {
            statusMessage = "Select an album or track before looking up releases."
            return
        }

        var queryMetadata = primary.metadata
        if albumTitle != nil || albumArtist != nil {
            // Explicit search criteria must not be constrained/ranked by stale IDs.
            for key in ["barcode", "musicbrainz_albumid", "musicbrainz_releaseid", "musicbrainz_releasegroupid", "catalognumber", "label"] {
                queryMetadata.unset(key)
            }
        }
        if let albumTitle { queryMetadata.setValue(albumTitle, for: "album") }
        if let albumArtist { queryMetadata.setValue(albumArtist, for: "albumartist") }
        let local = LocalAlbumCandidate(metadata: queryMetadata, tracks: selectedFiles.map { Self.localCandidate($0) })
        guard local.albumTitle != nil || local.albumArtist != nil || local.barcode != nil else {
            statusMessage = "Add an album, artist, or barcode before searching MusicBrainz."
            return
        }

        isWorking = true
        cancelMatchReview()
        let generation = lookupGeneration
        let targets = selectedFileIDs
        lookupResults.removeAll(); matchResults.removeAll()
        errorMessage = nil
        statusMessage = "Searching MusicBrainz…"
        defer { isWorking = false }
        do {
            let results = try await musicBrainzClient.searchReleases(for: local)
            guard generation == lookupGeneration, targets == selectedFileIDs else { return }
            lookupResults = results
            matchResults = ReleaseMatcher(preferences: releaseMatchPreferences).rank(local: local, candidates: results)
            statusMessage = results.isEmpty ? "No matching releases found." : "Found \(results.count) releases."
        } catch {
            guard generation == lookupGeneration else { return }
            present(error)
        }
    }

    func chooseMatch(_ result: ReleaseMatchResult, recordingEvidence: [UUID: String] = [:]) async {
        guard let musicBrainzClient, canLookupSelection else { return }
        isWorking = true
        errorMessage = nil
        selectedRelease = nil
        selectedReleaseFileIDs = []
        matchReview = nil
        reviewFiles.removeAll()
        lookupGeneration = UUID()
        let generation = lookupGeneration
        statusMessage = "Loading release details…"
        defer { isWorking = false }
        do {
            let originals = selectedFiles
            let targets = Set(originals.map(\.id))
            let release = try await musicBrainzClient.lookupRelease(id: result.release.id)
            var candidates: [LocalTrackCandidate] = []
            for file in originals {
                var duration = file.durationInMilliseconds
                if duration == nil {
                    duration = try? await lookupAudioEngine.read(url: file.url).audioProperties?.lengthInMilliseconds
                }
                let local = Self.localCandidate(file, duration: duration)
                if let recording = recordingEvidence[file.id] {
                    candidates.append(LocalTrackCandidate(id: local.id, title: local.title, artist: local.artist,
                        durationInMilliseconds: local.durationInMilliseconds, trackNumber: local.trackNumber, discNumber: local.discNumber,
                        recordingID: recording, isrcs: local.isrcs))
                } else { candidates.append(local) }
            }
            guard generation == lookupGeneration, targets == selectedFileIDs,
                  originals.allSatisfy({ file(id: $0.id) == $0 }) else { return }
            let localTracks = candidates
            let review = try await Task.detached(priority: .userInitiated) {
                try ReleaseMatchReview(release: release, localTracks: localTracks)
            }.value
            guard generation == lookupGeneration, targets == selectedFileIDs,
                  originals.allSatisfy({ file(id: $0.id) == $0 }) else { return }
            selectedRelease = release
            selectedReleaseFileIDs = targets
            reviewFiles = originals
            matchReview = review
            statusMessage = "Review \(review.assignments.count) suggested matches for \(result.release.title)."
        } catch {
            guard generation == lookupGeneration else { return }
            present(error)
        }
    }

    var canApplyReleaseReview: Bool {
        guard !isBusy, let matchReview, !matchReview.assignments.isEmpty,
              selectedFileIDs == selectedReleaseFileIDs else { return false }
        return reviewFiles.allSatisfy { file(id: $0.id) == $0 }
    }

    func reviewFile(_ id: UUID) -> AudioFile? { reviewFiles.first { $0.id == id } }

    func assignReviewTrack(fileID: UUID, trackID: String?) {
        guard !isBusy, var review = matchReview else { return }
        do { try review.assign(fileID: fileID, trackID: trackID); matchReview = review }
        catch { present(error) }
    }

    func resetReviewAssignments(unmatchAll: Bool = false) {
        guard !isBusy, var review = matchReview else { return }
        if unmatchAll { review.unmatchAll() } else { review.resetToSuggestions() }
        matchReview = review
    }

    func cancelMatchReview() {
        fingerprintReviewScores.removeAll()
        lookupGeneration = UUID()
        selectedRelease = nil; selectedReleaseFileIDs.removeAll()
        matchReview = nil; reviewFiles.removeAll()
    }

    func reviewedMetadata(for fileID: UUID) -> Metadata? {
        guard let review = matchReview, let file = reviewFile(fileID),
              let remoteID = review.assignments[fileID], let track = review.release.tracks.first(where: { $0.id == remoteID }) else { return nil }
        return metadata(for: file, release: review.release, track: track)
    }

    private func metadata(for file: AudioFile, release: MusicBrainzRelease, track: MusicBrainzTrack) -> Metadata? {
        guard let medium = release.media.first(where: { $0.tracks.contains { $0.id == track.id } }) else { return nil }
        var metadata = file.metadata
        metadata.setValue(release.title, for: "album")
        metadata.setValue(release.artistCredit, for: "albumartist")
        for (key, value) in [("date", release.date), ("barcode", release.barcode), ("musicbrainz_releasegroupid", release.releaseGroupID),
                             ("label", release.labelNames.first), ("catalognumber", release.catalogNumbers.first)] {
            if let value { metadata.setValue(value, for: key) } else { metadata.unset(key) }
        }
        metadata.setValue(release.id, for: "musicbrainz_albumid")
        metadata.unset("musicbrainz_releaseid")
        metadata.setValue(track.title, for: "title")
        metadata.setValue(track.artistCredit.isEmpty ? release.artistCredit : track.artistCredit, for: "artist")
        metadata.setValue(track.number, for: "tracknumber")
        metadata.setValue(String(medium.tracks.count), for: "totaltracks")
        metadata.setValue(String(medium.position), for: "discnumber")
        metadata.setValue(String(release.media.count), for: "totaldiscs")
        metadata.setValue(track.id, for: "musicbrainz_releasetrackid")
        if let recording = track.recordingID { metadata.setValue(recording, for: "musicbrainz_trackid") }
        else { metadata.unset("musicbrainz_trackid") }
        metadata.unset("musicbrainz_recordingid")
        if track.isrcs.isEmpty { metadata.unset("isrc") } else { metadata.setValues(track.isrcs, for: "isrc") }
        for key in configuration.editing.preservedTags {
            if file.metadata.isDeleted(key) { metadata.delete(key) }
            else if file.metadata.contains(key) { metadata.setValues(file.metadata.values(for: key), for: key) }
            else { metadata.unset(key) }
        }
        return metadata
    }

    @discardableResult
    func applySelectedRelease() -> Bool {
        guard canApplyReleaseReview, let review = matchReview else {
            statusMessage = "Review track assignments first. If the files changed, reload the release."
            return false
        }
        var edited = files
        let indices = Dictionary(uniqueKeysWithValues: edited.enumerated().map { ($0.element.id, $0.offset) })
        do {
            for fileID in review.assignments.keys {
                guard let index = indices[fileID], let metadata = reviewedMetadata(for: fileID) else { return false }
                try edited[index].updateMetadata(metadata)
            }
        } catch { present(error); return false }
        commitStagedEdits(edited, action: "Apply reviewed matches")
        for (fileID, trackID) in review.assignments {
            if let recording = review.release.tracks.first(where: { $0.id == trackID })?.recordingID { verifiedRecordingMappings[fileID] = recording }
        }
        if let currentLibraryReviewID { setProposalStatus(currentLibraryReviewID, .applied) }
        statusMessage = "Applied reviewed metadata to \(review.assignments.count) files; \(review.unmatchedFileIDs.count) left unchanged. Save Tags to write to disk."
        errorMessage = nil
        cancelMatchReview()
        scheduleSessionSave()
        if configuration.automaticCoverArt && configuration.editing.embedImportedArtwork {
            let ids = selectedFileIDs
            Task { guard self.selectedFileIDs == ids else { return }; await self.downloadCoverArt() }
        }
        return true
    }

    static func localCandidate(_ file: AudioFile, duration: Int? = nil) -> LocalTrackCandidate {
        var metadata = file.metadata
        if metadata.firstValue(for: "title")?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            let name = file.url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: #"^\s*\d+\s*[-_. ]\s*"#, with: "", options: .regularExpression)
            if name.range(of: #"^(track|audio|untitled|unknown)([\s_-]*\d+)?$"#, options: [.regularExpression, .caseInsensitive]) == nil {
                metadata.setValue(name, for: "title")
            }
        }
        return LocalTrackCandidate(metadata: metadata, id: file.id, durationInMilliseconds: duration ?? file.durationInMilliseconds)
    }

    func canDiscardChanges(_ ids: Set<UUID>) -> Bool {
        let targets = contextFiles(ids).filter(\.isModified)
        return !isBusy && !targets.isEmpty && targets.allSatisfy {
            [.ready, .changed, .saved, .removed, .failed, .unsupported].contains($0.state)
        }
    }

    func discardChanges(_ ids: Set<UUID>, confirmed: Bool = false) async {
        guard confirmed, canDiscardChanges(ids) else { return }
        isWorking = true
        defer { isWorking = false }
        let previous = files
        var edited = previous
        var count = 0
        do {
            for index in edited.indices where ids.contains(edited[index].id) && edited[index].isModified {
                try edited[index].discardChanges(); count += 1
            }
        files = edited
            cancelMatchReview()
            try await flushSession()
            clearEditHistory()
            errorMessage = nil
            statusMessage = "Discarded pending tag and artwork changes for \(count) files. Audio files were not modified."
        } catch {
            files = previous
            statusMessage = "Discard could not be saved. Your pending edits were kept."
            present(error)
        }
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
        let targetVersions = selectedFiles
        let targetWorkspace = activeWorkspaceID
        defer { isWorking = false }
        do {
            let release = try await coverArtClient.release(identifier: releaseIdentifier)
            guard let image = release.images.first(where: { $0.types.contains(.front) }) ?? release.images.first else {
                statusMessage = "No cover art is available for this release."
                return
            }
            let artwork = try await coverArtClient.download(image, size: CoverArtImageSize(rawValue: configuration.editing.coverArtSize) ?? .thumbnail1200)
            guard activeWorkspaceID == targetWorkspace, targetVersions.allSatisfy({ self.file(id: $0.id) == $0 }) else {
                statusMessage = "Files changed while artwork was downloading. Download again to update them."; return
            }
            var edited = files
            for index in edited.indices where targets.contains(edited[index].id) {
                var collection = edited[index].artwork
                if configuration.editing.replaceFrontCover {
                    collection = ArtworkCollection(images: collection.images.filter { $0.type != .front })
                }
                collection.append(artwork)
                if let format = FormatRegistry.format(forExtension: edited[index].url.pathExtension) { try format.validateArtwork(collection) }
                try edited[index].updateArtwork(collection)
            }
            commitStagedEdits(edited, action: "Download artwork")
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
                    preserveModificationDate: configuration.preserveFileTimestamps
                ))
                saved.append(result)
            } catch { failures.append("\(file.url.lastPathComponent): \(error.localizedDescription)") }
            progress = Double(index + 1) / Double(targets.count)
        }
        if !saved.isEmpty { clearEditHistory() }
        replaceFiles(saved)
        statusMessage = "Saved \(saved.count) \(saved.count == 1 ? "file" : "files")."
        errorMessage = failures.isEmpty ? nil : failures.prefix(3).joined(separator: "\n")
        await saveSession()
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
                commitStagedEdits(edited, action: "Apply script")
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
        files = loaded.document.files.map(AudioFile.restore(from:)).filter { file in
            guard let directory = libraryDirectory,
                  let path = LibraryPaths.relativePath(of: file.url, in: directory) else { return true }
            return activeWorkspace?.excludedRelativePaths.contains(path) != true
        }
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

    func installConfiguration(_ value: AppConfiguration) {
        let previous = configuration
        configuration = value
        if let snapshot {
            self.snapshot = RuntimeSnapshot(paths: snapshot.paths, configuration: value, diagnostics: snapshot.diagnostics)
        }
        if organizationNamingScript == previous.editing.namingPattern || previous.editing.namingPattern != value.editing.namingPattern {
            organizationNamingScript = value.editing.namingPattern
        }
        if scriptSource == previous.editing.defaultTagScript || previous.editing.defaultTagScript != value.editing.defaultTagScript {
            scriptSource = value.editing.defaultTagScript
        }
        autosaveTask?.cancel()
        if value.autosaveEnabled { startAutosave(interval: value.autosaveIntervalSeconds) }
        restartLibraryMonitoring()
    }

    var releaseMatchPreferences: ReleaseMatchPreferences {
        ReleaseMatchPreferences(preferredCountries: configuration.preferredReleaseCountry.isEmpty ? [] : [configuration.preferredReleaseCountry])
    }

    private func saveRecovery() async {
        guard let sessionManager, !isExecutingOrganization else { return }
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
