// Enemies: the stat records BattleFD_UnkB438 loads, the rewards
// BattleFD_AddEnemyRewards adds, the names, the enemy attack and tech
// records and the AI scripts. Layout and evidence: docs/enemies.md; the
// Python twin and every claim's check: re_workspace/tools/ct_enemies.py.
import Foundation

extension CharacterDef {
    /// An enemy's game data (`kind: "enemy"`), imported from the ROM and
    /// written back by `rom build` (docs/enemies.md). An edited `ai` text is
    /// written too (CTEnemyAIPatch); `attack` is shown, not written.
    public struct Enemy: Codable, Equatable, Sendable {
        public var enemyId: Int                // 0-254 (255 is "no enemy" to the battle code)
        public var hp: Int                     // +$00 u16
        public var level: Int                  // +$02
        public var status: [Int]               // +$03-$07: the status bytes (BattlerStats.Unk4C+3..+7)
        public var stats: Stats                // +$08-$0F
        public var affinity: Affinity          // +$10-$13: the divisor bytes per element (4 = normal)
        public var immunity: Int               // +$14 (BattlerStats.Unk46)
        public var flags15: Int                // +$15 (BattlerStats.Unk47)
        public var attackId: Int               // +$16: the EnemyAttacks record of its plain attack
        public var reward: Reward
        public var ai: Script? = nil
        public var attack: Action? = nil

        public struct Stats: Codable, Equatable, Sendable {
            public var stamina: Int, speed: Int, magic: Int, hit: Int, evade: Int, magicDefense: Int
            public var attack: Int, defense: Int
            public static let names = ["stamina", "speed", "magic", "hit", "evade", "magicDefense", "attack", "defense"]
            public static let labels = ["Stamina", "Speed", "Magic", "Hit", "Evade", "Magic Def", "Attack", "Defense"]
            public init(_ v: [Int]) {
                precondition(v.count == 8)
                stamina = v[0]; speed = v[1]; magic = v[2]; hit = v[3]; evade = v[4]; magicDefense = v[5]
                attack = v[6]; defense = v[7]
            }
            public var values: [Int] {
                get { [stamina, speed, magic, hit, evade, magicDefense, attack, defense] }
                set { self = Stats(newValue) }
            }
        }
        /// Element n's byte: bit 7 absorb, bit 6 divisor - 2, bits 5-0 the divisor (BattleSys_HitModUnk6CScale).
        public struct Affinity: Codable, Equatable, Sendable {
            public var lightning: Int, shadow: Int, water: Int, fire: Int
            public static let names = ["lightning", "shadow", "water", "fire"]
            public init(_ v: [Int]) { precondition(v.count == 4); lightning = v[0]; shadow = v[1]; water = v[2]; fire = v[3] }
            public var values: [Int] {
                get { [lightning, shadow, water, fire] }
                set { self = Affinity(newValue) }
            }
        }
        public struct Reward: Codable, Equatable, Sendable {
            public var exp: Int                // u16, added to each PC's exp (BattleSys_AddExp)
            public var gold: Int               // u16
            public var drop: Int               // item id, 0 = none: 90%, or certain when = charm
            public var charm: Int              // item id: the steal's better item
            public var techPoints: Int         // u8
            public init(exp: Int, gold: Int, drop: Int, charm: Int, techPoints: Int) {
                self.exp = exp; self.gold = gold; self.drop = drop; self.charm = charm; self.techPoints = techPoints
            }
        }
        /// The AI script as text (CTEnemyAI.format), or why it does not parse.
        /// `rom build` writes an edited `text` back (CTEnemyAIPatch); `size`,
        /// `shared` and `sha256` record the imported script's length, the
        /// enemies whose scripts overlap it and its bytes' hash, so the
        /// budget can be checked without the ROM (absent in older files).
        public struct Script: Codable, Equatable, Sendable {
            public var address: String
            public var text: String?
            public var error: String?
            public var size: Int? = nil
            public var shared: [Int]? = nil
            public var sha256: String? = nil
            public init(address: String, text: String? = nil, error: String? = nil,
                        size: Int? = nil, shared: [Int]? = nil, sha256: String? = nil) {
                self.address = address; self.text = text; self.error = error
                self.size = size; self.shared = shared; self.sha256 = sha256
            }
        }
        /// An enemy attack or tech record (TechRec's layout, one part) and its effect record.
        public struct Action: Codable, Equatable, Sendable {
            public var id: Int
            public var flags: Int
            public var elementBits: Int        // byte 3 bits 7-4: lightning, shadow, water, fire
            public var part: Int               // effect record number, $FF none
            public var effect: [Int]?          // 12 bytes (CTTechROM's effect fields)
            public var targetMode: Int? = nil  // techs: EnemyTechTarget byte 0
            public var area: Int? = nil
            public init(id: Int, flags: Int, elementBits: Int, part: Int, effect: [Int]?, targetMode: Int? = nil, area: Int? = nil) {
                self.id = id; self.flags = flags; self.elementBits = elementBits; self.part = part; self.effect = effect
                self.targetMode = targetMode; self.area = area
            }
        }

