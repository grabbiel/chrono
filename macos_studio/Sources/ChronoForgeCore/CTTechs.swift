// The tech system: single, double and triple techs, their parts, the
// combination table, tech points and the new-game tech state.
// Layout, rule and evidence: docs/techs.md; the Python twin and every
// claim's check: re_workspace/tools/ct_techs.py.
import Foundation

// MARK: - tech_system.json

/// The ROM's tech tables as the builder writes them back. Fields marked
/// read-only are decoded for the Studio and must keep the base ROM's values.
public struct TechSystemDef: Codable, Equatable, Sendable {
    public var schema: String = "ct-techs/1"
    public var techs: [Tech]                   // ids 0-$74: 0 none, $01-$38 singles, $39-$65 doubles, $66-$74 triples
    public var parts: [Part]                   // part numbers 0-71
    public var tpCost: [[Int]]                 // 7 x 8: tech points for each character's single k
    public var combos: [Combo]                 // the ComboTechs records
    public var learned: Learned                // the new-game state
    public var userSets: [[Int]]               // read-only: 52 x 3 character ids, 255 = none
    public var areas: [[Area]]                 // read-only: area number -> its entries (0 = none)

    public struct Tech: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var name: String                // read-only (TechNames; never written)
        public var icon: Int?                  // read-only: the name's icon byte ($2F on magic)
        public var kind: String                // read-only: none | single | double | triple
        public var targetMode: Int             // TechInfo byte 0 bits 6-0: BattleTgt_ModeTable handler (0-$20)
        public var fieldMenu: Bool             // TechInfo byte 0 bit 7: usable from the field menu
        public var area: Int                   // TechInfo byte 1: area number (0 = none, 1-$0B)
        public var userSet: Int                // read-only: TechRec byte 0 bits 6-0
        public var needsUnlock: Bool           // TechRec byte 0 bit 7: needs the character's $7F:01E0 bit
        public var flags: Int                  // read-only: TechRec byte 1
        public var element: String?            // TechRec byte 3 bits 7-4: lightning | shadow | water | fire
        public var attr: Int                   // read-only: TechRec byte 3 bits 3-0
        public var parts: [Int]                // TechRec bytes 5-7: user k's part number, bit 7 = none
        public var modifiers: [Int]            // TechRec bytes 8-10: user k's modifier record
        public var anim: Anim
    }
    public struct Anim: Codable, Equatable, Sendable {
        public var script: Int                 // PcTechScripts number (< 128)
        public var gfxA: Int                   // read-only
        public var gfxB: Int                   // read-only
        public var frames: Int                 // < 80
        public var pal: Int                    // read-only
        public var obj: Int                    // read-only
        public var arg: Int                    // read-only
    }
    public struct Part: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var mp: Int                     // TechMpCost: 0-99 (255 on unused parts)
        public var effect: Effect
    }
    /// An effect record (12 B); docs/techs.md names what each byte does per type.
    public struct Effect: Codable, Equatable, Sendable {
        public var type: Int                   // BattleSys_EffectTable handler (< 45)
        public var arg1: Int
        public var arg2: Int
        public var casterStat: Int             // stat block offset of the hit roll's caster byte
        public var targetStat: Int
        public var formula: Int                // BattleSys_CalcDamage kind (types 3, 8)
        public var defence: Int
        public var flags: Int
        public var flags2: Int
        public var power: Int
        public var immunity: Int
        public var arg11: Int

        public static let names = ["type", "arg1", "arg2", "casterStat", "targetStat", "formula", "defence", "flags",
                                   "flags2", "power", "immunity", "arg11"]
        public init(bytes b: [UInt8]) {
            precondition(b.count == 12)
            type = Int(b[0]); arg1 = Int(b[1]); arg2 = Int(b[2]); casterStat = Int(b[3]); targetStat = Int(b[4])
            formula = Int(b[5]); defence = Int(b[6]); flags = Int(b[7]); flags2 = Int(b[8]); power = Int(b[9])
            immunity = Int(b[10]); arg11 = Int(b[11])
        }
        public var values: [Int] {
            get { [type, arg1, arg2, casterStat, targetStat, formula, defence, flags, flags2, power, immunity, arg11] }
            set {
                precondition(newValue.count == 12)
                type = newValue[0]; arg1 = newValue[1]; arg2 = newValue[2]; casterStat = newValue[3]
                targetStat = newValue[4]; formula = newValue[5]; defence = newValue[6]; flags = newValue[7]
                flags2 = newValue[8]; power = newValue[9]; immunity = newValue[10]; arg11 = newValue[11]
            }
        }
    }
    /// A ComboTechs record: its members' bits ($80 >> id), first id and,
    /// per tech, the members' required single counts (255 for a pair's third).
    public struct Combo: Codable, Equatable, Sendable {
        public var mask: Int                   // read-only
        public var first: Int                  // read-only
        public var requirements: [[Int]]       // count read-only; values 1-8
        public init(mask: Int, first: Int, requirements: [[Int]]) {
            self.mask = mask; self.first = first; self.requirements = requirements
        }
        public var members: [Int] { CTTechROM.members(mask) }
    }
    /// The eighth MenuRom_CharRecordInit record's tech state.
    public struct Learned: Codable, Equatable, Sendable {
        public var counts: [Int]               // singles learned per character (0-8)
        public var bits1: [Int]                // their bits: the top `count` bits
        public var comboBits: [Int]            // 30 B: one per ComboTechs record (doubles from bit 7), then the triples
        public init(counts: [Int], bits1: [Int], comboBits: [Int]) {
            self.counts = counts; self.bits1 = bits1; self.comboBits = comboBits
        }
    }
    public struct Area: Codable, Equatable, Sendable {
        public var shape: Int                  // BattleSys_AreaTable type 0-6
        public var param: Int                  // bit 7 = position query; bits 6-0 = AreaParamTable entry
        public var size: Int                   // bits 6-0 = size; bit 7 = variant
    }

    /// The character ids that perform tech `id` (its user set).
    public func users(of id: Int) -> [Int] {
        guard techs.indices.contains(id), userSets.indices.contains(techs[id].userSet) else { return [] }
        return userSets[techs[id].userSet].filter { $0 != 0xFF }
    }

    /// The ComboTechs record and position of a double or triple tech.
    public func combo(of id: Int) -> (index: Int, k: Int)? {
        for (i, c) in combos.enumerated() where (c.first..<(c.first + c.requirements.count)).contains(id) {
            return (i, id - c.first)
        }
        return nil
    }

    /// Whether tech `id` is learned in the new-game state.
    public func isLearned(_ id: Int) -> Bool {
        if (1..<CTTechROM.firstDouble).contains(id) {
            let c = (id - 1) / 8
            return (id - 1) % 8 < learned.counts[c]
        }
        if let (i, k) = combo(of: id) { return learned.comboBits[i] & (0x80 >> k) != 0 }
        if (CTTechROM.firstTriple..<CTTechROM.count).contains(id) {
            // a triple in no record: its Battle_TechBits3 byte, bit 7
            return learned.comboBits[CTTechROM.doubleRecords + id - CTTechROM.firstTriple] & 0x80 != 0
        }
        return false
    }
}

