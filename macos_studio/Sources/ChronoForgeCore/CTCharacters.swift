// The seven playable characters' records, growth rows and level-up rule.
// Layout, rule and evidence: docs/characters.md; the Python twin and every
// claim's check: re_workspace/tools/ct_characters.py.
import Foundation

public enum CTCharacterROM {
    public static let recordsPC = 0x0C0000             // $CC:0000, 8 x $50 copied to $7E:2600 for a new game
    public static let recordSize = 0x50
    public static let count = 7                        // ids 0-6
    public static let hpGrowthPC = 0x0C258A            // 8 B per id: 4 (top level, gain) pairs
    public static let mpGrowthPC = 0x0C25C2
    public static let statGrowthPC = 0x0C25FA          // 7 B per id, growth order
    public static let expToLevelPC = 0x0C2632          // 100 words
    public static let growthRow = 8, statGrowthRow = 7
    static let itemTablesAPC = 0x3FCF0E                // MenuRom_ItemTablesA: bank-$CC address per category
    static let itemSizesAPC = 0x3FCF18                 // MenuRom_ItemRecSizesA
    static let itemBoundsPC = 0x0288A7                 // Menu_ItemCategoryBounds
    static let itemNamesPC = 0x0C0B5E                  // 11 B per item: icon, 10 glyphs
    static let equipMaskByte = 3                       // record A byte 3

    /// CT's standard id order (docs/characters.md).
    public static let names = ["crono", "marle", "lucca", "robo", "frog", "ayla", "magus"]
    /// Byte k of a StatGrowth row and of the growth base belongs to stat growthOrder[k].
    public static let growthOrder = [0, 1, 2, 4, 5, 3, 6]
    public static let speed = 2                        // not recomputed by a level-up
    /// Item categories 0-3, the slot each fills, and its record offset.
    public static let slots = ["weapon", "armor", "helmet", "accessory"]
    public static let slotOffset = ["helmet": 0x27, "armor": 0x28, "weapon": 0x29, "accessory": 0x2A]

    /// Every field the builder writes: (offset, size, name). Other bytes of a
    /// record (+$01-$02, +$19-$26, +$36-$4F) are never written by a character
    /// build; a tech build sets bit 4 of +$02 (all singles learned, CTTechROM).
    public static let writableFields: [(offset: Int, size: Int, name: String)] = [
        (0x03, 2, "hp"), (0x05, 2, "max HP"), (0x07, 2, "mp"), (0x09, 2, "max MP"),
        (0x0B, 1, "power"), (0x0C, 1, "stamina"), (0x0D, 1, "speed"), (0x0E, 1, "magic"), (0x0F, 1, "hit"),
        (0x10, 1, "evade"), (0x11, 1, "magic defense"), (0x12, 1, "level"), (0x13, 3, "exp"),
        (0x16, 3, "tech points"), (0x27, 1, "helmet"), (0x28, 1, "armor"), (0x29, 1, "weapon"),
        (0x2A, 1, "accessory"), (0x2B, 2, "exp to next"), (0x2D, 2, "tech points to next"),
        (0x2F, 7, "growth base"),
    ]

    public static func recordPC(_ id: Int) -> Int { recordsPC + recordSize * id }

    // MARK: Codec

    static func value(_ bytes: [UInt8], _ at: Int, _ size: Int) -> Int {
        (0..<size).reduce(0) { $0 | Int(bytes[at + $1]) << (8 * $1) }
    }

    /// The decoded fields of one $50-byte record.
    public static func decode(record raw: [UInt8]) -> CharacterDef.Record {
        precondition(raw.count == recordSize)
        var base = [Int](repeating: 0, count: 7)
        for k in 0..<7 { base[growthOrder[k]] = Int(raw[0x2F + k]) }
        return .init(charId: Int(raw[0]), level: Int(raw[0x12]), exp: value(raw, 0x13, 3), expToNext: value(raw, 0x2B, 2),
                     hp: value(raw, 0x03, 2), maxHp: value(raw, 0x05, 2), mp: value(raw, 0x07, 2),
                     maxMp: value(raw, 0x09, 2), stats: .init((0..<7).map { Int(raw[0x0B + $0]) }),
                     growthBase: .init(base),
                     equipment: .init(helmet: Int(raw[0x27]), armor: Int(raw[0x28]), weapon: Int(raw[0x29]),
                                      accessory: Int(raw[0x2A])),
                     techPoints: value(raw, 0x16, 3), techPointsToNext: value(raw, 0x2D, 2))
    }

