// Standard MIDI files to `ct-song/1` listings (docs/music_tracker.md, "MIDI
// import"): channels become the driver's 8 song voices, times are quantized
// to song steps and written with Spc_DurationTable lengths (ties where one
// length is not enough), notes become octave + index, programs become the
// project's samples through an explicit table, and tempo becomes the driver's
// tempo byte. The result fits the song budgets or the import is refused.
import Foundation

/// A Standard MIDI File, read as its channel events in time order.
public struct CTMIDIFile: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case noteOn(channel: Int, key: Int, velocity: Int)
        case noteOff(channel: Int, key: Int)
        case program(channel: Int, program: Int)
        /// Microseconds per quarter note (meta $51).
        case tempo(Int)
    }

    public struct Event: Equatable, Sendable {
        public let tick: Int
        public let kind: Kind
        public init(tick: Int, kind: Kind) { self.tick = tick; self.kind = kind }
    }

    public let format: Int
    /// Ticks per quarter note.
    public let division: Int
    /// All tracks' events merged by tick; in one tick, offs, then programs and tempos, then ons.
    public let events: [Event]

    public init(format: Int, division: Int, events: [Event]) {
        self.format = format; self.division = division
        func rank(_ k: Kind) -> Int {
            switch k {
            case .noteOff, .noteOn(_, _, 0): return 0
            case .program, .tempo: return 1
            case .noteOn: return 2
            }
        }
        // Compared field by field: CI's older type checker (Xcode 26.6) struggles with tuple comparisons in closures.
        func before(_ a: (offset: Int, element: Event), _ b: (offset: Int, element: Event)) -> Bool {
            if a.element.tick != b.element.tick { return a.element.tick < b.element.tick }
            let ra: Int = rank(a.element.kind), rb: Int = rank(b.element.kind)
            if ra != rb { return ra < rb }
            return a.offset < b.offset
        }
        self.events = events.enumerated().sorted(by: before).map(\.element)
    }

    /// Read an SMF (format 0 or 1, ticks per quarter). Note-on with
    /// velocity 0 is a note-off; system exclusive and other meta events are skipped.
    public init(bytes: [UInt8]) throws {
        func fail(_ m: String) -> CTSongError { CTSongError("MIDI: \(m)") }
        var p = 0
        func u32(_ at: Int) -> Int {
            var value = 0
            for k in 0..<4 { value = value << 8 | Int(bytes[at + k]) }
            return value
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) << 8 | Int(bytes[at + 1]) }
        let magic: [UInt8] = Array("MThd".utf8)
        guard bytes.count >= 14, Array(bytes[0..<4]) == magic, u32(4) >= 6 else { throw fail("not a Standard MIDI File") }
        let format = u16(8), count = u16(10), division = u16(12)
        guard format <= 1 else { throw fail("format \(format) files are not read (0 and 1 are)") }
        guard division & 0x8000 == 0, division > 0 else { throw fail("SMPTE time division is not read (ticks per quarter is)") }
        p = 8 + u32(4)
        var events: [Event] = []
        for t in 0..<count {
            guard p + 8 <= bytes.count, Array(bytes[p..<(p + 4)]) == Array("MTrk".utf8) else { throw fail("track \(t) has no MTrk chunk") }
            let end = p + 8 + u32(p + 4)
            guard end <= bytes.count else { throw fail("track \(t) runs past the file") }
            p += 8
            var tick = 0, status = 0
            func byte() throws -> Int {
                guard p < end else { throw fail("track \(t) ends inside an event") }
                defer { p += 1 }
                return Int(bytes[p])
            }
            func varlen() throws -> Int {
                var v = 0
                for _ in 0..<4 {
                    let b = try byte()
                    v = v << 7 | b & 0x7F
                    if b & 0x80 == 0 { return v }
                }
                throw fail("track \(t): a variable-length number is longer than 4 bytes")
            }
            while p < end {
                tick += try varlen()
                var b = try byte()
                if b == 0xFF {
                    let type = try byte(), length = try varlen()
                    guard p + length <= end else { throw fail("track \(t): a meta event runs past the track") }
                    if type == 0x51 && length == 3 { events.append(.init(tick: tick, kind: .tempo(Int(bytes[p]) << 16 | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2])))) }
                    p += length
                    if type == 0x2F { break }
                    continue
                }
                if b == 0xF0 || b == 0xF7 {
                    let length = try varlen()
                    p += length
                    continue
                }
                var first: Int
                if b & 0x80 != 0 { status = b; first = try byte() }
                else {
                    guard status != 0 else { throw fail("track \(t): running status before any status byte") }
                    first = b
                }
                b = status
                let channel = b & 0x0F
                switch b & 0xF0 {
                case 0x80: _ = try byte(); events.append(.init(tick: tick, kind: .noteOff(channel: channel, key: first)))
                case 0x90:
                    let v = try byte()
                    events.append(.init(tick: tick, kind: v == 0 ? .noteOff(channel: channel, key: first)
                                                              : .noteOn(channel: channel, key: first, velocity: v)))
                case 0xA0, 0xB0, 0xE0: _ = try byte()
                case 0xC0: events.append(.init(tick: tick, kind: .program(channel: channel, program: first)))
                case 0xD0: break
                default: throw fail(String(format: "track %d: status $%02X", t, b))
                }
            }
            p = end
        }
        self.init(format: format, division: division, events: events)
    }

    /// A format 1 file with one track per entry (tempo events go where they
    /// are given). The tests' and the verifier's synthetic files are written so.
    public static func write(division: Int, tracks: [[Event]]) -> [UInt8] {
        func be(_ v: Int, _ n: Int) -> [UInt8] {
            var out: [UInt8] = []
            for i in (0..<n).reversed() {
                let shifted: Int = v >> (8 * i)
                out.append(UInt8(shifted & 0xFF))
            }
            return out
        }
        func varlen(_ v: Int) -> [UInt8] {
            var out = [UInt8(v & 0x7F)], x = v >> 7
            while x > 0 { out.insert(UInt8(x & 0x7F | 0x80), at: 0); x >>= 7 }
            return out
        }
        var file = Array("MThd".utf8) + be(6, 4) + be(1, 2) + be(tracks.count, 2) + be(division, 2)
        for track in tracks {
            var body: [UInt8] = [], tick = 0
            for e in track.sorted(by: { $0.tick < $1.tick }) {
                body += varlen(e.tick - tick); tick = e.tick
                switch e.kind {
                case .noteOn(let c, let k, let v): body += [UInt8(0x90 | c), UInt8(k), UInt8(v)]
                case .noteOff(let c, let k): body += [UInt8(0x80 | c), UInt8(k), 0]
                case .program(let c, let p): body += [UInt8(0xC0 | c), UInt8(p)]
                case .tempo(let us): body += [0xFF, 0x51, 3] + be(us, 3)
                }
            }
            body += [0, 0xFF, 0x2F, 0]
            file += Array("MTrk".utf8) + be(body.count, 4) + body
        }
        return file
    }
}