// MARK: - ROM codec

public enum CTTechROM {
    public static let count = 0x75
    public static let firstDouble = 0x39, firstTriple = 0x66
    public static let namesPC = 0x0C15C4, nameSize = 11
    public static let infoPC = 0x0C1ACB                // 2 B per id
    public static let recPC = 0x0C1BEB, recSize = 11
    public static let effectsPC = 0x0C213F, effectSize = 12
    public static let partCount = 72
    public static let userSetsPC = 0x0C249F, userSetCount = 52
    public static let mpCostPC = 0x0C253B
    public static let tpCostPC = 0x0C26FA              // 8 words per character
    public static let charTechsPC = 0x0C276A
    public static let combosPC = 0x0C2778, comboSize = 5
    public static let modifiersPC = 0x0C2A05, modifierCount = 57
    public static let areaPtrsPC = 0x0C2AB0, areaCount = 12
    public static let actPC = 0x0D45A6, actSize = 7
    public static let statePC = 0x0C0230               // the eighth new-game record
    public static let comboBytes = 30                  // Battle_TechBits2 (15 B) + Battle_TechBits3 (15 B)
    public static let doubleRecords = 15               // bytes 0-14: doubles, 3 per byte; 15-29: triples in bit 7
    public static let stateSize = 2 * CTCharacterROM.count + comboBytes
    public static let targetModes = 0x21, effectTypes = 45, scripts = 128, animFrames = 80
    public static let elements = ["lightning", "shadow", "water", "fire"]   // byte 3 bits 7, 6, 5, 4
    public static let singlesPerCharacter = 8
    public static let allTechsBit = 0x10               // record +$02 bit 4

