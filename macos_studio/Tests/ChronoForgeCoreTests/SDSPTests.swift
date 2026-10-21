// SDSPTests.swift — S-DSP arithmetic and timing against values derived by
// hand from fullsnes and the SNESdev Wiki. ROM-free.
import XCTest
@testable import ChronoForgeCore

final class SDSPTests: XCTestCase {
    /// Fresh DSP and RAM with the sample directory at $0100 (DIR = 1):
    /// source 0 starts and loops at $0200. Echo writes off, not muted.
    private func machine(block: [UInt8]) -> (SDSP, [UInt8]) {
        var ram = [UInt8](repeating: 0, count: 0x10000)
        ram.replaceSubrange(0x0100..<0x0104, with: [0x00, 0x02, 0x00, 0x02])
        ram.replaceSubrange(0x0200..<0x0200 + block.count, with: block)
        let dsp = SDSP()
        dsp.writeRegister(0x5D, 0x01)
        dsp.writeRegister(0x6C, 0x20)
        return (dsp, ram)
    }

    private func clock(_ dsp: SDSP, _ ram: inout [UInt8], _ count: Int) {
        for _ in 0..<count { dsp.clock(ram: &ram) }
    }

    // MARK: Gaussian table

    func testGaussianTableProperties() {
        let g = SDSP.gaussTable.map(Int.init)
        XCTAssertEqual(g.count, 512)
        XCTAssertEqual(g, g.sorted(), "fullsnes table is non-decreasing")
        XCTAssertEqual(Array(g[0..<16]), Array(repeating: 0, count: 16))
        XCTAssertEqual(g[511], 0x519)
        // The four taps for each position sum to $7FF...$801 (unity is $800).
        let sums: [Int] = (0..<256).map { (i: Int) -> Int in
            let outer: Int = g[255 - i] + g[i]
            return outer + g[511 - i] + g[256 + i]
        }
        XCTAssertEqual(sums.min(), 0x7FF)
        XCTAssertEqual(sums.max(), 0x801)
        XCTAssertEqual(sums[0], 0x172 + 0x519 + 0x176 + 0)
    }

    func testGaussianSumWrapsThenSaturates() {
        // i = 0, all samples 1000: 361 + 1274 + 365 + 0 = 2000, SAR 1.
        XCTAssertEqual(SDSP.gaussian(1000, 1000, 1000, 1000, index: 0), 1000)
        // All 16383: the first three terms reach 5919 + 20878 + 5983 = 32780,
        // which wraps to -32756 before the fourth (zero) term (fullsnes overflow).
        XCTAssertEqual(SDSP.gaussian(16383, 16383, 16383, 16383, index: 0), -16378)
        // i = 255 weights the newest sample by gauss[255] = $172: -16384 x 370 SAR 10 = -5920.
        XCTAssertEqual(SDSP.gaussian(0, 0, 0, -16384, index: 255), -2960)
    }

    // MARK: BRR

    /// The first 12 samples a key-on decodes (three 4-sample steps, pitch 0).
    private func keyOnDecode(header: UInt8, data: [UInt8]) -> [Int] {
        var (dsp, ram) = machine(block: [header] + data + [0, 0])
        dsp.writeRegister(0x4C, 0x01)
        clock(dsp, &ram, 400)
        return Array(dsp.decoded[0..<12])
    }

