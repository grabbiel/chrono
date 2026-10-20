// Lowering of Studio scenes (ctproj/1 DSL) to a Chrono Trigger event pack.
// Only operations with handler evidence are emitted; see docs/event_bytecode.md.
import Foundation

public enum CTEventLowering {
    /// A pack built from Studio scenes. Message indices are local to this pack;
    /// `relocations` must be patched by a ROM builder before the pack can run.
    public struct Output: Codable, Equatable, Sendable {
        public struct Relocation: Codable, Equatable, Sendable {
            public let offset: Int          // index into `bytes` (byte 0 = object count)
            public let size: Int
            public let kind: String         // "messageTable": 24-bit pointer for OpB8_SetMsgPtr
        }
        public let schema: String
        public let bytes: [UInt8]           // unpacked, as loaded to $7F:2000
        public let messages: [String]       // string IDs by message index
        public let relocations: [Relocation]
        public let listing: String
    }

    public static let opReturn: UInt8 = 0x00, opJumpFwd: UInt8 = 0x10, opJumpBack: UInt8 = 0x11
    public static let opIfMemByte: UInt8 = 0x16, opSetMemBit: UInt8 = 0x65, opClearMemBit: UInt8 = 0x66
    public static let opWaitRuns: UInt8 = 0xAD, opHalt: UInt8 = 0xB2, opSetMsgPtr: UInt8 = 0xB8, opMsg: UInt8 = 0xBB
    public static let cmpAndNonzero: UInt8 = 6

    public static func lower(project: CTProject, scenes ids: [String]) throws -> Output {
        let scenes = try ids.map { id -> (id: String?, scene: EventScene) in
            guard let scene = project.scenes[id]?.scene else { throw CTEventError("unknown scene \(id)") }
            return (id, scene)
        }
        return try lower(named: scenes, flag: flagResolver(project.project.flags))
    }

    /// Opcodes a `ct` statement may not use: the message opcodes take indices
    /// into the pack's message table, which `text` statements own.
    public static let reservedOpcodes: Set<UInt8> = [opSetMsgPtr, opMsg, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4]

    /// Why `ct opcode operands` cannot be lowered, or nil: the derived table
    /// must give exactly this length and a flow that goes on to the next opcode.
    public static func ctProblem(opcode: UInt8, operands: [UInt8]) -> String? {
        let op = CTEventISA.opcodes[Int(opcode)]
        if reservedOpcodes.contains(opcode) {
            return "ct \(op.name): message opcodes are written by text statements"
        }
        let bytes = [opcode] + operands
        guard let (length, flow) = op.resolve(bytes[...], at: 0) else {
            return "ct \(op.name): unused or untraced opcode, or the operand that decides its length is missing"
        }
        guard length == bytes.count else {
            return "ct \(op.name): takes \(length - 1) operand bytes here, got \(operands.count)"
        }
        // `e` (a path the tracer could not follow to a known position, e.g. the
        // walks' saved offsets) is accepted next to `n`; jumps and pure ends are not.
        guard flow.contains(.next), !flow.contains(.jump) else {
            return "ct \(op.name): changes control flow; use if, jump or call statements"
        }
        return nil
    }

    public static func lower(scenes: [EventScene],
                             flag: (String) throws -> (m: UInt8, page: Bool, bit: UInt8)) throws -> Output {
        try lower(named: scenes.map { (nil, $0) }, flag: flag)
    }