    public static func kind(_ id: Int) -> String {
        id == 0 ? "none" : id < firstDouble ? "single" : id < firstTriple ? "double" : "triple"
    }

    /// Character ids of a mask's bits, from bit 7.
    public static func members(_ mask: Int) -> [Int] { (0..<CTCharacterROM.count).filter { mask & (0x80 >> $0) != 0 } }

    /// The top `n` bits of a byte (bits1 for n singles learned).
    public static func topBits(_ n: Int) -> Int { (0xFF00 >> min(max(n, 0), 8)) & 0xFF }

    static func word(_ rom: [UInt8], _ at: Int) -> Int { Int(rom[at]) | Int(rom[at + 1]) << 8 }

    /// Every tech table of `rom`. Names need `codec` (nil: names left empty).
    public static func decode(rom: [UInt8], codec: CTTextCodec?) throws -> TechSystemDef {
        var techs: [TechSystemDef.Tech] = []
        for t in 0..<count {
            let rec = Array(rom[(recPC + recSize * t)..<(recPC + recSize * (t + 1))])
            let act = Array(rom[(actPC + actSize * t)..<(actPC + actSize * (t + 1))])
            let info0 = Int(rom[infoPC + 2 * t]), info1 = Int(rom[infoPC + 2 * t + 1])
            let raw = Array(rom[(namesPC + nameSize * t)..<(namesPC + nameSize * (t + 1))])
            let icon: Int? = raw[0] < 0xA0 && raw[0] != 0xEF && raw[0] != 0xFF ? Int(raw[0]) : nil
            var name = ""
            if let codec {
                // Glyphs one at a time (as the item names): $FF is a blank, $EF pads.
                name = try raw.dropFirst(icon == nil ? 0 : 1).filter { $0 != 0xEF }
                    .map { $0 == 0xFF ? " " : try codec.decode([$0]) }.joined()
                    .trimmingCharacters(in: .whitespaces)
            }
            let bits = Int(rec[3]) >> 4
            techs.append(.init(id: t, name: name, icon: icon, kind: kind(t), targetMode: info0 & 0x7F,
                               fieldMenu: info0 & 0x80 != 0, area: info1, userSet: Int(rec[0]) & 0x7F,
                               needsUnlock: rec[0] & 0x80 != 0, flags: Int(rec[1]),
                               element: (0..<4).first { bits & (8 >> $0) != 0 }.map { elements[$0] },
                               attr: Int(rec[3]) & 0x0F, parts: rec[5..<8].map(Int.init),
                               modifiers: rec[8..<11].map(Int.init),
                               anim: .init(script: Int(act[0]), gfxA: Int(act[1]), gfxB: Int(act[2]), frames: Int(act[3]),
                                           pal: Int(act[4]), obj: Int(act[5]), arg: Int(act[6]))))
        }
        let parts = (0..<partCount).map { p in
            TechSystemDef.Part(id: p, mp: Int(rom[mpCostPC + p]),
                               effect: .init(bytes: Array(rom[(effectsPC + effectSize * p)..<(effectsPC + effectSize * (p + 1))])))
        }
        let tpCost = (0..<CTCharacterROM.count).map { c in (0..<8).map { word(rom, tpCostPC + 16 * c + 2 * $0) } }
        var combos: [TechSystemDef.Combo] = []
        var at = combosPC
        while rom[at] != 0xFF {
            let req = 0x0C0000 + word(rom, at + 3)
            combos.append(.init(mask: Int(rom[at]), first: Int(rom[at + 1]),
                                requirements: (0..<Int(rom[at + 2])).map { k in (0..<3).map { Int(rom[req + 3 * k + $0]) } }))
            at += comboSize
        }
        let state = rom[statePC..<(statePC + stateSize)].map(Int.init)
        let n = CTCharacterROM.count
        let learned = TechSystemDef.Learned(counts: Array(state[0..<n]), bits1: Array(state[n..<(2 * n)]),
                                            comboBits: Array(state[(2 * n)...]))
        let userSets = (0..<userSetCount).map { s in (0..<3).map { Int(rom[userSetsPC + 3 * s + $0]) } }
        var areas: [[TechSystemDef.Area]] = [[]]
        for a in 1..<areaCount {
            let rec = 0x0C0000 + word(rom, areaPtrsPC + 2 * a)
            areas.append((0..<Int(rom[rec])).map { k in
                .init(shape: Int(rom[rec + 1 + 3 * k]), param: Int(rom[rec + 2 + 3 * k]), size: Int(rom[rec + 3 + 3 * k]))
            })
        }
        return TechSystemDef(techs: techs, parts: parts, tpCost: tpCost, combos: combos, learned: learned,
                             userSets: userSets, areas: areas)
    }

