// SFXLabTests.swift — the SFX Lab's encoder, import, synthesis, envelope
// and voice effects, checked against the S-DSP model. Fixtures are synthetic.
import XCTest
@testable import ChronoForgeCore

final class SFXLabTests: XCTestCase {
    /// A mixed test signal: a decaying FM blip over a saw and some noise.
    static func testSignal(count: Int = 4096, rate: Double = 32000) -> [Int16] {
        var lfsr: UInt32 = 1
        return (0..<count).map { i in
            let t = Double(i) / rate
            let blip = sin(2 * .pi * 660 * t + 3 * exp(-8 * t) * sin(2 * .pi * 1320 * t)) * exp(-3 * t)
            let saw = 2 * (110 * t - (110 * t).rounded(.down)) - 1
            let bit = lfsr & 1; lfsr >>= 1; if bit != 0 { lfsr ^= 0x6000 }
            let noise = Double(Int(lfsr) - 0x4000) / 0x4000
            return Int16((0.6 * blip + 0.25 * saw + 0.05 * noise) * 30000)
        }
    }

    // MARK: Decode and S-DSP parity

    func testEncodedSamplePlaysExactlyAsDecodedOnTheSDSP() throws {
        let result = BRREncoder.encode(Self.testSignal(count: 2048))
        let report = try BRRParity.check(blocks: result.blocks, loopBlock: 0)
        XCTAssertTrue(report.passed, report.description)
        XCTAssertGreaterThan(report.frames, 2048 * 2)   // first pass and two loop passes
    }

    func testHandBlocksWithEveryShiftFilterAndOverflowPlayAsDecoded() throws {
        // Shifts 0-15 with each filter, full-scale nibbles: exercises the
        // shift 13-15 rule, 16-bit clamping and the 15-bit wrap.
        var blocks: [UInt8] = []
        for shift in 0...15 {
            for filter in 0...3 {
                blocks.append(UInt8(shift << 4 | filter << 2))
                blocks += [0x77, 0x77, 0x7F, 0x80, 0x88, 0x07, 0x70, 0x19]
            }
        }
        let decoded = BRR.decodeDSP(blocks)
        XCTAssertEqual(decoded.count, 64 * 16)
        // Clamped-then-wrapped values occur (the 15-bit wrap is exercised).
        XCTAssertTrue(decoded.contains { $0 < -8192 } && decoded.contains { $0 > 8192 })
        let report = try BRRParity.check(blocks: blocks, loopBlock: 16)
        XCTAssertTrue(report.passed, report.description)
    }

    func testDecodeDSPScalesAsTheHardware() {
        // Shift 12, filter 0, nibble 7: (7 << 12) >> 1 = 14336 (15-bit).
        let block: [UInt8] = [0xC0, 0x70, 0, 0, 0, 0, 0, 0, 0]
        XCTAssertEqual(BRR.decodeDSP(block)[0], 14336)
        // Shift 13 acts as 12 with the nibble SAR 3: 7 -> 0, -8 -> -1 << 11.
        XCTAssertEqual(BRR.decodeDSP([0xD0, 0x78, 0, 0, 0, 0, 0, 0, 0])[0...1], [0, -2048])
    }

    // MARK: Encoder

    func testBeamSearchBeatsGreedyAndTheLegacyEncoder() {
        let source = Self.testSignal()
        var greedy = BRREncoder.Options(); greedy.beam = 1
        let g = BRREncoder.encode(source, options: greedy)
        let b = BRREncoder.encode(source)
        let legacy = BRR.decodeDSP(BRR.encode(source))
        let snrGreedy = BRREncoder.snr(source: source, decoded: g.decoded)
        let snrBeam = BRREncoder.snr(source: source, decoded: b.decoded)
        let snrLegacy = BRREncoder.snr(source: source, decoded: legacy)
        print(String(format: "SFX encoder SNR on the synthetic mix: legacy %.2f dB, greedy %.2f dB, beam 4 %.2f dB", snrLegacy, snrGreedy, snrBeam))
        XCTAssertGreaterThanOrEqual(snrBeam, snrGreedy)
        XCTAssertGreaterThan(snrGreedy, snrLegacy)
        XCTAssertGreaterThan(snrBeam, 30)
        XCTAssertEqual(b.squaredError, zip(source, b.decoded).reduce(0) { $0 + pow(Double($1.0) - 2 * Double($1.1), 2) })
    }

