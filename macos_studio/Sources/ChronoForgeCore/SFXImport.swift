// SFXImport.swift — WAV or synthesized PCM to a BRR sample: resample,
// normalize, snap the loop to blocks, crossfade its seam, encode, measure.
import Foundation

/// How a sample's BRR data was made from a WAV, kept in its sidecar so it can
/// be re-encoded. Every field is optional.
public struct SampleSource: Codable, Equatable, Sendable {
    /// Project-relative or absolute path of the source WAV.
    public var wav: String?
    public var sourceRate: Int?
    /// Peak level the PCM was normalized to (dBFS); nil: not normalized.
    public var normalizeDBFS: Double?
    /// Samples (at the sample's rate) crossfaded into the loop's end.
    public var crossfade: Int?
    public var beam: Int?
    /// Measured at encode time: SNR (dB) and largest error (16-bit units)
    /// of the S-DSP decode against the resampled, normalized source.
    public var snrDB: Double?
    public var maxError: Int?
    public init(wav: String? = nil, sourceRate: Int? = nil, normalizeDBFS: Double? = nil, crossfade: Int? = nil,
                beam: Int? = nil, snrDB: Double? = nil, maxError: Int? = nil) {
        self.wav = wav; self.sourceRate = sourceRate; self.normalizeDBFS = normalizeDBFS; self.crossfade = crossfade
        self.beam = beam; self.snrDB = snrDB; self.maxError = maxError
    }
}

public enum SFXImport {
    public struct Options: Equatable, Sendable {
        /// Output rate; nil keeps the source rate up to 32 kHz.
        public var rate: Int?
        /// Peak level in dBFS; nil leaves the level alone.
        public var normalizeDBFS: Double? = -1
        /// Loop points in source samples; both set means the sample loops.
        public var loopStart: Int?, loopEnd: Int?
        /// Crossfade length (output samples) blending the samples before the
        /// loop start into the loop's end, so the jump back is continuous.
        public var crossfade = 0
        public var beam = 4
        public var maxShift = 12
        public init() {}
    }

    public struct Prepared: Sendable {
        public var pcm: [Int16]
        public var rate: Int
        /// Snapped loop in output samples (start and end on 16-sample blocks).
        public var loop: Range<Int>?
        public var gain: Double
    }

    public struct Report: Sendable {
        public var options: Options
        public var prepared: Prepared
        public var encoded: BRREncoder.Result
        public var snrDB: Double
        public var maxError: Int
        /// Largest difference between the loop's first pass and a repeat
        /// pass (15-bit units); 0 means the jump back cannot click from the
        /// filter history.
        public var loopSeamError: Int?
        /// A sidecar for the encoded data (`brr` left for the caller).
        public var meta: SampleMeta {
            var m = SampleMeta(brr: "", rate: prepared.rate, loop: prepared.loop != nil,
                               loopStartSample: prepared.loop?.lowerBound, loopEndSample: prepared.loop?.upperBound)
            m.source = SampleSource(normalizeDBFS: options.normalizeDBFS, crossfade: options.crossfade == 0 ? nil : options.crossfade,
                                    beam: options.beam, snrDB: snrDB.isFinite ? (snrDB * 100).rounded() / 100 : nil, maxError: maxError)
            return m
        }
    }

    // MARK: Pipeline

