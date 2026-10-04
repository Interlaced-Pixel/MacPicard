import AppKit
import SwiftUI

/// MusicBrainz's published magenta/orange identity, adapted to native light/dark contrast.
enum MusicBrainzTheme {
    static let purple = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.88, green: 0.51, blue: 0.74, alpha: 1)
            : NSColor(srgbRed: 0.60, green: 0.20, blue: 0.44, alpha: 1)
    })
    static let brandPurple = Color(red: 186 / 255, green: 71 / 255, blue: 143 / 255)
    static let orange = Color(red: 235 / 255, green: 116 / 255, blue: 59 / 255)
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.12, green: 0.11, blue: 0.13, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.97, blue: 0.96, alpha: 1)
    })
}

struct MusicBrainzBrandHeader: View {
    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "hexagon.fill").foregroundStyle(MusicBrainzTheme.brandPurple)
                .overlay { Image(systemName: "music.note").font(.caption2.weight(.bold)).foregroundStyle(.white) }
            HStack(spacing: 0) { Text("Mac").foregroundStyle(MusicBrainzTheme.purple); Text("Picard").foregroundStyle(MusicBrainzTheme.orange) }
            Spacer()
        }.font(.title3.weight(.bold)).padding(.horizontal, 16).padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                HStack(spacing: 0) { MusicBrainzTheme.brandPurple; MusicBrainzTheme.orange }.frame(height: 3)
            }.accessibilityElement(children: .combine).accessibilityLabel("MacPicard")
    }
}
