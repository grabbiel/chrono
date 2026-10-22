// The item tables: weapons, armour, helmets, accessories and consumables,
// their names and descriptions, ItemBoosts, and the menu's equipment stats.
// Layout, rule and evidence: docs/items.md; the Python twin and every claim's
// check: re_workspace/tools/ct_items.py.
import Foundation

// MARK: - item_tables.json

/// The tables items share. Boosts are written back; the rest is read-only
/// (decoded for the Studio's stat totals).
public struct ItemTablesDef: Codable, Equatable, Sendable {
    public var schema: String = "ct-item-tables/1"
    public var boosts: [Boost]                 // ItemBoosts: 23 words, 0 = no boost
    public var statOrder: [String]             // read-only: MenuRom_StatOrder (boost bit 7 down)
    public var statCaps: [Int]                 // read-only: MenuRom_StatCaps, by stat order
    public var char5Attack: [Int]              // read-only: MenuRom_Char5Attack (attack formula C)
    public struct Boost: Codable, Equatable, Sendable {
        public var stats: [String]             // the stats it raises (CharacterDef.StatBlock names)
        public var amount: Int                 // 0-255
        public init(stats: [String], amount: Int) { self.stats = stats; self.amount = amount }
    }
    public init(boosts: [Boost], statOrder: [String], statCaps: [Int], char5Attack: [Int]) {
        self.boosts = boosts; self.statOrder = statOrder; self.statCaps = statCaps; self.char5Attack = char5Attack
    }

    /// ItemBoosts word `n`: bit 7 - i for each stat statOrder[i] raised, the amount in the high byte.
    public func word(_ n: Int) -> Int {
        let b = boosts[n]
        let bits = statOrder.enumerated().reduce(0) { b.stats.contains($1.element) ? $0 | 0x80 >> $1.offset : $0 }
        return bits | b.amount << 8
    }
}

// MARK: - ROM codec

public enum CTItemROM {
    public static let count = 0xF2
    public static let categories = ["weapon", "armor", "helmet", "accessory", "consumable"]
    public static let first = [0x00, 0x5A, 0x7B, 0x94, 0xBC, 0xF2]        // Menu_ItemCategoryBounds
    public static let sizesA = [6, 6, 6, 4, 3], sizesB = [5, 3, 3, 4, 4]
    static let tablesAPC = 0x3FCF0E, sizesAPC = 0x3FCF18                   // MenuRom_ItemTablesA / RecSizesA
    static let tablesBPC = 0x3FCF1D, sizesBPC = 0x3FCF27                   // MenuRom_ItemTablesB / RecSizesB
    static let statOrderPC = 0x3FCF2C, statCapsPC = 0x3FCF33
    public static let namesPC = 0x0C0B5E, nameSize = 11, nameGlyphs = 10
    public static let targetModePC = 0x0C1BB5                              // 1 B per consumable
    public static let boostsPC = 0x0C29D7, boostCount = 23
    public static let char5AttackPC = 0x0C2D69, char5AttackCount = 100
    public static let descPC = 0x0C2EB1, descEnd = 0x0C36F4                // 242 pointers, then the strings
    public static let modifierCount = 57                                   // BattleRom_UnkCC2A05 records
    public static let elements = CTTechROM.elements                        // bonus bits 7, 6, 5, 4
    public static let accessoryBoostBit = 0x40                             // record B byte 1 bit 6
    public static let halfHPItem = 0xA1, quarterHPItem = 0xA0, doubleStat5Item = 0xA8
    public static let blank: UInt8 = 0xFF, pad: UInt8 = 0xEF               // name glyphs

    /// Record B fields by category, in byte order (the keys of `ItemDef.stats`).
    public static let statFields: [String: [String]] = [
        "weapon": ["attack", "byte1", "critical", "modifier", "modifierArg"],
        "armor": ["defence", "modifier", "modifierOn"],
        "helmet": ["defence", "modifier", "modifierOn"],
        "accessory": ["battleFlags", "special", "specialArg", "specialBits"],
        "consumable": ["useKind", "restores", "amount", "byte3"],
    ]

