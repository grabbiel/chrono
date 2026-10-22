// Story memory ($7F:0000-$7F:01FF, Menu_FlagBlock7F) as the event packs use it:
// every instruction that sets, clears, tests, reads or writes it, the location
// changes with the flag tests guarding them, and the registry a project keeps
// (story/flags.json). The operand meanings are the handlers' (event_vm_isa.json);
// re_workspace/tools/ct_story.py is the Python twin with the evidence checks.
// See docs/story.md.
import Foundation

public enum CTStory {
    public static let memoryEnd = 0x200
    public static let bitSetPC = 0xFF20                 // BitSet ($00:FF20)
    public static let firstBankC2Location = 0x1F0       // Loc_FirstBankC2
    public static let locationIDMask = 0x1FF            // Loc_IdMask

    public enum Kind: String, Codable, Sendable, CaseIterable { case set, clear, test, read, write }

    /// One story byte (or bit) an instruction touches.
    public struct Access: Codable, Equatable, Sendable {
        public var kind: Kind
        public var addr: Int
        public var bit: Int?            // nil: the byte (or a multi-bit mask)
        public var width: Int
        public var mask: Int? = nil     // $65/$66: the BitSet mask used
        public var cmp: String? = nil   // $16/$18: Evt_CmpTable8 comparison
        public var value: Int? = nil
    }

    /// An instruction of a pack, where it is reached from.
    public struct Site: Codable, Equatable, Hashable, Sendable {
        public var entry: Int           // first Evt_PackPtrs index of the pack
        public var locations: [Int]
        public var offset: Int          // Evt_Data offset
        public var opcode: Int
        public var functions: [[Int]]   // [object, function] pairs reaching it
    }

    public struct Reference: Codable, Equatable, Sendable {
        public var site: Site
        public var access: Access
    }

    /// A memory test that holds (fall-through) or fails (its jump) on every
    /// path from a function's entry to a warp.
    public struct Guard: Codable, Equatable, Hashable, Sendable {
        public var offset: Int
        public var opcode: Int
        public var addr: Int
        public var bit: Int?
        public var cmp: String?
        public var value: Int?
        public var holds: Bool
    }

    public struct Warp: Codable, Equatable, Sendable {
        public var site: Site
        public var kind: String         // warp, warpNow, setLoc, setPrevLoc, warpVars
        public var dest: Int?
        public var x: Int?, y: Int?, facing: Int?
        public var guards: [Guard]
    }

    public struct Scan: Equatable, Sendable {
        public var references: [Reference]
        public var warps: [Warp]
        public var instructions: Int
        public var packs: Int
    }

    static let warpKinds: [UInt8: String] = [0xE0: "warp", 0xE1: "warpNow", 0xDF: "warpNow", 0xDD: "setLoc",
                                             0xDE: "setLoc", 0xDC: "setPrevLoc", 0xE2: "warpVars"]
    static let cmpNames = ["=", "!=", ">", "<", ">=", "<=", "and", "or"]
    static let memoryOpcodes: Set<UInt8> = [0x65, 0x66, 0x16, 0x18, 0x1C, 0x53, 0x54, 0x55, 0x56, 0x58, 0x59, 0x5A,
                                            0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E]
    static let branchTests: Set<UInt8> = [0x16, 0x18]