    // MARK: Checks

    /// The ranges the game's code keeps (docs/techs.md): the jump tables'
    /// sizes, the tables' sizes, and a new-game state the tech-point code reads.
    public static func check(_ s: TechSystemDef) throws {
        func need(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw CTROMBuildError("techs: \(what())") } }
        try need(s.schema == "ct-techs/1", "schema \(s.schema) is not ct-techs/1")
        try need(s.techs.count == count && s.techs.enumerated().allSatisfy { $0.offset == $0.element.id },
                 "need techs 0-$74 in order")
        for t in s.techs {
            let name = String(format: "tech $%02X", t.id)
            try need((0..<targetModes).contains(t.targetMode), "\(name): target mode \(t.targetMode) is not 0-$20")
            try need((0..<areaCount).contains(t.area) && (t.area == 0 || s.areas.indices.contains(t.area) && !s.areas[t.area].isEmpty),
                     "\(name): area \(t.area) is not 0-$0B")
            try need(t.element == nil || elements.contains(t.element!), "\(name): element \(t.element ?? "") is not one of \(elements)")
            try need(t.parts.count == 3 && t.parts.allSatisfy { (0...0xFF).contains($0) && $0 & 0x7F < partCount },
                     "\(name): parts \(t.parts) need 3 part numbers below 72 (bit 7 = none)")
            try need(t.modifiers.count == 3 && t.modifiers.allSatisfy { (0..<modifierCount).contains($0) },
                     "\(name): modifiers \(t.modifiers) need 3 record numbers below \(modifierCount)")
            try need((0..<scripts).contains(t.anim.script), "\(name): animation script \(t.anim.script) is not 0-127")
            try need((0..<animFrames).contains(t.anim.frames), "\(name): animation frames \(t.anim.frames) is not 0-79")
        }
        try need(s.parts.count == partCount && s.parts.enumerated().allSatisfy { $0.offset == $0.element.id },
                 "need parts 0-71 in order")
        for p in s.parts {
            try need((0...99).contains(p.mp) || p.mp == 0xFF, "part \(p.id): MP \(p.mp) is not 0-99 (or 255)")
            try need((0..<effectTypes).contains(p.effect.type), "part \(p.id): effect type \(p.effect.type) is not 0-44")
            try need(p.effect.values.allSatisfy { (0...0xFF).contains($0) }, "part \(p.id): effect bytes must be 0-255")
        }
        try need(s.tpCost.count == CTCharacterROM.count && s.tpCost.allSatisfy { $0.count == 8 }, "tpCost needs 7 rows of 8")
        try need(s.tpCost.joined().allSatisfy { (0...0xFFFF).contains($0) }, "tech points must be 0-65535")
        for (i, c) in s.combos.enumerated() {
            let who = c.members.count
            try need(who == 2 || who == 3, "combination \(i): mask \(c.mask) needs 2 or 3 characters")
            for (k, row) in c.requirements.enumerated() {
                try need(row.count == 3 && row.prefix(who).allSatisfy { (1...8).contains($0) } && row.dropFirst(who).allSatisfy { $0 == 0xFF },
                         String(format: "tech $%02X: requirements %@ need 1-8 per member (255 for a pair's third)",
                                c.first + k, "\(row)"))
            }
        }
        let l = s.learned
        try need(l.counts.count == CTCharacterROM.count && l.counts.allSatisfy { (0...singlesPerCharacter).contains($0) },
                 "learned counts \(l.counts) need 7 values 0-8")
        try need(l.bits1.count == CTCharacterROM.count && zip(l.bits1, l.counts).allSatisfy { $0 == topBits($1) },
                 "learned single bits \(l.bits1) must be each count's top bits")
        try need(l.comboBits.count == comboBytes, "learned comboBits need \(comboBytes) bytes")
        for (i, b) in l.comboBits.enumerated() {
            let allowed = i < s.combos.count ? topBits(s.combos[i].requirements.count) : i >= doubleRecords ? 0x80 : 0
            try need(b & ~allowed == 0, String(format: "learned combination byte %d: $%02X sets a bit past its techs", i, b))
        }
    }

    /// The read-only fields must be the base ROM's (names aside: never written).
    public static func check(_ s: TechSystemDef, against base: TechSystemDef) throws {
        func need(_ ok: Bool, _ what: @autoclosure () -> String) throws { if !ok { throw CTROMBuildError("techs: \(what())") } }
        try need(s.techs.count == base.techs.count, "need techs 0-$74 in order")
        for (t, b) in zip(s.techs, base.techs) {
            let name = String(format: "tech $%02X", t.id)
            try need(t.kind == b.kind && t.userSet == b.userSet, "\(name): kind and user set are read-only")
            try need(t.flags == b.flags && t.attr == b.attr, "\(name): flags and attributes are read-only")
            let (a, x) = (t.anim, b.anim)
            try need(a.gfxA == x.gfxA && a.gfxB == x.gfxB && a.pal == x.pal && a.obj == x.obj && a.arg == x.arg,
                     "\(name): only the animation's script and frames are writable")
        }
        try need(s.combos.count == base.combos.count, "the combination records are read-only (\(base.combos.count) records)")
        for (c, b) in zip(s.combos, base.combos) {
            try need(c.mask == b.mask && c.first == b.first && c.requirements.count == b.requirements.count,
                     String(format: "combination $%02X: members, first tech and count are read-only", b.first))
        }
        try need(s.userSets == base.userSets, "user sets are read-only")
        try need(s.areas == base.areas, "areas are read-only")
    }

    // MARK: Writes

    /// The bytes the builder writes, each over the base ROM `rom`: (pc, bytes, what).
    public static func writes(_ s: TechSystemDef, rom: [UInt8]) -> [(pc: Int, bytes: [UInt8], what: String)] {
        var out: [(pc: Int, bytes: [UInt8], what: String)] = []
        for t in s.techs {
            let name = String(format: "tech $%02X", t.id)
            out.append((infoPC + 2 * t.id, [UInt8(t.targetMode | (t.fieldMenu ? 0x80 : 0)), UInt8(t.area)], "\(name) target"))
            let rec = recPC + recSize * t.id
            out.append((rec, [rom[rec] & 0x7F | (t.needsUnlock ? 0x80 : 0)], "\(name) unlock"))
            let bits = t.element.flatMap { elements.firstIndex(of: $0) }.map { 0x80 >> $0 } ?? 0
            out.append((rec + 3, [rom[rec + 3] & 0x0F | UInt8(bits)], "\(name) element"))
            out.append((rec + 5, (t.parts + t.modifiers).map { UInt8($0) }, "\(name) parts"))
            let act = actPC + actSize * t.id
            out.append((act, [UInt8(t.anim.script)], "\(name) animation script"))
            out.append((act + 3, [UInt8(t.anim.frames)], "\(name) animation frames"))
        }
        for p in s.parts {
            out.append((mpCostPC + p.id, [UInt8(p.mp)], "part \(p.id) MP"))
            out.append((effectsPC + effectSize * p.id, p.effect.values.map { UInt8($0) }, "part \(p.id) effect"))
        }
        out.append((tpCostPC, s.tpCost.joined().flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }, "TechTpCost"))
        for (i, c) in s.combos.enumerated() {
            let req = 0x0C0000 + word(rom, combosPC + comboSize * i + 3)
            out.append((req, c.requirements.joined().map { UInt8($0) }, String(format: "combination $%02X requirements", c.first)))
        }
        let l = s.learned
        out.append((statePC, (l.counts + l.bits1 + l.comboBits).map { UInt8($0) }, "new-game tech state"))
        for c in 0..<CTCharacterROM.count {
            let at = CTCharacterROM.recordPC(c) + 2
            let all = l.counts[c] >= singlesPerCharacter ? UInt8(allTechsBit) : 0
            out.append((at, [rom[at] & ~UInt8(allTechsBit) | all], "record \(c) all-singles bit"))
        }
        return out
    }

    /// Whether a report write's `what` is one of `writes`'.
    public static func isTechWrite(_ what: String) -> Bool {
        ["tech $", "part ", "TechTpCost", "combination $", "new-game tech state"].contains { what.hasPrefix($0) }
            || what.hasPrefix("record ") && what.hasSuffix(" all-singles bit")
    }

    // MARK: Import

    /// The ROM's tech tables into `project.techSystem`; `rom.techs` is set.
    public static func importTechs(rom input: [UInt8], into project: inout CTProject) throws {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("techs import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        let codec = try CTTextCodec(profile: project.textProfile ?? CTTextProfile.fromROM(Data(rom)))
        project.techSystem = try decode(rom: rom, codec: codec)
        var spec = project.project.rom ?? .init()
        spec.techs = true
        project.project.rom = spec
    }
}

