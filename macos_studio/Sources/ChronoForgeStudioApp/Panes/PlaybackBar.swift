// PlaybackBar.swift — transport for live S-SMP/S-DSP playback (Music, SFX).
import SwiftUI
import ChronoForgeAudio
import ChronoForgeCore

/// What is playing, position, buffer and underruns, volume and Stop; with
/// `choosesROM`, the ROM song playback boots the sound driver from.
struct PlaybackBar: View {
    let store: ProjectStore
    var choosesROM = false
    @State private var pickROM = false

    var body: some View {
        @Bindable var audio = store.audio
        HStack(spacing: 10) {
            if audio.isLoading {
                ProgressView().controlSize(.small)
                Text("Loading…")
            } else if let title = audio.nowPlaying {
                Image(systemName: "speaker.wave.2.fill")
                Text(title).lineLimit(1)
                Text(Duration.seconds(audio.status.seconds).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1))))
                    .monospacedDigit()
                Text("buffer \(audio.status.bufferedFrames * 1000 / SPCRender.sampleRate) ms")
                    .monospacedDigit().foregroundStyle(.secondary)
                if audio.status.underrunCallbacks > 0 {
                    Text("\(audio.status.underrunCallbacks) underruns").foregroundStyle(.orange)
                }
            } else if let error = audio.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).lineLimit(2)
            } else {
                Text("Not playing").foregroundStyle(.secondary)
            }
            Spacer()
            if choosesROM {
                Button(store.playbackROMPath.map { "Sound ROM: " + ($0 as NSString).lastPathComponent } ?? "Sound ROM…") { pickROM = true }
                    .help("The verified CT USA 1.0 ROM the sound driver boots from")
            }
            Slider(value: $audio.volume, in: 0...1) { Image(systemName: "speaker.fill") }
                .frame(width: 110)
            Button("Stop", systemImage: "stop.fill") { audio.stop() }
                .disabled(!audio.isPlaying && !audio.isLoading)
                .keyboardShortcut(".", modifiers: .command)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.bar)
        .fileImporter(isPresented: $pickROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { picked in
            if case .success(let urls) = picked, let url = urls.first { store.setPlaybackROM(url) }
        }
    }
}
