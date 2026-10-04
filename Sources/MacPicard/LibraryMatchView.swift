import PicardMusicBrainz
import SwiftUI

struct LibraryMatchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var threshold = 0.85
    @State private var proposalFilter = "All"

    private var run: AppModel.LibraryMatchRun? { model.libraryMatchRun }
    private var visibleProposals: [AppModel.LibraryMatchProposal] {
        guard let proposals = run?.proposals else { return [] }
        return proposals.filter { proposal in
            switch proposalFilter {
            case "Ready": return model.isEligibleLibraryProposal(proposal)
            case "Review": return proposal.status == .review
            case "Unresolved": return [.noMatch, .failed].contains(proposal.status)
            case "Rejected": return proposal.status == .rejected
            case "Stale": return !proposal.baselines.allSatisfy { $0.matches(model.file(id: $0.id)) }
            default: return true
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let run {
                summary(run)
                Divider()
                proposalList(visibleProposals)
            } else if model.isWorking {
                ProgressView(value: model.progress) {
                    Text(model.statusMessage)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(40)
            } else {
                ContentUnavailableView(
                    "Match your entire library",
                    systemImage: "wand.and.stars",
                    description: Text("Search MusicBrainz for each album, then review the matches before applying tags.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear {
            threshold = model.configuration.editing.matchThreshold
            if let existing = model.libraryMatchRun { threshold = existing.autoApplyThreshold }
        }
        .task {
            await model.restoreReviewCheckpoint()
            if let run = model.libraryMatchRun { threshold = run.autoApplyThreshold }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Label("Match Entire Library", systemImage: "wand.and.stars")
                .font(.title3.weight(.semibold))
            Spacer()
            if model.isWorking { ProgressView().controlSize(.small) }
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(18)
    }

    private func summary(_ run: AppModel.LibraryMatchRun) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                metric("Ready", value: run.highConfidence.count, color: MusicBrainzTheme.success)
                metric("Review", value: run.needsReview.count, color: MusicBrainzTheme.orange)
                metric("Unresolved", value: run.unresolved.count, color: .secondary)
                Spacer()
                Picker("Results", selection: $proposalFilter) {
                    ForEach(["All", "Ready", "Review", "Unresolved", "Rejected", "Stale"], id: \.self) { Text($0).tag($0) }
                }.frame(width: 180)
            }
            Text("Apply Ready albums together, or review an album’s track matches. Save writes the applied tags to audio.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private func metric(_ label: String, value: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value, format: .number)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func proposalList(_ proposals: [AppModel.LibraryMatchProposal]) -> some View {
        List(proposals) { proposal in
            HStack(spacing: 12) {
                Image(systemName: symbol(for: proposal.status))
                    .foregroundStyle(color(for: proposal.status))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.albumTitle).font(.headline)
                    Text(proposal.artist).font(.caption).foregroundStyle(.secondary)
                    if let result = proposal.result {
                        Text("\(result.release.title) · \(proposal.trackMatchCount)/\(proposal.fileIDs.count) tracks · \(Int(proposal.score * 100))%")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let error = proposal.errorMessage {
                        Text(error).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Text(proposal.status.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(color(for: proposal.status))
                if ![.rejected, .applied].contains(proposal.status) {
                    Button("Review") {
                        model.prepareLibraryProposalForReview(proposal)
                        presentation.isShowingLibraryMatch = false
                        presentation.isShowingLookup = true
                        Task { if let result = proposal.result { await model.chooseMatch(result) } else { await model.lookup() } }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                    Button("Reject") { model.setProposalStatus(proposal.id, .rejected) }.disabled(model.isBusy)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if run == nil {
                Text("Ready threshold")
                    .font(.callout)
                Slider(value: $threshold, in: 0.60...0.95, step: 0.01)
                    .frame(width: 180)
                Text("\(Int(threshold * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            Spacer()
            if let run {
                let eligible = run.highConfidence.filter { model.isEligibleLibraryProposal($0) }
                Button("Apply \(eligible.count) Ready Albums") {
                    model.applyLibraryMatches(eligible)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill)
                .disabled(eligible.isEmpty || model.isBusy)
                Button("Resume") { model.startLibraryMatch(threshold: threshold, resume: true) }.disabled(model.isBusy)
                    .help("Continue unfinished albums and recheck stale matches")
                Button("Run Again") { model.startLibraryMatch(threshold: threshold) }
                    .disabled(model.isBusy)
            } else {
                Button("Start Library Match") { model.startLibraryMatch(threshold: threshold) }
                    .buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill)
                    .disabled(model.isBusy)
            }
            if model.isWorking { Button("Stop Search") { model.cancelLibraryMatch() } }
            Button("Cancel") { dismiss() }
        }
        .padding(16)
    }

    private func symbol(for status: AppModel.LibraryMatchProposalStatus) -> String {
        switch status {
        case .matched: "checkmark.circle.fill"
        case .review: "exclamationmark.triangle.fill"
        case .noMatch: "questionmark.circle"
        case .failed: "xmark.circle.fill"
        case .rejected: "hand.raised.fill"
        case .applied: "checkmark.seal.fill"
        }
    }

    private func color(for status: AppModel.LibraryMatchProposalStatus) -> Color {
        switch status {
        case .matched: MusicBrainzTheme.success
        case .review: MusicBrainzTheme.orange
        case .noMatch: .secondary
        case .failed: MusicBrainzTheme.error
        case .rejected, .applied: .secondary
        }
    }
}
