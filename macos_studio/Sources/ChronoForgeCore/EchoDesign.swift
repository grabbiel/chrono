// A song's echo and instruments as the driver sets them: the echo delay of
// its AudioRom_SongEcho row, the echo volume, feedback and FIR set of its
// sequence commands, echo per track, and the samples its @samples row loads
// with their tuning and ADSR words. Driver tables are read from the ROM.
import Foundation

public enum CTSongEcho {
    /// Spc_FirSets (driver ARAM $1D93): the four FIR sets `fir` chooses from.
    static let firSetsAram = 0x1D93
    /// !Audio_EchoTopPage: the echo buffer ends below $F100.
    public static let echoTop = 0xF100

    /// The driver's four FIR sets of eight taps, read from its boot blocks.
    public static func firSets(rom: [UInt8]) throws -> [[Int8]] {
        let ram = try CTSPCDriver.bootImage(rom: rom).ram
        return (0..<4).map { k in (0..<8).map { Int8(bitPattern: ram[firSetsAram + 8 * k + $0]) } }
    }

    /// The echo buffer for delay `edl` (Spc_SetEchoDelay: ESA = $F1 - 8 x EDL pages).
    public static func buffer(edl: Int) -> Range<Int> { (echoTop - 0x800 * edl)..<echoTop }

    /// The echo the song sets: the first of each command any track runs
    /// (with its statement), and each track's echo at its first note.
    public struct Settings: Equatable, Sendable {
        /// AudioRom_SongEcho: the echo delay (low nibble of byte 0) and byte 1 (Spc_Unk4D).
        public var edl: Int?, songEchoByte1: Int?
        public var evol: Int?, evolItem: Int?
        public var efb: Int?, efbItem: Int?
        public var firSet: Int?, firItem: Int?
        /// Per track 0-7: echo on when its first note plays (nil: no track).
        public var eon: [Bool?] = Array(repeating: nil, count: 8)
    }

    public static func settings(_ doc: CTSongDocument, _ timeline: CTSongTimeline) -> Settings {
        var s = Settings()
        if let echo = doc.directive("@echo"), echo.count == 2,
           let b0 = UInt8(echo[0].dropFirst(), radix: 16), let b1 = UInt8(echo[1].dropFirst(), radix: 16) {
            s.edl = Int(b0 & 0x0F); s.songEchoByte1 = Int(b1)
        }
        let events = timeline.tracks.flatMap(\.events).sorted { ($0.step, $0.track) < ($1.step, $1.track) }
        for e in events {
            guard case .command(let op, let operands, _) = e.statement else { continue }
            switch op {
            case 0xF2 where s.evol == nil: s.evol = Int(Int8(bitPattern: operands[0])); s.evolItem = e.item
            case 0xF3 where s.evol == nil: s.evol = Int(Int8(bitPattern: operands[1])); s.evolItem = e.item
            case 0xF7 where s.efb == nil: s.efb = Int(Int8(bitPattern: operands[1])); s.efbItem = e.item
            case 0xF8 where s.firSet == nil: s.firSet = Int(operands[1] & 3); s.firItem = e.item
            default: break
            }
        }
        for t in timeline.tracks where t.stop != "none" {
            let first = t.notes.first?.start ?? t.endStep
            var on = false
            for e in t.events where e.step <= first {
                if case .command(let op, _, _) = e.statement, op == 0xD4 || op == 0xD5 { on = op == 0xD4 }
                if case .note = e.statement { break }
            }
            s.eon[t.index] = on
        }
        return s
    }

    /// Magnitude response of a FIR set, in dB, at `points` frequencies from 0
    /// to 16 kHz (the taps are x / 128, as the S-DSP applies them).
    public static func frequencyResponse(_ taps: [Int8], points: Int = 128) -> [(hz: Double, db: Double)] {
        (0..<points).map { k in
            let hz = 16_000.0 * Double(k) / Double(points - 1)
            let w = 2 * Double.pi * hz / 32_000
            var re = 0.0, im = 0.0
            for (n, c) in taps.enumerated() { re += Double(c) / 128 * cos(w * Double(n)); im -= Double(c) / 128 * sin(w * Double(n)) }
            return (hz, 20 * log10(max(1e-6, (re * re + im * im).squareRoot())))
        }
    }