    /// Looks up project flags by symbol for `lower(scenes:flag:)`.
    public static func flagResolver(_ flags: [Project.Flag]) -> (String) throws -> (m: UInt8, page: Bool, bit: UInt8) {
        let bySymbol = Dictionary(flags.map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        return { symbol in
            guard let f = bySymbol[symbol] else { throw CTEventError("unknown flag \(symbol)") }
            return try memoryBit(addr: f.addr, bit: f.bit, symbol: symbol)
        }
    }

    /// ($7F:0000 + m, page bit) and bit number of a project flag. The bit and
    /// test opcodes reach $7F:0000-$7F:01FF; bit numbers 8-15 read past BitSet.
    public static func memoryBit(addr: String, bit: Int, symbol: String) throws -> (m: UInt8, page: Bool, bit: UInt8) {
        let parts = addr.split(separator: ":")
        guard parts.count == 2, let bank = Int(parts[0], radix: 16), let low = Int(parts[1], radix: 16),
              bank == 0x7F, (0...0x1FF).contains(low) else {
            throw CTEventError("flag \(symbol) at \(addr): event bit opcodes reach only 7F:0000-7F:01FF")
        }
        guard (0...7).contains(bit) else { throw CTEventError("flag \(symbol): bit \(bit) is not 0-7") }
        return (UInt8(low & 0xFF), low >= 0x100, UInt8(bit))
    }

    /// Scenes with their project IDs (for `call_obj`), one per object slot.
    public static func lower(named: [(id: String?, scene: EventScene)],
                             flag: (String) throws -> (m: UInt8, page: Bool, bit: UInt8)) throws -> Output {
        guard !named.isEmpty else { throw CTEventError("no scenes to lower") }
        let scenes = named.map(\.scene)
        var byID: [String: EventScene] = [:]
        for case let (id?, scene) in named { byID[id] = scene }
        var bySlot: [Int: EventScene] = [:]
        for scene in scenes {
            guard (0...15).contains(scene.object) else { throw CTEventError("object \(scene.object) is not 0-15") }
            guard bySlot.updateValue(scene, forKey: scene.object) == nil else {
                throw CTEventError("two scenes use object \(scene.object)")
            }
        }
        let objectCount = bySlot.keys.max()! + 1
        var messages: [String] = [], messageIndex: [String: Int] = [:]
        func message(_ id: String) throws -> UInt8 {
            if let i = messageIndex[id] { return UInt8(i) }
            guard messages.count < 256 else { throw CTEventError("more than 256 messages in one pack") }
            messageIndex[id] = messages.count
            messages.append(id)
            return UInt8(messages.count - 1)
        }
        var items: [CTEventProgram.Item] = []
        var functions: [[CTEventProgram.Target]] = []
        var serial = 0
        func fresh(_ stem: String) -> String { serial += 1; return "\(stem)_\(serial)" }
        func entry(_ o: Int, _ f: Int) -> String { "O\(o)_F\(f)" }

        func emit(_ stmts: [EventStmt], object: Int, defined: Set<Int>) throws {
            for stmt in stmts {
                switch stmt {
                case .nop: break
                case .wait(let frames):
                    guard frames >= 0 else { throw CTEventError("negative wait") }
                    var left = frames
                    while left > 0 {
                        let n = min(left, 255)
                        items.append(.op(opWaitRuns, [.byte(UInt8(n))]))
                        left -= n
                    }
                case .setFlag(let symbol), .clearFlag(let symbol):
                    let f = try flag(symbol)
                    let op = { if case .setFlag = stmt { return opSetMemBit } else { return opClearMemBit } }()
                    items.append(.op(op, [.byte(f.bit | (f.page ? 0x80 : 0)), .byte(f.m)]))
                case .text(let id):
                    items.append(.op(opMsg, [.byte(try message(id))]))
                case .call(let map, let index):
                    throw CTEventError("call \(map)#\(index): cross-map calls have no ctproj/1 binding to an object and function yet; use call_obj for scenes in this pack")
                case .callObject(let id, let index, let mode, let level):
                    guard let target = byID[id] else {
                        throw CTEventError("call_obj \(id)#\(index): scene \(id) is not lowered into this pack")
                    }
                    guard target.funcs.contains(where: { $0.index == index }) else {
                        throw CTEventError("call_obj \(id)#\(index): scene \(id) has no func \(index)")
                    }
                    let op: UInt8 = [EventCallMode.start: 0x02, .retry: 0x03, .wait: 0x04][mode]!
                    items.append(.op(op, [.byte(UInt8(target.object * 2)), .byte(UInt8(level << 4 | index))]))
                case .callMember(let member, let index, let mode, let level):
                    let op: UInt8 = [EventCallMode.start: 0x05, .retry: 0x06, .wait: 0x07][mode]!
                    items.append(.op(op, [.byte(UInt8(member * 2)), .byte(UInt8(level << 4 | index))]))
                case .ct(let opcode, let operands):
                    if let problem = ctProblem(opcode: opcode, operands: operands) { throw CTEventError(problem) }
                    items.append(.op(opcode, operands.map { .byte($0) }))
                case .jump(let index):
                    guard defined.contains(index) else { throw CTEventError("jump to undefined func\(index)") }
                    // $10 or $11 is chosen once offsets are known; both are 2 bytes.
                    items.append(.op(opJumpFwd, [.label(entry(object, index))]))
                case .ifFlag(let symbol, let then, let otherwise):
                    let f = try flag(symbol)
                    let elseLabel = fresh("ELSE"), endLabel = fresh("END")
                    items.append(.op(opIfMemByte, [.byte(f.m), .byte(1 << f.bit),
                                                   .byte(cmpAndNonzero | (f.page ? 0x80 : 0)),
                                                   .label(otherwise.isEmpty ? endLabel : elseLabel)]))
                    try emit(then, object: object, defined: defined)
                    if !otherwise.isEmpty {
                        items.append(.op(opJumpFwd, [.label(endLabel)]))
                        items.append(.label(elseLabel))
                        try emit(otherwise, object: object, defined: defined)
                    }
                    items.append(.label(endLabel))
                }
            }
        }

        for object in 0..<objectCount {
            let stub = "O\(object)_RET"
            let funcs = bySlot[object]?.funcs ?? []
            let defined = Set(funcs.map(\.index))
            guard defined.count == funcs.count, defined.allSatisfy({ (0...15).contains($0) }) else {
                throw CTEventError("object \(object): functions must be unique 0-15")
            }
            var row = [CTEventProgram.Target](repeating: .label(stub), count: CTEventPack.functionsPerObject)
            let needsStub = defined.count < CTEventPack.functionsPerObject
            if !defined.contains(0) {
                // No init: the object returns at once and rests on the halt after it.
                row[0] = .label(stub)
            }
            for function in funcs.sorted(by: { $0.index < $1.index }) {
                row[function.index] = .label(entry(object, function.index))
                items.append(.label(entry(object, function.index)))
                if object == 0 && function.index == 0 {
                    items.append(.op(opSetMsgPtr, [.byte(0), .byte(0), .byte(0)]))
                }
                try emit(function.stmts, object: object, defined: defined)
                items += [.op(opReturn, []), .op(opHalt, [])]
            }
            if needsStub || !defined.contains(0) {
                items.append(.label(stub))
                if object == 0 && !defined.contains(0) {
                    items.append(.op(opSetMsgPtr, [.byte(0), .byte(0), .byte(0)]))
                }
                items += [.op(opReturn, []), .op(opHalt, [])]
            }
            functions.append(row)
        }
        // The message pointer is only needed when there are messages.
        if messages.isEmpty {
            items.removeAll { $0 == .op(opSetMsgPtr, [.byte(0), .byte(0), .byte(0)]) }
        }
        var program = CTEventProgram(objectCount: objectCount, functions: functions, items: items)
        // Direction of each local jump, now that offsets are fixed.
        let (labels, offsets) = try program.offsets()
        for (i, item) in program.items.enumerated() {
            if case .op(opJumpFwd, let operands) = item, case .label(let name)? = operands.first,
               let target = labels[name], target <= offsets[i]! {
                program.items[i] = .op(opJumpBack, operands)
            }
        }
        let bytes = try program.assemble()
        var relocations: [Output.Relocation] = []
        let (_, final) = try program.offsets()
        for (i, item) in program.items.enumerated() where item == .op(opSetMsgPtr, [.byte(0), .byte(0), .byte(0)]) {
            relocations.append(.init(offset: final[i]! + 2, size: 3, kind: "messageTable"))
        }
        return Output(schema: "ct-event-lowered/1", bytes: bytes, messages: messages, relocations: relocations,
                      listing: CTEventListing.render(program, title: "lowered from Studio scenes; message pointer unrelocated"))
    }
}

extension CTEventProgram {
    /// Offsets (relative to Evt_Data) of labels and of each item.
    public func offsets() throws -> (labels: [String: Int], items: [Int: Int]) {
        var labels: [String: Int] = [:], at: [Int: Int] = [:]
        var offset = objectCount * 2 * CTEventPack.functionsPerObject
        var last: Int?
        for (i, item) in items.enumerated() {
            at[i] = offset
            switch item {
            case .label(let name): labels[name] = offset
            case .op(_, let operands): last = offset; offset += 1 + operands.count
            case .inner(let k, let name):
                guard let host = last else { throw CTEventError("@inner without an opcode") }
                labels[name] = host + k
            case .bytes(let data): offset += data.count; last = nil
            }
        }
        return (labels, at)
    }
}
