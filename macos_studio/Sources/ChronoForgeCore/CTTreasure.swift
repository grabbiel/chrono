// CTTreasure.swift — TreasureRom rebuilt as a whole (docs/maps.md, "Chests"):
// the 513 offset words at $F5:F000 and every location's 4-byte records, one
// list after another. A chest's flag is its record's place in the block,
// (offset − word 0) / 4; Field_CheckTileInFront and Map_TreasureTaken are the
// only code that numbers them and no event names one
// (re_workspace/tools/ct_chests.py), so adding or removing a chest just
// renumbers the later ones. The block stays in place while it fits, grows into
// free space right after it, or moves anywhere in bank $F5; with no such room a
// MapProps pack of bank $F5 is moved out (its bytes as they are, Map_PropsPtrs
// repointed) and the records take its span.
import Foundation

public enum CTTreasure {
    public static let wordsPC = CTMapROM.pc(CTMapROM.treasureOfs), wordCount = CTMapROM.locCount + 1
    /// The PC bank the records are read from (TreasureRom = $F5:0000 + offset).
    public static let bank = CTMapROM.pc(CTMapROM.treasureBank) >> 16
    /// Treasure_Flags is 64 bytes (Treasure_FlagByteMask $3F): flags 0-511.
    public static let flagCount = 512
    /// Map_TreasureIdx keeps 7 bits (bit 7 is "no treasure"): at most 128 records in a list.
    public static let listMax = 128

    public struct Record: Equatable, Hashable, Sendable {
        public var tile: Int                   // row << 8 | column; 0 in a first record: a redirect
        public var contents: Int
        public init(tile: Int, contents: Int) { self.tile = tile; self.contents = contents }
        public init(_ t: GameMap.Treasure) { tile = t.y << 8 | t.x; contents = t.contents }
    }

    /// Every location's own records as the offset words split them (a redirect list holds its tile-0 record).
    public static func lists(_ rom: [UInt8]) -> [[Record]] {
        (0..<CTMapROM.locCount).map { i in
            let first = CTMapROM.u16(rom, CTMapROM.treasureOfs + 2 * i), end = CTMapROM.u16(rom, CTMapROM.treasureOfs + 2 * i + 2)
            return stride(from: first, to: max(first, end), by: CTMapROM.treasureBytes).map {
                Record(tile: CTMapROM.u16(rom, CTMapROM.treasureBank + $0), contents: CTMapROM.u16(rom, CTMapROM.treasureBank + $0 + 2))
            }
        }
    }

    /// Word 0: the offset of the first record, which the numbers count from (Map_TreasureRec0).
    public static func start(_ rom: [UInt8]) -> Int { CTMapROM.u16(rom, CTMapROM.treasureOfs) }

    public static func isRedirect(_ list: [Record]) -> Bool { list.first?.tile == 0 }

    /// Each record's flag number: its place in the block.
    public static func numbers(_ lists: [[Record]]) -> [[Int]] {
        var n = 0, out: [[Int]] = []
        for list in lists {
            out.append(Array(n..<(n + list.count)))
            n += list.count
        }
        return out
    }

    /// Every location's list as the project's maps hold it (`edited` in place of its saved map); nil when a
    /// location has no map.
    public static func projectLists(_ project: CTProject, replacing edited: GameMap? = nil) -> (lists: [[Record]], maps: [Int: GameMap])? {
        var byLocation: [Int: GameMap] = [:]
        for m in project.maps.values {
            guard let loc = m.rom?.location else { continue }
            byLocation[loc] = m
        }
        if let edited, let loc = edited.rom?.location {
            if let old = project.maps[edited.id]?.rom?.location, old != loc { byLocation[old] = nil }
            byLocation[loc] = edited
        }
        var lists: [[Record]] = []
        for i in 0..<CTMapROM.locCount {
            guard let m = byLocation[i], let r = m.rom else { return nil }
            lists.append(r.treasureList != i ? [Record(tile: 0, contents: r.treasureList)] : (m.treasure ?? []).map(Record.init))
        }
        return (lists, byLocation)
    }