    /// The story bytes the instruction at `offset` touches (empty when its
    /// operands address other memory). `bitSet`: the 16 bytes at $00:FF20.
    public static func accesses(_ pack: CTEventPack, at offset: Int, bitSet: [UInt8]) -> [Access] {
        guard let ins = pack.instructions[offset] else { return [] }
        let at = offset + 1
        func b(_ k: Int) -> Int { Int(pack.bytes[at + k]) }
        func w(_ k: Int) -> Int { b(k) | b(k + 1) << 8 }
        func long(_ k: Int) -> Int? { b(k + 2) == 0x7F && w(k) < memoryEnd ? w(k) : nil }
        switch ins.opcode {
        case 0x65, 0x66:
            let operand = b(1), number = operand & 0x0F, mask = Int(bitSet[number])
            let bits = (0..<8).filter { mask >> $0 & 1 == 1 }
            return [Access(kind: ins.opcode == 0x65 ? .set : .clear, addr: b(2) + (operand & 0x80 != 0 ? 0x100 : 0),
                           bit: bits.count == 1 ? bits[0] : nil, width: 1, mask: mask)]
        case 0x16:
            let value = b(2), cmp = b(3), c = cmp & 0x7F
            let single = c == 6 && value != 0 && value & (value - 1) == 0
            return [Access(kind: .test, addr: b(1) + (cmp & 0x80 != 0 ? 0x100 : 0),
                           bit: single ? value.trailingZeroBitCount : nil, width: 1,
                           cmp: c < 8 ? cmpNames[c] : String(c), value: value)]
        case 0x18: return [Access(kind: .test, addr: 0, bit: nil, width: 1, cmp: "<", value: b(1))]
        case 0x55: return [Access(kind: .read, addr: 0, bit: nil, width: 1)]
        case 0x5A: return [Access(kind: .write, addr: 0, bit: nil, width: 1)]
        case 0x1C, 0x54: return w(1) < memoryEnd ? [Access(kind: .read, addr: w(1), bit: nil, width: 2)] : []
        case 0x53: return w(1) < memoryEnd ? [Access(kind: .read, addr: w(1), bit: nil, width: 1)] : []
        case 0x56, 0x58: return w(2) < memoryEnd ? [Access(kind: .write, addr: w(2), bit: nil, width: 1)] : []
        case 0x59: return w(2) < memoryEnd ? [Access(kind: .write, addr: w(2), bit: nil, width: 2)] : []
        case 0x48, 0x49:
            return long(1).map { [Access(kind: .read, addr: $0, bit: nil, width: ins.opcode == 0x48 ? 1 : 2)] } ?? []
        case 0x4A, 0x4B, 0x4C, 0x4D:
            let width = ins.opcode == 0x4B || ins.opcode == 0x4D ? 2 : 1
            return long(1).map { [Access(kind: .write, addr: $0, bit: nil, width: width)] } ?? []
        case 0x4E:                      // dst (word), bank ($7E, else $7F), len counting itself and the data
            guard b(3) != 0x7E, w(1) < memoryEnd else { return [] }
            return [Access(kind: .write, addr: w(1), bit: nil, width: max(0, w(4) - 2))]
        default: return []
        }
    }

    // MARK: Functions and guards

    /// Successors of `y` in function `f`: phase 0 runs to the first $00; in
    /// function 0 (Evt_RunObjInit) the object goes on at the next byte, phase 1,
    /// where a $00 stops it. `outcome` marks a memory test's fall-through (true)
    /// or jump (false).
    static func edges(_ pack: CTEventPack, function f: Int, _ y: Int, phase: Int)
        -> [(offset: Int, phase: Int, outcome: Bool?)] {
        guard let ins = pack.instructions[y] else { return [] }
        if ins.opcode == 0 {
            return f == 0 && phase == 0 && y + 1 < pack.scriptSize ? [(y + 1, 1, nil)] : []
        }
        let test = branchTests.contains(ins.opcode)
        var out: [(Int, Int, Bool?)] = []
        if ins.flow.contains(.next) { out.append((y + ins.length, phase, test ? true : nil)) }
        if let t = ins.jumpTarget { out.append((t, phase, test ? false : nil)) }
        return out
    }

    struct Node: Hashable { let offset: Int, phase: Int }

