// A song's drum kit: its AudioRom_SongExtra row (36 bytes), which a song load
// sends to ARAM $F120 (!AudioAram_SongExtra). In drum mode (`drums_on`,
// !Spc_Unk7C), Spc_DrumNote (ChronoRET driver.asm, $0720, MIT) reads a note's
// index i (byte / 14, 0-11) as entry i: byte 3i is the sample
// (Spc_SetTrackSample: the directory entry, with its tuning and ADSR words),
// byte 3i + 1 the note, which goes on like any note (+ the transpose - 10),
// and byte 3i + 2, below $80, the pan (x 2 into !Spc_TrackF280's high byte, as
// `pan` stores it); $80 or more keeps the track's pan. `CTDrumKitTrace`
// checks this against the emulated driver (docs/music_tracker.md).
import Foundation

public struct CTDrumKit: Equatable, Codable, Sendable {
    public static let padCount = 12, size = 36
    /// The first directory entry a song load fills: `sample $20 + n` plays its n-th listed sample.
    public static let firstEntry = 0x20
    /// Driver notes the kit editor offers at transpose $0A (the template's): C0-B7.
    public static let noteRange = 0...95

    public struct Pad: Equatable, Codable, Hashable, Sendable {
        /// The directory entry (SRCN): $20 + n is the song's n-th listed sample; 0 on an unused pad.
        public var sample: Int
        /// The note byte: the driver plays note + transpose - 10.
        public var note: Int
        /// $00-$7F: the track's pan from this pad on ($40 centre); $80-$FF: the track's pan stays.
        public var pan: Int
        public init(sample: Int = 0, note: Int = 0, pan: Int = 0) { self.sample = sample; self.note = note; self.pan = pan }

        /// All three bytes zero: the ROM's kits leave unused pads so.
        public var isEmpty: Bool { sample == 0 && note == 0 && pan == 0 }
        public var keepsPan: Bool { pan >= 0x80 }
        /// The song's sample slot this pad plays (sample - $20), nil below $20.
        public var slot: Int? { sample >= CTDrumKit.firstEntry ? sample - CTDrumKit.firstEntry : nil }
        /// The driver's note number on a track with this transpose byte (Spc_TrackStep: + transpose - 10).
        public func number(transpose: Int = 0x0A) -> Int { (note + transpose - 10) & 0xFF }
        /// !Spc_TrackF280's high byte after the pad (pan x 2), nil when the track keeps its pan.
        public var panRegister: Int? { keepsPan ? nil : pan << 1 & 0xFF }
    }

    public var pads: [Pad]

    public init(pads: [Pad]) throws {
        guard pads.count == Self.padCount else { throw CTSongError("a drum kit has \(Self.padCount) pads") }
        for (k, p) in pads.enumerated() where ![p.sample, p.note, p.pan].allSatisfy({ (0...0xFF).contains($0) }) {
            throw CTSongError("drum \(k): sample, note and pan are bytes")
        }
        self.pads = pads
    }

    public init(bytes: [UInt8]) throws {
        guard bytes.count == Self.size else { throw CTSongError("the drum kit is \(Self.size) bytes") }
        pads = (0..<Self.padCount).map { k in
            Pad(sample: Int(bytes[3 * k]), note: Int(bytes[3 * k + 1]), pan: Int(bytes[3 * k + 2]))
        }
    }

    public static let empty = try! CTDrumKit(bytes: [UInt8](repeating: 0, count: size))

    public var bytes: [UInt8] { pads.flatMap { [UInt8($0.sample), UInt8($0.note), UInt8($0.pan)] } }
    public var isEmpty: Bool { pads.allSatisfy(\.isEmpty) }

    /// The listing's lines for the kit: `@drums none`, or 12 `@drum` lines.
    public var listingLines: [String] { CTSongListing.renderTables(.init(drums: bytes)) }

    /// What the driver would play wrongly, pad by pad: a sample that is not
    /// one of the song's `listed` entries (nil: the list is not known), or a
    /// note outside C0-B7 at transpose $0A.
    public func problems(listed: Int?) -> [String] {
        var out: [String] = []
        for (k, p) in pads.enumerated() where !p.isEmpty {
            if p.sample < Self.firstEntry {
                out.append(String(format: "drum %d: sample $%02X is a directory entry the song load does not set ($20 on)", k, p.sample))
            } else if let listed, p.sample >= Self.firstEntry + listed {
                out.append(String(format: "drum %d: sample $%02X is past the song's %d listed samples ($20-$%02X)",
                                  k, p.sample, listed, Self.firstEntry + max(listed, 1) - 1))
            }
            if !Self.noteRange.contains(p.number()) {
                out.append(String(format: "drum %d: note $%02X is outside C0-B7 (0-95)", k, p.note))
            }
        }
        return out
    }
}

extension CTSongDocument {
    /// The listing's drum kit row, nil when it leaves the ROM's row as it is.
    public var drumKit: CTDrumKit? {
        guard let bytes = tables?.drums else { return nil }
        return try? CTDrumKit(bytes: bytes)
    }

    /// Replace the listing's `@drums` / `@drum` lines with `kit`'s, where the
    /// first of them was (else after `@echo`, `@samples` or `@notrack`).
    public mutating func setDrumKit(_ kit: CTDrumKit) {
        func isKitLine(_ item: Item) -> Bool {
            guard case .text(let l) = item else { return false }
            let head = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            return head == "@drums" || head == "@drum"
        }
        func isLine(_ item: Item, _ name: String) -> Bool {
            guard case .text(let l) = item else { return false }
            return l.split(whereSeparator: { $0 == " " || $0 == "\t" }).first == Substring(name)
        }
        var at = items.firstIndex(where: isKitLine)
        items.removeAll(where: isKitLine)
        for name in ["@echo", "@samples", "@notrack"] where at == nil {
            at = items.firstIndex { isLine($0, name) }.map { (i: Int) -> Int in i + 1 }
        }
        items.insert(contentsOf: kit.listingLines.map { Item.text($0) }, at: at ?? 0)
    }
}

