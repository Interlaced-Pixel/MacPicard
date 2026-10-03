import AppKit
import SwiftUI

@MainActor
final class MacPicardAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.fitWindowsToVisibleScreen()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

    var body: some Scene {
        WindowGroup("MacPicard") {
            ContentView(model: model)
                .task { await model.bootstrap() }
        }
        .defaultSize(width: 1_360, height: 860)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Select All Tracks") { model.selectAllVisible() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                Button("Clear Selection") { model.clearSelection() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            CommandMenu("MusicBrainz") {
                Button("Look Up Release") { Task { await model.lookup() } }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Apply Selected Match") { model.applySelectedRelease() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
            }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var isImporting = false
    @State private var isChoosingDestination = false
    @State private var isShowingLookup = false
    @State private var isShowingScript = false
    @State private var isShowingSettings = false
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
            isPresented: $isImporting,
            allowedContentTypes: [.audio, .folder],
            allowsMultipleSelection: true,
            onCompletion: { result in Task { await model.importResult(result) } }
        )
        .fileImporter(
            isPresented: $isChoosingDestination,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: model.chooseDestination
        )
        .sheet(isPresented: $isShowingLookup) {
            LookupView(model: model)
                .frame(minWidth: 760, minHeight: 480)
        }
        .sheet(isPresented: $isShowingScript) {
            ScriptView(model: model)
                .frame(minWidth: 760, minHeight: 500)
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(model: model)
                .frame(width: 500, height: 390)
        }
    }

    private var mainWorkspace: some View {
        HSplitView {
            LibrarySidebar(
                model: model,
                isImporting: $isImporting,
                isShowingSettings: $isShowingSettings
            )
            .frame(minWidth: 250, idealWidth: 300, maxWidth: 360)

            WorkspaceView(
                model: model,
                isImporting: $isImporting,
                isChoosingDestination: $isChoosingDestination,
                isShowingLookup: $isShowingLookup,
                isShowingScript: $isShowingScript,
                isDropTargeted: $isDropTargeted
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
