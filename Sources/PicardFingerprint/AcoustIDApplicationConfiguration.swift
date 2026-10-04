import Foundation

/// A registered, redistributable application credential supplied by the publisher.
/// Never reads the user's Keychain, submission token, environment, or preferences.
public enum AcoustIDApplicationConfiguration {
    public static func applicationKey(in bundle: Bundle = .main) throws -> String {
        guard let resources = bundle.resourceURL,
              let data = try? Data(contentsOf: resources.appendingPathComponent("AcoustID.plist")),
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let key = value["ApplicationKey"] as? String,
              !key.isEmpty, key.utf8.count <= 256,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }) else {
            throw FingerprintError.unavailable("This MacPicard build is missing its identification service configuration. Contact Interlaced Pixel for an updated build. Offline fingerprints and MusicBrainz lookup remain available.")
        }
        return key
    }
}
