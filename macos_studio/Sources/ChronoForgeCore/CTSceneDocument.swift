// A location's event pack raised into a scene (`ct-scene/1`): the editable
// program (labels, opcodes, data) plus what it says about the location: each
// object's 16 functions and the statements they reach at their Evt_Data
// offsets, the calls between objects at their levels, and the map objects
// the handlers prove (characters, sprites, placements, the save menu,
// on-map battles). Lowering assembles the program through CTEventProgram,
// whose re-disassembly is the verifier; see docs/scene_director.md.
import Foundation

public struct CTSceneDocument: Equatable, Sendable {
    public static let schema = "ct-scene/1"
    /// Objects a pack may hold: the Obj_* tables are $80 bytes of words
    /// (Obj_PosX $7E:1800, Obj_PosY $7E:1880), and one ROM pack has 64.
    public static let maximumObjects = 64
    public var location: Int?
    public var packEntry: Int?
    public var program: CTEventProgram

    public init(program: CTEventProgram, location: Int? = nil, packEntry: Int? = nil) {
        self.program = program; self.location = location; self.packEntry = packEntry
    }

    public static func raise(_ pack: CTEventPack, location: Int? = nil, packEntry: Int? = nil) -> CTSceneDocument {
        CTSceneDocument(program: CTEventListing.program(pack), location: location, packEntry: packEntry)
    }

    public static func raise(bytes: [UInt8], location: Int? = nil, packEntry: Int? = nil) throws -> CTSceneDocument {
        raise(try CTEventPack(bytes: bytes), location: location, packEntry: packEntry)
    }

    /// The pack bytes, assembled and checked by re-disassembly.
    public func lower() throws -> [UInt8] { try program.assemble() }

    public func pack() throws -> CTEventPack { try CTEventPack(bytes: lower()) }

    public func analyze() throws -> CTSceneAnalysis { CTSceneAnalysis(try pack()) }

    // MARK: Edits (each re-assembles; a failed edit leaves the document as it was)

    /// Index of the `.op` item at Evt_Data offset `offset`.
    func opIndex(at offset: Int) throws -> Int {
        let (_, at) = try program.offsets()
        for (i, item) in program.items.enumerated() {
            if case .op = item, at[i] == offset { return i }
        }
        throw CTEventError(String(format: "no opcode starts at $%04X", offset))
    }

    private mutating func commit(_ edit: (inout CTEventProgram) throws -> Void) throws {
        var candidate = program
        try edit(&candidate)
        _ = try candidate.assemble()
        program = candidate
    }

    private static func checkInsertable(_ opcode: UInt8, _ operands: [UInt8]) throws {
        let def = CTEventISA.opcodes[Int(opcode)]
        if def.jump != nil { throw CTEventError("\(def.name) jumps: edit jumps in the listing, where labels name their targets") }
    }

    /// Writes opcode + operands after the statement at `offset` (and any
    /// @inner labels of it), before the labels that follow: a jump to the
    /// next statement skips the new one.
    public mutating func insert(_ opcode: UInt8, _ operands: [UInt8], after offset: Int) throws {
        try Self.checkInsertable(opcode, operands)
        let i = try opIndex(at: offset)
        try commit { p in
            var j = i + 1
            while j < p.items.count, case .inner = p.items[j] { j += 1 }
            p.items.insert(.op(opcode, operands.map { .byte($0) }), at: j)
        }
    }

    /// Writes opcode + operands as the first statement of a function (after
    /// its entry label, so every way into the function runs it).
    public mutating func insert(_ opcode: UInt8, _ operands: [UInt8], atStartOf object: Int, function: Int) throws {
        try Self.checkInsertable(opcode, operands)
        guard program.functions.indices.contains(object), (0..<CTEventPack.functionsPerObject).contains(function) else {
            throw CTEventError("no function \(function) of object \(object)")
        }
        guard case .label(let name) = program.functions[object][function] else {
            throw CTEventError("function \(function) of object \(object) points outside the scripts")
        }
        try commit { p in
            guard let at = p.items.firstIndex(of: .label(name)) else { throw CTEventError("label \(name) is not defined") }
            var j = at + 1
            while j < p.items.count, case .label = p.items[j] { j += 1 }
            p.items.insert(.op(opcode, operands.map { .byte($0) }), at: j)
        }
    }

