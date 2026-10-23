// CTTechCombos.swift — dual and triple techs as the battle and field menus
// see them: the field menu's own copies of a combination's members and MP
// (TechByteMembers, TechLineBits, TechMenuTiles, TechLineTiles; the pair
// records' cost columns are user sets 7-21), the rock combinations, the
// capacity of the tech state, and repurposing a record.
// Evidence and the interpreter runs: docs/techs.md, re_workspace/tools/ct_tech_combos.py.
import Foundation

public enum CTTechCombos {
    public static let pairRecords = 15, trioRecords = 10, rockCount = 5
    public static let firstRock = 0x70                       // $70-$74: the rock triples
    public static let rockAccessory = 0xAE                   // rock r is accessory $AE + r (Menu_Unk82E1)
    public static let byteMembersPC = 0x0C2963               // MenuRom_TechByteMembers: bytes 7-21 the pair records
    public static let lineBitsPC = 0x0C2979                  // MenuRom_TechLineBits: the trio records' members
    public static let menuTilesPC = 0x0C28DB                 // MenuRom_TechMenuTiles: 6 B per pair record
    public static let lineTilesPC = 0x0C2935                 // MenuRom_TechLineTiles: 3 B per trio record
    public static let comboNeedsPC = 0x0C2953                // MenuRom_ComboNeeds: 3 B per rock combination
    public static let comboMembersPC = 0x0C2983              // MenuRom_ComboMembers
    public static let menuColumnsSet = 7                     // pair record i's cost columns: user set 7 + i (MenuRom_TechMenuRec)

    /// Why there is no new combination (docs/techs.md, the capacity proof).
    public static let capacity = "the tech state holds 30 combination bytes: 15 pair records of 3 doubles ($39-$65; " +
        "BattleSys_UnkCA1A and Menu_TechFirstIds fix 3 ids to each byte) and 15 triples ($66-$74, one per byte); " +
        "records 0-24 use 25 bytes and bytes 25-29 ($70-$74) are the rock combinations, which Menu_Unk82E1 rewrites " +
        "at every menu exit, so a new combination has no room: repurpose an existing record instead"

    static func bit(_ c: Int) -> Int { 0x80 >> c }
    static func mask(_ chars: [Int]) -> Int { chars.reduce(0) { $0 | bit($1) } }

    /// The record's kind by its place in the state: pairs at bytes 0-14, trios at 15-24.
    public static func isPairRecord(_ index: Int) -> Bool { index < pairRecords }

    // MARK: Decode

    /// The field menu's MpCost index per tech and member (ids ascending), or nil
    /// when the record does not have its place's shape.
    static func decodeMenuCosts(rom: [UInt8], record i: Int, combo: TechSystemDef.Combo, userSets: [[Int]]) -> [[Int]]? {
        let who = combo.members, count = combo.requirements.count
        if i < pairRecords, who.count == 2, count <= 3 {
            let cols = columns(record: i, members: who, userSets: userSets)
            // Loops with typed lets: CI's older type checker (Xcode 26.6) is slow on nested closures with arithmetic.
            var out: [[Int]] = []
            for k in 0..<count {
                var row: [Int] = []
                for c in who {
                    let at: Int = menuTilesPC + 6 * i + 2 * k + cols.firstIndex(of: c)!
                    row.append(Int(rom[at]))
                }
                out.append(row)
            }
            return out
        }
        if i >= pairRecords, i < pairRecords + trioRecords, who.count == 3, count == 1 {
            let base: Int = lineTilesPC + 3 * (i - pairRecords)
            return [(0..<3).map { (k: Int) -> Int in Int(rom[base + k]) }]
        }
        return nil
    }

    /// Pair record i's two cost columns in the field menu: user set 7 + i's
    /// first two ids when they are the members, else the members in order.
    static func columns(record i: Int, members who: [Int], userSets: [[Int]]) -> [Int] {
        let set = userSets.indices.contains(menuColumnsSet + i) ? Array(userSets[menuColumnsSet + i].prefix(2)) : []
        return Set(set) == Set(who) && set.count == 2 ? set : who
    }

