import XCTest
@testable import ChronoForgeCore

final class SPCIPLHostTests: XCTestCase {
    /// Swift model of the documented IPL receive loop; it contains no firmware.
    /// One step is one modeled instruction. Like the real loop it echoes each
    /// payload byte BEFORE storing it, treats a header with command 0 as the
    /// start jump, and can defer stores further to prove late verification.
    private final class Receiver: SPCIPLTransport {
        enum State: Equatable { case boot(Int), kick, header, waitZero, compare, store(UInt8), jump, entry }
        private(set) var state = State.boot(3)
        private(set) var cycles = 0, steps = 0, bytes = 0, executedAtEntry = 0, maxPending = 0
        private(set) var stopped = false
        private(set) var fault: SSMPBus.Fault?
        private(set) var ram = [UInt8](repeating: 0, count: 65536)
        private(set) var input = [UInt8](repeating: 0, count: 4)
        private(set) var headers: [[UInt16]] = []   // [token, command, address]
        private var output = [UInt8](repeating: 0, count: 4)
        private var base: UInt16 = 0, y: UInt8 = 0, target: UInt16 = 0
        private var pending: [(Int, UInt8)] = []
        var silent = false, deferStores = false
        var corrupt: Int?, ackLimit: Int?, stopAt: Int?, faultAt: Int?
        var jumpOffset: UInt16 = 0

        var pc: UInt16 { state == .entry ? target : 0xFFD0 }
        func hostWrite(port: Int, value: UInt8) { input[port] = value }
        func hostRead(port: Int) -> UInt8 { output[port] }

        func step() {
            guard !stopped else { return }
            steps += 1; cycles += 4
            if steps == stopAt { stopped = true; return }
            if steps == faultAt { fault = .unsupportedTEST(0); return }
            switch state {
            case .boot(let remaining):
                guard !silent else { return }
                if remaining > 0 { state = .boot(remaining - 1) } else {
                    output[0] = 0xAA; output[1] = 0xBB; state = .kick
                }
            case .kick:
                if input[0] == 0xCC { state = .header }
            case .header:
                base = UInt16(input[2]) | UInt16(input[3]) << 8
                headers.append([UInt16(input[0]), UInt16(input[1]), base])
                output[0] = input[0]
                state = input[1] == 0 ? .jump : .waitZero
            case .waitZero:
                y = input[0]
                if y == 0 { state = .compare }
            case .compare:
                if input[0] == y {
                    if let ackLimit, bytes >= ackLimit { return }
                    output[0] = y; bytes += 1; state = .store(input[1])
                } else if Int8(bitPattern: y &- input[0]) < 0 {
                    state = .header
                }
            case .store(let value):
                let address = Int(base) + Int(y)
                let stored = address == corrupt ? value ^ 0xFF : value
                if deferStores {
                    pending.append((address, stored)); maxPending = max(maxPending, pending.count)
                } else { ram[address] = stored }
                y &+= 1
                if y == 0 { base &+= 0x100 }
                state = .compare
            case .jump:
                for (address, value) in pending { ram[address] = value }
                pending = []
                target = base &+ jumpOffset; state = .entry
            case .entry:
                executedAtEntry += 1
            }
        }
    }

    private typealias Failure = SPCIPLHost.Failure
    private static let knownIPLSHA256 = "c95f88b299030d5afa55b1031e2b5ef2dff650c4b4e6bb6f8b1359436521278f"