    /// Resample, loop and normalize 16-bit PCM.
    public static func prepare(_ samples: [Int16], rate sourceRate: Int, options: Options) throws -> Prepared {
        guard sourceRate > 0 else { throw CTSongError("source rate must be positive") }
        let rate = options.rate ?? min(sourceRate, SPCRender.sampleRate)
        guard (1000...SPCRender.sampleRate * 4).contains(rate) else { throw CTSongError("rate \(rate) Hz is outside 1000...128000") }
        var pcm = resample(samples.map(Double.init), from: sourceRate, to: rate)
        var loop: Range<Int>?
        if let start = options.loopStart, let end = options.loopEnd {
            guard 0 <= start, start < end, end <= samples.count else {
                throw CTSongError("loop \(start)..<\(end) is outside the \(samples.count)-sample source")
            }
            let ratio = Double(rate) / Double(sourceRate)
            let snapped = snapLoop(start: Double(start) * ratio, end: Double(end) * ratio, count: pcm.count)
            pcm = Array(pcm.prefix(snapped.upperBound))
            let fade = min(options.crossfade, snapped.lowerBound, snapped.count)
            for i in 0..<fade {
                let w = Double(i + 1) / Double(fade + 1)
                let at = snapped.upperBound - fade + i
                pcm[at] = pcm[at] * (1 - w) + pcm[snapped.lowerBound - fade + i] * w
            }
            loop = snapped
        }
        var gain = 1.0
        if let db = options.normalizeDBFS {
            let peak = pcm.reduce(0) { max($0, abs($1)) }
            if peak > 0 { gain = 32767 * pow(10, db / 20) / peak }
        }
        var out = pcm.map { Int16(max(-32768, min(32767, ($0 * gain).rounded()))) }
        if loop == nil {
            // A non-looping voice is muted as soon as its end block is
            // fetched, before that block plays: end on a silent block.
            out += [Int16](repeating: 0, count: (16 - out.count % 16) % 16 + 16)
        }
        return Prepared(pcm: out, rate: rate, loop: loop, gain: gain)
    }

    /// Loop start and end rounded to the nearest 16-sample blocks (at least one block long).
    public static func snapLoop(start: Double, end: Double, count: Int) -> Range<Int> {
        let blocks = max(1, count / 16)
        let s = min(blocks - 1, max(0, Int((start / 16).rounded())))
        let e = min(blocks, max(s + 1, Int((end / 16).rounded())))
        return (s * 16)..<(e * 16)
    }

    public static func encode(_ prepared: Prepared, options: Options = .init()) -> Report {
        var encoder = BRREncoder.Options()
        encoder.beam = options.beam
        encoder.maxShift = options.maxShift
        encoder.loop = prepared.loop != nil
        if let loop = prepared.loop { encoder.filterZeroBlocks.insert(loop.lowerBound / 16) }
        let encoded = BRREncoder.encode(prepared.pcm, options: encoder)
        var seam: Int?
        if let loop = prepared.loop {
            let played = BRR.decodeDSPLooping(encoded.blocks, loopBlock: loop.lowerBound / 16, passes: 1)
            let first = played[loop], again = played[(prepared.pcm.count)...]
            seam = zip(first, again).map { abs(Int($0) - Int($1)) }.max() ?? 0
        }
        return Report(options: options, prepared: prepared, encoded: encoded,
                      snrDB: BRREncoder.snr(source: prepared.pcm, decoded: encoded.decoded),
                      maxError: BRREncoder.maxError(source: prepared.pcm, decoded: encoded.decoded),
                      loopSeamError: seam)
    }

    public static func encode(wav: WAV, options: Options) throws -> Report {
        encode(try prepare(wav.samples, rate: wav.sampleRate, options: options), options: options)
    }

    /// The `.brr` file layout the project uses: [u16 LE byte length][blocks].
    public static func fileBytes(_ blocks: [UInt8]) -> [UInt8] {
        [UInt8(blocks.count & 0xFF), UInt8(blocks.count >> 8 & 0xFF)] + blocks
    }

    // MARK: Resampling