    public static func decodeRocks(rom: [UInt8]) -> [TechSystemDef.Rock] {
        var rocks: [TechSystemDef.Rock] = []
        for r in 0..<rockCount {
            let base: Int = comboNeedsPC + 3 * r
            let needs: [Int] = (0..<3).map { (k: Int) -> Int in Int(rom[base + k]) }
            rocks.append(TechSystemDef.Rock(mask: Int(rom[comboMembersPC + r]), needs: needs))
        }
        return rocks
    }

    // MARK: Editing

    public struct EditError: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Gives record `i` new members: its mask, and each of its techs' user sets
    /// (and, for a pair, the menu's column set 7 + i) with old member p
    /// replaced by new member p (ids ascending), so each part stays with the
    /// member in its place. Requirements, parts and MP indexes are kept.
    public static func repurpose(_ s: inout TechSystemDef, record i: Int, members new: [Int]) throws {
        guard s.combos.indices.contains(i) else { throw EditError("no combination record \(i) (\(capacity))") }
        let old = s.combos[i].members
        let to = Array(Set(new)).sorted()
        guard to.count == new.count, to.allSatisfy({ (0..<CTCharacterROM.count).contains($0) }) else {
            throw EditError("members \(new) need distinct character ids 0-6")
        }
        guard to.count == old.count else {
            throw EditError("record \(i) is a \(old.count == 2 ? "pair" : "trio"): it needs \(old.count) members " +
                            "(its techs' ids and state bits are fixed)")
        }
        let m = mask(to)
        if let other = s.combos.indices.first(where: { $0 != i && s.combos[$0].mask == m }) {
            throw EditError("record \(other) already has these members; BattleSys_AwardTechPoints takes the first record of a mask")
        }
        var sets = Set(s.combos[i].requirements.indices.map { s.techs[s.combos[i].first + $0].userSet })
        if isPairRecord(i) { sets.insert(menuColumnsSet + i) }
        for n in sets {
            let users = techs(using: n, in: s).filter { s.combo(of: $0)?.index != i }
            if let t = users.first { throw EditError(String(format: "user set %d is shared with tech $%02X", n, t)) }
        }
        let map = Dictionary(uniqueKeysWithValues: zip(old, to))
        for n in sets.sorted() { s.userSets[n] = s.userSets[n].map { map[$0] ?? $0 } }
        s.combos[i].mask = m
    }

    /// The tech ids whose user set is `n`.
    static func techs(using n: Int, in s: TechSystemDef) -> [Int] {
        s.techs.filter { $0.userSet == n && $0.id != 0 }.map(\.id)
    }

    /// One member of a combination tech: its battle part (TechRec, user k) and
    /// MP, and the field menu's MpCost index and MP.
    public struct Member: Equatable, Sendable {
        public var char: Int
        public var user: Int?
        public var part: Int?
        public var mp: Int?
        public var menuIndex: Int?
        public var menuMP: Int?
    }

    public static func members(of id: Int, in s: TechSystemDef) -> [Member] {
        guard let (i, k) = s.combo(of: id) else { return [] }
        let users = s.techs[id].userSet < s.userSets.count ? s.userSets[s.techs[id].userSet] : []
        let costs = s.combos[i].menuCosts
        // A loop with typed lets: CI's older type checker (Xcode 26.6) is slow on nested optional closures.
        var out: [Member] = []
        for (p, c) in s.combos[i].members.enumerated() {
            let u: Int? = users.firstIndex(of: c)
            var part: Int? = nil
            if let u, s.techs[id].parts.indices.contains(u) { part = s.techs[id].parts[u] }
            var menu: Int? = nil
            if let costs, costs.indices.contains(k), costs[k].indices.contains(p) { menu = costs[k][p] }
            out.append(Member(char: c, user: u, part: part, mp: partMP(s, part), menuIndex: menu, menuMP: partMP(s, menu)))
        }
        return out
    }

