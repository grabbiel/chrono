/// S-DSP (SNES sound DSP) model clocked by the S-SMP bus: 8 BRR voices with
/// Gaussian interpolation, ADSR/GAIN envelopes, noise, pitch modulation and
/// the echo unit, producing one 32 kHz stereo frame every 32 SMP clocks.
///
/// Behavior follows written hardware documentation, not emulator source:
/// - nocash fullsnes (https://problemkaputt.de/fullsnes.htm), "SNES APU DSP BRR
///   Samples / BRR Pitch / ADSR/Gain Envelope / Volume / Control / Echo
///   Registers" and "SNES APU Low Level Timings": BRR shift, filters and 15-bit
///   clipping, the Gaussian table and its overflow behaviour, pitch and PMON,
///   envelope steps, KON/KOFF/FLG/ENDX, noise, mixer and echo FIR arithmetic,
///   and the T0...T31 register/RAM access chart this schedule follows.
/// - SNESdev Wiki (CC0), "DSP envelopes": the rate counter starts at 0,
///   decrements once per sample, wraps to $77FF and fires a rate when
///   (counter + offset) mod period = 0. "S-DSP registers": KON is polled every
///   second sample and its internal bits clear 63 clocks after the poll.
///
/// Representation: decoded and interpolated samples are 15-bit values; voice
/// amplitudes, mixer sums and output are 16-bit. Where fullsnes leaves a step
/// unstated the choice is documented at that step. The output is the DSP's
/// digital sample, before the board's inverting amplifier. Single owner.
public final class SDSP: SSMPDSPPort {
    /// fullsnes "4-Point Gaussian Interpolation" table, entries 000h...1FFh.
    public static let gaussTable: [Int16] = [
        0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000, 0x000,
        0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x001, 0x002, 0x002, 0x002, 0x002, 0x002,
        0x002, 0x002, 0x003, 0x003, 0x003, 0x003, 0x003, 0x004, 0x004, 0x004, 0x004, 0x004, 0x005, 0x005, 0x005, 0x005,
        0x006, 0x006, 0x006, 0x006, 0x007, 0x007, 0x007, 0x008, 0x008, 0x008, 0x009, 0x009, 0x009, 0x00A, 0x00A, 0x00A,
        0x00B, 0x00B, 0x00B, 0x00C, 0x00C, 0x00D, 0x00D, 0x00E, 0x00E, 0x00F, 0x00F, 0x00F, 0x010, 0x010, 0x011, 0x011,
        0x012, 0x013, 0x013, 0x014, 0x014, 0x015, 0x015, 0x016, 0x017, 0x017, 0x018, 0x018, 0x019, 0x01A, 0x01B, 0x01B,
        0x01C, 0x01D, 0x01D, 0x01E, 0x01F, 0x020, 0x020, 0x021, 0x022, 0x023, 0x024, 0x024, 0x025, 0x026, 0x027, 0x028,
        0x029, 0x02A, 0x02B, 0x02C, 0x02D, 0x02E, 0x02F, 0x030, 0x031, 0x032, 0x033, 0x034, 0x035, 0x036, 0x037, 0x038,
        0x03A, 0x03B, 0x03C, 0x03D, 0x03E, 0x040, 0x041, 0x042, 0x043, 0x045, 0x046, 0x047, 0x049, 0x04A, 0x04C, 0x04D,
        0x04E, 0x050, 0x051, 0x053, 0x054, 0x056, 0x057, 0x059, 0x05A, 0x05C, 0x05E, 0x05F, 0x061, 0x063, 0x064, 0x066,
        0x068, 0x06A, 0x06B, 0x06D, 0x06F, 0x071, 0x073, 0x075, 0x076, 0x078, 0x07A, 0x07C, 0x07E, 0x080, 0x082, 0x084,
        0x086, 0x089, 0x08B, 0x08D, 0x08F, 0x091, 0x093, 0x096, 0x098, 0x09A, 0x09C, 0x09F, 0x0A1, 0x0A3, 0x0A6, 0x0A8,
        0x0AB, 0x0AD, 0x0AF, 0x0B2, 0x0B4, 0x0B7, 0x0BA, 0x0BC, 0x0BF, 0x0C1, 0x0C4, 0x0C7, 0x0C9, 0x0CC, 0x0CF, 0x0D2,
        0x0D4, 0x0D7, 0x0DA, 0x0DD, 0x0E0, 0x0E3, 0x0E6, 0x0E9, 0x0EC, 0x0EF, 0x0F2, 0x0F5, 0x0F8, 0x0FB, 0x0FE, 0x101,
        0x104, 0x107, 0x10B, 0x10E, 0x111, 0x114, 0x118, 0x11B, 0x11E, 0x122, 0x125, 0x129, 0x12C, 0x130, 0x133, 0x137,
        0x13A, 0x13E, 0x141, 0x145, 0x148, 0x14C, 0x150, 0x153, 0x157, 0x15B, 0x15F, 0x162, 0x166, 0x16A, 0x16E, 0x172,
        0x176, 0x17A, 0x17D, 0x181, 0x185, 0x189, 0x18D, 0x191, 0x195, 0x19A, 0x19E, 0x1A2, 0x1A6, 0x1AA, 0x1AE, 0x1B2,
        0x1B7, 0x1BB, 0x1BF, 0x1C3, 0x1C8, 0x1CC, 0x1D0, 0x1D5, 0x1D9, 0x1DD, 0x1E2, 0x1E6, 0x1EB, 0x1EF, 0x1F3, 0x1F8,
        0x1FC, 0x201, 0x205, 0x20A, 0x20F, 0x213, 0x218, 0x21C, 0x221, 0x226, 0x22A, 0x22F, 0x233, 0x238, 0x23D, 0x241,
        0x246, 0x24B, 0x250, 0x254, 0x259, 0x25E, 0x263, 0x267, 0x26C, 0x271, 0x276, 0x27B, 0x280, 0x284, 0x289, 0x28E,
        0x293, 0x298, 0x29D, 0x2A2, 0x2A6, 0x2AB, 0x2B0, 0x2B5, 0x2BA, 0x2BF, 0x2C4, 0x2C9, 0x2CE, 0x2D3, 0x2D8, 0x2DC,
        0x2E1, 0x2E6, 0x2EB, 0x2F0, 0x2F5, 0x2FA, 0x2FF, 0x304, 0x309, 0x30E, 0x313, 0x318, 0x31D, 0x322, 0x326, 0x32B,
        0x330, 0x335, 0x33A, 0x33F, 0x344, 0x349, 0x34E, 0x353, 0x357, 0x35C, 0x361, 0x366, 0x36B, 0x370, 0x374, 0x379,
        0x37E, 0x383, 0x388, 0x38C, 0x391, 0x396, 0x39B, 0x39F, 0x3A4, 0x3A9, 0x3AD, 0x3B2, 0x3B7, 0x3BB, 0x3C0, 0x3C5,
        0x3C9, 0x3CE, 0x3D2, 0x3D7, 0x3DC, 0x3E0, 0x3E5, 0x3E9, 0x3ED, 0x3F2, 0x3F6, 0x3FB, 0x3FF, 0x403, 0x408, 0x40C,
        0x410, 0x415, 0x419, 0x41D, 0x421, 0x425, 0x42A, 0x42E, 0x432, 0x436, 0x43A, 0x43E, 0x442, 0x446, 0x44A, 0x44E,
        0x452, 0x455, 0x459, 0x45D, 0x461, 0x465, 0x468, 0x46C, 0x470, 0x473, 0x477, 0x47A, 0x47E, 0x481, 0x485, 0x488,
        0x48C, 0x48F, 0x492, 0x496, 0x499, 0x49C, 0x49F, 0x4A2, 0x4A6, 0x4A9, 0x4AC, 0x4AF, 0x4B2, 0x4B5, 0x4B7, 0x4BA,
        0x4BD, 0x4C0, 0x4C3, 0x4C5, 0x4C8, 0x4CB, 0x4CD, 0x4D0, 0x4D2, 0x4D5, 0x4D7, 0x4D9, 0x4DC, 0x4DE, 0x4E0, 0x4E3,
        0x4E5, 0x4E7, 0x4E9, 0x4EB, 0x4ED, 0x4EF, 0x4F1, 0x4F3, 0x4F5, 0x4F6, 0x4F8, 0x4FA, 0x4FB, 0x4FD, 0x4FF, 0x500,
        0x502, 0x503, 0x504, 0x506, 0x507, 0x508, 0x50A, 0x50B, 0x50C, 0x50D, 0x50E, 0x50F, 0x510, 0x511, 0x511, 0x512,
        0x513, 0x514, 0x514, 0x515, 0x516, 0x516, 0x517, 0x517, 0x517, 0x518, 0x518, 0x518, 0x518, 0x518, 0x519, 0x519,
    ]

