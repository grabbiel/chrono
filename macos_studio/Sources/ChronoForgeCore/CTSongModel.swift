// The event model of a `ct-song/1` listing: the listing as items that render
// back to the same text (so the same bytes), and the timeline the driver
// plays from them, in song steps. The timeline follows Spc_TrackStep and the
// sequence handlers of ChronoRET's driver.asm (MIT); `CTSongDriverTrace`
// checks it against the emulated driver.
import Foundation

/// One sequence statement of a listing.
public enum CTSongStatement: Equatable, Sendable {
    case note(semitone: Int, steps: Int)
    case tie(steps: Int)
    case rest(steps: Int)
    /// A command byte ($C4-$FF), its operand bytes without the address, and
    /// the label of its address operand (jump, loop_jump, branch).
    case command(UInt8, operands: [UInt8], target: String?)

    public static func command(_ name: String, _ operands: UInt8...) -> CTSongStatement {
        .command(CTSongListing.byName[name]!, operands: operands, target: nil)
    }

    /// Its length in song data bytes.
    public var length: Int {
        if case .command(let op, _, _) = self { return CTSongISA.length(of: op) }
        return 1
    }

    /// Steps a note, tie or rest byte waits (before a `wait` override).
    public var steps: Int? {
        switch self {
        case .note(_, let s), .tie(let s), .rest(let s): return s
        case .command: return nil
        }
    }

    public var name: String {
        switch self {
        case .note: return "note"
        case .tie: return "tie"
        case .rest: return "rest"
        case .command(let op, _, _): return CTSongISA.commandNames[Int(op - CTSongISA.firstCommand)]
        }
    }

    /// The statement as a listing line (four-space indent).
    public var text: String {
        switch self {
        case .note(let n, let s): return "    note \(CTSongISA.noteNames[n]) \(s)"
        case .tie(let s): return "    tie \(s)"
        case .rest(let s): return "    rest \(s)"
        case .command(let op, let operands, let target):
            var words = operands.map { String(format: "$%02X", $0) }
            if let j = CTSongISA.jumpOperand[op] { words.insert("->" + (target ?? "?"), at: min(j, words.count)) }
            return "    " + ([name] + words).joined(separator: " ")
        }
    }

    /// Parse a statement line (without its comment); nil when it is not one.
    static func parse(_ words: [Substring]) -> CTSongStatement? {
        guard let head = words.first else { return nil }
        switch head {
        case "note":
            guard words.count == 3, let n = CTSongISA.noteNames.firstIndex(of: String(words[1])),
                  let s = Int(words[2]), CTSongISA.durations.contains(s) else { return nil }
            return .note(semitone: n, steps: s)
        case "tie", "rest":
            guard words.count == 2, let s = Int(words[1]), CTSongISA.durations.contains(s) else { return nil }
            return head == "tie" ? .tie(steps: s) : .rest(steps: s)
        default:
            guard let op = CTSongListing.byName[String(head)] else { return nil }
            var operands: [UInt8] = [], target: String?
            for w in words.dropFirst() {
                if w.hasPrefix("->") { target = String(w.dropFirst(2)) }
                else if w.count == 3, w.hasPrefix("$"), let v = UInt8(w.dropFirst(), radix: 16) { operands.append(v) }
                else { return nil }
            }
            guard (CTSongISA.jumpOperand[op] != nil) == (target != nil),
                  operands.count + (target == nil ? 0 : 2) == CTSongISA.length(of: op) - 1 else { return nil }
            return .command(op, operands: operands, target: target)
        }
    }
}

/// A listing as items, in order. Unedited items keep their source line, so
/// `listing` gives back the text it was read from, character for character.
public struct CTSongDocument: Equatable, Sendable {
    public enum Item: Equatable, Sendable {
        /// Comments, blank lines and directives other than @track.
        case text(String)
        /// `@track A|B n LABEL|-`: track 0-15 (set A is 0-7).
        case track(Int, label: String?, raw: String)
        case label(String, raw: String)
        /// A statement; `raw` is its source line while it is unedited.
        case statement(CTSongStatement, raw: String?)
        case bytes([UInt8], raw: String)

