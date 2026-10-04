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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("MusicBrainz · Find and Match", systemImage: "arrow.triangle.branch")
                    .font(.title3.weight(.semibold))
                Spacer()
                if model.isWorking { ProgressView().controlSize(.small) }
                Button(embedded ? "Close Comparison" : "Cancel") { model.cancelMatchReview(); finish() }
                    .keyboardShortcut(.cancelAction)
            }.padding(18)
            HStack(spacing: 10) {
                TextField("Album", text: $albumQuery).accessibilityLabel("Search album title")
                TextField("Artist", text: $artistQuery).accessibilityLabel("Search album artist")
                Button("Search", systemImage: "magnifyingglass", action: search)
                    .disabled(model.isBusy || (albumQuery.isEmpty && artistQuery.isEmpty))
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(search)
            .disabled(model.isBusy)
            .padding(.horizontal, 18).padding(.bottom, 14)
            HStack {
                TextField("MusicBrainz release URL or UUID", text: $releaseReference).textFieldStyle(.roundedBorder)
                Button("Load Release") { Task { await model.loadReleaseReference(releaseReference) } }.disabled(model.isBusy || releaseReference.isEmpty)
                if model.libraryMatchRun != nil {
                    Button("Review Next") { Task { await model.reviewNextLibraryProposal() } }.disabled(model.isBusy)
                    Button("Reject Proposal") { if let id = model.currentLibraryReviewID { model.setProposalStatus(id, .rejected); model.cancelMatchReview() } }.disabled(model.isBusy || model.currentLibraryReviewID == nil)
                }
            }.padding(.horizontal, 18).padding(.bottom, 10)
            Divider()
            HSplitView {
                ReleaseResultsView(model: model)
                    .frame(minWidth: 200, idealWidth: 230, maxWidth: 285)
                if let review = model.matchReview {
                    MatchReviewPane(model: model, review: review)
                        .frame(minWidth: 570, maxWidth: .infinity)
                } else if model.isWorking {
                    ProgressView(model.statusMessage).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("Choose a release", systemImage: "opticaldisc",
                        description: Text("Compare its tracks with your files before applying any changes. Missing and extra tracks are allowed."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.errorMessage ?? "Only assigned files change. Nothing is written to audio until Save Tags.")
                        .foregroundStyle(model.errorMessage == nil ? Color.secondary : .red)
                    if let review = model.matchReview, !model.canApplyReleaseReview, !review.assignments.isEmpty, !model.isBusy {
                        Text("Files changed since this review. Select the release again to reload it.").foregroundStyle(.orange)
                    }
                }.font(.caption).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Apply \(model.matchReview?.assignments.count ?? 0) Reviewed Matches") {
                    if model.applySelectedRelease() { if !embedded { finish() } }
                }.buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .disabled(!model.canApplyReleaseReview)
            }.padding(16)
        }
        .onAppear {
            albumQuery = model.primarySelectedFile?.metadata.firstValue(for: "album") ?? ""
            artistQuery = model.primarySelectedFile?.metadata.firstValue(for: "albumartist")
                ?? model.primarySelectedFile?.metadata.firstValue(for: "artist") ?? ""
        }
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
                .foregroundStyle(.secondary).padding(14)
            if model.matchResults.isEmpty {
                Text(model.isWorking ? "Searching…" : model.statusMessage)
                    .font(.callout).foregroundStyle(.secondary).padding(14)
                Spacer()
            } else {
                List(model.matchResults) { result in
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
                            Text(result.release.artistCredit).lineLimit(2)
                            Text("\(result.release.date ?? "Undated") · \(result.release.country ?? "Unknown country")")
                            Text("\(result.release.trackCount) tracks · \(result.release.mediaCount) discs")
                            Text("Release similarity \(result.score.total, format: .percent.precision(.fractionLength(0)))")
                                .foregroundStyle(.secondary)
                            Text(result.release.labelNames.joined(separator: ", ") + " · " + result.release.catalogNumbers.joined(separator: ", "))
                            DisclosureGroup("Score details") {
                                Text("Title \(Int(result.score.albumTitle * 100))% · Artist \(Int(result.score.artist * 100))% · Tracks \(Int(result.score.tracks * 100))% · Duration \(Int(result.score.duration * 100))% · Variant margin \(Int(result.margin * 100))%")
                            }
                        }.font(.caption).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(model.isBusy)
                }.listStyle(.inset)
            }
        }.background(.thinMaterial)
    }
}

