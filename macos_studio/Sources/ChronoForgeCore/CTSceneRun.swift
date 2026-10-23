// CTSceneRun.swift — Module 8's timeline as the game times it: a location
// loaded and run headless in CTFieldRuntime (Evt_InitObjects' startups and
// Evt_RunObj0Func1 at load, then GameLoop_FrameBody frame by frame), with
// every handler CTEventVM runs recorded by the frame it ran in. An
// instruction is a bar from the frame its handler first ran to the frame it
// let the object go on (X past it): moves, animations, waits, messages and
// scrolls last what their handlers make them last. Story flags set before the
// load choose the branches; each conditional opcode's outcome is kept. An
// opcode with no model ends its object's lane with the VM's reason.
import Foundation

public enum CTSceneRun {
    /// A story byte or bit set before the load.
    public struct FlagSetting: Codable, Equatable, Hashable, Sendable {
        public var address: Int         // $7F:0000-$01FF, long
        public var bit: Int?
        public var value: Int           // 0/1 for a bit, 0-255 for a byte
        public var label: String
        public init(address: Int, bit: Int?, value: Int, label: String) {
            self.address = address; self.bit = bit; self.value = value; self.label = label
        }
    }

    /// `NAME=1` or `SYMBOL=1` (a registry entry), `7F:0010.3=1`, `$7F0010=$12`, `0x7F0010=18`.
    public static func flag(_ text: String, registry: CTStoryRegistry?) throws -> FlagSetting {
        let parts = text.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, let value = number(parts[1]) else {
            throw CTEventError("flag '\(text)': expected NAME=value")
        }
        let key = parts[0]
        if let e = registry?.entries.first(where: { $0.name == key || $0.symbol == key }) {
            let address = WRAM.evtMem7F + e.address
            return try checked(FlagSetting(address: address, bit: e.bit, value: value, label: e.name ?? e.symbol))
        }
        var addressText = key, bit: Int?
        if let dot = key.lastIndex(of: ".") {
            addressText = String(key[..<dot])
            guard let b = Int(key[key.index(after: dot)...]), (0...7).contains(b) else { throw CTEventError("flag '\(text)': bad bit") }
            bit = b
        }
        let bare = addressText.uppercased().replacingOccurrences(of: "7F:", with: "")
        guard var a = number(bare.hasPrefix("$") || bare.hasPrefix("0X") ? bare : "$" + bare) else {
            throw CTEventError("flag '\(text)': no registry entry or address '\(key)'")
        }
        if a < 0x10000 { a += WRAM.evtMem7F }
        return try checked(FlagSetting(address: a, bit: bit, value: value, label: key))
    }

    static func checked(_ f: FlagSetting) throws -> FlagSetting {
        guard (WRAM.evtMem7F..<(WRAM.evtMem7F + CTStory.memoryEnd)).contains(f.address) else {
            throw CTEventError(String(format: "flag %@: $%06X is not a story byte ($7F:0000-$01FF)", f.label, f.address))
        }
        guard f.bit == nil ? (0...255).contains(f.value) : (0...1).contains(f.value) else {
            throw CTEventError("flag \(f.label): value \(f.value) out of range")
        }
        return f
    }

    static func number(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("$") { return Int(t.dropFirst(), radix: 16) }
        if t.lowercased().hasPrefix("0x") { return Int(t.dropFirst(2), radix: 16) }
        return Int(t)
    }

    /// Function 1 (activate, Evt_StartTargetFunc1) or 2 (touch, Evt_StartTargetFunc2)
    /// of an object, started at the start of `frame` as the field starts them.
    public struct Trigger: Codable, Equatable, Sendable {
        public var object: Int, function: Int, frame: Int
        public init(object: Int, function: Int, frame: Int = 0) { self.object = object; self.function = function; self.frame = frame }
    }

    public struct Options: Equatable, Sendable {
        public var frames = 600
        public var input = CTFieldInput.Script(entries: [])
        public var flags: [FlagSetting] = []
        public var party: [UInt8] = [0, 0x80, 0x80]
        public var entry: [Int]?                // column, row[, facing]
        public var trigger: Trigger?
        /// The pack to run instead of the ROM's (an edited scene).
        public var pack: CTEventPack?
        /// Run `$E7`'s scroll-to (CTFieldRuntime.runsScrollTo).
        public var scrollTo = true
        /// A battle `$D8` starts is taken as over the next frame (FadeFlag_AfterBattle).
        public var skipBattles = true
        /// Animation loop counts as Obj_AnimTickAndQueue keeps them (CTFieldRuntime.romAnimLoops).
        public var romAnimLoops = true
        public init() {}
    }

