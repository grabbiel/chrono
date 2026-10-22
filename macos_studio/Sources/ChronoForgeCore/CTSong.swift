// Chrono Trigger SPC700 song sequences (Audio_SongTable data): decode, the
// `ct-song/1` listing and its assembler. The tables and rules are those of the
// sound driver as ChronoRET transcribes it; re_workspace/tools/ct_spc_seq.py is
// the independent Python twin, and the gate compares both on every ROM song.
import Foundation

public struct CTSongError: Error, CustomStringConvertible, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public enum CTSongISA {
    public static let songTablePC = 0x070D18                // Audio_SongTable ($C7:0D18), long pointers
    public static let songCountPC = 0x070AE9                // Audio_SongCount ($C7:0AE9)
    public static let romSongCount = 0x53                   // its value in the US 1.0 ROM
    public static let samplesPC = 0x070E11                  // AudioRom_SongSamples: 16 words per song, 0-ended
    public static let echoPC = 0x07241D                     // AudioRom_SongEcho: a word per song
    public static let drumsPC = 0x071871                    // AudioRom_SongExtra: 36 bytes per song (the drum kit)
    public static let sampleMax = 62                        // Audio_SampleTable entries in the US 1.0 ROM
    /// The sample numbers a listing may name: a built ROM can append to the
    /// table (CTSamplePatch), so the builder checks them against its count.
    public static let sampleNumberMax = 255
    public static let header = 0x24                         // !SpcSong_Data
    public static let songRoom = 0x0F00                     // !Audio_SongRoom: longer songs overwrite the $2F00 block
    public static let songAram = 0x2000, block4700 = 0x4700 // !AudioAram_Song, !AudioAram_Block4700
    public static let firstTie: UInt8 = 0xA8, firstRest: UInt8 = 0xB6, firstCommand: UInt8 = 0xC4

    /// Spc_DurationTable: note lengths in song steps, by byte % 14.
    public static let durations: [Int] = [0xC0, 0x60, 0x40, 0x48, 0x30, 0x20, 0x24, 0x18, 0x10, 0x0C, 0x08, 0x06, 0x04, 0x03]
    /// Spc_SeqOperandCounts, commands $C4-$FF.
    public static let operandCounts: [Int] = [
        1, 2, 1, 2, 2, 3, 0, 3, 0, 2, 0, 1,  0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1,
        1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0,  1, 1, 1, 0, 0, 0, 0, 0, 1, 2, 1, 2,
        1, 3, 2, 2, 2, 1, 3, 0, 0, 1, 0, 0,
    ]
    /// Command names from the handler labels of Spc_SeqCmdTable, $C4-$FF.
    public static let commandNames: [String] = [
        "volume", "volume_fade", "pan", "pan_fade", "pitch_slide", "vibrato", "vibrato_off", "tremolo",
        "tremolo_off", "pan_lfo", "pan_lfo_off", "noise_clock", "noise_on", "noise_off", "pmon_on", "pmon_off",
        "echo_on", "echo_off", "octave", "octave_up", "octave_down", "transpose", "transpose_add", "fine_tune",
        "sample", "attack", "decay", "sustain_level", "sustain_rate", "adsr_reset", "loop_start", "loop_end",
        "legato_on", "null_e5", "unk60_on", "null_e7", "wait", "sfx_track1", "sfx_track2", "end",
        "end_ec", "end_ed", "end_ee", "end_ef", "tempo", "tempo_fade", "echo_volume", "echo_volume_fade",
        "song_volume", "loop_jump", "jump", "efb_fade", "fir", "marker", "branch", "drums_on",
        "drums_off", "volume_scale", "end_fe", "end_ff",
    ]
    public static let noteNames = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
    /// Commands with an address operand, and the index of its low byte.
    public static let jumpOperand: [UInt8: Int] = [0xF6: 0, 0xF5: 1, 0xFA: 1]
    /// Commands after which a track does not go on to the next byte.
    public static let stops: Set<UInt8> = [0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xFE, 0xFF, 0xF6, 0xE9, 0xEA]

    public static func length(of byte: UInt8) -> Int {
        byte >= firstCommand ? 1 + operandCounts[Int(byte - firstCommand)] : 1
    }
    /// Audio_SendSongData writes length / 3 + 1 triples from $2000; they must stop before $4700.
    public static func fits(_ length: Int) -> Bool { length >= 0 && songAram + 3 * (length / 3 + 1) <= block4700 }
    public static let maxLength = (block4700 - songAram) / 3 * 3 - 1
}

