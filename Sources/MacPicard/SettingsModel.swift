import Foundation
import PicardFoundation
import PicardFingerprint
import PicardScripts

enum ServiceCredential: String, CaseIterable {
    case submissionToken = "acoustid-user-token"
}

extension AppModel {
    /// Validate before touching either preferences or the Keychain. Restore secrets on persistence failure.
    func savePreferences(_ value: AppConfiguration, credentials: [ServiceCredential: String] = [:]) async throws {
        guard !isBusy, let runtime else { throw PicardError.invalidConfiguration("Settings are unavailable while the app is busy.") }
        try value.validate()
        _ = try ScriptParser().parse(value.editing.namingPattern)
        _ = try ScriptParser().parse(value.editing.defaultTagScript)
        var old: [ServiceCredential: Data] = [:]
        for key in credentials.keys {
            old[key] = try await runtime.keychain.data(for: key.rawValue)
        }
        // A settings commit is a foreground operation so monitoring/mutations cannot race it.
        isWorking = true
        defer { isWorking = false }
        do {
            for (key, secret) in credentials {
                if secret.isEmpty { try await runtime.keychain.remove(account: key.rawValue) }
                else { try await runtime.keychain.set(Data(secret.utf8), for: key.rawValue) }
            }
            try await runtime.configurationStore.save(value)
        } catch {
            var rollbackFailed = false
            for key in credentials.keys {
                do {
                    if let data = old[key] { try await runtime.keychain.set(data, for: key.rawValue) }
                    else { try await runtime.keychain.remove(account: key.rawValue) }
                } catch { rollbackFailed = true }
            }
            if rollbackFailed { throw PicardError.invalidConfiguration("Settings could not be saved and credential recovery failed. Reopen Settings and check your credentials.") }
            throw error
        }
        installConfiguration(value)
    }

    func savedCredentials() async throws -> [ServiceCredential: String] {
        guard let runtime else { return [:] }
        var result: [ServiceCredential: String] = [:]
        for key in ServiceCredential.allCases {
            if let data = try await runtime.keychain.data(for: key.rawValue) {
                result[key] = String(data: data, encoding: .utf8) ?? ""
            }
        }
        return result
    }
}

actor FingerprintToolInspector {
    func version() async throws -> String {
        let executable = try ChromaprintFingerprintProvider.bundledExecutableURL()
        return try await ChromaprintFingerprintProvider.version(executableURL: executable)
    }
}
