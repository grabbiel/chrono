// Edits of a `ct-song/1` document in tracker terms: notes by pitch, start and
// length, controls before a note, and loops. Each edit rewrites statements;
// lines it does not touch keep their text, so an edit's diff is its own lines.
import Foundation

extension CTSongDocument {
    /// Durations (Spc_DurationTable values) that add up to `steps`, fewest
    /// first; nil for lengths no sum reaches (1, 2 and 5 steps).
    public static func durations(for steps: Int) -> [Int]? {
        guard steps > 0 else { return steps == 0 ? [] : nil }
        var best = [[Int]?](repeating: nil, count: steps + 1)
        best[0] = []
        for n in 1...steps {
            for d in CTSongISA.durations where d <= n {
                if let rest = best[n - d], best[n] == nil || rest.count + 1 < best[n]!.count { best[n] = [d] + rest }
            }
        }
        return best[steps].map { $0.sorted(by: >) }
    }

    /// Statements for one note, tie or rest run of `steps`: table lengths, or
    /// `wait` (the next byte's exact length, 1-255) where the table cannot.
    static func run(_ first: CTSongStatement, steps: Int) throws -> [CTSongStatement] {
        func with(_ d: Int) -> CTSongStatement {
            switch first {
            case .note(let n, _): return .note(semitone: n, steps: d)
            case .tie: return .tie(steps: d)
            default: return .rest(steps: d)
            }
        }
        if let ds = durations(for: steps) {
            return ds.enumerated().map { k, d in k == 0 ? with(d) : (first.isRest ? .rest(steps: d) : .tie(steps: d)) }
        }
        guard (1...255).contains(steps) else { throw CTSongError("no statements make \(steps) steps") }
        return [.command("wait", UInt8(steps)), with(CTSongISA.durations.last!)]
    }

    mutating func replace(_ range: Range<Int>, with statements: [CTSongStatement]) {
        items.replaceSubrange(range, with: statements.map { .statement($0, raw: nil) })
    }

    /// Index of the statement just before `item` when it is a `wait` (nothing
    /// but commands and no label between).
    func waitBefore(_ item: Int) -> Int? {
        var k = item - 1
        while k >= 0, case .statement(let s, _) = items[k], s.steps == nil {
            if case .command(0xE8, _, _) = s { return k }
            k -= 1
        }
        return nil
    }

    // MARK: Notes

    /// Set a note statement's index above the octave base (0-11).
    public mutating func setSemitone(_ item: Int, _ semitone: Int) throws {
        guard case .note(_, let steps)? = statement(item), (0...11).contains(semitone) else {
            throw CTSongError("line \(item + 1) is not a note, or \(semitone) is not 0-11")
        }
        replace(item..<(item + 1), with: [.note(semitone: semitone, steps: steps)])
    }