    public static func category(of item: Int) -> Int { (0..<5).first { item < first[$0 + 1] } ?? 5 }

    /// The file name of a ROM item: its id and its name, e.g. `01_wood_sword`.
    public static func fileID(_ item: Int, name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
            .split(separator: "_").joined(separator: "_")
        return String(format: "%02x_", item) + (slug.isEmpty ? "none" : slug)
    }

    static func word(_ rom: [UInt8], _ at: Int) -> Int { Int(rom[at]) | Int(rom[at + 1]) << 8 }

    static func recordA(_ rom: [UInt8], _ item: Int) -> Int {
        let c = category(of: item)
        return 0x0C0000 + word(rom, tablesAPC + 2 * c) + (item - first[c]) * Int(rom[sizesAPC + c])
    }
    static func recordB(_ rom: [UInt8], _ item: Int) -> Int {
        let c = category(of: item)
        return 0x0C0000 + word(rom, tablesBPC + 2 * c) + (item - first[c]) * Int(rom[sizesBPC + c])
    }

    /// Bytes 1-10 of a name record: $FF is a blank, $EF pads; other glyphs
    /// through the dialogue codec's glyph table ({gXX} when it has none).
    public static func decodeName(_ glyphs: ArraySlice<UInt8>) -> String {
        glyphs.filter { $0 != pad }.map { $0 == blank ? " " : CTTextCodec.glyphText($0) ?? String(format: "{g%02X}", $0) }
            .joined()
    }

    /// The 10 glyph bytes of a name ($EF-padded); throws on an unknown glyph or past 10.
    public static func encodeName(_ name: String) throws -> [UInt8] {
        var out: [UInt8] = [], chars = Array(name), i = 0
        while i < chars.count {
            if chars[i] == "{", i + 4 < chars.count, chars[i + 1] == "g", chars[i + 4] == "}",
               let v = UInt8(String(chars[(i + 2)...(i + 3)]), radix: 16), v >= 0xA0, v != pad {
                out.append(v); i += 5; continue
            }
            if chars[i] == " " { out.append(blank) }
            else if let v = CTTextCodec.glyphByte(String(chars[i])), v != pad, v != blank { out.append(v) }
            else { throw CTROMBuildError("name \(String(reflecting: name)): no glyph for \(String(reflecting: String(chars[i])))") }
            i += 1
        }
        guard out.count <= nameGlyphs else { throw CTROMBuildError("name \(String(reflecting: name)) is \(out.count) glyphs; the most is 10") }
        return out + [UInt8](repeating: pad, count: nameGlyphs - out.count)
    }

    /// Per id, the description's bytes up to (not with) its $00.
    public static func descriptionBytes(rom: [UInt8]) -> [[UInt8]] {
        (0..<count).map { item in
            let at = 0x0C0000 + word(rom, descPC + 2 * item)
            guard at >= descPC, at < descEnd, let end = rom[at..<descEnd].firstIndex(of: 0) else { return [] }
            return Array(rom[at..<end])
        }
    }

    // MARK: Decode

