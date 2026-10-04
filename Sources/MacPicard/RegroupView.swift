import SwiftUI

struct RegroupView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var album = ""
    @State private var artist = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Regroup Selected Files").font(.title2)
            Text("Change album and album artist on \(model.selectedFileIDs.count) files. Other tags stay unchanged.").font(.callout)
            TextField("Album", text: $album).textFieldStyle(.roundedBorder)
            TextField("Album artist", text: $artist).textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Apply") { model.regroupSelected(album: album, artist: artist); dismiss() }.buttonStyle(.borderedProminent)
                    .disabled(!model.canEditSelection || album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 500)
        .onAppear { album = model.metadataValue("album"); artist = model.metadataValue("albumartist") }
    }
}
