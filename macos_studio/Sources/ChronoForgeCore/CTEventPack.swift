// Chrono Trigger US 1.0 location event packs (Evt_PackPtrs, unpacked to $7F:2000).
// Layout: object count, 16 function offsets per object (relative to Evt_Data,
// $7F:2001), then the scripts. Reachability follows tools/ct_event_packs.py,
// whose opcode shapes come from tracing the ROM's own handlers; see
// docs/event_bytecode.md for evidence and limits.
import Foundation
import CryptoKit

public struct CTEventError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// How the interpreter leaves an opcode: on to the next one, staying on it
/// (a wait), ending the run at an unknown position, or jumping.
public struct CTEventFlow: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let next = CTEventFlow(rawValue: 1)
    public static let stay = CTEventFlow(rawValue: 2)
    public static let end = CTEventFlow(rawValue: 4)
    public static let jump = CTEventFlow(rawValue: 8)
    init(_ code: String) {
        var flow: CTEventFlow = []
        for ch in code {
            switch ch {
            case "n": flow.insert(.next)
            case "s": flow.insert(.stay)
            case "e": flow.insert(.end)
            case "j": flow.insert(.jump)
            default: preconditionFailure("unknown flow code \(ch)")
            }
        }
        self = flow
    }
}

public indirect enum CTEventShape: Sendable, Equatable {
    case fixed(length: Int, flow: CTEventFlow)
    /// length = add + little-endian word at operand byte `operand` (opcode = byte 0).
    case counted(operand: Int, add: Int, flow: CTEventFlow)
    /// The shape depends on operand byte `operand`; one entry per value.
    case byKind(operand: Int, cases: [CTEventShape])
    /// Not decodable: an unused opcode (its handler stops the game) or an
    /// operand value whose handler could not be traced.
    case halt
}

/// Jump target = opcode offset + base + sign × operand byte `operand`.
public struct CTEventJump: Sendable, Equatable {
    public let operand: Int, sign: Int, base: Int
}

public struct CTEventOpcode: Sendable {
    public let name: String
    public let shape: CTEventShape
    public let jump: CTEventJump?
}

extension CTEventOpcode {
    /// (length, flow) of this opcode at `start` in `bytes` (the opcode byte),
    /// or nil when an operand that decides the shape lies past the end.
    func resolve(_ bytes: ArraySlice<UInt8>, at start: Int) -> (length: Int, flow: CTEventFlow)? {
        var shape = self.shape
        while true {
            switch shape {
            case .fixed(let length, let flow): return (length, flow)
            case .halt: return nil
            case .counted(let operand, let add, let flow):
                guard start + operand + 1 < bytes.endIndex else { return nil }
                return (add + (Int(bytes[start + operand]) | Int(bytes[start + operand + 1]) << 8), flow)
            case .byKind(let operand, let cases):
                guard start + operand < bytes.endIndex else { return nil }
                shape = cases[Int(bytes[start + operand])]
            }
        }
    }
}

public struct CTEventInstruction: Equatable, Sendable {
    public let offset: Int          // relative to Evt_Data
    public let opcode: UInt8
    public let length: Int
    public let flow: CTEventFlow
    public let jumpTarget: Int?
    public var successors: [Int] {
        (flow.contains(.next) ? [offset + length] : []) + (jumpTarget.map { [$0] } ?? [])
    }
}

/// An unpacked event pack and its reachable instructions.
public struct CTEventPack: Equatable, Sendable {
    public static let functionsPerObject = 16
    public let bytes: [UInt8]                       // as unpacked to $7F:2000
    public let objectCount: Int
    public let functions: [[Int]]                   // [object][function] offsets
    public let instructions: [Int: CTEventInstruction]
    public let entries: Set<Int>
    public var headerSize: Int { objectCount * 2 * Self.functionsPerObject }
    public var scriptSize: Int { bytes.count - 1 }

