// The chronological view of a raised event pack: every object's functions
// walked in execution order (conditions fall through), projected into Studio
// scenes and run in EventScheduler's multi-object scheduler, then laid out as
// per-object lanes over logical frames. The same walk gives the choreography
// the map canvas draws: placements, walks to tiles and camera scrolls.
import Foundation

/// One function followed from its entry: unconditional jumps are taken,
/// conditional ones fall through, a revisited offset ends the walk (a loop).
/// Function 0 goes on past its first `$00` into the object's continuation.
public struct CTSceneWalk: Equatable, Sendable {
    public var object: Int
    public var function: Int
    public var offsets: [Int]
    public var end: String          // "return", "halt", "loop", "ends here", "limit"

    public static let limit = 2000

    public init(_ pack: CTEventPack, object: Int, function: Int) {
        self.object = object; self.function = function
        var y = pack.functions[object][function], seen = Set<Int>(), out: [Int] = []
        var passedInit = function != 0, end = "limit"
        while out.count < Self.limit {
            guard let ins = pack.instructions[y] else { end = "ends here"; break }
            guard seen.insert(y).inserted else { end = "loop"; break }
            if ins.opcode == 0 {
                if !passedInit { passedInit = true; out.append(y); y += 1; continue }
                out.append(y); end = "return"; break
            }
            out.append(y)
            if ins.opcode == 0xB2 { end = "halt"; break }
            if ins.flow.contains(.next) { y += ins.length } else if let t = ins.jumpTarget { y = t } else { end = "ends here"; break }
        }
        offsets = out
        self.end = end
    }
}

