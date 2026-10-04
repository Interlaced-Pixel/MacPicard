import SwiftUI

struct PlaybackBar: View {
    @ObservedObject var playback: PlaybackController
    @ObservedObject var presentation: AppPresentation
    @State private var isSeeking = false
    @State private var seekValue = 0.0

    var body: some View {
        if let track = playback.currentTrack {
            VStack(spacing: 5) {
                HStack(spacing: 14) {
                    ArtworkThumbnail(artwork: track.artwork)
                        .frame(width: 40, height: 40)
                        .clipShape(.rect(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(playback.state == .loading ? "Loading audio…" : track.artist)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(minWidth: 100, idealWidth: 170, maxWidth: 200, alignment: .leading)
                    .help("\(track.title) — \(track.artist)")

                    transport

                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { isSeeking ? seekValue : playback.elapsed },
                                              set: {
                                                  seekValue = $0
                                                  if !isSeeking { playback.seek(to: $0) }
                                              }),
                               in: 0...max(playback.duration, 0.01)) { editing in
                            if editing { seekValue = playback.elapsed; isSeeking = true }
                            else { isSeeking = false; playback.seek(to: seekValue) }
                        }
                        .disabled(playback.duration == 0 || playback.state == .loading || playback.state == .failed)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(time(playback.elapsed)) of \(time(playback.duration))")
                        HStack {
                            Text(time(isSeeking ? seekValue : playback.elapsed))
                            Spacer()
                            Text(time(playback.duration))
                        }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(minWidth: 120, maxWidth: .infinity)
                    .onChange(of: playback.currentEntryID) { _, _ in isSeeking = false; seekValue = 0 }

                    HStack(spacing: 5) {
                        Button { playback.toggleMute() } label: {
                            Image(systemName: playback.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playback.volume == 0 ? "Unmute" : "Mute")
                        Slider(value: $playback.volume, in: 0...1)
                            .frame(width: 75)
                            .accessibilityLabel("Playback volume")
                            .accessibilityValue("\(Int(playback.volume * 100)) percent")
                    }
                    Button { presentation.showsPlaybackQueue.toggle() } label: {
                        Label("\(playback.remainingCount)", systemImage: "list.bullet")
                    }
                    .buttonStyle(.bordered)
                    .help("Show playback queue")
                    .accessibilityLabel("Playback queue, \(playback.remainingCount) upcoming tracks")
                    .popover(isPresented: $presentation.showsPlaybackQueue) { PlaybackQueueView(playback: playback) }
                }
                if let error = playback.errorMessage {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(MusicBrainzTheme.error).lineLimit(2)
                        Spacer()
                        Button("Retry") { playback.togglePlayPause() }.buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
    }

    private var transport: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                Button { playback.previous() } label: { Image(systemName: "backward.end.fill") }
                    .disabled(!playback.canGoPrevious)
                    .help("Previous track or restart")
                    .accessibilityLabel("Previous Track")
                Button { playback.togglePlayPause() } label: {
                    Image(systemName: playback.transportIsActive ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderedProminent).tint(MusicBrainzTheme.buttonFill)
                .help(playback.transportIsActive ? "Pause" : "Play")
                .accessibilityLabel(playback.transportIsActive ? "Pause Playback" : "Play Playback")
                Button { playback.next() } label: { Image(systemName: "forward.end.fill") }
                    .disabled(!playback.canGoNext)
                    .help("Next track")
                    .accessibilityLabel("Next Track")
                Button { playback.stop() } label: { Image(systemName: "stop.fill") }
                    .help("Stop playback")
                    .accessibilityLabel("Stop Playback")
            }.buttonStyle(.bordered)
        }
    }

    private func time(_ value: Double) -> String {
        guard value.isFinite else { return "0:00" }
        let seconds = Int(max(value, 0))
        if seconds >= 3_600 { return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PlaybackQueueView: View {
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Playback Queue").font(.headline)
                Spacer()
                Text("\(playback.queue.count) tracks").font(.caption).foregroundStyle(.secondary)
                Button("Clear") { playback.stop(clearQueue: true) }
                    .disabled(playback.queue.isEmpty)
            }.padding(14)
            Divider()
            List(playback.queue) { entry in
                Button { playback.playEntry(entry.id) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: playback.currentEntryID == entry.id ? "speaker.wave.2.fill" : "music.note")
                            .foregroundStyle(playback.currentEntryID == entry.id ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.track.title).lineLimit(1)
                            Text(entry.track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(entry.track.title)")
                .contextMenu {
                    Button("Play Now") { playback.playEntry(entry.id) }
                    Button("Remove from Queue") { playback.removeEntry(entry.id) }
                }
            }
        }.frame(width: 390, height: 380)
    }
}