    func testEncoderFlagsAndFilterZeroBlocks() {
        var options = BRREncoder.Options()
        options.loop = true
        options.filterZeroBlocks = [0, 3]
        let r = BRREncoder.encode(Self.testSignal(count: 100), options: options)
        XCTAssertEqual(r.blocks.count, 7 * 9)                       // padded to whole blocks
        XCTAssertEqual(r.blocks[6 * 9] & 3, 3)                      // end + loop on the last block only
        XCTAssertTrue(stride(from: 0, to: 6 * 9, by: 9).allSatisfy { r.blocks[$0] & 3 == 0 })
        XCTAssertEqual(r.blocks[0] >> 2 & 3, 0)
        XCTAssertEqual(r.blocks[27] >> 2 & 3, 0)
    }

    // MARK: Import

    func testResamplingKeepsPitchAndLevel() {
        let source = (0..<44100 / 10).map { Int16(20000 * sin(2 * .pi * 1000 * Double($0) / 44100)) }
        let out = SFXImport.resample(source.map(Double.init), from: 44100, to: 32000)
        XCTAssertEqual(out.count, 3200)
        let middle = out[400..<2800]
        let crossings = zip(middle, middle.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }.count
        XCTAssertEqual(crossings, 75, accuracy: 1)                  // 1 kHz over 75 ms
        XCTAssertEqual(middle.max()!, 20000, accuracy: 300)
    }

    func testLoopIsSnappedToBlocksAndItsSeamCannotClick() throws {
        let source = (0..<22050).map { i -> Int16 in
            let t = Double(i) / 22050
            return Int16(15000 * sin(2 * .pi * 220 * t) + 4000 * sin(2 * .pi * 37 * t))
        }
        let wav = try WAV.read(data: WAV.writeWav(samples: source, rate: 22050))
        var options = SFXImport.Options()
        options.rate = 32000
        options.loopStart = 1001; options.loopEnd = 15003
        options.crossfade = 64
        let report = try SFXImport.encode(wav: wav, options: options)
        let loop = try XCTUnwrap(report.prepared.loop)
        XCTAssertEqual(loop.lowerBound % 16, 0)
        XCTAssertEqual(loop.upperBound % 16, 0)
        XCTAssertEqual(Double(loop.lowerBound), 1001 * 32000 / 22050, accuracy: 8)
        XCTAssertEqual(Double(loop.upperBound), 15003 * 32000 / 22050, accuracy: 8)
        XCTAssertEqual(report.prepared.pcm.count, loop.upperBound)
        XCTAssertEqual(report.loopSeamError, 0, "the loop block uses filter 0, so both entries decode alike")
        XCTAssertEqual(report.encoded.blocks[9 * (loop.lowerBound / 16)] >> 2 & 3, 0)
        XCTAssertGreaterThan(report.snrDB, 25)
        XCTAssertEqual(report.meta.loopStartSample, loop.lowerBound)
        XCTAssertEqual(report.meta.source?.crossfade, 64)
        // The S-DSP plays the looping sample exactly as decoded.
        let parity = try BRRParity.check(blocks: report.encoded.blocks, loopBlock: loop.lowerBound / 16, frames: 4000)
        XCTAssertTrue(parity.passed, parity.description)
    }

    func testNormalizingAndTheSilentEndBlock() throws {
        let prepared = try SFXImport.prepare([0, 1000, -2000, 500], rate: 32000, options: .init())
        XCTAssertEqual(prepared.pcm.count, 32)                       // one block, then a silent one
        XCTAssertTrue(prepared.pcm[16...].allSatisfy { $0 == 0 })
        XCTAssertEqual(Int(prepared.pcm[2]), -Int((32767 * pow(10, -1.0 / 20)).rounded()))
        XCTAssertThrowsError(try SFXImport.prepare([1, 2], rate: 0, options: .init()))
        var bad = SFXImport.Options(); bad.loopStart = 5; bad.loopEnd = 2
        XCTAssertThrowsError(try SFXImport.prepare([Int16](repeating: 1, count: 64), rate: 32000, options: bad))
    }