        public init(enemyId: Int, hp: Int, level: Int, status: [Int], stats: Stats, affinity: Affinity, immunity: Int,
                    flags15: Int, attackId: Int, reward: Reward, ai: Script? = nil, attack: Action? = nil) {
            self.enemyId = enemyId; self.hp = hp; self.level = level; self.status = status; self.stats = stats
            self.affinity = affinity; self.immunity = immunity; self.flags15 = flags15; self.attackId = attackId
            self.reward = reward; self.ai = ai; self.attack = attack
        }
    }
}

public enum CTEnemyROM {
    public static let count = 255                      // ids 0-254 imported; 255 is !Battle_EntryNone
    public static let statsPC = 0x0C4700, statsSize = 23
    public static let rewardsPC = 0x0C5E00, rewardSize = 7
    public static let namesPC = 0x0C6500, nameSize = 11, named = 251
    public static let techsPC = 0x0C6FC9, actionSize = 11, techCount = 256
    public static let effectsAPC = 0x0C7AC9, effectSize = 12
    public static let techTargetPC = 0x0C86C9
    public static let attacksPC = 0x0C88C9, attackCount = 23
    public static let effectsBPC = 0x0C89C6
    public static let aiPointersPC = 0x0C8B08, aiBankPC = 0x0C0000
    public static let itemCount = 0xF2                 // item ids 0-$F1
    public static let hpMax = 0x7FFF                   // target handler $08 starts its lowest-HP search here
    public static let blank: UInt8 = 0xEF              // ' ' in names; also the padding
    public static let partNone = 0xFF

    /// Every field the builder writes: (record, offset, size, name).
    public static let statFields: [(offset: Int, size: Int, name: String)] = [
        (0x00, 2, "hp"), (0x02, 1, "level"), (0x03, 5, "status"), (0x08, 1, "stamina"), (0x09, 1, "speed"),
        (0x0A, 1, "magic"), (0x0B, 1, "hit"), (0x0C, 1, "evade"), (0x0D, 1, "magic defense"), (0x0E, 1, "attack"),
        (0x0F, 1, "defense"), (0x10, 4, "affinity"), (0x14, 1, "immunity"), (0x15, 1, "flags15"), (0x16, 1, "attack id"),
    ]
    public static let rewardFields: [(offset: Int, size: Int, name: String)] = [
        (0, 2, "exp"), (2, 2, "gold"), (4, 1, "drop"), (5, 1, "charm"), (6, 1, "tech points"),
    ]

    public static func statsPC(_ id: Int) -> Int { statsPC + statsSize * id }
    public static func rewardPC(_ id: Int) -> Int { rewardsPC + rewardSize * id }
    public static func namePC(_ id: Int) -> Int { namesPC + nameSize * id }
    /// The project file id of enemy `id`.
    public static func fileID(_ id: Int) -> String { String(format: "enemy_%03d", id) }

    static func value(_ b: [UInt8], _ at: Int, _ size: Int) -> Int {
        var v = 0
        for i in 0..<size { v |= Int(b[at + i]) << (8 * i) }
        return v
    }

    // MARK: Codec

