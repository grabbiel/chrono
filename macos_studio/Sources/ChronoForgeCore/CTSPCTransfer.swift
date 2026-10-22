import Foundation

/// Bounded host-side model of Chrono Trigger's first song load after a driver
/// boot: the song command and the sample, directory, parameter, song and extra
/// transfers that follow it, stored by the original driver.
/// 65816 sender: ChronoRET af992bdd99603332ac91b32c621dfbfec3ae816a,
/// asm/bankC7/bankC7.asm (Audio_CmdLoadSong ... Audio_SendSongData,
/// Audio_UploadSample, Audio_StartSong, Audio_SendSeq; $C7:01A1...$C7:0A97).
/// Driver side: asm/spc700/driver.asm (Spc_CmdSongCheck, Spc_StartSong,
/// Spc_XferReceive/Spc_XferHeader, Spc_XferWords, Spc_XferTriples).
/// This drives host ports while executing the SPC700, not the 65816 sender.
/// Host writes take no SMP clocks and happen between whole SMP instructions.
public enum CTSPCTransfer {
    // Bank $C7 tables as file offsets / long addresses (bankC7.asm:2019-2100,
    // constants_engine.inc:241-253); CTSongISA holds the per-song ones.
    static let songBit2ListPC = 0x070AD8        // Audio_SongBit2List
    static let sampleTablePC = 0x070AEA         // Audio_SampleTable: 62 long pointers
    static let sampleLoopPC = 0x070BA4          // Audio_SampleLoop: a word per sample
    static let paramALong = 0xC70C20            // Audio_SampleParamA
    static let paramBLong = 0xC70C9C            // Audio_SampleParamB
    static let block4700PC = 0x0740B4           // !AudioRom_Block4700: boot block 2's length word
    static let extraLong = 0xC71871             // !AudioRom_SongExtra: 36 bytes per song
    // ARAM destinations (constants_engine.inc:225-237).
    static let songDirectory: UInt16 = 0x1E80, songParamA: UInt16 = 0x1F40
    static let songParamB: UInt16 = 0x1FC0, songExtra: UInt16 = 0xF120
    /// Transfer modes (!Audio_XferWords / !Audio_XferTriples; Spc_XferModeTable).
    public static let modeWords: UInt8 = 2, modeTriples: UInt8 = 3
    /// !Audio_SeqHeader = !SpcCmd_XferEnd: the header value after a transfer and
    /// the APUIO1/APUIO0 pair that ends the load. Sequence values count mod $80.
    static let sequenceEnd: UInt8 = 0xE0, sequenceMask: UInt8 = 0x7F

    public struct Sample: Codable, Equatable, Sendable {
        /// Audio_SampleTable entry + 1 (1...62), and the slot the load puts it in.
        public let number, slot: Int
        public let destination: UInt16
        public let length, loopOffset: Int
        /// File offset of the first BRR byte. `crossesBank` selects the
        /// sender's bank-stepping copy; the bytes are contiguous either way.
        public let sourcePC: Int
        public let crossesBank: Bool
    }

    public struct Transfer: Equatable, Sendable {
        public let label: String
        public let destination: UInt16
        public let mode: UInt8
        /// Whole steps: 2 (words) or 3 (triples) bytes, stored in order.
        public let bytes: [UInt8]
        public var width: Int { mode == modeWords ? 2 : 3 }
        public var steps: Int { bytes.count / width }
    }

    /// What CT's sender transmits for a song's first load after a driver boot.
    public struct Plan: Equatable, Sendable {
        public let song: Int
        /// APUIO0, then APUIO1-3: the song, its echo word's byte 1, its echo delay.
        public let command: UInt8
        public let arguments: [UInt8]
        public let samples: [Sample]
        public let transfers: [Transfer]
        /// The song's length-word payload (header and data), without the over-send.
        public let songData: [UInt8]

        init(song: Int, command: UInt8, arguments: [UInt8], samples: [Sample] = [],
             transfers: [Transfer], songData: [UInt8] = []) throws {
            self.song = song; self.command = command; self.arguments = arguments
            self.samples = samples; self.transfers = transfers; self.songData = songData
            try validate()
        }