    // MARK: Synthesis

    func testSynthLoopsAreWholePeriodsInWholeBlocks() throws {
        for wave in SynthSpec.Wave.allCases where wave != .noise {
            let out = try SFXSynth.render(SynthSpec(wave: wave, frequency: 523.25, loop: true))
            let period = Int((32000 / 523.25).rounded())
            XCTAssertEqual(out.pcm.count % 16, 0, "\(wave)")
            XCTAssertEqual(out.pcm.count % period, 0, "\(wave)")
            XCTAssertEqual(out.loop, 0..<out.pcm.count)
            XCTAssertEqual(out.frequency, 32000 / Double(period), accuracy: 1e-9)
        }
    }

    func testSynthIsDeterministicAndSeeded() throws {
        let a = try SFXSynth.render(SynthSpec(wave: .noise, frequency: 8000, duration: 0.05, seed: 7))
        XCTAssertEqual(a.pcm, try SFXSynth.render(SynthSpec(wave: .noise, frequency: 8000, duration: 0.05, seed: 7)).pcm)
        XCTAssertNotEqual(a.pcm, try SFXSynth.render(SynthSpec(wave: .noise, frequency: 8000, duration: 0.05, seed: 9)).pcm)
        let blip = try SFXSynth.render(SynthSpec(wave: .fm, frequency: 880, endFrequency: 220, duration: 0.2, decay: 10))
        XCTAssertEqual(blip.pcm.count, 6400)
        let early = blip.pcm[0..<400].map { abs(Int($0)) }.max()!, late = blip.pcm[6000...].map { abs(Int($0)) }.max()!
        XCTAssertGreaterThan(early, 4 * late)
        XCTAssertThrowsError(try SFXSynth.render(SynthSpec(frequency: 20000)))
    }

    func testSynthEncodeAndSidecarRoundTrip() throws {
        let spec = SynthSpec(wave: .pulse, frequency: 440, duty: 0.25, loop: true)
        let report = try SFXSynth.encode(spec)
        XCTAssertNotNil(report.prepared.loop)
        XCTAssertEqual(report.loopSeamError, 0)
        var meta = report.meta
        meta.brr = "audio/samples/pulse.brr"
        meta.synth = spec
        meta.fx = SampleFX(vibratoCents: 30, vibratoPeriodTicks: 12, noise: false)
        let json = try JSONEncoder().encode(meta)
        XCTAssertEqual(try JSONDecoder().decode(SampleMeta.self, from: json), meta)
        // Older sidecars (no SFX Lab fields) still load, and a short synth spec takes defaults.
        let old = #"{"brr":"a.brr","loop":false,"synth":{"wave":"saw"}}"#
        let decoded = try JSONDecoder().decode(SampleMeta.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.synth, SynthSpec(wave: .saw))
        XCTAssertNil(decoded.fx)
    }

    // MARK: Envelope (rendered by the S-DSP)

    func testEnvelopeCurvesFollowTheHardwareRates() throws {
        var s = DSPEnvelope.Setting()
        s.mode = .linearIncrease; s.rate = 31
        let rise = try DSPEnvelope.render(s, frames: 120, stride: 1).levels
        let start = try XCTUnwrap(rise.firstIndex { $0 > 0 })
        XCTAssertEqual(Array(rise[start..<start + 4]), [0x20, 0x40, 0x60, 0x80])   // +$20 per sample
        XCTAssertEqual(rise[start + 63], 0x7FF)                                       // clipped at $7FF
        s = DSPEnvelope.Setting(); s.attack = 15
        let attack = try DSPEnvelope.render(s, frames: 40, stride: 1).levels
        let a0 = try XCTUnwrap(attack.firstIndex { $0 > 0 })
        XCTAssertEqual(Array(attack[a0...a0 + 1]), [0x400, 0x7FF])                    // attack 15: +$400
        s = DSPEnvelope.Setting(); s.mode = .direct; s.level = 0x55
        XCTAssertEqual(try DSPEnvelope.render(s, frames: 40, stride: 1).levels.last, 0x550)
        s.mode = .exponentialDecrease; s.rate = 31; s.startLevel = 127
        let fall = try DSPEnvelope.render(s, frames: 2000, stride: 1).levels
        XCTAssertEqual(fall.max(), 0x7F0)
        XCTAssertLessThan(fall.last!, 0x100)
        // Exponential: each step subtracts 1 + level/256.
        let i = try XCTUnwrap(fall.lastIndex(of: 0x7F0))
        XCTAssertEqual(fall[i + 1], 0x7F0 - 1 - ((0x7F0 - 1) >> 8))
    }

