import XCTest
@testable import ChronoForgeCore

final class SSMPBusTests: XCTestCase {
    private final class DSP: SSMPDSPPort {
        var registers = [UInt8](repeating: 0, count: 128)
        var clocks = 0
        var accesses: [String] = []
        func readRegister(_ address: UInt8) -> UInt8 {
            accesses.append("read \(address) at \(clocks)")
            return registers[Int(address)]
        }
        func writeRegister(_ address: UInt8, _ value: UInt8) {
            accesses.append("write \(address) at \(clocks)")
            registers[Int(address)] = value
        }
        func clock(ram: inout [UInt8]) { clocks += 1 }
    }

    private func advance(_ bus: SSMPBus, to cycle: Int) {
        precondition(cycle >= bus.cycles)
        while bus.cycles < cycle { bus.idle() }
    }

    func testInitialMemoryIsNotMMIOStateAndLengthsAreValidated() throws {
        let dsp = DSP(), ram = [UInt8](repeating: 0xA5, count: 65536)
        let bus = try SSMPBus(ram: ram, dsp: dsp)
        XCTAssertEqual(bus.read(0x1234), 0xA5)
        for address in [UInt16](arrayLiteral: 0xF0, 0xF1, 0xF2, 0xF4, 0xF8, 0xFA, 0xFD) {
            XCTAssertEqual(bus.read(address), 0)
        }
        XCTAssertEqual(bus.ram[0xF8], 0xA5)
        XCTAssertThrowsError(try SSMPBus(ram: [], dsp: dsp))
        XCTAssertThrowsError(try SSMPBus(iplROM: [], dsp: dsp))
        XCTAssertThrowsError(try SSMPBus(iplROM: [0], dsp: dsp))
        XCTAssertThrowsError(try SSMPBus(iplROMEnabled: true, dsp: dsp))
    }

    func testDirectionalPortsAndPairClearingDoNotClearReplies() throws {
        let bus = try SSMPBus(dsp: DSP())
        for port in 0..<4 {
            bus.hostWrite(port: port, value: UInt8(0x10 + port))
            XCTAssertEqual(bus.hostRead(port: port), 0)
        }
        XCTAssertEqual(bus.cycles, 0)
        XCTAssertEqual(bus.ram[0xF4], 0)
        for port in 0..<4 {
            bus.write(UInt16(0xF4 + port), UInt8(0x20 + port))
            XCTAssertEqual(bus.read(UInt16(0xF4 + port)), UInt8(0x10 + port))
            XCTAssertEqual(bus.hostRead(port: port), UInt8(0x20 + port))
        }
        bus.write(0xF1, 0x10)
        XCTAssertEqual(bus.read(0xF4), 0)
        XCTAssertEqual(bus.read(0xF5), 0)
        XCTAssertEqual(bus.read(0xF6), 0x12)
        XCTAssertEqual(bus.read(0xF7), 0x13)
        bus.hostWrite(port: 0, value: 0x99)
        bus.write(0xF1, 0x20)
        XCTAssertEqual(bus.read(0xF4), 0x99)
        XCTAssertEqual(bus.read(0xF6), 0)
        XCTAssertEqual(bus.read(0xF7), 0)
        for port in 0..<4 { XCTAssertEqual(bus.hostRead(port: port), UInt8(0x20 + port)) }
    }

    func testIPLOverlayPreservesWritesAndIsOnlyMappedAtTopOfRAM() throws {
        // Deliberately synthetic IPL bytes: tests do not embed a console ROM.
        let rom = (0..<64).map { UInt8($0 + 0x40) }
        let bus = try SSMPBus(iplROM: rom, iplROMEnabled: true, dsp: DSP())
        bus.write(0xFFC0, 0x12); bus.write(0xFFFF, 0x34)
        bus.write(0xFFBF, 0x56); bus.write(0x01F1, 0x78)
        XCTAssertEqual(bus.read(0xFFC0), 0x40)
        XCTAssertEqual(bus.read(0xFFFF), 0x7F)
        XCTAssertEqual(bus.read(0xFFBF), 0x56)
        XCTAssertEqual(bus.read(0x01F1), 0x78)
        XCTAssertEqual(bus.ram[0xFFC0], 0x12)
        bus.write(0xF1, 0)
        XCTAssertEqual(bus.read(0xFFC0), 0x12)
        XCTAssertEqual(bus.read(0xFFFF), 0x34)
        bus.write(0xF1, 0x80)
        XCTAssertEqual(bus.read(0xFFC0), 0x40)
    }

