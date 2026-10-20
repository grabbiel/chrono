// Studio scene AST and internal bytecode. This format is NOT CT ROM bytecode.
// ROM export requires a separate, evidence-backed lowering pass.
import Foundation

public indirect enum EventStmt: Equatable, Sendable {
    case nop
    case wait(frames: Int)
    case setFlag(symbol: String)
    case clearFlag(symbol: String)
    case text(stringID: String)
    case call(map: String, funcIndex: Int)
    case jump(funcIndex: Int)
    case ifFlag(symbol: String, then: [EventStmt], else: [EventStmt])
    /// Run function `funcIndex` of the object another scene of the same pack
    /// occupies (CT opcodes $02-$04), at priority `level` (0 most urgent, 6).
    case callObject(scene: String, funcIndex: Int, mode: EventCallMode, level: Int)
    /// The same on party member `member`'s object (0-2; CT opcodes $05-$07).
    case callMember(member: Int, funcIndex: Int, mode: EventCallMode, level: Int)
    /// One CT event opcode with its operand bytes, checked against the derived
    /// opcode table when lowered (no jumps, ends or message opcodes).
    case ct(opcode: UInt8, operands: [UInt8])
}

/// How a call statement starts the target's function (CT call opcodes).
public enum EventCallMode: String, Codable, CaseIterable, Sendable {
    case start      // $02/$05: start it if the target can take it, never wait
    case retry      // $03/$06: wait until the target can take it, then go on
    case wait       // $04/$07: as retry, then wait until the function ends
}

// Human-friendly, stable JSON: {"op": "text", "stringID": "greeting"} etc.
extension EventStmt: Codable {
    private enum Op: String, Codable {
        case nop, wait, set_flag, clear_flag, text, call, jump, if_flag, call_obj, call_pc, ct
    }
    private enum CodingKeys: String, CodingKey {
        case op, frames, symbol, stringID, map, `func`, then, `else`, scene, member, mode, level, opcode, operands
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .nop: self = .nop
        case .wait: self = .wait(frames: try c.decode(Int.self, forKey: .frames))
        case .set_flag: self = .setFlag(symbol: try c.decode(String.self, forKey: .symbol))
        case .clear_flag: self = .clearFlag(symbol: try c.decode(String.self, forKey: .symbol))
        case .text: self = .text(stringID: try c.decode(String.self, forKey: .stringID))
        case .call: self = .call(map: try c.decode(String.self, forKey: .map),
                                 funcIndex: try c.decode(Int.self, forKey: .func))
        case .jump: self = .jump(funcIndex: try c.decode(Int.self, forKey: .func))
        case .if_flag: self = .ifFlag(symbol: try c.decode(String.self, forKey: .symbol),
                                      then: try c.decode([EventStmt].self, forKey: .then),
                                      else: try c.decode([EventStmt].self, forKey: .`else`))
        case .call_obj: self = .callObject(scene: try c.decode(String.self, forKey: .scene),
                                           funcIndex: try c.decode(Int.self, forKey: .func),
                                           mode: try c.decode(EventCallMode.self, forKey: .mode),
                                           level: try c.decode(Int.self, forKey: .level))
        case .call_pc: self = .callMember(member: try c.decode(Int.self, forKey: .member),
                                          funcIndex: try c.decode(Int.self, forKey: .func),
                                          mode: try c.decode(EventCallMode.self, forKey: .mode),
                                          level: try c.decode(Int.self, forKey: .level))
        case .ct: self = .ct(opcode: try c.decode(UInt8.self, forKey: .opcode),
                             operands: try c.decode([UInt8].self, forKey: .operands))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nop: try c.encode(Op.nop, forKey: .op)
        case .wait(let f): try c.encode(Op.wait, forKey: .op); try c.encode(f, forKey: .frames)
        case .setFlag(let s): try c.encode(Op.set_flag, forKey: .op); try c.encode(s, forKey: .symbol)
        case .clearFlag(let s): try c.encode(Op.clear_flag, forKey: .op); try c.encode(s, forKey: .symbol)
        case .text(let s): try c.encode(Op.text, forKey: .op); try c.encode(s, forKey: .stringID)
        case .call(let m, let f): try c.encode(Op.call, forKey: .op); try c.encode(m, forKey: .map); try c.encode(f, forKey: .func)
        case .jump(let f): try c.encode(Op.jump, forKey: .op); try c.encode(f, forKey: .func)
        case .ifFlag(let s, let t, let e):
            try c.encode(Op.if_flag, forKey: .op); try c.encode(s, forKey: .symbol)
            try c.encode(t, forKey: .then); try c.encode(e, forKey: .`else`)
        case .callObject(let scene, let f, let mode, let level):
            try c.encode(Op.call_obj, forKey: .op); try c.encode(scene, forKey: .scene); try c.encode(f, forKey: .func)
            try c.encode(mode, forKey: .mode); try c.encode(level, forKey: .level)
        case .callMember(let member, let f, let mode, let level):
            try c.encode(Op.call_pc, forKey: .op); try c.encode(member, forKey: .member); try c.encode(f, forKey: .func)
            try c.encode(mode, forKey: .mode); try c.encode(level, forKey: .level)
        case .ct(let opcode, let operands):
            try c.encode(Op.ct, forKey: .op); try c.encode(opcode, forKey: .opcode); try c.encode(operands, forKey: .operands)
        }
    }
}

