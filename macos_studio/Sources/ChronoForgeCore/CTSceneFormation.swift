// CTSceneFormation.swift — which enemies a field battle starts with. `$D8 a b`
// does not select a formation: `a` is Battle_Unk2989 (Field_Unk7E2989), a byte
// of battle behaviour bits, and `b` FieldBtl_EvtFlags. The enemies are the
// location's own objects, chosen when the scene changes to the battle:
//
//   Field_Unk0617 ($C0:0617)     lists the objects from slot Evt_ObjCount x 2
//                                down to 2 with Obj_Unk1A81 bit 7 or Obj_Unk0F00
//                                set, of kind 5 or 6 (Obj_Unk1100: `$83`
//                                InitEnemySprite), inside the screen (tile minus
//                                Map_TileOriginX/Y / 2 in 1..$0E / 1..$0D), at
//                                most $0C, then Obj_None
//   FieldBtl_SaveObjs ($C0:04ED) empties the 8 FieldBtlObj records and runs
//   FieldBtl_SaveObj ($C0:0557)  for list entries 0-5: the record number from
//                                Obj_VramTile (`$83`'s tile slot), and in it
//                                Obj_Unk1101 (`$83`'s first operand) at +5
//
// and the battle reads +5 of each record as BattleEnemyInit.Id ($7E:29C4,
// 12 bytes a record; BankCC's enemy set-up indexes BattleRom_EnemySpr and
// Battler_UnkAEFF by it): the enemy id. `ct_scene_run.py formations` runs
// both routines in ChronoRET's interpreter against `compute`.
import Foundation

public enum CTSceneFormation {
    public static let objectList = WRAM.dpField + 0x9D          // Field_BattleObjList
    public static let objectSlots = WRAM.dpField + 0xA3         // FieldBtl_ObjSlots (8)
    public static let records = 0x7E29BF                        // FieldBtlObj, 12 bytes each
    public static let recordSize = 12, listMax = 0x0C, viewTilesX = 0x0F, viewTilesY = 0x0E

    /// One FieldBtlObj record the battle starts from.
    public struct Enemy: Codable, Equatable, Sendable {
        public var record: Int          // 0-7: the battle's enemy slot
        public var object: Int          // the field object
        public var enemyId: Int         // Obj_Unk1101 = BattleEnemyInit.Id
        public var flags: Int           // FieldBtlObj.Flags: size class, $40 kind 6, $80 Obj_Unk1A81 bit 7
        public var tileX: Int, tileY: Int
        public var name: String?
    }

    /// A `$D8` the run reached, with the enemies the hand-off would save.
    public struct Battle: Codable, Equatable, Sendable {
        public var frame: Int, object: Int, offset: Int
        public var unk2989: Int, evtFlags: Int
        public var listed: [Int]        // Field_BattleObjList: object numbers
        public var enemies: [Enemy]
        public var bits: [String]       // Battle_Unk2989's bits as the battle code reads them
    }

    /// Battle_Unk2989's bits, by the battle routines that test them (constants_battle.inc).
    public static func describe2989(_ v: Int) -> [String] {
        let names: [(Int, String)] = [
            (0x01, "bit 0: service 8 returns before its pose"),
            (0x02, "bit 1: copied to Battle_UnkEC at the start"),
            (0x04, "bit 2: boxes end at the probe y"),
            (0x10, "bit 4: ORed into Battle_ActAttrBits"),
            (0x20, "bit 5: a fixed battle (Start does not pause, Battle_RandRange gives its low bound, PCs' ATB $30)"),
            (0x80, "bit 7: L+R does not bump Battle_Unk99CD"),
        ]
        var out = names.filter { v & $0.0 != 0 }.map(\.1)
        if v & 0x48 != 0 { out.append(String(format: "bits $%02X: not traced", v & 0x48)) }
        return out
    }

    /// Field_Unk0617 then FieldBtl_SaveObjs on `w` (which they change as the
    /// routines do: the list, the slots and the records).
    public static func compute(_ w: inout WRAMModel) -> (listed: [Int], enemies: [Enemy]) {
        let originX = w[WRAM.mapTileOriginX] >> 1, originY = w[WRAM.mapTileOriginY] >> 1
        w[WRAM.dpField + 0xDB] = originX; w[WRAM.dpField + 0xDD] = originY        // FieldBtl_OriginX/Y
        var list: [UInt8] = []
        var x = Int(w[WRAM.evtObjCount] &<< 1)
        repeat {
            defer { x = (x - 2) & 0xFF }
            guard w[WRAM.objUnk1A81 + x] & 0x80 != 0 || w[WRAM.objUnk0F00 + x] != 0 else { continue }
            let kind = w[WRAM.objUnk1100 + x]
            guard kind == 5 || kind == 6 else { continue }
            let dx = w[WRAM.objTileX + x] &- originX, dy = w[WRAM.objTileY + x] &- originY
            guard dx != 0, dx < viewTilesX, dy != 0, dy < viewTilesY else { continue }
            list.append(UInt8(x))
            if list.count == listMax { break }
        } while x != 0
        for (i, s) in list.enumerated() { w[objectList + i] = s }
        w[objectList + list.count] = 0x80
        // FieldBtl_SaveObjs
        w[WRAM.dpField + 0xF0] = originX; w[WRAM.dpField + 0xF1] = originY          // FieldBtl_RestOriginX/Y
        for k in 0..<8 { w[records + k * recordSize + 5] = 0xFF; w[records + k * recordSize + 6] = 0xFF; w[objectSlots + k] = 0xFF }
        var enemies: [Enemy] = []
        for s in list.prefix(6) {
            if let e = save(&w, slot: Int(s), originX: originX, originY: originY) { enemies.append(e) }
        }
        return (list.map { Int($0) / 2 }, enemies)
    }