// MARK: - Tech points

/// The game's tech-point award (BattleSys_AwardTechPoints and callees), the
/// twin of ct_techs.award_tech_points; tested against its vectors.
public enum CTTechPoints {
    public static let totalCap = 0x98967F

    /// A PC slot: character id, record +$02 (bit 4 = all singles learned),
    /// total tech points (+$16, 24 bits) and the next single's need (+$2D).
    public struct Slot: Codable, Equatable, Sendable {
        public var char: Int
        public var flags: Int
        public var tp: Int
        public var toNext: Int
        public init(char: Int, flags: Int, tp: Int, toNext: Int) {
            self.char = char; self.flags = flags; self.tp = tp; self.toNext = toNext
        }
    }
    /// Battle_TechCount / Bits1 / Bits2+3, the unlock byte $7F:01E0 and the party.
    public struct State: Codable, Equatable, Sendable {
        public var counts: [Int]
        public var bits1: [Int]
        public var comboBits: [Int]
        public var unlock: Int
        public var slots: [Slot?]
        public init(counts: [Int], bits1: [Int], comboBits: [Int], unlock: Int, slots: [Slot?]) {
            self.counts = counts; self.bits1 = bits1; self.comboBits = comboBits; self.unlock = unlock; self.slots = slots
        }
    }
    public struct Tables: Sendable {
        public var charTechs: [[Int]]          // (first id, count) per character
        public var tp: [Int]                   // the 56 TechTpCost words and the word after them
        public var needsUnlock: [Bool]         // per tech id
        public var combos: [TechSystemDef.Combo]
        public init(charTechs: [[Int]], tp: [Int], needsUnlock: [Bool], combos: [TechSystemDef.Combo]) {
            self.charTechs = charTechs; self.tp = tp; self.needsUnlock = needsUnlock; self.combos = combos
        }
    }