        /// Song commands the driver loads ($10/$11/$14/$15, Spc_CmdTable10).
        /// Each region lies in $1E00...$FFFF, below which the driver stores
        /// nothing (Spc_XferHeader .refuse), and regions do not overlap, so
        /// ARAM can be compared with every payload once the load has ended.
        func validate() throws {
            guard [0x10, 0x11, 0x14, 0x15].contains(command), arguments.count == 3 else {
                throw Failure.invalidInput("a song load takes command $10, $11, $14 or $15 and three arguments")
            }
            guard (1...64).contains(transfers.count) else { throw Failure.invalidInput("supply 1...64 transfers") }
            var occupied = IndexSet()
            for transfer in transfers {
                guard [modeWords, modeTriples].contains(transfer.mode), !transfer.bytes.isEmpty,
                      transfer.bytes.count % transfer.width == 0 else {
                    throw Failure.invalidInput("\(transfer.label): mode 2 or 3 with whole, nonempty steps")
                }
                let range = Int(transfer.destination)..<(Int(transfer.destination) + transfer.bytes.count)
                guard range.lowerBound >= 0x1E00, range.upperBound <= 0x10000 else {
                    throw Failure.invalidInput("\(transfer.label): transfers must fit ARAM $1E00...$FFFF")
                }
                guard !occupied.intersects(integersIn: range) else {
                    throw Failure.invalidInput("\(transfer.label): transfers must not overlap")
                }
                occupied.insert(integersIn: range)
            }
        }