    /// Each writable field's bytes, in `writableFields` order (values must be in range).
    public static func fieldBytes(_ r: CharacterDef.Record) -> [[UInt8]] {
        func le(_ v: Int, _ size: Int) -> [UInt8] { (0..<size).map { UInt8(v >> (8 * $0) & 0xFF) } }
        var base = [UInt8](repeating: 0, count: 7)
        for k in 0..<7 { base[k] = UInt8(r.growthBase[growthOrder[k]]) }
        let e = r.equipment
        return [le(r.hp, 2), le(r.maxHp, 2), le(r.mp, 2), le(r.maxMp, 2)] + r.stats.values.map { [UInt8($0)] } +
            [[UInt8(r.level)], le(r.exp, 3), le(r.techPoints, 3), [UInt8(e.helmet)], [UInt8(e.armor)], [UInt8(e.weapon)],
             [UInt8(e.accessory)], le(r.expToNext, 2), le(r.techPointsToNext, 2), base]
    }

    /// `base` with the writable fields of `r` put in.
    public static func encode(_ r: CharacterDef.Record, over base: [UInt8]) -> [UInt8] {
        precondition(base.count == recordSize)
        var raw = base
        for (field, bytes) in zip(writableFields, fieldBytes(r)) {
            raw.replaceSubrange(field.offset..<(field.offset + field.size), with: bytes)
        }
        return raw
    }

    public static func decodeGrowth(rom: [UInt8], id: Int) -> CharacterDef.Growth {
        func row(_ pc: Int) -> [CharacterDef.Growth.Step] {
            (0..<4).map { .init(toLevel: Int(rom[pc + growthRow * id + 2 * $0]), gain: Int(rom[pc + growthRow * id + 2 * $0 + 1])) }
        }
        var stats = [Int](repeating: 0, count: 7)
        for k in 0..<7 { stats[growthOrder[k]] = Int(rom[statGrowthPC + statGrowthRow * id + k]) }
        return .init(hp: row(hpGrowthPC), mp: row(mpGrowthPC), stats: .init(stats))
    }

    /// The HP row, MP row and StatGrowth row bytes.
    public static func encodeGrowth(_ g: CharacterDef.Growth) -> (hp: [UInt8], mp: [UInt8], stats: [UInt8]) {
        func row(_ steps: [CharacterDef.Growth.Step]) -> [UInt8] { steps.flatMap { [UInt8($0.toLevel), UInt8($0.gain)] } }
        return (row(g.hp), row(g.mp), (0..<7).map { UInt8(g.stats[growthOrder[$0]]) })
    }

    public static func expToLevel(rom: [UInt8]) -> [Int] {
        (0...CTLevelCurve.levelMax).map { value(rom, expToLevelPC + 2 * $0, 2) }
    }

    // MARK: Equipment

    /// The item category (0-3: weapon, armor, helmet, accessory; 4+: not equipment).
    public static func category(of item: Int, rom: [UInt8]) -> Int {
        var c = 0
        while c < 4 && item >= Int(rom[itemBoundsPC + c + 1]) { c += 1 }
        return c
    }

    /// Menu_ItemEquipChars[item]: bit $80 >> id for each character who can equip it.
    public static func equipMask(of item: Int, rom: [UInt8]) -> Int {
        let c = category(of: item, rom: rom)
        guard c < 4 else { return 0 }
        let table = value(rom, itemTablesAPC + 2 * c, 2), size = Int(rom[itemSizesAPC + c])
        return Int(rom[0x0C0000 + table + (item - Int(rom[itemBoundsPC + c])) * size + equipMaskByte])
    }

    /// Every equipment item of the ROM with its name, slot and mask.
    public static func equipmentCatalog(rom: [UInt8], codec: CTTextCodec) throws -> [PartyDef.EquipItem] {
        let end = Int(rom[itemBoundsPC + 4])
        return try (0..<end).map { item in
            // Glyphs one at a time: the dialogue codec would show a run the
            // dictionary could pack as a literal «run»; $FF is a blank.
            let at = itemNamesPC + 11 * item
            let name = try rom[(at + 1)..<(at + 11)].map { $0 == 0xFF || $0 == 0xEF ? " " : try codec.decode([$0]) }
                .joined().trimmingCharacters(in: .whitespaces)
            return .init(id: item, name: name, slot: slots[category(of: item, rom: rom)], equipMask: equipMask(of: item, rom: rom))
        }
    }

    // MARK: Checks

    /// The ranges the game's code keeps (docs/characters.md); equipment must be
    /// in its slot's category and equippable by the character in `rom`.
    public static func check(_ r: CharacterDef.Record, growth: CharacterDef.Growth?, rom: [UInt8]) throws {
        try check(r, growth: growth, category: { category(of: $0, rom: rom) }, mask: { equipMask(of: $0, rom: rom) })
    }