    /// Every item of `rom` and the shared tables. Names and descriptions
    /// need `codec` (nil: names from the glyph table, no descriptions).
    public static func decode(rom: [UInt8], codec: CTTextCodec?) throws -> (items: [ItemDef], tables: ItemTablesDef) {
        let descriptions = descriptionBytes(rom: rom)
        var items: [ItemDef] = []
        for item in 0..<count {
            let c = category(of: item), kind = categories[c]
            let a = recordA(rom, item), b = recordB(rom, item), n = namesPC + nameSize * item
            let name = decodeName(rom[(n + 1)..<(n + nameSize)])
            var stats: [String: Int] = [:]
            for (k, field) in statFields[kind]!.enumerated() { stats[field] = Int(rom[b + k]) }
            let record = ItemDef.Record(itemId: item, icon: Int(rom[n]), flags: Int(rom[a]),
                                        equip: c < 4 ? Int(rom[a + 3]) : nil, boost: c < 3 ? Int(rom[a + 4]) : nil,
                                        elementBonus: c < 3 ? Int(rom[a + 5]) : nil,
                                        targetMode: c == 4 ? Int(rom[targetModePC + item - first[4]]) : nil)
            items.append(ItemDef(id: fileID(item, name: name), name: name, kind: kind, price: word(rom, a + 1),
                                 effect: nil, stats: stats, rom: record,
                                 description: try codec.map { try $0.decode(descriptions[item]) }))
        }
        let order = (0..<7).map { Int(rom[statOrderPC + $0]) }
        let names = CharacterDef.StatBlock.names
        let boosts = (0..<boostCount).map { i -> ItemTablesDef.Boost in
            let w = word(rom, boostsPC + 2 * i)
            return .init(stats: (0..<7).filter { w & (0x80 >> $0) != 0 }.map { names[order[$0]] }, amount: w >> 8)
        }
        let tables = ItemTablesDef(boosts: boosts, statOrder: order.map { names[$0] },
                                   statCaps: (0..<7).map { Int(rom[statCapsPC + $0]) },
                                   char5Attack: (0..<char5AttackCount).map { word(rom, char5AttackPC + 2 * $0) })
        return (items, tables)
    }

    // MARK: Checks

