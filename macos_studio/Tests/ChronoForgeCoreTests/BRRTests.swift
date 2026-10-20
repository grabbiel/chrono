// BRRTests.swift — BRR decode parity vs the Python pipeline (ct_audio.py)
// on AudioSample_01 ($C7:730D), plus round-trip envelope checks.
import XCTest
@testable import ChronoForgeCore

final class BRRTests: XCTestCase {
    /// AudioSample_01: blob at $C7:730D = [u16 len][BRR blocks].
    static let audioSample01PC = 0x7730D

    func testAudioSample01ParityAgainstPythonWAV() throws {
        let wavURL = Repo.audioSamples.appendingPathComponent("AudioSample_01.wav")
        guard FileManager.default.fileExists(atPath: wavURL.path) else {
            throw XCTSkip("ct_audio.py WAV not present")
        }
        let rom = try Repo.romData()
        let blob = [UInt8](rom.subdata(in: Self.audioSample01PC..<rom.count))
        let dec = BRR.decodeBlob(blob)
        XCTAssertGreaterThan(dec.blocks, 100)
        XCTAssertEqual(dec.invalidHeaders, 0)
        XCTAssertTrue(dec.endBitSet)

        let wav = try WAV.read(url: wavURL)
        XCTAssertEqual(wav.sampleRate, 32000)
        XCTAssertEqual(wav.samples.count, dec.samples.count,
                       "sample count differs from python pipeline")
        // Exact int16 equality on the first 256 samples (identical recursions).
        for i in 0..<min(256, wav.samples.count) {
            XCTAssertEqual(dec.samples[i], wav.samples[i],
                           "sample \(i) differs from ct_audio.py output")
        }
        // And full-stream equality (both use identical integer recursions).
        XCTAssertEqual(dec.samples, wav.samples, "full BRR stream differs from python")
    }

    func testFixtureSampleRoundTrip() throws {
        let data = try resourceData("MyGame.ctproj/audio/samples/hit.brr")
        let dec = BRR.decodeBlob([UInt8](data))
        XCTAssertEqual(dec.blocks, 40)
        XCTAssertTrue(dec.endBitSet)
        XCTAssertEqual(dec.invalidHeaders, 0)
        // Re-encode decoded samples: must stay inside the SNES error envelope.
        let re = BRR.encode(dec.samples)
        let back = BRR.decode(re, off: 0, nBlocks: re.count / 9)
        var maxErr = 0
        for i in 0..<dec.samples.count {
            maxErr = max(maxErr, abs(Int(dec.samples[i]) - Int(back.samples[i])))
        }
        XCTAssertLessThanOrEqual(maxErr, Validator.brrEnvelope)
    }

    func testShift13And14SpecialCases() {
        // shift 13: x = (n<<13)>>1; shift 14: x = 0. Build hand-made blocks.
        var block13: [UInt8] = [UInt8(13 << 4 | 0 << 2 | 1)] // end bit
        block13 += [0x80, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00] // first nibble 8 -> n=-8
        let d13 = BRR.decode(block13, off: 0, nBlocks: 1)
        XCTAssertEqual(d13.samples[0], Int16(((-8) << 13) >> 1))
        var block14: [UInt8] = [UInt8(14 << 4 | 1 << 2 | 1)]
        block14 += [0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        let d14 = BRR.decode(block14, off: 0, nBlocks: 1)
        XCTAssertEqual(d14.samples[0], 0)  // x=0, filter1 on silence stays 0
    }
}
