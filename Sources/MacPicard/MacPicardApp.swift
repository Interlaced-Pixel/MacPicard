import AppKit
import PicardFormats
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class MacPicardAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminationInProgress = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(mainWindowWillClose(_:)), name: NSWindow.willCloseNotification, object: nil)
        DispatchQueue.main.async { [weak self] in
            self?.fitWindowsToVisibleScreen()
        }
    }

    @objc private func mainWindowWillClose(_ notification: Notification) {
        guard !terminationInProgress, (notification.object as? NSWindow)?.title == "MacPicard" else { return }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.isExecutingOrganization || model.isExportingArtwork || model.isWritingAudio {
            let alert = NSAlert()
            alert.messageText = model.isExportingArtwork ? "Artwork is still being exported." : "Files are still being written or organized."
            alert.informativeText = "Wait for the file operation to finish before quitting so its results can be safely saved."
            alert.addButton(withTitle: "Keep Open")
            alert.runModal()
            return .terminateCancel
        }
        model.playback.stop(clearQueue: true)
        model.stopLibraryMonitoring()
        model.cancelFingerprintOperation()
        model.cancelLibraryMatch()
        terminationInProgress = true
        Task { @MainActor in
            do {
                try await model.flushSession()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The library could not be saved."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit Without Saving")
                let shouldQuit = alert.runModal() == .alertSecondButtonReturn
                terminationInProgress = shouldQuit
                sender.reply(toApplicationShouldTerminate: shouldQuit)
            }
        }
        return .terminateLater
    }

    private func fitWindowsToVisibleScreen() {
        for window in NSApplication.shared.windows where window.title == "MacPicard" {
            guard let screen = window.screen ?? NSScreen.main else { continue }

            let visibleFrame = screen.visibleFrame.insetBy(dx: 24, dy: 24)
            let width = min(max(window.frame.width, 1_180), visibleFrame.width)
            let height = min(max(window.frame.height, 760), visibleFrame.height)
            let originX = min(
                max(window.frame.minX, visibleFrame.minX),
                visibleFrame.maxX - width
            )
            let originY = min(
                max(window.frame.minY, visibleFrame.minY),
                visibleFrame.maxY - height
            )

            let fittedFrame = NSRect(
                x: originX,
                y: originY,
                width: width,
                height: height
            )
            if window.frame != fittedFrame {
                window.setFrame(fittedFrame, display: true, animate: false)
            }
        }
    }
}

