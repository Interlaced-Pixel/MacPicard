import PicardFoundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = AppConfiguration()
    @State private var section = SectionName.general
    @State private var error: String?
    @State private var saving = false
    @State private var choosingTool = false
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
                Text(error ?? (draft == model.configuration ? "Preferences are up to date." : "Unsaved preferences"))
                    .font(.caption).foregroundStyle(error == nil ? Color.secondary : .red)
                    .textSelection(.enabled)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save") { save() }.buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || saving || loadingCredentials)
            }.padding(16)
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear { draft = model.configuration }
        .fileImporter(isPresented: $choosingTool, allowedContentTypes: [.item]) { result in
            do { let url = try result.get(); draft.editing.fpcalcPath = url.path; toolResult = nil }
            catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder private var settingsContent: some View {
        switch section {
        case .general:
            Section("Workspace recovery") {
                Toggle("Write periodic recovery snapshots", isOn: $draft.autosaveEnabled)
                Stepper("Recovery every \(draft.autosaveIntervalSeconds) seconds", value: $draft.autosaveIntervalSeconds, in: 15...3600, step: 15)
                    .disabled(!draft.autosaveEnabled)
                Text("Edits, workspace switches, and quit always save the workspace. Recovery snapshots provide additional protection; they never write audio tags.").font(.caption)
            }
        case .libraries:
            Section("Background monitoring") {
                Toggle("Enable monitoring for new libraries", isOn: $draft.editing.newLibrariesMonitorAutomatically)
                Stepper("Check every \(draft.editing.monitoringIntervalSeconds / 60) minutes", value: $draft.editing.monitoringIntervalSeconds, in: 60...3600, step: 60)
                Text("Existing libraries keep their own monitoring switch. Background checks defer during playback or foreground work; manual refresh stays available.").font(.caption)
                if model.activeWorkspace?.kind == .library {
                    Text("Current library: \(model.activeWorkspace?.name ?? "")")
                }
            }
        case .matching:
            Section("Release matching") {
                TextField("Preferred country (e.g. US)", text: $draft.preferredReleaseCountry)
                Text("Leave country empty for no regional preference.").font(.caption)
                Slider(value: $draft.editing.matchThreshold, in: 0.60...0.95, step: 0.01) {
                    Text("Automatic eligibility: \(Int((draft.editing.matchThreshold * 100).rounded()))%")
                }
                Text("Threshold: \(Int((draft.editing.matchThreshold * 100).rounded()))%. Ambiguous or incomplete matches still require review.").font(.caption)
            }
        case .metadata:
            Section("Tag preservation") {
                TextField("Preserve tags (comma separated)", text: Binding(
                    get: { draft.editing.preservedTags.joined(separator: ", ") },
                    set: { draft.editing.preservedTags = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty } }
                ))
                Text("These tags keep their current values when MusicBrainz metadata is applied. Scripts and deliberate manual edits remain available.").font(.caption)
            }
            Section("Saving") {
                Toggle("Preserve file modification timestamps", isOn: $draft.preserveFileTimestamps)
                Text("External file changes are always checked before saving. Save Tags writes staged edits; Save Workspace does not.").font(.caption)
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
        case .naming:
            Section("Default organization pattern") {
                TextEditor(text: $draft.editing.namingPattern).font(.system(.body, design: .monospaced)).frame(minHeight: 125)
                    .accessibilityLabel("Default naming pattern")
                Text("Used for Organize previews. Import continues to use the standard library layout. Naming patterns do not run tag-editing scripts.").font(.caption)
            }
        case .fingerprinting:
            Section("Fingerprint calculator") {
                TextField("Absolute fpcalc path (optional)", text: $draft.editing.fpcalcPath)
                HStack {
                    Button("Choose…") { choosingTool = true }
                    Button(testingTool ? "Checking…" : "Check Tool") { checkTool() }.disabled(testingTool)
                }
                if let toolResult { Text(toolResult).font(.caption).textSelection(.enabled) }
                Text("An empty path allows standard tool discovery. Identification actions are part of the later fingerprinting phase.").font(.caption)
            }
            Section("Service credentials") {
                if editingCredentials {
                    SecureField("AcoustID application key", text: Binding(get: { credentials[.applicationKey] ?? "" }, set: { credentials[.applicationKey] = $0 }))
                    SecureField("User submission token", text: Binding(get: { credentials[.submissionToken] ?? "" }, set: { credentials[.submissionToken] = $0 }))
                    Text("Saved only in Keychain. Empty fields remove their stored credential. An application key identifies the app; the user token authorizes submissions.").font(.caption)
                } else {
                    Button(loadingCredentials ? "Loading…" : "Edit Keychain Credentials…") {
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
                Text("System accessibility settings control contrast, motion, and transparency. Content uses standard readable surfaces; native glass is reserved for controls.").font(.caption)
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
        let executable = draft.editing.fpcalcPath.isEmpty
            ? ["/opt/homebrew/bin/fpcalc", "/usr/local/bin/fpcalc", "/usr/bin/fpcalc"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? ""
            : draft.editing.fpcalcPath
        Task {
            defer { testingTool = false }
            do { toolResult = try await FingerprintToolInspector().version(path: executable) }
            catch { toolResult = error.localizedDescription }
        }
    }
}