/// A song's rows of the per-song tables; nil leaves that row as it is.
public struct CTSongTables: Codable, Equatable, Sendable {
    public var samples: [Int]?                              // sample numbers 1-62, at most 16
    public var echo: [UInt8]?                               // 2 bytes: echo delay (low nibble), Spc_Unk4D
    public var drums: [UInt8]?                              // 36 bytes: 12 x sample, note, pan
    public init(samples: [Int]? = nil, echo: [UInt8]? = nil, drums: [UInt8]? = nil) {
        self.samples = samples; self.echo = echo; self.drums = drums
    }

    public static func rom(_ rom: [UInt8], song i: Int) -> CTSongTables {
        let words = (0..<16).map { k in Int(rom[CTSongISA.samplesPC + 32 * i + 2 * k]) | Int(rom[CTSongISA.samplesPC + 32 * i + 2 * k + 1]) << 8 }
        return .init(samples: Array(words.prefix { $0 != 0 }),
                     echo: Array(rom[(CTSongISA.echoPC + 2 * i)..<(CTSongISA.echoPC + 2 * i + 2)]),
                     drums: Array(rom[(CTSongISA.drumsPC + 36 * i)..<(CTSongISA.drumsPC + 36 * i + 36)]))
    }

    /// The table rows this sets for song `i`: (ROM offset, bytes).
    public func rows(song i: Int) -> [(pc: Int, bytes: [UInt8])] {
        var rows: [(pc: Int, bytes: [UInt8])] = []
        if let samples {
            let bytes = samples.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
            rows.append((CTSongISA.samplesPC + 32 * i, bytes + [UInt8](repeating: 0, count: 32 - bytes.count)))
        }
        if let echo { rows.append((CTSongISA.echoPC + 2 * i, echo)) }
        if let drums { rows.append((CTSongISA.drumsPC + 36 * i, drums)) }
        return rows
    }

    public func validate() throws {
        if let samples, samples.count > 16 || samples.contains(where: { !(1...CTSongISA.sampleNumberMax).contains($0) }) {
            throw CTSongError("@samples takes at most 16 sample numbers 1-\(CTSongISA.sampleNumberMax)")
        }
        if let echo, echo.count != 2 { throw CTSongError("@echo takes 2 bytes") }
        if let drums, drums.count != 36 { throw CTSongError("the drum kit is 36 bytes") }
    }
}

/// One song's data: the bytes after its u16 length, as loaded to ARAM $2000.
public struct CTSong: Equatable, Sendable {
    public let data: [UInt8]
    public var origin: Int { Int(data[0]) | Int(data[1]) << 8 }
    public var noTrack: Int { Int(data[2]) | Int(data[3]) << 8 }
    public var tracks: [Int] { (0..<16).map { Int(data[4 + 2 * $0]) | Int(data[5 + 2 * $0]) << 8 } }

    public init(data: [UInt8]) throws {
        guard data.count >= CTSongISA.header else { throw CTSongError("song shorter than its \(CTSongISA.header)-byte header") }
        self.data = data
    }

    /// Song offset of an address in the origin's space (the driver's 16-bit move).
    public func offset(_ address: Int) -> Int { ((address - origin) & 0xFFFF) + CTSongISA.header }
    public func address(_ offset: Int) -> Int { (origin + offset - CTSongISA.header) & 0xFFFF }

    func target(at o: Int) -> Int? {
        guard let k = CTSongISA.jumpOperand[data[o]] else { return nil }
        return offset(Int(data[o + 1 + k]) | Int(data[o + 2 + k]) << 8)
    }

    /// Every statement the tracks reach (offset -> length), following jumps.
    public func walk() throws -> [Int: Int] {
        var seen: [Int: Int] = [:]
        var work = tracks.filter { $0 != noTrack }.map(offset)
        while var o = work.popLast() {
            while seen[o] == nil {
                guard (CTSongISA.header..<data.count).contains(o) else {
                    throw CTSongError(String(format: "a track reaches $%04X, outside the song", address(o)))
                }
                let n = CTSongISA.length(of: data[o])
                guard o + n <= data.count else {
                    throw CTSongError(String(format: "the command at $%04X runs past the end", address(o)))
                }
                seen[o] = n
                if let t = target(at: o) { work.append(t) }
                if CTSongISA.stops.contains(data[o]) { break }
                o += n
            }
        }
        let starts = seen.keys.sorted()
        for (a, b) in zip(starts, starts.dropFirst()) where a + seen[a]! > b {
            throw CTSongError(String(format: "$%04X is reached inside the command at $%04X", address(b), address(a)))
        }
        return seen
    }