    /// The flag numbers each project map's chests get when every location is built as the project holds
    /// it (a redirected map shows its target's), keyed by map id; nil when a location has no map.
    public static func projectNumbers(_ project: CTProject, replacing edited: GameMap? = nil) -> [String: [Int]]? {
        guard let (lists, byLocation) = projectLists(project, replacing: edited) else { return nil }
        let numbers = self.numbers(lists)
        var out: [String: [Int]] = [:]
        for (i, m) in byLocation {
            let list = m.rom!.treasureList
            out[m.id] = numbers[(0..<CTMapROM.locCount).contains(list) ? list : i]
        }
        return out
    }

    /// The 513 offset words for `lists` with the records from `start`.
    static func words(_ lists: [[Record]], start: Int) -> [UInt8] {
        var out: [UInt8] = [], at = start
        for list in lists {
            out += [UInt8(at & 0xFF), UInt8(at >> 8)]
            at += CTMapROM.treasureBytes * list.count
        }
        out += [UInt8(at & 0xFF), UInt8(at >> 8)]
        return out
    }

    static func records(_ lists: [[Record]]) -> [UInt8] {
        lists.flatMap { $0 }.flatMap { r in
            [UInt8(r.tile & 0xFF), UInt8(r.tile >> 8), UInt8(r.contents & 0xFF), UInt8(r.contents >> 8)]
        }
    }

    /// The limits a build keeps: 512 flags in all, 128 records in a list.
    public static func check(_ lists: [[Record]]) throws {
        let total = lists.reduce(0) { $0 + $1.count }
        guard total <= flagCount else {
            throw CTROMBuildError("TreasureRom would hold \(total) records; Treasure_Flags has \(flagCount) flags " +
                                  "(\(total - flagCount) too many)")
        }
        if let i = lists.firstIndex(where: { $0.count > listMax }) {
            throw CTROMBuildError("location \(i) would list \(lists[i].count) chests; Map_TreasureIdx numbers at most \(listMax)")
        }
    }

    public struct Evicted: Codable, Equatable, Sendable {
        public let entries: [Int]              // the Map_PropsPtrs entries naming the pack
        public let from: String
        public let to: String
        public let pc: Int
        public let bytes: Int
    }

    public struct ReportBlock: Codable, Equatable, Sendable {
        public let address: String             // the records
        public let pc: Int
        public let records: Int
        public let bytes: Int
        public let placement: String           // original | grown | moved
        public let from: String?               // the old records, when moved
        public let renumbered: Int             // chests whose flag number changed
        public let flagsLeft: Int              // of the 512
        public let evicted: [Evicted]?         // MapProps packs moved out of bank $F5 to make room
    }