    func testBRRShiftsAndRangeSpecialCases() {
        // shift 12: (n << 12) SAR 1 for 7, -8, 1, 0, -1.
        XCTAssertEqual(keyOnDecode(header: 0xC0, data: [0x78, 0x10, 0xF0, 0, 0, 0]),
                       [14336, -16384, 2048, 0, -2048, 0, 0, 0, 0, 0, 0, 0])
        // shift 0: (n << 0) SAR 1 for 7, -8, 1, -1.
        XCTAssertEqual(keyOnDecode(header: 0x00, data: [0x78, 0x1F, 0, 0, 0, 0]),
                       [3, -4, 0, -1, 0, 0, 0, 0, 0, 0, 0, 0])
        // shifts 13-15: nibble SAR 3, then SHL 11: 7 -> 0, -8 -> -2048, -1 -> -2048.
        XCTAssertEqual(keyOnDecode(header: 0xD0, data: [0x78, 0xF0, 0, 0, 0, 0]),
                       [0, -2048, -2048, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(keyOnDecode(header: 0xF0, data: [0x87, 0, 0, 0, 0, 0]),
                       [-2048, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    }

    func testBRRFiltersClipTo16BitsThenKeep15() {
        // Filter 1 (old + -old SAR 4), shift 12, nibbles 7: 14336, then
        // 14336 + 14336 - 896 = 27776, which keeps 15 bits as -4992.
        XCTAssertEqual(keyOnDecode(header: 0xC4, data: [0x77, 0x77, 0x77, 0, 0, 0]),
                       [14336, -4992, 9656, -9380, 5542, -13237, -12410, -11635, -10908, -10227, -9588, -8989])
        // Filter 2, shift 12: 14336 + 2 x 14336 - 1344 = 41664 clips to 32767,
        // which keeps 15 bits as -1.
        XCTAssertEqual(keyOnDecode(header: 0xC8, data: [0x77, 0x77, 0x77, 0x77, 0x77, 0x77]),
                       [14336, -1, 894, 16040, -1, -704, 12994, -1, 2152, -14330, -14999, -822])
        // Filters 2 and 3 on the same nibbles, shift 8.
        let data: [UInt8] = [0x7F, 0x31, 0x9C, 0x05, 0xE2, 0x60]
        XCTAssertEqual(keyOnDecode(header: 0x88, data: data),
                       [896, 1580, 2555, 3516, 3410, 2691, 1932, 1799, 1361, 1163, 1708, 2164])
        XCTAssertEqual(keyOnDecode(header: 0x8C, data: data),
                       [896, 1482, 2318, 3088, 2768, 1952, 1258, 1314, 1082, 1132, 1922, 2533])
    }

    // MARK: KON, KOFF, ENDX and envelopes

    // From a fresh DSP (T2 at clock 0) T31 runs at clocks 29 + 32k; KON is
    // polled when the T30 toggle leaves every-other set: clocks 61 + 64k.
    // Voice 0's main step shares T31, so a KON written at clock 0 is taken at
    // clock 61 and its five-sample delay ends at clock 221 = 61 + 5 x 32.

    func testKeyOnDelayThenADSRAttackDecayAndSustain() {
        var (dsp, ram) = machine(block: [0x03] + [UInt8](repeating: 0, count: 8))
        dsp.writeRegister(0x05, 0x8F)   // ADSR: attack rate 31 (+$400), decay rate 16
        dsp.writeRegister(0x06, 0xE0)   // sustain level 7, sustain rate 0
        dsp.writeRegister(0x4C, 0x01)
        clock(dsp, &ram, 221)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0)
        clock(dsp, &ram, 1)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x400)
        XCTAssertEqual(dsp.voiceEnvelope(0).mode, .attack)
        clock(dsp, &ram, 32)            // $800 clips to $7FF and attack ends
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x7FF)
        XCTAssertEqual(dsp.voiceEnvelope(0).mode, .decay)
        // Decay's candidate $7F7 reaches sustain level 7 now, but rate 16
        // fires only when the counter (30720 - 9 here) is a multiple of 64.
        clock(dsp, &ram, 32)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x7FF)
        XCTAssertEqual(dsp.voiceEnvelope(0).mode, .sustain)
        // ENVX (written at T2) is the level SAR 4 that the sample's main step
        // used: $400 from clock 253's step, then $7FF from clock 285's at 288.
        XCTAssertEqual(dsp.readRegister(0x08), 0x40)
        clock(dsp, &ram, 3)
        XCTAssertEqual(dsp.readRegister(0x08), 0x7F)
    }