    /// Samples between envelope/noise steps for each 5-bit rate (fullsnes
    /// "ADSR/Gain (and Noise) Rates"); rate 0 never fires.
    public static let ratePeriods: [Int] = [
        0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192, 160, 128, 96, 80,
        64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1,
    ]
    /// Counter offsets (SNESdev Wiki "DSP envelopes"): rate 1 is 0, rate 2 is
    /// 1040, then 536, 0, 1040 repeat from rate 3.
    public static let rateOffsets: [Int] = [0, 0, 1040] + Array([[536, 0, 1040]].repeated(9).joined()) + [536, 0]
    /// The counter wraps from 0 to $77FF.
    public static let counterPeriod = 0x7800

    public enum EnvelopeMode: Int, Sendable { case attack, decay, sustain, release }

    /// What the DSP does at one SMP clock (fullsnes T0...T31).
    enum Step: Equatable {
        case source(Int), directory(Int), pitchHigh(Int), header(Int), main(Int)
        case decode(Int), right(Int), envx(Int), outx(Int)
        case echoReadLeft, echoReadRight, firLatch(Int), filter
        case outputLeft, outputRight, flagLatch, echoWriteLeft, poll, echoWriteRight
    }

    /// Per-clock work, from the fullsnes Low Level Timings chart. Voice n's
    /// steps are 3 clocks apart from voice n-1's; voices 0 and 1 start in the
    /// previous pass (the chart reads V0SRCN at T18, V1SRCN at T21 and voice
    /// 0's directory, PITCHH, BRR header and ADSR2 at T22, T23, T26 and T31).
    static let schedule: [[Step]] = {
        var t = [[Step]](repeating: [], count: 32)
        for v in 0..<8 {
            t[v == 0 ? 18 : v == 1 ? 21 : 3 * v - 6].append(.source(v))
            t[v == 0 ? 22 : 3 * v - 2].append(.directory(v))
            if v > 0 { t[3 * v - 1] += [.pitchHigh(v), .header(v), .main(v)] }
        }
        t[23].append(.pitchHigh(0))
        t[26].append(.header(0))
        for v in 0..<8 {
            // VxVOLL with the second BRR byte, VxVOLR with ENDX, then ENVX and OUTX.
            t[3 * v].append(.decode(v))
            t[3 * v + 1].append(.right(v))
            t[3 * v + 2].append(.envx(v))
            t[3 * v + 3].append(.outx(v))
        }
        t[23] += [.echoReadLeft, .firLatch(0)]
        t[24] += [.echoReadRight, .firLatch(1), .firLatch(2)]
        t[25] += [.firLatch(3), .firLatch(4), .firLatch(5)]
        t[26] += [.firLatch(6), .firLatch(7), .filter]
        t[27].append(.outputLeft)
        t[28].append(.outputRight)
        t[29].append(.flagLatch)
        t[30].append(.echoWriteLeft)
        t[31] += [.poll, .main(0), .echoWriteRight]
        return t
    }()

