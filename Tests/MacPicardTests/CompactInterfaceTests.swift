import AppKit
import PicardFoundation
import PicardMusicBrainz
import SwiftUI
import XCTest

@testable import MacPicard

final class CompactInterfaceTests: XCTestCase {
    @MainActor func testCompactComparisonAndWorkspaceRenderWithoutChangingFiles() async throws {
        let releaseID = "11111111-1111-1111-1111-111111111111"
        func title(_ number: Int) -> String {
            number == 2
                ? "A Long Track Title With Several Collaborators (Extended Anniversary Remix, Part Two)"
                : "Song \(number)"
        }
        let tracks: [[String: Any]] = (1...14).map { number in
            [
                "id": "track-\(number)", "position": number, "number": String(number), "title": title(number),
                "length": 180000,
                "artist-credit": [["name": "Fixture Artist"]], "recording": ["id": "recording-\(number)"],
            ]
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "id": releaseID, "title": "An Album With a Long Name", "artist-credit": [["name": "Fixture Artist"]],
            "date": "2024-01-01", "country": "GB", "media": [["position": 1, "tracks": tracks]],
        ])
        let client = MusicBrainzClient(
            userAgent: "InterfaceTests/1.0", transport: CompactTransport(payload: payload),
            minimumRequestInterval: .zero)
        let model = AppModel(musicBrainzClient: client)
        for number in 1...12 {
            var file = AudioFile(url: URL(fileURLWithPath: "/tmp/Compact-\(UUID())/\(number) - \(title(number)).flac"))
            try file.beginLoading()
            try file.finishLoading(
                metadata: Metadata(fields: [
                    "title": [title(number)], "artist": ["Fixture Artist"], "album": ["An Album With a Long Name"],
                    "tracknumber": [String(number)], "musicbrainz_albumid": [releaseID],
                ]),
                identity: AudioFileIdentity(
                    resourceIdentifier: nil, byteCount: 1, modificationDate: nil, prefixHash: "render"),
                durationInMilliseconds: 180000)
            model.files.append(file)
        }
        model.selectionChanged(Set(model.files.map(\.id)))
        defer {
            model.sessionSaveTask?.cancel()
            model.searchTask?.cancel()
        }
        let original = model.files
        await model.loadReleaseReference(releaseID)
        XCTAssertEqual(model.files, original)
        XCTAssertEqual(model.matchReview?.localTracks.count, 12)
        XCTAssertEqual(model.matchReview?.missingTracks.count, 2)
        XCTAssertTrue(model.canApplyReleaseReview)
        for comparison in [false, true] {
            for dark in [false, true] {
                let presentation = AppPresentation()
                presentation.showsMatchComparison = comparison
                let size = NSSize(width: 1180, height: 760)
                let view = NSHostingView(
                    rootView: ContentView(model: model, presentation: presentation).preferredColorScheme(
                        dark ? .dark : .light))
                let window = NSWindow(
                    contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                    defer: false)
                window.contentView = view
                view.frame = NSRect(origin: .zero, size: size)
                try await Task.sleep(for: .milliseconds(250))
                view.layoutSubtreeIfNeeded()
                view.displayIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                XCTAssertGreaterThan(png.count, 5000)
                if let path = ProcessInfo.processInfo.environment["MACPICARD_COMPACT_RENDER_OUTPUT"] {
                    try png.write(
                        to: URL(
                            fileURLWithPath:
                                "\(path)-\(comparison ? "comparison" : "workspace")-\(dark ? "dark" : "light").png"))
                }
                XCTAssertEqual(model.files, original)
                window.contentView = nil
                // Closing a comparison intentionally drops its transient review.
                if comparison { await model.loadReleaseReference(releaseID) }
            }
        }
        for dark in [false, true] {
            let review = try XCTUnwrap(model.matchReview)
            let size = NSSize(width: 720, height: 500)
            let view = NSHostingView(
                rootView: CompactMatchReviewPane(
                    model: model, review: review, focusedFileID: original[0].id, showsReleaseTracks: true
                ).tint(.primary).accentColor(MusicBrainzTheme.purple).preferredColorScheme(dark ? .dark : .light))
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered,
                defer: false)
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            try await Task.sleep(for: .milliseconds(250))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(png.count, 5000)
            if let path = ProcessInfo.processInfo.environment["MACPICARD_COMPACT_RENDER_OUTPUT"] {
                try png.write(to: URL(fileURLWithPath: "\(path)-details-\(dark ? "dark" : "light").png"))
            }
            XCTAssertEqual(model.files, original)
            XCTAssertEqual(model.matchReview?.assignments, review.assignments)
            window.contentView = nil
        }
    }
    func testIconBackgroundIsTransparentAndNoteIsOpaque() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let image = try XCTUnwrap(
            NSImage(contentsOf: root.appendingPathComponent("Sources/MacPicard/Resources/AppIcon.png")))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        XCTAssertTrue(rep.hasAlpha)
        for (x, y) in [
            (0, 0), (rep.pixelsWide - 1, 0), (0, rep.pixelsHigh - 1), (rep.pixelsWide - 1, rep.pixelsHigh - 1),
        ] { XCTAssertEqual(rep.colorAt(x: x, y: y)?.alphaComponent, 0) }
        let centerNote = try XCTUnwrap(rep.colorAt(x: rep.pixelsWide * 53 / 100, y: rep.pixelsHigh * 39 / 100))
        XCTAssertGreaterThan(centerNote.alphaComponent, 0.99)
        let rgb = try XCTUnwrap(centerNote.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(rgb.redComponent, 0.95)
        XCTAssertGreaterThan(rgb.greenComponent, 0.95)
        XCTAssertGreaterThan(rgb.blueComponent, 0.95)
    }
}

private struct CompactTransport: MusicBrainzTransport {
    let payload: Data
    func data(for request: URLRequest) async throws -> MusicBrainzHTTPResponse {
        MusicBrainzHTTPResponse(statusCode: 200, data: payload)
    }
}
