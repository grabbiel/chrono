// DSPEnvelope.swift — ADSR/GAIN settings as S-DSP register values, and the
// envelope the S-DSP actually produces for them, read from `SDSP` while a
// preview voice plays (not computed from a formula).
import Foundation

public enum DSPEnvelope {
    /// ADSR, or one of GAIN's five modes (fullsnes "ADSR/Gain Envelope").
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case adsr = "ADSR"
        case direct = "Direct"
        case linearIncrease = "Linear increase"
        case bentIncrease = "Bent increase"
        case linearDecrease = "Linear decrease"
        case exponentialDecrease = "Exponential decrease"
        public var id: String { rawValue }
    }

    public struct Setting: Equatable, Sendable {
        public var mode: Mode = .adsr
        /// ADSR: attack 0-15, decay 0-7, sustain level 0-7, sustain rate 0-31.
        public var attack = 15, decay = 7, sustainLevel = 7, sustainRate = 0
        /// GAIN direct level 0-127.
        public var level = 127
        /// GAIN increase/decrease rate 0-31.
        public var rate = 28
        /// GAIN direct level at key-on before the envelope takes over (`SampleFX.gainStart`).
        public var startLevel: Int?
        public init() {}

        public init(adsr: (UInt8, UInt8)?, gain: UInt8, startLevel: Int? = nil) {
            self.startLevel = startLevel
            if let (a1, a2) = adsr, a1 & 0x80 != 0 {
                mode = .adsr
                attack = Int(a1 & 0x0F); decay = Int(a1 >> 4 & 7)
                sustainLevel = Int(a2 >> 5); sustainRate = Int(a2 & 0x1F)
            } else if gain & 0x80 == 0 {
                mode = .direct; level = Int(gain)
            } else {
                mode = [.linearDecrease, .exponentialDecrease, .linearIncrease, .bentIncrease][Int(gain >> 5 & 3)]
                rate = Int(gain & 0x1F)
            }
        }

        /// The envelope a sidecar plays with (`SPCStream.Voice(sample:)`).
        public init(sample meta: SampleMeta) {
            let voice = SPCStream.Voice(sample: meta)
            self.init(adsr: voice.adsr, gain: voice.gain, startLevel: voice.gainStart.map(Int.init))
        }

        public var adsrRegisters: (UInt8, UInt8)? {
            guard mode == .adsr else { return nil }
            return (UInt8(0x80 | (decay & 7) << 4 | attack & 15), UInt8((sustainLevel & 7) << 5 | sustainRate & 31))
        }

        public var gainRegister: UInt8 {
            switch mode {
            case .adsr: return 0
            case .direct: return UInt8(level & 0x7F)
            case .linearDecrease: return UInt8(0x80 | rate & 31)
            case .exponentialDecrease: return UInt8(0xA0 | rate & 31)
            case .linearIncrease: return UInt8(0xC0 | rate & 31)
            case .bentIncrease: return UInt8(0xE0 | rate & 31)
            }
        }

        /// Writes the setting into a sidecar: `adsr` as the four fields
        /// (ADSR) or nil (GAIN), `gain` as the register byte, `fx.gainStart`.
        public func apply(to meta: inout SampleMeta) {
            if mode == .adsr {
                meta.adsr = [attack, decay, sustainLevel, sustainRate]
            } else {
                meta.adsr = nil
                meta.gain = Int(gainRegister)
            }
            var fx = meta.fx ?? SampleFX()
            fx.gainStart = startLevel
            meta.fx = fx == SampleFX() ? nil : fx
        }

        func apply(to voice: inout SPCStream.Voice) {
            voice.adsr = adsrRegisters
            if mode != .adsr { voice.gain = gainRegister }
            voice.gainStart = startLevel.map { UInt8(max(0, min(127, $0))) }
        }
    }

    public struct Curve: Sendable {
        /// The 11-bit envelope level of every `stride`-th output frame.
        public var levels: [Int]
        public var stride: Int
        /// Frame of the key-off tick, if any.
        public var keyOffFrame: Int?
        public var seconds: Double { Double(levels.count * stride) / Double(SPCRender.sampleRate) }
    }

    /// The DC sample the curve is measured with: shift 12, filter 0, nibble 7,
    /// looping (15-bit value 14336).
    static let dcBlock: [UInt8] = [0xC3] + [UInt8](repeating: 0x77, count: 8)

    /// Output frame value (voice and main volume $7F) for each envelope
    /// level 0...$7FF of the DC sample; strictly increasing, so a frame
    /// gives back the level it was played at.
    static let dcFrames: [Int] = {
        let g = SDSP.gaussian(14336, 14336, 14336, 14336, index: 0)
        return (0...0x7FF).map { level in
            let voice = SDSP.clamp((((g * level) >> 11) * 0x7F) >> 6)
            return SDSP.clamp(SDSP.wrap((voice * 0x7F) >> 7))
        }
    }()

    /// Plays a full-scale DC sample with `setting` through the preview
    /// stream (`SPCStream.sample`: the same key-on, GAIN hand-over and
    /// key-off ticks the preview uses) for `frames` output frames, and reads
    /// each frame's envelope level back from the frame itself. The curve is
    /// therefore the envelope the S-DSP applied to the audio, frame by frame.
    public static func render(_ setting: Setting, keyOffTick: Int? = nil, tickDivider: UInt8 = 32,
                              frames: Int, stride: Int = 8) throws -> Curve {
        precondition(frames > 0 && stride > 0)
        var voice = SPCStream.Voice()
        setting.apply(to: &voice)
        voice.keyOffTick = keyOffTick
        voice.tickDivider = tickDivider
        let stream = try SPCStream.sample(brr: dcBlock, loopBlock: 0, voice: voice)
        let pcm = try stream.render(frames: frames)
        var levels: [Int] = []
        levels.reserveCapacity(frames / stride + 1)
        for t in Swift.stride(from: stride - 1, to: frames, by: stride) {
            levels.append(level(frame: Int(pcm[2 * t])))
        }
        let tickFrames = (tickDivider == 0 ? 256 : Int(tickDivider)) * 4   // 128 clocks per divider step, 32 per frame
        return Curve(levels: levels, stride: stride, keyOffFrame: keyOffTick.map { ($0 + 1) * tickFrames })
    }

    /// The envelope level a DC-sample frame was played at.
    static func level(frame value: Int) -> Int {
        var lo = 0, hi = 0x7FF
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if dcFrames[mid] <= value { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
}