    public struct RuleError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// The tables of a tech system. CharTechs is fixed (8 singles from 1 + 8c),
    /// so the word after the TP rows is its first entry (1, 8).
    public static func tables(_ s: TechSystemDef) -> Tables {
        Tables(charTechs: (0..<CTCharacterROM.count).map { [1 + 8 * $0, 8] }, tp: Array(s.tpCost.joined()) + [1 | 8 << 8],
               needsUnlock: s.techs.map(\.needsUnlock), combos: s.combos)
    }

    /// The new-game state with `party` (character ids or nil) in slots 0-2:
    /// the tech state of `system`, tech points from the characters' records.
    public static func startingState(_ system: TechSystemDef, records: [Int: CharacterDef.Record], party: [Int?],
                                     unlock: Int) -> State {
        let l = system.learned
        return State(counts: l.counts, bits1: l.bits1, comboBits: l.comboBits, unlock: unlock, slots: party.map { c in
            c.map { c in
                let r = records[c]
                return Slot(char: c, flags: l.counts[c] >= CTTechROM.singlesPerCharacter ? CTTechROM.allTechsBit : 0,
                            tp: r?.techPoints ?? 0, toNext: r?.techPointsToNext ?? 0)
            }
        })
    }

    static func needsUnlock(_ t: Tables, _ tech: Int) throws -> Bool {
        guard t.needsUnlock.indices.contains(tech) else {
            throw RuleError(description: String(format: "tech $%02X is past the tech table", tech))
        }
        return t.needsUnlock[tech]
    }