    /// FieldBtl_SaveObj (8-bit X: the record offset is the product's low byte).
    static func save(_ w: inout WRAMModel, slot y: Int, originX: UInt8, originY: UInt8) -> Enemy? {
        let tile = w[WRAM.objVramTile + y]
        guard tile < 0xC0 else { return nil }
        let v = tile >> 3
        let rec = Int(((v >> 1) &- 4 &+ (v & 1)) & 0xFF)
        w[objectSlots + rec] = UInt8(y)                     // D + $A3 + X: no wrap in the page
        let at = records + ((rec * recordSize) & 0xFF)
        let tx = w[WRAM.objTileX + y] &- originX, ty = w[WRAM.objTileY + y] &- originY
        w[at] = tx; w[at + 2] = w[WRAM.objScreenX + y] & 0x0F
        w[at + 1] = ty; w[at + 3] = w[WRAM.objScreenY + y] & 0x0F
        w[at + 5] = w[WRAM.objUnk1101 + y]; w[at + 6] = 0
        let size = w[WRAM.objSprSize + y] & 0x03
        var flags = w[WRAM.objUnk1100 + y] == 6 ? size | 0x40 : size
        flags |= w[WRAM.objUnk1A81 + y] & 0x80
        w[at + 7] = flags
        w[at + 4] = size >= 3 ? 0 : w[WRAM.objLastFrame + y]
        w[at + 8] = w[WRAM.objOamAttr + y] >> 1          // before it, Obj_Unk72B4's palette claim (not run here)
        w[at + 11] = w[WRAM.objGfxBank + y]
        w[at + 10] = w[WRAM.objGfxOfs + y + 1]; w[at + 9] = w[WRAM.objGfxOfs + y]
        guard rec < 8 else { return nil }
        return Enemy(record: rec, object: y / 2, enemyId: Int(w[WRAM.objUnk1101 + y]), flags: Int(flags),
                     tileX: Int(tx), tileY: Int(ty), name: nil)
    }

    /// Enemy `id`'s name from the ROM's enemy name table.
    public static func name(_ id: Int, rom: [UInt8]) -> String? {
        let at = CTEnemyROM.namePC(id)
        guard id < CTEnemyROM.named, at + CTEnemyROM.nameSize <= rom.count else { return nil }
        let n = CTEnemyROM.decodeName(rom[at..<(at + CTEnemyROM.nameSize)])
        return n.isEmpty ? nil : n
    }

    /// The location's encounter groups without running it: per `$D8`, its
    /// object, and the enemy objects (`$83`) that can join, by their ids.
    public struct Group: Codable, Equatable, Sendable {
        public var object: Int, offset: Int, unk2989: Int, evtFlags: Int
        public var candidates: [Candidate]
        public var label: String
    }
    public struct Candidate: Codable, Equatable, Sendable {
        public var object: Int, enemyId: Int, tileSlot: Int, kind6: Bool, name: String?
    }

    public static func groups(_ analysis: CTSceneAnalysis, rom: [UInt8]?) -> [Group] {
        var candidates: [Candidate] = []
        for o in analysis.objects {
            for m in o.markers where m.kind == "enemySprite" {
                candidates.append(Candidate(object: o.index, enemyId: m.operands[0], tileSlot: (m.operands[1] & 0x7F) + 1,
                                            kind6: m.operands[1] & 0x80 != 0, name: rom.flatMap { name(m.operands[0], rom: $0) }))
            }
        }
        var seen = Set<Int>(), out: [Group] = []
        for o in analysis.objects {
            for m in o.markers where m.kind == "battle" && seen.insert(m.offset).inserted {
                let names = candidates.map { $0.name ?? String(format: "enemy $%02X", $0.enemyId) }
                var counts: [String: Int] = [:]
                for n in names { counts[n, default: 0] += 1 }
                let label = counts.keys.sorted().map { counts[$0]! > 1 ? "\($0) ×\(counts[$0]!)" : $0 }.joined(separator: ", ")
                out.append(Group(object: o.index, offset: m.offset, unk2989: m.operands[0], evtFlags: m.operands[1],
                                 candidates: candidates, label: label.isEmpty ? "no enemy objects" : label))
            }
        }
        return out
    }
}
