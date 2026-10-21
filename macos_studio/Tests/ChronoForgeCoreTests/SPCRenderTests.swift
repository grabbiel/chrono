// SPCRenderTests.swift — SPC snapshot export/restore, render limits and WAV
// output. ROM-free except the CT song render, which skips without the ROM.
import XCTest
@testable import ChronoForgeCore

final class SPCRenderTests: XCTestCase {
    private func idle(_ bus: SSMPBus, to cycle: Int) {
        while bus.cycles < cycle { bus.idle() }
    }

    /// Parked CPU (BRA $) at $0200, voice 0 keyed on from a looping BRR
    /// sample at $0400 (directory $0300), GAIN direct, no echo.
    private func parkedSnapshot() throws -> SPCFile {
        var ram = [UInt8](repeating: 0, count: 0x10000)
        ram[0x0200] = 0x2F; ram[0x0201] = 0xFE
        ram.replaceSubrange(0x0300..<0x0304, with: [0x00, 0x04, 0x00, 0x04])
        ram.replaceSubrange(0x0400..<0x0409, with: [0x93, 0x17, 0x7F, 0x80, 0xF1, 0x2C, 0xD3, 0x00, 0x7A])
        var dsp = [UInt8](repeating: 0, count: 128)
        dsp[0x00] = 0x40; dsp[0x01] = 0x40; dsp[0x03] = 0x10; dsp[0x07] = 0x60
        dsp[0x0C] = 0x60; dsp[0x1C] = 0x60; dsp[0x5D] = 0x03; dsp[0x6C] = 0x20; dsp[0x4C] = 0x01
        return try SPCFile(registers: SPC700.Registers(pc: 0x0200, sp: 0xEF), ram: ram, dsp: dsp)
    }

    func testSnapshotRoundTripsMMIODSPAndPendingKeyOn() throws {
        let dsp = SDSP()
        let bus = try SSMPBus(dsp: dsp)
        let cpu = SPC700(bus: bus, registers: .init(pc: 0x0200))
        bus.write(0xFC, 1); bus.write(0xFA, 2); bus.write(0xFB, 3)
        bus.write(0xF1, 0x04)                       // timer 2 only
        bus.write(0xF2, 0x0C); bus.write(0xF3, 0x7F)
        bus.write(0xF2, 0x4C); bus.write(0xF3, 0x05)    // KON, not yet polled
        bus.hostWrite(port: 0, value: 0xAB)
        idle(bus, to: 40)                           // the first KON poll is at clock 61
        let snapshot = try SPCRender.snapshot(cpu: cpu, bus: bus, dsp: dsp)
        XCTAssertEqual(snapshot.dsp[0x4C], 0x05)
        XCTAssertEqual(snapshot.dsp[0x0C], 0x7F)
        XCTAssertEqual(snapshot.ram[0xF1], 0x04)
        XCTAssertEqual(snapshot.ram[0xF2], 0x4C)
        XCTAssertEqual(snapshot.ram[0xF3], 0x05)
        XCTAssertEqual(snapshot.ram[0xF4], 0xAB)
        XCTAssertEqual(Array(snapshot.ram[0xFA...0xFC]), [2, 3, 1])
        let decoded = try SPCFile(data: try snapshot.encode())
        XCTAssertEqual(decoded.ram, snapshot.ram)
        XCTAssertEqual(decoded.dsp, snapshot.dsp)

        let restoredDSP = SDSP()
        restoredDSP.load(registers: decoded.dsp)
        let restored = try SSMPBus(snapshot: decoded, dsp: restoredDSP)
        XCTAssertEqual(restored.snapshotRAM(), decoded.ram)
        XCTAssertEqual(restoredDSP.registers, decoded.dsp)
        XCTAssertEqual(restoredDSP.pendingKeyOn, 0x05)
        // Restore convention: each prescaler ticks on the first clock, so
        // timer 2 (target 1) counts one more on the first idle cycle.
        let output = decoded.ram[0xFF] & 0x0F
        restored.idle()
        XCTAssertEqual(restored.read(0xFF), output + 1)
    }

    func testTimersBeforeAccessShowsATickToTheSameCycleRead() throws {
        for timersFirst in [false, true] {
            let bus = try SSMPBus(dsp: SDSP())
            bus.timersBeforeAccess = timersFirst
            bus.write(0xFA, 1); bus.write(0xF1, 0x01)
            idle(bus, to: 127)
            // The 128th clock is timer 0's first tick; this read is in it.
            XCTAssertEqual(bus.read(0xFD), timersFirst ? 1 : 0)
            XCTAssertEqual(bus.read(0xFD), timersFirst ? 0 : 1)
            XCTAssertEqual(bus.cycles, 129)
        }
    }