    /// A part's MP (bit 7 of the part byte is not the index), or nil past the parts.
    static func partMP(_ s: TechSystemDef, _ n: Int?) -> Int? {
        guard let n else { return nil }
        let k: Int = n & 0x7F
        return s.parts.indices.contains(k) ? s.parts[k].mp : nil
    }

    /// Sets member `c`'s battle part number of tech `id` (bit 7, "runs nothing", kept).
    public static func setPart(_ s: inout TechSystemDef, tech id: Int, member c: Int, part: Int) throws {
        guard (0..<CTTechROM.partCount).contains(part) else { throw EditError("part \(part) is not 0-71") }
        let users = s.userSets[s.techs[id].userSet]
        guard let u = users.firstIndex(of: c), u < 3 else { throw EditError("character \(c) does not perform this tech") }
        s.techs[id].parts[u] = part | (s.techs[id].parts[u] & 0x80)
    }

    /// Sets member `c`'s field-menu MpCost index of tech `id`.
    public static func setMenuCost(_ s: inout TechSystemDef, tech id: Int, member c: Int, index: Int) throws {
        guard (0..<CTTechROM.partCount).contains(index) else { throw EditError("MP index \(index) is not 0-71") }
        guard let (i, k) = s.combo(of: id), let p = s.combos[i].members.firstIndex(of: c),
              var costs = s.combos[i].menuCosts else { throw EditError("no field-menu MP for this member") }
        costs[k][p] = index
        s.combos[i].menuCosts = costs
    }

    // MARK: Checks