    struct Voice {
        var brrAddress = 0, brrOffset = 1, bufferPosition = 0
        /// Pitch counter: bits 12-14 select the sample, bits 4-11 the Gaussian index.
        var position = 0
        var konDelay = 0
        var envelope = 0, hiddenEnvelope = 0
        var mode = EnvelopeMode.release
        // Values latched by earlier steps of the same sample.
        var source = 0, nextAddress = 0, adsr1 = 0, pitch = 0, header = 0, data = 0
        /// 15-bit sample after the envelope, and ENVX, for this sample.
        var output = 0, envx = 0
        var looped = false
    }

    /// Register array; ENVX, OUTX and ENDX are updated by the DSP.
    public private(set) var registers: [UInt8]
    /// SMP clocks and CPU register writes seen.
    public private(set) var clocks = 0, registerWrites = 0
    /// Next schedule slot (fullsnes T). A fresh DSP on a fresh `SSMPBus`
    /// starts at T2, so the bus's timer ticks (clock 15 mod 16) land on T1/T17
    /// as fullsnes's chart shows.
    public private(set) var phase = 2
    /// The most recent stereo frame (after FLG mute).
    public private(set) var lastFrame: (left: Int16, right: Int16) = (0, 0)
    public private(set) var frameCount = 0
    /// Voices mixed into the output and echo input (bit n = voice n). A muted
    /// voice still runs and still drives PMON; it only stops being mixed.
    public var mixMask: UInt8 = 0xFF
    /// Interleaved L/R frames since the last `takeRecording()`, while recording.
    public var isRecording = false
    public private(set) var recording: [Int16] = []

