import AVFoundation
import Combine
import Foundation
import PicardFoundation

struct PlaybackTrack: Equatable, Sendable {
    let fileID: UUID
    let url: URL
    let title: String
    let artist: String
    let artwork: Artwork?

    init(_ file: AudioFile) {
        fileID = file.id
        url = file.url
        title = file.metadata.firstValue(for: "title") ?? file.url.deletingPathExtension().lastPathComponent
        artist = file.metadata.firstValue(for: "artist") ?? "Unknown artist"
        artwork = file.artwork.first(of: .front)
    }
}

struct PlaybackQueueEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    var track: PlaybackTrack
    init(track: PlaybackTrack) { id = UUID(); self.track = track }
}

enum PlaybackState: Equatable { case idle, loading, playing, paused, ended, failed }

/// A local, audio-only AVPlayer. Playback never mutates an AudioFile or writes to disk.
@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var queue: [PlaybackQueueEntry] = []
    @Published private(set) var currentEntryID: UUID?
    @Published private(set) var state = PlaybackState.idle
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var wantsPlayback = false
    @Published var volume: Double {
        didSet { player.volume = Float(min(max(volume, 0), 1)) }
    }

    private let player = AVPlayer()
    private var loadingTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    private var completionObservation: PlaybackCompletionObservation?
    private var fileAccess: PlaybackFileAccess?
    private var requestID = UUID()
    private var loadingStartedAt: Date?
    private var lastAudibleVolume = 0.65

    init(volume: Double = 0.65) {
        self.volume = min(max(volume, 0), 1)
        player.volume = Float(self.volume)
        player.automaticallyWaitsToMinimizeStalling = true
        monitoringTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                self.pollPlayer()
            }
        }
    }

    deinit { loadingTask?.cancel(); monitoringTask?.cancel() }

    var currentIndex: Int? { queue.firstIndex { $0.id == currentEntryID } }
    var currentTrack: PlaybackTrack? { currentIndex.map { queue[$0].track } }
    var isPlaying: Bool { state == .playing }
    var transportIsActive: Bool { wantsPlayback && (state == .playing || state == .loading) }
    var indicatorSymbol: String {
        switch state {
        case .loading: "hourglass"
        case .playing: "speaker.wave.2.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "pause.circle.fill"
        }
    }
    var statusDescription: String {
        switch state {
        case .idle: "Ready to play"
        case .loading: "Loading audio"
        case .playing: "Now playing"
        case .paused: "Playback paused"
        case .ended: "Playback finished"
        case .failed: "Playback error"
        }
    }
    var canGoNext: Bool { currentIndex.map { $0 + 1 < queue.count } ?? false }
    var canGoPrevious: Bool { elapsed > 0 || (currentIndex ?? 0) > 0 }
    var outputRate: Float { player.rate }
    var remainingCount: Int { currentIndex.map { max(queue.count - $0 - 1, 0) } ?? queue.count }

    func play(_ tracks: [PlaybackTrack], startingAt fileID: UUID? = nil) {
        guard !tracks.isEmpty else { return }
        unload()
        queue = tracks.map(PlaybackQueueEntry.init(track:))
        let index = fileID.flatMap { id in queue.firstIndex { $0.track.fileID == id } } ?? 0
        load(queue[index], autoplay: true)
    }

    func enqueue(_ tracks: [PlaybackTrack], next: Bool = false) {
        guard !tracks.isEmpty else { return }
        let entries = tracks.map(PlaybackQueueEntry.init(track:))
        if queue.isEmpty {
            queue = entries
            currentEntryID = entries[0].id
            state = .idle
        } else if next {
            queue.insert(contentsOf: entries, at: min((currentIndex ?? -1) + 1, queue.count))
        } else { queue.append(contentsOf: entries) }
    }

    func playEntry(_ id: UUID) {
        guard let entry = queue.first(where: { $0.id == id }) else { return }
        load(entry, autoplay: true)
    }

    func togglePlayPause() {
        guard let index = currentIndex else { return }
        if state == .playing || (state == .loading && wantsPlayback) {
            wantsPlayback = false
            player.pause()
            if player.currentItem?.status == .readyToPlay { state = .paused }
        } else if player.currentItem?.status == .readyToPlay, state != .failed {
            if state == .ended { seek(to: 0) }
            wantsPlayback = true
            player.play()
            state = .playing
        } else if state == .loading {
            wantsPlayback = true
        } else { load(queue[index], autoplay: true) }
    }

    func pause() {
        wantsPlayback = false
        player.pause()
        if state == .playing { state = .paused }
    }

    func stop(clearQueue: Bool = false) {
        unload()
        elapsed = 0
        duration = 0
        state = .idle
        errorMessage = nil
        if clearQueue { queue = []; currentEntryID = nil }
    }

    func next() {
        guard let index = currentIndex, index + 1 < queue.count else { return }
        load(queue[index + 1], autoplay: wantsPlayback || state == .ended)
    }

    func previous() {
        if elapsed > 3, player.currentItem != nil { seek(to: 0); return }
        guard let index = currentIndex else { return }
        if index > 0 { load(queue[index - 1], autoplay: wantsPlayback) }
        else { seek(to: 0) }
    }

    func seek(to seconds: Double) {
        guard duration > 0, seconds.isFinite, player.currentItem?.status == .readyToPlay else { return }
        let target = min(max(seconds, 0), duration)
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if state == .ended { state = .paused }
    }

    func toggleMute() {
        if volume > 0 { lastAudibleVolume = volume; volume = 0 }
        else { volume = lastAudibleVolume }
    }

    func removeEntry(_ id: UUID) {
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let wasCurrent = currentEntryID == id
        let resume = wantsPlayback
        if wasCurrent { unload() }
        queue.remove(at: index)
        if queue.isEmpty { stop(clearQueue: true) }
        else if wasCurrent {
            let replacement = queue[min(index, queue.count - 1)]
            currentEntryID = replacement.id
            state = .idle
            elapsed = 0
            duration = 0
            if resume { load(replacement, autoplay: true) }
        }
    }

    func updateTracks(_ files: [AudioFile]) {
        guard !queue.isEmpty else { return }
        let byID = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let updated = queue.map { entry in
            var entry = entry
            if let file = byID[entry.track.fileID] { entry.track = PlaybackTrack(file) }
            return entry
        }
        if queue != updated { queue = updated }
    }

    private func load(_ entry: PlaybackQueueEntry, autoplay: Bool) {
        unload()
        currentEntryID = entry.id
        elapsed = 0
        duration = 0
        state = .loading
        wantsPlayback = autoplay
        errorMessage = nil
        loadingStartedAt = Date()
        let request = requestID
        fileAccess = PlaybackFileAccess(url: entry.track.url)
        loadingTask = Task { @MainActor [weak self] in
            do {
                guard entry.track.url.isFileURL, FileManager.default.isReadableFile(atPath: entry.track.url.path) else {
                    throw PlaybackError.unavailable(entry.track.url.lastPathComponent)
                }
                let asset = AVURLAsset(url: entry.track.url)
                let (playable, time) = try await asset.load(.isPlayable, .duration)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                try Task.checkCancellation()
                guard playable, !tracks.isEmpty,
                      time.seconds.isFinite, time.seconds > 0 else {
                    throw PlaybackError.unsupported(entry.track.url.lastPathComponent)
                }
                guard let self, self.requestID == request else { return }
                self.duration = time.seconds
                let item = AVPlayerItem(asset: asset)
                self.completionObservation = PlaybackCompletionObservation(item: item) { [weak self] in
                    Task { @MainActor in self?.finished(request: request) }
                }
                self.player.replaceCurrentItem(with: item)
                if self.wantsPlayback { self.player.play() }
            } catch is CancellationError {
                // Superseded requests cannot change the new track's state.
            } catch {
                guard let self, self.requestID == request else { return }
                self.fail(error.localizedDescription)
            }
        }
    }

    private func pollPlayer() {
        guard let item = player.currentItem else {
            if state == .loading, let start = loadingStartedAt, Date().timeIntervalSince(start) > 30 {
                fail("Audio loading timed out. Try playing this track again.")
            }
            return
        }
        if item.status == .failed {
            fail(item.error?.localizedDescription ?? "The audio decoder could not play this file.")
            return
        }
        if item.status == .readyToPlay {
            let time = player.currentTime().seconds
            if time.isFinite { elapsed = min(max(time, 0), duration) }
            if state == .loading { state = wantsPlayback ? .playing : .paused }
        } else if let start = loadingStartedAt, Date().timeIntervalSince(start) > 30 {
            fail("Audio loading timed out. Try playing this track again.")
        }
    }

    private func finished(request: UUID) {
        guard requestID == request, wantsPlayback else { return }
        if canGoNext { next() }
        else {
            player.pause()
            elapsed = duration
            state = .ended
            wantsPlayback = false
        }
    }

    private func fail(_ message: String) {
        unload()
        state = .failed
        errorMessage = message
    }

    private func unload() {
        requestID = UUID()
        loadingTask?.cancel()
        loadingTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        completionObservation = nil
        fileAccess = nil
        wantsPlayback = false
        loadingStartedAt = nil
    }
}

private enum PlaybackError: LocalizedError {
    case unavailable(String), unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unavailable(let name): "\(name) is unavailable. Reconnect its folder or refresh the library."
        case .unsupported(let name): "macOS could not decode audio in \(name). The file may be damaged or protected."
        }
    }
}

/// Immutable lifetime tokens; Foundation's observer removal and scoped URL access are thread-safe.
private final class PlaybackCompletionObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(item: AVPlayerItem, completion: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                       object: item, queue: .main) { _ in completion() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}

private final class PlaybackFileAccess {
    private let url: URL
    private let accessing: Bool
    init(url: URL) { self.url = url; accessing = url.startAccessingSecurityScopedResource() }
    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}
