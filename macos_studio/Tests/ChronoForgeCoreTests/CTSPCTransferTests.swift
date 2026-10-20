import XCTest
@testable import ChronoForgeCore

final class CTSPCTransferTests: XCTestCase {
    /// Swift model of the driver's song command and transfer receive
    /// (Spc_PollCommand, Spc_CmdSongCheck, Spc_XferReceive, Spc_XferHeader,
    /// Spc_XferWords, Spc_XferTriples); it contains no firmware. One step is
    /// one modeled instruction of 4 clocks. Like the driver it echoes a
    /// triples step after reading CPUIO1 and reads CPUIO2/3 on the next two
    /// steps, while a words step is read whole before its echo.
    private final class Receiver: SPCIPLTransport {
        enum State: Equatable { case idle, songCheck, sameSong, waitSequence, header, firstStep, triples(Int), words, waitStep, starting(Int), done }
        private(set) var state = State.idle
        private(set) var cycles = 0, steps = 0
        private(set) var stopped = false
        private(set) var fault: SSMPBus.Fault?
        private(set) var ram = [UInt8](repeating: 0, count: 65536)
        private(set) var input = [UInt8](repeating: 0, count: 4)
        private(set) var commands: [[UInt8]] = []
        private(set) var headers: [[Int]] = []      // [sequence, mode, address]
        private var output = [UInt8](repeating: 0, count: 4)
        private var id: UInt8 = 0, x: UInt8 = 0, mode: UInt8 = 0, address = 0, offset = 0
        var currentSong: UInt8 = 0xFF, voices: UInt8 = 0x05, startSteps = 20
        var refuseWith: UInt8?, corrupt: Int?, stopAt: Int?, faultAt: Int?, deaf = false

        var pc: UInt16 { 0x1000 }
        func hostWrite(port: Int, value: UInt8) { input[port] = value }
        func hostRead(port: Int) -> UInt8 { output[port] }
        func report(_ value: UInt8) { output[0] = value }

        func step() {
            guard !stopped else { return }
            steps += 1; cycles += 4
            if steps == stopAt { stopped = true; return }
            if steps == faultAt { fault = .unsupportedTEST(0); return }
            switch state {
            case .idle:
                guard !deaf, input[0] != 0 else { return }
                id = input[0]; commands.append(input)
                input[0] = 0; input[1] = 0                          // Spc_ClearPorts01
                state = .songCheck
            case .songCheck:
                let song = commands.last![1]
                if song == currentSong { output[1] = 0xFF; output[0] = id; state = .sameSong; return }
                currentSong = song; output[1] = song; output[0] = id; state = .waitSequence
            case .sameSong:
                if input[0] != 0 { input[0] = 0; input[1] = 0; state = .idle }
            case .waitSequence:
                if input[0] == id { output[0] = id } else if input[0] == (id &+ 1) & 0x7F { x = input[0]; state = .header }
            case .header:
                address = Int(input[2]) | Int(input[3]) << 8; mode = input[1]
                headers.append([Int(x), Int(mode), address])
                if mode == 0xE0 {
                    output[1] = 0; output[0] = x; input[0] = 0; input[1] = 0; state = .starting(startSteps)
                } else {
                    output[1] = refuseWith ?? mode; output[0] = x; offset = 0; state = .firstStep
                }
            case .firstStep:
                if input[0] != x { x = input[0]; output[1] = 0xEE; state = mode == 2 ? .words : .triples(1) }
            case .triples(1): store(input[1]); output[0] = x; state = .triples(2)
            case .triples(2): store(input[2]); state = .triples(3)
            case .triples: store(input[3]); state = .waitStep
            case .words: let low = input[1], high = input[2]; output[0] = x; store(low); store(high); state = .waitStep
            case .waitStep:
                guard input[0] != x else { return }
                x = input[0]
                if x == 0xE0 { state = .header } else if x & 0x80 == 0 { state = mode == 2 ? .words : .triples(1) }
            case .starting(let remaining):
                if remaining > 0 { state = .starting(remaining - 1) } else { output[3] = voices; output[0] = 0; state = .done }
            case .done: break
            }
        }