        /// Transcribe the sender for song `song` of a HiROM image laid out like
        /// the US 1.0 ROM. The state is the one Audio_Boot leaves: every sample
        /// slot free, $2F00 block current (Audio_BlockDirty 0), so the load
        /// uploads the song's whole sample list in order and no $2F00 block.
        public init(rom: [UInt8], song: Int) throws {
            guard rom.count == 4_194_304 else { throw Failure.invalidInput("expected a 4 MiB HiROM image") }
            let songCount = Int(rom[CTSongISA.songCountPC])
            // Audio_CmdLoadSong ignores a song number not below Audio_SongCount.
            guard (0..<songCount).contains(song) else {
                throw Failure.invalidInput("song must be 0...\(songCount - 1) (Audio_SongCount)")
            }
            func word(_ pc: Int) -> Int { Int(rom[pc]) | Int(rom[pc + 1]) << 8 }
            func pointer(_ pc: Int) -> Int { word(pc) | Int(rom[pc + 2]) << 16 }

            // Audio_AdjustSongCmd (bankC7.asm:1394-1414): bit 2 for songs on the list.
            var command: UInt8 = 0x10
            var listPC = songBit2ListPC
            while rom[listPC] & 0x80 == 0 {
                if Int(rom[listPC]) == song { command |= 0x04; break }
                listPC += 1
                guard listPC < songBit2ListPC + 0x10000 else { throw Failure.invalidInput("Audio_SongBit2List has no end marker") }
            }
            // Audio_StartSong (bankC7.asm:1951-1975): AudioRom_SongEcho word of song & $7F.
            let echo = CTSongISA.echoPC + 2 * (song & 0x7F)
            let arguments = [UInt8(song), rom[echo + 1], rom[echo] & 0x0F]

            // Audio_CmdLoadSong .copy_list (bankC7.asm:504-526): up to 16 words, 0-ended.
            var list: [Int] = []
            for k in 0..<16 {
                let number = word(CTSongISA.samplesPC + 32 * song + 2 * k)
                if number == 0 { break }
                guard (1...CTSongISA.sampleMax).contains(number) else {
                    throw Failure.invalidInput("song \(song) lists sample \(number); the sample table has 1...\(CTSongISA.sampleMax)")
                }
                list.append(number)
            }

            // Audio_Boot: slot 0 starts right after boot block 2 (bankC7.asm:289-294).
            var address = (0x4700 + word(block4700PC)) & 0xFFFF
            var samples: [Sample] = [], transfers: [Transfer] = []
            for (slot, number) in list.enumerated() {
                // Audio_UploadSample (bankC7.asm:1247-1359): length word, then
                // length / 3 triples; the BNE loop needs a nonzero multiple of 3.
                var reader = Reader(rom: rom, long: pointer(sampleTablePC + 3 * (number - 1)))
                let length = try reader.length()
                guard length > 0, length % 3 == 0 else {
                    throw Failure.invalidInput("sample \(number) length \(length) is not a nonzero multiple of 3")
                }
                let crossesBank = reader.y + length > 0xFFFF, sourcePC = reader.pc
                let bytes = try reader.bytes(length, stepBank: crossesBank)
                samples.append(.init(number: number, slot: slot, destination: UInt16(address), length: length,
                                     loopOffset: word(sampleLoopPC + 2 * (number - 1)), sourcePC: sourcePC,
                                     crossesBank: crossesBank))
                transfers.append(.init(label: "sample \(number)", destination: UInt16(address), mode: modeTriples, bytes: bytes))
                address = (address + length) & 0xFFFF
            }

            // Audio_SendSampleDir (bankC7.asm:790-833): per listed sample, the
            // start and loop start of the first slot holding it. Entries past
            // the list keep what Audio_DirBuf held; this model sends zero.
            var directory = [UInt8](repeating: 0, count: 64)
            for (k, number) in list.enumerated() {
                let sample = samples[list.firstIndex(of: number)!]
                let start = Int(sample.destination), loop = (start + sample.loopOffset) & 0xFFFF
                directory.replaceSubrange((4 * k)..<(4 * k + 4),
                                          with: [UInt8(start & 0xFF), UInt8(start >> 8), UInt8(loop & 0xFF), UInt8(loop >> 8)])
            }
            // The parameter words index the tables by (sample - 1) x 2 in 16 bits,
            // so an unused (0) entry reads the table + $FFFE, in bank $C8
            // (bankC7.asm:766-774, 884-901, 922-939).
            func parameters(_ table: Int) throws -> [UInt8] {
                try (0..<16).flatMap { k -> [UInt8] in
                    var reader = Reader(rom: rom, long: table + ((2 * ((k < list.count ? list[k] : 0) - 1)) & 0xFFFF))
                    return try reader.bytes(2, stepBank: true)
                }
            }
            transfers.append(.init(label: "directory", destination: songDirectory, mode: modeWords, bytes: directory))
            transfers.append(.init(label: "parameters A", destination: songParamA, mode: modeWords, bytes: try parameters(paramALong)))
            transfers.append(.init(label: "parameters B", destination: songParamB, mode: modeWords, bytes: try parameters(paramBLong)))

            // Audio_SendSongData (bankC7.asm:1023-1108): X counts the length down
            // by 3 while it stays >= 0 (BPL, 16-bit), so length / 3 + 1 steps
            // send 1-3 bytes past the data.
            var reader = Reader(rom: rom, long: pointer(CTSongISA.songTablePC + 3 * song))
            let songLength = try reader.length()
            var x = songLength, steps = 0
            repeat { steps += 1; x = (x - 3) & 0xFFFF } while x & 0x8000 == 0
            guard 3 * steps >= songLength else { throw Failure.invalidInput("song \(song) is too long for the sender's loop") }
            let songBytes = try reader.bytes(3 * steps, stepBank: reader.y + songLength > 0xFFFF)
            transfers.append(.init(label: "song", destination: UInt16(CTSongISA.songAram), mode: modeTriples, bytes: songBytes))
            // bankC7.asm:1112-1164: 12 triples from AudioRom_SongExtra + 36 x song.
            var extra = Reader(rom: rom, long: extraLong + 36 * song)
            transfers.append(.init(label: "song extra", destination: songExtra, mode: modeTriples,
                                   bytes: try extra.bytes(36, stepBank: true)))
            try self.init(song: song, command: command, arguments: arguments, samples: samples,
                          transfers: transfers, songData: Array(songBytes.prefix(songLength)))
        }
    }

    /// ROM bytes as bank $C7's `[Audio_Ptr],Y` loops read them (HiROM banks
    /// $C0-$FF): Y wraps inside the pointer's bank, and only the bank-crossing
    /// copies (and 24-bit long reads) move the bank on.
    private struct Reader {
        let rom: [UInt8]
        var bank, y: Int
        init(rom: [UInt8], long: Int) { self.rom = rom; bank = long >> 16; y = long & 0xFFFF }
        var pc: Int { (bank - 0xC0) << 16 | y }

        mutating func byte(stepBank: Bool) throws -> UInt8 {
            guard (0xC0...0xFF).contains(bank) else {
                throw Failure.invalidInput(String(format: "ROM read at $%02X:%04X is outside banks $C0-$FF", bank, y))
            }
            let value = rom[pc]
            y = (y + 1) & 0xFFFF
            if y == 0 && stepBank { bank += 1 }
            return value
        }