public enum CTSceneTimeline {
    public struct Event: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var frame: Int
        public var duration: Int
        public var object: Int
        public var function: Int
        public var level: Int
        public var offset: Int?
        public var category: CTSceneAnalysis.Category
        public var text: String
        public var detail: String
    }
    public struct Lane: Codable, Equatable, Sendable, Identifiable {
        public var object: Int
        public var events: [Event]
        public var id: Int { object }
    }
    public struct Result: Codable, Equatable, Sendable {
        public var lanes: [Lane]
        public var frames: Int
        public var stopReason: String
        public var notes: [String]
    }
    /// A function started at frame 0 the way Evt_StartTargetFunc1 starts an
    /// activate: at `level` (1), saving what the object ran.
    public struct Trigger: Equatable, Sendable {
        public var object: Int, function: Int, level: Int
        public init(object: Int, function: Int, level: Int = 1) { self.object = object; self.function = function; self.level = level }
    }

    public static func sceneID(_ object: Int) -> String { String(format: "obj%02d", object) }

    /// `$65`/`$66` bit `m` as a flag symbol: `7F:0xxx.b`.
    public static func flagSymbol(bitByte: UInt8, m: UInt8) -> String {
        String(format: "7F:%04X.%d", (bitByte & 0x80 != 0 ? 0x100 : 0) + Int(m), Int(bitByte & 7))
    }

    /// The walks as scheduler scenes, with each statement's Evt_Data offset.
    public static func project(_ pack: CTEventPack) -> (scenes: [String: EventScene], offsets: [String: [Int: [Int]]]) {
        var scenes: [String: EventScene] = [:], offsets: [String: [Int: [Int]]] = [:]
        let head = pack.headerSize, size = pack.scriptSize
        for k in 0..<pack.objectCount {
            var funcs: [EventFunc] = [], map: [Int: [Int]] = [:]
            for f in 0..<CTEventPack.functionsPerObject {
                let entry = pack.functions[k][f]
                guard head <= entry, entry < size, pack.instructions[entry] != nil else { continue }
                if f != 0 && pack.instructions[entry]!.opcode == 0 { continue }   // returns at once
                let walk = CTSceneWalk(pack, object: k, function: f)
                var stmts: [EventStmt] = [], at: [Int] = []
                for y in walk.offsets {
                    let ins = pack.instructions[y]!
                    if ins.opcode == 0 { continue }                               // the startup's end
                    stmts.append(statement(pack, ins, objects: pack.objectCount))
                    at.append(y)
                }
                funcs.append(EventFunc(index: f, stmts: stmts))
                map[f] = at
            }
            let id = sceneID(k)
            scenes[id] = EventScene(object: k, funcs: funcs)
            offsets[id] = map
        }
        return (scenes, offsets)
    }

    static func statement(_ pack: CTEventPack, _ ins: CTEventInstruction, objects: Int) -> EventStmt {
        let o = Array(pack.bytes[(ins.offset + 2)..<(ins.offset + 1 + ins.length)])
        switch ins.opcode {
        case 0xAD: return .wait(frames: Int(o[0]))
        case 0xB9: return .wait(frames: 4)
        case 0xBA: return .wait(frames: 8)
        case 0xBC: return .wait(frames: 16)
        case 0xBD: return .wait(frames: 32)
        case 0xBB: return .text(stringID: "msg \(o[0])")
        case 0x65: return .setFlag(symbol: flagSymbol(bitByte: o[0], m: o[1]))
        case 0x66: return .clearFlag(symbol: flagSymbol(bitByte: o[0], m: o[1]))
        case 0x02...0x04 where Int(o[0]) / 2 < objects && o[1] >> 4 <= 6:
            return .callObject(scene: sceneID(Int(o[0]) / 2), funcIndex: Int(o[1] & 0x0F),
                               mode: [.start, .retry, .wait][Int(ins.opcode) - 2], level: Int(o[1] >> 4))
        case 0x05...0x07 where o[0] / 2 <= 2 && o[1] >> 4 <= 6:
            return .callMember(member: Int(o[0]) / 2, funcIndex: Int(o[1] & 0x0F),
                               mode: [.start, .retry, .wait][Int(ins.opcode) - 5], level: Int(o[1] >> 4))
        default: return .ct(opcode: ins.opcode, operands: Array(o.prefix(255)))
        }
    }

    /// Script runs a wait opcode lasts ($AD n; $B9/$BA/$BC/$BD: 4, 8, 16, 32).
    public static func waitRuns(_ pack: CTEventPack, _ ins: CTEventInstruction) -> Int {
        switch ins.opcode {
        case 0xAD: return Int(pack.bytes[ins.offset + 2])
        case 0xB9: return 4
        case 0xBA: return 8
        case 0xBC: return 16
        case 0xBD: return 32
        default: return 0
        }
    }

    /// Runs the location as it loads: every object starts its function 0 at
    /// the idle level (startup, then continuation), and `trigger` starts one
    /// function at frame 0. `party` gives the objects of party members 0-2.
    public static func run(_ pack: CTEventPack, trigger: Trigger? = nil, party: [Int]? = nil,
                           frameLimit: Int = 600, stepLimit: Int = 5000) throws -> Result {
        let (scenes, offsets) = project(pack)
        var starts: [EventScheduler.Start] = []
        for k in 0..<pack.objectCount {
            let id = sceneID(k)
            if scenes[id]!.funcs.contains(where: { $0.index == 0 }) { starts.append(.init(scene: id, function: 0, level: EventScheduler.idleLevel)) }
        }
        if let trigger {
            guard (0..<pack.objectCount).contains(trigger.object),
                  scenes[sceneID(trigger.object)]!.funcs.contains(where: { $0.index == trigger.function }) else {
                throw CTEventError("object \(trigger.object) has no function \(trigger.function) with code")
            }
            guard (0...6).contains(trigger.level) else { throw CTEventError("a trigger level is 0-6") }
            starts.append(.init(scene: sceneID(trigger.object), function: trigger.function, level: trigger.level))
        }
        let (trace, steps) = try EventScheduler.trace(scenes: scenes, starts: starts, party: party,
                                                     frameLimit: frameLimit, stepLimit: stepLimit,
                                                     slots: 0...(CTSceneDocument.maximumObjects - 1))
        var lanes: [Int: [Event]] = [:]
        for (n, e) in trace.entries.enumerated() {
            let at = offsets[e.scene]?[e.function].flatMap { steps[n] < $0.count ? $0[steps[n]] : nil }
            let ins = at.flatMap { pack.instructions[$0] }
            let category = ins.map { CTSceneAnalysis.category($0.opcode) } ?? .other
            let duration = ins.map { waitRuns(pack, $0) } ?? 0
            let text = ins.map { i in
                ([CTEventISA.opcodes[Int(i.opcode)].name]
                 + pack.bytes[(i.offset + 2)..<(i.offset + 1 + i.length)].map { String(format: "$%02X", $0) }).joined(separator: " ")
            } ?? e.action
            lanes[e.object, default: []].append(Event(id: n, frame: e.frame, duration: duration, object: e.object,
                                                      function: e.function, level: e.level, offset: at, category: category,
                                                      text: text, detail: e.detail))
        }
        let notes = [
            "Logical frames: EventScheduler's 5 statements per object per frame and CT call levels.",
            "Conditions fall through (their jumps are not taken); a revisited offset ends a walk.",
            "Waits ($AD, $B9-$BD) last their script runs as frames; moves, animations and messages show as instants.",
        ]
        return Result(lanes: lanes.keys.sorted().map { Lane(object: $0, events: lanes[$0]!) }, frames: trace.elapsedFrames,
                      stopReason: trace.stopReason, notes: notes)
    }

    public static func render(_ r: Result) -> String {
        var lines = ["; ct-scene timeline: \(r.frames) frames, \(r.stopReason)"]
        for lane in r.lanes {
            lines.append("lane obj \(lane.object)")
            for e in lane.events {
                let at = e.offset.map { String(format: "$%04X", $0) } ?? "-----"
                lines.append("  f\(e.frame)\(e.duration > 0 ? "+\(e.duration)" : "") L\(e.level) func \(e.function) \(at) "
                             + "\(e.category.rawValue): \(e.text)\(e.detail.isEmpty ? "" : " — \(e.detail)")")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Choreography on the map

public struct CTSceneChoreography: Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case place          // $8B PlaceAtTile / $8D SetPos
        case walk           // $96 WalkToTile: facing and walk animation
        case move           // $A0 MoveToTile: no facing or animation
        case camera         // $E7 ScrollTo: the camera's top-left goes to the tile (Map_Unk91AC)
        case direction      // $92 WalkDir / $9C MoveDir: an angle for a number of frames
    }
    public struct Point: Equatable, Sendable, Identifiable {
        public var kind: Kind
        public var function: Int
        public var offset: Int
        public var column: Int, row: Int
        /// `.direction`: Obj_Direction (256 a turn), Obj_MoveFrames and the Obj_Speed
        /// the walk last set (`$89`; Obj_Unk1A00Init $10 before one).
        public var angle: Int? = nil, frames: Int? = nil, speed: Int? = nil
        public var id: Int { offset }
    }
    public var object: Int
    public var points: [Point]

    public static let opcodes: [Kind: UInt8] = [.place: 0x8B, .walk: 0x96, .move: 0xA0, .camera: 0xE7]

    /// Every object's tile targets in walk order, per function.
    public static func extract(_ pack: CTEventPack) -> [CTSceneChoreography] {
        let head = pack.headerSize, size = pack.scriptSize
        return (0..<pack.objectCount).map { k in
            var points: [Point] = [], seen = Set<Int>()
            for f in 0..<CTEventPack.functionsPerObject {
                let entry = pack.functions[k][f]
                guard head <= entry, entry < size, pack.instructions[entry] != nil else { continue }
                var speed = 0x10
                for y in CTSceneWalk(pack, object: k, function: f).offsets where !seen.contains(y) {
                    let ins = pack.instructions[y]!, at = y + 2
                    let kind: Kind?
                    switch ins.opcode {
                    case 0x89: speed = Int(pack.bytes[at]); kind = nil
                    case 0x92, 0x9C:
                        seen.insert(y)
                        points.append(Point(kind: .direction, function: f, offset: y, column: 0, row: 0,
                                            angle: Int(pack.bytes[at]), frames: Int(pack.bytes[at + 1]), speed: speed))
                        continue
                    case 0x8B: kind = .place
                    case 0x96: kind = .walk
                    case 0xA0: kind = .move
                    case 0xE7: kind = .camera
                    case 0x8D:
                        seen.insert(y)
                        points.append(Point(kind: .place, function: f, offset: y,
                                            column: Int(pack.bytes[at + 1]), row: Int(pack.bytes[at + 3])))
                        continue
                    default: kind = nil
                    }
                    guard let kind else { continue }
                    seen.insert(y)
                    points.append(Point(kind: kind, function: f, offset: y,
                                        column: Int(pack.bytes[at]), row: Int(pack.bytes[at + 1])))
                }
            }
            return CTSceneChoreography(object: k, points: points)
        }
    }
}

extension CTSceneChoreography {
    /// Where a direction move ends, in tiles from where it starts: each frame
    /// Obj_MoveStep adds Obj_VelX/Y, which Obj_SetVelocityChecked takes from
    /// Obj_Speed x Rom_SineTable256 ($00:F800; X a quarter turn on). Obj_Pos
    /// has 256 units a tile. A blocked tile on the way turns the object at
    /// random (Obj_SetVelocityChecked), which only a run shows.
    public static func directionDelta(angle: Int, frames: Int, speed: Int, rom: [UInt8]) -> (dx: Double, dy: Double) {
        func part(_ a: Int) -> Int {
            let i = a & 0xFF, sine = rom.count > 0xF800 + i ? Int(rom[0xF800 + i]) : 0
            // As velocityPart: the high byte of speed x |sine| (Swift's >> binds tighter than *).
            let product: Int = i < 0x80 ? speed * sine : speed * ((256 - sine) & 0xFF)
            return i < 0x80 ? product >> 8 : -(product >> 8)
        }
        return (Double(part(angle + 0x40) * frames) / 256, Double(part(angle) * frames) / 256)
    }
}

extension CTSceneDocument {
    /// Adds a waypoint (`$96`/`$A0`), placement (`$8B`) or camera keyframe
    /// (`$E7`) after `offset`, or at the start of `function` without one.
    public mutating func addPoint(_ kind: CTSceneChoreography.Kind, column: Int, row: Int,
                                  after offset: Int?, object: Int, function: Int) throws {
        guard let op = CTSceneChoreography.opcodes[kind] else { throw CTEventError("\(kind) is not a tile target") }
        let operands = [UInt8(clamping: column), UInt8(clamping: row)]
        if let offset { try insert(op, operands, after: offset) } else { try insert(op, operands, atStartOf: object, function: function) }
    }

    /// Moves a choreography point (or an `$8D` placement, by its tiles) to another tile.
    public mutating func movePoint(at offset: Int, column: Int, row: Int) throws {
        let pack = try pack()
        guard let ins = pack.instructions[offset] else { throw CTEventError(String(format: "no opcode at $%04X", offset)) }
        let c = UInt8(clamping: column), r = UInt8(clamping: row)
        let old = Array(pack.bytes[(offset + 2)..<(offset + 1 + ins.length)])
        switch ins.opcode {
        case 0x8B, 0x96, 0xA0, 0xE7: try setOperands(at: offset, [c, r])
        case 0x8D: try setOperands(at: offset, [old[0], c, old[2], r])
        default: throw CTEventError("\(CTEventISA.opcodes[Int(ins.opcode)].name) is not a tile target")
        }
    }
}

// MARK: - Choreography in Studio scenes (ctproj DSL)

public enum SceneChoreography {
    /// Appends `ct` statements to function `function` of a Studio scene: the
    /// statement for a waypoint, placement or camera keyframe. Lowering checks
    /// them against the derived opcode table (docs/event_bytecode.md).
    public static func append(_ kind: CTSceneChoreography.Kind, column: Int, row: Int,
                              to scene: inout EventScene, function: Int) throws {
        guard let i = scene.funcs.firstIndex(where: { $0.index == function }) else {
            throw EventBytecode.CompileError("the scene has no func \(function)")
        }
        guard (0...255).contains(column), (0...255).contains(row) else {
            throw EventBytecode.CompileError("tile columns and rows are 0-255")
        }
        guard let op = CTSceneChoreography.opcodes[kind] else { throw EventBytecode.CompileError("\(kind) is not a tile target") }
        scene.funcs[i].stmts.append(.ct(opcode: op, operands: [UInt8(column), UInt8(row)]))
    }

    /// An animation (`$AA` row, `$AB` row once, `$B7` row count) or a line of
    /// dialogue at the end of a Studio function.
    public static func appendAnimation(row: Int, loops: Int? = nil, once: Bool = false,
                                       to scene: inout EventScene, function: Int) throws {
        guard let i = scene.funcs.firstIndex(where: { $0.index == function }) else {
            throw EventBytecode.CompileError("the scene has no func \(function)")
        }
        guard (0...255).contains(row), (0...255).contains(loops ?? 0) else { throw EventBytecode.CompileError("rows and counts are 0-255") }
        let stmt: EventStmt = loops.map { .ct(opcode: 0xB7, operands: [UInt8(row), UInt8($0)]) }
            ?? .ct(opcode: once ? 0xAB : 0xAA, operands: [UInt8(row)])
        scene.funcs[i].stmts.append(stmt)
    }
}
