import SwiftUI

struct FingerprintResultsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(model.fingerprintRun?.identifying == true ? "Identify Audio" : "Local Fingerprints", systemImage: "waveform").font(.title2.weight(.semibold))
                Spacer()
                if model.isBusy { Button("Cancel Operation") { model.cancelFingerprintOperation() } }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Text("No tags change during scanning. Choose a candidate to review its assignment and tag differences before applying.").font(.callout).foregroundStyle(.secondary)
            if let progress = model.progress { ProgressView(value: progress) }
            if let error = model.errorMessage { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.fingerprintRun?.results ?? []) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.baseline.url.lastPathComponent).font(.headline)
                            if let error = item.error { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                            else if let fingerprint = item.fingerprint {
                                Text("Fingerprint generated · \(fingerprint.durationInSeconds, format: .number.precision(.fractionLength(1))) seconds").font(.caption).foregroundStyle(.secondary)
                                if model.fingerprintRun?.identifying == true && item.candidates.isEmpty { Text("No recording candidates found. Try a manual MusicBrainz lookup.").foregroundStyle(.secondary) }
                                ForEach(item.candidates) { candidate in
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(candidate.release.title + " — " + candidate.release.artistCredit).fontWeight(.medium)
                                            Text("Fingerprint: \(candidate.fingerprintConfidence, format: .percent.precision(.fractionLength(0))) · Release: \(candidate.result.score.total, format: .percent.precision(.fractionLength(0)))").font(.caption)
                                            if let track = candidate.result.trackMatches.first {
                                                Text("Track confidence: \(track.score, format: .percent.precision(.fractionLength(0))) · \(candidate.release.country ?? "Unknown country") · \(candidate.release.date ?? "Undated")").font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Button("Review Candidate") {
                                            Task {
                                                if await model.reviewFingerprintCandidate(fileID: item.id, candidateID: candidate.id) {
                                                    presentation.showsMatchComparison = true; dismiss()
                                                }
                                            }
                                        }.disabled(model.isBusy || !item.baseline.matches(model.file(id: item.id)))
                                    }.padding(10).background(.quaternary, in: .rect(cornerRadius: 10))
                                }
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
                    }
                    if model.fingerprintRun?.results.isEmpty != false {
                        ContentUnavailableView("No completed fingerprints", systemImage: "waveform", description: Text("Select audio, then identify it online or generate fingerprints offline. Everything needed is built into MacPicard."))
                    }
                }
            }
            HStack {
                Button("Generate Selected Offline") { model.startFingerprintScan(identify: false) }.disabled(model.isBusy || model.selectedFiles.isEmpty)
                Button("Scan Selected") { model.startFingerprintScan() }.disabled(model.isBusy || model.selectedFiles.isEmpty)
                Spacer()
                Text(model.statusMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }.padding(24).frame(minWidth: 800, idealWidth: 900, minHeight: 540, idealHeight: 650)
    }
}

struct FingerprintSubmissionView: View {
    @ObservedObject var model: AppModel
    let review: FingerprintSubmissionReview
    @Environment(\.dismiss) private var dismiss
    @State private var consent = false
    @State private var attempted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submit Verified AcoustIDs").font(.title2.weight(.semibold))
            Text("This batch sends fingerprints, durations, and MusicBrainz recording IDs to AcoustID. Audio files are not uploaded. Only explicitly approved current mappings are eligible.").foregroundStyle(.secondary)
            List(review.items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.baseline.url.lastPathComponent).fontWeight(.medium)
                    Text(item.recordingID).font(.caption.monospaced()).textSelection(.enabled)
                    Text("\(item.fingerprint.durationInSeconds, format: .number.precision(.fractionLength(1))) seconds · \(model.fingerprintSubmissionOutcomes[item.id] ?? "Not sent")").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 5)
            }
            Toggle("I verified these recording mappings and consent to send this batch to AcoustID.", isOn: $consent).disabled(attempted)
            Text("Submissions are journaled before sending. Accepted or uncertain attempts are never automatically resent. An uncertain result needs service-side verification, not another click.").font(.caption).foregroundStyle(.secondary)
            if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Close") { dismiss() }.disabled(model.isBusy).keyboardShortcut(.cancelAction)
                Spacer()
                if model.isBusy { Button("Cancel Remaining") { model.cancelFingerprintOperation() }; ProgressView().controlSize(.small) }
                Button("Submit \(review.items.count) Verified Fingerprints") {
                    attempted = true
                    model.fingerprintTask = Task { await model.submitReviewedFingerprints(reviewID: review.id, consent: consent) }
                }.disabled(!consent || attempted || model.isBusy).buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 780, height: 590).interactiveDismissDisabled(model.isBusy)
    }
}