    /// The ranges the game's code keeps (docs/items.md).
    public static func check(_ items: [ItemDef], tables: ItemTablesDef?) throws {
        func need(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw CTROMBuildError("items: \(what())") } }
        var seen = Set<Int>()
        for i in items {
            guard let r = i.rom else { continue }
            let name = String(format: "item $%02X (%@)", r.itemId, i.id)
            try need((0..<count).contains(r.itemId), "\(name): the item id must be 0-$F1")
            try need(seen.insert(r.itemId).inserted, "\(name): item id built twice")
            let c = category(of: r.itemId), kind = categories[c]
            try need(i.kind == kind, "\(name): kind \(i.kind) is not its category (\(kind))")
            try need((0...0xFF).contains(r.flags) && r.flags & 0x61 == 0,
                     String(format: "%@: flags $%02X use bits 0, 5 or 6 (no reader)", name, r.flags & 0xFF))
            try need((0...0xFFFF).contains(i.price ?? -1), "\(name): price \(i.price.map(String.init) ?? "none") is not 0-65535")
            try need((r.equip != nil) == (c < 4), "\(name): equip mask \(c < 4 ? "missing" : "on a consumable")")
            if let e = r.equip { try need((0...0xFE).contains(e) && e & 1 == 0, "\(name): equip mask \(e) names a character past 6") }
            try need((r.boost != nil) == (c < 3) && (r.elementBonus != nil) == (c < 3),
                     "\(name): boost and element bonus are \(c < 3 ? "needed" : "for weapons, armour and helmets only")")
            if let b = r.boost { try need((0..<boostCount).contains(b), "\(name): boost \(b) is not 0-22") }
            if let e = r.elementBonus { try need((0...0xFF).contains(e), "\(name): element bonus must be a byte") }
            try need((r.targetMode != nil) == (c == 4), "\(name): target mode is for consumables only")
            if let t = r.targetMode { try need((0...0xFF).contains(t), "\(name): target mode must be a byte") }
            let fields = statFields[kind]!
            try need(Set((i.stats ?? [:]).keys) == Set(fields), "\(name): stats need exactly \(fields)")
            try need(fields.allSatisfy { (0...0xFF).contains(i.stats![$0]!) }, "\(name): stats must be bytes")
            if c < 3, let m = i.stats?["modifier"] { try need(m < modifierCount, "\(name): modifier \(m) is not 0-56") }
            if c == 1 || c == 2 { try need([0, 1].contains(i.stats!["modifierOn"]!), "\(name): modifierOn is 0 or 1") }
            if c == 3, i.stats!["special"]! & accessoryBoostBit != 0 {
                try need(i.stats!["specialArg"]! < boostCount, "\(name): with special bit 6, specialArg is a boost (0-22)")
            }
            _ = try encodeName(i.name)
        }
        guard let t = tables else { return }
        try need(t.schema == "ct-item-tables/1", "item_tables.json schema \(t.schema) is not ct-item-tables/1")
        try need(t.boosts.count == boostCount, "ItemBoosts needs 23 entries")
        try need(Set(t.statOrder) == Set(CharacterDef.StatBlock.names) && t.statOrder.count == 7 && t.statCaps.count == 7
                 && t.char5Attack.count == char5AttackCount, "statOrder, statCaps and char5Attack need 7, 7 and 100 entries")
        try need(t.boosts.first == .init(stats: [], amount: 0), "boost 0 is no boost (the menu skips it)")
        for (n, b) in t.boosts.enumerated() {
            try need(b.stats.allSatisfy(t.statOrder.contains) && Set(b.stats).count == b.stats.count,
                     "boost \(n): stats \(b.stats) must be distinct stat names")
            try need((0...0xFF).contains(b.amount), "boost \(n): amount \(b.amount) is not 0-255")
        }
    }

    /// The read-only fields must be the base ROM's.
    public static func check(_ items: [ItemDef], tables: ItemTablesDef?, against base: (items: [ItemDef], tables: ItemTablesDef)) throws {
        func need(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw CTROMBuildError("items: \(what())") } }
        for i in items {
            guard let r = i.rom else { continue }
            try need(base.items.indices.contains(r.itemId), String(format: "item $%02X is not 0-$F1", r.itemId))
            try need(r.icon == base.items[r.itemId].rom!.icon, String(format: "item $%02X: the icon byte is read-only", r.itemId))
        }
        if let t = tables {
            try need(t.statOrder == base.tables.statOrder && t.statCaps == base.tables.statCaps
                     && t.char5Attack == base.tables.char5Attack, "the stat order, caps and Char5Attack are read-only")
        }
    }

    // MARK: Writes

    /// The bytes the builder writes, each over the base ROM `rom`: (pc, bytes, what).
    /// Descriptions are written only when one differs from the base's text
    /// (they need `codec`).
    public static func writes(_ items: [ItemDef], tables: ItemTablesDef?, rom: [UInt8],
                              codec: CTTextCodec?) throws -> [(pc: Int, bytes: [UInt8], what: String)] {
        var out: [(pc: Int, bytes: [UInt8], what: String)] = []
        let sorted = items.filter { $0.rom != nil }.sorted { $0.rom!.itemId < $1.rom!.itemId }
        for i in sorted {
            let r = i.rom!, c = category(of: r.itemId), price = i.price ?? 0
            let name = String(format: "item $%02X", r.itemId)
            var a = [UInt8(r.flags), UInt8(price & 0xFF), UInt8(price >> 8)]
            if let e = r.equip { a.append(UInt8(e)) }
            if let b = r.boost, let e = r.elementBonus { a += [UInt8(b), UInt8(e)] }
            out.append((recordA(rom, r.itemId), a, "\(name) record A"))
            out.append((recordB(rom, r.itemId), statFields[categories[c]]!.map { UInt8(i.stats![$0]!) }, "\(name) record B"))
            out.append((namesPC + nameSize * r.itemId + 1, try encodeName(i.name), "\(name) name"))
            if let t = r.targetMode { out.append((targetModePC + r.itemId - first[4], [UInt8(t)], "\(name) target mode")) }
        }
        if let t = tables {
            out.append((boostsPC, (0..<boostCount).flatMap { [UInt8(t.word($0) & 0xFF), UInt8(t.word($0) >> 8)] }, "ItemBoosts"))
        }
        if let codec, let table = try descriptionTable(sorted, rom: rom, codec: codec) {
            out.append((descPC, table, "item descriptions"))
        } else if codec == nil, sorted.contains(where: { $0.description != nil }) {
            throw CTROMBuildError("items: descriptions need the text codec")
        }
        return out
    }

    /// The description table (pointers and strings) when an item's text
    /// differs from the base's; nil when all are the base's. Unchanged texts
    /// keep their bytes; identical strings share one copy.
    static func descriptionTable(_ items: [ItemDef], rom: [UInt8], codec: CTTextCodec) throws -> [UInt8]? {
        var strings = descriptionBytes(rom: rom)
        var changed = false
        for i in items {
            guard let r = i.rom, let text = i.description else { continue }
            if try codec.decode(strings[r.itemId]) == text { continue }
            var bytes = try codec.compileMessage(text)
            bytes.removeLast()                         // the $00 every string gets below
            strings[r.itemId] = bytes
            changed = true
        }
        guard changed else { return nil }
        var pointers: [Int] = [], body: [UInt8] = [], at: [[UInt8]: Int] = [:]
        let start = descPC + 2 * count
        for s in strings {
            if let p = at[s] { pointers.append(p); continue }
            let p = start + body.count
            at[s] = p; pointers.append(p)
            body += s + [0]
        }
        guard start + body.count <= descEnd else {
            throw CTROMBuildError("items: the descriptions take \(body.count) bytes; \(descEnd - start) fit at $CC:\(String(format: "%04X", start & 0xFFFF))")
        }
        body += [UInt8](repeating: 0, count: descEnd - start - body.count)
        return pointers.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF)] } + body
    }

    /// Whether a report write's `what` is one of `writes`'.
    public static func isItemWrite(_ what: String) -> Bool {
        what.hasPrefix("item $") || what == "ItemBoosts" || what == "item descriptions"
    }

    // MARK: Import

    /// The ROM's items into `project.items` (earlier ROM items are replaced,
    /// project-only items kept) and `project.itemTables`; `rom.items` is set.
    /// Returns the item file ids.
    @discardableResult
    public static func importItems(rom input: [UInt8], into project: inout CTProject) throws -> [String] {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("items import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        let codec = try CTTextCodec(profile: project.textProfile ?? CTTextProfile.fromROM(Data(rom)))
        let (items, tables) = try decode(rom: rom, codec: codec)
        project.items = project.items.filter { $0.value.rom == nil }
        for i in items { project.items[i.id] = i }
        project.itemTables = tables
        var spec = project.project.rom ?? .init()
        spec.items = true
        project.project.rom = spec
        return items.map(\.id)
    }
}