    /// The echo's impulse response (no voice output, only the echo path):
    /// an impulse enters the buffer, comes back through the FIR every
    /// EDL x 16 ms with feedback EFB / 128, and leaves at EVOL / 128. A
    /// floating-point model of the S-DSP's integer path; 32 kHz samples.
    public static func impulseResponse(taps: [Int8], edl: Int, efb: Int, evol: Int, samples: Int = 32_000) -> [Double] {
        let delay = max(1, edl) * 512
        var buffer = [Double](repeating: 0, count: delay), history = [Double](repeating: 0, count: 8)
        var out = [Double](repeating: 0, count: samples), position = 0, h = 0
        for n in 0..<samples {
            history[h] = buffer[position]                       // the oldest buffered sample
            var fir = 0.0
            for k in 0..<8 { fir += Double(taps[k]) / 128 * history[(h + 1 + k) & 7] }
            h = (h + 1) & 7
            out[n] = fir * Double(evol) / 128
            buffer[position] = (n == 0 ? 1 : 0) + fir * Double(efb) / 128
            position = (position + 1) % delay
        }
        return out
    }
}

extension CTSongDocument {
    /// Set the song's echo delay (0-15) in its @echo row, keeping byte 1
    /// (`byte1` when the listing has no @echo yet).
    public mutating func setEchoDelay(_ edl: Int, byte1: UInt8 = 0) throws {
        guard (0...15).contains(edl) else { throw CTSongError("the echo delay is 0-15") }
        var b0: UInt8 = 0, b1 = byte1
        if let echo = directive("@echo"), echo.count == 2,
           let x = UInt8(echo[0].dropFirst(), radix: 16), let y = UInt8(echo[1].dropFirst(), radix: 16) { b0 = x; b1 = y }
        setDirective("@echo", String(format: "$%02X $%02X", (b0 & 0xF0) | UInt8(edl), b1))
    }

    /// Set the first echo_volume, efb_fade or fir statement (`item` from
    /// `CTSongEcho.Settings`) to `value`, keeping a fade's steps; with no such
    /// statement, an immediate one goes at the start of the first track.
    public mutating func setEcho(_ name: String, item: Int?, value: UInt8) throws {
        if let item, case .command(let op, let operands, _)? = statement(item) {
            let new: [UInt8] = operands.count == 2 ? [operands[0], value] : [value]
            replace(item..<(item + 1), with: [.command(op, operands: new, target: nil)])
            return
        }
        let statement: CTSongStatement
        switch name {
        case "echo_volume": statement = .command("echo_volume", value)
        case "efb_fade": statement = .command("efb_fade", 0, value)
        case "fir": statement = .command("fir", 0, value & 3)
        default: throw CTSongError("\(name) is not an echo setting")
        }
        try insertAtTrackStart(0, statement)
    }

    /// Echo on or off for a track from its start: its first echo_on/echo_off
    /// statement changes, or one is put at its start.
    public mutating func setTrackEcho(_ track: CTSongTimeline.Track, on: Bool) throws {
        let op: UInt8 = on ? 0xD4 : 0xD5
        if let e = track.events.first(where: { if case .command(let o, _, _) = $0.statement { return o == 0xD4 || o == 0xD5 } else { return false } }) {
            replace(e.item..<(e.item + 1), with: [.command(op, operands: [], target: nil)])
        } else {
            try insertAtTrackStart(track.index, .command(op, operands: [], target: nil))
        }
    }

    mutating func insertAtTrackStart(_ track: Int, _ statement: CTSongStatement) throws {
        guard let label = trackLabels[track] ?? (track == 0 ? trackLabels.compactMap({ $0 }).first : nil),
              let at = labels[label] else { throw CTSongError("track \(track) has no entry") }
        items.insert(.statement(statement, raw: nil), at: at + 1)
    }
}