public struct EventFunc: Equatable, Sendable, Codable {
    public var index: Int
    public var stmts: [EventStmt]
    public init(index: Int, stmts: [EventStmt]) { self.index = index; self.stmts = stmts }
}

public struct NodeMeta: Equatable, Sendable, Codable {
    public var nodeID: Int
    public var x: Int
    public var y: Int
    private enum CodingKeys: String, CodingKey { case nodeID = "node_id", x, y }
    public init(nodeID: Int, x: Int, y: Int) { self.nodeID = nodeID; self.x = x; self.y = y }
}

public struct EventScene: Equatable, Sendable, Codable {
    public var object: Int            // object slot 0..15
    public var funcs: [EventFunc]
    public var layout: [NodeMeta]
    public init(object: Int, funcs: [EventFunc], layout: [NodeMeta] = []) {
        self.object = object; self.funcs = funcs; self.layout = layout
    }
}

/// Internal Studio bytecode, retained for ctproj/1 compatibility. Not a ROM format.
public enum EventBytecode {
    static let opNop: UInt8 = 0x00
    static let opWait: UInt8 = 0x01
    static let opSetFlag: UInt8 = 0x02
    static let opClearFlag: UInt8 = 0x03
    static let opText: UInt8 = 0x04
    static let opCall: UInt8 = 0x05
    static let opJump: UInt8 = 0x06
    static let opIfFlag: UInt8 = 0x07
    static let opElse: UInt8 = 0x08
    static let opEndIf: UInt8 = 0x09
    static let opCallObject: UInt8 = 0x0A
    static let opCallMember: UInt8 = 0x0B
    static let opCT: UInt8 = 0x0C
    static let opEndFunc: UInt8 = 0xFF