        mutating func bytes(_ count: Int, stepBank: Bool) throws -> [UInt8] {
            try (0..<count).map { _ in try byte(stepBank: stepBank) }
        }

        /// A length word, read with the senders' INY / BNE / INC bank pairs.
        mutating func length() throws -> Int {
            let low = Int(try byte(stepBank: true))
            return low | Int(try byte(stepBank: true)) << 8
        }
    }

    public struct Limits: Equatable, Sendable {
        public let totalCycles, waitCycles, stepDelay: Int
        /// Budgets are checked at instruction boundaries; a failed load can
        /// exceed one by the last instruction but cannot succeed beyond it.
        ///
        /// `stepDelay`: SMP clocks the host lets pass after each acknowledgement
        /// before it writes the next step's ports (all of them, APUIO0 last).
        /// Spc_XferTriples echoes a step after reading CPUIO1 but before reading
        /// CPUIO2/3 (driver.asm:2956-2965); CPUIO3 is read 14 clocks after the
        /// echo instruction (mov dp 3 + mov !abs+y 6 + inc 2 + mov dp 3). CT's
        /// fastest loop, Audio_SendSongData .extra_loop (bankC7.asm:1150-1164),
        /// takes 58 65816 cycles from reading the echo to storing APUIO3: at
        /// least 58 x 6 master clocks, 16.6 SMP clocks. Writing everything at
        /// that lower bound is never later than CT's sender.
        /// Defaults: every US 1.0 song loads within 810,539 clocks, and the
        /// longest single wait (echo change before the first report) is 293,933.
        public init(totalCycles: Int = 4_000_000, waitCycles: Int = 1_000_000, stepDelay: Int = 16) {
            self.totalCycles = totalCycles; self.waitCycles = waitCycles; self.stepDelay = stepDelay
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidInput(String)
        case notIdle(UInt8)
        case budgetExceeded(phase: String, cycles: Int, pc: UInt16)
        case stopped(phase: String, pc: UInt16)
        case busFault(SSMPBus.Fault)
        case songAlreadyCurrent(reply: UInt8)
        case refused(transfer: Int, mode: UInt8, reply: UInt8)
        case integrity(transfer: Int, address: UInt16, expected: UInt8, actual: UInt8)

        public var description: String {
            switch self {
            case .invalidInput(let message): return "song load: \(message)"
            case .notIdle(let value):
                return "song load: CPUIO0 is $\(String(value, radix: 16)), not the driver's idle report 0"
            case .budgetExceeded(let phase, let cycles, let pc):
                return "song load \(phase) exceeded cycle budget at \(cycles) cycles (PC $\(String(pc, radix: 16)))"
            case .stopped(let phase, let pc):
                return "song load CPU stopped during \(phase) (PC $\(String(pc, radix: 16)))"
            case .busFault(let fault): return "song load bus fault: \(fault)"
            case .songAlreadyCurrent(let reply):
                return "song load: driver answered $\(String(reply, radix: 16)) (bit 7: song already current, nothing to send)"
            case .refused(let transfer, let mode, let reply):
                return "song load transfer \(transfer): header mode \(mode) answered with \(reply)"
            case .integrity(let transfer, let address, let expected, let actual):
                return "song load transfer \(transfer) differs at $\(String(address, radix: 16)): expected \(expected), got \(actual)"
            }
        }
    }

    public struct TransferReport: Codable, Equatable, Sendable {
        public let label: String
        public let destination: UInt16
        public let mode, headerSequence: UInt8
        public let steps, byteCount: Int
        public let sha256: String
        /// From the header write to the last step's acknowledgement.
        public let cycles: Int
    }

    public struct Report: Codable, Equatable, Sendable {
        public let command: UInt8
        public let arguments: [UInt8]
        /// CPUIO1 at the command's echo (Spc_CmdSongCheck: the song, or $FF).
        public let songReply: UInt8
        public let transfers: [TransferReport]
        /// Data bytes and steps sent (the song's over-send included); command,
        /// headers, steps and the end step each take one acknowledgement.
        public let bytesTransferred, stepCount, acknowledgementCount: Int
        /// Command write to the end acknowledgement, where ARAM is verified;
        /// then to the driver's first idle port report; and both.
        public let loadCycles, startCycles, totalCycles: Int
        /// CPUIO1 at the end acknowledgement (Spc_XferHeader .end writes 0).
        public let endReply: UInt8
        /// CPUIO3 at the first port report after the load: voices in use.
        public let voicesReport: UInt8
        public let payloadVerified: Bool
    }