    /// The same checks with the equipment of party.json (the Studio, without a ROM).
    public static func check(_ r: CharacterDef.Record, growth: CharacterDef.Growth?, party: PartyDef) throws {
        let items = Dictionary(party.equipment.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        try check(r, growth: growth, category: { items[$0].flatMap { slots.firstIndex(of: $0.slot) } ?? 4 },
                  mask: { items[$0]?.equipMask ?? 0 })
    }

    static func check(_ r: CharacterDef.Record, growth: CharacterDef.Growth?, category: (Int) -> Int,
                      mask: (Int) -> Int) throws {
        func need(_ ok: Bool, _ what: String) throws { if !ok { throw CTROMBuildError("character \(r.charId): \(what)") } }
        try need((0..<count).contains(r.charId), "the character id must be 0-6")
        try need((1...CTLevelCurve.levelMax).contains(r.level), "level \(r.level) is not 1-99")
        try need((0...CTLevelCurve.expCap).contains(r.exp), "exp \(r.exp) is not 0-9,999,999")
        try need((0...0xFFFF).contains(r.expToNext), "exp to next \(r.expToNext) is not 0-65,535")
        try need((0...CTLevelCurve.maxHpCap).contains(r.maxHp) && (0...r.maxHp).contains(r.hp),
                 "HP \(r.hp)/\(r.maxHp): need 0 <= HP <= max HP <= 999")
        try need((0...CTLevelCurve.maxMpCap).contains(r.maxMp) && (0...r.maxMp).contains(r.mp),
                 "MP \(r.mp)/\(r.maxMp): need 0 <= MP <= max MP <= 99")
        for (i, name) in CharacterDef.StatBlock.names.enumerated() {
            try need((0...CTLevelCurve.statCap).contains(r.stats[i]), "\(name) \(r.stats[i]) is not 0-99")
            try need((0...CTLevelCurve.statCap).contains(r.growthBase[i]), "growth base \(name) \(r.growthBase[i]) is not 0-99")
        }
        try need((0...0xFFFFFF).contains(r.techPoints), "tech points \(r.techPoints) do not fit 24 bits")
        try need((0...0xFFFF).contains(r.techPointsToNext), "tech points to next \(r.techPointsToNext) do not fit 16 bits")
        let e = r.equipment
        for (slot, item) in [("weapon", e.weapon), ("armor", e.armor), ("helmet", e.helmet), ("accessory", e.accessory)] {
            try need((0...0xFF).contains(item) && category(item) == slots.firstIndex(of: slot)!,
                     String(format: "%@ $%02X is not a %@", slot, item & 0xFF, slot))
            try need(mask(item) & (0x80 >> r.charId) != 0,
                     String(format: "%@ $%02X is not equippable by %@", slot, item, names[r.charId]))
        }
        guard let growth else { return }
        for (name, row) in [("HP", growth.hp), ("MP", growth.mp)] {
            try need(row.count == 4, "the \(name) row needs 4 steps")
            try need(row.allSatisfy { (0...0xFF).contains($0.toLevel) && (0...0xFF).contains($0.gain) },
                     "the \(name) row's levels and gains must be 0-255")
            try need(row.contains { $0.toLevel >= CTLevelCurve.levelMax },
                     "the \(name) row must reach level 99 (the game reads past the row otherwise)")
        }
        try need(growth.stats.values.allSatisfy { (0...0xFF).contains($0) }, "stat growth must be 0-255")
    }

    // MARK: Import

    /// The ROM's seven records and growth rows into `project`: a character
    /// whose `pc.charId` (else whose id) matches is updated, others are
    /// added; party.json gets the experience table and the equipment; every
    /// character is listed in `rom.characters`. Returns the ids.
    @discardableResult
    public static func importCharacters(rom input: [UInt8], into project: inout CTProject) throws -> [String] {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("characters import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        let codec = try CTTextCodec(profile: project.textProfile ?? CTTextProfile.fromROM(Data(rom)))
        var ids: [String] = []
        for charId in 0..<count {
            let record = decode(record: Array(rom[recordPC(charId)..<(recordPC(charId) + recordSize)]))
            let growth = decodeGrowth(rom: rom, id: charId)
            let id = project.characters.first { $0.value.pc?.charId == charId }?.key ?? names[charId]
            var c = project.characters[id] ?? CharacterDef(id: id, name: names[charId].capitalized, kind: "playable")
            c.pc = record
            c.growth = growth
            c.level = record.level
            project.characters[id] = c
            ids.append(id)
        }
        project.party = PartyDef(expToLevel: expToLevel(rom: rom), equipment: try equipmentCatalog(rom: rom, codec: codec))
        var spec = project.project.rom ?? .init()
        spec.characters = ids + spec.characters.filter { !ids.contains($0) }
        project.project.rom = spec
        return ids
    }
}

/// The game's level-up (BattleSys_AddExp, ApplyExpStep, GrowHpMp,
/// LevelUpStep), the twin of ct_characters.level_up; tested against its vectors.
public enum CTLevelCurve {
    public static let levelMax = 99
    public static let statCap = 99, speedCapAtLevelUp = 50
    public static let maxHpCap = 999, maxMpCap = 99
    public static let expCap = 0x98967F               // 9,999,999
    /// A curve row: these columns, the stats in record order.
    public static let columns = ["level", "exp", "expToNext", "maxHp", "maxMp", "power", "stamina", "speed",
                                 "magic", "hit", "evade", "magic_defense"]

    public struct RuleError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// BattleSys_AddExp: a 24-bit add, then the cap as coded (only the low
    /// word is compared after a carry into the cap's bank).
    public static func addExp(_ total: Int, _ amount: Int) -> Int {
        var low = (total & 0xFFFF) + amount, high = total >> 16
        if low > 0xFFFF { low &= 0xFFFF; high = (high + 1) & 0xFF }
        if high >= 0x98 {
            high = 0x98
            if low >= 0x9680 { low = 0x967F }
        }
        return high << 16 | low
    }

    /// The gain of the first step whose top level reaches `level`.
    public static func gain(_ row: [CharacterDef.Growth.Step], level: Int) throws -> Int {
        guard let step = row.first(where: { $0.toLevel >= level }) else {
            throw RuleError(description: "no step of the row reaches level \(level)")
        }
        return step.gain
    }

    /// One level granted by exp_to_next experience. Below level 99 only.
    public static func levelUp(_ r: CharacterDef.Record, growth: CharacterDef.Growth, expToLevel: [Int]) throws -> CharacterDef.Record {
        guard (1..<levelMax).contains(r.level) else { throw RuleError(description: "level \(r.level) cannot level up") }
        var v = r
        v.exp = addExp(r.exp, r.expToNext)
        v.level = r.level + 1
        v.expToNext = v.level >= levelMax ? 0 : expToLevel[v.level]
        v.maxHp = try min((r.maxHp + gain(growth.hp, level: v.level)) & 0xFFFF, maxHpCap)
        v.maxMp = try min((r.maxMp + gain(growth.mp, level: v.level)) & 0xFFFF, maxMpCap)
        var stats = r.stats.values
        for k in 0..<7 where CTCharacterROM.growthOrder[k] != CTCharacterROM.speed {
            let s = CTCharacterROM.growthOrder[k]
            let quotient = growth.stats[s] * ((v.level - 1) & 0xFF) / 100
            stats[s] = (r.growthBase[s] + (quotient & 0xFF)) & 0xFF
        }
        stats = stats.map { min($0, statCap) }
        stats[CTCharacterROM.speed] = min(stats[CTCharacterROM.speed], speedCapAtLevelUp)
        v.stats = .init(stats)
        return v
    }

    /// The record at its own level and after each level-up to 99.
    public static func curve(_ r: CharacterDef.Record, growth: CharacterDef.Growth, expToLevel: [Int]) throws -> [CharacterDef.Record] {
        var out = [r]
        while out[out.count - 1].level < levelMax {
            out.append(try levelUp(out[out.count - 1], growth: growth, expToLevel: expToLevel))
        }
        return out
    }

    public static func row(_ r: CharacterDef.Record) -> [Int] {
        [r.level, r.exp, r.expToNext, r.maxHp, r.maxMp] + r.stats.values
    }

    /// Stats whose value differs from growth base + growth x (level - 1) / 100
    /// (speed aside): the first level-up recomputes them. Index -> (now, curve).
    public static func offCurve(_ r: CharacterDef.Record, growth: CharacterDef.Growth) -> [Int: (Int, Int)] {
        var out: [Int: (Int, Int)] = [:]
        for s in 0..<7 where s != CTCharacterROM.speed {
            let expect = min((r.growthBase[s] + growth.stats[s] * ((r.level - 1) & 0xFF) / 100) & 0xFF, statCap)
            if expect != r.stats[s] { out[s] = (r.stats[s], expect) }
        }
        return out
    }

    /// Experience at the start of `level` (the sum of the table's entries
    /// 1 to level - 1) and the amount the next level needs.
    public static func expAt(level: Int, expToLevel: [Int]) -> (exp: Int, toNext: Int) {
        let exp = expToLevel[1..<max(1, level)].reduce(0, +)
        return (min(exp, expCap), level >= levelMax ? 0 : expToLevel[level])
    }
}
