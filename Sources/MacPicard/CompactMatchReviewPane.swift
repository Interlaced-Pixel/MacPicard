import PicardFoundation
import PicardMusicBrainz
import SwiftUI

struct CompactMatchReviewPane: View {
    @ObservedObject var model: AppModel
    let review: ReleaseMatchReview
    @State private var selectedID: UUID?
    @State private var showsTracks = false
    @State private var showsReleaseDetails = false
    @State private var filter = ""
    @State private var unassignedOnly = false
    init(model: AppModel, review: ReleaseMatchReview, focusedFileID: UUID? = nil, showsReleaseTracks: Bool = false) {
        self.model = model
        self.review = review
        _selectedID = State(initialValue: focusedFileID)
        _showsTracks = State(initialValue: showsReleaseTracks)
    }
    private var rows: [LocalTrackCandidate] {
        review.localTracks.filter { local in
            (!unassignedOnly || review.assignments[local.id] == nil)
                && (filter.isEmpty || local.title.localizedCaseInsensitiveContains(filter)
                    || model.reviewFile(local.id)?.url.lastPathComponent.localizedCaseInsensitiveContains(filter)
                        == true)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(review.assignments.count) matched").font(.caption)
                Toggle("Unmatched (\(review.unmatchedFileIDs.count))", isOn: $unassignedOnly).toggleStyle(.button).help(
                    "Show files without a track assignment")
                Button { showsTracks.toggle() } label: {
                    Label("\(review.missingTracks.count) missing", systemImage: "music.note.list")
                }
                    .help(
                        "\(showsTracks ? "Hide" : "Show") release order · \(review.missingTracks.count) tracks without files"
                    )
                Spacer(minLength: 0)
                TextField("Filter files", text: $filter).textFieldStyle(.roundedBorder).frame(
                    minWidth: 65, idealWidth: 100, maxWidth: 120)
                Button {
                    showsReleaseDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                }
                .help("Release details").accessibilityLabel("Release details")
                .popover(isPresented: $showsReleaseDetails) { releaseDetails }
                Menu {
                    Button("Reset Matches") { model.resetReviewAssignments() }
                    Button("Unmatch All") { model.resetReviewAssignments(unmatchAll: true) }
                } label: {
                    Image(systemName: "ellipsis")
                }.menuIndicator(.hidden).accessibilityLabel("Assignment options").disabled(model.isBusy)
            }.controlSize(.small).buttonStyle(.bordered).padding(.horizontal, 10).padding(.vertical, 7)
            HSplitView {
                GeometryReader { geometry in
                    let columnWidth = max(80, (geometry.size.width - 124) / 2)
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            Text("Local File").frame(width: columnWidth, alignment: .leading)
                            Text("MusicBrainz Track").frame(width: columnWidth, alignment: .leading)
                            Text("Match").frame(width: 46)
                            Text("Tags").frame(width: 24)
                        }.font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(
                            .vertical, 5)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(rows) { local in
                                    if let file = model.reviewFile(local.id) {
                                        fileRow(file, local: local, columnWidth: columnWidth)
                                        Divider()
                                    }
                                }
                                if rows.isEmpty {
                                    Text("No files match this filter.").foregroundStyle(.secondary).padding(20)
                                }
                            }
                        }
                    }
                }.frame(minWidth: 440, maxWidth: .infinity)
                if showsTracks {
                    ReleaseTrackList(model: model, review: review).frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
                }
            }.frame(maxHeight: .infinity)
            if let selectedID, let file = model.reviewFile(selectedID) {
                Divider()
                changes(for: file).frame(height: 165)
            }
        }.background(MusicBrainzTheme.surface)
            .onChange(of: review.release.id) { _, _ in selectedID = nil }
    }
    private func fileRow(_ file: AudioFile, local: LocalTrackCandidate, columnWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(local.title.isEmpty ? file.url.lastPathComponent : local.title).fontWeight(.medium).lineLimit(1)
                Text("\(file.url.lastPathComponent) · \(MatchReviewDisplay.duration(local.durationInMilliseconds))")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.frame(width: columnWidth, alignment: .leading).help(file.url.path)
            Picker(
                "Matched track",
                selection: Binding(
                    get: { review.assignments[file.id] ?? "" },
                    set: { model.assignReviewTrack(fileID: file.id, trackID: $0.isEmpty ? nil : $0) })
            ) {
                Text("Unmatched").tag("")
                ForEach(review.release.media.sorted { $0.position < $1.position }) { medium in
                    ForEach(medium.tracks.sorted { $0.position < $1.position }) { track in
                        Text(
                            MatchReviewDisplay.track(
                                track, disc: medium.position, multiDisc: review.release.media.count > 1)
                        ).tag(track.id)
                    }
                }
            }.pickerStyle(.menu).labelsHidden().lineLimit(1).truncationMode(.tail)
                .frame(width: columnWidth, alignment: .leading).clipped()
                .disabled(model.isBusy).accessibilityLabel("Track for \(file.url.lastPathComponent)")
                .help(
                    review.release.tracks.first(where: { $0.id == review.assignments[file.id] })?.title ?? "Unmatched")
            Group {
                if let track = review.release.tracks.first(where: { $0.id == review.assignments[file.id] }) {
                    let evidence = TrackMatcher().evidence(
                        local: local, remote: track, disc: review.disc(for: track.id))
                    Text(evidence.score, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(
                            evidence.score < model.configuration.editing.matchThreshold ? MusicBrainzTheme.orange : .secondary
                        ).help(evidence.reasons.joined(separator: "\n"))
                } else {
                    Text("—").foregroundStyle(.secondary)
                }
            }.font(.caption.monospacedDigit()).frame(width: 46)
            Button {
                selectedID = selectedID == file.id ? nil : file.id
            } label: {
                Image(systemName: selectedID == file.id ? "chevron.up" : "slider.horizontal.3")
            }
            .buttonStyle(.borderless).help("Tag changes and match details").accessibilityLabel(
                "Changes for \(file.url.lastPathComponent)"
            ).frame(width: 24)
        }.font(.callout).controlSize(.small).padding(.horizontal, 12).padding(.vertical, 7)
            .background(selectedID == file.id ? MusicBrainzTheme.purple.opacity(0.08) : .clear)
            .draggable("macpicard:file:\(file.id.uuidString)")
            .dropDestination(for: String.self) { values, _ in
                guard !model.isBusy, values.count == 1, values[0].hasPrefix("macpicard:track:\(review.release.id):")
                else { return false }
                let id = String(values[0].dropFirst("macpicard:track:\(review.release.id):".count))
                guard review.release.tracks.contains(where: { $0.id == id }) else { return false }
                model.assignReviewTrack(fileID: file.id, trackID: id)
                return true
            }
    }
    private func changes(for file: AudioFile) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(file.url.lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                Spacer()
                Button {
                    selectedID = nil
                } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(.borderless).accessibilityLabel("Hide tag changes")
            }
            if let id = review.assignments[file.id], let track = review.release.tracks.first(where: { $0.id == id }),
                let metadata = model.reviewedMetadata(for: file.id),
                let local = review.localTracks.first(where: { $0.id == file.id })
            {
                let evidence = TrackMatcher().evidence(local: local, remote: track, disc: review.disc(for: id))
                Text(
                    "\(review.manualFileIDs.contains(file.id) ? "Manual match" : evidence.exact ? "Identifier match" : "Suggested match") · \(evidence.reasons.joined(separator: " · "))"
                ).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                if let confidence = model.fingerprintReviewScores[file.id] {
                    Text("Fingerprint: \(confidence, format: .percent.precision(.fractionLength(0)))").font(.caption2)
                }
                let changes = metadata.difference(from: file.metadata).changes
                if changes.isEmpty {
                    Text("Tags already match.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Tag").frame(width: 120, alignment: .leading)
                                Text("Current").frame(maxWidth: .infinity, alignment: .leading)
                                Text("MusicBrainz").frame(maxWidth: .infinity, alignment: .leading)
                            }.fontWeight(.medium)
                            ForEach(changes) { change in
                                HStack(alignment: .top) {
                                    Text(change.key).frame(width: 120, alignment: .leading)
                                    Text(
                                        change.originalValues.isEmpty
                                            ? "—" : change.originalValues.joined(separator: "; ")
                                    ).frame(maxWidth: .infinity, alignment: .leading)
                                    Text(
                                        change.currentValues.isEmpty
                                            ? "—" : change.currentValues.joined(separator: "; ")
                                    ).frame(maxWidth: .infinity, alignment: .leading)
                                }.textSelection(.enabled)
                            }
                        }.font(.caption)
                    }
                }
            } else if let suggestion = review.suggestions.first(where: { $0.localTrackID == file.id }),
                let track = review.release.tracks.first(where: { $0.id == suggestion.releaseTrackID })
            {
                HStack {
                    Text(
                        "Suggested: \(track.title) · \(suggestion.score, format: .percent.precision(.fractionLength(0)))"
                    ).font(.caption)
                    Button("Use Match") { model.assignReviewTrack(fileID: file.id, trackID: track.id) }.disabled(
                        model.isBusy)
                }
            } else {
                Text("Choose a track, or leave this file unmatched to keep its tags.").font(.caption).foregroundStyle(
                    .secondary)
            }
            Spacer(minLength: 0)
        }.padding(10)
    }
    private var releaseDetails: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(review.release.title).font(.headline)
                Text(review.release.artistCredit)
                Text(
                    [
                        review.release.country, review.release.date, review.release.labelNames.joined(separator: ", "),
                        review.release.catalogNumbers.joined(separator: ", "),
                    ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                Text("Barcode: \(review.release.barcode ?? "—")")
                Text(
                    "Artwork: \(review.release.coverArtAvailable.map { $0 ? "Available" : "Not listed" } ?? "Unknown")")
                Text("Release: \(review.release.id)\nRelease group: \(review.release.releaseGroupID ?? "—")")
                    .textSelection(.enabled)
                Link("MusicBrainz", destination: URL(string: "https://musicbrainz.org/release/\(review.release.id)")!)
            }.font(.caption).padding(14)
        }.frame(width: 360, height: 250)
    }
}
