// SFXPane.swift — Module 5, the Character Sound & SFX Lab: BRR samples from
// WAV imports or synth generators, a block-snapped loop, the S-DSP's own
// envelope, pitch bend / vibrato / noise, live S-DSP playback, and saving to
// audio/samples/<id>.brr with its sidecar. See docs/sfx_lab.md.
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct SFXPane: View {
    let store: ProjectStore
    let project: CTProject
    /// `--select <id>` at launch selects that sample (as in Tilesets).
    @State private var selection: String? = LaunchArguments.value("--select")
    @State private var importing = false
    @State private var newSynth = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SFX Lab").font(.headline)
                Spacer()
                Button("Import WAV…", systemImage: "square.and.arrow.down") { importing = true }
                    .help("Resample, normalize and encode a WAV into a new sample")
                Button("New synth…", systemImage: "waveform.path") { newSynth = true }
                    .help("Generate a retro sound and encode it into a new sample")
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider()
            // A plain list column: a nested NavigationSplitView sizes its
            // columns from the editor's ideal width and pushes the window.
            HStack(spacing: 0) {
                List(project.samples.keys.sorted(), id: \.self, selection: $selection) { Text($0) }
                    .frame(width: 180)
                Divider()
                if let id = selection, let meta = project.samples[id] {
                    SFXLabEditor(store: store, id: id, saved: meta).id(id)
                } else {
                    ContentUnavailableView("SFX", systemImage: "waveform", description: Text("Select a sample, import a WAV or make a synth sound"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            PlaybackBar(store: store)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.wav], allowsMultipleSelection: false) { picked in
            if case .success(let urls) = picked, let url = urls.first { importWAV(url) }
        }
        .sheet(isPresented: $newSynth) {
            SynthSheet(store: store) { id in selection = id }
        }
    }

    private func importWAV(_ url: URL) {
        let id = store.newSampleID(url.deletingPathExtension().lastPathComponent)
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let wav = try WAV.read(url: url)
                let report = try await ProjectStore.encodeWAV(url, options: .init())
                var meta = report.meta
                meta.source?.wav = url.path
                meta.source?.sourceRate = wav.sampleRate
                if store.saveSample(id: id, blocks: report.encoded.blocks, meta: meta) {
                    store.statusMessage = String(format: "imported %@ as %@: SNR %.1f dB", url.lastPathComponent, id, report.snrDB)
                    selection = id
                }
            } catch {
                store.statusMessage = "WAV import failed: \(error)"
                store.statusIsError = true
            }
        }
    }
}

/// One sample: waveform and loop, encode, envelope, voice effects, play, save.
struct SFXLabEditor: View {
    let store: ProjectStore
    let id: String
    let saved: SampleMeta
    @State private var meta: SampleMeta
    @State private var blocks: [UInt8] = []
    @State private var decoded: [Int16] = []
    @State private var envelope: DSPEnvelope.Setting
    @State private var samplesPerPoint = 8.0
    @State private var importOptions = SFXImport.Options()
    @State private var report = ""
    @State private var busy = false

    init(store: ProjectStore, id: String, saved: SampleMeta) {
        self.store = store; self.id = id; self.saved = saved
        _meta = State(initialValue: saved)
        _envelope = State(initialValue: DSPEnvelope.Setting(sample: saved))
    }