// MARK: - Equipment stats

/// The menu's equipment stat totals (Menu_CharRecalc and its callees), the
/// twin of ct_items.calc_stats; tested against its vectors.
public enum CTEquipStats {
    /// What the rule reads: the menu's per-id tables and the ROM's.
    public struct Tables: Sendable {
        public var sortKeys: [Int]             // Menu_ItemSortKeys (256): attack / defence of ids 0-$93
        public var info4: [Int]                // Menu_ItemInfo4 (by id): boost numbers
        public var boosts: [Int]               // ItemBoosts words
        public var statOrder: [Int]            // stat numbers
        public var statCaps: [Int]
        public var char5Attack: [Int]
        public init(sortKeys: [Int], info4: [Int], boosts: [Int], statOrder: [Int], statCaps: [Int], char5Attack: [Int]) {
            self.sortKeys = sortKeys; self.info4 = info4; self.boosts = boosts; self.statOrder = statOrder
            self.statCaps = statCaps; self.char5Attack = char5Attack
        }
    }
    /// The 7 stats with boosts (record order), attack, defence and max HP; and
    /// the record's HP (+$03), lowered to that max HP.
    public struct Result: Equatable, Sendable {
        public var stats: [Int]
        public var attack: Int
        public var defence: Int
        public var maxHp: Int
        public var hp: Int
        /// The 11 bytes Menu_CharRecalc writes at +$36.
        public var derived: [Int] { stats + [attack, defence, maxHp & 0xFF, maxHp >> 8] }
    }

    public struct RuleError: Error, CustomStringConvertible, Sendable { public let description: String }