    func testDSPMirroringWriteProtectionAndAccessBeforeClock() throws {
        let dsp = DSP(), bus = try SSMPBus(dsp: dsp)
        bus.write(0xF2, 0x4C)
        bus.write(0xF3, 0xA5)
        XCTAssertEqual(dsp.accesses, ["write 76 at 1"])
        XCTAssertEqual(bus.read(0xF3), 0xA5)
        bus.write(0xF2, 0xCC)
        XCTAssertEqual(bus.read(0xF2), 0xCC)
        bus.write(0xF3, 0xFF)
        XCTAssertEqual(bus.read(0xF3), 0xA5)
        XCTAssertEqual(dsp.accesses, ["write 76 at 1", "read 76 at 2", "read 76 at 6"])
        XCTAssertEqual(bus.ram[0xF3], 0xFF)
        bus.idle()
        XCTAssertEqual(bus.cycles, 8)
        XCTAssertEqual(dsp.clocks, 8)
    }

    func testTimerRatesReadClearAndReadOnlyOutputs() throws {
        let bus = try SSMPBus(dsp: DSP())
        bus.write(0xFA, 1); bus.write(0xFB, 2); bus.write(0xFC, 1)
        bus.write(0xF1, 7)
        advance(bus, to: 127)
        // Access occurs before the 128th clock. That clock raises timer0's
        // output after its old zero has been returned and cleared.
        XCTAssertEqual(bus.read(0xFD), 0)
        XCTAssertEqual(bus.read(0xFD), 1)
        XCTAssertEqual(bus.read(0xFD), 0)
        XCTAssertEqual(bus.read(0xFE), 0)
        XCTAssertEqual(bus.read(0xFF), 8)
        XCTAssertEqual(bus.read(0xFF), 0)
        advance(bus, to: 256)
        bus.write(0xFE, 0xFF)
        XCTAssertEqual(bus.read(0xFE), 1)
        XCTAssertEqual(bus.ram[0xFE], 0xFF)
        XCTAssertEqual(bus.read(0xFA), 0)
    }

    func testTimerEnableResetsDividerAndOutputButNotPrescaler() throws {
        let bus = try SSMPBus(dsp: DSP())
        bus.write(0xFC, 2)
        advance(bus, to: 15)
        bus.write(0xF1, 4) // First enabled base tick at cycle16, not cycle31.
        advance(bus, to: 32)
        XCTAssertEqual(bus.read(0xFF), 1)
        advance(bus, to: 48) // First half of the next target period.
        bus.write(0xF1, 4) // Rewriting enabled must not reset the divider.
        advance(bus, to: 64)
        XCTAssertEqual(bus.read(0xFF), 1)
        advance(bus, to: 96) // Leave an unread output and part of next period.
        bus.write(0xF1, 0)
        XCTAssertEqual(bus.read(0xFF), 1) // Disable retains unread output.
        advance(bus, to: 111)
        bus.write(0xF1, 4) // Rise clears divider/output; phase still reaches112.
        XCTAssertEqual(bus.read(0xFF), 0)
        advance(bus, to: 128)
        XCTAssertEqual(bus.read(0xFF), 1)
    }

    func testEnableClearsUnreadOutputForEveryTimer() throws {
        for index in 0..<3 {
            let bus = try SSMPBus(dsp: DSP())
            bus.write(UInt16(0xFA + index), 1)
            bus.write(0xF1, UInt8(1 << index))
            advance(bus, to: 128)
            bus.write(0xF1, 0)
            bus.write(0xF1, UInt8(1 << index))
            XCTAssertEqual(bus.read(UInt16(0xFD + index)), 0)
        }
    }