    /// Spans a page-crossing counter wrap (300 bytes, last token $2B) and the
    /// zero-token correction (253 bytes: last $FC, $FC + 4 wraps to 0 -> 1).
    private static func protocolBlocks() -> [SPCIPLHost.Block] {
        var program: [UInt8] = [0x8F, 0x5A, 0xF4, 0xE4, 0xF4, 0xFF]   // MOV $F4,#$5A; MOV A,$F4; STOP
        program += (0..<294).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }
        return [.init(destination: 0x0480, bytes: program),
                .init(destination: 0x3000, bytes: (0..<253).map { UInt8(255 - $0) }),
                .init(destination: 0x7000, bytes: [0x42])]
    }

    private func upload(_ receiver: Receiver, blocks: [SPCIPLHost.Block] = SPCIPLHostTests.protocolBlocks(),
                        entry: UInt16 = 0x0480, limits: SPCIPLHost.Limits = .init()) throws -> SPCIPLHost.Report {
        try SPCIPLHost.upload(to: receiver, blocks: blocks, entry: entry, limits: limits)
    }

    private func assertFailure(_ expression: @autoclosure () throws -> Any,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ matches: (Failure) -> Bool) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let failure = error as? Failure else {
                return XCTFail("unexpected error \(error)", file: file, line: line)
            }
            XCTAssertTrue(matches(failure), "unexpected failure \(failure)", file: file, line: line)
        }
    }

    // Token values below are hand-derived from the CT sender rule, not the host.
    private func assertProtocolReport(_ report: SPCIPLHost.Report, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(report.blocks.map(\.startToken), [0xCC, 0x2F, 0x01], file: file, line: line)
        XCTAssertEqual(report.blocks.map(\.lastByteToken), [0x2B, 0xFC, 0x00], file: file, line: line)
        XCTAssertEqual(report.blocks.map(\.nextToken), [0x2F, 0x01, 0x04], file: file, line: line)
        XCTAssertEqual(report.startToken, 0x04, file: file, line: line)
        XCTAssertEqual(report.bytesTransferred, 554, file: file, line: line)
        XCTAssertEqual(report.acknowledgementCount, 4 + 554, file: file, line: line)
        XCTAssertEqual(report.entry, 0x0480, file: file, line: line)
        XCTAssertTrue(report.payloadVerified, file: file, line: line)
        XCTAssertEqual(report.blocks.map(\.sha256), Self.protocolBlocks().map { CTEventPack.sha256($0.bytes) },
                       file: file, line: line)
    }

    // MARK: Synthetic protocol lane (no firmware)

    func testSyntheticUploadWrapsCountersCorrectsZeroTokenAndStopsBeforeEntry() throws {
        let receiver = Receiver()
        let report = try upload(receiver)
        assertProtocolReport(report)
        XCTAssertEqual(receiver.headers, [[0xCC, 0xCC, 0x0480], [0x2F, 0x2F, 0x3000],
                                          [0x01, 0x01, 0x7000], [0x04, 0x00, 0x0480]])
        for block in Self.protocolBlocks() {
            let start = Int(block.destination)
            XCTAssertEqual(Array(receiver.ram[start..<(start + block.bytes.count)]), block.bytes)
        }
        XCTAssertEqual(receiver.pc, 0x0480)
        XCTAssertEqual(receiver.executedAtEntry, 0, "host must stop before the entry instruction")
        XCTAssertEqual(receiver.input[0], 0, "CT writes APUIO0 = 0 after the start echo")
        XCTAssertEqual(report.totalCycles, receiver.cycles)
    }

    func testVerificationWaitsForStoresCommittedAfterTheirAcknowledgements() throws {
        let receiver = Receiver()
        receiver.deferStores = true
        assertProtocolReport(try upload(receiver))
        XCTAssertEqual(receiver.maxPending, 554, "every store was still pending at its echo")
    }

    func testCorruptedStoreIsReportedWithBlockAndAddress() {
        let receiver = Receiver()
        receiver.corrupt = 0x3005
        assertFailure(try upload(receiver)) {
            $0 == .integrity(block: 1, address: 0x3005, expected: 250, actual: 250 ^ 0xFF)
        }
    }

    func testBudgetsBoundEveryWait() {
        let limits = SPCIPLHost.Limits(totalCycles: 10_000, waitCycles: 200)
        let silent = Receiver(); silent.silent = true
        assertFailure(try upload(silent, limits: limits)) {
            guard case .budgetExceeded("ready signature", let cycles, _) = $0 else { return false }
            return (200...204).contains(cycles)
        }
        let stalled = Receiver(); stalled.ackLimit = 10
        assertFailure(try upload(stalled, limits: limits)) {
            guard case .budgetExceeded("block 0 byte 10", _, _) = $0 else { return false }
            return true
        }
        let misdirected = Receiver(); misdirected.jumpOffset = 1
        assertFailure(try upload(misdirected, limits: limits)) { $0 == .wrongEntry(expected: 0x0480, actual: 0x0481) }
        XCTAssertEqual(misdirected.executedAtEntry, 0, "a wrong jump target must not be executed")
        let healthy = Receiver()
        assertFailure(try upload(healthy, limits: .init(totalCycles: 1_000, waitCycles: 200))) {
            guard case .budgetExceeded(_, let cycles, _) = $0 else { return false }
            return (1_000...1_004).contains(cycles)
        }
    }

    func testStoppedCPUAndBusFaultAbortTheUpload() {
        let stopped = Receiver(); stopped.stopAt = 40
        assertFailure(try upload(stopped)) {
            guard case .stopped(let phase, _) = $0 else { return false }
            return phase.hasPrefix("block 0 byte")
        }
        let faulted = Receiver(); faulted.faultAt = 40
        assertFailure(try upload(faulted)) { $0 == .busFault(.unsupportedTEST(0)) }
        XCTAssertEqual(faulted.steps, 40)
    }

    func testInvalidRequestsAreRejectedBeforeAnyPortActivity() {
        let one = SPCIPLHost.Block(destination: 0x0400, bytes: [0])
        let cases: [([SPCIPLHost.Block], UInt16, SPCIPLHost.Limits)] = [
            ([], 0x0400, .init()),
            (Array(repeating: one, count: 257), 0x0400, .init()),
            ([.init(destination: 0x0400, bytes: [])], 0x0400, .init()),
            ([.init(destination: 0x01FF, bytes: [0, 0])], 0x0200, .init()),
            ([.init(destination: 0xFFBF, bytes: [0, 0])], 0xFFBF, .init()),
            ([.init(destination: 0x0400, bytes: [0, 0]), .init(destination: 0x0401, bytes: [0])], 0x0400, .init()),
            ([one], 0x0401, .init()),
            ([one], 0x0400, .init(totalCycles: 0)),
            ([one], 0x0400, .init(waitCycles: 100_000_001)),
        ]
        for (index, (blocks, entry, limits)) in cases.enumerated() {
            let receiver = Receiver()
            assertFailure(try upload(receiver, blocks: blocks, entry: entry, limits: limits)) {
                guard case .invalidInput = $0 else { return false }
                return true
            }
            XCTAssertEqual(receiver.steps, 0, "case \(index)")
            XCTAssertEqual(receiver.input, [0, 0, 0, 0], "case \(index)")
        }
        // Boundaries themselves are accepted.
        XCTAssertNoThrow(try upload(Receiver(), blocks: [.init(destination: 0x0200, bytes: [0]),
                                                         .init(destination: 0xFFBF, bytes: [0])], entry: 0xFFBF))
    }

    // MARK: Real SPC700 + bus adapter with synthetic (non-IPL) images

    func testHostAdapterSurfacesCPUStateAndIsSingleUse() throws {
        let block = [SPCIPLHost.Block(destination: 0x0400, bytes: [0])]
        XCTAssertThrowsError(try SPCIPLHost(iplROM: [UInt8](repeating: 0, count: 63), dsp: NullDSP()))
        XCTAssertThrowsError(try SPCIPLHost(iplROM: [UInt8](repeating: 0, count: 64), dsp: NullDSP(),
                                            limits: .init(totalCycles: 0)))
        let stopping = try SPCIPLHost(iplROM: [UInt8](repeating: 0xFF, count: 64), dsp: NullDSP())   // STOP
        assertFailure(try stopping.upload(blocks: block, entry: 0x0400)) {
            guard case .stopped("ready signature", _) = $0 else { return false }
            return true
        }
        assertFailure(try stopping.upload(blocks: block, entry: 0x0400)) { $0 == .alreadyUsed }
        let testWrite = try SPCIPLHost(iplROM: [0x8F, 0x00, 0xF0] + [UInt8](repeating: 0, count: 61), dsp: NullDSP())
        assertFailure(try testWrite.upload(blocks: block, entry: 0x0400)) { $0 == .busFault(.unsupportedTEST(0)) }
        let spinning = try SPCIPLHost(iplROM: [0x2F, 0xFE] + [UInt8](repeating: 0, count: 62), dsp: NullDSP(),
                                      limits: .init(totalCycles: 50_000, waitCycles: 1_000))   // BRA $FFC0
        assertFailure(try spinning.upload(blocks: block, entry: 0x0400)) {
            guard case .budgetExceeded("ready signature", let cycles, 0xFFC0) = $0 else { return false }
            return (1_000...1_004).contains(cycles)
        }
    }

    // MARK: Real-image lane (local IPL via CHRONOFORGE_IPL_ROM; never bundled)

    /// Absent variable: skipped and reported UNVERIFIED. Explicit bad path or
    /// unexpected image: the test fails instead of silently skipping.
    private func localIPL() throws -> [UInt8] {
        guard let path = ProcessInfo.processInfo.environment["CHRONOFORGE_IPL_ROM"], !path.isEmpty else {
            throw XCTSkip("UNVERIFIED real-IPL lane: set CHRONOFORGE_IPL_ROM to a local 64-byte S-SMP IPL image")
        }
        let image = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard image.count == 64, CTEventPack.sha256(image) == Self.knownIPLSHA256 else {
            throw InvalidIPL(description: "CHRONOFORGE_IPL_ROM is not the expected 64-byte S-SMP IPL image")
        }
        return image
    }

    func testRealIPLUploadMatchesProtocolModelAndStopsBeforeEntry() throws {
        let host = try SPCIPLHost(iplROM: localIPL(), dsp: NullDSP())
        let report = try host.upload(blocks: Self.protocolBlocks(), entry: 0x0480)
        assertProtocolReport(report)
        XCTAssertEqual(host.cpu.registers.pc, 0x0480)
        XCTAssertEqual(report.totalCycles, host.cpu.cycles)
        XCTAssertEqual(host.cpu.cycles, host.bus.cycles)
        XCTAssertNil(host.bus.fault)
        for block in Self.protocolBlocks() {
            let start = Int(block.destination)
            XCTAssertEqual(Array(host.bus.ram[start..<(start + block.bytes.count)]), block.bytes)
        }
        XCTAssertEqual(host.bus.hostRead(port: 0), 0x04, "IPL echo of the start token")
        XCTAssertEqual(host.bus.hostRead(port: 1), 0xBB, "IPL ready signature byte")
        host.cpu.step()   // the entry instruction: MOV $F4,#$5A
        XCTAssertEqual(host.bus.hostRead(port: 0), 0x5A, "entry had not executed before upload returned")
        host.cpu.registers.a = 0xEE
        host.cpu.step()   // MOV A,$F4 reads the host->SMP latch
        XCTAssertEqual(host.cpu.registers.a, 0, "host cleared APUIO0 after the start echo, as CT does")
    }

    func testRealIPLUploadsCTBootBlocksBeforeDriverEntry() throws {
        let ipl = try localIPL()
        guard let data = try? Repo.romData() else { throw XCTSkip("local ROM not present") }
        let rom = [UInt8](data)
        let image = try CTSPCDriver.bootImage(rom: rom)
        let host = try SPCIPLHost(iplROM: ipl, dsp: NullDSP())
        let report = try host.upload(blocks: image.blocks.map {
            .init(destination: UInt16($0.destination), bytes: Array(rom[($0.sourcePC + 2)..<($0.sourcePC + 2 + $0.length)]))
        }, entry: 0x0200)
        XCTAssertEqual(host.cpu.registers.pc, 0x0200)
        // Independent of the host's own check: compare ARAM to the ROM sources.
        for block in image.blocks {
            XCTAssertEqual(Array(host.bus.ram[block.destination..<(block.destination + block.length)]),
                           Array(rom[(block.sourcePC + 2)..<(block.sourcePC + 2 + block.length)]))
        }
        // Lengths $1BEF, $1800, $201, $24, $14, $14; next = last + 4 (0 -> 1).
        XCTAssertEqual(report.blocks.map(\.startToken), [0xCC, 0xF2, 0x03, 0x04, 0x27, 0x17])
        XCTAssertEqual(report.blocks.map(\.lastByteToken), [0xEE, 0xFF, 0x00, 0x23, 0x13, 0x13])
        XCTAssertEqual(report.startToken, 0x17)
        XCTAssertEqual(report.bytesTransferred, 13_884)
        XCTAssertEqual(report.acknowledgementCount, 13_884 + 7)

        let diagnostic = try CTSPCDriver.check(rom: rom, iplROM: ipl)
        XCTAssertTrue(diagnostic.passed, diagnostic.checks.filter { !$0.passed }.map(\.name).joined(separator: ", "))
        XCTAssertEqual(diagnostic.checks.count, 13)
        XCTAssertEqual(diagnostic.upload, report)
        XCTAssertEqual(diagnostic.iplSHA256, Self.knownIPLSHA256)
        XCTAssertTrue(diagnostic.mode.hasPrefix("IPL-upload"))
        XCTAssertGreaterThanOrEqual(diagnostic.bootCycles, 81_920)
        XCTAssertLessThan(diagnostic.totalCycles, 250_000)
    }
}

private struct InvalidIPL: Error, CustomStringConvertible { let description: String }

private final class NullDSP: SSMPDSPPort {
    func readRegister(_ address: UInt8) -> UInt8 { 0 }
    func writeRegister(_ address: UInt8, _ value: UInt8) {}
    func clock(ram: inout [UInt8]) {}
}
