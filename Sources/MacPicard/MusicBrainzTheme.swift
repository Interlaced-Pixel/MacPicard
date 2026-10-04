import AppKit
import SwiftUI

/// Accent text and filled controls have different contrast requirements. Never use
/// the light dark-mode accent as a background behind white button labels.
enum MusicBrainzTheme {
    static let accentColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.94, green: 0.64, blue: 0.83, alpha: 1)
            : NSColor(srgbRed: 0.55, green: 0.17, blue: 0.40, alpha: 1)
    }
    static let purple = Color(nsColor: accentColor)
    static let buttonColor = NSColor(srgbRed: 0.50, green: 0.14, blue: 0.36, alpha: 1)
    static let buttonFill = Color(nsColor: buttonColor)
    static let brandPurple = Color(red: 186 / 255, green: 71 / 255, blue: 143 / 255)
    static let warningColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.67, blue: 0.42, alpha: 1)
            : NSColor(srgbRed: 0.65, green: 0.27, blue: 0.06, alpha: 1)
    }
    static let orange = Color(nsColor: warningColor)
    static let successColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.46, green: 0.82, blue: 0.58, alpha: 1)
            : NSColor(srgbRed: 0.12, green: 0.40, blue: 0.22, alpha: 1)
    }
    static let success = Color(nsColor: successColor)
    static let errorColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.58, blue: 0.60, alpha: 1)
            : NSColor(srgbRed: 0.70, green: 0.15, blue: 0.20, alpha: 1)
    }
    static let error = Color(nsColor: errorColor)
    static let surface = Color(nsColor: .windowBackgroundColor)
}
