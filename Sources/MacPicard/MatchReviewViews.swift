import PicardFoundation
import PicardMusicBrainz
import SwiftUI

struct LookupView: View {
    @ObservedObject var model: AppModel
    var embedded = false
    var close: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var albumQuery = ""
    @State private var artistQuery = ""
    @State private var releaseReference = ""
    @State private var showsReference = false
    @State private var showsReleases = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Match Tracks").font(.headline)
                TextField("Album", text: $albumQuery).accessibilityLabel("Album to search")
                TextField("Artist", text: $artistQuery).accessibilityLabel("Artist to search")
                Button("Search", systemImage: "magnifyingglass", action: search).disabled(
                    model.isBusy || (albumQuery.isEmpty && artistQuery.isEmpty))
                Button {
                    showsReference.toggle()
                } label: {
                    Image(systemName: "link")
                }.help("Load a MusicBrainz release URL or ID").accessibilityLabel("Load release by URL or ID")
                if model.isWorking { ProgressView().controlSize(.small) }
                Button {
                    model.cancelMatchReview()
                    finish()
                } label: {
                    Image(systemName: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .help("Close matching").accessibilityLabel("Close matching")
            }.textFieldStyle(.roundedBorder).buttonStyle(.bordered).controlSize(.small)
                .onSubmit(search).padding(.horizontal, 12).padding(.vertical, 9)
            if showsReference {
                HStack {
                    TextField("MusicBrainz release URL or ID", text: $releaseReference).textFieldStyle(.roundedBorder)
                    Button("Load") { Task { await model.loadReleaseReference(releaseReference) } }.disabled(
                        model.isBusy || releaseReference.isEmpty)
                }.controlSize(.small).padding(.horizontal, 12).padding(.bottom, 8)
            }
            HStack(spacing: 10) {
                if !model.matchResults.isEmpty {
                    Button {
                        showsReleases.toggle()
                    } label: {
                        Label("Releases (\(model.matchResults.count))", systemImage: "sidebar.left")
                    }.help("Show search results")
                }
                if let review = model.matchReview {
                    Text(review.release.title).fontWeight(.medium).lineLimit(1)
                    Text(review.release.artistCredit).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.libraryMatchRun != nil {
                    Button("Next Album") { Task { await model.reviewNextLibraryProposal() } }.disabled(model.isBusy)
                    Button("Reject Album") {
                        if let id = model.currentLibraryReviewID {
                            model.setProposalStatus(id, .rejected)
                            model.cancelMatchReview()
                        }
                    }.disabled(model.isBusy || model.currentLibraryReviewID == nil)
                }
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 6)
            Divider()
            HSplitView {
                if showsReleases {
                    ReleaseResultsView(model: model).frame(minWidth: 180, idealWidth: 205, maxWidth: 235)
                }
                if let review = model.matchReview {
                    CompactMatchReviewPane(model: model, review: review).frame(minWidth: 480, maxWidth: .infinity)
                } else if model.isWorking {
                    ProgressView(model.statusMessage).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView(
                        "Select a release", systemImage: "opticaldisc",
                        description: Text("Search by album and artist, or load a release URL.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.errorMessage ?? "Applies tags to matched files. Save writes them to audio.")
                        .foregroundStyle(model.errorMessage == nil ? Color.secondary : .red)
                    if let review = model.matchReview, !model.canApplyReleaseReview, !review.assignments.isEmpty,
                        !model.isBusy
                    {
                        Text("Files changed. Reload this release before applying.").foregroundStyle(.orange)
                    }
                }.font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Apply to \(model.matchReview?.assignments.count ?? 0) Files") {
                    if model.applySelectedRelease() { if !embedded { finish() } }
                }.buttonStyle(.borderedProminent).tint(MusicBrainzTheme.purple)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.canApplyReleaseReview)
            }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
        }
        .onAppear {
            albumQuery = model.primarySelectedFile?.metadata.firstValue(for: "album") ?? ""
            artistQuery =
                model.primarySelectedFile?.metadata.firstValue(for: "albumartist")
                ?? model.primarySelectedFile?.metadata.firstValue(for: "artist") ?? ""
            showsReleases = model.matchResults.count > 1
        }
        .onChange(of: model.matchResults.count) { _, count in showsReleases = count > 1 }
        .onDisappear { model.cancelMatchReview() }
    }