@main
struct MacPicardApp: App {
    @NSApplicationDelegateAdaptor(MacPicardAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var presentation = AppPresentation()

    var body: some Scene {
        Window("MacPicard", id: "workspace") {
            ContentView(model: model, presentation: presentation)
                .onAppear { appDelegate.model = model }
                .task {
                    // Xcode's hosted model tests create their own temporary
                    // workspaces. Do not restore or autosave the user's library
                    // just because the test runner launched the app executable.
                    guard ProcessInfo.processInfo.environment["MACPICARD_UNIT_TEST_HOST"] != "1" else { return }
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1_360, height: 860)
        .commands { MacPicardCommands(model: model, presentation: presentation) }
        Window("Collection Tools", id: "collection-tools") {
            CollectionToolsView(model: model, presentation: presentation)
                .tint(MusicBrainzTheme.purple).accentColor(MusicBrainzTheme.purple)
                .preferredColorScheme(model.configuration.editing.appearance == "dark" ? .dark : model.configuration.editing.appearance == "light" ? .light : nil)
        }.defaultSize(width: 1100, height: 780)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @State private var isDropTargeted = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Starting MacPicard…")
                    .controlSize(.large)
            } else if let errorMessage = model.errorMessage, model.snapshot == nil {
                StartupErrorView(message: errorMessage)
            } else {
                mainWorkspace
            }
        }
        .frame(minWidth: 1_180, minHeight: 760)
        .background(GlassBackdrop())
        .tint(MusicBrainzTheme.purple)
        .accentColor(MusicBrainzTheme.purple)
        .preferredColorScheme(model.configuration.editing.appearance == "dark" ? .dark : model.configuration.editing.appearance == "light" ? .light : nil)
        .onAppear {
            presentation.showsSidebar = model.browserPreferences.showsSidebar
            presentation.showsInspector = model.browserPreferences.showsInspector
        }
        .onChange(of: presentation.showsSidebar) { _, value in
            model.browserPreferences.showsSidebar = value
            model.saveBrowserPreferences()
        }
        .onChange(of: presentation.showsInspector) { _, value in
            model.browserPreferences.showsInspector = value
            model.saveBrowserPreferences()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSText.didChangeNotification)) { _ in model.editHistoryRevision += 1 }
        .onChange(of: presentation.isImporting) { _, importing in
            guard importing else { return }
            let panel = NSOpenPanel()
            panel.title = "Import Audio"
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.allowedContentTypes = AudioFormat.allCases.flatMap { format in
                format.fileExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
            }
            guard let window = NSApp.keyWindow else { presentation.isImporting = false; return }
            let workspaceID = model.activeWorkspaceID
            panel.beginSheetModal(for: window) { response in
                presentation.isImporting = false
                guard response == .OK, workspaceID == model.activeWorkspaceID else { return }
                Task { await model.importResult(.success(panel.urls)) }
            }
        }
        .onChange(of: presentation.isAddingLibrary) { _, choosing in
            guard choosing else { return }
            chooseLibraryDirectory(relinking: false)
        }
        .onChange(of: presentation.isRelinkingLibrary) { _, choosing in
            guard choosing else { return }
            chooseLibraryDirectory(relinking: true)
        }
        .sheet(isPresented: $presentation.isShowingLookup) {
            LookupView(model: model)
                    .frame(minWidth: 900, minHeight: 560)
        }
        .onChange(of: presentation.isShowingScript) { _, showing in
            if showing { presentation.isShowingScript = false; presentation.collectionToolsScope = .selection; presentation.collectionToolsPage = "scripts"; openWindow(id: "collection-tools") }
        }
        .onChange(of: presentation.isShowingCollectionTools) { _, showing in
            if showing { presentation.isShowingCollectionTools = false; openWindow(id: "collection-tools") }
        }
        .sheet(isPresented: $presentation.isShowingOrganization) {
            OrganizationView(model: model)
                .frame(minWidth: 980, minHeight: 660)
        }
        .sheet(isPresented: $presentation.isShowingLibraryMatch) {
            LibraryMatchView(model: model, presentation: presentation)
                .frame(minWidth: 900, minHeight: 620)
        }
        .sheet(isPresented: $presentation.isShowingSettings) {
            SettingsView(model: model)
                .frame(minWidth: 720, idealWidth: 820, minHeight: 560, idealHeight: 650)
        }
        .sheet(isPresented: $presentation.isShowingToolbarEditor) {
            ToolbarEditorView(model: model)
                .frame(width: 440, height: 540)
        }
        .sheet(isPresented: $presentation.isShowingMetadataEditor) {
            MetadataEditorView(model: model).frame(minWidth: 850, minHeight: 570)
        }
        .sheet(isPresented: $presentation.isShowingArtwork) { ArtworkManagerView(model: model) }
        .sheet(isPresented: $presentation.isShowingActivity) { ActivityView(model: model) }
        .sheet(isPresented: $presentation.isShowingFingerprints) { FingerprintResultsView(model: model, presentation: presentation) }
        .sheet(item: $model.fingerprintSubmissionReview) { review in FingerprintSubmissionView(model: model, review: review) }
        .sheet(isPresented: $presentation.isRegrouping) { RegroupView(model: model) }
        .sheet(isPresented: $presentation.isNamingLibrary) {
            NewMusicLibraryView(model: model)
        }
        .sheet(isPresented: $presentation.isManagingWorkspaces) {
            WorkspaceManagerView(model: model, presentation: presentation)
        }
        .sheet(isPresented: $presentation.isShowingGuide) { QuickStartView() }
        .alert(
            presentation.trackRemovalRequest?.trash == true ? "Move library files to Trash?" : "Remove selected items?",
            isPresented: $presentation.isConfirmingTrackRemoval,
            presenting: presentation.trackRemovalRequest
        ) { request in
            Button(request.trash ? "Move to Trash" : "Remove Items", role: .destructive) {
                guard request.workspaceID == model.activeWorkspaceID else { return }
                Task { await model.removeFiles(request.fileIDs, movingToTrash: request.trash, confirmed: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text(request.trash
                 ? "\(request.fileIDs.count) library files will be moved to the recoverable Trash. External originals stay untouched. Pending edits on these items will be discarded."
                 : "\(request.fileIDs.count) items will be removed from this library; all audio files stay on disk. Removed library items stay hidden during refresh until re-imported or restored. Pending edits on these items will be discarded.")
        }
    }

    private func chooseLibraryDirectory(relinking: Bool) {
        // Inactive SwiftUI folder importers can reconfigure the shared native
        // open panel while Import Audio is visible. Configure only on demand.
        let panel = NSOpenPanel()
        panel.title = relinking ? "Reconnect Music Library" : "Add Music Library"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard let window = NSApp.keyWindow else {
            presentation.isAddingLibrary = false; presentation.isRelinkingLibrary = false; return
        }
        let workspaceID = model.activeWorkspaceID
        panel.beginSheetModal(for: window) { response in
            presentation.isAddingLibrary = false; presentation.isRelinkingLibrary = false
            guard response == .OK, let directory = panel.url, workspaceID == model.activeWorkspaceID else { return }
            Task {
                if relinking { await model.relinkLibrary(directory: directory) }
                else { await model.addLibrary(directory: directory) }
            }
        }
    }

    private var mainWorkspace: some View {
        HSplitView {
            if presentation.showsSidebar {
                LibrarySidebar(model: model, presentation: presentation)
                    .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)
            }

            WorkspaceView(
                model: model,
                isImporting: $presentation.isImporting,
                isShowingLookup: $presentation.isShowingLookup,
                isShowingScript: $presentation.isShowingScript,
                isDropTargeted: $isDropTargeted,
                presentation: presentation
            )
            .frame(minWidth: 900, maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert("Discard unsaved changes?", isPresented: $presentation.isConfirmingDiscard,
               presenting: presentation.discardRequest) { request in
            Button("Discard Changes", role: .destructive) {
                guard request.workspaceID == model.activeWorkspaceID else { return }
                Task { await model.discardChanges(request.fileIDs, confirmed: true) }
            }
            Button("Keep Editing", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { request in
            Text("Pending tag and artwork edits on \(request.fileIDs.count) files will revert to their last saved or loaded values. Audio files will not be changed. This cannot undo tags already saved to disk.")
        }
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(MusicBrainzTheme.orange)
            Text("MacPicard could not start")
                .font(.title2.weight(.semibold))
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
        .padding(40)
    }
}

private struct GlassBackdrop: View {
    var body: some View {
        MusicBrainzTheme.surface.ignoresSafeArea()
    }
}