    /// BattleSys_SpendTechPoints, quirks included: after T >= L the loop
    /// pays the award (or a stored leftover) again.
    static func spend(_ t: Tables, _ s: inout State, slot n: Int, award: Int) throws {
        var b2db = award
        while true {
            // BattleSys_TryNextTech
            var slot = s.slots[n]!
            let cid = slot.char
            let tech = (t.charTechs[cid][0] + s.counts[cid]) & 0xFF
            if try needsUnlock(t, tech), s.unlock & (1 << cid) == 0 { break }
            let need = slot.toNext
            guard need <= b2db else { slot.toNext = need - b2db; s.slots[n] = slot; break }
            slot.toNext = b2db - need
            if slot.flags & CTTechROM.allTechsBit != 0 { s.slots[n] = slot; break }
            // BattleSys_LearnSingleTech
            let count = s.counts[cid]
            s.bits1[cid] |= count < 8 ? 0x80 >> count : 0
            s.counts[cid] = (count + 1) & 0xFF
            if s.counts[cid] >= t.charTechs[cid][1] { slot.flags |= CTTechROM.allTechsBit }
            let index = cid * 8 + ((s.counts[cid] * 2) & 0xFF) / 2
            guard t.tp.indices.contains(index) else { throw RuleError(description: "the next cost is past the TP table") }
            let cost = t.tp[index], left = slot.toNext
            if cost >= left { slot.toNext = cost - left } else { b2db = left; slot.toNext = cost }
            s.slots[n] = slot
        }
        var slot = s.slots[n]!
        var low = (slot.tp & 0xFFFF) + award, high = slot.tp >> 16
        if low > 0xFFFF { low &= 0xFFFF; high = (high + 1) & 0xFF }
        if low >= 0x967F && high >= 0x98 { high = 0x98; low = 0x967F }
        slot.tp = high << 16 | low
        s.slots[n] = slot
    }

    /// BattleSys_BuildComboMasks: the slots' bits sorted up; the pairs, then all three.
    public static func comboMasks(_ chars: [Int?]) -> [Int] {
        var p = chars.map { c in c.map { $0 < 8 ? 0x80 >> $0 : 0 } ?? 0 }
        for (i, j) in [(0, 1), (0, 2), (1, 2)] where !(p[i] < p[j]) { p.swapAt(i, j) }
        return [p[0] | p[1], p[0] | p[2], p[1] | p[2], p[0] | p[1] | p[2]]
    }

    /// BattleSys_AwardTechPoints: the state after a battle's `award` (0-65535).
    public static func award(_ state: State, tables t: Tables, award: Int) throws -> State {
        guard (0...0xFFFF).contains(award) else { throw RuleError(description: "an award is 0-65535") }
        guard state.slots.count == 3 else { throw RuleError(description: "a party has 3 slots") }
        var s = state
        for n in 0..<3 {
            guard let slot = s.slots[n], slot.flags & CTTechROM.allTechsBit == 0 else { continue }
            guard (0..<t.charTechs.count).contains(slot.char) else { throw RuleError(description: "character id \(slot.char)") }
            try spend(t, &s, slot: n, award: award)
        }
        for mask in comboMasks(s.slots.map { $0?.char }) {
            guard let i = t.combos.firstIndex(where: { $0.mask == mask }), t.combos[i].first != 0xFF else { continue }
            let rec = t.combos[i]
            guard !rec.requirements.isEmpty else { throw RuleError(description: "a combination record with no techs") }
            let counts = CTTechROM.members(mask).map { s.counts[$0] }
            let reqs = Array(rec.requirements.joined())
            var tech = rec.first
            for k in 0..<rec.requirements.count {
                let bit = k < 8 ? 0x80 >> k : 0
                if s.comboBits[i] & bit == 0,
                   counts.enumerated().allSatisfy({ $0.element >= reqs[3 * k + $0.offset] }),
                   try !needsUnlock(t, tech) {
                    s.comboBits[i] |= bit
                }
                tech = (tech + 1) & 0xFF
            }
        }
        return s
    }
}
