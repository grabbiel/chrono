import Foundation

/// Bounded execution diagnostics for the US 1.0 CT sound driver. Boot blocks
/// are copied directly to ARAM, or uploaded through a caller-supplied IPL image
/// by `SPCIPLHost` (host-side port protocol only, not the 65816 sender).
/// The S-DSP runs alongside (`SDSP`); this diagnostic does not record its PCM.
public enum CTSPCDriver {
    public static let cleanROMSHA256 = "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"
    public static let entry: UInt16 = 0x0200
    public static let mainLoop: UInt16 = 0x0299

    public struct BootBlock: Codable, Equatable, Sendable {
        public let index, sourcePC, destination, length: Int
        public let sha256: String
    }

    public struct Check: Codable, Equatable, Sendable {
        public let name: String
        public let passed: Bool
    }

    public struct Diagnostic: Encodable, Sendable {
        public let format = "ct-spc-driver-check/1"
        public let mode: String
        public let romSHA256: String
        /// Present only for an IPL upload; nil fields are omitted from JSON.
        public let iplSHA256: String?
        public let blocks: [BootBlock]
        public let upload: SPCIPLHost.Report?
        /// Both count SMP clocks from the driver entry; upload clocks are separate.
        public let bootCycles, totalCycles, dspWrites: Int
        public let checks: [Check]
        public let limitations: [String]
        public let passed: Bool
    }

    /// The driver started by `boot`, stopped at its first `Spc_MainLoop` entry.
    /// Single owner; `CTSPCTransfer` continues from it.
    final class Session {
        let bus: SSMPBus
        let cpu: SPC700
        let dsp: SDSP
        let blocks: [BootBlock]
        let upload: SPCIPLHost.Report?
        /// SMP clocks before the driver entry (the IPL upload) and the
        /// post-entry budget `run` enforces.
        let entryCycles, cycleLimit: Int

        init(bus: SSMPBus, cpu: SPC700, dsp: SDSP, blocks: [BootBlock],
             upload: SPCIPLHost.Report?, cycleLimit: Int) {
            self.bus = bus; self.cpu = cpu; self.dsp = dsp; self.blocks = blocks
            self.upload = upload; self.cycleLimit = cycleLimit
            entryCycles = cpu.cycles
        }

        var postEntryCycles: Int { cpu.cycles - entryCycles }

        func run(until predicate: () -> Bool, phase: String) throws {
            while !predicate() {
                guard postEntryCycles < cycleLimit, !cpu.stopped else {
                    throw CTSongError("driver-check \(phase) did not complete within \(cycleLimit) cycles (PC $\(String(cpu.registers.pc, radix: 16)))")
                }
                cpu.step()
                if let fault = bus.fault { throw CTSongError("driver-check bus fault: \(fault)") }
            }
        }
    }

    /// Start the actual ROM payload with deterministic zero-filled unloaded
    /// RAM, the S-DSP's reset registers (zero, FLG $E0) and a fresh
    /// normal-speed timer phase, and run it
    /// to its first main-loop entry. Without `iplROM` the blocks are copied
    /// directly and IPL is off. With it, the six blocks are uploaded through
    /// that image and verified before $0200 runs; `cycleLimit` then bounds only
    /// post-entry execution.
    /// This is a diagnostic start state, not a hardware reset or SPC restore.
    static func boot(rom: [UInt8], iplROM: [UInt8]?, cycleLimit: Int) throws -> Session {
        guard (1...2_000_000).contains(cycleLimit) else {
            throw CTSongError("driver-check cycle limit must be 1...2000000")
        }
        let image = try bootImage(rom: rom)
        let dsp = SDSP()
        let bus: SSMPBus, cpu: SPC700
        var upload: SPCIPLHost.Report?
        if let iplROM {
            let host = try SPCIPLHost(iplROM: iplROM, dsp: dsp)
            upload = try host.upload(blocks: image.blocks.map {
                .init(destination: UInt16($0.destination),
                      bytes: Array(image.ram[$0.destination..<($0.destination + $0.length)]))
            }, entry: entry)
            bus = host.bus; cpu = host.cpu
        } else {
            bus = try SSMPBus(ram: image.ram, dsp: dsp)
            cpu = SPC700(bus: bus, registers: .init(pc: entry))
        }
        let session = Session(bus: bus, cpu: cpu, dsp: dsp, blocks: image.blocks, upload: upload, cycleLimit: cycleLimit)
        try session.run(until: { cpu.registers.pc == mainLoop }, phase: "boot")
        return session
    }