    func testDurationLimitsAndOptionsAreRefused() throws {
        XCTAssertEqual(try SPCRender.frames(seconds: 1), 32000)
        XCTAssertEqual(try SPCRender.frames(seconds: 300), 9_600_000)
        XCTAssertEqual(try SPCRender.frames(seconds: 1e-9), 1)
        for seconds in [0, -1, 300.0001, .nan, .infinity] {
            XCTAssertThrowsError(try SPCRender.frames(seconds: seconds)) { error in
                guard case .invalidDuration? = error as? SPCRender.Failure else { return XCTFail("\(error)") }
            }
        }
        var options = SPCRender.Options()
        options.counter = SDSP.counterPeriod
        XCTAssertThrowsError(try SPCRender.render(snapshot: try parkedSnapshot(), seconds: 0.01, options: options)) {
            XCTAssertEqual($0 as? SPCRender.Failure, .invalidCounter(SDSP.counterPeriod))
        }
    }

    func testStereoWAVHeader() {
        let wav = [UInt8](SPCRender.wav([1, -2, 3, -4]))
        let u16 = { (i: Int) in Int(wav[i]) | Int(wav[i + 1]) << 8 }
        let u32 = { (i: Int) in u16(i) | u16(i + 2) << 16 }
        XCTAssertEqual(Array(wav[0..<4]), Array("RIFF".utf8))
        XCTAssertEqual(u32(4), 36 + 8)
        XCTAssertEqual(u16(20), 1)            // PCM
        XCTAssertEqual(u16(22), 2)            // channels
        XCTAssertEqual(u32(24), 32000)
        XCTAssertEqual(u32(28), 128_000)      // byte rate
        XCTAssertEqual(u16(32), 4)            // block align
        XCTAssertEqual(u16(34), 16)
        XCTAssertEqual(u32(40), 8)
        XCTAssertEqual(Array(wav[44...]), [1, 0, 0xFE, 0xFF, 3, 0, 0xFC, 0xFF])
    }

    func testParkedSnapshotRendersDeterministicallyAndMutes() throws {
        let snapshot = try parkedSnapshot()
        let pcm = try SPCRender.render(snapshot: snapshot, seconds: 0.05)
        XCTAssertEqual(pcm.count, 2 * 1600)
        XCTAssertTrue(pcm.contains { $0 != 0 })
        // Volumes 64/64 and MVOL 96/96: both channels carry the same signal.
        XCTAssertEqual(stride(from: 0, to: pcm.count, by: 2).map { pcm[$0] },
                       stride(from: 1, to: pcm.count, by: 2).map { pcm[$0] })
        XCTAssertEqual(try SPCRender.render(snapshot: snapshot, seconds: 0.05), pcm)
        var options = SPCRender.Options()
        options.voices = 0xFE
        XCTAssertTrue(try SPCRender.render(snapshot: snapshot, seconds: 0.05, options: options).allSatisfy { $0 == 0 })
        options = SPCRender.Options()
        options.counter = 0x7F0
        options.timersBeforeAccess = true
        // GAIN direct fires every sample and no timer runs: the same PCM.
        XCTAssertEqual(try SPCRender.render(snapshot: snapshot, seconds: 0.05, options: options), pcm)
    }

    func testCTSongRenderFromTheDriverLoad() throws {
        let rom = [UInt8](try Repo.romData())
        let render = try CTSPCRender.render(rom: rom, song: 0x18, seconds: 0.25)
        XCTAssertEqual(render.pcm.count, 2 * 8000)
        XCTAssertEqual(render.report.frames, 8000)
        XCTAssertTrue(render.report.loadChecks.allSatisfy(\.passed))
        XCTAssertGreaterThan(render.report.peak, 0)
        XCTAssertEqual(render.report.pcmSHA256, CTEventPack.sha256(render.pcm.withUnsafeBytes { Array($0) }))
        XCTAssertEqual(try CTSPCRender.render(rom: rom, song: 0x18, seconds: 0.25).pcm, render.pcm)
        // The start state replays through the snapshot path.
        let replay = try SPCRender.render(snapshot: try SPCFile(data: try render.snapshot.encode()), seconds: 0.25)
        XCTAssertEqual(replay.count, render.pcm.count)
        XCTAssertThrowsError(try CTSPCRender.render(rom: rom, song: 0x18, seconds: 301))
    }
}