    static func validate(_ limits: Limits) throws {
        guard (1...200_000_000).contains(limits.totalCycles), (1...100_000_000).contains(limits.waitCycles),
              (0...10_000).contains(limits.stepDelay) else {
            throw Failure.invalidInput("budgets must be 1...200000000 / 1...100000000 cycles, step delay 0...10000")
        }
    }

    // Same transport boundary as SPCIPLHost: protocol tests run against a
    // Swift receiver model instead of firmware.
    static func load(on machine: any SPCIPLTransport, plan: Plan, limits: Limits) throws -> Report {
        try validate(limits)
        try plan.validate()
        guard machine.hostRead(port: 0) == 0 else { throw Failure.notIdle(machine.hostRead(port: 0)) }
        let initialCycles = machine.cycles
        var lastAcknowledgement = initialCycles, acknowledgements = 0
        func wait(_ phase: String, until predicate: () -> Bool) throws {
            let start = machine.cycles
            while true {
                if let fault = machine.fault { throw Failure.busFault(fault) }
                if machine.stopped { throw Failure.stopped(phase: phase, pc: machine.pc) }
                if machine.cycles - initialCycles > limits.totalCycles || machine.cycles - start > limits.waitCycles {
                    throw Failure.budgetExceeded(phase: phase, cycles: machine.cycles - initialCycles, pc: machine.pc)
                }
                if predicate() { return }
                guard machine.cycles - initialCycles < limits.totalCycles,
                      machine.cycles - start < limits.waitCycles else {
                    throw Failure.budgetExceeded(phase: phase, cycles: machine.cycles - initialCycles, pc: machine.pc)
                }
                machine.step()
            }
        }
        // One handshake (Audio_SendSeq): data ports, then APUIO0, then its echo.
        func send(_ phase: String, _ ports: [(Int, UInt8)], sequence: UInt8) throws {
            try wait(phase, until: { machine.cycles - lastAcknowledgement >= limits.stepDelay })
            for (port, value) in ports { machine.hostWrite(port: port, value: value) }
            machine.hostWrite(port: 0, value: sequence)
            try wait(phase, until: { machine.hostRead(port: 0) == sequence })
            lastAcknowledgement = machine.cycles
            acknowledgements += 1
        }

        // Audio_StartSong: APUIO3/2/1 = Arg2/Arg1/Arg0, APUIO0 = the command;
        // after the echo, APUIO1 bit 7 set means nothing more is sent.
        try send("song command", [(3, plan.arguments[2]), (2, plan.arguments[1]), (1, plan.arguments[0])],
                 sequence: plan.command)
        let songReply = machine.hostRead(port: 1)
        guard songReply & 0x80 == 0 else { throw Failure.songAlreadyCurrent(reply: songReply) }

        // Each transfer: a header step (address in APUIO2/3, mode in APUIO1),
        // accepted when APUIO1 echoes the mode, then one step per 2 or 3 bytes.
        // The first header continues Audio_StartSong's sequence (command + 1),
        // which Spc_XferReceive waits for; later ones use !Audio_SeqHeader.
        var sequence = (plan.command &+ 1) & sequenceMask
        var reports: [TransferReport] = []
        for (index, transfer) in plan.transfers.enumerated() {
            let start = machine.cycles, header = sequence
            try send("transfer \(index) header", [(2, UInt8(transfer.destination & 0xFF)), (3, UInt8(transfer.destination >> 8)),
                                                  (1, transfer.mode)], sequence: header)
            let reply = machine.hostRead(port: 1)
            guard reply == transfer.mode else { throw Failure.refused(transfer: index, mode: transfer.mode, reply: reply) }
            for step in 0..<transfer.steps {
                sequence = (sequence &+ 1) & sequenceMask
                let bytes = transfer.bytes[(step * transfer.width)..<((step + 1) * transfer.width)]
                try send("transfer \(index) step \(step)", bytes.enumerated().map { ($0.offset + 1, $0.element) },
                         sequence: sequence)
            }
            sequence = sequenceEnd
            reports.append(.init(label: transfer.label, destination: transfer.destination, mode: transfer.mode,
                                 headerSequence: header, steps: transfer.steps, byteCount: transfer.bytes.count,
                                 sha256: CTEventPack.sha256(transfer.bytes), cycles: machine.cycles - start))
        }
        // Audio_SendSongData's end: APUIO1 = APUIO0 = $E0 (bankC7.asm:1165-1174).
        try send("end", [(1, sequenceEnd)], sequence: sequenceEnd)
        let endReply = machine.hostRead(port: 1)
        let loadCycles = machine.cycles - initialCycles

        // Verification point: each mode handler finishes its stores before it
        // returns to Spc_XferHeader, and the driver echoes the end only from
        // there (driver.asm:2874-2923), so every payload is in ARAM now and
        // no song code has run yet.
        let ram = machine.ram
        for (index, transfer) in plan.transfers.enumerated() {
            for (offset, expected) in transfer.bytes.enumerated() {
                let address = Int(transfer.destination) + offset
                guard ram[address] == expected else {
                    throw Failure.integrity(transfer: index, address: UInt16(address), expected: expected, actual: ram[address])
                }
            }
        }
        // Spc_StartSong then starts the song and returns to Spc_MainLoop, whose
        // port report writes CPUIO0 = 0 and the voices in use to CPUIO3.
        try wait("first port report", until: { machine.hostRead(port: 0) == 0 })
        return .init(command: plan.command, arguments: plan.arguments, songReply: songReply, transfers: reports,
                     bytesTransferred: plan.transfers.reduce(0) { $0 + $1.bytes.count },
                     stepCount: plan.transfers.reduce(0) { $0 + $1.steps }, acknowledgementCount: acknowledgements,
                     loadCycles: loadCycles, startCycles: machine.cycles - initialCycles - loadCycles,
                     totalCycles: machine.cycles - initialCycles, endReply: endReply,
                     voicesReport: machine.hostRead(port: 3), payloadVerified: true)
    }