    public static func decode(stats raw: [UInt8], reward r: [UInt8], id: Int) -> CharacterDef.Enemy {
        precondition(raw.count == statsSize && r.count == rewardSize)
        let stats = (0..<8).map { Int(raw[8 + $0]) }, affinity = (0..<4).map { Int(raw[0x10 + $0]) }
        return .init(enemyId: id, hp: value(raw, 0, 2), level: Int(raw[2]), status: (3..<8).map { Int(raw[$0]) },
                     stats: .init(stats), affinity: .init(affinity), immunity: Int(raw[0x14]), flags15: Int(raw[0x15]),
                     attackId: Int(raw[0x16]),
                     reward: .init(exp: value(r, 0, 2), gold: value(r, 2, 2), drop: Int(r[4]), charm: Int(r[5]),
                                   techPoints: Int(r[6])))
    }

    static func le(_ v: Int, _ size: Int) -> [UInt8] { (0..<size).map { UInt8(v >> (8 * $0) & 0xFF) } }

    /// Each stat field's bytes, in `statFields` order (values must be in range).
    public static func statBytes(_ e: CharacterDef.Enemy) -> [[UInt8]] {
        var out: [[UInt8]] = [le(e.hp, 2), [UInt8(e.level)], e.status.map { UInt8($0) }]
        for v in e.stats.values { out.append([UInt8(v)]) }
        out.append(e.affinity.values.map { UInt8($0) })
        out += [[UInt8(e.immunity)], [UInt8(e.flags15)], [UInt8(e.attackId)]]
        return out
    }

    public static func rewardBytes(_ r: CharacterDef.Enemy.Reward) -> [[UInt8]] {
        [le(r.exp, 2), le(r.gold, 2), [UInt8(r.drop)], [UInt8(r.charm)], [UInt8(r.techPoints)]]
    }

    public static func encode(stats e: CharacterDef.Enemy) -> [UInt8] { statBytes(e).flatMap { $0 } }
    public static func encode(reward r: CharacterDef.Enemy.Reward) -> [UInt8] { rewardBytes(r).flatMap { $0 } }