    /// The sidecar as edited, envelope included.
    private var edited: SampleMeta {
        var m = meta
        envelope.apply(to: &m)
        return m
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                GroupBox("Waveform (S-DSP decode)") { waveform }
                GroupBox("Encode") { encodeControls }
                if meta.synth != nil {
                    GroupBox("Synth") { SynthControls(spec: Binding(get: { meta.synth! }, set: { meta.synth = $0 })) }
                }
                GroupBox("Envelope") { EnvelopeShaper(setting: $envelope, fx: $meta.fx) }
                GroupBox("Pitch, vibrato and noise") { VoiceFXControls(meta: $meta) }
                GroupBox("Use in game") { SampleUseInGameView(store: store, id: id, unsaved: edited != saved) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The content's ideal width (the waveform is as wide as the sample) must
        // not size the split view's columns.
        .frame(minWidth: 320, idealWidth: 480, maxWidth: .infinity)
        .onAppear(perform: reload)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(id).font(.title3.bold())
            Text(meta.brr).font(.caption.monospaced()).foregroundStyle(.secondary)
            Spacer()
            if busy { ProgressView().controlSize(.small) }
            Button("Play", systemImage: "play.fill") {
                guard !blocks.isEmpty else { return }
                store.playSample(blocks: blocks, meta: edited, title: id)
            }
            .keyboardShortcut("p", modifiers: .command)
            .help("Play on the S-DSP with these settings (live, unsaved edits included)")
            .disabled(blocks.isEmpty)
            Button("Save", systemImage: "square.and.arrow.down.on.square") {
                store.saveSample(id: id, blocks: blocks, meta: edited)
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(blocks.isEmpty)
        }
    }

    private var waveform: some View {
        VStack(alignment: .leading, spacing: 6) {
            WaveformView(samples: decoded, loop: meta.loop,
                         loopStart: Binding(get: { meta.loopStartSample ?? 0 }, set: { meta.loopStartSample = $0 }),
                         loopEnd: Binding(get: { meta.loopEndSample ?? decoded.count }, set: { meta.loopEndSample = $0 }),
                         samplesPerPoint: samplesPerPoint)
                .frame(minWidth: 240, idealWidth: 480, maxWidth: .infinity, minHeight: 160, maxHeight: 160)
            HStack(spacing: 12) {
                Toggle("Loop", isOn: $meta.loop)
                if meta.loop {
                    let start = meta.loopStartSample ?? 0, end = meta.loopEndSample ?? decoded.count
                    Text("blocks \(start / 16)..<\((end + 15) / 16)  (samples \(start)..<\(end))").monospacedDigit()
                    if let seam = seamError { Text("seam \(seam)").foregroundStyle(seam == 0 ? Color.secondary : Color.orange)
                        .help("Largest difference between the loop's first pass and a repeat (15-bit units); 0 cannot click. Re-encode to force filter 0 on the loop block.") }
                }
            }
            .font(.caption)
            HStack(spacing: 12) {
                Text("Zoom")
                Slider(value: Binding(get: { -log2(samplesPerPoint) }, set: { samplesPerPoint = pow(2, -$0) }), in: -8...3)
                    .frame(width: 140)
                Text(samplesPerPoint >= 1 ? "\(Int(samplesPerPoint)) samples/pt" : "\(Int(1 / samplesPerPoint)) pt/sample")
                    .monospacedDigit()
                Spacer()
                Text("\(blocks.count / 9) blocks, \(decoded.count) samples" + String(format: ", %.3f s at %d Hz", Double(decoded.count) / Double(meta.rate ?? 32000), meta.rate ?? 32000))
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
    }

    /// The loop block decoded on the first pass and after a jump back.
    private var seamError: Int? {
        guard meta.loop, !blocks.isEmpty else { return nil }
        let start = (meta.loopStartSample ?? 0) / 16
        let end = min(blocks.count / 9, ((meta.loopEndSample ?? decoded.count) + 15) / 16)
        guard start < end else { return nil }
        let loop = Array(blocks.prefix(9 * end))
        let played = BRR.decodeDSPLooping(loop, loopBlock: start, passes: 1)
        let first = played[(start * 16)..<(end * 16)], again = played[(end * 16)...]
        return zip(first, again).map { abs(Int($0) - Int($1)) }.max()
    }

    private var encodeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let source = meta.source {
                Text("Source: \(source.wav ?? "—")" + (source.sourceRate.map { " (\($0) Hz)" } ?? ""))
                    .font(.caption).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 600, alignment: .leading)
                HStack {
                    if let snr = source.snrDB { Text(String(format: "SNR %.2f dB", snr)) }
                    if let e = source.maxError { Text("max error \(e)") }
                }
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Picker("Rate", selection: Binding(get: { importOptions.rate ?? meta.rate ?? 32000 }, set: { importOptions.rate = $0 })) {
                    ForEach([8000, 11025, 16000, 22050, 32000], id: \.self) { Text("\($0) Hz").tag($0) }
                }
                .frame(width: 160)
                Stepper("Beam \(importOptions.beam)", value: $importOptions.beam, in: 1...16)
                if meta.synth == nil {
                    Stepper("Crossfade \(importOptions.crossfade)", value: $importOptions.crossfade, in: 0...1024, step: 16)
                    Toggle("Normalize −1 dBFS", isOn: Binding(get: { importOptions.normalizeDBFS != nil }, set: { importOptions.normalizeDBFS = $0 ? -1 : nil }))
                }
            }
            .font(.caption)
            HStack {
                Button(meta.synth != nil ? "Regenerate and encode" : "Re-encode from source") { reencode() }
                    .disabled(busy || (meta.synth == nil && meta.source?.wav == nil))
                    .help("Encode again with these settings and the loop above (loop block forced to filter 0)")
                Text(report).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private func reload() {
        guard let b = store.sampleBlocks(saved) else { blocks = []; decoded = []; return }
        blocks = b
        decoded = BRR.decodeDSP(b)
        if meta.loopEndSample == nil, meta.loop { meta.loopEndSample = decoded.count }
    }

    private func reencode() {
        busy = true
        let meta = self.meta
        var options = importOptions
        Task {
            defer { busy = false }
            do {
                let r: SFXImport.Report
                if var spec = meta.synth {
                    spec.rate = options.rate ?? spec.rate
                    self.meta.synth = spec
                    r = try await ProjectStore.encodeSynth(spec, beam: options.beam)
                } else if let path = meta.source?.wav {
                    let url = URL(fileURLWithPath: path)
                    let source = try WAV.read(url: url)
                    if meta.loop, let start = meta.loopStartSample {
                        // The loop in output samples, back in source samples.
                        let ratio = Double(source.sampleRate) / Double(meta.rate ?? 32000)
                        options.loopStart = Int((Double(start) * ratio).rounded())
                        options.loopEnd = min(source.samples.count, Int((Double(meta.loopEndSample ?? decoded.count) * ratio).rounded()))
                    }
                    r = try await ProjectStore.encodeWAV(url, options: options)
                } else { return }
                blocks = r.encoded.blocks
                decoded = r.encoded.decoded
                let fresh = r.meta
                self.meta.rate = fresh.rate
                self.meta.loop = fresh.loop
                self.meta.loopStartSample = fresh.loopStartSample
                self.meta.loopEndSample = fresh.loopEndSample
                if meta.synth == nil {
                    var src = fresh.source ?? SampleSource()
                    src.wav = meta.source?.wav; src.sourceRate = meta.source?.sourceRate
                    self.meta.source = src
                }
                report = String(format: "SNR %.2f dB, max error %d", r.snrDB, r.maxError)
                    + (r.loopSeamError.map { ", seam \($0)" } ?? "") + " — Save to keep"
            } catch {
                report = "encode failed: \(error)"
            }
        }
    }
}
