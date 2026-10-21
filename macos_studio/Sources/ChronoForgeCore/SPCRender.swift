import Foundation

/// Bounded offline PCM rendering through `SPC700`, `SSMPBus` and `SDSP`:
/// 32 kHz, stereo, 16-bit, interleaved L/R.
public enum SPCRender {
    public static let sampleRate = 32_000
    /// Hard limit for one render.
    public static let maxSeconds = 300.0

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidDuration(Double)
        case invalidCounter(Int)
        case budgetExceeded(cycles: Int, pc: UInt16)
        case busFault(SSMPBus.Fault)

        public var description: String {
            switch self {
            case .invalidDuration(let seconds):
                return "render duration \(seconds) s is outside 0 < seconds <= \(SPCRender.maxSeconds)"
            case .invalidCounter(let value):
                return "S-DSP rate counter \(value) is outside 0...$77FF"
            case .budgetExceeded(let cycles, let pc):
                return "render exceeded its cycle budget at \(cycles) cycles (PC $\(String(pc, radix: 16)))"
            case .busFault(let fault): return "render bus fault: \(fault)"
            }
        }
    }

    /// Whole frames for `seconds`, refusing durations outside the hard limit.
    public static func frames(seconds: Double) throws -> Int {
        guard seconds.isFinite, seconds > 0, seconds <= maxSeconds else { throw Failure.invalidDuration(seconds) }
        return max(1, Int((seconds * Double(sampleRate)).rounded()))
    }

    /// Run the machine until `frames` stereo frames are produced. A stopped
    /// CPU (SLEEP/STOP) holds while the DSP keeps running. The budget is the
    /// frames' clocks plus one frame; a bus fault stops the render.
    static func record(cpu: SPC700, bus: SSMPBus, dsp: SDSP, frames: Int) throws -> [Int16] {
        _ = dsp.takeRecording()
        dsp.isRecording = true
        defer { dsp.isRecording = false }
        let start = bus.cycles, budget = (frames + 1) * 32
        while dsp.recording.count < frames * 2 {
            guard bus.cycles - start <= budget else {
                throw Failure.budgetExceeded(cycles: bus.cycles - start, pc: cpu.registers.pc)
            }
            if cpu.stopped { bus.idle() } else { cpu.step() }
            if let fault = bus.fault { throw Failure.busFault(fault) }
        }
        return Array(dsp.takeRecording().prefix(frames * 2))
    }

    /// The running state as an SPC v0.30 snapshot. KON holds only bits not yet
    /// polled, so a loader does not key on voices again; timer prescalers and
    /// the DSP's internal voice/echo state are not representable.
    public static func snapshot(cpu: SPC700, bus: SSMPBus, dsp: SDSP) throws -> SPCFile {
        var registers = dsp.registers
        registers[0x4C] = dsp.pendingKeyOn
        return try SPCFile(registers: cpu.registers, ram: bus.snapshotRAM(), dsp: registers,
                           extraRAM: Array(bus.ram[0xFFC0...0xFFFF]))
    }

    /// Choices an SPC snapshot leaves open, and voice muting for analysis.
    public struct Options: Sendable {
        /// Voices mixed (bit n = voice n); muted voices still run.
        public var voices: UInt8 = 0xFF
        /// S-DSP rate counter start (`SDSP.load(registers:counter:)`).
        public var counter = 0
        /// `SSMPBus.timersBeforeAccess`.
        public var timersBeforeAccess = false
        public init() {}
    }

    /// Render a snapshot from its saved state (see `SSMPBus.init(snapshot:)`
    /// and `SDSP.load(registers:counter:)` for what restarts). An enabled IPL
    /// overlay needs the caller's 64-byte image.
    public static func render(snapshot: SPCFile, seconds: Double, iplROM: [UInt8]? = nil,
                              options: Options = Options()) throws -> [Int16] {
        let frames = try frames(seconds: seconds)
        guard (0..<SDSP.counterPeriod).contains(options.counter) else { throw Failure.invalidCounter(options.counter) }
        let dsp = SDSP()
        dsp.load(registers: snapshot.dsp, counter: options.counter)
        dsp.mixMask = options.voices
        let bus = try SSMPBus(snapshot: snapshot, iplROM: iplROM, dsp: dsp)
        bus.timersBeforeAccess = options.timersBeforeAccess
        let cpu = SPC700(bus: bus, registers: snapshot.registers)
        return try record(cpu: cpu, bus: bus, dsp: dsp, frames: frames)
    }

    /// 16-bit PCM WAV, stereo.
    public static func wav(_ pcm: [Int16]) -> Data {
        WAV.writeWav(samples: pcm, rate: sampleRate, channels: 2)
    }
}