public enum CTMIDIImport {
    /// Song steps in a quarter note: Spc_DurationTable's 96 is a whole note,
    /// 24 a quarter and 3 a 32nd (the template's bars are 96 steps).
    public static let stepsPerQuarter = 24
    /// The MIDI channel General MIDI keeps for percussion (10, 0-based 9).
    public static let percussionChannel = 9

    public struct DrumPad: Codable, Equatable, Sendable {
        /// The channel-10 key this pad plays, the sample number, the note the driver plays it at, and its pan ($80: the track's).
        public var key: Int, sample: Int, note: Int, pan: Int
        public init(key: Int, sample: Int, note: Int = CTSampleTuning.defaultRoot, pan: Int = 0x80) {
            self.key = key; self.sample = sample; self.note = note; self.pan = pan
        }
    }

    public struct Options: Codable, Equatable, Sendable {
        /// MIDI program (0-127) to sample number (1-255: the ROM's, or 63 on for appended project samples).
        public var programs: [Int: Int] = [:]
        /// The sample for programs the table leaves out (nil: they are refused).
        public var defaultSample: Int?
        /// Notes start and end on multiples of this many steps (3 or more).
        public var grid = 3
        /// Semitones added to every key; the driver's note number is key + transpose.
        public var transpose = 0
        /// Channel-10 keys to drum pads (at most 12): the channel then plays in drum mode. Empty: it is a melodic channel.
        public var drums: [DrumPad] = []
        public var volume = 0x60, edl = 0
        /// The @echo row's byte 1, the song volume (!Spc_Unk4D; 0 is silent).
        public var songVolume = 0xFF
        /// The tracks jump back to their start at the end (else they end).
        public var loop = true
        public init() {}
    }