    public init(bytes: [UInt8]) throws {
        guard let count = bytes.first else { throw CTEventError("an empty pack") }
        let n = Int(count), head = n * 2 * Self.functionsPerObject, size = bytes.count - 1
        guard 1 + head <= bytes.count else {
            throw CTEventError("\(n) objects need \(head) header bytes; the pack has \(size)")
        }
        let functions = (0..<n).map { o in
            (0..<Self.functionsPerObject).map { f in
                let k = 1 + o * 2 * Self.functionsPerObject + 2 * f
                return Int(bytes[k]) | Int(bytes[k + 1]) << 8
            }
        }
        let script = bytes[1...]   // index i = Evt_Data offset i - 1 + 1
        var ops: [Int: CTEventInstruction] = [:]
        var entries = Set(functions.flatMap { $0 }.filter { head <= $0 && $0 < size })
        var doneInit = Set<Int>()
        while true {
            var work = entries.subtracting(ops.keys).sorted()
            while let y = work.popLast() {
                if ops[y] != nil { continue }
                guard head <= y, y < size else {
                    throw CTEventError(String(format: "an opcode at $%04X, outside the scripts", y))
                }
                let at = y + 1, op = bytes[at], def = CTEventISA.opcodes[Int(op)]
                guard let (length, flow) = def.resolve(script, at: at) else {
                    throw CTEventError(String(format: "$%04X: opcode $%02X (%@) cannot be decoded here", y, op, def.name))
                }
                guard y + length <= size else {
                    throw CTEventError(String(format: "$%04X: opcode $%02X runs %d bytes past the pack", y, op, y + length - size))
                }
                var target: Int?
                if flow.contains(.jump), let jump = def.jump {
                    target = y + jump.base + jump.sign * Int(bytes[at + jump.operand])
                }
                let instruction = CTEventInstruction(offset: y, opcode: op, length: length, flow: flow, jumpTarget: target)
                ops[y] = instruction
                work += instruction.successors.filter { ops[$0] == nil }
            }
            // After each object's function 0, the opcode after the $00 it stops at
            // is where the object goes on (Evt_RunObjInit).
            var more = Set<Int>()
            for object in functions {
                let start = object[0]
                guard !doneInit.contains(start), ops[start] != nil else { continue }
                doneInit.insert(start)
                var seen = Set<Int>(), todo = [start]
                while let y = todo.popLast() {
                    guard !seen.contains(y), let o = ops[y] else { continue }
                    seen.insert(y)
                    if o.opcode == 0 {
                        if y + 1 < size { more.insert(y + 1) }
                        continue
                    }
                    todo += o.successors
                }
            }
            if more.isSubset(of: ops.keys) { break }
            entries.formUnion(more)
        }
        self.bytes = bytes
        self.objectCount = n
        self.functions = functions
        self.instructions = ops
        self.entries = entries
    }

    /// Instructions written in order (each starts where the previous ends) and
    /// those that start inside another's bytes (a jump into operands), by host.
    public var layout: (primary: [Int], inner: [Int: Int]) {
        var primary: [Int] = [], inner: [Int: Int] = [:], end = -1
        for y in instructions.keys.sorted() {
            if y >= end { primary.append(y); end = y + instructions[y]!.length }
            else { inner[y] = primary.last! }
        }
        return (primary, inner)
    }

    /// Script offsets no instruction covers.
    public var unreachedOffsets: [Int] {
        var covered = [Bool](repeating: false, count: scriptSize)
        for i in 0..<headerSize where i < scriptSize { covered[i] = true }
        for y in layout.primary { for i in y..<(y + instructions[y]!.length) { covered[i] = true } }
        return covered.indices.filter { !covered[$0] }
    }
    public var dataByteCount: Int { unreachedOffsets.count }

    /// SHA-256 over the sorted instruction offsets (2-byte little-endian each);
    /// the Python verifier records the same digest per pack.
    public var instructionDigest: String {
        CTEventPack.sha256(instructions.keys.sorted().flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] })
    }

    public static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Evt_PackPtrs ($FC:F9F0): 513 long pointers to LZSS-packed event data.
public enum CTEventROM {
    public static let pointerTablePC = 0x3CF9F0
    public static let pointerCount = 513

    public struct Entry: Equatable, Sendable {
        public let index: Int
        public let snesAddress: Int
        public var pc: Int { ((snesAddress >> 16) & 0x3F) << 16 | (snesAddress & 0xFFFF) }
    }

    public static func entries(rom: [UInt8]) throws -> [Entry] {
        guard rom.count == 4_194_304 else { throw CTEventError("expected a 4 MiB unheadered ROM") }
        return (0..<pointerCount).map { i in
            let p = pointerTablePC + 3 * i
            return Entry(index: i, snesAddress: Int(rom[p]) | Int(rom[p + 1]) << 8 | Int(rom[p + 2]) << 16)
        }
    }

    public static func unpack(rom: [UInt8], entry: Entry) throws -> [UInt8] {
        guard entry.snesAddress >= 0xC00000 else { throw CTEventError("pointer outside ROM banks") }
        let end = min(rom.count, entry.pc + 0x10000)
        if let out = LibCTCodec.shared.lzssDecompress(Array(rom[entry.pc..<end]), cap: 0x10000) { return out }
        return try LZSS.decompress(Array(rom[entry.pc..<end]), maxOutput: 0x10000).out
    }
}