    /// The songs of a ROM: (index, long pointer, file offset, data).
    public static func romSongs(_ rom: [UInt8]) throws -> [(index: Int, pointer: Int, pc: Int, data: [UInt8])] {
        guard rom.count > CTSongISA.songTablePC + 3 * 256 else { throw CTSongError("ROM too small") }
        return try (0..<Int(rom[CTSongISA.songCountPC])).map { i in
            let at = CTSongISA.songTablePC + 3 * i
            let pointer = Int(rom[at]) | Int(rom[at + 1]) << 8 | Int(rom[at + 2]) << 16
            let pc = (pointer >> 16 & 0x3F) << 16 | pointer & 0xFFFF
            guard pc + 2 <= rom.count else { throw CTSongError("song \(i) points outside the ROM") }
            let n = Int(rom[pc]) | Int(rom[pc + 1]) << 8
            guard pc + 2 + n <= rom.count else { throw CTSongError("song \(i) runs past the ROM") }
            return (i, pointer, pc, Array(rom[(pc + 2)..<(pc + 2 + n)]))
        }
    }
}

/// Text form (`ct-song/1`), one statement per line:
///
///     @origin $8B18           (the header's origin word: addresses below are in its space)
///     @notrack $8FB3          (the word that marks an unused track)
///     @track A 0 L_8B18       (16 lines: sets A and B, tracks 0-7; `-` for none)
///     L_8B18:
///         tempo $46
///         note C# 48          (semitone of the octave base, length in steps)
///         tie 24
///         rest 96
///         jump ->L_8B18
///     @bytes EB               (bytes no track reaches)
public enum CTSongListing {
    public static func label(_ address: Int) -> String { String(format: "L_%04X", address) }

    static func renderTables(_ tables: CTSongTables) -> [String] {
        var lines: [String] = []
        if let samples = tables.samples {
            lines.append("@samples " + (samples.isEmpty ? "none" : samples.map(String.init).joined(separator: " ")))
        }
        if let echo = tables.echo { lines.append("@echo " + echo.map { String(format: "$%02X", $0) }.joined(separator: " ")) }
        if let drums = tables.drums {
            if drums.allSatisfy({ $0 == 0 }) { lines.append("@drums none") }
            else {
                for k in 0..<12 {
                    lines.append("@drum \(k) " + drums[(3 * k)..<(3 * k + 3)].map { String(format: "$%02X", $0) }.joined(separator: " "))
                }
            }
        }
        return lines
    }