private struct MatchReviewPane: View {
    @ObservedObject var model: AppModel
    let review: ReleaseMatchReview

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(review.release.title).font(.title2.weight(.semibold)).lineLimit(2)
                Text(review.release.artistCredit).foregroundStyle(.secondary)
                Text("\(review.release.country ?? "Unknown country") · \(review.release.date ?? "Undated") · \(review.release.labelNames.joined(separator: ", ")) · \(review.release.catalogNumbers.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Barcode: \(review.release.barcode ?? "Unavailable") · Artwork: \(review.release.coverArtAvailable.map { $0 ? "Available in archive" : "Not reported in archive" } ?? "Unknown")")
                    .font(.caption).foregroundStyle(.secondary)
                Link("Open release on MusicBrainz", destination: URL(string: "https://musicbrainz.org/release/\(review.release.id)")!).font(.caption)
                DisclosureGroup("Release identifiers") {
                    Text("Release: \(review.release.id)\nRelease group: \(review.release.releaseGroupID ?? "Unavailable")").font(.caption).textSelection(.enabled)
                }
                Text("Matching \(review.localTracks.count) selected files against \(review.release.tracks.count) release tracks")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Label("\(review.assignments.count) matched", systemImage: "checkmark.circle")
                    Label("\(review.unmatchedFileIDs.count) unassigned files", systemImage: "questionmark.circle")
                    Label("\(review.missingTracks.count) tracks without files", systemImage: "music.note.list")
                }.font(.caption)
                if review.needsReviewCount > 0 {
                    Label("\(review.needsReviewCount) uncertain suggestions need your choice.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack {
                    Text("Pick a track for each file. Choosing an occupied track swaps its pairing.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Suggestions") { model.resetReviewAssignments() }
                        .help("Replace manual mappings with the original confident suggestions.")
                    Button("Unmatch All") { model.resetReviewAssignments(unmatchAll: true) }
                }.controlSize(.small).disabled(model.isBusy)
            }.padding(18)
            Divider()
            HSplitView {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        Text("LOCAL FILE → MUSICBRAINZ TRACK").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(review.localTracks) { local in
                            if let file = model.reviewFile(local.id) {
                                LocalMatchRow(model: model, file: file, local: local, review: review)
                            }
                        }
                    }.padding(14)
                }.frame(minWidth: 350, maxWidth: .infinity)
                ReleaseTrackList(model: model, review: review)
                    .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)
            }
        }
    }
}

private struct LocalMatchRow: View {
    @ObservedObject var model: AppModel
    let file: AudioFile
    let local: LocalTrackCandidate
    let review: ReleaseMatchReview