    /// Band-limited resampling: a Blackman-windowed sinc, 16 zero crossings
    /// each side, cut off at 95% of the lower Nyquist frequency.
    public static func resample(_ x: [Double], from: Int, to: Int) -> [Double] {
        guard from != to, !x.isEmpty else { return x }
        let ratio = Double(to) / Double(from)
        let cutoff = 0.95 * min(1, ratio)                 // of the source Nyquist
        let half = 16.0 / cutoff                          // window half-width, source samples
        let count = max(1, Int((Double(x.count) * ratio).rounded()))
        var out = [Double](repeating: 0, count: count)
        for j in 0..<count {
            let center = Double(j) / ratio
            let lo = max(0, Int((center - half).rounded(.up))), hi = min(x.count - 1, Int((center + half).rounded(.down)))
            guard lo <= hi else { continue }
            var acc = 0.0
            for i in lo...hi {
                let d = Double(i) - center
                let arg = .pi * d * cutoff
                let sinc = d == 0 ? 1 : sin(arg) / arg
                let w = 0.42 + 0.5 * cos(.pi * d / half) + 0.08 * cos(2 * .pi * d / half)
                acc += x[i] * cutoff * sinc * w
            }
            out[j] = acc
        }
        return out
    }
}

/// Plays BRR blocks looping at pitch $1000 on the S-DSP (`SPCStream.sample`,
/// GAIN direct $7F, full volume) and checks every output frame against the
/// prediction from `BRR.decodeDSPLooping`: the same 15-bit samples through
/// the Gaussian interpolator (index 0 at pitch $1000), envelope $7F0, voice
/// and main volume, per fullsnes. Equality on every frame means the S-DSP
/// played exactly the decoded samples. The comparison starts at the frame
/// that interpolates decoded samples 0-3: the frames before it are played
/// with the envelope still 0 (it starts after the key-on delay).
public enum BRRParity {
    public struct Report: Sendable, CustomStringConvertible {
        /// Frames compared and how many were equal.
        public var frames: Int
        public var matched: Int
        /// Output frames before decoded sample 0 is heard (key-on delay).
        public var offset: Int?
        public var firstMismatch: Int?
        public var passed: Bool { offset != nil && matched == frames }
        public var description: String {
            passed ? "S-DSP parity: \(matched) of \(frames) frames equal the decode (offset \(offset!))"
                   : "S-DSP parity FAILED: \(matched) of \(frames) frames, first mismatch at frame \(firstMismatch ?? -1)"
        }
    }

    public static func check(blocks: [UInt8], loopBlock: Int, frames requested: Int? = nil) throws -> Report {
        var brr = blocks
        for h in stride(from: 0, to: brr.count, by: 9) { brr[h] &= 0xFC }
        brr[brr.count - 9] |= 3
        let frames = requested ?? min(blocks.count / 9 * 16 + 2 * (blocks.count / 9 - loopBlock) * 16 + 64, 96_000)
        let stream = try SPCStream.sample(brr: brr, loopBlock: loopBlock)
        let pcm = try stream.render(frames: frames)
        let passes = (frames / max(1, (blocks.count / 9 - loopBlock) * 16)) + 2
        let decoded = BRR.decodeDSPLooping(brr, loopBlock: loopBlock, passes: passes).map(Int.init)
        func predicted(_ j: Int) -> Int {
            func d(_ k: Int) -> Int { k < 0 ? 0 : decoded[k] }
            let s = SDSP.gaussian(d(j - 3), d(j - 2), d(j - 1), d(j), index: 0)
            let out = (s * 0x7F0) >> 11
            let main = SDSP.clamp((out * 0x7F) >> 6)
            return SDSP.clamp(SDSP.wrap((main * 0x7F) >> 7))
        }
        var best = Report(frames: 0, matched: 0, offset: nil, firstMismatch: 0)
        for offset in 0..<32 {
            var matched = 0, mismatch: Int?
            let compared = (offset + 3)..<frames
            for t in compared {
                let p = predicted(t - offset)
                if Int(pcm[2 * t]) == p && Int(pcm[2 * t + 1]) == p { matched += 1 } else if mismatch == nil { mismatch = t }
            }
            if matched == compared.count { return Report(frames: matched, matched: matched, offset: offset, firstMismatch: nil) }
            if matched > best.matched { best = Report(frames: compared.count, matched: matched, offset: nil, firstMismatch: mismatch) }
        }
        return best
    }
}
