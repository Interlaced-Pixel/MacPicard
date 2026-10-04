import PicardMusicBrainz
import SwiftUI

struct LibraryMatchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var threshold = 0.85
    @State private var showOnlyReview = false

    private var run: AppModel.LibraryMatchRun? { model.libraryMatchRun }
    private var visibleProposals: [AppModel.LibraryMatchProposal] {
        guard let proposals = run?.proposals else { return [] }
        return showOnlyReview ? proposals.filter { $0.status == .review } : proposals
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
                    description: Text("MacPicard will search MusicBrainz album by album, score full-track assignments, stage high-confidence metadata, and leave uncertain albums for review.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .onAppear {
            if let existing = model.libraryMatchRun { threshold = existing.autoApplyThreshold }
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
                metric("Ready", value: run.highConfidence.count, color: .green)
                metric("Review", value: run.needsReview.count, color: .orange)
                metric("Unresolved", value: run.unresolved.count, color: .secondary)
                Spacer()
                Toggle("Review queue only", isOn: $showOnlyReview)
                    .toggleStyle(.checkbox)
            }
            Text("Only Ready proposals are eligible for the one-click batch apply. Review opens the normal track-by-track matcher for that album. Nothing is written to audio until Save Tags.")
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
                if proposal.status == .review {
                    Button("Review") {
                        model.prepareLibraryProposalForReview(proposal)
                        presentation.isShowingLibraryMatch = false
                        presentation.isShowingLookup = true
                        if let result = proposal.result { Task { await model.chooseMatch(result) } }
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.vertical, 4)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if run == nil {
                Text("Auto-apply threshold")
                    .font(.callout)
                Slider(value: $threshold, in: 0.60...0.95, step: 0.01)
                    .frame(width: 180)
                Text("\(Int(threshold * 100))%")
                    .font(.caption.monospacedDigit())
                    .frame(width: 36, alignment: .trailing)
            }
            Spacer()
            if let run {
                Button("Apply \(run.highConfidence.count) Ready Albums") {
                    model.applyLibraryMatches(run.highConfidence)
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .disabled(run.highConfidence.isEmpty || model.isBusy)
                Button("Run Again") { Task { await model.matchEntireLibrary(autoApplyThreshold: threshold) } }
                    .disabled(model.isBusy)
            } else {
                Button("Start Library Match") { Task { await model.matchEntireLibrary(autoApplyThreshold: threshold) } }
                    .buttonStyle(.glassProminent)
                    .disabled(model.isBusy)
            }
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
        }
    }

    private func color(for status: AppModel.LibraryMatchProposalStatus) -> Color {
        switch status {
        case .matched: .green
        case .review: .orange
        case .noMatch: .secondary
        case .failed: .red
        }
    }
}
