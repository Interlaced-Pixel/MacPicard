import AppKit
import PicardSessions
import SwiftUI
import UniformTypeIdentifiers

struct OrganizationView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingDirectory = false
    @State private var search = ""
    @State private var filter = PreviewFilter.all
    @State private var acknowledgesOutsideMove = false
    @State private var confirmsMove = false
    @State private var confirmationReview: OrganizationReview?
    @State private var showsNamingPattern = false

    private struct PreviewKey: Equatable {
        let directory: URL?
        let script: String
        let policy: OrganizationConflictPolicy
        let excluded: Set<UUID>
    }
    private var previewKey: PreviewKey {
        .init(directory: model.organizationDirectory, script: model.organizationNamingScript,
              policy: model.organizationConflictPolicy, excluded: model.organizationExcludedIDs)
    }
    private enum PreviewFilter: String, CaseIterable {
        case all = "All files", changes = "Moves", attention = "Needs attention"
    }
    private enum NamingPreset: String, CaseIterable {
        case library = "Artist / Album / Track — Title"
        case artist = "Artist / Title"
        case filename = "Keep filenames"
        case custom = "Custom pattern"
        var script: String? {
            switch self {
            case .library: LibraryImporter.defaultNamingScript
            case .artist: "$if2(%albumartist%,%artist%,Unknown Artist)/$if2(%title%,%filename%).%extension%"
            case .filename: "%filename%.%extension%"
            case .custom: nil
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            options
            Divider()
            preview
            Divider()
            footer
        }
        .background(.background)
        .onAppear { model.beginOrganizationReview(entireLibrary: model.organizationEntireLibraryRequested) }
        .task(id: previewKey) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await model.refreshOrganizationPreview()
        }
        .onChange(of: model.organizationReview?.id) { acknowledgesOutsideMove = false }
        .onDisappear { model.cancelOrganizationReview() }
        .interactiveDismissDisabled(model.isWorking)
        .onChange(of: choosingDirectory) { _, choosing in
            guard choosing else { return }
            let panel = NSOpenPanel()
            panel.title = "Choose Organization Folder"
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            let workspaceID = model.activeWorkspaceID
            let response = panel.runModal()
            choosingDirectory = false
            if response == .OK, let url = panel.url, workspaceID == model.activeWorkspaceID {
                Task { await model.chooseOrganizationDirectory(.success([url])) }
            }
        }
        .alert("Move \(confirmationReview?.moveCount ?? 0) files?", isPresented: $confirmsMove, presenting: confirmationReview) { review in
            Button("Move Files", role: .destructive) {
                let allowOutside = acknowledgesOutsideMove
                Task {
                    if await model.executeOrganization(reviewID: review.id, confirmed: true, allowOutsideLibrary: allowOutside) { dismiss() }
                }
            }
            Button("Keep Reviewing", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { review in
            Text("Only the \(review.moveCount) ready files in this preview will be renamed or moved. Their original paths will no longer exist. Existing files will not be overwritten. Tags and artwork will not be saved. Other music apps or playlists may need their file locations updated.")
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.organizationTargetsEntireLibrary ? "Organize Entire Library" : "Organize Files")
                    .font(.title2.weight(.semibold))
                Text(model.organizationTargetsEntireLibrary
                     ? "\(model.activeWorkspace?.name ?? "Library") · \(model.organizationFiles.count) files · all indexed items"
                     : "\(model.organizationScopeLabel) · \(model.organizationFiles.count) files · review folders and filenames")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isPreparingOrganization || model.isWorking { ProgressView().controlSize(.small) }
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.isWorking)
        }.padding(20)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Destination").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(model.organizationDirectory?.path ?? "Choose a folder for this session")
                        .font(.callout).lineLimit(2).textSelection(.enabled)
                        .help(model.organizationDirectory?.path ?? "No folder selected")
                }.frame(maxWidth: .infinity, alignment: .leading)
                if let root = model.organizationLibraryRoot {
                    Button("Library Folder") { model.organizationDirectory = root }
                        .disabled(model.organizationDirectory == root)
                }
                Button("Choose Folder…", systemImage: "folder") { choosingDirectory = true }
            }
            HStack(spacing: 20) {
                Menu("Saved Naming Scripts") {
                    ForEach(model.workflowDocument.scripts.filter { $0.kind == .naming && $0.enabled }) { script in
                        Button(script.name) { model.organizationNamingScript = script.source }
                    }
                    Button("Default Naming Pattern") { model.organizationNamingScript = model.configuration.editing.namingPattern }
                }
                Picker("Naming", selection: Binding<NamingPreset>(
                    get: { NamingPreset.allCases.first { $0.script == model.organizationNamingScript } ?? .custom },
                    set: { if let script = $0.script { model.organizationNamingScript = script } else { showsNamingPattern = true } }
                )) {
                    ForEach(NamingPreset.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: .infinity)
                Picker("Conflicts", selection: $model.organizationConflictPolicy) {
                    ForEach(OrganizationConflictPolicy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 300)
            }
            DisclosureGroup("Naming pattern · separate from tag scripts", isExpanded: $showsNamingPattern) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Naming pattern", text: $model.organizationNamingScript, axis: .vertical)
                        .font(.system(.caption, design: .monospaced)).textFieldStyle(.roundedBorder).lineLimit(2...4)
                        .accessibilityLabel("Organization naming pattern")
                    Text("Use %artist%, %album%, %title%, %tracknumber%, %filename%, %extension% and Picard functions. Slashes create folders; unsafe tag characters are sanitized.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 7)
            }
        }.padding(.horizontal, 20).padding(.vertical, 16).background(.thinMaterial)
            .disabled(model.isWorking)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if let review = model.organizationReview {
                    Label("\(review.moveCount) ready", systemImage: "arrow.right.circle").foregroundStyle(.tint)
                    Text("\(review.rows.count { $0.status == .unchanged }) unchanged").foregroundStyle(.secondary)
                    Text("\(review.blockedCount) blocked").foregroundStyle(review.blockedCount == 0 ? Color.secondary : MusicBrainzTheme.orange)
                    Text("\(review.rows.count { $0.status == .excluded || $0.status == .skipped }) skipped").foregroundStyle(.secondary)
                } else {
                    Text(model.isPreparingOrganization ? "Building preview…" : "File preview").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Update Preview", systemImage: "arrow.clockwise") { Task { await model.refreshOrganizationPreview() } }
                    .disabled(model.isBusy || model.organizationDirectory == nil)
            }.font(.caption).padding(14)
            HStack(spacing: 12) {
                TextField("Search filenames or paths", text: $search).textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Search organization preview")
                Picker("Show", selection: $filter) {
                    ForEach(PreviewFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 165)
                Button("Include All") { model.organizationExcludedIDs.removeAll() }
                    .disabled(model.organizationExcludedIDs.isEmpty || model.isWorking)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            if let review = model.organizationReview {
                let rows = visibleRows(review)
                if rows.isEmpty {
                    ContentUnavailableView.search(text: search).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(rows) { row in
                                OrganizationPathRow(row: row, included: Binding(
                                    get: { !model.organizationExcludedIDs.contains(row.id) },
                                    set: { include in
                                        if include { model.organizationExcludedIDs.remove(row.id) }
                                        else { model.organizationExcludedIDs.insert(row.id) }
                                    }
                                )).disabled(model.isWorking)
                            }
                        }.padding(16)
                    }
                }
            } else {
                ContentUnavailableView(model.organizationDirectory == nil ? "Choose a destination" : "Preview not ready",
                    systemImage: "folder", description: Text(model.organizationError ?? "Choose a folder to preview paths. Confirm the moves when ready."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.organizationOutsideLibraryCount > 0 {
                Label("\(model.organizationOutsideLibraryCount) files will leave the library folder. They remain linked here, but are no longer stored in it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(MusicBrainzTheme.orange)
                Toggle("I understand these files will move outside this Music Library.", isOn: $acknowledgesOutsideMove)
                    .toggleStyle(.checkbox).font(.caption).disabled(model.isWorking)
            }
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.organizationError ?? "Move, not copy. Existing files are never overwritten. Tags and artwork remain unchanged on disk.")
                        .foregroundStyle(model.organizationError == nil ? Color.secondary : .red)
                    if model.organizationReview != nil && !model.organizationInputsAreCurrent {
                        Text("The selection or files changed. Close and reopen Organize to review the latest files.").foregroundStyle(MusicBrainzTheme.orange)
                    }
                    if model.organizationFiles.contains(where: \.isModified) {
                        Text("Pending tags determine new filenames, but stay unsaved. Save Tags separately when ready.").foregroundStyle(.secondary)
                    }
                }.font(.caption).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Move \(model.organizationReview?.moveCount ?? 0) Files…") {
                    confirmationReview = model.organizationReview
                    confirmsMove = true
                }.buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill)
                    .disabled(!model.canExecuteOrganization || (model.organizationOutsideLibraryCount > 0 && !acknowledgesOutsideMove))
            }
        }.padding(18).background(.bar)
    }

    private func visibleRows(_ review: OrganizationReview) -> [OrganizationReviewRow] {
        review.rows.filter { row in
            let matchesFilter = filter == .all || (filter == .changes && row.status == .move)
                || (filter == .attention && (row.status == .blocked || row.status == .skipped))
            return matchesFilter && (search.isEmpty || [row.source.path, row.destination?.path ?? "", row.message]
                .contains { $0.localizedStandardContains(search) })
        }
    }
}

private struct OrganizationPathRow: View {
    let row: OrganizationReviewRow
    @Binding var included: Bool
    private var color: Color {
        switch row.status {
        case .move: .accentColor
        case .blocked: MusicBrainzTheme.orange
        case .unchanged, .skipped, .excluded: .secondary
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Toggle(isOn: $included) { Text(row.source.lastPathComponent).fontWeight(.semibold).lineLimit(1) }
                    .toggleStyle(.checkbox).accessibilityLabel("Include \(row.source.lastPathComponent)")
                Spacer(minLength: 10)
                Text(row.status.rawValue).font(.caption.weight(.medium)).foregroundStyle(color)
            }
            pathLine("From", row.source)
            if let destination = row.destination { pathLine("To", destination) }
            if !row.message.isEmpty { Text(row.message).font(.caption).foregroundStyle(color).textSelection(.enabled) }
        }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.8), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(0.18)))
    }
    private func pathLine(_ label: String, _ url: URL) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            Text(url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).help(url.path)
        }.font(.caption)
    }
}