        public var line: String {
            switch self {
            case .text(let s): return s
            case .track(_, _, let raw), .label(_, let raw), .bytes(_, let raw): return raw
            case .statement(let s, let raw): return raw ?? s.text
            }
        }
    }

    public var items: [Item]

    /// Read a listing. Lines that are not well-formed statements stay text,
    /// and the assembler reports them.
    public init(listing: String) {
        items = listing.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let code = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let head = words.first else { return .text(line) }
            if head == "@track", words.count == 4, let set = ["A", "B"].firstIndex(of: String(words[1])),
               let t = Int(words[2]), (0...7).contains(t) {
                return .track(set * 8 + t, label: words[3] == "-" ? nil : String(words[3]), raw: line)
            }
            if head == "@bytes" {
                let bytes = words.dropFirst().compactMap { $0.count == 2 ? UInt8($0, radix: 16) : nil }
                return bytes.count == words.count - 1 ? .bytes(bytes, raw: line) : .text(line)
            }
            if head.hasPrefix("@") { return .text(line) }
            if words.count == 1, head.hasSuffix(":") { return .label(String(head.dropLast()), raw: line) }
            if let s = CTSongStatement.parse(words) { return .statement(s, raw: line) }
            return .text(line)
        }
    }

    public init(items: [Item]) { self.items = items }

    public var listing: String { items.map(\.line).joined(separator: "\n") }

    /// Assemble through the `ct-song/1` assembler.
    public func assemble() throws -> (data: [UInt8], tables: CTSongTables) {
        try CTSongListing.assembleSong(listing)
    }

    /// Item index of each label.
    public var labels: [String: Int] {
        var out: [String: Int] = [:]
        for (i, item) in items.enumerated() { if case .label(let name, _) = item { out[name] = i } }
        return out
    }

    /// The entry label of each of the 16 tracks (nil: no track).
    public var trackLabels: [String?] {
        var out = [String?](repeating: nil, count: 16)
        for item in items { if case .track(let t, let label, _) = item { out[t] = label } }
        return out
    }

    public func statement(_ item: Int) -> CTSongStatement? {
        guard items.indices.contains(item), case .statement(let s, _) = items[item] else { return nil }
        return s
    }

    /// The value of the first `@name` directive's operands, as written.
    public func directive(_ name: String) -> [Substring]? {
        for item in items {
            guard case .text(let line) = item else { continue }
            let code = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if words.first == Substring(name) { return Array(words.dropFirst()) }
        }
        return nil
    }

    /// Replace (or add after `@notrack`) the `@name` line.
    public mutating func setDirective(_ name: String, _ value: String) {
        let line = "\(name) \(value)"
        if let i = items.firstIndex(where: { if case .text(let l) = $0 { return l.hasPrefix(name + " ") } else { return false } }) {
            items[i] = .text(line)
        } else {
            let at = items.firstIndex { if case .text(let l) = $0 { return l.hasPrefix("@notrack") } else { return false } }
            items.insert(.text(line), at: (at ?? -1) + 1)
        }
    }

    /// The per-song table rows the listing sets (its @samples, @echo and drums).
    public var tables: CTSongTables? { try? assemble().tables }
}

// MARK: - Timeline

/// The song as the driver plays it, in song steps from its start: each
/// track's notes, rests and commands with the steps they happen at.
public struct CTSongTimeline: Sendable {
    /// A driver note number as a name and octave ("C#4": number 49).
    public static func noteName(_ number: Int) -> String { CTSongISA.noteNames[number % 12] + String(number / 12) }

