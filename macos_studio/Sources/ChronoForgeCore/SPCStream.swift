import Foundation

/// Continuous S-SMP/S-DSP rendering for playback: the machine loop of
/// `SPCRender.record`, run in chunks, so chunked output is the same PCM as a
/// one-shot render of the same total length. 32 kHz, stereo, 16-bit,
/// interleaved L/R. Not thread-safe: one owner (the playback producer thread).
public final class SPCStream {
    let cpu: SPC700
    let bus: SSMPBus
    let dsp: SDSP
    /// Ends a source that has nothing more to play (a non-looping sample).
    private let finished: (SDSP) -> Bool
    public private(set) var framesRendered = 0

    init(cpu: SPC700, bus: SSMPBus, dsp: SDSP, finished: @escaping (SDSP) -> Bool = { _ in false }) {
        self.cpu = cpu; self.bus = bus; self.dsp = dsp; self.finished = finished
    }

    /// True once the source can only produce silence from now on.
    public var isFinished: Bool { finished(dsp) }

    /// The next `frames` stereo frames (`2 * frames` samples). Recording stops
    /// after the step that completes the last frame (a step is shorter than a
    /// 32-clock frame), so the next call continues from the same clock a
    /// one-shot render would. Each call has the one-shot budget for its frames.
    public func render(frames: Int) throws -> [Int16] {
        precondition(frames > 0, "render at least one frame")
        let pcm = try SPCRender.record(cpu: cpu, bus: bus, dsp: dsp, frames: frames)
        framesRendered += frames
        return pcm
    }

    // MARK: Sources

    /// A ROM song from the driver's first idle report after its load, as
    /// `CTSPCRender.render` starts recording.
    public static func ctSong(rom: [UInt8], song: Int, iplROM: [UInt8]? = nil) throws -> SPCStream {
        let (session, load) = try CTSPCTransfer.loadSession(rom: rom, song: song, iplROM: iplROM, limits: .init())
        return try stream(session, load)
    }

    /// An edited song (`data` as loaded to ARAM $2000, plus the per-song table
    /// rows its listing sets) in place of ROM song `song`: `CTROMBuilder` writes
    /// it into a copy of the verified ROM, the transfer plan is read from that
    /// copy, and the driver boots from the verified ROM.
    public static func ctSong(rom: [UInt8], replacing song: Int, data: [UInt8], tables: CTSongTables = .init(),
                              iplROM: [UInt8]? = nil) throws -> SPCStream {
        let built = try CTROMBuilder.build(base: rom, requests: [],
                                           songs: [.init(song: song, source: "studio playback", data: data, tables: tables)],
                                           textProfile: nil).rom
        let plan = try CTSPCTransfer.Plan(rom: built, song: song)
        let (session, load) = try CTSPCTransfer.loadSession(rom: rom, plan: plan, iplROM: iplROM, limits: .init())
        return try stream(session, load)
    }

    private static func stream(_ session: CTSPCDriver.Session, _ load: CTSPCTransfer.Diagnostic) throws -> SPCStream {
        guard load.passed else {
            throw CTSongError("song load checks failed: " + load.checks.filter { !$0.passed }.map(\.name).joined(separator: ", "))
        }
        return SPCStream(cpu: session.cpu, bus: session.bus, dsp: session.dsp)
    }

    /// An SPC snapshot, started as `SPCRender.render(snapshot:)` starts it.
    public static func snapshot(_ snapshot: SPCFile, iplROM: [UInt8]? = nil,
                                options: SPCRender.Options = .init()) throws -> SPCStream {
        guard (0..<SDSP.counterPeriod).contains(options.counter) else {
            throw SPCRender.Failure.invalidCounter(options.counter)
        }
        let dsp = SDSP()
        dsp.load(registers: snapshot.dsp, counter: options.counter)
        dsp.mixMask = options.voices
        let bus = try SSMPBus(snapshot: snapshot, iplROM: iplROM, dsp: dsp)
        bus.timersBeforeAccess = options.timersBeforeAccess
        return SPCStream(cpu: SPC700(bus: bus, registers: snapshot.registers), bus: bus, dsp: dsp)
    }

    /// One BRR sample keyed on voice 0 with the CPU stopped, for previews.
    public struct Voice: Equatable, Sendable {
        /// 14-bit pitch; $1000 plays at 32 kHz.
        public var pitch: UInt16 = 0x1000
        /// ADSR1/ADSR2 (ADSR1 bit 7 set enables ADSR); nil uses `gain`.
        public var adsr: (UInt8, UInt8)? = nil
        /// GAIN register when ADSR is off; $7F is a fixed full envelope.
        public var gain: UInt8 = 0x7F
        public var volume: Int8 = 0x7F
        public init() {}

        public static func == (a: Voice, b: Voice) -> Bool {
            a.pitch == b.pitch && a.adsr?.0 == b.adsr?.0 && a.adsr?.1 == b.adsr?.1 && a.gain == b.gain && a.volume == b.volume
        }

        /// From a ctproj sample sidecar. `rate` sets the pitch (32 kHz = $1000).
        /// `adsr` is used when it holds hardware fields: two raw bytes
        /// [ADSR1, ADSR2], or [attack 0-15, decay 0-7, sustain level 0-7,
        /// sustain rate 0-31]; other values are not register fields and are
        /// ignored. `gain` is the GAIN register byte.
        public init(sample meta: SampleMeta) {
            if let rate = meta.rate, rate > 0 { pitch = UInt16(min(0x3FFF, rate * 0x1000 / SPCRender.sampleRate)) }
            if let a = meta.adsr {
                if a.count == 2, a.allSatisfy({ (0...255).contains($0) }), a[0] & 0x80 != 0 {
                    adsr = (UInt8(a[0]), UInt8(a[1]))
                } else if a.count == 4, (0...15).contains(a[0]), (0...7).contains(a[1]),
                          (0...7).contains(a[2]), (0...31).contains(a[3]) {
                    adsr = (UInt8(0x80 | a[1] << 4 | a[0]), UInt8(a[2] << 5 | a[3]))
                }
            }
            if let g = meta.gain, (0...255).contains(g) { gain = UInt8(g) }
        }
    }

