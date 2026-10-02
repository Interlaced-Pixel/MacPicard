import PicardFoundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: RuntimeSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false

    private var runtime: PicardRuntime?

    func bootstrap() async {
        guard snapshot == nil, !isLoading else {
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let runtime = try PicardRuntime.live()
            let snapshot = try await runtime.start()
            self.runtime = runtime
            self.snapshot = snapshot
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

@main
struct MacPicardApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("MacPicard") {
            ContentView(model: model)
                .task {
                    await model.bootstrap()
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.isLoading {
                ProgressView("Starting MacPicard…")
            } else if let errorMessage = model.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("MacPicard could not start")
                        .font(.headline)
                    Text(errorMessage)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .padding(32)
            } else if let snapshot = model.snapshot {
                FoundationStatusView(snapshot: snapshot)
            } else {
                ProgressView("Preparing MacPicard…")
            }
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct FoundationStatusView: View {
    let snapshot: RuntimeSnapshot

    var body: some View {
        Form {
            Section("Foundation") {
                LabeledContent("Configuration schema", value: "\(snapshot.configuration.schemaVersion)")
                LabeledContent("Operating system", value: snapshot.diagnostics.operatingSystem)
                LabeledContent("Architecture", value: snapshot.diagnostics.architecture)
                LabeledContent("Processors", value: "\(snapshot.diagnostics.activeProcessorCount) active")
            }

            Section("Application paths") {
                LabeledContent("Application Support", value: snapshot.paths.applicationSupportDirectory.path)
                LabeledContent("Configuration", value: snapshot.paths.configurationFile.path)
            }

            Section("Phase 1 status") {
                Label("Swift 6 strict concurrency enabled", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Configuration and migration system ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Label("Keychain and security-scoped bookmark services ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