    public struct Note: Equatable, Sendable, Identifiable {
        public var id: String { "\(track):\(start)" }
        public let track: Int
        /// The note statement and the tie statements that hold it on.
        public let item: Int
        public let ties: [Int]
        public let start: Int
        /// Steps it sounds (with its ties) and steps of the note byte alone.
        public let length: Int, ownLength: Int
        /// Index above the octave base (0-11), and the driver's note number:
        /// base + index + transpose - 10, from which Spc_NotePitch takes the
        /// octave (number / 12) and the semitone (number % 12). In drum mode,
        /// the drum kit entry's note.
        public let semitone: Int, number: Int
        /// The track's sample operand when it starts ($20 + n is the n-th
        /// listed sample), nil before any; the drum kit's sample in drum mode.
        public let sample: Int?
        public let volume: Int?, pan: Int?
        /// Keyed on (false under legato), drum mode, and how many times the
        /// statement has been reached on this track before (loops).
        public let keyOn: Bool, drum: Bool
        public let pass: Int
    }

    public struct Event: Equatable, Sendable {
        public let track: Int, item: Int, step: Int
        public let statement: CTSongStatement
        /// Steps it waits (with a `wait` override) for a note, tie or rest; 0 for a command.
        public var length = 0
        /// base + transpose - 10 when it runs: a note index i sounds number offset + i.
        public var offset = 0
    }

    public struct Track: Sendable {
        public let index: Int
        public var notes: [Note] = []
        /// Every statement run, in order (notes, ties, rests and commands).
        public var events: [Event] = []
        /// The song loop: the step where the repeated part starts, and where
        /// the track jumps back to it (nil for a track that ends).
        public var loopStart: Int?, loopEnd: Int?
        /// The step the track stops at: its end, its loop jump, or the limit.
        public var endStep = 0
        /// Why it stopped: "end", "loop", "limit", "sfx" (jumps into the
        /// effects block, which is not modelled).
        public var stop = "limit"
    }

    public let tracks: [Track]
    /// Every tempo statement in the order the driver runs them.
    public let tempo: [Event]

    /// The longest track's end step.
    public var length: Int { tracks.map(\.endStep).max() ?? 0 }

    public struct Options: Sendable {
        /// Stop each track at its song loop (else run to `maxSteps`).
        public var untilLoop = true
        public var maxSteps = 20_000
        /// How far a track runs while its song loop is looked for: the loop
        /// must repeat twice within it.
        public var loopSearchSteps = 150_000
        /// !Spc_SongCond, which `branch` compares; a song start sets it to 0.
        public var songCondition = 0
        /// Song tracks: set A (command $10) is tracks 0-7.
        public var set = 0
        public init(untilLoop: Bool = true, maxSteps: Int = 20_000) { self.untilLoop = untilLoop; self.maxSteps = maxSteps }
    }

    public init(_ doc: CTSongDocument, tables: CTSongTables? = nil, options: Options = .init()) throws {
        let labels = doc.labels
        let drums = tables?.drums ?? doc.tables?.drums
        var tracks: [Track] = [], tempo: [(order: (Int, Int, Int), event: Event)] = []
        for (voice, label) in doc.trackLabels[(options.set * 8)..<(options.set * 8 + 8)].enumerated() {
            guard let label else { tracks.append(Track(index: voice, stop: "none")); continue }
            guard let entry = labels[label] else { throw CTSongError("track \(voice): undefined label \(label)") }
            var walker = Walker(doc: doc, labels: labels, voice: voice, drums: drums, options: options)
            let track = try walker.run(from: entry)
            tracks.append(track)
            for (k, e) in track.events.enumerated() where e.statement.isTempo { tempo.append(((e.step, voice, k), e)) }
        }
        self.tracks = tracks
        self.tempo = tempo.sorted { $0.order < $1.order }.map(\.event)
    }

    /// Runs one track the way Spc_TrackStep does, step by step.
    private struct Walker {
        let doc: CTSongDocument
        let labels: [String: Int]
        let voice: Int
        let drums: [UInt8]?
        let options: CTSongTimeline.Options

