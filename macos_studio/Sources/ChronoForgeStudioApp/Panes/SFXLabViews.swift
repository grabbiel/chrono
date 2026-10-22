// SFXLabViews.swift — the SFX Lab's waveform and loop scrubber, envelope
// shaper (the curve is the S-DSP's own output), voice effects and synth.
import SwiftUI
import ChronoForgeCore

/// Decoded samples with a zoom, a 16-sample BRR block grid and a loop whose
/// start and end handles snap to blocks.
struct WaveformView: View {
    let samples: [Int16]
    let loop: Bool
    @Binding var loopStart: Int
    @Binding var loopEnd: Int
    let samplesPerPoint: Double
    @State private var dragging: Int?   // 0: start handle, 1: end handle

    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                let width = max(geo.size.width, CGFloat(Double(samples.count) / samplesPerPoint))
                Canvas { context, size in draw(context, size) }
                    .frame(width: width, height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(loop ? scrub : nil)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func x(_ sample: Int) -> CGFloat { CGFloat(Double(sample) / samplesPerPoint) }

    private func snapped(_ x: CGFloat) -> Int {
        let sample = Double(x) * samplesPerPoint
        let blocks = max(1, samples.count / 16)
        return min(blocks, max(0, Int((sample / 16).rounded()))) * 16
    }

    private var scrub: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                if dragging == nil {
                    dragging = abs(g.startLocation.x - x(loopStart)) <= abs(g.startLocation.x - x(loopEnd)) ? 0 : 1
                }
                let s = snapped(g.location.x)
                if dragging == 0 { loopStart = min(s, loopEnd - 16) } else { loopEnd = max(s, loopStart + 16) }
            }
            .onEnded { _ in dragging = nil }
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        let mid = size.height / 2, scale = (size.height / 2 - 4) / 16384
        if loop {
            context.fill(Path(CGRect(x: x(loopStart), y: 0, width: x(loopEnd) - x(loopStart), height: size.height)),
                         with: .color(.accentColor.opacity(0.12)))
        }
        // Block grid once blocks are at least 6 points wide; every 8th block darker.
        if 16 / samplesPerPoint >= 6 {
            var thin = Path(), thick = Path()
            for b in 0...(samples.count / 16) {
                let px = x(b * 16)
                if b % 8 == 0 { thick.move(to: .init(x: px, y: 0)); thick.addLine(to: .init(x: px, y: size.height)) }
                else { thin.move(to: .init(x: px, y: 0)); thin.addLine(to: .init(x: px, y: size.height)) }
            }
            context.stroke(thin, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
            context.stroke(thick, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
        }
        var axis = Path(); axis.move(to: .init(x: 0, y: mid)); axis.addLine(to: .init(x: size.width, y: mid))
        context.stroke(axis, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
        guard !samples.isEmpty else { return }
        var wave = Path()
        if samplesPerPoint <= 1 {
            for (i, s) in samples.enumerated() {
                let p = CGPoint(x: x(i), y: mid - CGFloat(s) * scale)
                if i == 0 { wave.move(to: p) } else { wave.addLine(to: p) }
            }
            context.stroke(wave, with: .color(.primary), lineWidth: 1)
        } else {
            let columns = Int(ceil(Double(samples.count) / samplesPerPoint))
            for c in 0..<columns {
                let lo = Int(Double(c) * samplesPerPoint), hi = min(samples.count, max(lo + 1, Int(Double(c + 1) * samplesPerPoint)))
                guard lo < hi else { break }
                var mn = Int16.max, mx = Int16.min
                for s in samples[lo..<hi] { mn = min(mn, s); mx = max(mx, s) }
                wave.move(to: .init(x: CGFloat(c), y: mid - CGFloat(mx) * scale))
                wave.addLine(to: .init(x: CGFloat(c), y: mid - CGFloat(mn) * scale + 0.5))
            }
            context.stroke(wave, with: .color(.primary), lineWidth: 1)
        }
        if loop {
            for (i, at) in [loopStart, loopEnd].enumerated() {
                var handle = Path()
                handle.move(to: .init(x: x(at), y: 0)); handle.addLine(to: .init(x: x(at), y: size.height))
                context.stroke(handle, with: .color(.accentColor), lineWidth: dragging == i ? 2.5 : 1.5)
                let tip = Path { p in
                    p.move(to: .init(x: x(at) - 6, y: 0)); p.addLine(to: .init(x: x(at) + 6, y: 0)); p.addLine(to: .init(x: x(at), y: 9))
                    p.closeSubpath()
                }
                context.fill(tip, with: .color(.accentColor))
            }
        }
    }
}

/// ADSR or GAIN mode and their fields, with the envelope the S-DSP produces
/// for them (rendered by `DSPEnvelope`, read back from its output).
struct EnvelopeShaper: View {
    @Binding var setting: DSPEnvelope.Setting
    @Binding var fx: SampleFX?
    @State private var curve: DSPEnvelope.Curve?
    @State private var seconds = 1.5
    @State private var error: String?

    private var keyOff: Int? { fx?.keyOffTick }
    private var divider: Int { fx?.tickDivider ?? 32 }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Mode", selection: $setting.mode) {
                    ForEach(DSPEnvelope.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 230)
                switch setting.mode {
                case .adsr:
                    field("Attack", $setting.attack, 0...15)
                    field("Decay", $setting.decay, 0...7)
                    field("Sustain level", $setting.sustainLevel, 0...7)
                    field("Sustain rate", $setting.sustainRate, 0...31)
                case .direct:
                    field("Level", $setting.level, 0...127)
                default:
                    field("Rate", $setting.rate, 0...31)
                    Toggle("Start level", isOn: Binding(get: { setting.startLevel != nil }, set: { setting.startLevel = $0 ? 127 : nil }))
                    if setting.startLevel != nil {
                        field("  from", Binding(get: { setting.startLevel ?? 0 }, set: { setting.startLevel = $0 }), 0...127)
                    }
                }
                Toggle("Key off (preview)", isOn: Binding(get: { keyOff != nil }, set: { on in updateFX { $0.keyOffTick = on ? 100 : nil } }))
                if let k = keyOff {
                    field("  at tick", Binding(get: { k }, set: { v in updateFX { $0.keyOffTick = v } }), 0...2000)
                    Text(String(format: "%.0f ms", Double(k + 1) * SFXPitch.tickSeconds(divider: divider) * 1000))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(registerText).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            .frame(width: 240)
            VStack(alignment: .leading, spacing: 4) {
                Canvas { context, size in draw(context, size) }
                    .frame(minWidth: 180, idealWidth: 360, maxWidth: .infinity, minHeight: 150)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack {
                    Text("S-DSP envelope, \(String(format: "%.2f", seconds)) s").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $seconds, in: 0.1...8).frame(width: 100)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
        }
        .task(id: TaskKey(setting: setting, keyOff: keyOff, divider: divider, seconds: seconds)) {
            try? await Task.sleep(for: .milliseconds(120))   // debounce slider drags
            guard !Task.isCancelled else { return }
            do {
                curve = try await ProjectStore.envelopeCurve(setting, keyOffTick: keyOff, tickDivider: UInt8(divider & 0xFF), seconds: seconds)
                error = nil
            } catch { self.error = "\(error)" }
        }
    }

    private struct TaskKey: Equatable { var setting: DSPEnvelope.Setting; var keyOff: Int?; var divider: Int; var seconds: Double }

    private func updateFX(_ change: (inout SampleFX) -> Void) {
        var f = fx ?? SampleFX()
        change(&f)
        fx = f == SampleFX() ? nil : f
    }

    private var registerText: String {
        if let (a1, a2) = setting.adsrRegisters { return String(format: "ADSR1 $%02X  ADSR2 $%02X", a1, a2) }
        return String(format: "GAIN $%02X", setting.gainRegister) + (setting.startLevel.map { String(format: " (from $%02X)", $0) } ?? "")
    }

    private func field(_ label: String, _ value: Binding<Int>, _ range: ClosedRange<Int>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
            Text("\(value.wrappedValue)").monospacedDigit().frame(width: 34, alignment: .trailing)
        }
        .font(.caption)
    }

    private func draw(_ context: GraphicsContext, _ size: CGSize) {
        guard let curve, !curve.levels.isEmpty else { return }
        let h = size.height - 8
        var grid = Path()
        for level in stride(from: 0, through: 0x800, by: 0x200) {
            let y = 4 + h - CGFloat(level) / 0x800 * h
            grid.move(to: .init(x: 0, y: y)); grid.addLine(to: .init(x: size.width, y: y))
        }
        context.stroke(grid, with: .color(.secondary.opacity(0.2)), lineWidth: 0.5)
        let total = CGFloat(curve.levels.count * curve.stride)
        if let k = curve.keyOffFrame, CGFloat(k) < total {
            var mark = Path()
            let px = CGFloat(k) / total * size.width
            mark.move(to: .init(x: px, y: 0)); mark.addLine(to: .init(x: px, y: size.height))
            context.stroke(mark, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        var line = Path()
        for (i, level) in curve.levels.enumerated() {
            let p = CGPoint(x: CGFloat(i * curve.stride) / total * size.width, y: 4 + h - CGFloat(level) / 0x800 * h)
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
    }
}

/// Rate, pitch bend, vibrato, noise and the tick length.
struct VoiceFXControls: View {
    @Binding var meta: SampleMeta

    private var fx: SampleFX { meta.fx ?? SampleFX() }
    private func set(_ change: (inout SampleFX) -> Void) {
        var f = fx
        change(&f)
        meta.fx = f == SampleFX() ? nil : f
    }

    var body: some View {
        let voice = SPCStream.Voice(sample: meta)
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                row("Rate (Hz)", Double(meta.rate ?? 32000), 1000...64000, 1) { meta.rate = Int($0) }
                Text(String(format: "pitch $%04X", voice.pitch)).font(.caption.monospaced()).foregroundStyle(.secondary)
                row("Tick (÷)", Double(fx.tickDivider ?? 32), 1...256, 1) { v in set { $0.tickDivider = Int(v) == 32 ? nil : Int(v) } }
                Text(String(format: "%.3f ms per tick", SFXPitch.tickSeconds(divider: fx.tickDivider ?? 32) * 1000))
                    .font(.caption).foregroundStyle(.secondary)
                row("Bend (semitones)", fx.bendSemitones ?? 0, -24...24, 0.5) { v in set { $0.bendSemitones = v == 0 ? nil : v } }
                row("  over ticks", Double(fx.bendTicks ?? 0), 0...500, 1) { v in set { $0.bendTicks = v == 0 ? nil : Int(v) } }
                row("Vibrato (cents)", fx.vibratoCents ?? 0, 0...200, 1) { v in set { $0.vibratoCents = v == 0 ? nil : v } }
                row("  period ticks", Double(fx.vibratoPeriodTicks ?? 16), 2...128, 1) { v in set { $0.vibratoPeriodTicks = Int(v) } }
                row("  delay ticks", Double(fx.vibratoDelayTicks ?? 0), 0...500, 1) { v in set { $0.vibratoDelayTicks = v == 0 ? nil : Int(v) } }
                Toggle("Noise channel (NON)", isOn: Binding(get: { fx.noise ?? false }, set: { on in set { $0.noise = on ? true : nil } }))
                if fx.noise == true {
                    row("  noise clock", Double(fx.noiseClock ?? 0), 0...31, 1) { v in set { $0.noiseClock = Int(v) } }
                    Text(String(format: "%.0f Hz", SFXPitch.noiseHz(clock: fx.noiseClock ?? 0))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 290)
            VStack(alignment: .leading, spacing: 4) {
                Canvas { context, size in drawPitch(voice, context, size) }
                    .frame(minWidth: 160, idealWidth: 300, maxWidth: .infinity, minHeight: 120)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                Text(voice.pitchCurve.isEmpty ? "Fixed pitch" :
                        "\(voice.pitchCurve.count) ticks per curve" + (voice.pitchRepeatFrom.map { ", repeating from tick \($0)" } ?? ", then held")
                        + " — written to the S-DSP by the preview's SPC700 tick program")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: String, _ value: Double, _ range: ClosedRange<Double>, _ step: Double, _ set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(label).frame(width: 104, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set(($0 / step).rounded() * step) }), in: range)
            Text(step < 1 ? String(format: "%.1f", value) : "\(Int(value))").monospacedDigit().frame(width: 52, alignment: .trailing)
        }
        .font(.caption)
    }

    private func drawPitch(_ voice: SPCStream.Voice, _ context: GraphicsContext, _ size: CGSize) {
        let curve = voice.pitchCurve.isEmpty ? [voice.pitch, voice.pitch] : voice.pitchCurve + [voice.pitchCurve.last!]
        let lo = Double(curve.min()!) * 0.98, hi = max(lo + 1, Double(curve.max()!) * 1.02)
        var line = Path()
        for (i, p) in curve.enumerated() {
            let pt = CGPoint(x: CGFloat(i) / CGFloat(curve.count - 1) * size.width,
                             y: size.height - CGFloat((Double(p) - lo) / (hi - lo)) * size.height)
            if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
        }
        context.stroke(line, with: .color(.accentColor), lineWidth: 1.5)
    }
}

/// A synth spec's fields.
struct SynthControls: View {
    @Binding var spec: SynthSpec

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Wave", selection: $spec.wave) { ForEach(SynthSpec.Wave.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 360)
            row("Frequency (Hz)", $spec.frequency, 20...8000)
            Toggle("Sweep", isOn: Binding(get: { spec.endFrequency != nil }, set: { spec.endFrequency = $0 ? spec.frequency / 2 : nil }))
            if spec.endFrequency != nil {
                row("  to (Hz)", Binding(get: { spec.endFrequency ?? spec.frequency }, set: { spec.endFrequency = $0 }), 20...8000)
            }
            row("Duration (s)", $spec.duration, 0.02...3)
            if spec.wave == .pulse { row("Duty", $spec.duty, 0.05...0.95) }
            if spec.wave == .fm {
                row("FM ratio", $spec.fmRatio, 0.25...8)
                row("FM index", $spec.fmIndex, 0...12)
                row("FM decay (/s)", $spec.fmDecay, 0...40)
            }
            row("Decay (/s)", $spec.decay, 0...40)
            row("Amplitude", $spec.amplitude, 0.05...1)
            Toggle("Loop (whole periods in whole blocks)", isOn: $spec.loop)
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range).frame(width: 220)
            Text(String(format: value.wrappedValue < 10 ? "%.2f" : "%.0f", value.wrappedValue)).monospacedDigit().frame(width: 52, alignment: .trailing)
        }
    }
}

/// New sample from a synth spec: generate, encode, save, select.
struct SynthSheet: View {
    let store: ProjectStore
    let created: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var spec = SynthSpec(wave: .fm, frequency: 880, endFrequency: 440, duration: 0.25, decay: 8)
    @State private var id = ""
    @State private var busy = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New synth sample").font(.headline)
            TextField("Sample id", text: $id, prompt: Text(store.newSampleID("synth_\(spec.wave.rawValue)")))
                .frame(width: 260)
            SynthControls(spec: $spec)
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate") { generate() }.keyboardShortcut(.defaultAction).disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    private func generate() {
        busy = true
        let spec = spec
        let name = store.newSampleID(id.isEmpty ? "synth_\(spec.wave.rawValue)" : id)
        Task {
            defer { busy = false }
            do {
                let report = try await ProjectStore.encodeSynth(spec, beam: 4)
                var meta = report.meta
                meta.synth = spec
                meta.source = nil
                if store.saveSample(id: name, blocks: report.encoded.blocks, meta: meta) {
                    store.statusMessage = String(format: "generated %@: SNR %.1f dB", name, report.snrDB)
                    created(name)
                    dismiss()
                }
            } catch { note = "\(error)" }
        }
    }
}