    var voices = [Voice](repeating: Voice(), count: 8)
    /// 12 decoded 15-bit samples per voice, written 4 at a time.
    var decoded = [Int](repeating: 0, count: 96)
    var counter = 0
    var noise = 0x4000
    var everyOther = true
    var newKON = 0, konLatch = 0, koffLatch = 0
    var pmonLatch = 0, nonLatch = 0, eonLatch = 0, dirLatch = 0
    var lastOutput = 0
    var mainLeft = 0, mainRight = 0, echoLeft = 0, echoRight = 0
    var echoOutLeft = 0, echoOutRight = 0
    var echoIndex = 0, echoLength = 0, esaLatch = 0, echoAddress = 0, echoWrites = false
    var echoHistory = [Int](repeating: 0, count: 16)   // 8 frames of L, R
    var historyIndex = 0
    var fir = [Int](repeating: 0, count: 8)
    var firLeft = 0, firRight = 0, outLeft = 0

    /// Reset state: registers zero except FLG = $E0 (fullsnes: keyed off,
    /// muted, echo writes off, noise stopped), counter 0, noise $4000.
    public init() {
        registers = [UInt8](repeating: 0, count: 128)
        registers[0x6C] = 0xE0
    }

    /// Load a register image the way SPC players start a snapshot: internal
    /// voice and echo state reset, schedule at T2, and KON bits taken as not
    /// yet polled. ENDX is kept. SPC files carry no internal DSP state, so the
    /// rate counter's start is the caller's choice: 0 is the reset value
    /// (SNESdev Wiki); libgme's default DSP loads with the equivalent of $7F0.
    public func load(registers image: [UInt8], counter start: Int = 0) {
        precondition(image.count == 128, "S-DSP register image must be 128 bytes")
        precondition((0..<Self.counterPeriod).contains(start), "rate counter must be 0...$77FF")
        let keep = (frameCount, clocks, registerWrites, isRecording, recording)
        let fresh = SDSP()
        // Reuse a fresh instance's initial internal state.
        voices = fresh.voices; decoded = fresh.decoded; counter = start; noise = fresh.noise
        everyOther = fresh.everyOther; konLatch = 0; koffLatch = 0
        pmonLatch = 0; nonLatch = 0; eonLatch = 0; dirLatch = Int(image[0x5D])
        lastOutput = 0; mainLeft = 0; mainRight = 0; echoLeft = 0; echoRight = 0
        echoOutLeft = 0; echoOutRight = 0; echoIndex = 0; echoLength = 0
        esaLatch = Int(image[0x6D]); echoAddress = 0; echoWrites = false
        echoHistory = fresh.echoHistory; historyIndex = 0; fir = fresh.fir
        firLeft = 0; firRight = 0; outLeft = 0; phase = fresh.phase
        registers = image
        newKON = Int(image[0x4C])
        (frameCount, clocks, registerWrites, isRecording, recording) = keep
    }