        struct Slot { var count = 0, iter = 0, back = 0 }
        var slots = [Slot](repeating: .init(), count: 4)
        var slot = 0                          // !Spc_TrackUnk27, wrapping in four
        var wait = 0                          // !Spc_TrackWait set by `wait`
        var base = 0, transpose = 0           // !Spc_TrackF200 low byte, F360 high byte
        var sample: Int?, volume: Int?, pan: Int?
        var drumMode = false
        var legato = false, unk60 = false, keyed = false   // !Spc_Unk5C, 60, 5E bits

        init(doc: CTSongDocument, labels: [String: Int], voice: Int, drums: [UInt8]?, options: CTSongTimeline.Options) {
            self.doc = doc; self.labels = labels; self.voice = voice; self.drums = drums; self.options = options
        }

        mutating func drop() { slot = (slot + 3) & 3 }

        mutating func target(_ name: String?) throws -> Int {
            guard let name, let i = labels[name] else { throw CTSongError("track \(voice): jump to an undefined label \(name ?? "")") }
            return i
        }

        /// The next statement at or after `i` (labels and text are skipped;
        /// data is an error, as the assembler refuses it).
        func next(_ i: Int) throws -> Int {
            var i = i
            while i < doc.items.count {
                switch doc.items[i] {
                case .statement: return i
                case .bytes: throw CTSongError("track \(voice) runs into @bytes data")
                default: i += 1
                }
            }
            throw CTSongError("track \(voice) runs past the end of the listing")
        }

        /// Runs one command; returns the next item, or nil when the track ends.
        mutating func command(_ op: UInt8, _ operands: [UInt8], _ target: String?, at i: Int) throws -> Int? {
            let a = Int(operands.first ?? 0)
            switch op {
            case 0xC4: volume = a & 0x7F
            case 0xC6: pan = a
            case 0xD6: base = (a * 12) & 0xFF
            case 0xD7: base = (base + 12) & 0xFF
            case 0xD8: base = (base - 12) & 0xFF
            case 0xD9: transpose = a
            case 0xDA: transpose = (transpose + a) & 0xFF
            case 0xDC: sample = a
            case 0xE2:                                           // Spc_SeqLoopStart
                slot = (slot + 1) & 3
                slots[slot] = Slot(count: a == 0 ? 0 : (a + 1) & 0xFF, iter: 1, back: i + 1)
            case 0xE3:                                           // Spc_SeqLoopEnd
                slots[slot].iter = (slots[slot].iter + 1) & 0xFF
                if slots[slot].count == 0 { return slots[slot].back }
                slots[slot].count -= 1
                if slots[slot].count == 0 { drop(); return i + 1 }
                return slots[slot].back
            case 0xE4: legato = true; keyed = false
            case 0xE6: unk60 = true
            case 0xE8: wait = a
            case 0xE9, 0xEA: return nil
            case 0xEB...0xEF, 0xFE, 0xFF: return nil
            case 0xF5:                                           // Spc_SeqLoopJump
                guard slots[slot].iter == a else { return i + 1 }
                if slots[slot].count == 1 { drop() }
                return try self.target(target)
            case 0xF6: return try self.target(target)
            case 0xFA:                                           // Spc_SeqBranch
                return options.songCondition >= a & 0x0F ? try self.target(target) : i + 1
            case 0xFB: drumMode = true
            case 0xFC: drumMode = false
            default: break
            }
            return i + 1
        }

