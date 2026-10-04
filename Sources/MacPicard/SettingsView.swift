import PicardFoundation
import PicardFingerprint
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppConfiguration()
    @State private var section = SectionName.general
    @State private var error: String?
    @State private var saving = false
    @State private var testingTool = false
    @State private var toolResult: String?
    @State private var credentials: [ServiceCredential: String] = [:]
    @State private var editingCredentials = false
    @State private var loadingCredentials = false

    private enum SectionName: String, CaseIterable, Identifiable {
        case general = "General", libraries = "Libraries", matching = "Matching"
        case metadata = "Metadata & Saving", artwork = "Artwork", naming = "Naming"
        case fingerprinting = "Fingerprinting", scripts = "Scripts", appearance = "Appearance"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            Divider()
            HSplitView {
                List(SectionName.allCases, selection: $section) { item in Text(item.rawValue).tag(item) }
                    .frame(minWidth: 175, idealWidth: 195, maxWidth: 220)
                    .accessibilityLabel("Settings sections")
                Form { settingsContent }.formStyle(.grouped)
                    .frame(minWidth: 430, maxWidth: .infinity)
            }
            Divider()
            HStack {
                Button("Restore Defaults") { draft = AppConfiguration(); toolResult = nil }
                Text(error ?? (draft == model.configuration ? "No changes" : "Unsaved settings"))
                    .font(.caption).foregroundStyle(error == nil ? Color.secondary : .red)
                    .textSelection(.enabled)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save") { save() }.buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill).keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || saving || loadingCredentials)
            }.padding(16)
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear { draft = model.configuration }
    }

    @ViewBuilder private var settingsContent: some View {
        switch section {
        case .general:
            Section("Workspace recovery") {
                Toggle("Write periodic recovery snapshots", isOn: $draft.autosaveEnabled)
                Stepper("Recovery every \(draft.autosaveIntervalSeconds) seconds", value: $draft.autosaveIntervalSeconds, in: 15...3600, step: 15)
                    .disabled(!draft.autosaveEnabled)
                Text("Edits are saved to your library or session automatically. Periodic backups add recovery points without writing audio tags.").font(.caption)
            }
        case .libraries:
            Section("Background monitoring") {
                Toggle("Enable monitoring for new libraries", isOn: $draft.editing.newLibrariesMonitorAutomatically)
                Stepper("Fallback check: every \(draft.editing.monitoringIntervalSeconds / 60) minutes", value: $draft.editing.monitoringIntervalSeconds, in: 60...3600, step: 60)
                Text("Folder changes are checked in the background. Checks wait during playback, pending edits and other work. Refresh checks now; the fallback catches missed notifications.").font(.caption)
                if model.activeWorkspace?.kind == .library {
                    Text("Current library: \(model.activeWorkspace?.name ?? "")")
                }
            }
        case .matching:
            Section("Release matching") {
                TextField("Preferred country (e.g. US)", text: $draft.preferredReleaseCountry)
                Text("Leave country empty for no regional preference.").font(.caption)
                Slider(value: $draft.editing.matchThreshold, in: 0.60...0.95, step: 0.01) {
                    Text("Ready threshold: \(Int((draft.editing.matchThreshold * 100).rounded()))%")
                }
                Text("Ambiguous or incomplete matches need review, regardless of score.").font(.caption)
            }
        case .metadata:
            Section("Tag preservation") {
                TextField("Preserve tags (comma separated)", text: Binding(
                    get: { draft.editing.preservedTags.joined(separator: ", ") },
                    set: { draft.editing.preservedTags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty } }
                ))
                Text("MusicBrainz matching will not replace these tags. You can still edit them manually or with scripts.").font(.caption)
            }
            Section("Saving") {
                Toggle("Preserve file modification timestamps", isOn: $draft.preserveFileTimestamps)
                Text("Save Tags writes changes to audio after checking for external edits. Save Workspace only saves the library or session.").font(.caption)
            }
        case .artwork:
            Section("Cover Art Archive") {
                Toggle("Download artwork after applying reviewed album matches", isOn: $draft.automaticCoverArt)
                Picker("Download size", selection: $draft.editing.coverArtSize) {
                    Text("250 pixels").tag("250"); Text("500 pixels").tag("500")
                    Text("1200 pixels").tag("1200"); Text("Original").tag("original")
                }
                Toggle("Replace existing front cover", isOn: $draft.editing.replaceFrontCover)
                Text("When replacement is off, the downloaded cover is appended. Artwork is staged until Save Tags.").font(.caption)
            }
            Section("Artwork manager defaults") {
                Toggle("Embed imported artwork on Save Tags", isOn: $draft.editing.embedImportedArtwork)
                TextField("Conversion maximum side (pixels)", value: $draft.editing.artworkMaximumPixels, format: .number)
                Picker("Conversion format", selection: $draft.editing.artworkOutputFormat) {
                    Text("Keep format").tag("preserve"); Text("JPEG").tag("jpeg"); Text("PNG").tag("png")
                }
                Slider(value: $draft.editing.artworkJPEGQuality, in: 0.1...1) { Text("JPEG quality") }
                Text("Convert images in Manage Artwork. Export-only mode leaves audio unchanged. Review export paths before saving; existing files are never overwritten.").font(.caption)
            }
        case .naming:
            Section("Default organization pattern") {
                TextEditor(text: $draft.editing.namingPattern).font(.system(.body, design: .monospaced)).frame(minHeight: 125)
                    .accessibilityLabel("Default naming pattern")
                Text("Used for Organize previews. Import continues to use the standard library layout. Naming patterns do not run tag-editing scripts.").font(.caption)
            }
        case .fingerprinting:
            Section("Built-in fingerprinting") {
                Label("Chromaprint is included with MacPicard", systemImage: "checkmark.seal.fill")
                Button(testingTool ? "Checking…" : "Check Built-in Calculator") { checkTool() }.disabled(testingTool)
                if let toolResult { Text(toolResult).font(.caption).textSelection(.enabled) }
                Text("Generate Fingerprints works offline. Scan uses AcoustID and MusicBrainz to identify audio. Both are ready to use; no extra setup is needed.").font(.caption)
                if (try? AcoustIDApplicationConfiguration.applicationKey()) == nil {
                    Label("Identification service configuration is missing in this build. Contact Interlaced Pixel.", systemImage: "exclamationmark.triangle").font(.caption)
                }
            }
            Section("Optional AcoustID contributions") {
                Text("Identification does not require an account. Only contributing new fingerprints requires your personal AcoustID submission token and explicit consent for each batch.").font(.caption)
                if editingCredentials {
                    SecureField("User submission token", text: Binding(get: { credentials[.submissionToken] ?? "" }, set: { credentials[.submissionToken] = $0 }))
                    Text("Saved only in Keychain. An empty field removes the token. This is never required to scan, match, or organize music.").font(.caption)
                    Link("Manage your AcoustID account", destination: URL(string: "https://acoustid.org/api-key")!)
                } else {
                    Button(loadingCredentials ? "Loading…" : "Manage Submission Token…") {
                        loadingCredentials = true
                        Task {
                            defer { loadingCredentials = false }
                            do { credentials = try await model.savedCredentials(); editingCredentials = true }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(loadingCredentials)
                }
            }
        case .scripts:
            Section("Default tagging script") {
                TextEditor(text: $draft.editing.defaultTagScript).font(.system(.body, design: .monospaced)).frame(minHeight: 160)
                    .accessibilityLabel("Default tagging script")
                Text("Loads into Script Editor on launch and after saving these preferences. Scripts run only when you explicitly preview or apply them.").font(.caption)
            }
        case .appearance:
            Section("Appearance") {
                Picker("Color scheme", selection: $draft.editing.appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                Text("MacPicard follows macOS contrast, motion and transparency settings.").font(.caption)
            }
        }
    }

    private func save() {
        saving = true; error = nil
        draft.preferredReleaseCountry = draft.preferredReleaseCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        Task {
            defer { saving = false }
            do { try await model.savePreferences(draft, credentials: editingCredentials ? credentials : [:]); dismiss() }
            catch { self.error = error.localizedDescription }
        }
    }

    private func checkTool() {
        testingTool = true; toolResult = nil
        Task {
            defer { testingTool = false }
            do { toolResult = try await FingerprintToolInspector().version() }
            catch { toolResult = error.localizedDescription }
        }
    }
}
