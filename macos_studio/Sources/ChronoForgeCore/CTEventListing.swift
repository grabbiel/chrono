// Editable form of a CT event pack: labels, opcodes with symbolic jump
// operands, and data bytes no opcode reaches. Text listings, ROM imports and
// the Studio scene lowering all assemble through CTEventProgram.
import Foundation

public struct CTEventProgram: Equatable, Sendable {
    public enum Operand: Equatable, Sendable {
        case byte(UInt8)
        case label(String)              // the opcode's jump operand
    }
    public enum Target: Equatable, Sendable {
        case label(String)
        case offset(Int)                // a function offset outside the scripts
    }
    public enum Item: Equatable, Sendable {
        case label(String)
        case op(UInt8, [Operand])
        case inner(Int, String)         // a label `k` bytes into the previous opcode
        case bytes([UInt8])
    }
    public var objectCount: Int
    public var functions: [[Target]]    // [object][16]
    public var items: [Item]

    public init(objectCount: Int, functions: [[Target]], items: [Item]) {
        self.objectCount = objectCount
        self.functions = functions
        self.items = items
    }

    /// Assemble to the unpacked pack bytes, then disassemble the result and
    /// require exactly the written opcodes to be reachable (labels on opcodes,
    /// no data bytes reached, every jump in range and every length the
    /// handler's).
    public func assemble() throws -> [UInt8] {
        guard (1...255).contains(objectCount) else { throw CTEventError("object count must be 1-255") }
        guard functions.count == objectCount, functions.allSatisfy({ $0.count == CTEventPack.functionsPerObject }) else {
            throw CTEventError("need \(CTEventPack.functionsPerObject) functions for each of \(objectCount) objects")
        }
        let head = objectCount * 2 * CTEventPack.functionsPerObject
        var labels: [String: Int] = [:], offset = head
        var opOffsets: [Int] = [], innerOffsets: Set<Int> = [], dataOffsets: [Range<Int>] = []
        func define(_ name: String, _ at: Int) throws {
            guard labels.updateValue(at, forKey: name) == nil else { throw CTEventError("label \(name) defined twice") }
        }
        var lastOp: (offset: Int, length: Int)?
        for item in items {
            switch item {
            case .label(let name): try define(name, offset)
            case .op(_, let operands):
                opOffsets.append(offset)
                lastOp = (offset, 1 + operands.count)
                offset += 1 + operands.count
            case .inner(let k, let name):
                guard let host = lastOp, host.offset + host.length == offset, k > 0, k < host.length else {
                    throw CTEventError("@inner +\(k) \(name) is not inside the opcode before it")
                }
                try define(name, host.offset + k)
                innerOffsets.insert(host.offset + k)
            case .bytes(let data):
                dataOffsets.append(offset..<(offset + data.count))
                offset += data.count
                lastOp = nil
            }
        }
        guard offset <= 0xFFFF else { throw CTEventError("scripts exceed 64 KiB") }
        func resolve(_ name: String) throws -> Int {
            guard let at = labels[name] else { throw CTEventError("undefined label \(name)") }
            return at
        }
        var out: [UInt8] = [UInt8(objectCount)]
        for object in functions {
            for target in object {
                let at: Int
                switch target {
                case .label(let name): at = try resolve(name)
                case .offset(let value):
                    guard (0...0xFFFF).contains(value) else { throw CTEventError("function offset out of range") }
                    at = value
                }
                out += [UInt8(at & 255), UInt8(at >> 8)]
            }
        }
        for item in items {
            guard case .op(let op, let operands) = item else {
                if case .bytes(let data) = item { out += data }
                continue
            }
            let at = out.count - 1, def = CTEventISA.opcodes[Int(op)]
            var encoded = [op]
            for (i, operand) in operands.enumerated() {
                switch operand {
                case .byte(let b): encoded.append(b)
                case .label(let name):
                    guard let jump = def.jump, jump.operand == i + 1 else {
                        throw CTEventError(String(format: "%@ ($%04X): operand %d is not a jump", def.name, at, i + 1))
                    }
                    let distance = (try resolve(name) - at - jump.base) * jump.sign
                    guard (0...255).contains(distance) else {
                        throw CTEventError(String(format: "%@ ($%04X): %@ is %d bytes away; one jump reaches 0-255",
                                                  def.name, at, name, distance))
                    }
                    encoded.append(UInt8(distance))
                }
            }
            if case .halt = def.shape { throw CTEventError("\(def.name) is an unused opcode (halts the game)") }
            // Shape operands can lie in the bytes after a short opcode: check in place.
            let probe = (out + encoded + [UInt8](repeating: 0, count: 2))[...]
            guard let (length, _) = def.resolve(probe, at: at + 1), length == encoded.count else {
                let want = def.resolve((out + encoded + [UInt8](repeating: 0, count: 2))[...], at: at + 1)?.length
                throw CTEventError(String(format: "%@ ($%04X) takes %@ bytes, not %d", def.name, at,
                                          want.map(String.init) ?? "an undecodable number of", encoded.count))
            }
            out += encoded
        }
        // The written structure must be what the interpreter reaches.
        let pack = try CTEventPack(bytes: out)
        let written = Set(opOffsets)
        for (y, instruction) in pack.instructions {
            if written.contains(y) || innerOffsets.contains(y) { continue }
            if dataOffsets.contains(where: { $0.contains(y) }) {
                throw CTEventError(String(format: "data bytes at $%04X are reached as an opcode; write them as opcodes", y))
            }
            throw CTEventError(String(format: "$%04X is reached inside an opcode without an @inner label", instruction.offset))
        }
        // Opcodes nothing reaches are kept as written; a later disassembly lists them as @bytes.
        return out
    }
}

