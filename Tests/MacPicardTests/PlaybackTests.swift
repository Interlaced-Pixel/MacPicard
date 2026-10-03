import Foundation
import PicardFoundation
import XCTest
@testable import MacPicard

final class PlaybackTests: XCTestCase {
    @MainActor
    func testNativePlaybackDecodesEverySupportedFormat() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let formats = [("mp3", "libmp3lame"), ("flac", "flac"), ("m4a", "aac"),
                       ("ogg", "vorbis"), ("opus", "libopus"), ("wav", "pcm_s16le")]
        let playback = PlaybackController(volume: 0)
        defer { playback.stop(clearQueue: true) }
        for (extensionName, codec) in formats {
            let file = try fixture(root: root, extensionName: extensionName, codec: codec, seconds: 1.5)
            playback.play([PlaybackTrack(file)])
            try await waitUntil { playback.state == .playing || playback.state == .failed }
            XCTAssertEqual(playback.state, .playing, "\(extensionName): \(playback.errorMessage ?? "")")
            XCTAssertGreaterThan(playback.duration, 1)
            try await waitUntil { playback.elapsed > 0.15 || playback.state == .failed }
            XCTAssertGreaterThan(playback.elapsed, 0.15, "The native decoder must actually advance for \(extensionName)")
            XCTAssertGreaterThan(playback.outputRate, 0)
            playback.stop(clearQueue: true)
        }
    }

    @MainActor
    func testPauseSeekVolumeStopAndRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try fixture(root: root, seconds: 2)
        let playback = PlaybackController(volume: 0)
        defer { playback.stop(clearQueue: true) }
        playback.play([PlaybackTrack(file)])
        playback.pause()
        try await waitUntil { playback.state == .paused }
        XCTAssertEqual(playback.elapsed, 0, accuracy: 0.01, "Pausing during loading must prevent autoplay")
        playback.togglePlayPause()
        try await waitUntil { playback.state == .playing }
        playback.pause()
        XCTAssertEqual(playback.state, .paused)
        XCTAssertEqual(playback.outputRate, 0)
        playback.seek(to: 1)
        try await waitUntil { abs(playback.elapsed - 1) < 0.15 }
        playback.seek(to: .infinity)
        XCTAssertTrue(playback.elapsed.isFinite)
        playback.volume = 0.3
        playback.toggleMute()
        XCTAssertEqual(playback.volume, 0)
        playback.toggleMute()
        XCTAssertEqual(playback.volume, 0.3, accuracy: 0.001)
        playback.volume = 0
        playback.stop()
        XCTAssertEqual(playback.elapsed, 0)
        XCTAssertEqual(playback.state, .idle)
        XCTAssertEqual(playback.queue.count, 1)
        playback.togglePlayPause()
        try await waitUntil { playback.state == .playing }
    }

    @MainActor
    func testQueueOrderingCompletionAndDuplicateEntries() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture(root: root, name: "first", seconds: 0.5)
        let second = try fixture(root: root, name: "second", seconds: 0.5)
        let third = try fixture(root: root, name: "third", seconds: 0.5)
        let playback = PlaybackController(volume: 0)
        defer { playback.stop(clearQueue: true) }
        playback.play([PlaybackTrack(first), PlaybackTrack(third)])
        playback.enqueue([PlaybackTrack(second)], next: true)
        XCTAssertEqual(playback.queue.map(\.track.fileID), [first.id, second.id, third.id])
        try await waitUntil { playback.currentTrack?.fileID == second.id }
        try await waitUntil { playback.currentTrack?.fileID == third.id }
        try await waitUntil { playback.state == .ended }
        playback.enqueue([PlaybackTrack(third)])
        XCTAssertEqual(Set(playback.queue.map(\.id)).count, 4, "Repeated songs need distinct queue identities")
        playback.next()
        try await waitUntil { playback.state == .playing }
        playback.removeEntry(try XCTUnwrap(playback.currentEntryID))
        XCTAssertEqual(playback.queue.count, 3)
        playback.stop(clearQueue: true)
        XCTAssertNil(playback.currentTrack)
        XCTAssertTrue(playback.queue.isEmpty)
    }

    @MainActor
    func testMissingFileAndRapidReplacementDoNotLeaveStalePlayback() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = AudioFile(url: root.appendingPathComponent("missing.mp3"))
        let good = try fixture(root: root, seconds: 1.5)
        let playback = PlaybackController(volume: 0)
        defer { playback.stop(clearQueue: true) }
        playback.play([PlaybackTrack(missing)])
        try await waitUntil { playback.state == .failed }
        XCTAssertNotNil(playback.errorMessage)
        playback.play([PlaybackTrack(missing)])
        playback.play([PlaybackTrack(good)])
        try await waitUntil { playback.state == .playing }
        XCTAssertEqual(playback.currentTrack?.fileID, good.id)
        XCTAssertNil(playback.errorMessage)
        playback.stop(clearQueue: true)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(playback.state, .idle)
        XCTAssertEqual(playback.outputRate, 0)
    }

    @MainActor
    func testContextActionsUseClickedTrackAndKeepAlbumPlaybackOrdered() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try fixture(root: root, name: "first", seconds: 1.5, track: "1")
        let second = try fixture(root: root, name: "second", seconds: 1.5, track: "2")
        let third = try fixture(root: root, name: "third", seconds: 1.5, track: "3")
        let model = AppModel()
        defer { model.playback.stop(clearQueue: true); model.sessionSaveTask?.cancel() }
        model.playback.volume = 0
        model.files = [third, second, first]
        model.selectionChanged([first.id, second.id])
        XCTAssertEqual(model.contextFileIDs(for: second.id), [first.id, second.id])
        XCTAssertEqual(model.contextFileIDs(for: third.id), [third.id])
        model.playTrack(second.id)
        XCTAssertEqual(model.playback.currentTrack?.fileID, second.id, "Play must use the clicked song, not the first selection")
        XCTAssertEqual(model.playback.queue.map(\.track.fileID), [first.id, second.id, third.id])
        XCTAssertEqual(model.selectedFileIDs, [first.id, second.id], "Playing must not change the editing selection")
        model.playback.stop(clearQueue: true)
        model.enqueueTracks([second.id, first.id], next: false)
        XCTAssertEqual(model.playback.queue.map(\.track.fileID), [first.id, second.id])
        XCTAssertEqual(model.playback.state, .idle, "Adding to an empty queue must not play unexpectedly")
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 8) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { XCTFail("Playback timed out"); throw TestError.timeout }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacPicard-playback-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func fixture(root: URL, name: String = "track", extensionName: String = "wav",
                         codec: String = "pcm_s16le", seconds: Double, track: String = "1") throws -> AudioFile {
        let url = root.appendingPathComponent("\(name).\(extensionName)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                             "anullsrc=r=48000:cl=stereo", "-t", String(seconds), "-c:a", codec, "-strict", "-2", url.path]
        process.standardOutput = Pipe(); process.standardError = Pipe()
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestError.fixture }
        var file = AudioFile(url: url)
        try file.beginLoading()
        try file.finishLoading(metadata: Metadata(fields: ["title": [name], "artist": ["Test Artist"],
                                                          "album": ["Test Album"], "tracknumber": [track]]),
                               identity: AudioFileIdentity.capture(url: url))
        return file
    }

    private enum TestError: Error { case timeout, fixture }
}