    public static func check(_ s: TechSystemDef) throws {
        func need(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw CTROMBuildError("techs: \(what())") } }
        try need(s.combos.count <= pairRecords + trioRecords,
                 "\(s.combos.count) combination records; the most is \(pairRecords + trioRecords): \(capacity)")
        var masks = Set<Int>()
        for (i, c) in s.combos.enumerated() {
            let name = String(format: "combination $%02X", c.first)
            try need((0...0xFE).contains(c.mask) && c.mask & 1 == 0, "\(name): mask \(c.mask) names characters 0-6 only")
            let pair: Bool = isPairRecord(i)
            let shape: String = pair ? "pair" : "trio", holds: String = pair ? "doubles" : "a triple"
            try need(c.members.count == (pair ? 2 : 3), "\(name): record \(i) is a \(shape) (its state byte holds \(holds))")
            try need(masks.insert(c.mask).inserted, "\(name): another record has the same members (only the first is learnt)")
            if let costs = c.menuCosts {
                try need(costs.count == c.requirements.count && costs.allSatisfy { $0.count == c.members.count }
                         && costs.joined().allSatisfy { (0..<CTTechROM.partCount).contains($0) },
                         "\(name): menu MP indexes need one per tech and member, 0-71")
            }
        }
    }

    /// Against the base ROM: the records' places, ids and counts are fixed,
    /// rocks and singles' sets read-only; a record whose members or sets
    /// changed must have each tech's set hold exactly its members, and a
    /// pair's column set 7 + i its two members.
    public static func check(_ s: TechSystemDef, against base: TechSystemDef) throws {
        func need(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw CTROMBuildError("techs: \(what())") } }
        if s.combos.count > base.combos.count {
            throw CTROMBuildError("techs: no room for combination record \(base.combos.count): \(capacity)")
        }
        try need(s.combos.count == base.combos.count, "the \(base.combos.count) combination records cannot be removed")
        for (c, b) in zip(s.combos, base.combos) {
            try need(c.first == b.first && c.requirements.count == b.requirements.count,
                     String(format: "combination $%02X: first tech and count are fixed by the state's bits", b.first))
        }
        if let r = s.rocks, let b = base.rocks { try need(r == b, "the rock combinations are read-only") }
        try need(s.userSets.count == base.userSets.count && s.userSets.allSatisfy { $0.count == 3 },
                 "user sets: need \(base.userSets.count) sets of 3")
        var mayChange = Set<Int>()
        for (i, c) in s.combos.enumerated() {
            for k in c.requirements.indices { mayChange.insert(s.techs[c.first + k].userSet) }
            if isPairRecord(i) { mayChange.insert(menuColumnsSet + i) }
        }
        for t in s.techs where t.kind == "single" { mayChange.remove(t.userSet) }
        for n in s.userSets.indices where s.userSets[n] != base.userSets[n] {
            try need(mayChange.contains(n), "user set \(n) is read-only (it is not a combination's)")
            try need(s.userSets[n].allSatisfy { (0..<CTCharacterROM.count).contains($0) || $0 == 0xFF },
                     "user set \(n): ids are 0-6 or 255")
        }
        for (i, c) in s.combos.enumerated() {
            let sets = c.requirements.indices.map { s.techs[c.first + $0].userSet } + (isPairRecord(i) ? [menuColumnsSet + i] : [])
            let changed = c.mask != base.combos[i].mask || sets.contains { s.userSets[$0] != base.userSets[$0] }
            guard changed else { continue }
            let name = String(format: "combination $%02X", c.first)
            for k in c.requirements.indices {
                let users = s.userSets[s.techs[c.first + k].userSet]
                try need(users.filter { $0 != 0xFF }.sorted() == c.members && users.prefix(c.members.count).allSatisfy { $0 != 0xFF },
                         String(format: "%@: tech $%02X's user set must hold exactly the members %@", name, c.first + k, "\(c.members)"))
            }
            if isPairRecord(i) {
                let cols = s.userSets[menuColumnsSet + i]
                try need(cols.prefix(2).sorted() == c.members && cols[2] == 0xFF,
                         "\(name): user set \(menuColumnsSet + i) (the field menu's cost columns) must hold the two members")
            }
        }
    }

    // MARK: Writes

    /// The members, the field menu's copies and MP indexes, and changed user
    /// sets, over the base ROM `rom`.
    public static func writes(_ s: TechSystemDef, rom: [UInt8]) -> [(pc: Int, bytes: [UInt8], what: String)] {
        var out: [(pc: Int, bytes: [UInt8], what: String)] = []
        for (i, c) in s.combos.enumerated() {
            let name = String(format: "combination $%02X", c.first)
            if c.mask != Int(rom[CTTechROM.combosPC + CTTechROM.comboSize * i]) {
                out.append((CTTechROM.combosPC + CTTechROM.comboSize * i, [UInt8(c.mask)], "\(name) members"))
                if isPairRecord(i) {
                    out.append((byteMembersPC + CTCharacterROM.count + i, [UInt8(c.mask)], "\(name) menu members"))
                } else if i < pairRecords + trioRecords {
                    out.append((lineBitsPC + i - pairRecords, [UInt8(c.mask)], "\(name) menu members"))
                }
            }
            guard let costs = c.menuCosts else { continue }
            let who = c.members
            if isPairRecord(i) {
                let cols = columns(record: i, members: who, userSets: s.userSets)
                var bytes: [UInt8] = []
                for row in costs {
                    for col in cols { bytes.append(UInt8(row[who.firstIndex(of: col)!])) }
                }
                out.append((menuTilesPC + 6 * i, bytes, "\(name) menu MP"))
            } else if i < pairRecords + trioRecords {
                out.append((lineTilesPC + 3 * (i - pairRecords), costs[0].map { UInt8($0) }, "\(name) menu MP"))
            }
        }
        for (n, row) in s.userSets.enumerated() {
            let at = CTTechROM.userSetsPC + 3 * n
            let bytes = row.map { UInt8($0) }
            if Array(rom[at..<(at + 3)]) != bytes { out.append((at, bytes, "user set \(n)")) }
        }
        return out
    }
}