    public struct Diagnostic: Encodable, Sendable {
        public let format = "ct-spc-song-load/1"
        public let mode: String
        public let romSHA256: String
        /// Present only after an IPL boot; nil fields are omitted from JSON.
        public let iplSHA256: String?
        public let upload: SPCIPLHost.Report?
        public let song: Int
        public let samples: [Sample]
        /// Post-entry clocks to the first main-loop entry and to the idle port
        /// report the load starts from; the load's own clocks are in `transfer`.
        public let driverBootCycles, idleCycles: Int
        public let transfer: Report
        public let dspWrites: Int
        public let checks: [CTSPCDriver.Check]
        public let limitations: [String]
        public let passed: Bool
    }

    /// Boot the driver from the verified US 1.0 ROM (copied, or uploaded through
    /// `iplROM`), wait for its idle port report, send `song` as CT's first load
    /// after boot does, then check the driver's song start through its RAM,
    /// DSP latch and ports. Expectations below are transcribed from
    /// driver.asm and spc700.inc, independently of the host above.
    public static func loadSong(rom: [UInt8], song: Int, iplROM: [UInt8]? = nil,
                                limits: Limits = .init()) throws -> Diagnostic {
        try loadSession(rom: rom, song: song, iplROM: iplROM, limits: limits).diagnostic
    }

    /// `loadSong`, keeping the running driver for `CTSPCRender`: the session
    /// stops at the first idle port report after the load.
    static func loadSession(rom: [UInt8], song: Int, iplROM: [UInt8]?, limits: Limits) throws
        -> (session: CTSPCDriver.Session, diagnostic: Diagnostic) {
        guard rom.count == 4_194_304, CTEventPack.sha256(rom) == CTSPCDriver.cleanROMSHA256 else {
            throw CTSongError("song-load requires the verified unheadered CT USA 1.0 ROM")
        }
        return try loadSession(rom: rom, plan: try Plan(rom: rom, song: song), iplROM: iplROM, limits: limits)
    }