    /// KON bits written but not yet polled, as an SPC snapshot stores them.
    public var pendingKeyOn: UInt8 { UInt8(newKON & ~konLatch) }

    public func voiceEnvelope(_ voice: Int) -> (level: Int, mode: EnvelopeMode) {
        (voices[voice].envelope, voices[voice].mode)
    }

    public func takeRecording() -> [Int16] {
        defer { recording.removeAll(keepingCapacity: true) }
        return recording
    }

    public func readRegister(_ address: UInt8) -> UInt8 { registers[Int(address & 0x7F)] }

    public func writeRegister(_ address: UInt8, _ value: UInt8) {
        registerWrites += 1
        let index = Int(address & 0x7F)
        switch index {
        case 0x7C: registers[index] = 0      // ENDX: any write clears every bit
        case 0x4C: registers[index] = value; newKON = Int(value)
        default: registers[index] = value
        }
    }

    public func clock(ram: inout [UInt8]) {
        clocks += 1
        for step in Self.schedule[phase] { perform(step, &ram) }
        phase = (phase + 1) & 31
    }

    // MARK: Steps

    private func perform(_ step: Step, _ ram: inout [UInt8]) {
        switch step {
        case .source(let v):
            voices[v].source = Int(registers[v << 4 | 0x04])
        case .directory(let v):
            // Start address while keying on, else the loop address.
            let entry = (dirLatch << 8) + voices[v].source * 4 + (voices[v].konDelay != 0 ? 0 : 2)
            voices[v].nextAddress = Int(ram[entry & 0xFFFF]) | Int(ram[(entry + 1) & 0xFFFF]) << 8
            voices[v].adsr1 = Int(registers[v << 4 | 0x05])
            voices[v].pitch = Int(registers[v << 4 | 0x02])
        case .pitchHigh(let v):
            voices[v].pitch |= Int(registers[v << 4 | 0x03] & 0x3F) << 8
        case .header(let v):
            let address = voices[v].brrAddress
            voices[v].header = Int(ram[address])
            voices[v].data = Int(ram[(address + voices[v].brrOffset) & 0xFFFF])
        case .main(let v): main(v)
        case .decode(let v): decode(v, &ram)
        case .right(let v):
            let bit = 1 << v
            mix(voices[v].output, Int8(bitPattern: registers[v << 4 | 0x01]), bit, &mainRight, &echoRight)
            var endx = Int(registers[0x7C])
            if voices[v].looped { endx |= bit }
            if voices[v].konDelay == 5 { endx &= ~bit }   // keyed on this sample
            registers[0x7C] = UInt8(endx)
        case .envx(let v):
            registers[v << 4 | 0x08] = UInt8(voices[v].envx)
        case .outx(let v):
            registers[v << 4 | 0x09] = UInt8(truncatingIfNeeded: voices[v].output >> 7)
        case .echoReadLeft:
            echoAddress = ((esaLatch << 8) + echoIndex) & 0xFFFF
            historyIndex = (historyIndex + 1) & 7
            echoHistory[historyIndex * 2] = Self.echoSample(ram, echoAddress)
        case .echoReadRight:
            echoHistory[historyIndex * 2 + 1] = Self.echoSample(ram, echoAddress + 2)
        case .firLatch(let tap):
            fir[tap] = Int(Int8(bitPattern: registers[tap << 4 | 0x0F]))
        case .filter:
            firLeft = filter(0); firRight = filter(1)
        case .outputLeft:
            // EFB is read here for both channels (fullsnes T27).
            let efb = Int(Int8(bitPattern: registers[0x0D]))
            outLeft = Self.output(mainLeft, firLeft, registers[0x0C], registers[0x2C])
            echoOutLeft = Self.echoInput(echoLeft, firLeft, efb)
            echoOutRight = Self.echoInput(echoRight, firRight, efb)
        case .outputRight:
            var left = outLeft, right = Self.output(mainRight, firRight, registers[0x1C], registers[0x3C])
            if registers[0x6C] & 0x40 != 0 { left = 0; right = 0 }   // FLG mute
            emit(Int16(left), Int16(right))
            mainLeft = 0; mainRight = 0
            pmonLatch = Int(registers[0x2D]) & 0xFE                  // voice 0 has no PMON
        case .flagLatch:
            nonLatch = Int(registers[0x3D]); eonLatch = Int(registers[0x4D])
            dirLatch = Int(registers[0x5D]); echoWrites = registers[0x6C] & 0x20 == 0
        case .echoWriteLeft:
            // ESA takes effect from the next sample's read; EDL only when the
            // index returns to 0 (fullsnes "Echo Buffer Notes").
            esaLatch = Int(registers[0x6D])
            if echoIndex == 0 { echoLength = Int(registers[0x7D] & 0x0F) << 11 }
            echoIndex += 4
            if echoIndex >= echoLength { echoIndex = 0 }
            if echoWrites { Self.store(&ram, echoAddress, echoOutLeft) }
            echoLeft = 0
            echoWrites = registers[0x6C] & 0x20 == 0
            everyOther.toggle()
            if everyOther { newKON &= ~konLatch }                     // 63 clocks after the poll
        case .poll:
            if everyOther { konLatch = newKON; koffLatch = Int(registers[0x5C]) }
            counter = counter == 0 ? Self.counterPeriod - 1 : counter - 1
            if fires(Int(registers[0x6C] & 0x1F)) {
                noise = (noise >> 1) & 0x3FFF | ((noise ^ noise >> 1) & 1) << 14
            }
        case .echoWriteRight:
            if echoWrites { Self.store(&ram, echoAddress + 2, echoOutRight) }
            echoRight = 0
        }
    }