    func testEnvelopeCurveIsTheSDSPsOwnEnvelope() throws {
        // The DC frames are strictly increasing in the level, so every frame
        // maps back to exactly one level.
        XCTAssertTrue(zip(DSPEnvelope.dcFrames, DSPEnvelope.dcFrames.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertTrue((0...0x7FF).allSatisfy { DSPEnvelope.level(frame: DSPEnvelope.dcFrames[$0]) == $0 })
        // Without ticks the CPU is stopped, so a 1-frame render ends exactly
        // on the frame and the voice's level is read at a fixed phase: the
        // level the next frame is played at. The curve agrees on every frame.
        var setting = DSPEnvelope.Setting()
        setting.attack = 10; setting.decay = 4; setting.sustainLevel = 3; setting.sustainRate = 20
        var voice = SPCStream.Voice()
        setting.apply(to: &voice)
        let stream = try SPCStream.sample(brr: DSPEnvelope.dcBlock, voice: voice)
        var inside: [Int] = []
        for _ in 0..<3000 { _ = try stream.render(frames: 1); inside.append(stream.dsp.voiceEnvelope(0).level) }
        let curve = try DSPEnvelope.render(setting, frames: 3000, stride: 1).levels
        XCTAssertEqual(Array(curve.dropFirst()), Array(inside.dropLast()))
        XCTAssertGreaterThanOrEqual(curve.max()!, 0x7E0)            // attack reached the top, then decay
        XCTAssertLessThan(curve.last!, 0x7FF)
        // With a key-off tick the voice releases to 0.
        let released = try DSPEnvelope.render(setting, keyOffTick: 4, frames: 1500, stride: 1)
        XCTAssertEqual(released.keyOffFrame, 5 * 128)
        XCTAssertEqual(released.levels.last, 0)
        XCTAssertGreaterThan(released.levels.max()!, 0x300)        // attack 10 is cut off by the key-off
    }

    func testSettingRegistersRoundTrip() {
        var s = DSPEnvelope.Setting()
        s.attack = 9; s.decay = 3; s.sustainLevel = 5; s.sustainRate = 17
        XCTAssertEqual(DSPEnvelope.Setting(adsr: s.adsrRegisters, gain: 0), s)
        for mode in DSPEnvelope.Mode.allCases where mode != .adsr {
            var g = DSPEnvelope.Setting(); g.mode = mode; g.rate = 13; g.level = 99
            let back = DSPEnvelope.Setting(adsr: nil, gain: g.gainRegister)
            XCTAssertEqual(back.mode, mode)
            XCTAssertEqual(back.gainRegister, g.gainRegister)
        }
        var meta = SampleMeta(brr: "x.brr", rate: 32000, loop: false, loopStartSample: nil, loopEndSample: nil, adsr: nil, gain: nil)
        s.startLevel = 40
        s.apply(to: &meta)
        XCTAssertEqual(meta.adsr, [9, 3, 5, 17])
        XCTAssertEqual(DSPEnvelope.Setting(sample: meta), s)
    }

    // MARK: Pitch, vibrato, noise

    func testPitchCurveBendThenRepeatingVibrato() {
        let (bend, none) = SFXPitch.curve(base: 0x1000, fx: SampleFX(bendSemitones: 12, bendTicks: 10))
        XCTAssertNil(none)
        XCTAssertEqual(bend.count, 11)
        XCTAssertEqual(bend.first, 0x1000); XCTAssertEqual(bend.last, 0x2000)
        let (vib, from) = SFXPitch.curve(base: 0x1000, fx: SampleFX(vibratoCents: 50, vibratoPeriodTicks: 8, vibratoDelayTicks: 3))
        XCTAssertEqual(from, 3)
        XCTAssertEqual(vib.count, 11)
        XCTAssertEqual(vib[3], 0x1000)
        XCTAssertEqual(Double(vib[5]), 4096 * pow(2, 50.0 / 1200), accuracy: 0.5)
        XCTAssertEqual(SFXPitch.curve(base: 0x3000, fx: SampleFX(bendSemitones: 24, bendTicks: 1)).pitches.last, 0x3FFF)
    }

    func testTickProgramWritesThePitchCurveOnTheSPC700() throws {
        let silent: [UInt8] = [0x03] + [UInt8](repeating: 0, count: 8)
        var voice = SPCStream.Voice()
        voice.pitchCurve = [0x0800, 0x0900, 0x0A00, 0x0B00]
        voice.pitchRepeatFrom = 2
        voice.tickDivider = 8                       // 1 ms ticks: 32 frames
        let stream = try SPCStream.sample(brr: silent, voice: voice)
        var seen: [Int] = []
        for _ in 0..<12 {
            _ = try stream.render(frames: 32)
            seen.append(Int(stream.dsp.registers[0x02]) | Int(stream.dsp.registers[0x03]) << 8)
        }
        // Ticks land once per 32 frames: the curve, then ticks 2...3 repeating.
        let ticks = Array(seen.drop { $0 == 0x1000 })
        XCTAssertEqual(Array(ticks.prefix(8)), [0x0800, 0x0900, 0x0A00, 0x0B00, 0x0A00, 0x0B00, 0x0A00, 0x0B00])
        XCTAssertFalse(stream.isFinished)
    }

    func testKeyOffEndsThePreviewAndNoiseReplacesTheSample() throws {
        let silent: [UInt8] = [0x03] + [UInt8](repeating: 0, count: 8)
        var meta = SampleMeta(brr: "x.brr", rate: 32000, loop: true, loopStartSample: 0, loopEndSample: 16, adsr: nil, gain: 0x7F)
        meta.fx = SampleFX(tickDivider: 16, noise: true, noiseClock: 30, keyOffTick: 20)
        let voice = SPCStream.Voice(sample: meta)
        XCTAssertTrue(voice.noise)
        XCTAssertEqual(voice.noiseClock, 30)
        XCTAssertEqual(voice.keyOffTick, 20)
        let stream = try SPCStream.sample(brr: silent, voice: voice)
        var pcm: [Int16] = []
        var chunks = 0
        while !stream.isFinished && chunks < 200 { pcm += try stream.render(frames: 256); chunks += 1 }
        XCTAssertTrue(stream.isFinished, "the preview ends after the key-off and release")
        XCTAssertLessThan(chunks, 200)
        // Noise from a silent sample until the key-off on the 21st tick (2 ms
        // = 64 frames each, the first a tick after the start), then the
        // release: -8 per sample from $7F0, about 254 frames.
        let loud = pcm.enumerated().filter { $0.offset % 2 == 0 && abs(Int($0.element)) > 1000 }.map { $0.offset / 2 }
        XCTAssertGreaterThan(loud.count, 500)
        XCTAssertEqual(Double(loud.last!), 21 * 64 + 254, accuracy: 32)
        XCTAssertGreaterThan(Set(pcm).count, 100)
    }

    func testGainStartHandsOverToTheEnvelopeOnTheFirstTick() throws {
        var s = DSPEnvelope.Setting()
        s.mode = .linearDecrease; s.rate = 31; s.startLevel = 64
        let curve = try DSPEnvelope.render(s, tickDivider: 8, frames: 200, stride: 1).levels
        let held = try XCTUnwrap(curve.firstIndex(of: 64 * 16))
        let fallStart = try XCTUnwrap(curve.firstIndex { $0 < 64 * 16 && $0 > 0 })
        XCTAssertGreaterThan(fallStart, held)
        XCTAssertEqual(curve[fallStart], 64 * 16 - 0x20)            // -$20 per sample from the start level
        XCTAssertEqual(curve.last, 0)
    }
}