    /// Replaces the operand bytes of the statement at `offset` (jump operands keep their labels).
    public mutating func setOperands(at offset: Int, _ operands: [UInt8]) throws {
        let i = try opIndex(at: offset)
        try commit { p in
            guard case .op(let op, let old) = p.items[i] else { return }
            guard old.count == operands.count else {
                throw CTEventError("\(CTEventISA.opcodes[Int(op)].name) takes \(old.count) operand bytes, not \(operands.count)")
            }
            let merged = zip(old, operands).map { o, b -> CTEventProgram.Operand in
                if case .label = o { return o }
                return .byte(b)
            }
            p.items[i] = .op(op, merged)
        }
    }

    /// Removes the statement at `offset`; its labels then name the next statement.
    public mutating func remove(at offset: Int) throws {
        let i = try opIndex(at: offset)
        try commit { p in
            if i + 1 < p.items.count, case .inner = p.items[i + 1] {
                throw CTEventError(String(format: "a jump lands inside the statement at $%04X", offset))
            }
            p.items.remove(at: i)
        }
    }

    /// Appends a copy of object `k` (every statement its functions reach,
    /// relabelled) as a new object, optionally placed elsewhere by its first
    /// `$8B PlaceAtTile`. Returns the new object's index.
    @discardableResult
    public mutating func duplicateObject(_ k: Int, placeAt tile: (column: Int, row: Int)? = nil) throws -> Int {
        guard program.functions.indices.contains(k) else { throw CTEventError("no object \(k)") }
        guard program.objectCount < Self.maximumObjects else {
            throw CTEventError("a pack holds at most \(Self.maximumObjects) objects")
        }
        let source = try pack()
        let analysis = CTSceneAnalysis(source)
        let reached = Set(analysis.objects[k].reached)
        let (labels, at) = try program.offsets()
        let new = program.objectCount
        let prefix = "D\(new)_"
        var copy: [CTEventProgram.Item] = []
        var copiedHost = false
        for (i, item) in program.items.enumerated() {
            switch item {
            case .label(let name):
                if reached.contains(at[i]!) { copy.append(.label(prefix + name)) }
            case .op(let op, let operands):
                copiedHost = reached.contains(at[i]!)
                guard copiedHost else { continue }
                copy.append(.op(op, operands.map { o in
                    if case .label(let name) = o { return .label(prefix + name) }
                    return o
                }))
            case .inner(let n, let name):
                if copiedHost { copy.append(.inner(n, prefix + name)) }
            case .bytes: copiedHost = false
            }
        }
        // Function entries: the copy's labels, or the original target when it
        // lies outside the scripts (or reaches nothing this object owns).
        let row = program.functions[k].map { target -> CTEventProgram.Target in
            if case .label(let name) = target, let y = labels[name], reached.contains(y) { return .label(prefix + name) }
            return target
        }
        let placement = analysis.objects[k].placementOffset
        try commit { p in
            p.objectCount += 1
            p.functions.append(row)
            p.items += copy
        }
        if let tile, let placement {
            // The copy's placement is the same statement, relabelled: find it by position.
            let moved = try CTSceneAnalysis(pack()).objects[new].placementOffset
            guard let moved else { throw CTEventError(String(format: "the copy of $%04X was not placed", placement)) }
            try setOperands(at: moved, [UInt8(clamping: tile.column), UInt8(clamping: tile.row)])
        }
        return new
    }
}

// MARK: - What a pack says about its location

