// SFXSynth.swift — retro sound generators (pulse, saw, triangle, sine,
// noise, two-operator FM blips) rendered to 16-bit PCM for BRR encoding.
// The parameters live in the sample's sidecar (`synth`), so a sample can be
// regenerated and re-encoded.
import Foundation

public struct SynthSpec: Codable, Equatable, Sendable {
    public enum Wave: String, Codable, CaseIterable, Identifiable, Sendable {
        case pulse, saw, triangle, sine, noise, fm
        public var id: String { rawValue }
    }

    public var wave: Wave
    /// Start frequency in Hz; for noise, how often a new random value is held.
    public var frequency: Double
    /// Frequency at the end of the sound (an exponential sweep); nil: none.
    public var endFrequency: Double?
    /// Length of a one-shot in seconds (a loop is one block-aligned cycle set).
    public var duration: Double
    /// Pulse duty cycle, 0.01-0.99.
    public var duty: Double
    /// FM: modulator frequency ratio, peak index and index decay per second.
    public var fmRatio: Double
    public var fmIndex: Double
    public var fmDecay: Double
    /// Amplitude decay per second (exponential); 0 holds.
    public var decay: Double
    /// Peak amplitude, 0-1 of full scale.
    public var amplitude: Double
    public var rate: Int
    /// Noise LFSR seed (nonzero).
    public var seed: Int
    /// Whole periods in whole BRR blocks, looping from the start: a sustained
    /// instrument-style sample. Ignores sweep, decay and duration.
    public var loop: Bool

    public init(wave: Wave = .pulse, frequency: Double = 440, endFrequency: Double? = nil, duration: Double = 0.25,
                duty: Double = 0.5, fmRatio: Double = 2, fmIndex: Double = 3, fmDecay: Double = 6, decay: Double = 0,
                amplitude: Double = 0.9, rate: Int = 32000, seed: Int = 1, loop: Bool = false) {
        self.wave = wave; self.frequency = frequency; self.endFrequency = endFrequency; self.duration = duration
        self.duty = duty; self.fmRatio = fmRatio; self.fmIndex = fmIndex; self.fmDecay = fmDecay; self.decay = decay
        self.amplitude = amplitude; self.rate = rate; self.seed = seed; self.loop = loop
    }

    enum CodingKeys: String, CodingKey {
        case wave, frequency, endFrequency, duration, duty, fmRatio, fmIndex, fmDecay, decay, amplitude, rate, seed, loop
    }

    /// Missing keys take the defaults, so a hand-written spec can be short.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SynthSpec()
        wave = try c.decodeIfPresent(Wave.self, forKey: .wave) ?? d.wave
        frequency = try c.decodeIfPresent(Double.self, forKey: .frequency) ?? d.frequency
        endFrequency = try c.decodeIfPresent(Double.self, forKey: .endFrequency)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? d.duration
        duty = try c.decodeIfPresent(Double.self, forKey: .duty) ?? d.duty
        fmRatio = try c.decodeIfPresent(Double.self, forKey: .fmRatio) ?? d.fmRatio
        fmIndex = try c.decodeIfPresent(Double.self, forKey: .fmIndex) ?? d.fmIndex
        fmDecay = try c.decodeIfPresent(Double.self, forKey: .fmDecay) ?? d.fmDecay
        decay = try c.decodeIfPresent(Double.self, forKey: .decay) ?? d.decay
        amplitude = try c.decodeIfPresent(Double.self, forKey: .amplitude) ?? d.amplitude
        rate = try c.decodeIfPresent(Int.self, forKey: .rate) ?? d.rate
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? d.seed
        loop = try c.decodeIfPresent(Bool.self, forKey: .loop) ?? d.loop
    }
}

public enum SFXSynth {
    public struct Output: Sendable {
        public var pcm: [Int16]
        public var rate: Int
        /// A looping spec's loop (the whole sample).
        public var loop: Range<Int>?
        /// The frequency actually played (a loop rounds to whole samples per period).
        public var frequency: Double
    }