    public struct Report: Codable, Equatable, Sendable {
        public struct Voice: Codable, Equatable, Sendable {
            public let voice: Int, channel: Int
            public let notes: Int, drums: Bool
            /// Notes dropped from chords (the voice keeps the highest of notes that start together) and notes cut short by the next.
            public let droppedFromChords: Int, shortened: Int
            public let lowest: Int?, highest: Int?
        }
        public struct Program: Codable, Equatable, Sendable {
            public let program: Int, sample: Int, slot: Int
            public let channels: [Int]
        }
        public struct Tempo: Codable, Equatable, Sendable {
            public let step: Int
            public let bpm: Double
            /// The `tempo` operand, the driver's tempo it gives (t + t x 20 / 256) and the BPM that plays.
            public let byte: Int, driverTempo: Int
            public let playedBPM: Double
            public var errorPercent: Double { 100 * (playedBPM - bpm) / bpm }
        }
        public var format = "ct-midi-import/1"
        public let division: Int, grid: Int
        public let voices: [Voice]
        public let programs: [Program]
        public let drumKit: [Int]?
        public let tempo: [Tempo]
        public let samples: [Int]
        /// Quantization: notes kept, and the largest and mean distance of a start or end from its exact step.
        public let notes: Int
        public let maxErrorSteps: Double, meanErrorSteps: Double
        /// The largest error at the first tempo, in milliseconds.
        public let maxErrorMilliseconds: Double
        public let steps: Int
        public let sequenceBytes: Int
    }

    /// A note in steps; `snappedEnd` is its end before a chord or the next note cut it.
    struct Note { var start: Int, end: Int, key: Int, program: Int, exactStart: Double, exactEnd: Double, snappedEnd: Int }

    /// The tempo operand whose driver tempo (t + t x 20 / 256, Spc_SeqTempo)
    /// plays `bpm` closest, and that tempo. A pass is 5.25 ms; each adds the
    /// tempo to an 8-bit accumulator and the song steps on its carry
    /// (Spc_StepTracks), so steps per second = tempo / 256 / 0.00525.
    public static func tempoByte(bpm: Double) -> (byte: Int, tempo: Int, bpm: Double) {
        let want: Double = bpm * Double(stepsPerQuarter) / 60 * 256 * CTSongTempoMap.secondsPerPass
        var best = (byte: 1, tempo: 1)
        for t in 1...0xFF {
            let tempo = (t + t * 0x14 / 256) & 0xFF
            guard tempo > 0 else { continue }
            if abs(Double(tempo) - want) < abs(Double(best.tempo) - want) { best = (t, tempo) }
        }
        let played = Double(best.tempo) / 256 / CTSongTempoMap.secondsPerPass * 60 / Double(stepsPerQuarter)
        return (best.byte, best.tempo, played)
    }

