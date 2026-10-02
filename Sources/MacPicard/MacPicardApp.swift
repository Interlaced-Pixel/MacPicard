import SwiftUI

@main
struct MacPicardApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacPicard") {
            ContentView(model: model)
                .task { await model.bootstrap() }
        }
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
        .frame(minWidth: 1_080, minHeight: 680)
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
        NavigationSplitView {
            LibrarySidebar(
                model: model,
                isImporting: $isImporting,
                isShowingSettings: $isShowingSettings
            )
        } detail: {
            WorkspaceView(
                model: model,
                isImporting: $isImporting,
                isChoosingDestination: $isChoosingDestination,
                isShowingLookup: $isShowingLookup,
                isShowingScript: $isShowingScript,
                isDropTargeted: $isDropTargeted
            )
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .title)
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