    /// Pitch modulation, key-on delay, interpolation or noise, envelope,
    /// end/reset silencing, KON/KOFF, then the envelope for the next sample.
    private func main(_ v: Int) {
        var voice = voices[v]
        let bit = 1 << v
        if pmonLatch & bit != 0 {
            // fullsnes: step * ((OUTX(v-1) SAR 4) + 400h) SAR 10.
            voice.pitch += ((lastOutput >> 4) * voice.pitch) >> 10
        }
        if voice.konDelay > 0 {
            // Five samples: the first fetches the start address, the next
            // three decode 12 samples, and neither pitch nor envelope run.
            if voice.konDelay == 5 {
                voice.brrAddress = voice.nextAddress; voice.brrOffset = 1
                voice.bufferPosition = 0; voice.header = 0
            }
            voice.envelope = 0; voice.hiddenEnvelope = 0
            voice.konDelay -= 1
            voice.position = voice.konDelay & 3 != 0 ? 0x4000 : 0
            voice.pitch = 0
        }
        let sample = nonLatch & bit != 0
            ? Int(Int16(truncatingIfNeeded: noise << 1)) >> 1
            : interpolate(v, voice)
        voice.output = (sample * voice.envelope) >> 11
        voice.envx = voice.envelope >> 4
        lastOutput = voice.output
        // End+Mute block or FLG soft reset: release with level 0 (checked every sample).
        if registers[0x6C] & 0x80 != 0 || voice.header & 3 == 1 {
            voice.mode = .release; voice.envelope = 0
        }
        if everyOther {
            if koffLatch & bit != 0 { voice.mode = .release }
            if konLatch & bit != 0 { voice.konDelay = 5; voice.mode = .attack }
        }
        if voice.konDelay == 0 { runEnvelope(&voice, v) }
        voices[v] = voice
    }

    private func interpolate(_ v: Int, _ voice: Voice) -> Int {
        let start = voice.bufferPosition + (voice.position >> 12), base = v * 12
        return Self.gaussian(decoded[base + start % 12], decoded[base + (start + 1) % 12],
                             decoded[base + (start + 2) % 12], decoded[base + (start + 3) % 12],
                             index: (voice.position >> 4) & 0xFF)
    }