/// One instrument of a song: a sample its @samples row loads, as the
/// sequence's `sample $20 + slot` plays it.
public struct CTSongInstrument: Equatable, Sendable, Identifiable {
    public var id: Int { slot }
    public let slot: Int                 // 0-15: sample operand $20 + slot
    public let sample: Int               // Audio_SampleTable number, 1-62 (more when appended)
    /// Audio_SampleParamA (the tuning: Spc_NotePitch) and ParamB (ADSR1, ADSR2).
    public let tuning: UInt16, adsr: UInt16
    /// BRR bytes and the loop's offset in them (Audio_SampleLoop).
    public let length: Int, loopOffset: Int

    /// The instruments of a sample list, with their words from the ROM's
    /// tables (where its code reads them: `CTSampleTables.locate`).
    public static func rack(rom: [UInt8], samples: [Int]) throws -> [CTSongInstrument] {
        guard rom.count == 4_194_304 else { throw CTSongError("expected a 4 MiB ROM") }
        let tables = try CTSampleTables.locate(rom)
        return try samples.enumerated().map { slot, n in
            let e = try tables.entry(rom, n)
            return .init(slot: slot, sample: n, tuning: UInt16(e.tuning), adsr: UInt16(e.adsr), length: e.length,
                         loopOffset: e.loopOffset)
        }
    }

    /// Where a song load puts its first sample: after boot block 2 at $4700
    /// (Audio_Boot); samples follow one another up to the echo buffer.
    public static func sampleAreaStart(rom: [UInt8]) -> Int {
        (0x4700 + (Int(rom[0x0740B4]) | Int(rom[0x0740B5]) << 8)) & 0xFFFF
    }

    /// The pitch factor the tuning gives (Spc_NotePitch, fine tune 0):
    /// 1 + t / 256 for a low byte t below $80, t / 256 from $80 up, and
    /// the high byte h adds about h / 65536 of it.
    public var pitchFactor: Double {
        let t = Double(tuning & 0xFF), h = Double(tuning >> 8)
        let base = tuning & 0x80 != 0 ? t / 256 : 1 + t / 256
        return base * (1 + h / 65536)
    }

    /// ADSR fields: enabled, attack 0-15, decay 0-7, sustain level 0-7, sustain rate 0-31.
    public var envelope: (on: Bool, attack: Int, decay: Int, sustainLevel: Int, sustainRate: Int) {
        let a1 = Int(adsr & 0xFF), a2 = Int(adsr >> 8)
        return (a1 & 0x80 != 0, a1 & 0x0F, a1 >> 4 & 7, a2 >> 5, a2 & 0x1F)
    }

    /// A listing that plays `number` (a driver note number) on this
    /// instrument for `steps`, with the song's tables (so the load sends the
    /// same samples): one track, then the end.
    public static func audition(slot: Int, number: Int, steps: Int = 96, tables: CTSongTables) -> String {
        // With transpose 10, octave o and index i sound number 12 o + i.
        let n = max(0, min(number, 0xFF)), octave = n / 12, semitone = n % 12
        let tracks = (0..<16).map { "@track \($0 < 8 ? "A" : "B") \($0 % 8) \($0 == 0 ? "AUDITION" : "-")" }
        let body = ["AUDITION:", "    tempo $40", "    volume $7F", "    pan $40",
                    String(format: "    sample $%02X", 0x20 + slot), String(format: "    octave $%02X", octave),
                    "    transpose $0A"]
            + (try! CTSongDocument.run(.note(semitone: semitone, steps: 3), steps: steps)).map(\.text)
            + ["    rest 96", "    end"]
        return (["; audition", "@origin $1000", "@notrack $FFFF"] + CTSongListing.renderTables(tables) + tracks + body)
            .joined(separator: "\n") + "\n"
    }
}
