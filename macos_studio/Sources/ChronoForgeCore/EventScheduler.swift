// Multi-object logical preview: every scene in a project runs as its own
// object, with CT's call levels (Evt_Op02/03/04 and Evt_Op00_Return in
// ChronoRET's bankC0.asm). Logical frames, no SNES timing claims.
import Foundation

public enum EventScheduler {
    public static let idleLevel = 7                     // Obj_Unk1C00Init
    public static let stepsPerFrame = 5                 // Field_Unk68 from load (Evt_RunObjScriptSteps)

    /// Empty input leaves party calls unbound. Never drop malformed entries:
    /// doing so would silently change which actor a party member addresses.
    public static func parsePartySlots(_ text: String) throws -> [Int]? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        let slots = parts.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard slots.count == parts.count else {
            throw EventBytecode.CompileError("party slots must be comma-separated integers")
        }
        try validateParty(slots)
        return slots
    }

    private static func validateParty(_ slots: [Int]) throws {
        guard (1...3).contains(slots.count), slots.allSatisfy({ (0...15).contains($0) }),
              Set(slots).count == slots.count else {
            throw EventBytecode.CompileError("party requires 1–3 distinct object slots in 0...15")
        }
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var frame: Int
        public var scene: String
        public var object: Int
        public var level: Int
        public var function: Int
        public var action: String
        public var detail: String
    }
    public struct ObjectState: Codable, Equatable, Sendable {
        public var scene: String
        public var object: Int
        public var level: Int
        public var function: Int?                       // nil: idle at level 7
        public var status: String
    }
    public struct Result: Codable, Equatable, Sendable {
        public var entries: [Entry]
        public var elapsedFrames: Int
        public var flags: [String]
        public var stopReason: String
        public var objects: [ObjectState]
    }

    /// A position in a function: its index and the statements still to run
    /// (innermost block last), as the single-scene preview keeps them.
    /// A preempted script keeps its block: the ROM resumes on the same
    /// opcode, and ObjX_CallWait survives the interruption.
    struct Cursor: Equatable {
        var function: Int
        var pending: [EventStmt]                        // reversed: next statement last
        var block: Block? = nil
        var status = "running"
    }
    enum Block: Equatable {
        case sleep(until: Int)
        case retry                                      // the call statement (back on top) is tried again
        case callWait(target: String, level: Int)       // until the target's level is above `level`
    }
    struct Object {
        let id: String
        let scene: EventScene
        var level = EventScheduler.idleLevel
        var cursor: Cursor?
        var saved: [Int: Cursor] = [:]                  // ObjX_Unk7F0580: interrupted scripts by level
        var queued: [Int: Int] = [:]                    // ObjX_Unk7F0580: functions queued by level
        var block: Block? {
            get { cursor?.block }
            set { cursor?.block = newValue }
        }
        var status: String {
            get { cursor?.status ?? "idle" }
            set { cursor?.status = newValue }
        }
    }

    /// Runs `entry` of scene `entryScene` (at the idle level, as a startup
    /// script) with every other scene as an idle object. `party` gives the
    /// object slots of party members 0-2 for `call_pc`; without it those
    /// calls are recorded and skipped. Dialogue adds no delay.
    public static func run(scenes: [String: EventScene], entryScene: String, entry: Int = 0,
                           flags initialFlags: Set<String> = [], dialogue: [String: String] = [:],
                           party: [Int]? = nil, frameLimit: Int = 10_000, stepLimit: Int = 1000) throws -> Result {
        guard (1...100_000).contains(stepLimit), (1...1_000_000).contains(frameLimit) else {
            throw EventBytecode.CompileError("preview limits out of range")
        }
        guard let start = scenes[entryScene] else { throw EventBytecode.CompileError("unknown entry scene \(entryScene)") }
        var owners: [Int: String] = [:]
        for id in scenes.keys.sorted() {
            let scene = scenes[id]!
            try EventBytecode.validate(scene)
            if let other = owners[scene.object] {
                throw EventBytecode.CompileError("object slot \(scene.object) is shared by scenes \(other) and \(id)")
            }
            owners[scene.object] = id
        }
        if let party { try validateParty(party) }
        guard let entryBody = start.funcs.first(where: { $0.index == entry })?.stmts else {
            throw EventBytecode.CompileError("missing entry function \(entry)")
        }
        var objects = scenes.keys.sorted().map { Object(id: $0, scene: scenes[$0]!) }
            .sorted { ($0.scene.object, $0.id) < ($1.scene.object, $1.id) }
        let index = Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($0.element.id, $0.offset) })
        objects[index[entryScene]!].cursor = Cursor(function: entry, pending: entryBody.reversed())
        objects[index[entryScene]!].status = "running"

        var flags = initialFlags, entries: [Entry] = []
        var frame = 0, stop: String?

        func functionBody(_ o: Object, _ f: Int) -> [EventStmt]? { o.scene.funcs.first { $0.index == f }?.stmts }
        func record(_ o: Object, _ function: Int, _ stmt: EventStmt, _ detail: String) {
            entries.append(Entry(id: entries.count, frame: frame, scene: o.id, object: o.scene.object, level: o.level,
                                 function: function, action: EventDSL.summary(stmt), detail: detail))
        }
        func target(of stmt: EventStmt) -> (id: String?, function: Int, mode: EventCallMode, level: Int, label: String) {
            switch stmt {
            case .callObject(let id, let f, let mode, let level): return (id, f, mode, level, "\"\(id)\"")
            case .callMember(let m, let f, let mode, let level):
                let slot = party.flatMap { $0.indices.contains(m) ? $0[m] : nil }
                let id = slot.flatMap { s in objects.first { $0.scene.object == s }?.id }
                return (id, f, mode, level, "party member \(m)")
            default: return (nil, 0, .start, 0, "")
            }
        }
        /// Evt_Op02's effect on the target: preempt, queue, or nothing.
        func call(_ t: Int, function f: Int, level: Int) -> String {
            var o = objects[t]
            defer { objects[t] = o }
            guard let stmts = functionBody(o, f) else { return "\(o.id) has no func \(f): nothing happens" }
            if level == o.level { return "\(o.id) is already at level \(level): nothing happens" }
            if level < o.level {
                if let c = o.cursor { o.saved[o.level] = c }
                o.cursor = Cursor(function: f, pending: stmts.reversed())
                o.level = level
                o.block = nil
                o.status = "running"
                return "\(o.id) starts func \(f) at level \(level)"
            }
            if o.queued[level] != nil || o.saved[level] != nil { return "level \(level) of \(o.id) is taken: not queued" }
            o.queued[level] = f
            return "\(o.id) is busy at level \(o.level): func \(f) queued at level \(level)"
        }
        /// Evt_Op00_Return: resume the next saved or queued entry above.
        func finish(_ i: Int) {
            var o = objects[i]
            defer { objects[i] = o }
            if o.level == idleLevel { o.cursor = nil; o.status = "idle"; return }
            o.saved[o.level] = nil; o.queued[o.level] = nil
            var l = o.level + 1
            while l <= idleLevel {
                if let c = o.saved.removeValue(forKey: l) { o.level = l; o.cursor = c; return }
                if let f = o.queued.removeValue(forKey: l), let stmts = functionBody(o, f) {
                    o.level = l; o.cursor = Cursor(function: f, pending: stmts.reversed()); o.status = "running"; return
                }
                l += 1
            }
            o.level = idleLevel; o.cursor = nil; o.status = "idle"
        }

        frames: while frame < frameLimit {
            var progressed = false
            for i in objects.indices {
                var steps = 0
                run: while steps < stepsPerFrame, objects[i].cursor != nil {
                    switch objects[i].block {
                    case .sleep(let until)?:
                        guard frame >= until else { break run }
                        objects[i].block = nil; objects[i].status = "running"
                    case .callWait(let id, let level)?:
                        guard let t = index[id], objects[t].level > level else { break run }
                        objects[i].block = nil; objects[i].status = "running"; progressed = true
                    case .retry, nil: break
                    }
                    guard let stmt = objects[i].cursor!.pending.popLast() else { finish(i); progressed = true; continue }
                    let o = objects[i], function = o.cursor!.function
                    if case .retry = o.block, case let c = target(of: stmt), let id = c.id, let t = index[id],
                       c.level >= objects[t].level {
                        objects[i].cursor!.pending.append(stmt)     // still busy: try again next frame, unrecorded
                        break run
                    }
                    objects[i].block = nil
                    objects[i].status = "running"
                    guard entries.count < stepLimit else { stop = "Step limit reached (possible loop)"; break frames }
                    steps += 1; progressed = true
                    switch stmt {
                    case .nop: record(o, function, stmt, "")
                    case .text(let id): record(o, function, stmt, dialogue[id] ?? "Unresolved dialogue: \(id)")
                    case .ct: record(o, function, stmt, "CT opcode, not simulated")
                    case .setFlag(let s): flags.insert(s); record(o, function, stmt, "")
                    case .clearFlag(let s): flags.remove(s); record(o, function, stmt, "")
                    case .wait(let n):
                        record(o, function, stmt, "")
                        if n > 0 { objects[i].block = .sleep(until: frame + n); objects[i].status = "waiting" }
                    case .ifFlag(let s, let yes, let no):
                        record(o, function, stmt, flags.contains(s) ? "then branch" : "else branch")
                        objects[i].cursor!.pending.append(contentsOf: (flags.contains(s) ? yes : no).reversed())
                    case .jump(let f):
                        record(o, function, stmt, "")
                        objects[i].cursor = Cursor(function: f, pending: (functionBody(o, f) ?? []).reversed())
                    case .call(let map, let f):
                        record(o, function, stmt, "")
                        stop = "Stopped at external call \(map)#\(f): map/function binding is not defined"
                        break frames
                    case .callObject, .callMember:
                        let c = target(of: stmt)
                        guard let id = c.id, let t = index[id] else {
                            record(o, function, stmt, c.label.hasPrefix("party")
                                   ? "\(c.label) has no object here (give party slots): not simulated"
                                   : "unknown scene \(c.label): not simulated")
                            break
                        }
                        if c.mode != .start && c.level >= objects[t].level {
                            record(o, function, stmt, "\(id) busy at level \(objects[t].level): retrying each frame")
                            objects[i].cursor!.pending.append(stmt)
                            objects[i].block = .retry; objects[i].status = "retrying \(id)"
                            break run
                        }
                        record(o, function, stmt, call(t, function: c.function, level: c.level))
                        if c.mode == .wait && t != i {
                            objects[i].block = .callWait(target: id, level: c.level); objects[i].status = "waiting for \(id)"
                        }
                    }
                    if objects[i].block != nil { break run }
                    if objects[i].cursor?.pending.isEmpty == true { finish(i) }
                }
            }
            let sleeping = objects.contains { if case .sleep = $0.block { return true } else { return false } }
            if objects.allSatisfy({ $0.cursor == nil }) { stop = "All objects idle"; break }
            if !progressed && !sleeping { stop = "Blocked: every running object waits on another"; break }
            frame += 1
        }
        return Result(entries: entries, elapsedFrames: frame, flags: flags.sorted(),
                      stopReason: stop ?? "Frame limit reached",
                      objects: objects.map { o in
                          ObjectState(scene: o.id, object: o.scene.object, level: o.level, function: o.cursor?.function, status: o.status)
                      })
    }
}