    /// fullsnes: oldest x gauss[0FFh-i], older x gauss[1FFh-i], old x
    /// gauss[100h+i], each SAR 10 and summed with 16-bit wraparound, then new
    /// x gauss[000h+i] added with saturation, SAR 1 to 15 bits.
    static func gaussian(_ oldest: Int, _ older: Int, _ old: Int, _ new: Int, index i: Int) -> Int {
        let g = gaussTable
        var out = (Int(g[255 - i]) * oldest) >> 10
        out += (Int(g[511 - i]) * older) >> 10
        out += (Int(g[256 + i]) * old) >> 10
        out = wrap(out)
        out += (Int(g[i]) * new) >> 10
        return clamp(out) >> 1
    }

    /// Decode 4 samples when the pitch counter has crossed into them, advance
    /// the counter, then mix the left channel.
    private func decode(_ v: Int, _ ram: inout [UInt8]) {
        var voice = voices[v]
        voice.looped = false
        if voice.position >= 0x4000 {
            let second = Int(ram[(voice.brrAddress + voice.brrOffset + 1) & 0xFFFF])
            let shift = voice.header >> 4, filter = (voice.header >> 2) & 3
            let nibbles = [voice.data >> 4, voice.data & 15, second >> 4, second & 15]
            let base = v * 12
            var position = voice.bufferPosition
            for nibble in nibbles {
                let n = nibble >= 8 ? nibble - 16 : nibble
                // Shifts 13-15 act as shift 12 with nibble SAR 3.
                let x = shift <= 12 ? (n << shift) >> 1 : (n >> 3) << 11
                let y1 = decoded[base + (position + 11) % 12], y2 = decoded[base + (position + 10) % 12]
                let y = Int(BRR.clamp16(BRR.filter(filter, x, y1, y2)))
                decoded[base + position] = Int(Int16(truncatingIfNeeded: y << 1)) >> 1   // keep 15 bits
                position = (position + 1) % 12
            }
            voice.bufferPosition = position
            voice.brrOffset += 2
            if voice.brrOffset >= 9 {
                voice.brrAddress = (voice.brrAddress + 9) & 0xFFFF
                if voice.header & 1 != 0 { voice.brrAddress = voice.nextAddress; voice.looped = true }
                voice.brrOffset = 1
            }
        }
        voice.position = min((voice.position & 0x3FFF) + voice.pitch, 0x7FFF)
        voices[v] = voice
        mix(voice.output, Int8(bitPattern: registers[v << 4]), 1 << v, &mainLeft, &echoLeft)
    }

    /// fullsnes mixer: sample x VxVOL SAR 6, saturated after each addition.
    private func mix(_ output: Int, _ volume: Int8, _ bit: Int, _ main: inout Int, _ echo: inout Int) {
        guard Int(mixMask) & bit != 0 else { return }
        let amplitude = (output * Int(volume)) >> 6
        main = Self.clamp(main + amplitude)
        if eonLatch & bit != 0 { echo = Self.clamp(echo + amplitude) }
    }