    // MARK: compile
    public static func compile(_ funcs: [EventFunc]) throws -> [UInt8] {
        try validate(funcs)
        var out: [UInt8] = []
        out.append(UInt8(funcs.count))
        for f in funcs {
            out.append(UInt8(f.index))
            emit(f.stmts, into: &out)
            out.append(opEndFunc)
        }
        return out
    }
    static func emit(_ stmts: [EventStmt], into out: inout [UInt8]) {
        for s in stmts {
            switch s {
            case .nop: out.append(opNop)
            case .wait(let fr): out.append(opWait); out16(fr, &out)
            case .setFlag(let sym): out.append(opSetFlag); str(sym, &out)
            case .clearFlag(let sym): out.append(opClearFlag); str(sym, &out)
            case .text(let id): out.append(opText); str(id, &out)
            case .call(let map, let fi): out.append(opCall); str(map, &out); out.append(UInt8(fi))
            case .jump(let fi): out.append(opJump); out.append(UInt8(fi))
            case .ifFlag(let sym, let t, let e):
                out.append(opIfFlag); str(sym, &out)
                emit(t, into: &out)
                if !e.isEmpty { out.append(opElse); emit(e, into: &out) }
                out.append(opEndIf)
            case .callObject(let scene, let fi, let mode, let level):
                out.append(opCallObject); str(scene, &out); out.append(UInt8(fi))
                out.append(UInt8(EventCallMode.allCases.firstIndex(of: mode)!)); out.append(UInt8(level))
            case .callMember(let member, let fi, let mode, let level):
                out.append(opCallMember); out.append(UInt8(member)); out.append(UInt8(fi))
                out.append(UInt8(EventCallMode.allCases.firstIndex(of: mode)!)); out.append(UInt8(level))
            case .ct(let opcode, let operands):
                out.append(opCT); out.append(opcode); out.append(UInt8(operands.count)); out.append(contentsOf: operands)
            }
        }
    }
    static func out16(_ v: Int, _ out: inout [UInt8]) {
        let u = UInt16(v)
        out.append(UInt8(u & 0xFF)); out.append(UInt8(u >> 8))
    }
    static func str(_ s: String, _ out: inout [UInt8]) {
        let b = Array(s.utf8)
        out.append(UInt8(b.count)); out.append(contentsOf: b)
    }

    // MARK: decompile
    public struct CompileError: Error, CustomStringConvertible {
        public var message: String
        public init(_ m: String) { message = m }
        public var description: String { message }
    }

    public static func decompile(_ code: [UInt8]) throws -> [EventFunc] {
        var i = 0
        func byte() throws -> UInt8 { guard i < code.count else { throw CompileError("eof") }; defer { i += 1 }; return code[i] }
        func u16() throws -> Int { let a = try byte(); let b = try byte(); return Int(a) | (Int(b) << 8) }
        func string() throws -> String {
            let n = Int(try byte())
            guard i + n <= code.count else { throw CompileError("eof in string") }
            guard let s = String(bytes: code[i..<(i + n)], encoding: .utf8) else {
                throw CompileError("invalid UTF-8 at byte \(i)")
            }
            i += n; return s
        }
        func mode() throws -> EventCallMode {
            let m = Int(try byte())
            guard m < EventCallMode.allCases.count else { throw CompileError("bad call mode \(m)") }
            return EventCallMode.allCases[m]
        }
        func stmts(depth: Int = 0) throws -> [EventStmt] {
            guard depth <= maximumNesting else { throw CompileError("conditional nesting exceeds \(maximumNesting)") }
            var list: [EventStmt] = []
            while true {
                let op = try byte()
                switch op {
                case opEndFunc, opElse, opEndIf: i -= 1; return list
                case opNop: list.append(.nop)
                case opWait: list.append(.wait(frames: try u16()))
                case opSetFlag: list.append(.setFlag(symbol: try string()))
                case opClearFlag: list.append(.clearFlag(symbol: try string()))
                case opText: list.append(.text(stringID: try string()))
                case opCall: list.append(.call(map: try string(), funcIndex: Int(try byte())))
                case opJump: list.append(.jump(funcIndex: Int(try byte())))
                case opIfFlag:
                    let sym = try string()
                    let then = try stmts(depth: depth + 1)
                    var els: [EventStmt] = []
                    var end = try byte()
                    if end == opElse {
                        els = try stmts(depth: depth + 1)
                        end = try byte()
                    }
                    guard end == opEndIf else { throw CompileError("missing endif at byte \(i - 1)") }
                    list.append(.ifFlag(symbol: sym, then: then, else: els))
                case opCallObject:
                    let scene = try string(), fi = Int(try byte())
                    list.append(.callObject(scene: scene, funcIndex: fi, mode: try mode(), level: Int(try byte())))
                case opCallMember:
                    let member = Int(try byte()), fi = Int(try byte())
                    list.append(.callMember(member: member, funcIndex: fi, mode: try mode(), level: Int(try byte())))
                case opCT:
                    let opcode = try byte(), n = Int(try byte())
                    guard i + n <= code.count else { throw CompileError("eof in ct operands") }
                    list.append(.ct(opcode: opcode, operands: Array(code[i..<(i + n)])))
                    i += n
                default: throw CompileError("bad opcode 0x\(String(op, radix: 16))")
                }
            }
        }
        let n = Int(try byte())
        var funcs: [EventFunc] = []
        for _ in 0..<n {
            let idx = Int(try byte())
            let body = try stmts()
            let term = try byte()
            guard term == opEndFunc else { throw CompileError("missing endfunc") }
            funcs.append(EventFunc(index: idx, stmts: body))
        }
        guard i == code.count else { throw CompileError("trailing bytes at byte \(i)") }
        try validate(funcs)
        return funcs
    }