        private func store(_ value: UInt8) {
            let target = (address + offset) & 0xFFFF
            ram[target] = target == corrupt ? value ^ 0xFF : value
            offset += 1
        }
    }

    private typealias Failure = CTSPCTransfer.Failure
    private static let iplSHA256 = "c95f88b299030d5afa55b1031e2b5ef2dff650c4b4e6bb6f8b1359436521278f"

    /// 120 triples steps take the sequence from $12 through $7F and $00.
    private static let triples: [UInt8] = (0..<360).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 1) }
    private static func modelPlan() throws -> CTSPCTransfer.Plan {
        try .init(song: 7, command: 0x10, arguments: [7, 0x9C, 3], transfers: [
            .init(label: "triples", destination: 0x4901, mode: 3, bytes: triples),
            .init(label: "words", destination: 0x1E80, mode: 2, bytes: (0..<64).map { UInt8($0) }),
            .init(label: "last", destination: 0xF120, mode: 3, bytes: [0xAA, 0xBB, 0xCC]),
        ])
    }

    private func load(_ receiver: Receiver, limits: CTSPCTransfer.Limits = .init()) throws -> CTSPCTransfer.Report {
        try CTSPCTransfer.load(on: receiver, plan: Self.modelPlan(), limits: limits)
    }

    private func assertFailure(_ expression: @autoclosure () throws -> Any,
                               file: StaticString = #filePath, line: UInt = #line,
                               _ matches: (Failure) -> Bool) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard let failure = error as? Failure else { return XCTFail("unexpected error \(error)", file: file, line: line) }
            XCTAssertTrue(matches(failure), "unexpected failure \(failure)", file: file, line: line)
        }
    }

    // MARK: Protocol model (no firmware)

    // Sequence values are hand-derived from Audio_StartSong / Audio_SendSeq:
    // first header = command + 1, later headers $E0, steps (header + 1) & $7F on.
    func testModelLoadFollowsTheSenderSequenceAndVerifiesAtTheEnd() throws {
        let receiver = Receiver()
        let report = try load(receiver)
        XCTAssertEqual(receiver.commands, [[0x10, 7, 0x9C, 3]])
        XCTAssertEqual(Array(receiver.headers.prefix(3)), [[0x11, 3, 0x4901], [0xE0, 2, 0x1E80], [0xE0, 3, 0xF120]])
        XCTAssertEqual(receiver.headers.last.map { Array($0.prefix(2)) }, [0xE0, 0xE0], "the end step: APUIO1 = APUIO0 = $E0")
        XCTAssertEqual(report.transfers.map(\.headerSequence), [0x11, 0xE0, 0xE0])
        XCTAssertEqual(report.transfers.map(\.steps), [120, 32, 1])
        XCTAssertEqual(report.songReply, 7)
        XCTAssertEqual(report.endReply, 0)
        XCTAssertEqual(report.voicesReport, 0x05)
        XCTAssertEqual(report.bytesTransferred, 360 + 64 + 3)
        XCTAssertEqual(report.stepCount, 153)
        XCTAssertEqual(report.acknowledgementCount, 1 + 3 + 153 + 1)
        XCTAssertTrue(report.payloadVerified)
        XCTAssertEqual(report.totalCycles, receiver.cycles)
        XCTAssertEqual(report.loadCycles + report.startCycles, report.totalCycles)
        XCTAssertEqual(report.transfers.map(\.sha256), try Self.modelPlan().transfers.map { CTEventPack.sha256($0.bytes) })
        for transfer in try Self.modelPlan().transfers {
            let start = Int(transfer.destination)
            XCTAssertEqual(Array(receiver.ram[start..<(start + transfer.bytes.count)]), transfer.bytes)
        }
        XCTAssertEqual(receiver.state, .done)
    }

    func testStepDelayCoversTheLateTriplesReads() throws {
        // No delay: step 0's bytes 2/3 are read after step 1 replaced them.
        assertFailure(try load(Receiver(), limits: .init(stepDelay: 0))) {
            $0 == .integrity(transfer: 0, address: 0x4902, expected: Self.triples[1], actual: Self.triples[4])
        }
        // One modeled instruction: byte 2 is read in time, byte 3 is not.
        assertFailure(try load(Receiver(), limits: .init(stepDelay: 4))) {
            $0 == .integrity(transfer: 0, address: 0x4903, expected: Self.triples[2], actual: Self.triples[5])
        }
        XCTAssertNoThrow(try load(Receiver(), limits: .init(stepDelay: 8)))
        // Words are read before their echo, so no delay is needed.
        let words = try CTSPCTransfer.Plan(song: 1, command: 0x11, arguments: [1, 0, 5], transfers: [
            .init(label: "words", destination: 0x1F40, mode: 2, bytes: (0..<40).map { UInt8($0 * 3) })])
        XCTAssertNoThrow(try CTSPCTransfer.load(on: Receiver(), plan: words, limits: .init(stepDelay: 0)))
    }

    func testCorruptedStoreIsReportedWithTransferAndAddress() {
        let receiver = Receiver()
        receiver.corrupt = 0x1E85
        assertFailure(try load(receiver)) { $0 == .integrity(transfer: 1, address: 0x1E85, expected: 5, actual: 5 ^ 0xFF) }
    }

    func testDriverRepliesThatEndTheLoad() {
        let current = Receiver(); current.currentSong = 7
        assertFailure(try load(current)) { $0 == .songAlreadyCurrent(reply: 0xFF) }
        XCTAssertEqual(current.headers, [], "nothing is sent after a same-song reply")
        let refusing = Receiver(); refusing.refuseWith = 0
        assertFailure(try load(refusing)) { $0 == .refused(transfer: 0, mode: 3, reply: 0) }
        let busy = Receiver(); busy.report(0x17)
        assertFailure(try load(busy)) { $0 == .notIdle(0x17) }
        XCTAssertEqual(busy.steps, 0)
        XCTAssertEqual(busy.input, [0, 0, 0, 0])
    }

    func testBudgetsStopAndFaultAbortTheLoad() {
        let deaf = Receiver(); deaf.deaf = true
        assertFailure(try load(deaf, limits: .init(totalCycles: 100_000, waitCycles: 400))) {
            guard case .budgetExceeded("song command", let cycles, _) = $0 else { return false }
            return (400...420).contains(cycles)   // the step delay's own wait comes first
        }
        let slowStart = Receiver(); slowStart.startSteps = 1_000
        assertFailure(try load(slowStart, limits: .init(waitCycles: 2_000))) {
            guard case .budgetExceeded("first port report", _, _) = $0 else { return false }
            return true
        }
        assertFailure(try load(Receiver(), limits: .init(totalCycles: 2_000))) {
            guard case .budgetExceeded(_, let cycles, _) = $0 else { return false }
            return (2_000...2_004).contains(cycles)
        }
        let stopped = Receiver(); stopped.stopAt = 200
        assertFailure(try load(stopped)) {
            guard case .stopped(let phase, _) = $0 else { return false }
            return phase.hasPrefix("transfer 0 step")
        }
        let faulted = Receiver(); faulted.faultAt = 200
        assertFailure(try load(faulted)) { $0 == .busFault(.unsupportedTEST(0)) }
        XCTAssertEqual(faulted.steps, 200)
    }

    func testInvalidRequestsAreRejectedBeforeAnyPortActivity() throws {
        for limits in [CTSPCTransfer.Limits(totalCycles: 0), .init(waitCycles: 0), .init(stepDelay: -1), .init(stepDelay: 10_001)] {
            let receiver = Receiver()
            assertFailure(try load(receiver, limits: limits)) {
                guard case .invalidInput = $0 else { return false }
                return true
            }
            XCTAssertEqual(receiver.steps, 0)
            XCTAssertEqual(receiver.input, [0, 0, 0, 0])
        }
        let one = CTSPCTransfer.Transfer(label: "t", destination: 0x2000, mode: 3, bytes: [1, 2, 3])
        let plans: [(UInt8, [UInt8], [CTSPCTransfer.Transfer])] = [
            (0x12, [0, 0, 5], [one]),
            (0x10, [0, 0], [one]),
            (0x10, [0, 0, 5], []),
            (0x10, [0, 0, 5], Array(repeating: one, count: 65)),
            (0x10, [0, 0, 5], [.init(label: "t", destination: 0x2000, mode: 5, bytes: [1, 2, 3])]),
            (0x10, [0, 0, 5], [.init(label: "t", destination: 0x2000, mode: 3, bytes: [])]),
            (0x10, [0, 0, 5], [.init(label: "t", destination: 0x2000, mode: 2, bytes: [1, 2, 3])]),
            (0x10, [0, 0, 5], [.init(label: "t", destination: 0x1DFF, mode: 2, bytes: [1, 2])]),
            (0x10, [0, 0, 5], [.init(label: "t", destination: 0xFFFE, mode: 3, bytes: [1, 2, 3])]),
            (0x10, [0, 0, 5], [one, .init(label: "u", destination: 0x2002, mode: 2, bytes: [1, 2])]),
        ]
        for (index, (command, arguments, transfers)) in plans.enumerated() {
            XCTAssertThrowsError(try CTSPCTransfer.Plan(song: 0, command: command, arguments: arguments, transfers: transfers),
                                 "case \(index)")
        }
        // Boundaries themselves are accepted.
        XCTAssertNoThrow(try CTSPCTransfer.Plan(song: 0, command: 0x15, arguments: [0, 0, 5], transfers: [
            .init(label: "low", destination: 0x1E00, mode: 2, bytes: [1, 2]),
            .init(label: "high", destination: 0xFFFD, mode: 3, bytes: [1, 2, 3])]))
    }

    // MARK: Sender transcription on synthetic tables (no ROM)

    /// A 4 MiB image with every byte position-dependent and hand-placed bank
    /// $C7 tables: song 0 has no samples and a fast-path song whose over-send
    /// wraps inside its bank; song 1 is on Audio_SongBit2List, has a sample
    /// crossing a bank, one whose length word straddles banks, and a song
    /// read through the bank-crossing copy.
    private static func syntheticROM() -> [UInt8] {
        var rom = (0..<4_194_304).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 8 &+ $0 >> 16) }
        func put(_ pc: Int, _ bytes: [UInt8]) { rom.replaceSubrange(pc..<(pc + bytes.count), with: bytes) }
        put(0x070AE9, [2])                               // Audio_SongCount
        put(0x070AD8, [0x01, 0xFF])                      // Audio_SongBit2List: song 1
        put(0x07241D, [0x05, 0xFF, 0x37, 0x9C])          // AudioRom_SongEcho
        put(0x070E11, [0, 0])                            // song 0: no samples
        put(0x070E31, [3, 0, 5, 0, 0, 0])                // song 1: samples 3, 5
        put(0x0740B4, [0x01, 0x02])                      // boot block 2: $0201 bytes
        put(0x070AF0, [0xF0, 0xFF, 0xC9])                // sample 3 at $C9:FFF0
        put(0x09FFF0, [27, 0])
        put(0x070AF6, [0xFF, 0xFF, 0xCA])                // sample 5 at $CA:FFFF
        put(0x0AFFFF, [9, 0])
        put(0x070BA8, [9, 0]); put(0x070BAC, [3, 0])     // Audio_SampleLoop
        put(0x070C24, [0xA3, 0x13]); put(0x070C28, [0xA5, 0x15]); put(0x080C1E, [0xAE, 0x1E])
        put(0x070CA0, [0xB3, 0x23]); put(0x070CA4, [0xB5, 0x25]); put(0x080C9A, [0xBE, 0x2E])
        put(0x070D18, [0xEE, 0xFF, 0xCB, 0xF0, 0xFF, 0xCC])   // Audio_SongTable
        put(0x0BFFEE, [15, 0])
        put(0x0CFFF0, [16, 0])
        return rom
    }

    func testPlanTranscribesTheSenderOnSyntheticTables() throws {
        let rom = Self.syntheticROM()
        func bytes(_ pc: Int, _ count: Int) -> [UInt8] { Array(rom[pc..<(pc + count)]) }
        let plan = try CTSPCTransfer.Plan(rom: rom, song: 1)
        XCTAssertEqual(plan.command, 0x14, "Audio_AdjustSongCmd sets bit 2 for a listed song")
        XCTAssertEqual(plan.arguments, [1, 0x9C, 7])
        XCTAssertEqual(plan.samples, [
            .init(number: 3, slot: 0, destination: 0x4901, length: 27, loopOffset: 9, sourcePC: 0x09FFF2, crossesBank: true),
            .init(number: 5, slot: 1, destination: 0x491C, length: 9, loopOffset: 3, sourcePC: 0x0B0001, crossesBank: false),
        ])
        XCTAssertEqual(plan.transfers.map(\.label),
                       ["sample 3", "sample 5", "directory", "parameters A", "parameters B", "song", "song extra"])
        XCTAssertEqual(plan.transfers.map(\.destination), [0x4901, 0x491C, 0x1E80, 0x1F40, 0x1FC0, 0x2000, 0xF120])
        XCTAssertEqual(plan.transfers.map(\.mode), [3, 3, 2, 2, 2, 3, 3])
        XCTAssertEqual(plan.transfers[0].bytes, bytes(0x09FFF2, 27))
        XCTAssertEqual(plan.transfers[1].bytes, bytes(0x0B0001, 9))
        XCTAssertEqual(plan.transfers[2].bytes, [0x01, 0x49, 0x0A, 0x49, 0x1C, 0x49, 0x1F, 0x49] + [UInt8](repeating: 0, count: 56))
        XCTAssertEqual(plan.transfers[3].bytes, [0xA3, 0x13, 0xA5, 0x15] + Array([[UInt8]](repeating: [0xAE, 0x1E], count: 14).joined()))
        XCTAssertEqual(plan.transfers[4].bytes, [0xB3, 0x23, 0xB5, 0x25] + Array([[UInt8]](repeating: [0xBE, 0x2E], count: 14).joined()))
        // 16 bytes: 16 / 3 + 1 = 6 steps, read on into bank $CD.
        XCTAssertEqual(plan.transfers[5].bytes, bytes(0x0CFFF2, 18))
        XCTAssertEqual(plan.songData, bytes(0x0CFFF2, 16))
        XCTAssertEqual(plan.transfers[6].bytes, bytes(0x071871 + 36, 36))

        let first = try CTSPCTransfer.Plan(rom: rom, song: 0)
        XCTAssertEqual(first.command, 0x10)
        XCTAssertEqual(first.arguments, [0, 0xFF, 5])
        XCTAssertEqual(first.samples, [])
        XCTAssertEqual(first.transfers.map(\.label), ["directory", "parameters A", "parameters B", "song", "song extra"])
        XCTAssertEqual(first.transfers[0].bytes, [UInt8](repeating: 0, count: 64))
        XCTAssertEqual(first.transfers[1].bytes, Array([[UInt8]](repeating: [0xAE, 0x1E], count: 16).joined()))
        // 15 bytes from $CB:FFF0 take the fast copy (Y + length <= $FFFF);
        // its 6 steps wrap Y to $CB:0000 instead of moving to bank $CC.
        XCTAssertEqual(first.transfers[3].bytes, bytes(0x0BFFF0, 16) + bytes(0x0B0000, 2))
        XCTAssertEqual(first.transfers[4].bytes, bytes(0x071871, 36))
    }

    func testPlanRefusesTablesTheSenderCannotSend() {
        let rom = Self.syntheticROM()
        XCTAssertNoThrow(try CTSPCTransfer.Plan(rom: rom, song: 1), "each case below changes one thing")
        func refused(_ edit: (inout [UInt8]) -> Void, song: Int = 1, file: StaticString = #filePath, line: UInt = #line) {
            var changed = rom
            edit(&changed)
            XCTAssertThrowsError(try CTSPCTransfer.Plan(rom: changed, song: song), file: file, line: line) {
                guard case .invalidInput? = $0 as? Failure else { return XCTFail("unexpected \($0)", file: file, line: line) }
            }
        }
        refused({ _ in }, song: 2)
        refused({ $0.removeLast() })
        refused({ $0[0x070E33] = 63 })                                    // sample 63
        refused({ $0[0x09FFF0] = 26 })                                    // not a multiple of 3
        refused({ $0[0x09FFF0] = 0 })                                     // empty sample
        refused({ $0[0x070AF2] = 0x40 })                                  // pointer outside $C0-$FF
    }

    // MARK: Real ROM lane (local ROM; never bundled)

    private func rom() throws -> [UInt8] {
        guard let data = try? Repo.romData() else { throw XCTSkip("local ROM not present") }
        return [UInt8](data)
    }

    func testROMPlanMatchesTheBankC7Tables() throws {
        let rom = try rom()
        // Independent transcription: Audio_SampleTable entry 12 = $C7F540 and
        // Audio_SongTable entry $18 = $CAF5FD (bankC7.asm:2047, 2104).
        let four = try CTSPCTransfer.Plan(rom: rom, song: 0x04)
        XCTAssertEqual(four.samples.map(\.number), Array((0..<16).map { Int(rom[0x070E11 + 32 * 4 + 2 * $0]) }.prefix { $0 != 0 }))
        XCTAssertEqual(four.samples.first?.destination, 0x4901, "slot 0 follows the $0201-byte block at $4700")
        let twelve = try XCTUnwrap(four.samples.first { $0.number == 12 })
        XCTAssertEqual(twelve.sourcePC, 0x07F542)
        XCTAssertTrue(twelve.crossesBank)
        XCTAssertEqual(four.transfers.first { $0.label == "sample 12" }?.bytes, Array(rom[0x07F542..<(0x07F542 + twelve.length)]))
        for (sample, next) in zip(four.samples, four.samples.dropFirst()) {
            XCTAssertEqual(Int(next.destination), Int(sample.destination) + sample.length)
        }
        let eighteen = try CTSPCTransfer.Plan(rom: rom, song: 0x18)
        let length = Int(rom[0x0AF5FD]) | Int(rom[0x0AF5FE]) << 8
        XCTAssertEqual(eighteen.songData, Array(rom[0x0AF5FF..<(0x0AF5FF + length)]))
        XCTAssertEqual(eighteen.transfers.first { $0.label == "song" }?.bytes,
                       Array(rom[0x0AF5FF..<(0x0AF5FF + 3 * (length / 3 + 1))]))
        XCTAssertThrowsError(try CTSPCTransfer.Plan(rom: rom, song: 0x53))
    }

    private func assertLoaded(_ result: CTSPCTransfer.Diagnostic, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.passed, result.checks.filter { !$0.passed }.map(\.name).joined(separator: ", "), file: file, line: line)
        XCTAssertEqual(result.checks.count, 9, file: file, line: line)
        XCTAssertTrue(result.transfer.payloadVerified, file: file, line: line)
        XCTAssertEqual(result.transfer.acknowledgementCount, result.transfer.stepCount + result.transfer.transfers.count + 2,
                       file: file, line: line)
        XCTAssertLessThan(result.transfer.totalCycles, 4_000_000, file: file, line: line)
    }

    /// No samples ($00); a bank-crossing sample and an echo change ($04);
    /// bank-crossing song data ($18); a song reaching the $2F00 block ($3F).
    func testRealDriverLoadsSongsAfterDirectBoot() throws {
        let rom = try rom()
        for song in [0x00, 0x04, 0x18, 0x3F] {
            let result = try CTSPCTransfer.loadSong(rom: rom, song: song)
            assertLoaded(result)
            let plan = try CTSPCTransfer.Plan(rom: rom, song: song)
            XCTAssertEqual(result.transfer.transfers.map(\.sha256), plan.transfers.map { CTEventPack.sha256($0.bytes) })
            XCTAssertEqual(result.transfer.transfers.first?.headerSequence, 0x11)
            XCTAssertTrue(result.mode.hasPrefix("direct-ARAM-load"))
            XCTAssertNil(result.upload)
        }
        let long = try CTSPCTransfer.Plan(rom: rom, song: 0x3F)
        XCTAssertGreaterThanOrEqual(long.songData.count, CTSongISA.songRoom)
    }

    func testRealDriverNeedsTheStepDelayAndRefusesBeforeExecution() throws {
        let rom = try rom()
        // Song $00 sends triples (song, extra). Without a delay the driver
        // stores the next step's CPUIO2/3; the ARAM check names the byte.
        let plan = try CTSPCTransfer.Plan(rom: rom, song: 0)
        assertFailure(try CTSPCTransfer.loadSong(rom: rom, song: 0, limits: .init(stepDelay: 0))) {
            guard case .integrity(let transfer, let address, _, _) = $0 else { return false }
            let target = plan.transfers[transfer]
            return target.mode == CTSPCTransfer.modeTriples && (Int(address) - Int(target.destination)) % 3 != 0
        }
        // The smallest safe delay lies between 1 and the default.
        let safe = try XCTUnwrap((0...16).first { (try? CTSPCTransfer.loadSong(rom: rom, song: 0, limits: .init(stepDelay: $0))) != nil })
        XCTAssertGreaterThan(safe, 0)
        XCTAssertLessThanOrEqual(safe, CTSPCTransfer.Limits().stepDelay)

        var changed = rom
        changed[0x724C5] ^= 1
        XCTAssertThrowsError(try CTSPCTransfer.loadSong(rom: changed, song: 0))
        XCTAssertThrowsError(try CTSPCTransfer.loadSong(rom: rom, song: 0x53))
        XCTAssertThrowsError(try CTSPCTransfer.loadSong(rom: rom, song: 0, limits: .init(totalCycles: 0)))
        XCTAssertThrowsError(try CTSPCTransfer.loadSong(rom: rom, song: 0x18, limits: .init(totalCycles: 100_000))) {
            guard case .budgetExceeded? = $0 as? Failure else { return XCTFail("unexpected \($0)") }
        }
    }

    // MARK: Real IPL lane (local IPL via CHRONOFORGE_IPL_ROM; never bundled)

    func testRealIPLBootThenSongLoadMatchesDirectBoot() throws {
        guard let path = ProcessInfo.processInfo.environment["CHRONOFORGE_IPL_ROM"], !path.isEmpty else {
            throw XCTSkip("UNVERIFIED real-IPL lane: set CHRONOFORGE_IPL_ROM to a local 64-byte S-SMP IPL image")
        }
        let ipl = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        guard ipl.count == 64, CTEventPack.sha256(ipl) == Self.iplSHA256 else {
            return XCTFail("CHRONOFORGE_IPL_ROM is not the expected 64-byte S-SMP IPL image")
        }
        let rom = try rom()
        let viaIPL = try CTSPCTransfer.loadSong(rom: rom, song: 0x18, iplROM: ipl)
        let direct = try CTSPCTransfer.loadSong(rom: rom, song: 0x18)
        assertLoaded(viaIPL)
        XCTAssertTrue(viaIPL.mode.hasPrefix("IPL-upload"))
        XCTAssertEqual(viaIPL.iplSHA256, Self.iplSHA256)
        XCTAssertEqual(viaIPL.upload?.bytesTransferred, 13_884)
        XCTAssertGreaterThan(viaIPL.idleCycles, viaIPL.driverBootCycles, "waits out the IPL start echo")
        // Same bytes, steps and sequences; only timer phase-dependent clocks differ.
        func shape(_ report: CTSPCTransfer.Report) -> [String] {
            report.transfers.map { "\($0.label) \($0.destination) \($0.mode) \($0.headerSequence) \($0.steps) \($0.sha256)" }
        }
        XCTAssertEqual(shape(viaIPL.transfer), shape(direct.transfer))
        XCTAssertEqual(viaIPL.transfer.acknowledgementCount, direct.transfer.acknowledgementCount)
        XCTAssertEqual(viaIPL.samples, direct.samples)
    }
}