    public static func render(_ song: CTSong, title: String? = nil, tables: CTSongTables = .init()) throws -> String {
        let seen = try song.walk()
        var targets = Set(song.tracks.filter { $0 != song.noTrack }.map(song.offset))
        for o in seen.keys { if let t = song.target(at: o) { targets.insert(t) } }
        var lines: [String] = title.map { ["; \($0)"] } ?? []
        lines += ["; ct-song/1 — CT SPC700 song sequence; see macos_studio/docs/music_sequences.md",
                  String(format: "@origin $%04X", song.origin), String(format: "@notrack $%04X", song.noTrack)]
        lines += renderTables(tables)
        for (i, a) in song.tracks.enumerated() {
            lines.append("@track \(i < 8 ? "A" : "B") \(i % 8) " + (a == song.noTrack ? "-" : label(a)))
        }
        let data = song.data
        var o = CTSongISA.header
        while o < data.count {
            if targets.contains(o) { lines.append(label(song.address(o)) + ":") }
            if let k = seen[o] {
                let b = data[o]
                var words: [String]
                if b < CTSongISA.firstCommand {
                    let kind = b < CTSongISA.firstTie ? "note \(CTSongISA.noteNames[Int(b) / 14])"
                        : b < CTSongISA.firstRest ? "tie" : "rest"
                    words = [kind, String(CTSongISA.durations[Int(b) % 14])]
                } else {
                    var ops = data[(o + 1)..<(o + k)].map { String(format: "$%02X", $0) }
                    if let j = CTSongISA.jumpOperand[b] {
                        ops.replaceSubrange(j..<(j + 2), with: ["->" + label(Int(data[o + 1 + j]) | Int(data[o + 2 + j]) << 8)])
                    }
                    words = [CTSongISA.commandNames[Int(b - CTSongISA.firstCommand)]] + ops
                }
                lines.append("    " + words.joined(separator: " "))
                o += k
                continue
            }
            var z = o + 1
            while z < data.count && seen[z] == nil && !targets.contains(z) { z += 1 }
            for s in stride(from: o, to: z, by: 16) {
                lines.append("@bytes " + data[s..<min(s + 16, z)].map { String(format: "%02X", $0) }.joined(separator: " "))
            }
            o = z
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func decimal(_ s: Substring) -> Int? {
        s.isEmpty || s.count > 4 || !s.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int(s)
    }

    private enum Operand { case byte(UInt8), label(String) }
    private enum Item { case label(String), op(UInt8, [Operand]), bytes([UInt8]) }
    static let byName: [String: UInt8] = Dictionary(uniqueKeysWithValues:
        CTSongISA.commandNames.enumerated().map { ($0.element, UInt8($0.offset) + CTSongISA.firstCommand) })

    /// Assemble a listing to song data. Every statement the tracks reach must
    /// have been written as one (no data bytes reached, no jumps inside a statement).
    public static func assemble(_ text: String) throws -> [UInt8] { try assembleSong(text).data }

    /// The song data and the per-song table rows the listing sets.
    public static func assembleSong(_ text: String) throws -> (data: [UInt8], tables: CTSongTables) {
        var origin: Int?, noTrack: Int?
        var tracks = [String?](repeating: nil, count: 16)
        var items: [Item] = []
        var tables = CTSongTables(), drums: [Int: [UInt8]] = [:]
        func isLabel(_ s: Substring) -> Bool {
            guard let first = s.first, first.isLetter || first == "_" else { return false }
            return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNo = index + 1
            func fail(_ message: String) -> CTSongError { CTSongError("line \(lineNo): \(message)") }
            let code = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let head = words.first else { continue }
            func hexWord(_ t: Substring) throws -> Int {
                guard t.count == 5, t.hasPrefix("$"), let v = Int(t.dropFirst(), radix: 16) else { throw fail("\(t) is not a $XXXX word") }
                return v
            }
            switch head {
            case "@origin", "@notrack":
                guard words.count == 2 else { throw fail("expected \(head) $XXXX") }
                if head == "@origin" { origin = try hexWord(words[1]) } else { noTrack = try hexWord(words[1]) }
            case "@samples":
                guard tables.samples == nil else { throw fail("@samples given twice") }
                if words.count == 2 && words[1] == "none" { tables.samples = []; break }
                let numbers = words.dropFirst().compactMap { decimal($0) }
                guard (1...16).contains(numbers.count), numbers.count == words.count - 1,
                      numbers.allSatisfy({ (1...CTSongISA.sampleNumberMax).contains($0) }) else {
                    throw fail("expected @samples none or 1-16 sample numbers 1-\(CTSongISA.sampleNumberMax)")
                }
                tables.samples = numbers
            case "@echo":
                let bytes = words.dropFirst().compactMap { w -> UInt8? in
                    w.count == 3 && w.hasPrefix("$") ? UInt8(w.dropFirst(), radix: 16) : nil
                }
                guard tables.echo == nil, words.count == 3, bytes.count == 2 else { throw fail("expected one @echo $XX $XX") }
                tables.echo = bytes
            case "@drums":
                guard words.count == 2, words[1] == "none", tables.drums == nil, drums.isEmpty else {
                    throw fail("expected one @drums none (or 12 @drum lines)")
                }
                tables.drums = [UInt8](repeating: 0, count: 36)
            case "@drum":
                let bytes = words.dropFirst(2).compactMap { w -> UInt8? in
                    w.count == 3 && w.hasPrefix("$") ? UInt8(w.dropFirst(), radix: 16) : nil
                }
                guard words.count == 5, let k = decimal(words[1]), (0...11).contains(k), bytes.count == 3 else {
                    throw fail("expected @drum 0-11 $SAMPLE $NOTE $PAN")
                }
                guard tables.drums == nil, drums[k] == nil else { throw fail("drum \(k) given twice") }
                drums[k] = bytes
            case "@track":
                guard words.count == 4, let set = ["A", "B"].firstIndex(of: String(words[1])),
                      words[2].count == 1, let t = Int(words[2]), (0...7).contains(t),
                      words[3] == "-" || isLabel(words[3]) else { throw fail("expected @track A|B 0-7 LABEL|-") }
                guard tracks[set * 8 + t] == nil else { throw fail("track given twice") }
                tracks[set * 8 + t] = String(words[3])
            case "@bytes":
                guard words.count > 1 else { throw fail("expected @bytes XX ...") }
                let bytes = try words.dropFirst().map { w -> UInt8 in
                    guard w.count == 2, let v = UInt8(w, radix: 16) else { throw fail("\(w) is not a hex byte") }
                    return v
                }
                items.append(.bytes(bytes))
            case "note", "tie", "rest":
                var rest = Array(words.dropFirst())
                var base = head == "tie" ? Int(CTSongISA.firstTie) : head == "rest" ? Int(CTSongISA.firstRest) : 0
                if head == "note" {
                    guard let name = rest.first, let n = CTSongISA.noteNames.firstIndex(of: String(name)) else {
                        throw fail("expected note C|C#|...|B LENGTH")
                    }
                    base = n * 14
                    rest.removeFirst()
                }
                guard rest.count == 1, let steps = Int(rest[0]), let d = CTSongISA.durations.firstIndex(of: steps) else {
                    throw fail("\(head) length must be one of \(CTSongISA.durations.sorted().map(String.init).joined(separator: ", "))")
                }
                items.append(.op(UInt8(base + d), []))
            default:
                if head.hasSuffix(":") {
                    guard words.count == 1, isLabel(head.dropLast()) else { throw fail("bad label") }
                    items.append(.label(String(head.dropLast())))
                    continue
                }
                guard let op = byName[String(head)] else { throw fail("unknown statement \(head)") }
                var operands: [Operand] = [], size = 0
                for token in words.dropFirst() {
                    if token.hasPrefix("->") {
                        guard let j = CTSongISA.jumpOperand[op], size == j, isLabel(token.dropFirst(2)) else {
                            throw fail("\(head): operand \(size + 1) is not an address")
                        }
                        operands.append(.label(String(token.dropFirst(2)))); size += 2
                    } else if token.count == 3, token.hasPrefix("$"), let v = UInt8(token.dropFirst(), radix: 16) {
                        operands.append(.byte(v)); size += 1
                    } else { throw fail("\(token) is not a $XX byte or ->LABEL") }
                }
                let want = CTSongISA.length(of: op) - 1
                let hasAddress = operands.contains { if case .label = $0 { return true } else { return false } }
                guard size == want, CTSongISA.jumpOperand[op] == nil || hasAddress else {
                    throw fail("\(head) takes \(want) operand bytes" + (CTSongISA.jumpOperand[op] != nil ? " with a ->LABEL address" : ""))
                }
                items.append(.op(op, operands))
            }
        }
        guard let origin, let noTrack else { throw CTSongError("need @origin and @notrack") }
        if let missing = tracks.firstIndex(where: { $0 == nil }) {
            throw CTSongError("missing @track \(missing < 8 ? "A" : "B") \(missing % 8)")
        }
        if !drums.isEmpty {
            guard drums.count == 12 else { throw CTSongError("give all 12 @drum lines (0-11) or @drums none") }
            tables.drums = (0..<12).flatMap { drums[$0]! }
        }
        return (try finish(origin: origin, noTrack: noTrack, tracks: tracks.map { $0! }, items: items), tables)
    }

    private static func finish(origin: Int, noTrack: Int, tracks: [String], items: [Item]) throws -> [UInt8] {
        var labels: [String: Int] = [:], offset = CTSongISA.header, written = Set<Int>()
        for item in items {
            switch item {
            case .label(let name):
                guard labels.updateValue((origin + offset - CTSongISA.header) & 0xFFFF, forKey: name) == nil else {
                    throw CTSongError("label \(name) defined twice")
                }
            case .bytes(let b): offset += b.count
            case .op(let op, _): written.insert(offset); offset += CTSongISA.length(of: op)
            }
        }
        func resolve(_ name: String) throws -> Int {
            guard let a = labels[name] else { throw CTSongError("undefined label \(name)") }
            return a
        }
        func le(_ v: Int) -> [UInt8] { [UInt8(v & 255), UInt8(v >> 8)] }
        var out = le(origin) + le(noTrack)
        for t in tracks {
            let a = t == "-" ? noTrack : try resolve(t)
            if t != "-" && a == noTrack { throw CTSongError("track label \(t) equals the @notrack word") }
            out += le(a)
        }
        for item in items {
            switch item {
            case .label: break
            case .bytes(let b): out += b
            case .op(let op, let operands):
                out.append(op)
                for operand in operands {
                    switch operand {
                    case .byte(let b): out.append(b)
                    case .label(let name): out += le(try resolve(name))
                    }
                }
            }
        }
        guard CTSongISA.fits(out.count) else {
            throw CTSongError("song is \(out.count) bytes; its transfer would reach $4700 (the most is \(CTSongISA.maxLength))")
        }
        let song = try CTSong(data: out)
        if let stray = try song.walk().keys.filter({ !written.contains($0) }).min() {
            throw CTSongError(String(format: "$%04X is reached but written as data; write it as statements", song.address(stray)))
        }
        return out
    }
}