/// Text form (`ct-events/1`), one opcode per line:
///
///     @objects 1
///     @func 0 0 L_0020        (function 0 of object 0 starts at L_0020; $XXXX for raw offsets)
///     L_0020:
///         Op65_SetMemBit $02 $03
///         Op16_IfMemByte $03 $04 $06 ->L_0030
///         @inner +2 L_0022    (a label inside the opcode above)
///     @bytes 01 02 03
public enum CTEventListing {
    static let names: [String] = CTEventISA.opcodes.map(\.name)
    static let byName: [String: UInt8] = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($0.element, UInt8($0.offset)) })

    public static func label(_ offset: Int) -> String { String(format: "L_%04X", offset) }

    /// The program of a disassembled pack: reached opcodes as lines, other bytes as data.
    public static func program(_ pack: CTEventPack) -> CTEventProgram {
        let (primary, inner) = pack.layout
        let size = pack.scriptSize, head = pack.headerSize
        var targets = pack.entries
        for o in pack.instructions.values { if let t = o.jumpTarget { targets.insert(t) } }
        for f in pack.functions.joined() where head <= f && f < size { targets.insert(f) }
        let innerByHost = Dictionary(grouping: inner.keys, by: { inner[$0]! })
        var covered = [Bool](repeating: false, count: max(size, 0))
        for y in primary { for i in y..<(y + pack.instructions[y]!.length) { covered[i] = true } }
        var items: [CTEventProgram.Item] = []
        var y = head
        let primarySet = Set(primary)
        while y < size {
            if targets.contains(y) && inner[y] == nil { items.append(.label(label(y))) }
            if primarySet.contains(y), let o = pack.instructions[y] {
                var operands = pack.bytes[(y + 2)..<(y + 1 + o.length)].map { CTEventProgram.Operand.byte($0) }
                if let target = o.jumpTarget, let jump = CTEventISA.opcodes[Int(o.opcode)].jump {
                    operands[jump.operand - 1] = .label(label(target))
                }
                items.append(.op(o.opcode, operands))
                for z in (innerByHost[y] ?? []).sorted() { items.append(.inner(z - y, label(z))) }
                y += o.length
                continue
            }
            var z = y + 1
            while z < size && !covered[z] && !(targets.contains(z) && inner[z] == nil) { z += 1 }
            items.append(.bytes(Array(pack.bytes[(y + 1)..<(z + 1)])))
            y = z
        }
        let functions = pack.functions.map { object in
            object.map { f -> CTEventProgram.Target in
                head <= f && f < size ? .label(label(f)) : .offset(f)
            }
        }
        return CTEventProgram(objectCount: pack.objectCount, functions: functions, items: items)
    }

    public static func render(_ program: CTEventProgram, title: String? = nil) -> String {
        var lines: [String] = []
        if let title { lines.append("; \(title)") }
        lines.append("; ct-events/1 — opcode names from Evt_OpcodeTable; see docs/event_bytecode.md")
        lines.append("@objects \(program.objectCount)")
        for (o, object) in program.functions.enumerated() {
            for (f, target) in object.enumerated() {
                switch target {
                case .label(let name): lines.append("@func \(o) \(f) \(name)")
                case .offset(let value): lines.append(String(format: "@func %d %d $%04X", o, f, value))
                }
            }
        }
        for item in program.items {
            switch item {
            case .label(let name): lines.append("\(name):")
            case .op(let op, let operands):
                let rendered = operands.map { operand -> String in
                    switch operand {
                    case .byte(let b): return String(format: "$%02X", b)
                    case .label(let name): return "->\(name)"
                    }
                }
                lines.append("    " + ([names[Int(op)]] + rendered).joined(separator: " "))
            case .inner(let k, let name): lines.append("    @inner +\(k) \(name)")
            case .bytes(let data):
                for start in stride(from: 0, to: data.count, by: 16) {
                    lines.append("@bytes " + data[start..<min(start + 16, data.count)].map { String(format: "%02X", $0) }.joined(separator: " "))
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func parse(_ text: String) throws -> CTEventProgram {
        var objects: Int?
        var functions: [[CTEventProgram.Target?]] = []
        var items: [CTEventProgram.Item] = []
        func hexByte(_ token: Substring, _ line: Int) throws -> UInt8 {
            let digits = token.hasPrefix("$") ? token.dropFirst() : token
            guard digits.count == 2, let value = UInt8(digits, radix: 16) else {
                throw CTEventError("line \(line): \(token) is not a hex byte")
            }
            return value
        }
        func isLabel(_ s: Substring) -> Bool {
            guard let first = s.first, first.isLetter || first == "_" else { return false }
            return s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
        for (index, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNo = index + 1
            let code = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let words = code.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let head = words.first else { continue }
            switch head {
            case "@objects":
                guard objects == nil, words.count == 2, let n = Int(words[1]), (1...255).contains(n) else {
                    throw CTEventError("line \(lineNo): expected one @objects 1-255")
                }
                objects = n
                functions = Array(repeating: Array(repeating: nil, count: CTEventPack.functionsPerObject), count: n)
            case "@func":
                guard let n = objects else { throw CTEventError("line \(lineNo): @func before @objects") }
                guard words.count == 4, let o = Int(words[1]), let f = Int(words[2]),
                      (0..<n).contains(o), (0..<CTEventPack.functionsPerObject).contains(f) else {
                    throw CTEventError("line \(lineNo): expected @func OBJECT FUNCTION TARGET")
                }
                guard functions[o][f] == nil else { throw CTEventError("line \(lineNo): function \(o) \(f) given twice") }
                if words[3].hasPrefix("$"), words[3].count == 5, let value = Int(words[3].dropFirst(), radix: 16) {
                    functions[o][f] = .offset(value)
                } else if isLabel(words[3]) {
                    functions[o][f] = .label(String(words[3]))
                } else { throw CTEventError("line \(lineNo): bad function target \(words[3])") }
            case "@bytes":
                guard words.count > 1 else { throw CTEventError("line \(lineNo): @bytes needs bytes") }
                let data = try words.dropFirst().map { try hexByte($0, lineNo) }
                if case .bytes(let previous)? = items.last { items[items.count - 1] = .bytes(previous + data) }
                else { items.append(.bytes(data)) }
            case "@inner":
                guard words.count == 3, words[1].hasPrefix("+"), let k = Int(words[1].dropFirst()), isLabel(words[2]) else {
                    throw CTEventError("line \(lineNo): expected @inner +OFFSET LABEL")
                }
                items.append(.inner(k, String(words[2])))
            default:
                if head.hasSuffix(":") {
                    let name = head.dropLast()
                    guard words.count == 1, isLabel(name) else { throw CTEventError("line \(lineNo): bad label") }
                    items.append(.label(String(name)))
                    continue
                }
                guard let op = byName[String(head)] else { throw CTEventError("line \(lineNo): unknown opcode \(head)") }
                let operands = try words.dropFirst().map { token -> CTEventProgram.Operand in
                    if token.hasPrefix("->") {
                        let name = token.dropFirst(2)
                        guard isLabel(name) else { throw CTEventError("line \(lineNo): bad jump label \(token)") }
                        return .label(String(name))
                    }
                    return .byte(try hexByte(token, lineNo))
                }
                items.append(.op(op, operands))
            }
        }
        guard let n = objects else { throw CTEventError("missing @objects") }
        var complete: [[CTEventProgram.Target]] = []
        for (o, object) in functions.enumerated() {
            var row: [CTEventProgram.Target] = []
            for (f, target) in object.enumerated() {
                guard let target else { throw CTEventError("missing @func \(o) \(f)") }
                row.append(target)
            }
            complete.append(row)
        }
        return CTEventProgram(objectCount: n, functions: complete, items: items)
    }
}