    private var assigned: MusicBrainzTrack? {
        review.release.tracks.first { $0.id == review.assignments[file.id] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: assigned == nil ? "questionmark.circle" : "checkmark.circle")
                    .foregroundStyle(assigned == nil ? Color.secondary : Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(local.title.isEmpty ? file.url.lastPathComponent : local.title).fontWeight(.semibold).lineLimit(2)
                    Text("\(local.artist ?? "Unknown artist") · \(MatchReviewDisplay.duration(local.durationInMilliseconds))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Local disc \(local.discNumber.map(String.init) ?? "?") · track \(local.trackNumber.map(String.init) ?? "?")")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(file.url.lastPathComponent).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).help(file.url.path)
                }
                Spacer(minLength: 2)
            }
            Picker("Matched track", selection: Binding(
                get: { review.assignments[file.id] ?? "" },
                set: { model.assignReviewTrack(fileID: file.id, trackID: $0.isEmpty ? nil : $0) }
            )) {
                Text("Leave unmatched — keep tags unchanged").tag("")
                ForEach(review.release.media.sorted { $0.position < $1.position }) { medium in
                    ForEach(medium.tracks.sorted { $0.position < $1.position }) { track in
                        Text(MatchReviewDisplay.track(track, disc: medium.position, multiDisc: review.release.media.count > 1)).tag(track.id)
                    }
                }
            }.pickerStyle(.menu).labelsHidden().disabled(model.isBusy)
                .accessibilityLabel("MusicBrainz assignment for \(file.url.lastPathComponent)")
            if let assigned {
                if let confidence = model.fingerprintReviewScores[file.id] {
                    Text("Fingerprint confidence: \(confidence, format: .percent.precision(.fractionLength(0)))").font(.caption.weight(.medium))
                }
                let evidence = TrackMatcher().evidence(local: local, remote: assigned, disc: review.disc(for: assigned.id))
                Text("\(review.manualFileIDs.contains(file.id) ? "Manual match" : evidence.exact ? "Identifier match" : "Suggested match") · \(evidence.score, format: .percent.precision(.fractionLength(0))) similarity")
                    .font(.caption.weight(.medium)).foregroundStyle(.tint)
                Text(evidence.reasons.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(3)
                if let metadata = model.reviewedMetadata(for: file.id) {
                    let changes = metadata.difference(from: file.metadata).changes
                    DisclosureGroup("Preview \(changes.count) tag changes") {
                        VStack(alignment: .leading, spacing: 7) {
                            ForEach(changes) { change in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.key).font(.caption.weight(.semibold))
                                    Text("\(change.originalValues.isEmpty ? "—" : change.originalValues.joined(separator: "; ")) → \(change.currentValues.isEmpty ? "—" : change.currentValues.joined(separator: "; "))")
                                        .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                            }
                        }.padding(.top, 7)
                    }.font(.caption)
                }
            } else if let suggestion = review.suggestions.first(where: { $0.localTrackID == file.id }),
                      let remote = review.release.tracks.first(where: { $0.id == suggestion.releaseTrackID }) {
                HStack(alignment: .top) {
                    Text("Needs review: \(remote.title) · \(suggestion.score, format: .percent.precision(.fractionLength(0))) similarity")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    Button("Use Suggestion") { model.assignReviewTrack(fileID: file.id, trackID: remote.id) }
                        .controlSize(.small).disabled(model.isBusy)
                }
            } else {
                Text("No reliable suggestion. Choose a track or leave this file unchanged.").font(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
        .draggable("macpicard:file:\(file.id.uuidString)")
        .dropDestination(for: String.self) { values, _ in
            guard values.count == 1, values[0].hasPrefix("macpicard:track:\(review.release.id):") else { return false }
            let trackID = String(values[0].dropFirst("macpicard:track:\(review.release.id):".count))
            guard review.release.tracks.contains(where: { $0.id == trackID }) else { return false }
            model.assignReviewTrack(fileID: file.id, trackID: trackID); return true
        }
    }
}

private struct ReleaseTrackList: View {
    @ObservedObject var model: AppModel
    let review: ReleaseMatchReview

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("RELEASE ORDER").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(review.release.media.sorted { $0.position < $1.position }) { medium in
                    Text("Disc \(medium.position) · \(medium.format ?? "Audio")").font(.caption.weight(.semibold))
                    ForEach(medium.tracks.sorted { $0.position < $1.position }) { track in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(track.number). \(track.title)").font(.callout.weight(.medium)).lineLimit(2)
                            Text("\(track.artistCredit) · \(MatchReviewDisplay.duration(track.lengthInMilliseconds))")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            if let owner = review.assignments.first(where: { $0.value == track.id })?.key {
                                Label(model.reviewFile(owner)?.url.lastPathComponent ?? "Matched", systemImage: "checkmark")
                                    .font(.caption2).foregroundStyle(.tint).lineLimit(2)
                            } else {
                                Label("No local file", systemImage: "minus.circle").font(.caption2).foregroundStyle(.secondary)
                            }
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
                            .draggable("macpicard:track:\(review.release.id):\(track.id)")
                            .dropDestination(for: String.self) { values, _ in
                                guard values.count == 1, values[0].hasPrefix("macpicard:file:"), let id = UUID(uuidString: String(values[0].dropFirst("macpicard:file:".count))), review.localTracks.contains(where: { $0.id == id }) else { return false }
                                model.assignReviewTrack(fileID: id, trackID: track.id); return true
                            }
                    }
                }
            }.padding(14)
        }.background(.thinMaterial)
    }
}

private enum MatchReviewDisplay {
    static func duration(_ milliseconds: Int?) -> String {
        guard let milliseconds, milliseconds > 0 else { return "Length unknown" }
        let seconds = milliseconds / 1_000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func track(_ track: MusicBrainzTrack, disc: Int, multiDisc: Bool) -> String {
        "\(multiDisc ? "Disc \(disc) · " : "")\(track.number). \(track.title) · \(duration(track.lengthInMilliseconds))"
    }
}