    static func nodes(_ pack: CTEventPack, function f: Int, start: Int) -> Set<Node> {
        var seen = Set<Node>(), todo = [Node(offset: start, phase: 0)]
        while let n = todo.popLast() {
            guard !seen.contains(n), pack.instructions[n.offset] != nil else { continue }
            seen.insert(n)
            todo += edges(pack, function: f, n.offset, phase: n.phase).map { Node(offset: $0.offset, phase: $0.phase) }
        }
        return seen
    }

    /// {offset: [[object, function]]} of the functions reaching each instruction.
    public static func functionReach(_ pack: CTEventPack) -> [Int: [[Int]]] {
        var reach: [Int: Set<[Int]>] = [:]
        for (o, object) in pack.functions.enumerated() {
            for (f, start) in object.enumerated() where pack.instructions[start] != nil {
                for n in nodes(pack, function: f, start: start) { reach[n.offset, default: []].insert([o, f]) }
            }
        }
        return reach.mapValues { $0.sorted { ($0[0], $0[1]) < ($1[0], $1[1]) } }
    }

    struct Condition: Hashable, Comparable {
        let offset: Int, holds: Bool
        static func < (a: Condition, b: Condition) -> Bool { (a.offset, a.holds ? 1 : 0) < (b.offset, b.holds ? 1 : 0) }
    }

    /// {warp offset: guards}: the memory tests whose outcome holds on every path
    /// from a function entry to it (a forward must-analysis, intersected over
    /// the functions reaching it).
    public static func guards(_ pack: CTEventPack) -> [Int: [Guard]] {
        var result: [Int: Set<Condition>] = [:]
        for object in pack.functions {
            for (f, start) in object.enumerated() where pack.instructions[start] != nil {
                let all = nodes(pack, function: f, start: start)
                let entry = Node(offset: start, phase: 0)
                var facts: [Node: Set<Condition>] = [entry: []]     // absent: not reached yet
                var work = [entry]
                while let n = work.popLast() {
                    for e in edges(pack, function: f, n.offset, phase: n.phase) {
                        let next = Node(offset: e.offset, phase: e.phase)
                        guard all.contains(next) else { continue }
                        var out = facts[n]!
                        if let holds = e.outcome { out.insert(Condition(offset: n.offset, holds: holds)) }
                        let new = next == entry ? [] : facts[next].map { $0.intersection(out) } ?? out
                        if new != facts[next] { facts[next] = new; work.append(next) }
                    }
                }
                for (n, fact) in facts where warpKinds[pack.instructions[n.offset]!.opcode] != nil {
                    result[n.offset] = result[n.offset].map { $0.intersection(fact) } ?? fact
                }
            }
        }
        let none = [UInt8](repeating: 0, count: 16)
        return result.mapValues { conditions in
            conditions.sorted().map { c in
                let a = accesses(pack, at: c.offset, bitSet: none)[0]
                return Guard(offset: c.offset, opcode: Int(pack.instructions[c.offset]!.opcode), addr: a.addr,
                             bit: a.bit, cmp: a.cmp, value: a.value, holds: c.holds)
            }
        }
    }

    static func warp(_ pack: CTEventPack, at y: Int, site: Site, guards: [Guard]) -> Warp {
        let op = pack.instructions[y]!.opcode
        func b(_ k: Int) -> Int { Int(pack.bytes[y + 1 + k]) }
        if op == 0xE2 { return Warp(site: site, kind: "warpVars", dest: nil, guards: guards) }
        let word = b(1) | b(2) << 8
        return Warp(site: site, kind: warpKinds[op]!, dest: word & locationIDMask, x: b(3), y: b(4),
                    facing: (word >> 9) & 0x0F, guards: guards)
    }

    // MARK: The ROM

    /// The Evt_PackPtrs entry of each of the 512 locations (LocRom +8).
    public static func locationEvents(rom: [UInt8]) -> [Int] {
        (0..<CTROMLayout.locationCount).map { i in
            let p = CTROMLayout.locationPC + CTROMLayout.locationStride * i + CTROMLayout.locationEventsOffset
            return Int(rom[p]) | Int(rom[p + 1]) << 8
        }
    }