    /// Writes `lists` as TreasureRom (nothing when they are the base's). `keep`: the Map_PropsPtrs entries
    /// this build wrote, which are not moved to make room.
    static func apply(lists new: [[Record]], base: [UInt8], keep: Set<Int>, space: inout FreeSpace,
                      write: ([UInt8], Int, String) -> Void,
                      relocated: (String, Int?, Int, Int) -> Void) throws -> ReportBlock? {
        let old = lists(base)
        guard new != old else { return nil }
        try check(new)
        let oldStart = start(base), oldPC = CTMapROM.pc(CTMapROM.treasureBank + oldStart)
        let oldBytes = CTMapROM.treasureBytes * old.reduce(0) { $0 + $1.count }
        let body = records(new)
        var pc = oldPC, placement = "original", evicted: [Evicted] = []
        if body.count > oldBytes {
            if space.allocateSpanning(body.count - oldBytes, at: oldPC + oldBytes) {
                placement = "grown"
            } else if let at = space.allocate(body.count, reclaimed: true, bank: bank)
                        ?? space.allocate(body.count, reclaimed: false, bank: bank) {
                pc = at; placement = "moved"
            } else {
                let made = try evict(body.count, base: base, keep: keep, space: &space, write: write, relocated: relocated)
                pc = made.pc; evicted = [made.evicted]; placement = "moved"
            }
            if placement == "moved" { space.add(oldPC..<(oldPC + oldBytes), reclaimed: true) }
        }
        let first = pc & 0xFFFF
        write(words(new, start: first), wordsPC, "TreasureRom_LocOfs")
        write(body, pc, "TreasureRom")
        if placement == "moved" { relocated("TreasureRom", oldPC, pc, body.count) }
        let before = numbers(old), after = numbers(new)
        var renumbered = 0
        for i in 0..<CTMapROM.locCount where !isRedirect(old[i]) && !isRedirect(new[i]) {
            renumbered += zip(before[i], after[i]).filter { $0 != $1 }.count
        }
        return ReportBlock(address: CTROMBuilder.snes(pc), pc: pc, records: body.count / CTMapROM.treasureBytes,
                           bytes: body.count, placement: placement, from: placement == "moved" ? CTROMBuilder.snes(oldPC) : nil,
                           renumbered: renumbered, flagsLeft: flagCount - body.count / CTMapROM.treasureBytes,
                           evicted: evicted.isEmpty ? nil : evicted)
    }

    /// Moves the smallest MapProps pack of bank $F5 that holds `size` bytes (and that no entry this build
    /// wrote names) out to free space, repoints its entries, and gives its span to the records.
    static func evict(_ size: Int, base: [UInt8], keep: Set<Int>, space: inout FreeSpace,
                      write: ([UInt8], Int, String) -> Void,
                      relocated: (String, Int?, Int, Int) -> Void) throws -> (pc: Int, evicted: Evicted) {
        var users: [Int: [Int]] = [:]
        for e in 0..<CTMapROM.propsCount {
            let p = CTMapROM.propsPointer(base, e)
            if p != 0 { users[p, default: []].append(e) }
        }
        var best: (pointer: Int, packed: Int)?
        for (p, es) in users where CTMapROM.pc(p) >> 16 == bank && keep.isDisjoint(with: es) {
            guard let packed = try? CTTilesetROM.unpack(base, p).length, packed >= size else { continue }
            if best == nil || packed < best!.packed || (packed == best!.packed && p < best!.pointer) { best = (p, packed) }
        }
        guard let best else {
            throw CTROMBuildError("TreasureRom grows to \(size) bytes and bank $F5 has no room: no free span and no " +
                                  "MapProps pack there of that size to move out")
        }
        let from = CTMapROM.pc(best.pointer), entries = users[best.pointer]!.sorted()
        let bytes = Array(base[from..<(from + best.packed)])
        let what = "MapProps entry \(entries.map(String.init).joined(separator: ", ")) (moved for TreasureRom)"
        let (to, _) = try CTROMBuilder.placeBlock(bytes, home: nil, space: &space, what: what)
        write(bytes, to, what)
        for e in entries {
            write([UInt8(to & 0xFF), UInt8(to >> 8 & 0xFF), UInt8(0xC0 | to >> 16)], CTMapROM.pc(CTMapROM.propsPtrs) + 3 * e,
                  "Map_PropsPtrs[\(e)]")
        }
        relocated(what, from, to, bytes.count)
        if best.packed > size { space.add((from + size)..<(from + best.packed), reclaimed: true) }
        return (from, Evicted(entries: entries, from: CTROMBuilder.snes(from), to: CTROMBuilder.snes(to), pc: to, bytes: bytes.count))
    }
}

// MARK: Editing a map's chests

extension CTTreasure {
    public enum Contents: Equatable, Sendable {
        case item(Int), gold(Int), empty

        /// The record's contents word (GameMap.Treasure.contents).
        public var word: Int {
            switch self {
            case .item(let i): return i & 0x1FF
            case .gold(let g): return 0x8000 | (g / 2) & 0x7FFF
            case .empty: return 0x4000
            }
        }