    private func search() {
        guard !model.isBusy else { return }
        Task { await model.lookup(albumTitle: albumQuery, albumArtist: artistQuery) }
    }
    private func finish() { if let close { close() } else { dismiss() } }
}

private struct ReleaseResultsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RELEASES · \(model.matchResults.count)").font(.caption.weight(.semibold))
                .foregroundStyle(.secondary).padding(10)
            if model.matchResults.isEmpty {
                Text(model.isWorking ? "Searching…" : model.statusMessage)
                    .font(.callout).foregroundStyle(.secondary).padding(14)
                Spacer()
            } else {
                List(model.matchResults) { result in
                    VStack(alignment: .leading, spacing: 3) {
                        Button {
                            Task { await model.chooseMatch(result) }
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .top) {
                                    Text(result.release.title).fontWeight(.semibold).lineLimit(2)
                                    Spacer(minLength: 4)
                                    if model.selectedRelease?.id == result.release.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                                    }
                                }
                                Text(result.release.artistCredit).lineLimit(1)
                                Text("\(result.release.date ?? "Undated") · \(result.release.country ?? "—")")
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Text("\(result.release.trackCount) tracks · \(result.release.mediaCount) discs")
                                    Spacer(minLength: 0)
                                    Text(result.score.total, format: .percent.precision(.fractionLength(0)))
                                        .monospacedDigit()
                                }.foregroundStyle(.secondary)
                            }.font(.caption).padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(model.isBusy)
                        DisclosureGroup("Match details") {
                            Text(
                                [
                                    result.release.labelNames.joined(separator: ", "),
                                    result.release.catalogNumbers.joined(separator: ", "),
                                ].filter { !$0.isEmpty }.joined(separator: " · "))
                            Text(
                                "Title \(Int(result.score.albumTitle * 100))% · Artist \(Int(result.score.artist * 100))% · Tracks \(Int(result.score.tracks * 100))% · Duration \(Int(result.score.duration * 100))% · Variant margin \(Int(result.margin * 100))%"
                            )
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }.listStyle(.inset)
            }
        }.background(.thinMaterial)
    }
}

struct ReleaseTrackList: View {
    @ObservedObject var model: AppModel
    let review: ReleaseMatchReview

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
                Text("RELEASE ORDER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(review.release.media.sorted { $0.position < $1.position }) { medium in
                    Text("Disc \(medium.position) · \(medium.format ?? "Audio")").font(.caption.weight(.semibold))
                    ForEach(medium.tracks.sorted { $0.position < $1.position }) { track in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(track.number). \(track.title)").font(.callout.weight(.medium)).lineLimit(2)
                            Text("\(track.artistCredit) · \(MatchReviewDisplay.duration(track.lengthInMilliseconds))")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            if let owner = review.assignments.first(where: { $0.value == track.id })?.key {
                                Label(
                                    model.reviewFile(owner)?.url.lastPathComponent ?? "Matched",
                                    systemImage: "checkmark"
                                )
                                .font(.caption2).foregroundStyle(.tint).lineLimit(2)
                            } else {
                                Label("No local file", systemImage: "minus.circle").font(.caption2).foregroundStyle(
                                    .secondary)
                            }
                        }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
                            .draggable("macpicard:track:\(review.release.id):\(track.id)")
                            .dropDestination(for: String.self) { values, _ in
                                guard values.count == 1, values[0].hasPrefix("macpicard:file:"),
                                    let id = UUID(uuidString: String(values[0].dropFirst("macpicard:file:".count))),
                                    review.localTracks.contains(where: { $0.id == id })
                                else { return false }
                                model.assignReviewTrack(fileID: id, trackID: track.id)
                                return true
                            }
                    }
                }
            }.padding(8)
        }.background(.thinMaterial)
    }
}

enum MatchReviewDisplay {
    static func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds, milliseconds > 0 else { return "Length unknown" }
        let seconds = milliseconds / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func track(_ track: MusicBrainzTrack, disc: Int, multiDisc: Bool) -> String {
        "\(multiDisc ? "Disc \(disc) · " : "")\(track.number). \(track.title) · \(duration(track.lengthInMilliseconds))"
    }
}