    /// Every story-memory access and location change in the ROM's event packs.
    public static func scan(rom: [UInt8]) throws -> Scan {
        let entries = try CTEventROM.entries(rom: rom)
        let bitSet = Array(rom[bitSetPC..<(bitSetPC + 16)])
        var byEntry: [Int: [Int]] = [:]
        for (loc, entry) in locationEvents(rom: rom).enumerated() { byEntry[entry, default: []].append(loc) }
        var groups: [Int: [Int]] = [:]                  // snes address -> pointer indices
        for e in entries where !CTROMLayout.notEventPackEntries.contains(e.index) {
            groups[e.snesAddress, default: []].append(e.index)
        }
        var scan = Scan(references: [], warps: [], instructions: 0, packs: 0)
        for indices in groups.values.sorted(by: { $0[0] < $1[0] }) {
            let bytes = try CTEventROM.unpack(rom: rom, entry: entries[indices[0]])
            guard !bytes.isEmpty else { continue }
            let pack = try CTEventPack(bytes: bytes)
            let locations = indices.flatMap { byEntry[$0] ?? [] }.sorted()
            scan.packs += 1
            scan.instructions += pack.instructions.count
            let reach = functionReach(pack)
            let hasWarps = pack.instructions.values.contains { warpKinds[$0.opcode] != nil }
            let guardSets = hasWarps ? guards(pack) : [:]
            for y in pack.instructions.keys.sorted() {
                let op = pack.instructions[y]!.opcode
                let site = Site(entry: indices[0], locations: locations, offset: y, opcode: Int(op),
                                functions: reach[y] ?? [])
                if memoryOpcodes.contains(op) {
                    for a in accesses(pack, at: y, bitSet: bitSet) { scan.references.append(Reference(site: site, access: a)) }
                }
                if warpKinds[op] != nil { scan.warps.append(warp(pack, at: y, site: site, guards: guardSets[y] ?? [])) }
            }
        }
        return scan
    }

    /// Absolute-long instructions addressing $7F:0000-$01FF anywhere in the ROM:
    /// a byte pattern that also matches data (pattern-matched until the Python
    /// evidence places it in a matched routine).
    public static func longAddressPatterns(rom: [UInt8]) -> [CodeReference] {
        let names: [UInt8: String] = [0x0F: "ORA", 0x2F: "AND", 0x4F: "EOR", 0x6F: "ADC", 0x8F: "STA", 0xAF: "LDA",
                                      0xCF: "CMP", 0xEF: "SBC"]
        var out: [CodeReference] = []
        for pc in 0..<(rom.count - 3) {
            let op = rom[pc]
            guard let name = names[op & 0xEF], op & 0x0F == 0x0F, rom[pc + 3] == 0x7F, rom[pc + 2] < 2 else { continue }
            let addr = Int(rom[pc + 1]) | Int(rom[pc + 2]) << 8
            let access: String = name == "STA" ? "write" : "read"
            out.append(CodeReference(addr: addr, width: 1, access: access, status: "pattern-matched",
                                     where_: String(format: "$%02X:%04X", 0xC0 | pc >> 16, pc & 0xFFFF),
                                     mnemonic: name + (op & 0x10 != 0 ? " ,X" : ""), routine: nil, source: nil))
        }
        return out
    }
}

/// Code outside the event VM that touches a story byte.
public struct CodeReference: Codable, Equatable, Sendable {
    public var addr: Int
    public var width: Int
    public var access: String           // read, write, rmw, other
    public var status: String           // code-proven, in-routine, pattern-matched
    public var where_: String           // SNES address, or a ChronoRET file:line
    public var mnemonic: String
    public var routine: String?
    public var source: String?          // ChronoRET file:line
    enum CodingKeys: String, CodingKey { case addr, width, access, status, where_ = "where", mnemonic, routine, source }
}
