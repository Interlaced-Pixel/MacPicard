import AppKit
import SwiftUI

@MainActor
final class MacPicardAppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.fitWindowsToVisibleScreen()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        model.playback.stop(clearQueue: true)
        Task { @MainActor in
            do {
                try await model.flushSession()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                let alert = NSAlert()
                alert.messageText = "The workspace could not be saved."
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "Keep Open")
                alert.addButton(withTitle: "Quit Without Saving")
                sender.reply(toApplicationShouldTerminate: alert.runModal() == .alertSecondButtonReturn)
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
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1_360, height: 860)
        .commands { MacPicardCommands(model: model, presentation: presentation) }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var presentation: AppPresentation
    @State private var isDropTargeted = false

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
        .fileImporter(
            isPresented: $presentation.isImporting,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true,
            onCompletion: { result in Task { await model.importResult(result) } }
        )
        .fileImporter(
            isPresented: $presentation.isChoosingDestination,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: model.chooseDestination
        )
        .fileImporter(isPresented: $presentation.isAddingLibrary,
                      allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.addLibrary(directory: url) }
            } else if case let .failure(error) = result { model.present(error) }
        }
        .fileImporter(isPresented: $presentation.isRelinkingLibrary,
                      allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task { await model.relinkLibrary(directory: url) }
            } else if case let .failure(error) = result { model.present(error) }
        }
        .sheet(isPresented: $presentation.isShowingLookup) {
            LookupView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .sheet(isPresented: $presentation.isShowingScript) {
            ScriptView(model: model)
                .frame(minWidth: 760, minHeight: 500)
        }
        .sheet(isPresented: $presentation.isShowingSettings) {
            SettingsView(model: model)
                .frame(width: 500, height: 390)
        }
        .sheet(isPresented: $presentation.isNamingSession) {
            NewSessionView(model: model, copying: presentation.copiesCurrentSession)
        }
        .sheet(isPresented: $presentation.isManagingWorkspaces) {
            WorkspaceManagerView(model: model, presentation: presentation)
        }
        .sheet(isPresented: $presentation.isShowingGuide) { QuickStartView() }
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
                isChoosingDestination: $presentation.isChoosingDestination,
                isShowingLookup: $presentation.isShowingLookup,
                isShowingScript: $presentation.isShowingScript,
                isDropTargeted: $isDropTargeted,
                presentation: presentation
            )
            .frame(minWidth: 900, maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct StartupErrorView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38))
                .foregroundStyle(.orange)
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
        ZStack {
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.13),
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .backgroundExtensionEffect()

            Circle()
                .fill(Color.accentColor.opacity(0.06))
                .frame(width: 500, height: 500)
                .blur(radius: 70)
                .offset(x: 340, y: -250)
                .accessibilityHidden(true)
        }
    }
}