/// A Chrono Trigger song rendered from the ROM: driver boot, the first song
/// load (`CTSPCTransfer`), then PCM from the driver's first idle port report.
public enum CTSPCRender {
    public struct Report: Encodable, Sendable {
        public let format = "ct-spc-render/1"
        public let mode: String
        public let romSHA256: String
        public let iplSHA256: String?
        public let song: Int
        public let sampleRate, channels, frames: Int
        public let seconds: Double
        /// Driver clocks after its entry when rendering starts, and the
        /// render's own clocks.
        public let startCycles, renderCycles: Int
        public let pcmSHA256: String
        public let peak: Int
        public let nonzeroFrames: Int
        public let loadChecks: [CTSPCDriver.Check]
        public let limitations: [String]
    }

    public struct Render: Sendable {
        public let pcm: [Int16]
        /// State at the first rendered frame's start (the snapshot instant).
        public let snapshot: SPCFile
        public let report: Report
    }

    public static func render(rom: [UInt8], song: Int, seconds: Double, iplROM: [UInt8]? = nil) throws -> Render {
        let frames = try SPCRender.frames(seconds: seconds)
        let (session, load) = try CTSPCTransfer.loadSession(rom: rom, song: song, iplROM: iplROM, limits: .init())
        guard load.passed else {
            throw CTSongError("song load checks failed: " + load.checks.filter { !$0.passed }.map(\.name).joined(separator: ", "))
        }
        let snapshot = try SPCRender.snapshot(cpu: session.cpu, bus: session.bus, dsp: session.dsp)
        let startCycles = session.postEntryCycles, start = session.bus.cycles
        let pcm = try SPCRender.record(cpu: session.cpu, bus: session.bus, dsp: session.dsp, frames: frames)
        let peak = pcm.reduce(0) { max($0, abs(Int($1))) }
        let nonzero = stride(from: 0, to: pcm.count, by: 2).reduce(0) { $0 + (pcm[$1] != 0 || pcm[$1 + 1] != 0 ? 1 : 0) }
        let boot = session.upload == nil ? "direct-ARAM-load" : "IPL-upload"
        let report = Report(
            mode: "\(boot); first song load; S-DSP PCM from the first idle port report",
            romSHA256: CTSPCDriver.cleanROMSHA256, iplSHA256: iplROM.map(CTEventPack.sha256), song: song,
            sampleRate: SPCRender.sampleRate, channels: 2, frames: frames, seconds: Double(frames) / Double(SPCRender.sampleRate),
            startCycles: startCycles, renderCycles: session.bus.cycles - start,
            pcmSHA256: CTEventPack.sha256(pcm.withUnsafeBytes { Array($0) }), peak: peak, nonzeroFrames: nonzero,
            loadChecks: load.checks,
            limitations: [
                "No host commands are sent after the load: no sound effects, fades or later song changes.",
                "Deterministic zero-state boot (zero RAM, fresh timer and DSP phase), not a hardware power-on; host writes between whole SMP instructions.",
                "Digital DSP output before the console's analog stage (no inverting amplifier or output filter).",
            ])
        return Render(pcm: pcm, snapshot: snapshot, report: report)
    }
}