    /// 11 glyphs, $EF a blank and the padding; trailing blanks dropped.
    public static func decodeName(_ raw: ArraySlice<UInt8>) -> String {
        var s = raw.map { CTTextCodec.glyphText($0) ?? String(format: "{g%02X}", $0) }.joined()
        while s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    public static func encodeName(_ name: String) throws -> [UInt8] {
        var out: [UInt8] = [], chars = Array(name), i = 0
        while i < chars.count {
            if chars[i] == "{", i + 4 < chars.count, chars[i + 1] == "g", chars[i + 4] == "}",
               let v = UInt8(String(chars[(i + 2)...(i + 3)]), radix: 16) {
                out.append(v); i += 5; continue
            }
            guard let v = CTTextCodec.glyphByte(String(chars[i])) else {
                throw CTROMBuildError("name \(String(reflecting: name)): no glyph for \(String(reflecting: String(chars[i])))")
            }
            out.append(v); i += 1
        }
        guard out.count <= nameSize else { throw CTROMBuildError("name \(String(reflecting: name)) is \(out.count) glyphs; the most is 11") }
        return out + [UInt8](repeating: blank, count: nameSize - out.count)
    }

    public static func name(rom: [UInt8], id: Int) -> String? {
        id < named ? decodeName(rom[namePC(id)..<(namePC(id) + nameSize)]) : nil
    }

    public static func actLengths(rom: [UInt8]) -> [Int] {
        (0..<23).map { Int(rom[CTEnemyAI.actLengthsPC + $0]) }
    }

    public static func script(rom: [UInt8], id: Int, lengths: [Int]) -> CharacterDef.Enemy.Script {
        let at = value(rom, aiPointersPC + 2 * id, 2)
        let address = String(format: "$CC:%04X", at)
        let bank = Array(rom[aiBankPC..<(aiBankPC + 0x10000)])
        do {
            let (parts, end) = try CTEnemyAI.parse(bank, at: at, lengths: lengths)
            return .init(address: address, text: CTEnemyAI.format(parts), size: end - at,
                         sha256: CTEventPack.sha256(Array(bank[at..<end])))
        } catch { return .init(address: address, error: "\(error)") }
    }

    public static func action(rom: [UInt8], base: Int, id: Int, effects: Int, targets: Int?) -> CharacterDef.Enemy.Action {
        let at = base + actionSize * id
        let part = Int(rom[at + 5])
        let effect = part == partNone ? nil : (0..<effectSize).map { Int(rom[effects + effectSize * part + $0]) }
        let elementBits: Int = Int(rom[at + 3]) >> 4
        var targetMode: Int? = nil, area: Int? = nil
        if let targets {
            targetMode = Int(rom[targets + 2 * id])
            area = Int(rom[targets + 2 * id + 1])
        }
        return .init(id: id, flags: Int(rom[at + 1]), elementBits: elementBits, part: part, effect: effect,
                     targetMode: targetMode, area: area)
    }

    public static func decode(rom: [UInt8], id: Int, lengths: [Int]? = nil) -> CharacterDef.Enemy {
        var e = decode(stats: Array(rom[statsPC(id)..<(statsPC(id) + statsSize)]),
                       reward: Array(rom[rewardPC(id)..<(rewardPC(id) + rewardSize)]), id: id)
        e.ai = script(rom: rom, id: id, lengths: lengths ?? actLengths(rom: rom))
        if e.attackId < attackCount {
            e.attack = action(rom: rom, base: attacksPC, id: e.attackId, effects: effectsBPC, targets: nil)
        }
        return e
    }

    /// An enemy tech record (the `tech` byte of AI actions $02, $12, $15).
    public static func tech(rom: [UInt8], id: Int) -> CharacterDef.Enemy.Action {
        action(rom: rom, base: techsPC, id: id, effects: effectsAPC, targets: techTargetPC)
    }

    // MARK: Checks

    /// The ranges the builder keeps: fields fit their bytes, level 0-99, HP
    /// at most $7FFF, items are item ids, the attack record exists, the name
    /// fits (and only ids 0-250 have one).
    public static func check(_ e: CharacterDef.Enemy, name: String?) throws {
        func need(_ ok: Bool, _ what: String) throws { if !ok { throw CTROMBuildError("enemy \(e.enemyId): \(what)") } }
        try need((0..<count).contains(e.enemyId), "the enemy id must be 0-254")
        try need((0...hpMax).contains(e.hp), "HP \(e.hp) is not 0-32767")
        try need((0...99).contains(e.level), "level \(e.level) is not 0-99")
        try need(e.status.count == 5 && e.status.allSatisfy { (0...0xFF).contains($0) }, "status needs 5 bytes 0-255")
        for (label, v) in zip(CharacterDef.Enemy.Stats.labels, e.stats.values) {
            try need((0...0xFF).contains(v), "\(label) \(v) is not 0-255")
        }
        for (label, v) in zip(CharacterDef.Enemy.Affinity.names, e.affinity.values) {
            try need((0...0xFF).contains(v), "\(label) affinity \(v) is not 0-255")
        }
        try need((0...0xFF).contains(e.immunity) && (0...0xFF).contains(e.flags15), "immunity and flags15 must be 0-255")
        try need((0..<attackCount).contains(e.attackId), "attack id \(e.attackId) is not 0-22")
        let r = e.reward
        try need((0...0xFFFF).contains(r.exp) && (0...0xFFFF).contains(r.gold), "exp and gold must be 0-65535")
        try need((0..<itemCount).contains(r.drop) && (0..<itemCount).contains(r.charm),
                 String(format: "drop $%02X and charm $%02X must be item ids below $F2", r.drop & 0xFF, r.charm & 0xFF))
        try need((0...0xFF).contains(r.techPoints), "tech points \(r.techPoints) is not 0-255")
        if let name {
            try need(e.enemyId < named, "only ids 0-250 have a name")
            let read = decodeName(try encodeName(name)[...])
            try need(read == name, "name \(String(reflecting: name)) reads back as \(String(reflecting: read)) " +
                     "(no trailing blanks; {gXX} only for bytes without a glyph)")
        }
    }

    /// The writes of enemy `e` (file `id`) over `base`: every stat and reward
    /// field, and the name when it differs from the base ROM's.
    public static func writes(_ e: CharacterDef.Enemy, id: String, name: String?, base: [UInt8]) throws -> [(pc: Int, bytes: [UInt8], what: String)] {
        var out: [(pc: Int, bytes: [UInt8], what: String)] = []
        for (f, bytes) in zip(statFields, statBytes(e)) {
            out.append((statsPC(e.enemyId) + f.offset, bytes, "enemy \(id) \(f.name)"))
        }
        for (f, bytes) in zip(rewardFields, rewardBytes(e.reward)) {
            out.append((rewardPC(e.enemyId) + f.offset, bytes, "enemy \(id) \(f.name)"))
        }
        if let name, name != CTEnemyROM.name(rom: base, id: e.enemyId) {
            out.append((namePC(e.enemyId), try encodeName(name), "enemy \(id) name"))
        }
        return out
    }

    // MARK: Import

    /// The ROM's enemies 0-254 into `project`: a character whose
    /// `enemy.enemyId` matches (else the file `enemy_NNN`) is updated, others
    /// added with `kind: "enemy"`; all are listed in `rom.enemies`. Returns the ids.
    @discardableResult
    public static func importEnemies(rom input: [UInt8], into project: inout CTProject) throws -> [String] {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("enemies import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        let lengths = actLengths(rom: rom)
        let sharers = CTEnemyAIPatch.sharers(CTEnemyAIPatch.spans(rom: rom, lengths: lengths))
        var byEnemy: [Int: String] = [:]
        for (key, c) in project.characters { if let n = c.enemy?.enemyId { byEnemy[n] = key } }
        var ids: [String] = []
        for n in 0..<count {
            let id = byEnemy[n] ?? fileID(n)
            let romName = name(rom: rom, id: n)
            let shown = (romName?.isEmpty ?? true) ? placeholder(n) : romName!
            var c = project.characters[id] ?? CharacterDef(id: id, name: shown, kind: "enemy")
            c.kind = "enemy"
            c.name = shown
            c.enemy = decode(rom: rom, id: n, lengths: lengths)
            if c.enemy!.ai?.text != nil { c.enemy!.ai!.shared = sharers[n] ?? [] }
            c.level = c.enemy!.level
            project.characters[id] = c
            ids.append(id)
        }
        var spec = project.project.rom ?? .init()
        spec.enemies = ids + spec.enemies.filter { !ids.contains($0) }
        project.project.rom = spec
        return ids
    }

    /// The name to write for an enemy file: its `name`, unless it is the
    /// placeholder the import gives a blank or missing ROM name.
    public static func writableName(_ c: CharacterDef) -> String? {
        guard let e = c.enemy, e.enemyId < named, c.name != placeholder(e.enemyId) else { return nil }
        return c.name
    }

    public static func placeholder(_ id: Int) -> String { String(format: "Enemy %03d", id) }

    // MARK: Display

    /// BattleSys_HitModUnk6CScale's reading of an affinity byte: "x4/4" normal,
    /// "x4/8" half, "absorb ..." with bit 7.
    public static func affinityText(_ byte: Int) -> String {
        let divisor = (byte & 0x3F) - (byte & 0x40 != 0 ? 2 : 0)
        let absorb = byte & 0x80 != 0
        if divisor <= 0 { return absorb ? "absorb x0" : "none (0 damage)" }
        return (absorb ? "absorb " : "") + "x4/\(divisor)"
    }

    /// Item names by item id: the project's items, else the ROM's names (or none).
    public static func itemNames(project: CTProject?, rom: [UInt8]?) -> [Int: String] {
        var out: [Int: String] = [:]
        if let project {
            for item in project.items.values { if let r = item.rom { out[r.itemId] = item.name } }
        }
        if out.isEmpty, let rom, let decoded = try? CTItemROM.decode(rom: rom, codec: nil) {
            for item in decoded.items { if let r = item.rom { out[r.itemId] = item.name } }
        }
        return out
    }
}