        mutating func run(from entry: Int) throws -> Track {
            var track = Track(index: voice)
            var reached: [Int: Int] = [:]          // statement -> times run
            var lastEvent: [Int: Int] = [:]        // statement -> its latest event index
            var jumps: [(event: Int, back: Int)] = []
            var step = 0
            var i = entry
            var held: Int?                     // index into notes of the note ties extend
            var lookahead = false              // the previous byte was a note or tie
            var commands = 0
            let limit = options.untilLoop ? options.loopSearchSteps : options.maxSteps
            func stop(_ reason: String) -> Track { track.endStep = step; track.stop = reason; return track }
            while true {
                i = try next(i)
                guard case .statement(let s, _) = doc.items[i] else { continue }
                let pass = reached[i, default: 0]
                reached[i] = pass + 1
                if case .command(let op, let operands, let target) = s {
                    commands += 1
                    guard commands < 100_000 else { throw CTSongError("track \(voice) runs commands without a note") }
                    // Spc_TrackLookAhead after a note or tie: $DC and $E4-$E7
                    // end legato, and so does an end (it peeks as a rest).
                    if lookahead, op == 0xDC || (0xE4...0xE7).contains(op) || [0xEB, 0xEC, 0xED, 0xEE, 0xEF, 0xFE, 0xFF].contains(op) {
                        legato = false; unk60 = false
                    }
                    let endless = op == 0xE3 && slots[slot].count == 0
                    track.events.append(.init(track: voice, item: i, step: step, statement: s, offset: (base + transpose - 10) & 0xFF))
                    lastEvent[i] = track.events.count - 1
                    guard let to = try command(op, operands, target, at: i) else {
                        return stop(op == 0xE9 || op == 0xEA ? "sfx" : "end")
                    }
                    // A jump back to a statement already run may be the song loop.
                    if op == 0xF6 || (op == 0xF5 && to != i + 1) || (op == 0xFA && to != i + 1) || endless {
                        let back = try next(to)
                        if let previous = lastEvent[back] { jumps.append((track.events.count - 1, previous)) }
                    }
                    i = to
                    continue
                }
                commands = 0
                if step >= limit { break }
                let own = s.steps!
                let length = wait != 0 ? wait : own
                wait = 0
                track.events.append(.init(track: voice, item: i, step: step, statement: s, length: length,
                                          offset: (base + transpose - 10) & 0xFF))
                lastEvent[i] = track.events.count - 1
                switch s {
                case .note(let semitone, _):
                    var number = (base + semitone + transpose - 10) & 0xFF
                    var noteSample = sample
                    var notePan = pan
                    if drumMode, let drums, semitone < 12 {
                        sample = Int(drums[3 * semitone])           // Spc_DrumNote sets the track's sample
                        noteSample = sample
                        number = (Int(drums[3 * semitone + 1]) + transpose - 10) & 0xFF
                        if drums[3 * semitone + 2] < 0x80 { pan = Int(drums[3 * semitone + 2]); notePan = pan }
                    }
                    let keyOn: Bool
                    if unk60 || !legato { keyOn = true }
                    else if keyed { keyOn = false }
                    else { keyed = true; keyOn = true }
                    track.notes.append(.init(track: voice, item: i, ties: [], start: step, length: length, ownLength: length,
                                             semitone: semitone, number: number, sample: noteSample, volume: volume,
                                             pan: notePan, keyOn: keyOn, drum: drumMode, pass: pass))
                    held = track.notes.count - 1
                    lookahead = true
                case .tie:
                    if let h = held {
                        let n = track.notes[h]
                        track.notes[h] = .init(track: n.track, item: n.item, ties: n.ties + [i], start: n.start,
                                               length: n.length + length, ownLength: n.ownLength, semitone: n.semitone,
                                               number: n.number, sample: n.sample, volume: n.volume, pan: n.pan,
                                               keyOn: n.keyOn, drum: n.drum, pass: n.pass)
                    }
                    lookahead = true
                default:                                            // a rest
                    if lookahead { legato = false; unk60 = false }  // the look-ahead saw it
                    held = nil
                    lookahead = false
                }
                step += length
                i += 1
            }
            guard options.untilLoop else { return stop("limit") }
            // The song loop: the first jump back after which the events repeat,
            // with the same period, through the end of the run (two periods at least).
            let events = track.events
            for (j, i0) in jumps {
                let period = j + 1 - i0
                guard events.count - (j + 1) >= 2 * period else { continue }
                let steps = events[j].step - events[i0].step
                guard steps > 0, (i0..<(events.count - period)).allSatisfy({ n in
                    events[n + period].item == events[n].item && events[n + period].step == events[n].step + steps
                }) else { continue }
                track.events = Array(events.prefix(j + 1))
                track.notes = track.notes.filter { $0.start < events[j].step }
                track.loopStart = events[i0].step; track.loopEnd = events[j].step
                track.endStep = events[j].step; track.stop = "loop"
                return track
            }
            step = events.last?.step ?? 0
            return stop("limit")
        }
    }
}