    /// `plan` (for example from a copy of the ROM with an edited song built in
    /// by `CTROMBuilder`) sent to the driver booted from the verified `rom`.
    static func loadSession(rom: [UInt8], plan: Plan, iplROM: [UInt8]?, limits: Limits) throws
        -> (session: CTSPCDriver.Session, diagnostic: Diagnostic) {
        guard rom.count == 4_194_304, CTEventPack.sha256(rom) == CTSPCDriver.cleanROMSHA256 else {
            throw CTSongError("song-load requires the verified unheadered CT USA 1.0 ROM")
        }
        try validate(limits)
        let song = plan.song
        let header = try CTSong(data: plan.songData)
        let session = try CTSPCDriver.boot(rom: rom, iplROM: iplROM, cycleLimit: 250_000)
        let driverBootCycles = session.postEntryCycles
        // After an IPL jump CPUIO0 holds the start echo until the first report.
        try session.run(until: { session.bus.hostRead(port: 0) == 0 }, phase: "first port report")
        let idleCycles = session.postEntryCycles
        let bus = session.bus, cpu = session.cpu, dsp = session.dsp
        let report = try load(on: SPCIPLHost.Machine(cpu: cpu, bus: bus), plan: plan, limits: limits)

        var checks: [CTSPCDriver.Check] = []
        func record(_ name: String, _ passed: Bool) { checks.append(.init(name: name, passed: passed)) }
        let ram = bus.ram, number = UInt8(song), delay = plan.arguments[2]
        // Spc_StartSong .move_track (driver.asm:2072-2093): track i of the chosen
        // set (A for $10/$14) plays unless its pointer equals the no-track word.
        let set = plan.command & 0x01 == 0 ? 0 : 8
        let tracks = (0..<8).reduce(UInt8(0)) { header.tracks[set + $1] == header.noTrack ? $0 : $0 | 1 << $1 }
        record("song command answered with the new song", report.songReply == number)
        record("end header acknowledged with CPUIO1 = 0", report.endReply == 0)
        record("ARAM matched every ROM payload at the end acknowledgement", report.payloadVerified)
        record("payloads unchanged at the first port report", plan.transfers.allSatisfy {
            Array(ram[Int($0.destination)..<(Int($0.destination) + $0.bytes.count)]) == $0.bytes
        })
        // !Spc_CurSong $80, !Spc_NewSong $BC, !Spc_SongHeaderSet $B9 ($10/$20),
        // !Spc_SongTracks $53, !Spc_EchoDelay $81 (spc700.inc).
        record("current and requested song recorded", ram[0x80] == number && ram[0xBC] == number)
        record("song tracks started from the command's header set",
               ram[0xB9] == (set == 0 ? 0x10 : 0x20) && ram[0x53] == tracks)
        // Spc_MainLoop step 3 (driver.asm:223-235): CPUIO3 = (tracks | tracks >> 4) & $0F, no effects.
        record("first port report lists the song's voices", report.voicesReport == (tracks | tracks >> 4) & 0x0F)
        // Spc_SetEchoDelay (driver.asm:3563-3595): EDL = delay, ESA = $F1 - 8 x delay.
        record("echo delay and buffer taken from the song", ram[0x81] == delay && dsp.registers[0x7D] == delay
               && dsp.registers[0x6D] == UInt8(truncatingIfNeeded: 0xF1 - 8 * Int(delay)))
        record("CPU, bus and DSP endpoint clocks agree", cpu.cycles == bus.cycles && dsp.clocks == cpu.cycles)
        let boot = session.upload == nil ? "direct-ARAM-load" : "IPL-upload"
        let diagnostic = Diagnostic(mode: "\(boot); first song load; S-DSP; no PCM recorded", romSHA256: CTSPCDriver.cleanROMSHA256,
                     iplSHA256: iplROM.map(CTEventPack.sha256), upload: session.upload, song: song, samples: plan.samples,
                     driverBootCycles: driverBootCycles, idleCycles: idleCycles, transfer: report,
                     dspWrites: dsp.registerWrites, checks: checks,
                     limitations: [
                        "Host writes ports between whole SMP instructions, \(limits.stepDelay) SMP clocks after each acknowledgement (a lower bound for CT's 65816 loops); 65816 timing, its timeouts and retries, and subcycle port races are not modeled.",
                        "Models the first load after a driver boot: every sample slot free, no $2F00 block resend, and directory entries past the song's samples sent as zero (the game sends whatever its WRAM buffer held).",
                        "The S-DSP runs (voices, envelopes, echo RAM writes) but no PCM is recorded here; music render records it. No hardware reset or snapshot restore is verified.",
                     ],
                     passed: checks.allSatisfy(\.passed))
        return (session, diagnostic)
    }
}