/// The driver's voices at each key-on of a built song: the voice's SRCN, the
/// track's note number (!Spc_TrackF3A0's high byte) and pan byte
/// (!Spc_TrackF280's high byte), read when the KON shadow reaches the S-DSP.
/// Spc_TrackStep writes SRCN (Spc_WriteSample) during the step and the main
/// loop writes KON at the top of the next pass, before any other step.
public enum CTDrumKitTrace {
    public struct KeyOn: Codable, Equatable, Sendable {
        public let step: Int, voice: Int
        public let sample: Int, number: Int, pan: Int
    }

    public struct Result: Encodable, Sendable {
        public let format = "ct-drum-kit-trace/1"
        public let song: Int
        public let steps: Int
        public let keyOns: [KeyOn]
        /// Drum-mode notes the model predicts over the steps, and how many
        /// key-ons agree with them in voice, step, sample, note and pan.
        public let drumNotes: Int, matched: Int
        public let mismatches: [String]
        public var passed: Bool { mismatches.isEmpty && drumNotes == matched }
    }

    // Driver RAM (spc700.inc), per track X = 2 x voice.
    static let trackF3A0 = 0xF3A0, trackF280 = 0xF280

    /// Boot the driver from `clean`, load song `song` of `built` as the
    /// ROM's sender would, and run `steps` song steps.
    public static func keyOns(clean: [UInt8], built: [UInt8], song: Int, steps: Int) throws -> [KeyOn] {
        let plan = try CTSPCTransfer.Plan(rom: built, song: song)
        let (session, load) = try CTSPCTransfer.loadSession(rom: clean, plan: plan, iplROM: nil, limits: .init())
        guard load.passed else { throw CTSongError("song load checks failed") }
        let cpu = session.cpu, bus = session.bus, dsp = session.dsp
        guard bus.ram[Int(CTSongDriverTrace.songStepPC)] == CTSongDriverTrace.songStepOpcode else {
            throw CTSongError("the driver at $0399 is not Spc_StepTracks' song step")
        }
        var out: [KeyOn] = [], step = -1, pass = -1, lastStepPass = 0
        var writes = dsp.registerWrites
        let passLimit = 64 * steps + 512
        while step < steps || pass <= lastStepPass {
            if pass >= passLimit { break }
            let pc = cpu.registers.pc
            if pc == CTSongDriverTrace.passPC { pass += 1 }
            else if pc == CTSongDriverTrace.songStepPC { step += 1; lastStepPass = pass }
            if cpu.stopped { bus.idle() } else { cpu.step() }
            if let fault = bus.fault { throw CTSongError("trace bus fault: \(fault)") }
            guard dsp.registerWrites != writes else { continue }
            writes = dsp.registerWrites
            let kon = dsp.registers[0x4C]
            guard bus.ram[0xF2] & 0x7F == 0x4C, kon != 0, step >= 0, step < steps else { continue }
            for v in 0..<8 where kon & (1 << v) != 0 {
                out.append(.init(step: step, voice: v, sample: Int(dsp.registers[v << 4 | 4]),
                                 number: Int(bus.ram[trackF3A0 + 2 * v + 1]), pan: Int(bus.ram[trackF280 + 2 * v + 1])))
            }
        }
        return out
    }

    /// Compare the driver's key-ons with the model's drum-mode notes (set A)
    /// over the first `steps` - 1 steps: same voice and step, the pad's
    /// sample as SRCN, its note number, and its pan x 2 (or the track's).
    public static func run(clean: [UInt8], built: [UInt8], song: Int, listing: String, steps: Int) throws -> Result {
        let doc = CTSongDocument(listing: listing)
        var options = CTSongTimeline.Options(untilLoop: false, maxSteps: steps)
        options.set = 0
        let timeline = try CTSongTimeline(doc, tables: doc.tables, options: options)
        let romKit = try CTDrumKit(bytes: CTSongTables.rom(built, song: song).drums ?? [])
        let kit = doc.drumKit ?? romKit
        let driver = try keyOns(clean: clean, built: built, song: song, steps: steps)
        let window = steps - 1
        var byKey: [String: KeyOn] = [:]
        for k in driver where k.step < window { byKey["\(k.voice):\(k.step)"] = k }
        var notes = 0, matched = 0, mismatches: [String] = []
        for track in timeline.tracks {
            for n in track.notes where n.drum && n.keyOn && n.start < window {
                notes += 1
                guard let k = byKey["\(track.index):\(n.start)"] else {
                    mismatches.append("voice \(track.index) step \(n.start): no key-on"); continue
                }
                // A pad that keeps the track's pan is not compared: pan fades move it, and the model has none.
                let pan = kit.pads.indices.contains(n.semitone) ? kit.pads[n.semitone].panRegister : nil
                if k.sample == n.sample, k.number == n.number, pan == nil || pan == k.pan { matched += 1 }
                else {
                    mismatches.append(String(format: "voice %d step %d: driver SRCN $%02X note %d pan $%02X, model $%02X %d %@",
                                             track.index, n.start, k.sample, k.number, k.pan, n.sample ?? -1, n.number,
                                             pan.map { String(format: "$%02X", $0) } ?? "-"))
                }
            }
        }
        return Result(song: song, steps: steps, keyOns: driver, drumNotes: notes, matched: matched, mismatches: mismatches)
    }
}