        public init(word c: Int) {
            switch CTMapROM.TreasureKind(contents: c) {
            case .gold(let g): self = .gold(g)
            case .empty: self = .empty
            case .item(let i): self = .item(i)
            }
        }

        public var problem: String? {
            switch self {
            case .item(let i):
                return (1..<CTEnemyROM.itemCount).contains(i) ? nil : String(format: "item $%X is not one of the items $01-$%02X", i, CTEnemyROM.itemCount - 1)
            case .gold(let g):
                return (2...0xFFFE).contains(g) && g % 2 == 0 ? nil : "gold \(g) is not an even amount 2-65534 (the record keeps half of it)"
            case .empty: return nil
            }
        }
    }

    /// Why a chest cannot stand at (x, y) of `map` (`except`: the chest being moved).
    public static func problems(_ map: GameMap, x: Int, y: Int, except: Int? = nil) -> [String] {
        var out: [String] = []
        if let r = map.rom, r.treasureList != r.location {
            out.append("\(map.id) shows location \(r.treasureList)'s chests; edit that map")
        }
        if !(0..<map.width).contains(x) || !(0..<map.height).contains(y) || x > 0xFF || y > 0xFF {
            out.append("(\(x),\(y)) is off the \(map.width)x\(map.height) map")
        }
        if x == 0 && y == 0 { out.append("tile 0,0 is where a record means \"use another location's list\"") }
        for (k, t) in (map.treasure ?? []).enumerated() where k != except && t.x == x && t.y == y {
            out.append("chest \(k) already stands at (\(x),\(y))")
        }
        return out
    }

    /// Adds a chest (at `index`, or after the others); its flag and every later chest's follow from its place.
    public static func add(_ map: inout GameMap, x: Int, y: Int, contents: Contents, at index: Int? = nil) throws {
        var problems = problems(map, x: x, y: y)
        if let p = contents.problem { problems.append(p) }
        var list = map.treasure ?? []
        if list.count >= listMax { problems.append("\(map.id) already has \(listMax) chests (Map_TreasureIdx keeps 7 bits)") }
        if let index, !(0...list.count).contains(index) { problems.append("index \(index) is not 0-\(list.count)") }
        if let p = problems.first { throw CTROMBuildError("\(map.id): \(p)") }
        list.insert(GameMap.Treasure(x: x, y: y, contents: contents.word), at: index ?? list.count)
        map.treasure = list
    }

    public static func remove(_ map: inout GameMap, _ k: Int) throws {
        guard var list = map.treasure, list.indices.contains(k) else { throw CTROMBuildError("\(map.id) has no chest \(k)") }
        if let r = map.rom, r.treasureList != r.location {
            throw CTROMBuildError("\(map.id) shows location \(r.treasureList)'s chests; edit that map")
        }
        list.remove(at: k)
        map.treasure = list
    }

    /// Moves chest k to (x, y) and, when given, changes what it holds; its flag stays.
    public static func move(_ map: inout GameMap, _ k: Int, x: Int, y: Int, contents: Contents? = nil) throws {
        guard var list = map.treasure, list.indices.contains(k) else { throw CTROMBuildError("\(map.id) has no chest \(k)") }
        var problems = problems(map, x: x, y: y, except: k)
        if let p = contents?.problem { problems.append(p) }
        if let p = problems.first { throw CTROMBuildError("\(map.id): \(p)") }
        list[k] = GameMap.Treasure(x: x, y: y, contents: contents?.word ?? list[k].contents)
        map.treasure = list
    }

    /// The records a build of the whole project would write, when every location has a map.
    public static func projectTotal(_ project: CTProject, replacing edited: GameMap? = nil) -> Int? {
        projectLists(project, replacing: edited)?.lists.reduce(0) { $0 + $1.count }
    }
}