    public static func validate(_ spec: SynthSpec) throws {
        guard (1000...SPCRender.sampleRate).contains(spec.rate) else { throw CTSongError("synth rate must be 1000...32000 Hz") }
        guard spec.frequency > 0, spec.frequency < Double(spec.rate) / 2 else { throw CTSongError("frequency must be between 0 and half the rate") }
        if let f = spec.endFrequency { guard f > 0, f < Double(spec.rate) / 2 else { throw CTSongError("end frequency must be between 0 and half the rate") } }
        guard spec.duration > 0, spec.duration <= 10 else { throw CTSongError("duration must be 0...10 s") }
        guard (0...1).contains(spec.amplitude) else { throw CTSongError("amplitude must be 0...1") }
    }

    public static func render(_ spec: SynthSpec) throws -> Output {
        try validate(spec)
        let rate = Double(spec.rate)
        var count = max(16, Int((spec.duration * rate).rounded()))
        var frequency = spec.frequency
        var loop: Range<Int>?
        if spec.loop {
            if spec.wave == .noise {
                count = (count + 15) / 16 * 16
            } else {
                // Whole samples per period, and enough periods to fill whole blocks.
                let period = max(2, Int((rate / spec.frequency).rounded()))
                frequency = rate / Double(period)
                count = period * (16 / gcd(period, 16))
                while count < 64 { count *= 2 }
            }
            loop = 0..<count
        }
        var out = [Int16](repeating: 0, count: count)
        var phase = 0.0, modPhase = 0.0, held = 0.0, lfsr = UInt32(truncatingIfNeeded: spec.seed == 0 ? 1 : spec.seed) & 0x7FFF
        if lfsr == 0 { lfsr = 1 }
        let duty = max(0.01, min(0.99, spec.duty))
        for i in 0..<count {
            let t = Double(i) / rate
            let f = spec.loop || spec.endFrequency == nil
                ? frequency
                : spec.frequency * pow(spec.endFrequency! / spec.frequency, Double(i) / Double(count))
            let dt = f / rate
            var v: Double
            switch spec.wave {
            case .pulse:
                v = (phase < duty ? 1 : -1) + blep(phase, dt) - blep((phase - duty + 1).truncatingRemainder(dividingBy: 1), dt)
            case .saw:
                v = 2 * phase - 1 - blep(phase, dt)
            case .triangle:
                v = phase < 0.5 ? 4 * phase - 1 : 3 - 4 * phase
            case .sine:
                v = sin(2 * .pi * phase)
            case .noise:
                if i == 0 || phase + dt >= 1 {
                    // 15-bit Galois LFSR, the classic retro noise source.
                    let bit = lfsr & 1
                    lfsr >>= 1
                    if bit != 0 { lfsr ^= 0x6000 }
                    held = Double(Int(lfsr & 0x7FFF) - 0x4000) / 0x4000
                }
                v = held
            case .fm:
                let index = spec.loop ? spec.fmIndex : spec.fmIndex * exp(-spec.fmDecay * t)
                v = sin(2 * .pi * phase + index * sin(2 * .pi * modPhase))
                modPhase = (modPhase + dt * spec.fmRatio).truncatingRemainder(dividingBy: 1)
            }
            phase += dt
            if phase >= 1 { phase -= 1 }
            if !spec.loop { v *= exp(-spec.decay * t) }
            out[i] = Int16(max(-32768, min(32767, (v * spec.amplitude * 32767).rounded())))
        }
        return Output(pcm: out, rate: spec.rate, loop: loop, frequency: frequency)
    }

    /// PolyBLEP step correction at a discontinuity of the phase wrap.
    static func blep(_ t: Double, _ dt: Double) -> Double {
        if t < dt { let x = t / dt; return x + x - x * x - 1 }
        if t > 1 - dt { let x = (t - 1) / dt; return x * x + x + x + 1 }
        return 0
    }

    static func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    /// Synthesize and encode: the import pipeline without resampling
    /// (normalizing only when `normalizeDBFS` is set).
    public static func encode(_ spec: SynthSpec, normalizeDBFS: Double? = nil, beam: Int = 4) throws -> SFXImport.Report {
        let out = try render(spec)
        var options = SFXImport.Options()
        options.normalizeDBFS = normalizeDBFS
        options.beam = beam
        if let loop = out.loop { options.loopStart = loop.lowerBound; options.loopEnd = loop.upperBound }
        let prepared = try SFXImport.prepare(out.pcm, rate: out.rate, options: options)
        return SFXImport.encode(prepared, options: options)
    }
}