    /// Give a note (with its ties) `steps` steps. The rest after it shrinks or
    /// grows to keep later notes in place; with `shift`, later notes move
    /// instead when there is no rest to take the time from.
    public mutating func setLength(_ note: CTSongTimeline.Note, _ steps: Int, shift: Bool = false) throws {
        guard steps > 0 else { throw CTSongError("a note needs at least one step") }
        let chain = [note.item] + note.ties
        guard chain == Array(chain[0]...chain.last!) else {
            throw CTSongError("line \(note.item + 1): its ties are split by other statements; edit the listing")
        }
        guard case .note(let semitone, _)? = statement(note.item) else { throw CTSongError("line \(note.item + 1) is not a note") }
        let delta = steps - note.length
        // The rests right after the note (commands between them are kept).
        var after = chain.last! + 1, rests: [Int] = [], restSteps = 0
        scan: while after < items.count {
            switch items[after] {
            case .statement(let s, _):
                if case .rest(let r) = s, waitBefore(after) == nil { rests.append(after); restSteps += r }
                else if s.steps != nil { break scan }
                else if !rests.isEmpty { break scan }
            case .label, .bytes, .track: break scan
            case .text: break
            }
            after += 1
        }
        if delta > 0, restSteps < delta, !shift {
            throw CTSongError("line \(note.item + 1): no rest after the note to grow into (\(restSteps) steps free, \(delta) needed)")
        }
        // Rests first (they are later in the listing), then the note.
        if delta != 0, !rests.isEmpty || delta < 0 {
            let left = rests.isEmpty ? -delta : max(0, restSteps - delta)
            let restRun = left == 0 ? [] : try Self.run(.rest(steps: 3), steps: left)
            if rests.isEmpty { items.insert(contentsOf: restRun.map { .statement($0, raw: nil) }, at: chain.last! + 1) }
            else {
                // Drop the rest run's own items (keeping commands between them).
                for r in rests.reversed() { items.remove(at: r) }
                items.insert(contentsOf: restRun.map { .statement($0, raw: nil) }, at: rests[0])
            }
        }
        var start = note.item
        if let w = waitBefore(note.item) { items.remove(at: w); start -= 1 }
        replace(start..<(start + chain.count), with: try Self.run(.note(semitone: semitone, steps: 3), steps: steps))
    }

    /// Turn a note (with its ties) into rests of the same length.
    public mutating func deleteNote(_ note: CTSongTimeline.Note) throws {
        for item in [note.item] + note.ties {
            guard let s = statement(item), let d = s.steps else { throw CTSongError("line \(item + 1) is not a note or tie") }
            replace(item..<(item + 1), with: [.rest(steps: d)])
        }
    }

    /// Put a note of `steps` at `step` on `track`, into the rests there. The
    /// note sounds driver number `number`; when that is outside the octave in
    /// force, octave_up/octave_down statements go around it. Returns the new
    /// note's item.
    @discardableResult
    public mutating func insertNote(track: Int, step: Int, number: Int, steps: Int,
                                    timeline: CTSongTimeline) throws -> Int {
        let events = timeline.tracks[track].events
        // The run of rest statements (one after another in the listing) that covers the span.
        guard let k = events.firstIndex(where: { $0.statement.isRest && $0.step <= step && step < $0.step + $0.length }) else {
            throw CTSongError("track \(track) has no rest at step \(step)")
        }
        var first = k, last = k
        while first > 0, events[first - 1].statement.isRest, events[first - 1].item == events[first].item - 1 { first -= 1 }
        while last + 1 < events.count, events[last + 1].statement.isRest, events[last + 1].item == events[last].item + 1 { last += 1 }
        let begin = events[first].step, end = events[last].step + events[last].length
        guard step + steps <= end else {
            throw CTSongError("track \(track): the rest at step \(step) ends at \(end); the note would need \(step + steps)")
        }
        let range = events[first].item..<(events[last].item + 1)
        guard !range.contains(where: { waitBefore($0) != nil }), labels.values.allSatisfy({ !range.dropFirst().contains($0) }),
              timeline.tracks.reduce(0, { n, t in n + t.events.filter { range.contains($0.item) }.count }) == last - first + 1 else {
            throw CTSongError("track \(track): the rests at step \(step) are shared or labelled; edit the listing")
        }
        let offset = events[k].offset
        var octaves = 0, semitone = number - offset
        while semitone < 0 { semitone += 12; octaves -= 1 }
        while semitone > 11 { semitone -= 12; octaves += 1 }
        var out: [CTSongStatement] = []
        if step > begin { out += try Self.run(.rest(steps: 3), steps: step - begin) }
        let up = CTSongStatement.command(octaves > 0 ? "octave_up" : "octave_down")
        let down = CTSongStatement.command(octaves > 0 ? "octave_down" : "octave_up")
        out += Array(repeating: up, count: abs(octaves))
        let noteAt = range.lowerBound + out.count
        out += try Self.run(.note(semitone: semitone, steps: 3), steps: steps)
        out += Array(repeating: down, count: abs(octaves))
        if end > step + steps { out += try Self.run(.rest(steps: 3), steps: end - step - steps) }
        replace(range, with: out)
        return noteAt + (out[noteAt - range.lowerBound].isWait ? 1 : 0)
    }