    /// The tables of a project's items (every id without a ROM record reads 0).
    public static func tables(items: [ItemDef], tables t: ItemTablesDef) -> Tables {
        var sort = [Int](repeating: 0, count: 0x100), info4 = [Int](repeating: 0, count: CTItemROM.count)
        for i in items {
            guard let r = i.rom, (0..<CTItemROM.count).contains(r.itemId) else { continue }
            let c = CTItemROM.category(of: r.itemId)
            if c < 3 { sort[r.itemId] = i.stats?[c == 0 ? "attack" : "defence"] ?? 0; info4[r.itemId] = r.boost ?? 0 }
            if c == 3, let s = i.stats, (s["special"] ?? 0) & CTItemROM.accessoryBoostBit != 0 { info4[r.itemId] = s["specialArg"] ?? 0 }
        }
        let names = CharacterDef.StatBlock.names
        return Tables(sortKeys: sort, info4: info4, boosts: (0..<t.boosts.count).map(t.word),
                      statOrder: t.statOrder.map { names.firstIndex(of: $0) ?? 0 }, statCaps: t.statCaps,
                      char5Attack: t.char5Attack)
    }

    /// Menu_CharRecalc on a $50-byte record.
    public static func compute(record rec: [UInt8], tables t: Tables) throws -> Result {
        guard rec.count >= 0x2B else { throw RuleError(description: "a record is $50 bytes") }
        guard t.sortKeys.count == 0x100, t.statOrder.count == 7, t.statOrder.allSatisfy((0..<7).contains), t.statCaps.count == 7 else {
            throw RuleError(description: "the tables need 256 sort keys, a 7-stat order and 7 caps")
        }
        var boost = [Int](repeating: 0, count: 7), armour = 0
        func word(_ at: Int) -> Int { Int(rec[at]) | Int(rec[at + 1]) << 8 }
        func addBoosts(_ item: Int) throws {
            let v = t.info4.indices.contains(item) ? t.info4[item] : 0
            guard v != 0 else { return }
            guard t.boosts.indices.contains(v) else { throw RuleError(description: "boost \(v) is past ItemBoosts") }
            let bits = t.boosts[v] & 0xFE, amount = t.boosts[v] >> 8
            for i in 0..<7 where bits & (0x80 >> i) != 0 { boost[t.statOrder[i]] = (boost[t.statOrder[i]] + amount) & 0xFF }
        }
        let acc = Int(rec[0x2A]), w5 = word(5)
        var hp = word(3)
        let bonus = acc == CTItemROM.halfHPItem ? w5 >> 1 : acc == CTItemROM.quarterHPItem ? w5 >> 2 : 0
        let maxHp = min((w5 + bonus) & 0xFFFF, CTLevelCurve.maxHpCap)
        if maxHp < hp { hp = maxHp }
        try addBoosts(acc)
        for slot in [0x27, 0x28] {
            armour = (armour + t.sortKeys[Int(rec[slot])]) & 0xFF
            try addBoosts(Int(rec[slot]))
        }
        let power = t.sortKeys[Int(rec[0x29])]
        try addBoosts(Int(rec[0x29]))
        var cur = [Int](repeating: 0, count: 7)
        for i in stride(from: 6, through: 0, by: -1) {
            let s = t.statOrder[i], v = (Int(rec[0x0B + s]) + boost[s]) & 0xFF
            cur[s] = v < t.statCaps[i] ? v : t.statCaps[i]
        }
        let dividend: Int, divisor: Int
        switch Int(rec[0]) & 7 {
        case 1, 2: dividend = (2 * (cur[4] + power)) & 0xFFFF; divisor = 3
        case 5:
            let k = Int(rec[0x12]) & 0x7F                 // the doubled index is taken 8-bit
            guard t.char5Attack.indices.contains(k) else { throw RuleError(description: "Char5Attack entry \(k) is past the table") }
            dividend = (16 * cur[0] + t.char5Attack[k]) & 0xFFFF; divisor = 9
        default: dividend = (5 * power + 12 * cur[0]) & 0xFFFF; divisor = 9
        }
        let attack = min(dividend / divisor, 0xFF), defence = min(cur[1] + armour, 0xFF)
        if acc == CTItemROM.doubleStat5Item { cur[5] = cur[5] << 1 & 0xFF }
        return Result(stats: cur, attack: attack, defence: defence, maxHp: maxHp, hp: hp)
    }
}
