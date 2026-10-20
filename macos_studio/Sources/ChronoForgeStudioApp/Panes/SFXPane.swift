// SFXPane.swift — BRR sample sidecars (loop/ADSR/GAIN) + WAV preview playback.
import SwiftUI
import AVFoundation
import ChronoForgeCore

struct SFXPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?
    @State private var player: AVAudioPlayer?

    var body: some View {
        EntityListView(title: "SFX", ids: project.samples.keys.sorted(),
                       selection: $selection) { id in
            if let s = project.samples[id] {
                EditorHost(entity: s, apply: { store.updateSample(id, $0) }) { $s in
                    Form {
                        TextField("BRR file", text: $s.brr)
                        Toggle("Loop", isOn: $s.loop)
                        OptionalIntField(label: "Loop start", value: $s.loopStartSample, range: 0...1_000_000)
                        OptionalIntField(label: "Loop end", value: $s.loopEndSample, range: 0...1_000_000)
                        OptionalIntField(label: "Rate", value: $s.rate, range: 8000...32000)
                        if let adsr = s.adsr {
                            Text("ADSR \(adsr.map(String.init).joined(separator: " "))")
                                .font(.system(.caption, design: .monospaced))
                        }
                        OptionalIntField(label: "GAIN", value: $s.gain, range: 0...255)
                        HStack {
                            Button("Play preview WAV") { play(s) }
                            Button("Stop") { player?.stop() }
                        }
                        ApplyBar(apply: { store.updateSample(id, $s.wrappedValue) })
                    }
                    .padding()
                }
                .id(id)
            }
        }
    }

    func play(_ s: SampleMeta) {
        guard let url = store.fileURL(s.brr) else { return }
        let wav = url.deletingPathExtension().appendingPathExtension("wav")
        guard FileManager.default.fileExists(atPath: wav.path) else { return }
        player = try? AVAudioPlayer(contentsOf: wav)
        player?.play()
    }
}