    /// Move a note to another start and number on its track: it becomes rests
    /// where it was, then is put into the rests at `step`.
    @discardableResult
    public mutating func moveNote(_ note: CTSongTimeline.Note, toStep step: Int, number: Int,
                                  tables: CTSongTables? = nil) throws -> Int {
        var copy = self
        try copy.deleteNote(note)
        let timeline = try CTSongTimeline(copy, tables: tables)
        let item = try copy.insertNote(track: note.track, step: step, number: number, steps: note.length, timeline: timeline)
        self = copy
        return item
    }

    // MARK: Controls and loops

    /// Set a command such as `sample`, `volume` or `pan` from `item` on: an
    /// equal command among those right before it takes the new value, else
    /// one is put before it. Like a tracker's effect column, it lasts until
    /// the next one.
    public mutating func setControl(before item: Int, _ name: String, _ value: UInt8) throws {
        guard let op = CTSongListing.byName[name], CTSongISA.length(of: op) == 2 else {
            throw CTSongError("\(name) is not a one-operand command")
        }
        var k = item - 1
        while k >= 0, case .statement(let s, _) = items[k], s.steps == nil {
            if case .command(op, _, _) = s { replace(k..<(k + 1), with: [.command(op, operands: [value], target: nil)]); return }
            k -= 1
        }
        let at = waitBefore(item) ?? item
        items.insert(.statement(.command(op, operands: [value], target: nil), raw: nil), at: at)
    }

    /// Set a loop_start's operand: the loop plays `passes` times (2-255), or
    /// 0 for endless.
    public mutating func setLoopPasses(_ item: Int, _ passes: Int) throws {
        guard case .command(0xE2, _, _)? = statement(item), passes == 0 || (2...255).contains(passes) else {
            throw CTSongError("line \(item + 1) is not a loop_start, or \(passes) is not 0 or 2-255 passes")
        }
        replace(item..<(item + 1), with: [.command("loop_start", UInt8(passes == 0 ? 0 : passes - 1))])
    }

    /// Repeat statements `first...last` `passes` times with loop_start/loop_end.
    public mutating func insertLoop(from first: Int, through last: Int, passes: Int) throws {
        guard first <= last, statement(first) != nil, statement(last) != nil, (2...255).contains(passes) else {
            throw CTSongError("choose statements and 2-255 passes")
        }
        items.insert(.statement(.command("loop_end"), raw: nil), at: last + 1)
        items.insert(.statement(.command("loop_start", UInt8(passes - 1)), raw: nil), at: first)
    }

    /// Make the track's song loop start at `item`: its closing `jump` goes to
    /// a label put before `item` (or the label already there).
    public mutating func setSongLoop(track: CTSongTimeline.Track, at item: Int) throws {
        guard track.stop == "loop", let jump = track.events.last?.item,
              case .command(0xF6, _, _)? = statement(jump), statement(item) != nil else {
            throw CTSongError("track \(track.index) does not end with a loop jump")
        }
        var label: String
        if item > 0, case .label(let name, _) = items[item - 1] { label = name }
        else {
            label = "loop_t\(track.index)"
            var n = 1
            while labels[label] != nil { n += 1; label = "loop_t\(track.index)_\(n)" }
        }
        replace(jump..<(jump + 1), with: [.command(0xF6, operands: [], target: label)])
        if labels[label] == nil { items.insert(.label(label, raw: label + ":"), at: item) }
    }
}

extension CTSongStatement {
    var isRest: Bool { if case .rest = self { return true } else { return false } }
    var isWait: Bool { if case .command(0xE8, _, _) = self { return true } else { return false } }
}