    func testZeroTargetMeans256AndOutputWrapsAt16() throws {
        let bus = try SSMPBus(dsp: DSP())
        bus.write(0xF1, 4)
        advance(bus, to: 4095)
        XCTAssertEqual(bus.read(0xFF), 0)
        XCTAssertEqual(bus.read(0xFF), 1)
        bus.write(0xF1, 0)
        bus.write(0xFC, 1)
        bus.write(0xF1, 4)
        advance(bus, to: 4352) // Sixteen enabled 16-cycle ticks after cycle4096.
        XCTAssertEqual(bus.read(0xFF), 0)
        advance(bus, to: 4368)
        XCTAssertEqual(bus.read(0xFF), 1)
    }

    func testChangingTargetUsesEqualityWithoutResettingCurrentDivider() throws {
        let bus = try SSMPBus(dsp: DSP())
        bus.write(0xFC, 4); bus.write(0xF1, 4)
        advance(bus, to: 48) // Divider is3.
        bus.write(0xFC, 2) // Must wrap to2, not trigger on >= or reset to0.
        advance(bus, to: 80)
        XCTAssertEqual(bus.read(0xFF), 0)
        advance(bus, to: 4128) // 258 total ticks: 3 + 255 more reaches2.
        XCTAssertEqual(bus.read(0xFF), 1)
    }

    func testUnsupportedModesFailClosed() throws {
        let dsp = DSP(), bus = try SSMPBus(dsp: dsp)
        bus.write(0xF0, 0x0A)
        XCTAssertNil(bus.fault)
        bus.write(0xF0, 0)
        XCTAssertEqual(bus.fault, .unsupportedTEST(0))
        bus.write(0x1000, 0xFF); bus.idle()
        XCTAssertEqual(bus.read(0x1000), 0)
        XCTAssertEqual(bus.cycles, 1)
        XCTAssertEqual(dsp.clocks, 1)
        XCTAssertEqual(bus.ram[0x1000], 0)
        XCTAssertEqual(bus.ram[0xF0], 0x0A)
        let noIPL = try SSMPBus(dsp: DSP())
        noIPL.write(0xF1, 0x80)
        XCTAssertEqual(noIPL.fault, .missingIPLROM)
        XCTAssertFalse(noIPL.iplROMEnabled)
        XCTAssertEqual(noIPL.cycles, 0)
    }

    func testCPUProgramObservesPortAndTimerThroughRealBus() throws {
        var ram = [UInt8](repeating: 0, count: 65536)
        // MOV A,$F4; MOV $F5,A; MOV $FC,#1; MOV $F1,#4;
        // MOV A,$FF; BEQ -4; MOV $0200,A; STOP.
        let program: [UInt8] = [0xE4, 0xF4, 0xC4, 0xF5, 0x8F, 1, 0xFC,
                               0x8F, 4, 0xF1, 0xE4, 0xFF, 0xF0, 0xFC,
                               0xC5, 0, 2, 0xFF]
        ram.replaceSubrange(0x100..<(0x100 + program.count), with: program)
        let dsp = DSP(), bus = try SSMPBus(ram: ram, dsp: dsp)
        bus.hostWrite(port: 0, value: 0x42)
        let cpu = SPC700(bus: bus, registers: .init(pc: 0x100))
        cpu.run(cycles: 100)
        XCTAssertTrue(cpu.stopped)
        XCTAssertEqual(bus.hostRead(port: 1), 0x42)
        XCTAssertEqual(bus.ram[0x200], 1)
        XCTAssertEqual(bus.cycles, cpu.cycles)
        XCTAssertEqual(dsp.clocks, cpu.cycles)
        XCTAssertNil(bus.fault)
    }

    func testCPUStoreDummyReadClearsTimerOutput() throws {
        var ram = [UInt8](repeating: 0, count: 65536)
        // MOV A,#$55; MOV $FF,A. The second instruction reads the target
        // before writing it: that dummy read must consume the timer count.
        ram.replaceSubrange(0x1000..<0x1004, with: [0xE8, 0x55, 0xC4, 0xFF])
        let bus = try SSMPBus(ram: ram, dsp: DSP())
        bus.write(0xFC, 16); bus.write(0xF1, 4)
        advance(bus, to: 256) // One output tick; next is not until clock512.
        let cpu = SPC700(bus: bus, registers: .init(pc: 0x1000))
        cpu.step(); cpu.step()
        XCTAssertEqual(bus.ram[0xFF], 0x55)
        XCTAssertEqual(bus.read(0xFF), 0)
    }
}