    /// Run the boot diagnostic: `boot`, then the checks and two driver commands below.
    public static func check(rom: [UInt8], iplROM: [UInt8]? = nil, cycleLimit: Int = 250_000) throws -> Diagnostic {
        let session = try boot(rom: rom, iplROM: iplROM, cycleLimit: cycleLimit)
        let bus = session.bus, cpu = session.cpu, dsp = session.dsp, upload = session.upload
        var checks: [Check] = []
        func record(_ name: String, _ passed: Bool) { checks.append(.init(name: name, passed: passed)) }
        func run(until predicate: () -> Bool, phase: String) throws { try session.run(until: predicate, phase: phase) }
        let bootCycles = session.postEntryCycles
        // Independent expectations transcribed from Spc_Start and its constants.
        record("driver reached main loop after minimum timer1 wait", bootCycles >= 81_920)
        record("stack initialized", cpu.registers.sp == 0xFF)
        record("no current, saved or pending song", [0x80, 0xBB, 0xBC].allSatisfy { bus.ram[$0] == 0xFF })
        record("three group volumes initialized", [0xF161, 0xF163, 0xF165].allSatisfy { bus.ram[$0] == 0xFF })
        record("DSP sample directory set", dsp.registers[0x5D] == 0x1E)
        record("eight voice gains initialized", (0..<8).allSatisfy { dsp.registers[$0 * 16 + 7] == 0xA0 })
        record("main volume initialized", dsp.registers[0x0C] == 0x40 && dsp.registers[0x1C] == 0x40)
        record("echo delay and base initialized", dsp.registers[0x7D] == 5 && dsp.registers[0x6D] == 0xC9)
        record("builtin sample parameters initialized", Array(bus.ram[0x1F20..<0x1F22]) == [0xE1, 0] && Array(bus.ram[0x1FA0..<0x1FA2]) == [0xFF, 0xE0])

        if let upload {
            // Real IPL leaves its start acknowledgement in CPUIO0 after the
            // jump; Spc_MainLoop's first timer0 pass writes the idle report.
            let held = bus.hostRead(port: 0) == upload.startToken
            try run(until: { bus.hostRead(port: 0) == 0 }, phase: "first port report")
            record("IPL start echo held until the driver's first port report", held)
        }

        // $01 is an echo-only low command. Distinct arguments prove input
        // latches survive independently of the driver's acknowledgement.
        guard bus.hostRead(port: 0) == 0 else {
            throw CTSongError("driver-check expected an idle acknowledgement latch after boot")
        }
        bus.hostWrite(port: 1, value: 0x42)
        bus.hostWrite(port: 2, value: 0x53)
        bus.hostWrite(port: 3, value: 0x64)
        bus.hostWrite(port: 0, value: 1)
        try run(until: { bus.hostRead(port: 0) == 1 }, phase: "command echo")
        record("command arguments captured", Array(bus.ram[0x8D..<0x91]) == [1, 0x42, 0x53, 0x64])

        // $FD = Spc_CmdWriteDsp. Wait for the write itself, since the driver
        // acknowledges high commands before running their handler.
        bus.hostWrite(port: 1, value: 0x2C) // EVOLL
        bus.hostWrite(port: 2, value: 0x37)
        bus.hostWrite(port: 3, value: 0)
        bus.hostWrite(port: 0, value: 0xFD)
        try run(until: { bus.hostRead(port: 0) == 0xFD && dsp.registers[0x2C] == 0x37 }, phase: "DSP command")
        record("DSP command executed through ROM handler", dsp.registers[0x2C] == 0x37)
        record("CPU, bus and DSP endpoint clocks agree", cpu.cycles == bus.cycles && dsp.clocks == cpu.cycles)
        let transfer = upload == nil
            ? "Direct RAM loading bypasses the 65816/IPL transfer handshake."
            : "IPL upload writes host ports between whole SMP instructions from zero-filled RAM; 65816 timing, power-on state and subcycle port races are not modeled."
        return .init(mode: (upload == nil ? "direct-ARAM-load" : "IPL-upload") + "; S-DSP; no PCM recorded",
                     romSHA256: cleanROMSHA256, iplSHA256: iplROM.map(CTEventPack.sha256),
                     blocks: session.blocks, upload: upload, bootCycles: bootCycles,
                     totalCycles: session.postEntryCycles, dspWrites: dsp.registerWrites, checks: checks,
                     limitations: [transfer,
                                   "The S-DSP runs (voices, envelopes, echo RAM writes) but no PCM is recorded or compared here; see music render.",
                                   "No song/sample transfer, PCM output, hardware reset or cycle-exact snapshot restore is verified."],
                     passed: checks.allSatisfy(\.passed))
    }

    /// Addresses derive from Audio_BootBlockPtrs / Audio_BootBlockAram,
    /// ChronoRET asm/bankC7/bankC7.asm. Pin the whole ROM because diagnostics
    /// interpret internal addresses in this specific driver revision.
    public static func bootImage(rom: [UInt8]) throws -> (ram: [UInt8], blocks: [BootBlock]) {
        guard rom.count == 4_194_304, CTEventPack.sha256(rom) == cleanROMSHA256 else {
            throw CTSongError("driver-check requires the verified unheadered CT USA 1.0 ROM")
        }
        func word(_ pc: Int) -> Int { Int(rom[pc]) | Int(rom[pc + 1]) << 8 }
        var ram = [UInt8](repeating: 0, count: 65536)
        var blocks: [BootBlock] = []
        for index in 0..<6 {
            let source = 0x70000 + word(0x70010 + index * 2)
            let destination = word(0x7001C + index * 2)
            let length = word(source)
            guard length > 0, source + 2 + length <= rom.count,
                  destination >= 0x100, destination + length <= 65536 else {
                throw CTSongError("invalid CT boot block \(index)")
            }
            let bytes = Array(rom[(source + 2)..<(source + 2 + length)])
            ram.replaceSubrange(destination..<(destination + length), with: bytes)
            blocks.append(.init(index: index, sourcePC: source, destination: destination,
                                length: length, sha256: CTEventPack.sha256(bytes)))
        }
        return (ram, blocks)
    }
}