extension CTSongStatement {
    var isTempo: Bool { if case .command(let op, _, _) = self { return op == 0xF0 || op == 0xF1 } else { return false } }
}

// MARK: - Tempo

/// Song steps against main-loop passes (one every 42 timer-0 ticks of 125 us,
/// 5.25 ms): Spc_StepTracks adds !Spc_Tempo to an accumulator each pass and
/// steps the song on its carry. Tempo commands and fades follow
/// Spc_SeqTempo, Spc_SeqTempoFade, Spc_FadeDelta and Spc_StepSongFades.
/// No host tempo adjustment (command $86) is applied.
public struct CTSongTempoMap: Sendable {
    public static let secondsPerPass = 42.0 / 8000.0
    /// The pass (0 = the first pass after the song starts) each step happens in.
    public let passOfStep: [Int]

    public init(_ timeline: CTSongTimeline, steps: Int) {
        var byStep: [Int: [CTSongStatement]] = [:]
        for e in timeline.tempo { byStep[e.step, default: []].append(e.statement) }
        var word = 0x0100                              // !Spc_StartTempo, fraction 0
        var fadeSteps = 0, fadeDelta = 0
        var accum = 0xFF                               // !Spc_TempoAccumStart
        var passes: [Int] = [], pass = 0
        passes.reserveCapacity(steps)
        while passes.count < steps {
            let tempo = word >> 8 & 0xFF
            accum += tempo
            if accum > 0xFF {
                accum &= 0xFF
                let step = passes.count
                passes.append(pass)
                for s in byStep[step] ?? [] {
                    guard case .command(let op, let ops, _) = s else { continue }
                    func scaled(_ t: Int) -> Int { (t + (t * 0x14) >> 8) & 0xFF }
                    if op == 0xF0 { word = scaled(Int(ops[0])) << 8; fadeSteps = 0; continue }
                    let n = Int(ops[0]), target = scaled(Int(ops[1]))
                    if n == 0 { word = target << 8; fadeSteps = 0; continue }
                    let diff = target - (word >> 8 & 0xFF)
                    if diff == 0 { fadeSteps = 0; continue }
                    let magnitude = abs(diff) & 0xFF
                    let delta = (magnitude / n) << 8 | ((magnitude % n) << 8) / n
                    fadeSteps = n; fadeDelta = diff > 0 ? delta : (0x10000 - delta) & 0xFFFF
                }
                if fadeSteps > 0 { fadeSteps -= 1; word = (word + fadeDelta) & 0xFFFF }
            }
            pass += 1
            if pass > 100_000_000 { break }               // a tempo of 0 never steps
        }
        passOfStep = passes
    }

    public func seconds(atStep step: Int) -> Double {
        guard let last = passOfStep.last else { return 0 }
        let pass = step < passOfStep.count ? passOfStep[max(0, step)] : last + (step - passOfStep.count + 1)
        return Double(pass) * Self.secondsPerPass
    }

    /// The step playing `seconds` after the song started.
    public func step(atSeconds seconds: Double) -> Int {
        let pass = Int((seconds / Self.secondsPerPass + 1e-6).rounded(.down))
        var lo = 0, hi = passOfStep.count
        while lo < hi { let mid = (lo + hi) / 2; if passOfStep[mid] <= pass { lo = mid + 1 } else { hi = mid } }
        return max(0, lo - 1)
    }
}