    /// Convert `file` to a listing. Throws when it cannot be played as one song:
    /// more than 8 channels, notes out of range, unmapped programs, more than
    /// 16 samples, a tempo past the driver's, or a sequence past $4700.
    public static func convert(_ file: CTMIDIFile, options o: Options, title: String = "imported MIDI") throws -> (listing: String, report: Report) {
        guard o.grid >= 3, o.grid <= 96 else { throw CTSongError("the grid is 3-96 steps") }
        let ticksPerStep = Double(file.division) / Double(stepsPerQuarter)
        func exact(_ tick: Int) -> Double { Double(tick) / ticksPerStep }
        func snap(_ tick: Int) -> Int { Int((exact(tick) / Double(o.grid)).rounded()) * o.grid }
        let drumMode = !o.drums.isEmpty
        guard o.drums.count <= CTDrumKit.padCount else { throw CTSongError("a drum kit has at most 12 pads (\(o.drums.count) keys given)") }

        // Notes per channel, with the program in force at their start.
        var program = [Int](repeating: 0, count: 16)
        var open: [Int: (tick: Int, program: Int)] = [:]          // channel << 7 | key
        var byChannel: [Int: [Note]] = [:]
        var tempos: [(tick: Int, us: Int)] = []
        let lastTick = file.events.last?.tick ?? 0
        func close(_ channel: Int, _ key: Int, at tick: Int) {
            guard let on = open.removeValue(forKey: channel << 7 | key) else { return }
            byChannel[channel, default: []].append(Note(start: snap(on.tick), end: snap(tick), key: key, program: on.program,
                                                        exactStart: exact(on.tick), exactEnd: exact(tick), snappedEnd: snap(tick)))
        }
        for e in file.events {
            switch e.kind {
            case .program(let c, let p): program[c] = p
            case .tempo(let us): tempos.append((e.tick, us))
            case .noteOff(let c, let k): close(c, k, at: e.tick)
            case .noteOn(let c, let k, _):
                close(c, k, at: e.tick)
                open[c << 7 | k] = (e.tick, program[c])
            }
        }
        for (key, on) in open { close(key >> 7, key & 0x7F, at: max(on.tick + 1, lastTick)) }

        let channels = byChannel.keys.sorted()
        guard !channels.isEmpty else { throw CTSongError("the file has no notes") }
        guard channels.count <= 8 else {
            // Built in steps for CI's older type checker (Xcode 26.6).
            let numbers: [String] = channels.map { (c: Int) -> String in String(c + 1) }
            let list: String = numbers.joined(separator: ", ")
            throw CTSongError("the driver plays 8 song voices; this file has notes on \(channels.count) channels: \(list)")
        }

        // One note at a time per voice: the highest of notes that start together, each cut at the next's start.
        var voices: [(channel: Int, notes: [Note], dropped: Int, shortened: Int)] = []
        for c in channels {
            let sorted = byChannel[c]!.sorted { ($0.start, -$0.key) < ($1.start, -$1.key) }
            var kept: [Note] = [], dropped = 0, shortened = 0
            for n in sorted {
                if let last = kept.last, last.start == n.start { dropped += 1; continue }
                if let last = kept.last, last.end > n.start { kept[kept.count - 1].end = n.start; shortened += 1 }
                var note = n
                note.end = max(note.end, note.start + o.grid)
                kept.append(note)
            }
            voices.append((c, kept, dropped, shortened))
        }

        // Keys to driver notes, programs to samples, channel-10 keys to pads.
        var outOfRange: Set<Int> = [], unmapped: Set<Int> = [], unmappedKeys: Set<Int> = []
        var samples: [Int] = [], programRows: [Int: (sample: Int, channels: Set<Int>)] = [:]
        func slot(_ sample: Int) -> Int {
            if let k = samples.firstIndex(of: sample) { return k }
            samples.append(sample); return samples.count - 1
        }
        var padOfKey: [Int: Int] = [:]
        for (k, d) in o.drums.enumerated() { padOfKey[d.key] = k }
        let order = voices.flatMap { v in v.notes.map { (v.channel, $0) } }.sorted { ($0.1.start, $0.0) < ($1.1.start, $1.0) }
        for (c, n) in order {
            if drumMode && c == percussionChannel {
                guard let pad = padOfKey[n.key] else { unmappedKeys.insert(n.key); continue }
                _ = slot(o.drums[pad].sample)
                continue
            }
            if !CTDrumKit.noteRange.contains(n.key + o.transpose) { outOfRange.insert(n.key) }
            guard let s = o.programs[n.program] ?? o.defaultSample else { unmapped.insert(n.program); continue }
            _ = slot(s)
            programRows[n.program, default: (s, [])].channels.insert(c + 1)
        }
        for d in o.drums where !samples.contains(d.sample) { _ = slot(d.sample) }
        if !unmapped.isEmpty {
            throw CTSongError("programs " + unmapped.sorted().map(String.init).joined(separator: ", ")
                              + " have no sample: map each one in the program table (music import-midi --programs P:S,...) or give a default sample")
        }
        if !unmappedKeys.isEmpty {
            throw CTSongError("channel 10 keys " + unmappedKeys.sorted().map(String.init).joined(separator: ", ") + " have no drum pad")
        }
        if !outOfRange.isEmpty {
            throw CTSongError("keys " + outOfRange.sorted().map(String.init).joined(separator: ", ")
                              + " (with transpose \(o.transpose)) are outside the driver's notes 0-95 (C0-B7)")
        }
        guard samples.count <= 16, samples.allSatisfy({ (1...CTSongISA.sampleNumberMax).contains($0) }) else {
            throw CTSongError("the song uses \(samples.count) samples (\(samples.map(String.init).joined(separator: ", "))); "
                              + "a song lists at most 16, numbered 1-\(CTSongISA.sampleNumberMax)")
        }
        var kit: CTDrumKit? = nil
        if drumMode {
            var pads: [CTDrumKit.Pad] = []
            for k in 0..<CTDrumKit.padCount {
                guard o.drums.indices.contains(k) else { pads.append(CTDrumKit.Pad()); continue }
                let d: DrumPad = o.drums[k]
                let sample: Int = CTDrumKit.firstEntry + slot(d.sample)
                pads.append(CTDrumKit.Pad(sample: sample, note: d.note, pan: d.pan))
            }
            kit = try CTDrumKit(pads: pads)
        }
        if let kit, !kit.problems(listed: samples.count).isEmpty {
            throw CTSongError(kit.problems(listed: samples.count).joined(separator: "; "))
        }

        // The length: every track ends at the same step, a whole number of 96-step bars.
        var lastEnd = 0
        for v in voices { for n in v.notes { lastEnd = max(lastEnd, n.end) } }
        let total = max(96, (lastEnd + 95) / 96 * 96)

        // Tempo: the first at step 0 (120 BPM when the file gives none there); none after the end.
        var tempoRows: [Report.Tempo] = []
        if tempos.first.map({ snap($0.tick) > 0 }) ?? true { tempos.insert((0, 500_000), at: 0) }
        for (tick, us) in tempos where snap(tick) < total {
            let step = snap(tick), bpm = 60_000_000 / Double(us)
            let t = tempoByte(bpm: bpm)
            let row = Report.Tempo(step: step, bpm: bpm, byte: t.byte, driverTempo: t.tempo, playedBPM: t.bpm)
            guard abs(row.errorPercent) < 5 else {
                throw CTSongError(String(format: "%.1f BPM is past the driver's tempo range (%.1f-%.1f BPM)", bpm,
                                         tempoByte(bpm: 1).bpm, tempoByte(bpm: 1000).bpm))
            }
            if let last = tempoRows.last, last.step == step { tempoRows[tempoRows.count - 1] = row } else { tempoRows.append(row) }
        }

        // The listing.
        func hex(_ v: Int) -> String { String(format: "$%02X", v & 0xFF) }
        var lines = ["; \(title)", "; ct-song/1 — imported from a MIDI file; see macos_studio/docs/music_tracker.md",
                     "@origin $2000", "@notrack $FFFF",
                     "@samples " + samples.map(String.init).joined(separator: " "), "@echo \(hex(o.edl)) \(hex(o.songVolume))"]
        lines += (kit ?? .empty).listingLines
        for i in 0..<16 { lines.append("@track \(i < 8 ? "A" : "B") \(i % 8) " + (i < voices.count ? "TRACK\(i)" : "-")) }
        for (i, v) in voices.enumerated() {
            let drums = drumMode && v.channel == percussionChannel
            lines.append("TRACK\(i):")
            if i == 0 { lines += ["    echo_volume $00", "    efb_fade $00 $00", "    fir $00 $00"] }
            lines += ["    volume \(hex(o.volume))", "    pan $40", "    transpose $0A"]
            if drums { lines.append("    drums_on") }
            lines.append("LOOP\(i):")
            // Commands at a step: the tempo changes (track 0), then the sample and octave a note needs.
            var tempoAt: [Int: Report.Tempo] = [:]
            if i == 0 { for t in tempoRows { tempoAt[t.step] = t } }
            var events: [(step: Int, note: Note?)] = v.notes.map { ($0.start, $0) }
            for step in tempoAt.keys where !v.notes.contains(where: { $0.start == step }) { events.append((step, nil)) }
            events.sort { $0.step < $1.step }
            var now = 0, sample: Int?, octave: Int?
            // Rests, notes and ties up to `to`, with tempo changes inside them split out.
            func fill(_ first: CTSongStatement, from: Int, to: Int) throws {
                var at = from, head = first
                let inside: [Int] = tempoAt.keys.filter { (k: Int) -> Bool in k > from && k < to }
                var cuts: [Int] = inside.sorted()
                cuts.append(to)
                for cut in cuts {
                    lines += try CTSongDocument.run(head, steps: cut - at).map(\.text)
                    if cut < to, let t = tempoAt[cut] { lines.append("    tempo \(hex(t.byte))") }
                    at = cut
                    if !head.isRest { head = .tie(steps: 3) }
                }
            }
            for (step, note) in events {
                if step > now { try fill(.rest(steps: 3), from: now, to: step); now = step }
                if let t = tempoAt[step], step == now { lines.append("    tempo \(hex(t.byte))"); tempoAt[step] = nil }
                guard let n = note, n.start >= now else { continue }
                let index: Int
                if drums {
                    index = padOfKey[n.key]!
                } else {
                    let s = slot(o.programs[n.program] ?? o.defaultSample!)
                    if sample != s { lines.append("    sample \(hex(CTDrumKit.firstEntry + s))"); sample = s }
                    let number = n.key + o.transpose
                    if octave != number / 12 { lines.append("    octave \(hex(number / 12))"); octave = number / 12 }
                    index = number % 12
                }
                try fill(.note(semitone: index, steps: 3), from: n.start, to: n.end)
                now = n.end
            }
            if total > now { try fill(.rest(steps: 3), from: now, to: total) }
            lines.append(o.loop ? "    jump ->LOOP\(i)" : "    end")
        }
        let text = lines.joined(separator: "\n") + "\n"
        let (data, _) = try CTSongListing.assembleSong(text)
        guard CTSongISA.fits(data.count) else {
            throw CTSongError("the song is \(data.count) sequence bytes; the most that loads below $4700 is \(CTSongISA.maxLength)")
        }

        var errors: [Double] = []
        for v in voices { for n in v.notes { errors += [abs(Double(n.start) - n.exactStart), abs(Double(n.snappedEnd) - n.exactEnd)] } }
        let maxError = errors.max() ?? 0
        let first = tempoRows.first!
        // The report's parts as typed lets: one initializer with these closures inline was too much
        // for CI's older type checker (Xcode 26.6).
        var voiceRows: [Report.Voice] = []
        var noteCount = 0
        for (i, v) in voices.enumerated() {
            let keys: [Int] = v.notes.map(\.key)
            let drums: Bool = drumMode && v.channel == percussionChannel
            voiceRows.append(Report.Voice(voice: i, channel: v.channel + 1, notes: v.notes.count, drums: drums,
                                          droppedFromChords: v.dropped, shortened: v.shortened,
                                          lowest: keys.min(), highest: keys.max()))
            noteCount += v.notes.count
        }
        var programList: [Report.Program] = []
        for p in programRows.keys.sorted() {
            guard let row = programRows[p], let at = samples.firstIndex(of: row.sample) else { continue }
            programList.append(Report.Program(program: p, sample: row.sample, slot: at, channels: row.channels.sorted()))
        }
        var kitBytes: [Int]? = nil
        if let kit { kitBytes = kit.bytes.map { (b: UInt8) -> Int in Int(b) } }
        var errorSum: Double = 0
        for e in errors { errorSum += e }
        let meanError: Double = errors.isEmpty ? 0 : errorSum / Double(errors.count)
        let scaled: Double = maxError * 60_000
        let maxMilliseconds: Double = scaled / first.playedBPM / Double(stepsPerQuarter)
        let report = Report(
            division: file.division, grid: o.grid, voices: voiceRows, programs: programList,
            drumKit: kitBytes, tempo: tempoRows, samples: samples, notes: noteCount, maxErrorSteps: maxError,
            meanErrorSteps: meanError, maxErrorMilliseconds: maxMilliseconds,
            steps: total, sequenceBytes: data.count)
        return (text, report)
    }
}