    /// ARAM layout of `sample`: directory at $0200 (DIR = $02), program (STOP)
    /// at $0400, BRR data from $0500.
    static let sampleDirectory = 0x0200, sampleProgram = 0x0400, sampleData = 0x0500

    /// Play `brr` (whole 9-byte blocks; its end block's loop flag decides
    /// whether it loops) from `loopBlock` when it loops. The stream finishes
    /// when a non-looping sample reaches its end block.
    public static func sample(brr: [UInt8], loopBlock: Int = 0, voice: Voice = .init()) throws -> SPCStream {
        guard !brr.isEmpty, brr.count % 9 == 0 else { throw CTSongError("BRR data must be whole 9-byte blocks") }
        guard sampleData + brr.count <= 0xFFC0 else { throw CTSongError("BRR sample too large for ARAM ($\(String(brr.count, radix: 16)) bytes)") }
        let blocks = brr.count / 9
        guard (0..<blocks).contains(loopBlock) else { throw CTSongError("loop block \(loopBlock) is outside 0..<\(blocks)") }
        var ram = [UInt8](repeating: 0, count: 65536)
        let loop = sampleData + 9 * loopBlock
        ram.replaceSubrange(sampleDirectory..<(sampleDirectory + 4),
                            with: [UInt8(sampleData & 0xFF), UInt8(sampleData >> 8), UInt8(loop & 0xFF), UInt8(loop >> 8)])
        ram[sampleProgram] = 0xFF  // STOP: the DSP runs on its own
        ram.replaceSubrange(sampleData..<(sampleData + brr.count), with: brr)

        var registers = [UInt8](repeating: 0, count: 128)
        let volume = UInt8(bitPattern: voice.volume)
        registers[0x00] = volume; registers[0x01] = volume                      // VOL L/R
        registers[0x02] = UInt8(voice.pitch & 0xFF); registers[0x03] = UInt8(voice.pitch >> 8 & 0x3F)
        registers[0x04] = 0                                                     // SRCN
        registers[0x05] = voice.adsr?.0 ?? 0; registers[0x06] = voice.adsr?.1 ?? 0
        registers[0x07] = voice.gain
        registers[0x0C] = 0x7F; registers[0x1C] = 0x7F                          // MVOL L/R
        registers[0x4C] = 0x01                                                  // KON voice 0
        registers[0x5D] = UInt8(sampleDirectory >> 8)                           // DIR
        registers[0x6C] = 0x20                                                  // FLG: echo writes off
        registers[0x6D] = 0xFF                                                  // ESA (unused)
        let dsp = SDSP()
        dsp.load(registers: registers)
        let bus = try SSMPBus(ram: ram, dsp: dsp)
        let cpu = SPC700(bus: bus, registers: .init(pc: UInt16(sampleProgram), sp: 0xEF))
        let loops = brr[brr.count - 9] & 0x02 != 0
        return SPCStream(cpu: cpu, bus: bus, dsp: dsp) { dsp in
            !loops && dsp.registers[0x7C] & 0x01 != 0 && dsp.voiceEnvelope(0).level == 0
        }
    }

    /// A ctproj sample for the SFX preview: `file` is the `.brr` file (bare
    /// blocks, the ROM's [u16 length] prefix, or a 2-byte loop-offset header)
    /// and `meta` its sidecar. The sidecar decides looping, not the data's
    /// flags: with `loop`, blocks `loopStartSample / 16` through the one
    /// holding `loopEndSample - 1` (default: the last) repeat; without it every
    /// block plays once. Only the last played block keeps an end flag.
    public static func sample(file: [UInt8], meta: SampleMeta) throws -> SPCStream {
        let blocks = try brrBlocks(file)
        let count = blocks.count / 9
        var end = count, loopBlock = 0
        if meta.loop {
            loopBlock = (meta.loopStartSample ?? 0) / 16
            if let last = meta.loopEndSample { end = min(count, (last + 15) / 16) }
            guard loopBlock < end else {
                throw CTSongError("loop start sample \(meta.loopStartSample ?? 0) is not before the loop end (\(end * 16) of \(count * 16) samples)")
            }
        }
        var brr = Array(blocks.prefix(9 * end))
        for header in stride(from: 0, to: brr.count, by: 9) { brr[header] &= 0xFC }
        brr[brr.count - 9] |= meta.loop ? 0x03 : 0x01
        return try sample(brr: brr, loopBlock: loopBlock, voice: Voice(sample: meta))
    }

    /// BRR blocks of a sample file, without the ROM's [u16 length] prefix or a
    /// 2-byte loop-offset header.
    static func brrBlocks(_ file: [UInt8]) throws -> ArraySlice<UInt8> {
        if file.count >= 11 {
            let length = Int(file[0]) | Int(file[1]) << 8
            if length == file.count - 2, length % 9 == 0 { return file[2...] }
        }
        if !file.isEmpty, file.count % 9 == 0 { return file[...] }
        if file.count > 2, (file.count - 2) % 9 == 0 { return file[2...] }
        throw CTSongError("\(file.count) bytes is not whole 9-byte BRR blocks (with or without a 2-byte header)")
    }
}
