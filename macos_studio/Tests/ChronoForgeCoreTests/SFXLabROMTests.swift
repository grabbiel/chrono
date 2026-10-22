// SFXLabROMTests.swift — the SFX Lab against Chrono Trigger's own samples
// (local ROM only; nothing from the ROM is stored): every Audio_SampleTable
// sample plays on the S-DSP exactly as BRR.decodeDSP decodes it, and the
// encoder's SNR re-encoding that decode is measured.
import XCTest
@testable import ChronoForgeCore

final class SFXLabROMTests: XCTestCase {
    /// Sample `number` (1...62): its BRR bytes and loop offset, read the way
    /// Audio_UploadSample does (a length word, then the bytes).
    static func romSample(_ rom: [UInt8], _ number: Int) -> (blocks: [UInt8], loopBlock: Int) {
        let p = CTSPCTransfer.sampleTablePC + 3 * (number - 1)
        let long = Int(rom[p]) | Int(rom[p + 1]) << 8 | Int(rom[p + 2]) << 16
        let pc = long & 0x3FFFFF
        let length = Int(rom[pc]) | Int(rom[pc + 1]) << 8
        let loop = Int(rom[CTSPCTransfer.sampleLoopPC + 2 * (number - 1)]) | Int(rom[CTSPCTransfer.sampleLoopPC + 2 * (number - 1) + 1]) << 8
        return (Array(rom[(pc + 2)..<(pc + 2 + length)]), loop / 9)
    }

    func testEveryROMSamplePlaysExactlyAsDecodedOnTheSDSP() throws {
        let rom = [UInt8](try Repo.romData())
        var frames = 0
        for number in 1...CTSongISA.sampleMax {
            let (blocks, loopBlock) = Self.romSample(rom, number)
            XCTAssertEqual(blocks.count % 9, 0, "sample \(number)")
            let report = try BRRParity.check(blocks: blocks, loopBlock: min(loopBlock, blocks.count / 9 - 1), frames: 3000)
            XCTAssertTrue(report.passed, "sample \(number): \(report)")
            frames += report.frames
        }
        print("SFX Lab ROM parity: \(CTSongISA.sampleMax) samples, \(frames) frames equal the decode")
    }

    func testEncoderOnROMSampleDecodes() throws {
        // The game's own decodes resampled 32 -> 28.8 kHz (so the source is
        // not already BRR-shaped), first 2048 samples each, 16-bit scale.
        // SNR is pooled: total signal energy over total error energy.
        let rom = [UInt8](try Repo.romData())
        var signal = 0.0, noise = [0.0, 0.0, 0.0], n = 0
        var greedyOptions = BRREncoder.Options(); greedyOptions.beam = 1
        for number in 1...CTSongISA.sampleMax {
            let decoded = BRR.decodeDSP(Self.romSample(rom, number).blocks).prefix(2304).map { 2 * Double($0) }
            let source = SFXImport.resample(Array(decoded), from: 32000, to: 28800).prefix(2048)
                .map { Int16(max(-32768, min(32767, $0.rounded()))) }
            guard source.contains(where: { $0 != 0 }) else { continue }
            let outputs = [BRR.decodeDSP(BRR.encode(source)), BRREncoder.encode(source, options: greedyOptions).decoded,
                           BRREncoder.encode(source).decoded]
            signal += source.reduce(0) { $0 + Double($1) * Double($1) }
            for (k, out) in outputs.enumerated() {
                noise[k] += zip(source, out).reduce(0.0) { $0 + pow(Double($1.0) - 2 * Double($1.1), 2) }
            }
            n += 1
        }
        let snr = noise.map { 10 * log10(signal / $0) }
        print(String(format: "SFX Lab ROM re-encode (resampled to 28.8 kHz), pooled SNR over %d samples: legacy %.2f dB, greedy %.2f dB, beam 4 %.2f dB",
                     n, snr[0], snr[1], snr[2]))
        XCTAssertGreaterThan(n, 50)
        XCTAssertGreaterThanOrEqual(snr[2], snr[1])
        XCTAssertGreaterThan(snr[1], snr[0])
    }
}