    /// fullsnes ADSR/GAIN rules. The candidate level decides phase changes
    /// every sample; the rate counter decides whether the level is stored.
    private func runEnvelope(_ voice: inout Voice, _ v: Int) {
        if voice.mode == .release {
            voice.envelope = max(0, voice.envelope - 8)
            return
        }
        var level = voice.envelope, rate: Int
        // Sustain boundary: ADSR2 bits 5-7, or GAIN's when in GAIN mode.
        let boundary: Int
        if voice.adsr1 & 0x80 != 0 {
            let adsr2 = Int(registers[v << 4 | 0x06])
            boundary = adsr2 >> 5
            switch voice.mode {
            case .attack:
                rate = (voice.adsr1 & 0x0F) * 2 + 1
                level += rate < 31 ? 0x20 : 0x400
            case .decay:
                rate = ((voice.adsr1 >> 4) & 7) * 2 + 16
                level -= 1; level -= level >> 8
            default:
                rate = adsr2 & 0x1F
                level -= 1; level -= level >> 8
            }
        } else {
            let gain = Int(registers[v << 4 | 0x07])
            boundary = gain >> 5
            if gain & 0x80 == 0 {
                level = (gain & 0x7F) * 16; rate = 31
            } else {
                rate = gain & 0x1F
                switch (gain >> 5) & 3 {
                case 0: level -= 0x20
                case 1: level -= 1; level -= level >> 8
                case 2: level += 0x20
                default:
                    // Bent line: the previous unclipped level as unsigned, so a
                    // negative one counts as >= $600 (fullsnes "Misc Notes").
                    level += UInt(bitPattern: voice.hiddenEnvelope) < 0x600 ? 0x20 : 0x08
                }
            }
        }
        if voice.mode == .decay && level >> 8 == boundary { voice.mode = .sustain }
        voice.hiddenEnvelope = level
        if level < 0 || level > 0x7FF {
            level = level < 0 ? 0 : 0x7FF
            if voice.mode == .attack { voice.mode = .decay }
        }
        if fires(rate) { voice.envelope = level }
    }

    private func fires(_ rate: Int) -> Bool {
        rate != 0 && (counter + Self.rateOffsets[rate]) % Self.ratePeriods[rate] == 0
    }

    private func filter(_ channel: Int) -> Int {
        Self.fir(fir) { echoHistory[((historyIndex + 1 + $0) & 7) * 2 + channel] }
    }

    /// fullsnes FIR: each sample x FIRn SAR 6; FIR0 x oldest ... FIR6 summed
    /// with 16-bit wraparound, then FIR7 x newest added with saturation.
    /// `sample(n)` is the n-th oldest of 8. Bit 0 is kept here; only the
    /// feedback written to echo RAM is masked.
    static func fir(_ taps: [Int], sample: (Int) -> Int) -> Int {
        var sum = 0
        for tap in 0..<7 { sum += (sample(tap) * taps[tap]) >> 6 }
        sum = wrap(sum)
        sum += (sample(7) * taps[7]) >> 6
        return clamp(sum)
    }

    /// Echo RAM input: the voices' echo sum plus FIR x EFB SAR 7 kept to 16
    /// bits, saturated, bit 0 cleared.
    static func echoInput(_ voices: Int, _ fir: Int, _ feedback: Int) -> Int {
        clamp(voices + wrap((fir * feedback) >> 7)) & ~1
    }

    private func emit(_ left: Int16, _ right: Int16) {
        lastFrame = (left, right)
        frameCount += 1
        if isRecording { recording.append(left); recording.append(right) }
    }

    /// Main x MVOL SAR 7 plus FIR x EVOL SAR 7; each product keeps 16 bits
    /// (fullsnes notes MVOL = -128 overflows), the sum saturates.
    static func output(_ main: Int, _ fir: Int, _ mainVolume: UInt8, _ echoVolume: UInt8) -> Int {
        clamp(wrap((main * Int(Int8(bitPattern: mainVolume))) >> 7) + wrap((fir * Int(Int8(bitPattern: echoVolume))) >> 7))
    }

    /// Echo RAM holds 16-bit little-endian samples; the FIR takes them SAR 1.
    static func echoSample(_ ram: [UInt8], _ address: Int) -> Int {
        Int(Int16(bitPattern: UInt16(ram[address & 0xFFFF]) | UInt16(ram[(address + 1) & 0xFFFF]) << 8)) >> 1
    }

    static func store(_ ram: inout [UInt8], _ address: Int, _ value: Int) {
        ram[address & 0xFFFF] = UInt8(truncatingIfNeeded: value)
        ram[(address + 1) & 0xFFFF] = UInt8(truncatingIfNeeded: value >> 8)
    }

    @inline(__always) static func clamp(_ value: Int) -> Int { max(-0x8000, min(0x7FFF, value)) }
    @inline(__always) static func wrap(_ value: Int) -> Int { Int(Int16(truncatingIfNeeded: value)) }
}

private extension Array {
    func repeated(_ count: Int) -> [Element] { (0..<count).flatMap { _ in self } }
}