    func testKeyOffReleasesEightPerSample() {
        var (dsp, ram) = machine(block: [0x03] + [UInt8](repeating: 0, count: 8))
        dsp.writeRegister(0x07, 0x7F)   // GAIN direct $7F0
        dsp.writeRegister(0x4C, 0x01)
        clock(dsp, &ram, 222)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x7F0)
        dsp.writeRegister(0x5C, 0x01)   // KOFF, polled at clock 253
        clock(dsp, &ram, 31)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x7F0)
        clock(dsp, &ram, 1)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x7E8)
        XCTAssertEqual(dsp.voiceEnvelope(0).mode, .release)
        clock(dsp, &ram, 32 * 10)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x7E8 - 8 * 10)
    }

    func testKeyOnWrittenBetweenPollsWaitsForTheNextOne() {
        var (dsp, ram) = machine(block: [0x03] + [UInt8](repeating: 0, count: 8))
        dsp.writeRegister(0x07, 0x7F)
        clock(dsp, &ram, 62)            // past the poll at clock 61
        dsp.writeRegister(0x4C, 0x01)   // taken at clock 125, delay ends at 285
        XCTAssertEqual(dsp.pendingKeyOn, 0x01)
        clock(dsp, &ram, 285 - 62)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0)
        XCTAssertEqual(dsp.pendingKeyOn, 0x00, "polled bits are no longer pending")
        clock(dsp, &ram, 1)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0x7F0)
    }

    func testENDXSetsAtLoopAndKeyOnClearsIt() {
        // One block with end + loop, pitch $1000: the key-on decodes samples
        // 0-11, then position reaches $4000 at the decode in clock 382, which
        // reads bytes 7-8, ends the block and loops; ENDX is set at T1 (clock 383).
        var (dsp, ram) = machine(block: [0x03] + [UInt8](repeating: 0x11, count: 8))
        dsp.writeRegister(0x07, 0x7F)
        dsp.writeRegister(0x03, 0x10)
        dsp.writeRegister(0x4C, 0x01)
        clock(dsp, &ram, 383)
        XCTAssertEqual(dsp.readRegister(0x7C), 0)
        clock(dsp, &ram, 1)
        XCTAssertEqual(dsp.readRegister(0x7C), 0x01)
        // A new KON is taken at clock 445; T1 two clocks later clears the bit.
        dsp.writeRegister(0x4C, 0x01)
        clock(dsp, &ram, 447 - 384)
        XCTAssertEqual(dsp.readRegister(0x7C), 0x01)
        clock(dsp, &ram, 1)
        XCTAssertEqual(dsp.readRegister(0x7C), 0x00)
        // The block ends again 161 clocks after the new delay (clock 766); any
        // CPU write to ENDX clears it.
        clock(dsp, &ram, 32 * 10)
        XCTAssertEqual(dsp.readRegister(0x7C), 0x01)
        dsp.writeRegister(0x7C, 0x55)
        XCTAssertEqual(dsp.readRegister(0x7C), 0x00)
    }

    func testEndWithoutLoopMutesTheVoice() {
        // End without loop ($01): the header check silences the voice (release,
        // level 0) on the sample whose header is the end block.
        var (dsp, ram) = machine(block: [0x01] + [UInt8](repeating: 0x11, count: 8))
        dsp.writeRegister(0x07, 0x7F)
        dsp.writeRegister(0x4C, 0x01)
        clock(dsp, &ram, 400)
        XCTAssertEqual(dsp.voiceEnvelope(0).level, 0)
        XCTAssertEqual(dsp.voiceEnvelope(0).mode, .release)
    }

    // MARK: Rate counter and noise

    func testRateCounterFiresAtSNESdevOffsets() {
        // Counter 0 at reset, decremented at each T31 (poll j at clock 29 + 32(j-1)),
        // so poll j sees 30720 - j; rate r fires when (that + offset) mod period = 0.
        let expected: [Int: [Int]] = [
            31: [1, 2, 3], 30: [2, 4, 6], 29: [2, 5, 8], 28: [4, 8, 12], 26: [2, 8, 14],
            3: [536, 1816, 3096], 2: [1040, 2576, 4112], 1: [2048, 4096, 6144],
        ]
        for (rate, firings) in expected {
            var ram = [UInt8](repeating: 0, count: 0x10000)
            let dsp = SDSP()
            dsp.writeRegister(0x6C, 0xE0 | UInt8(rate))   // noise clock = rate
            var seen: [Int] = [], noise = dsp.noise
            clock(dsp, &ram, 29)
            for poll in 1...firings.last! {
                clock(dsp, &ram, 1)
                if dsp.noise != noise { seen.append(poll); noise = dsp.noise }
                if poll < firings.last! { clock(dsp, &ram, 31) }
            }
            XCTAssertEqual(seen, firings, "rate \(rate)")
        }
    }

    func testNoiseLFSRSequenceAndPeriod() {
        var ram = [UInt8](repeating: 0, count: 0x10000)
        let dsp = SDSP()
        dsp.writeRegister(0x6C, 0xE0 | 31)
        var values: [Int] = [dsp.noise]
        clock(dsp, &ram, 29)
        for _ in 0..<17 { clock(dsp, &ram, 1); values.append(dsp.noise); clock(dsp, &ram, 31) }
        // bit 14 = bit 0 XOR bit 1 of the previous value, shifted right.
        XCTAssertEqual(values, [0x4000, 0x2000, 0x1000, 0x0800, 0x0400, 0x0200, 0x0100, 0x0080, 0x0040,
                                0x0020, 0x0010, 0x0008, 0x0004, 0x0002, 0x4001, 0x6000, 0x3000, 0x1800])
        // Maximal length: 32767 steps return to $4000 and never pass 0.
        var n = 0x4000, period = 0
        repeat {
            n = (n >> 1) | (((n ^ (n >> 1)) & 1) << 14)
            period += 1
            XCTAssertNotEqual(n, 0)
        } while n != 0x4000 && period < 40000
        XCTAssertEqual(period, 32767)
    }

    // MARK: Mixer and echo

    func testOutputWrapsEachProductAndSaturatesTheSum() {
        XCTAssertEqual(SDSP.output(1000, 2000, 0x40, 0x20), 500 + 500)
        // MVOL = -128 on -32768 gives +32768, which wraps (fullsnes).
        XCTAssertEqual(SDSP.output(-32768, 0, 0x80, 0), -32768)
        XCTAssertEqual(SDSP.output(32767, 32767, 0x7F, 0x7F), 32767)
        XCTAssertEqual(SDSP.output(-32768, -32768, 0x7F, 0x7F), -32768)
    }

    func testFIRWrapsSevenTapsThenSaturatesTheEighth() {
        let taps = [127, 127, 127, 127, 127, 127, 127, 127]
        // Each term (16383 x 127) SAR 6 = 32510; seven sum to 227570, which
        // wraps to 30962; adding the eighth saturates.
        XCTAssertEqual(SDSP.fir(taps) { _ in 16383 }, 32767)
        XCTAssertEqual(SDSP.fir([127, 127, 127, 127, 127, 127, 127, 0]) { _ in 16383 }, 30962)
        // Tap order: FIR0 takes the oldest sample, FIR7 the newest.
        XCTAssertEqual(SDSP.fir([64, 0, 0, 0, 0, 0, 0, 0]) { $0 == 0 ? 100 : 0 }, 100)
        XCTAssertEqual(SDSP.fir([0, 0, 0, 0, 0, 0, 0, -128]) { $0 == 7 ? 100 : 0 }, -200)
        XCTAssertEqual(SDSP.fir([-1, 0, 0, 0, 0, 0, 0, 0]) { _ in 1 }, -1, "terms round down")
    }

    func testEchoFeedbackClearsBitZero() {
        XCTAssertEqual(SDSP.echoInput(3, 0, 0), 2)
        XCTAssertEqual(SDSP.echoInput(32000, 20000, 127), 32766)          // 32000 + 19843 saturates
        XCTAssertEqual(SDSP.echoInput(-5, 3, -128), -8)                   // -5 + (-3)
        XCTAssertEqual(SDSP.echoInput(0, -32768, -128), -32768)           // +32768 wraps first
    }

    func testEchoBufferReadThroughFIRAndOverwritten() {
        // ESA 0, EDL 1 (512 frames), FIR0 = 64 only, EVOL left 64, no voices.
        // Sample 1 reads $0000 = $1000 (SAR 1: 2048); FIR0 sees it 7 samples
        // later: frame 8 left = (2048 x 64 SAR 6) x 64 SAR 7 = 1024. Sample 1
        // also writes 0 there, so the buffer's second pass is silent.
        var ram = [UInt8](repeating: 0, count: 0x10000)
        ram[0x0001] = 0x10
        let dsp = SDSP()
        let writes: [(UInt8, UInt8)] = [(0x6D, 0x00), (0x7D, 0x01), (0x0F, 64), (0x2C, 64), (0x6C, 0x00)]
        for (register, value) in writes { dsp.writeRegister(register, value) }
        dsp.isRecording = true
        clock(dsp, &ram, 32 * 520)
        let pcm = dsp.takeRecording()
        let left = stride(from: 0, to: pcm.count, by: 2).map { Int(pcm[$0]) }
        let right = stride(from: 1, to: pcm.count, by: 2).map { Int(pcm[$0]) }
        XCTAssertEqual(Array(left[0..<10]), [0, 0, 0, 0, 0, 0, 0, 1024, 0, 0])
        XCTAssertEqual(left.filter { $0 != 0 }.count, 1)
        XCTAssertTrue(right.allSatisfy { $0 == 0 })
        XCTAssertEqual(Array(ram[0..<4]), [0, 0, 0, 0])
    }

    func testFLGMuteSilencesOutput() {
        var ram = [UInt8](repeating: 0, count: 0x10000)
        ram[0x0001] = 0x10
        let dsp = SDSP()
        // FIR7 (newest) would put the $1000 at $0000 into frame 1 without FLG.6.
        let writes: [(UInt8, UInt8)] = [(0x7D, 0x01), (0x7F, 64), (0x2C, 64), (0x6C, 0x40)]
        for (register, value) in writes { dsp.writeRegister(register, value) }
        dsp.isRecording = true
        clock(dsp, &ram, 32 * 4)
        XCTAssertTrue(dsp.takeRecording().allSatisfy { $0 == 0 })
        XCTAssertEqual(dsp.frameCount, 4)
    }

    // MARK: Snapshot load

    func testLoadKeepsRegistersAndTakesKONAsPending() {
        var image = [UInt8](repeating: 0, count: 128)
        image[0x4C] = 0x81; image[0x7C] = 0x0F; image[0x6C] = 0x20; image[0x0C] = 0x7F
        let dsp = SDSP()
        dsp.load(registers: image, counter: 0x7F0)
        XCTAssertEqual(dsp.registers, image)
        XCTAssertEqual(dsp.pendingKeyOn, 0x81)
        XCTAssertEqual(dsp.counter, 0x7F0)
        XCTAssertEqual(dsp.phase, 2)
    }
}