public struct CTSceneAnalysis: Codable, Equatable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable {
        case control, call, wait, move, animation, dialogue, memory, sprite, battle, menu, sound, camera, screen, warp, party, other
    }

    public struct Statement: Codable, Equatable, Sendable, Identifiable {
        public var offset: Int
        public var opcode: Int
        public var name: String
        public var operands: [Int]
        public var length: Int
        public var category: Category
        public var jumpTarget: Int?
        public var id: Int { offset }
        public var text: String {
            ([name] + operands.map { String(format: "$%02X", $0) }).joined(separator: " ")
                + (jumpTarget.map { String(format: " ->$%04X", $0) } ?? "")
        }
    }

    public struct Function: Codable, Equatable, Sendable, Identifiable {
        public var index: Int
        public var role: String
        public var entry: Int
        /// False when the entry lies outside the scripts (the object never runs it).
        public var inScripts: Bool
        /// Offsets this function reaches, in address order (shared code included).
        public var statements: [Int]
        /// It returns at once: its first statement is `$00`.
        public var stub: Bool
        /// The first function of this object with the same entry, when that is another.
        public var alias: Int?
        public var id: Int { index }
    }

    public struct Marker: Codable, Equatable, Sendable {
        public var kind: String
        public var function: Int?       // nil: the continuation after the startup
        public var offset: Int
        public var operands: [Int]
        public var detail: String
    }

    public struct Object: Codable, Equatable, Sendable, Identifiable {
        public var index: Int
        public var functions: [Function]
        /// What the object runs after its startup's `$00` (Evt_RunObjInit).
        public var continuation: [Int]
        public var markers: [Marker]
        /// Every offset any of its functions or its continuation reaches.
        public var reached: [Int]
        public var id: Int { index }
        public var placementOffset: Int? { markers.first { $0.kind == "placement" }?.offset }
        public var placement: (column: Int, row: Int)? {
            markers.first { $0.kind == "placement" }.map { ($0.operands[0], $0.operands[1]) }
        }
        /// A short name from the markers ("save point", "encounter", "PC 0", ...).
        public var kind: String {
            let kinds = Set(markers.map(\.kind))
            if kinds.contains("saveMenu") { return "save point" }
            if kinds.contains("battle") { return "encounter" }
            if let pc = markers.first(where: { $0.kind == "pc" }) { return "PC \(pc.operands[0])" }
            if kinds.contains("enemySprite") { return "enemy sprite" }
            if kinds.contains("sprite") || kinds.contains("wramSprite") { return "sprite" }
            return "object"
        }
    }

    public struct Call: Codable, Equatable, Sendable {
        public var object: Int
        public var function: Int?      // nil: in the continuation
        public var offset: Int
        public var opcode: Int
        public var targetObject: Int?  // $02-$04
        public var member: Int?        // $05-$07: party member 0-2
        public var targetFunction: Int
        public var level: Int
        public var mode: EventCallMode
    }

    public var objectCount: Int
    public var objects: [Object]
    public var statements: [Statement]
    public var calls: [Call]
    public var dataBytes: Int

    public func statement(at offset: Int) -> Statement? {
        var lo = 0, hi = statements.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if statements[mid].offset == offset { return statements[mid] }
            if statements[mid].offset < offset { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    public static func role(_ function: Int) -> String {
        switch function {
        case 0: return "startup"
        case 1: return "activate"
        case 2: return "touch"
        default: return "routine \(function)"
        }
    }

    public init(_ pack: CTEventPack) {
        var statements: [Statement] = []
        for y in pack.instructions.keys.sorted() {
            let ins = pack.instructions[y]!
            var operands = pack.bytes[(y + 2)..<(y + 1 + ins.length)].map(Int.init)
            if let jump = CTEventISA.opcodes[Int(ins.opcode)].jump, ins.jumpTarget != nil {
                operands.remove(at: jump.operand - 1)
            }
            statements.append(Statement(offset: y, opcode: Int(ins.opcode), name: CTEventISA.opcodes[Int(ins.opcode)].name,
                                        operands: operands, length: ins.length,
                                        category: Self.category(ins.opcode), jumpTarget: ins.jumpTarget))
        }
        func reach(_ start: Int) -> [Int] {
            var seen = Set<Int>(), todo = [start]
            while let y = todo.popLast() {
                guard !seen.contains(y), let ins = pack.instructions[y] else { continue }
                seen.insert(y)
                todo += ins.successors
            }
            return seen.sorted()
        }
        let head = pack.headerSize, size = pack.scriptSize
        var objects: [Object] = [], calls: [Call] = []
        for k in 0..<pack.objectCount {
            var functions: [Function] = []
            var firstAt: [Int: Int] = [:]
            for (f, entry) in pack.functions[k].enumerated() {
                let inside = head <= entry && entry < size
                let alias = firstAt[entry]
                if alias == nil { firstAt[entry] = f }
                let body = inside ? (alias.map { functions[$0].statements } ?? reach(entry)) : []
                functions.append(Function(index: f, role: Self.role(f), entry: entry, inScripts: inside, statements: body,
                                          stub: inside && pack.instructions[entry]?.opcode == 0, alias: alias))
            }
            // The continuation: after each $00 that function 0 reaches.
            var continuation = Set<Int>()
            for y in functions[0].statements where pack.instructions[y]?.opcode == 0 && y + 1 < size {
                continuation.formUnion(reach(y + 1))
            }
            let cont = continuation.subtracting(functions[0].statements).sorted()
            var markers: [Marker] = []
            func scan(_ body: [Int], _ f: Int?) {
                for y in body {
                    let ins = pack.instructions[y]!
                    let ops = pack.bytes[(y + 2)..<(y + 1 + ins.length)].map(Int.init)
                    if let m = Self.marker(opcode: ins.opcode, operands: ops, function: f, offset: y) { markers.append(m) }
                    if let c = Self.call(opcode: ins.opcode, operands: ops, object: k, function: f, offset: y, objects: pack.objectCount) {
                        calls.append(c)
                    }
                }
            }
            for function in functions where function.inScripts && !function.stub && function.alias == nil {
                scan(function.statements, function.index)
            }
            scan(cont, nil)
            // One marker per offset (shared code is scanned once per function reaching it).
            var seenMarker = Set<String>()
            markers = markers.filter { seenMarker.insert("\($0.kind)@\($0.offset)").inserted }
            // The placement that counts is the startup's first (or the continuation's).
            markers.sort { ($0.function ?? 16, $0.offset) < ($1.function ?? 16, $1.offset) }
            let reached = Set(functions.flatMap(\.statements)).union(cont).sorted()
            objects.append(Object(index: k, functions: functions, continuation: cont, markers: markers, reached: reached))
        }
        var seenCall = Set<String>()
        calls = calls.filter { seenCall.insert("\($0.object)/\($0.function ?? -1)@\($0.offset)").inserted }
        self.objectCount = pack.objectCount
        self.objects = objects
        self.statements = statements
        self.calls = calls
        self.dataBytes = pack.dataByteCount
    }

    // MARK: Opcode classes (names and shapes from Evt_OpcodeTable; see event_vm_isa.json)

    /// Characters of the one-byte init opcodes ($57 description: $5C, $62, $68,
    /// $6A, $6C and $6D are characters 1, 2, 4, 3, 5 and 6).
    public static let initCharacter: [UInt8: Int] = [0x57: 0, 0x5C: 1, 0x62: 2, 0x6A: 3, 0x68: 4, 0x6C: 5, 0x6D: 6]

    public static func category(_ op: UInt8) -> Category {
        switch op {
        case 0x02...0x07: return .call
        case 0x00, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x10, 0x11, 0x12...0x16, 0x18, 0x1A, 0x27, 0x28, 0x2D, 0x30, 0x31,
             0x34...0x39, 0x3B, 0x3C, 0x3F...0x44, 0xB1, 0xB2, 0xC9, 0xCC, 0xCF, 0xD2: return .control
        case 0xAD, 0xB9, 0xBA, 0xBC, 0xBD, 0xED, 0xEE, 0xF2, 0xF3: return .wait
        case 0x7A, 0x7B, 0x89, 0x8A, 0x8B, 0x8C, 0x8D, 0x8F, 0x92, 0x94...0x9A, 0x9C...0xA1, 0xB5, 0xB6, 0xD9, 0xDA: return .move
        case 0x0F, 0x17, 0x1B, 0x1D, 0x1E, 0x1F, 0x25, 0x26, 0xA6...0xAC, 0xAE, 0xB3, 0xB4, 0xB7: return .animation
        case 0xB8, 0xBB, 0xC0...0xC4: return .dialogue
        case 0x57, 0x5C, 0x62, 0x68, 0x6A, 0x6C, 0x6D, 0x7C, 0x7D, 0x7E, 0x80...0x84, 0x87, 0x8E, 0x90, 0x91: return .sprite
        case 0x19, 0x1C, 0x20...0x24, 0x48...0x56, 0x58...0x5B, 0x5D...0x61, 0x63...0x67, 0x69, 0x6B, 0x6F,
             0x71...0x73, 0x75...0x77, 0x7F: return .memory
        case 0xD8: return .battle
        case 0xC8, 0xF8, 0xF9, 0xFA: return .menu
        case 0xE8, 0xEA, 0xEB, 0xEC: return .sound
        case 0xE7, 0xE6, 0xF4: return .camera
        case 0x2C, 0x2E, 0x33, 0x88, 0xE4, 0xE5, 0xF0, 0xF1, 0xFE: return .screen
        case 0xDC...0xE2: return .warp
        case 0xC7, 0xCA, 0xCB, 0xCD, 0xCE, 0xD0, 0xD1, 0xD3, 0xD4, 0xD6, 0xD7: return .party
        default: return .other
        }
    }

    /// The `$C8 EnterBankC2` argument as Field_SceneChangeTick ($C0:0C76 on)
    /// turns it into a BankC2_Entry8000 argument, and the menu mode that
    /// argument selects (Menu_EntryModes, $C2:808F: $0E,$00,$0C,$0D,$0F,$07,$0B).
    public static func menu(_ arg: Int) -> (bankArgument: Int, mode: Int, list: Int?) {
        let modes = [0x0E, 0x00, 0x0C, 0x0D, 0x0F, 0x07, 0x0B]
        if arg == 0 { return (5, modes[5], nil) }                  // Field_RunBankC2Mode5
        if arg & 0x80 != 0 { let a = arg >> 6 & 3; return (a, modes[a], arg & 0x3F) }   // bits 7-6, X = bits 5-0
        let a = arg & 1 == 0 ? 6 : 0                                // ExitMenu_Mode6, or 0
        return (a, modes[a], nil)
    }

    /// The `$C8` argument that opens the save-slot menu: bit 7 and bit 0 clear, nonzero.
    public static func isSaveMenu(_ arg: Int) -> Bool { menu(arg).mode == 0x0B }

    static func marker(opcode op: UInt8, operands o: [Int], function f: Int?, offset y: Int) -> Marker? {
        func m(_ kind: String, _ detail: String) -> Marker { Marker(kind: kind, function: f, offset: y, operands: o, detail: detail) }
        switch op {
        case 0x80 where o[0] <= 6: return m("pc", "Evt_Op80_InitCharObj: Chr_ObjSlot[\(o[0])] = this object")
        case _ where initCharacter[op] != nil:
            let c = initCharacter[op]!
            return Marker(kind: "pc", function: f, offset: y, operands: [c], detail: "\(CTEventISA.opcodes[Int(op)].name): character \(c)")
        case 0x81: return m("sprite", "Evt_Op81_InitSprite: RomE4_SprRec record \(o[0])")
        case 0x82: return m("wramSprite", "Evt_Op82_InitWramSprite: record \(o[0])")
        case 0x83:
            return m("enemySprite", "Evt_Op83_InitEnemySprite: RomE4_EnemySprRec record \(o[0]), OBJ tile slot \((o[1] & 0x7F) + 1)"
                     + (o[1] & 0x80 != 0 ? ", Obj_Unk1100Kind6" : ""))
        case 0x8B: return m("placement", "Evt_Op8B_PlaceAtTile: column \(o[0]), row \(o[1])")
        case 0x8D:
            return Marker(kind: "placement", function: f, offset: y, operands: [o[1], o[3]],
                          detail: "Evt_Op8D_SetPos: x $\(String(format: "%04X", o[0] | o[1] << 8)), y $\(String(format: "%04X", o[2] | o[3] << 8))")
        case 0xC8:
            let (a, mode, list) = menu(o[0])
            if mode == 0x0B {
                return m("saveMenu", "Evt_OpC8_EnterBankC2 $\(String(format: "%02X", o[0])): BankC2 argument 6, menu mode $0B, the save-slot list (Menu_Mode0BH1 confirms through Menu_Mode06H1Confirm, Menu_SaveToSlot)")
            }
            return m("menu", String(format: "Evt_OpC8_EnterBankC2 $%02X: BankC2 argument %d, menu mode $%02X", o[0], a, mode)
                     + (list.map { ", list \($0)" } ?? "") + (mode == 0x0C ? " (Menu_Mode0C: the shop list)" : ""))
        case 0xD8:
            var bits: [String] = []
            if o[1] & 0x20 != 0 { bits.append("FieldBtl_EvtNoReset (the field is rebuilt even when the battle returns 1)") }
            if o[1] & 0x40 != 0 { bits.append("FieldBtl_EvtKeepMusic") }
            if o[1] & 0x80 != 0 { bits.append("FieldBtl_EvtUnk80 (members 2 and 3 keep their scripts)") }
            return m("battle", String(format: "Evt_OpD8_StartBattle: Battle_Unk2989 = $%02X, FieldBtl_EvtFlags = $%02X", o[0], o[1])
                     + (bits.isEmpty ? "" : "; " + bits.joined(separator: ", ")))
        case 0x7E: return m("battleObject", "Evt_Op7E_SetUnk1A81Bit7: FieldBtl_ObjUnk1A81Bit, carried into the battle hand-off (FieldBtlObj.Flags)")
        default: return nil
        }
    }

    static func call(opcode op: UInt8, operands o: [Int], object: Int, function: Int?, offset: Int, objects: Int) -> Call? {
        guard (0x02...0x07).contains(op) else { return nil }
        let mode: EventCallMode = [.start, .retry, .wait][Int(op - 2) % 3]
        let target = o[0] / 2
        return Call(object: object, function: function, offset: offset, opcode: Int(op),
                    targetObject: op <= 0x04 ? target : nil, member: op >= 0x05 ? target : nil,
                    targetFunction: o[1] & 0x0F, level: o[1] >> 4, mode: mode)
    }
}

// MARK: - The graph of objects and functions

public struct CTSceneGraph: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable, Hashable, Identifiable {
        public var object: Int
        public var function: Int          // 16: the continuation after the startup
        public var id: String { "\(object).\(function)" }
    }
    public struct Edge: Codable, Equatable, Sendable {
        public var from: Node
        public var to: Node?              // nil for party calls
        public var member: Int?
        public var level: Int
        public var mode: EventCallMode
        public var offset: Int
    }
    public static let continuation = 16
    public var nodes: [Node]
    public var edges: [Edge]

    /// Functions sharing an entry are one node, named by the first of them.
    public init(_ a: CTSceneAnalysis) {
        var nodes: [Node] = []
        for o in a.objects {
            for f in o.functions where f.inScripts && !f.stub && f.alias == nil { nodes.append(Node(object: o.index, function: f.index)) }
            if !o.continuation.isEmpty { nodes.append(Node(object: o.index, function: Self.continuation)) }
        }
        edges = a.calls.map { c in
            let to = c.targetObject.map { t in
                Node(object: t, function: a.objects.indices.contains(t) ? a.objects[t].functions[c.targetFunction].alias ?? c.targetFunction : c.targetFunction)
            }
            return Edge(from: Node(object: c.object, function: c.function ?? Self.continuation),
                        to: to, member: c.member,
                        level: c.level, mode: c.mode, offset: c.offset)
        }
        self.nodes = nodes
    }

    public func render() -> String {
        func name(_ n: Node) -> String {
            "obj \(n.object) " + (n.function == Self.continuation ? "continuation" : "func \(n.function) (\(CTSceneAnalysis.role(n.function)))")
        }
        var lines = ["; ct-scene graph: \(nodes.count) nodes, \(edges.count) calls"]
        for n in nodes { lines.append("node " + name(n)) }
        for e in edges {
            let to = e.to.map(name) ?? "party member \(e.member ?? 0) func \(e.to?.function ?? 0)"
            lines.append(String(format: "call $%04X ", e.offset) + "\(name(e.from)) -> \(to) [\(e.mode.rawValue), level \(e.level)]")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - Listing text with object and function headings

extension CTSceneDocument {
    /// The ct-events/1 listing with `;` headings before each function entry;
    /// it parses back to the same program. `lineOffsets[i]` is the Evt_Data
    /// offset of line i's opcode (nil for other lines).
    public func annotatedListing(title: String? = nil) throws -> (text: String, lineOffsets: [Int?]) {
        let plain = CTEventListing.render(program, title: title)
        var lines = plain.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        var headings: [String: [String]] = [:]
        for (o, row) in program.functions.enumerated() {
            for (f, target) in row.enumerated() {
                if case .label(let name) = target {
                    headings[name, default: []].append("obj \(o) func \(f) (\(CTSceneAnalysis.role(f)))")
                }
            }
        }
        let (_, at) = try program.offsets()
        // Body lines are the items in order, after the header lines.
        let header = lines.count - program.items.reduce(0) { n, item in
            if case .bytes(let data) = item { return n + (data.count + 15) / 16 }
            return n + 1
        }
        var out: [String] = Array(lines[0..<header]), offsets = [Int?](repeating: nil, count: header)
        var line = header
        for (i, item) in program.items.enumerated() {
            let count: Int
            if case .bytes(let data) = item { count = (data.count + 15) / 16 } else { count = 1 }
            if case .label(let name) = item, let names = headings[name] {
                let shown = names.count > 3 ? names.prefix(3).joined(separator: "; ") + "; +\(names.count - 3) more" : names.joined(separator: "; ")
                out.append("; ── " + shown); offsets.append(nil)
            }
            for k in 0..<count {
                out.append(lines[line + k])
                if case .op = item, k == 0 { offsets.append(at[i]) } else { offsets.append(nil) }
            }
            line += count
        }
        return (out.joined(separator: "\n") + "\n", offsets)
    }
}

// MARK: - JSON (ct-scene/1)

extension CTSceneDocument: Codable {
    private enum CodingKeys: String, CodingKey { case schema, location, packEntry, objects, functions, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try c.decode(String.self, forKey: .schema)
        guard schema == Self.schema else { throw CTEventError("expected schema \(Self.schema), got \(schema)") }
        location = try c.decodeIfPresent(Int.self, forKey: .location)
        packEntry = try c.decodeIfPresent(Int.self, forKey: .packEntry)
        let functions = try c.decode([[String]].self, forKey: .functions).map { row in
            try row.map { t -> CTEventProgram.Target in
                if t.hasPrefix("$"), let v = Int(t.dropFirst(), radix: 16) { return .offset(v) }
                guard !t.isEmpty else { throw CTEventError("empty function target") }
                return .label(t)
            }
        }
        program = CTEventProgram(objectCount: try c.decode(Int.self, forKey: .objects), functions: functions,
                                 items: try c.decode([CTSceneItem].self, forKey: .items).map(\.item))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.schema, forKey: .schema)
        try c.encodeIfPresent(location, forKey: .location)
        try c.encodeIfPresent(packEntry, forKey: .packEntry)
        try c.encode(program.objectCount, forKey: .objects)
        try c.encode(program.functions.map { row in
            row.map { t -> String in
                switch t {
                case .label(let name): return name
                case .offset(let v): return String(format: "$%04X", v)
                }
            }
        }, forKey: .functions)
        try c.encode(program.items.map(CTSceneItem.init), forKey: .items)
    }
}

/// One program item: {"label": "L_0020"}, {"op": "Op96_WalkToTile", "operands": [5, 7]}
/// (a jump operand is its label), {"inner": 2, "label": "L_0022"}, {"bytes": "99AB"}.
struct CTSceneItem: Codable {
    let item: CTEventProgram.Item
    init(_ item: CTEventProgram.Item) { self.item = item }

    private enum Operand: Codable {
        case byte(UInt8), label(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(UInt8.self) { self = .byte(b) } else { self = .label(try c.decode(String.self)) }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .byte(let b): try c.encode(b)
            case .label(let s): try c.encode(s)
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case label, op, operands, inner, bytes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let name = try c.decodeIfPresent(String.self, forKey: .op) {
            guard let op = CTEventListing.byName[name] else { throw CTEventError("unknown opcode \(name)") }
            let operands = try c.decodeIfPresent([Operand].self, forKey: .operands) ?? []
            item = .op(op, operands.map {
                switch $0 {
                case .byte(let b): return .byte(b)
                case .label(let s): return .label(s)
                }
            })
        } else if let hex = try c.decodeIfPresent(String.self, forKey: .bytes) {
            guard hex.count % 2 == 0, !hex.isEmpty else { throw CTEventError("bytes must be pairs of hex digits") }
            var data: [UInt8] = [], i = hex.startIndex
            while i < hex.endIndex {
                let j = hex.index(i, offsetBy: 2)
                guard let b = UInt8(hex[i..<j], radix: 16) else { throw CTEventError("bad hex \(hex[i..<j])") }
                data.append(b); i = j
            }
            item = .bytes(data)
        } else if let k = try c.decodeIfPresent(Int.self, forKey: .inner) {
            item = .inner(k, try c.decode(String.self, forKey: .label))
        } else {
            item = .label(try c.decode(String.self, forKey: .label))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch item {
        case .label(let name): try c.encode(name, forKey: .label)
        case .op(let op, let operands):
            try c.encode(CTEventListing.names[Int(op)], forKey: .op)
            if !operands.isEmpty {
                try c.encode(operands.map { o -> Operand in
                    switch o {
                    case .byte(let b): return .byte(b)
                    case .label(let s): return .label(s)
                    }
                }, forKey: .operands)
            }
        case .inner(let k, let name): try c.encode(k, forKey: .inner); try c.encode(name, forKey: .label)
        case .bytes(let data): try c.encode(data.map { String(format: "%02X", $0) }.joined(), forKey: .bytes)
        }
    }
}