    public static let maximumNesting = 64

    /// Reject lossy integer/string conversions before writing any output.
    public static func validate(_ funcs: [EventFunc]) throws {
        guard funcs.count <= 16 else { throw CompileError("a scene supports at most 16 functions") }
        var indices = Set<Int>()
        for f in funcs {
            guard (0...15).contains(f.index), indices.insert(f.index).inserted else {
                throw CompileError("function indices must be unique and in 0...15 (got \(f.index))")
            }
        }
        func symbol(_ value: String) throws {
            guard !value.isEmpty, value.utf8.count <= 255 else {
                throw CompileError("identifiers must contain 1...255 UTF-8 bytes")
            }
        }
        func callTarget(_ index: Int, _ level: Int) throws {
            guard (0...15).contains(index) else { throw CompileError("call function must be in 0...15") }
            guard (0...6).contains(level) else { throw CompileError("call level must be in 0...6 (7 is an idle object's)") }
        }
        func walk(_ body: [EventStmt], depth: Int) throws {
            guard depth <= maximumNesting else { throw CompileError("conditional nesting exceeds \(maximumNesting)") }
            for stmt in body {
                switch stmt {
                case .nop: break
                case .wait(let frames):
                    guard (0...65535).contains(frames) else { throw CompileError("wait must be in 0...65535 frames") }
                case .setFlag(let s), .clearFlag(let s), .text(let s): try symbol(s)
                case .call(let map, let index):
                    try symbol(map)
                    guard (0...15).contains(index) else { throw CompileError("call function must be in 0...15") }
                case .jump(let index):
                    guard indices.contains(index) else { throw CompileError("jump to missing function \(index)") }
                case .ifFlag(let s, let t, let e):
                    try symbol(s)
                    try walk(t, depth: depth + 1)
                    try walk(e, depth: depth + 1)
                case .callObject(let scene, let index, _, let level):
                    try symbol(scene)
                    try callTarget(index, level)
                case .callMember(let member, let index, _, let level):
                    guard (0...2).contains(member) else { throw CompileError("party member must be 0, 1 or 2") }
                    try callTarget(index, level)
                case .ct(_, let operands):
                    guard operands.count <= 255 else { throw CompileError("ct takes at most 255 operand bytes") }
                }
            }
        }
        for f in funcs { try walk(f.stmts, depth: 0) }
    }

    public static func validate(_ scene: EventScene) throws {
        guard (0...15).contains(scene.object) else { throw CompileError("object slot must be in 0...15") }
        try validate(scene.funcs)
        var ids = Set<Int>()
        for node in scene.layout {
            guard node.nodeID >= 0, ids.insert(node.nodeID).inserted else {
                throw CompileError("layout node IDs must be nonnegative and unique")
            }
        }
    }
}