    /// One handler run.
    public struct Step: Codable, Equatable, Sendable {
        public var frame: Int           // -1: at load
        public var object: Int, offset: Int, opcode: Int, level: Int
        public var next: Int?           // nil when the object stopped
        public var carry: Bool
        public var stop: String?
    }

    public struct Bar: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var object: Int, offset: Int, opcode: Int, level: Int
        public var start: Int
        /// The frame the handler let the object go on; nil: still on it when the run ended.
        public var end: Int?
        public var runs: Int
        public var category: CTSceneAnalysis.Category
        public var text: String
        /// The object left it before its handler finished (a call or a start moved it).
        public var interrupted = false
        /// A conditional opcode: true when it jumped, false when it went on.
        public var jumped: Bool?
        public var stop: String?
        public var duration: Int? { end.map { $0 - start } }
    }

    public struct Branch: Codable, Equatable, Sendable {
        public var frame: Int, object: Int, offset: Int, opcode: Int
        public var jumped: Bool, next: Int
    }

    public struct Lane: Codable, Equatable, Sendable, Identifiable {
        public var object: Int
        public var bars: [Bar]
        public var stopped: String?
        public var stoppedAt: Int?
        public var id: Int { object }
    }

    /// An object's pixel position (Obj_Pos >> 4) from `frame` on.
    public struct Point: Codable, Equatable, Sendable {
        public var frame: Int, x: Int, y: Int
    }

    public struct Track: Codable, Equatable, Sendable {
        public var object: Int
        public var points: [Point]
    }

    public struct Result: Codable, Equatable, Sendable {
        public var location: Int
        public var frames: Int
        public var lanes: [Lane]
        public var branches: [Branch]
        public var messages: [CTFieldRuntime.Message]
        public var warps: [CTFieldRuntime.Warp]
        public var flags: [FlagSetting]
        public var tracks: [Track]
        public var camera: [Point]
        public var battles: [CTSceneFormation.Battle]
        public var error: String?
        public var steps: Int
        public var notes: [String]

        /// The objects' positions at `frame` (the last point at or before it).
        public func positions(at frame: Int) -> [Int: (x: Int, y: Int)] {
            var out: [Int: (x: Int, y: Int)] = [:]
            for t in tracks {
                if let p = t.points.last(where: { $0.frame <= frame }) { out[t.object] = (p.x, p.y) }
            }
            return out
        }
        public func cameraAt(_ frame: Int) -> (x: Int, y: Int)? {
            camera.last(where: { $0.frame <= frame }).map { ($0.x, $0.y) }
        }
    }

    public static let notes = [
        "Frames are GameLoop_FrameBody frames of CTFieldRuntime; load (-1) is Evt_InitObjects' startups and Evt_RunObj0Func1.",
        "A bar runs from the frame its handler first ran to the frame the handler let the object go on.",
        "Objects run when their script timer (Obj_Unk1000, 4 by default) runs out, up to Field_Unk68 opcodes each.",
        "Messages hold until A pages them (the input script); a battle is taken as over the frame after $D8 starts it.",
    ]

    // MARK: Running

    public static func run(rom: [UInt8], location: Int, options: Options = Options()) throws -> Result {
        let field = try CTFieldRuntime(rom: rom, location: location, party: options.party)
        if let p = options.pack { field.packOverrides[location] = p }
        field.runsScrollTo = options.scrollTo
        field.romAnimLoops = options.romAnimLoops
        if let e = options.entry, e.count >= 2 { field.setEntry(x: e[0], y: e[1], facing: e.count > 2 ? e[2] : 1) }
        for f in options.flags { apply(f, to: &field.vm.wram) }
        var steps: [Step] = [], frame = -1
        field.vm.trace = { e in
            let level = Int(field.vm.wram[WRAM.objUnk1C00 + e.slot])
            var s = Step(frame: frame, object: e.slot / 2, offset: e.offset, opcode: Int(e.opcode), level: level,
                         next: nil, carry: false, stop: nil)
            switch e.outcome {
            case .go(let x, let c): s.next = x; s.carry = c
            case .unmodelled(let why), .halted(let why): s.stop = why
            }
            steps.append(s)
        }
        var error: String?
        var tracks: [Int: [Point]] = [:], camera: [Point] = [], battles: [CTSceneFormation.Battle] = []
        var battlePending = false
        func record(_ f: Int) {
            let w = field.vm.wram
            for o in 0..<field.vm.pack.objectCount {
                let px = w.word(WRAM.objPosX + 2 * o), py = w.word(WRAM.objPosY + 2 * o)
                guard px != 0xFF00 || py != 0xFF00 else { continue }
                let p = Point(frame: f, x: px >> 4, y: py >> 4)
                if let last = tracks[o]?.last, last.x == p.x, last.y == p.y { continue }
                tracks[o, default: []].append(p)
            }
            let c = Point(frame: f, x: field.camera.x, y: field.camera.y)
            if camera.last.map({ $0.x != c.x || $0.y != c.y }) ?? true { camera.append(c) }
        }
        do {
            try field.start()
            record(-1)
            for f in 0..<options.frames {
                frame = f
                if let t = options.trigger, t.frame == f {
                    guard (0..<field.vm.pack.objectCount).contains(t.object), [1, 2].contains(t.function) else {
                        throw CTEventError("a trigger starts function 1 or 2 of an object of the pack")
                    }
                    field.startFunction(2 * t.object, function: t.function)
                }
                if battlePending {                                       // DefaultHandler ran the battle
                    field.vm.wram[WRAM.fieldSceneFlags] &= ~0x21
                    field.vm.wram[WRAM.fieldFadeFlags] |= 0x01
                    battlePending = false
                }
                let before = steps.count
                try field.step(input: options.input.held(at: f))
                record(f)
                for s in steps[before...] where s.opcode == 0xD8 && s.next == s.offset {
                    let w = field.vm.wram
                    guard w[WRAM.fieldSceneFlags] & 0x01 != 0, !battlePending else { continue }
                    if !options.skipBattles, let last = battles.last, last.object == s.object, last.offset == s.offset { continue }
                    var copy = w
                    let (listed, enemies) = CTSceneFormation.compute(&copy)
                    let a = Int(w[0x7E2989]), b = Int(w[0x7E2A1F])
                    battles.append(.init(frame: f, object: s.object, offset: s.offset, unk2989: a, evtFlags: b, listed: listed,
                                         enemies: enemies.map { e in var e = e; e.name = CTSceneFormation.name(e.enemyId, rom: rom); return e },
                                         bits: CTSceneFormation.describe2989(a)))
                    if options.skipBattles { battlePending = true }
                }
            }
        } catch let e {
            error = "\(e)"
        }
        field.vm.trace = nil
        let pack = field.vm.pack
        let (lanes, branches) = derive(steps, pack: pack)
        return Result(location: location, frames: field.frameCount, lanes: lanes, branches: branches,
                      messages: field.messages, warps: field.warps, flags: options.flags,
                      tracks: tracks.keys.sorted().map { Track(object: $0, points: tracks[$0]!) }, camera: camera,
                      battles: battles, error: error, steps: steps.count, notes: notes)
    }

    public static func apply(_ f: FlagSetting, to w: inout WRAMModel) {
        if let bit = f.bit {
            let m = UInt8(1 << bit)
            if f.value != 0 { w[f.address] |= m } else { w[f.address] &= ~m }
        } else {
            w[f.address] = UInt8(f.value & 0xFF)
        }
    }

    // MARK: Bars from steps

    /// Bars per object and the conditional outcomes, from the handler runs in order.
    public static func derive(_ steps: [Step], pack: CTEventPack) -> (lanes: [Lane], branches: [Branch]) {
        var bars: [Int: [Bar]] = [:], branches: [Branch] = [], id = 0
        var stopped: [Int: (String, Int)] = [:]
        for s in steps {
            var list = bars[s.object, default: []]
            if var last = list.last, last.end == nil {
                if last.offset == s.offset {
                    last.runs += 1
                    finish(&last, s, pack)
                    list[list.count - 1] = last
                    bars[s.object] = list
                    noteBranch(s, pack, &branches)
                    if let why = s.stop { stopped[s.object] = (why, s.frame) }
                    continue
                }
                last.end = s.frame
                last.interrupted = true
                list[list.count - 1] = last
            }
            var bar = Bar(id: id, object: s.object, offset: s.offset, opcode: s.opcode, level: s.level, start: s.frame,
                          end: nil, runs: 1, category: CTSceneAnalysis.category(UInt8(s.opcode)), text: text(pack, s.offset))
            id += 1
            finish(&bar, s, pack)
            list.append(bar)
            bars[s.object] = list
            noteBranch(s, pack, &branches)
            if let why = s.stop { stopped[s.object] = (why, s.frame) }
        }
        let lanes = bars.keys.sorted().map { o in
            Lane(object: o, bars: bars[o]!, stopped: stopped[o]?.0, stoppedAt: stopped[o]?.1)
        }
        return (lanes, branches)
    }

    /// Ends the bar on the run that stops or moves X on; a condition then
    /// records whether it jumped (also after runs that yielded first).
    static func finish(_ bar: inout Bar, _ s: Step, _ pack: CTEventPack) {
        if let why = s.stop { bar.stop = why; bar.end = s.frame; return }
        guard let n = s.next, n != s.offset else { return }
        bar.end = s.frame
        if let ins = pack.instructions[s.offset], ins.jumpTarget != nil, ins.flow.contains(.next) {
            bar.jumped = n != s.offset + ins.length
        }
    }

    static func noteBranch(_ s: Step, _ pack: CTEventPack, _ out: inout [Branch]) {
        guard out.count < 20_000, let ins = pack.instructions[s.offset], ins.jumpTarget != nil, ins.flow.contains(.next),
              let n = s.next, n != s.offset else { return }
        out.append(Branch(frame: s.frame, object: s.object, offset: s.offset, opcode: s.opcode,
                          jumped: n != s.offset + ins.length, next: n))
    }

    public static func text(_ pack: CTEventPack, _ offset: Int) -> String {
        guard let i = pack.instructions[offset], offset + 1 + i.length <= pack.bytes.count else {
            return String(format: "$%04X (not an instruction start)", offset)
        }
        var parts = [CTEventISA.opcodes[Int(i.opcode)].name]
        for b in pack.bytes[(offset + 2)..<(offset + 1 + i.length)] { parts.append(String(format: "$%02X", b)) }
        return parts.joined(separator: " ")
    }

    // MARK: Text

    public static func render(_ r: Result) -> String {
        var lines = ["; ct-scene VM timeline: location \(r.location), \(r.frames) frames, \(r.steps) handler runs"
                     + (r.error.map { "; stopped: \($0)" } ?? "")]
        for f in r.flags { lines.append("; flag \(f.label) = \(f.value)") }
        for lane in r.lanes {
            lines.append("lane obj \(lane.object)" + (lane.stopped.map { "  STOPPED at \(lane.stoppedAt ?? -1): \($0)" } ?? ""))
            for b in lane.bars {
                let start = b.start < 0 ? "load" : "f\(b.start)"
                let span = b.end.map { $0 == b.start ? "" : "-\($0)" } ?? "-…"
                var line = String(format: "  %@%@ L%d $%04X %@: %@", start, span, b.level, b.offset, b.category.rawValue, b.text)
                if let j = b.jumped { line += j ? "  [jumped]" : "  [went on]" }
                if b.interrupted { line += "  [left]" }
                if let s = b.stop { line += "  STOP: \(s)" }
                lines.append(line)
            }
        }
        for b in r.battles {
            let names = b.enemies.map { "\($0.record):\($0.name ?? String(format: "$%02X", $0.enemyId))" }.joined(separator: ", ")
            lines.append(String(format: "battle at f%d obj %d $%04X: Battle_Unk2989 $%02X, enemies [%@]", b.frame, b.object, b.offset,
                                b.unk2989, names))
        }
        for m in r.messages {
            lines.append("message \(m.index) from obj \(m.slot / 2) at f\(m.frame)" + (m.closedAt.map { ", closed f\($0)" } ?? ", open"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