extension CTMIDIImport {
    /// `P:S,...`: MIDI program P (0-127) plays sample number S. Numbers are decimal or `$` hex.
    public static func programTable(_ text: String) throws -> [Int: Int] {
        var out: [Int: Int] = [:]
        for part in text.split(separator: ",") {
            let f = part.split(separator: ":").map { number(String($0)) }
            guard f.count == 2, let p = f[0], let s = f[1], (0...127).contains(p), (1...CTSongISA.sampleNumberMax).contains(s) else {
                throw CTSongError("programs are P:S pairs (program 0-127, sample 1-\(CTSongISA.sampleNumberMax)), not \(part)")
            }
            guard out[p] == nil else { throw CTSongError("program \(p) is mapped twice") }
            out[p] = s
        }
        return out
    }

    /// `KEY:SAMPLE[:NOTE[:PAN]],...`: channel-10 key to a pad, in pad order.
    public static func drumTable(_ text: String) throws -> [DrumPad] {
        // A loop with typed lets for CI's older type checker (Xcode 26.6).
        var pads: [DrumPad] = []
        for part in text.split(separator: ",") {
            let fields: [Int?] = part.split(separator: ":").map { (s: Substring) -> Int? in number(String(s)) }
            let f: [Int] = fields.compactMap { $0 }
            let bytesOK: Bool = f.dropFirst(2).allSatisfy { (v: Int) -> Bool in (0...0xFF).contains(v) }
            guard (2...4).contains(fields.count), f.count == fields.count, (0...127).contains(f[0]),
                  (1...CTSongISA.sampleNumberMax).contains(f[1]), bytesOK else {
                throw CTSongError("drum pads are KEY:SAMPLE[:NOTE[:PAN]] (key 0-127, sample 1-\(CTSongISA.sampleNumberMax), bytes), not \(part)")
            }
            let note: Int = f.count > 2 ? f[2] : CTSampleTuning.defaultRoot
            let pan: Int = f.count > 3 ? f[3] : 0x80
            pads.append(DrumPad(key: f[0], sample: f[1], note: note, pan: pan))
        }
        return pads
    }

    static func number(_ s: String) -> Int? { s.hasPrefix("$") ? Int(s.dropFirst(), radix: 16) : Int(s) }

    /// `convert`, then song `song`'s budget as `rom build` would load it with
    /// the project's rom.samples (`CTProjectSamples.budget`): a song over its
    /// sequence or sample budget, or naming a sample neither the ROM nor
    /// rom.samples has, is refused.
    public static func importSong(_ file: CTMIDIFile, options: Options, rom: [UInt8], project: CTProject, song: Int,
                                  title: String) throws -> (listing: String, report: Report, budget: CTSongBudget) {
        let (text, report) = try convert(file, options: options, title: title)
        let (data, tables) = try CTSongListing.assembleSong(text)
        let budget = try CTProjectSamples.budget(rom: rom, project: project, song: song, data: data, tables: tables)
        if let problem = budget.problem { throw CTSongError(problem) }
        return (text, report, budget)
    }
}
