// CTSceneRunVectors.swift — the model's side of re_workspace/tools/ct_scene_run.py:
//
//   durations   one instruction of one object over consecutive frames, each
//               frame as CTFieldRuntime runs it: the script timer
//               (Obj_Unk1001 counting down to Obj_Unk1000), the handler when
//               it runs out, then the object's Obj_MoveStep and its animation
//               tick (Obj_AnimTickAndQueue, the frame-build queue empty, as the
//               runtime drains it every frame). Per frame: X, carry, position,
//               Obj_MoveFrames and the animation bytes; the frame X moves on is
//               the instruction's length in frames.
//   formations  Field_Unk0617 and FieldBtl_SaveObjs (CTSceneFormation.compute)
//               on a WRAM state: the object list, FieldBtl_ObjSlots and the
//               8 FieldBtlObj records.
//
// The tool runs the ROM's handler and routines in ChronoRET's interpreter on
// the same states and compares.
import Foundation

public enum CTSceneRunVectors {
    struct Input: Decodable {
        var packs: [String: String]
        var durations: [Duration]
        var formations: [Formation]
    }
    struct Duration: Decodable {
        var id: Int, pack: String, y: Int, slot: Int, frames: Int
        var regions: [[Region]]
    }
    struct Formation: Decodable {
        var id: Int
        var regions: [[Region]]
    }
    /// [address, hex bytes] as ct_event_vm.py writes them.
    enum Region: Decodable {
        case address(Int), bytes(String)
        init(from d: Decoder) throws {
            let c = try d.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .address(n) } else { self = .bytes(try c.decode(String.self)) }
        }
    }

    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = [], chars = Array(s.utf8), i = 0
        out.reserveCapacity(chars.count / 2)
        while i + 1 < chars.count {
            out.append(UInt8(String(decoding: chars[i...(i + 1)], as: UTF8.self), radix: 16) ?? 0)
            i += 2
        }
        return out
    }

    static func load(_ regions: [[Region]], into w: inout WRAMModel) {
        for r in regions {
            guard r.count == 2, case .address(let at) = r[0], case .bytes(let h) = r[1] else { continue }
            for (i, b) in hex(h).enumerated() { w[at + i] = b }
        }
    }

    /// The bytes compared each frame, in this order.
    public static let frameFields = ["x", "carry", "posX", "posY", "moveFrames", "animTimer", "animColumn", "animLoops", "animMode"]

    public static func run(rom: [UInt8], casesJSON: Data, romAnimLoops: Bool = true) throws -> Data {
        let input = try JSONDecoder().decode(Input.self, from: casesJSON)
        var packs: [String: CTEventPack] = [:]
        for (k, v) in input.packs { packs[k] = try CTEventPack(bytes: hex(v)) }
        // A field to borrow Obj_MoveStep and the animation tick from (its map is not used).
        let field = try CTFieldRuntime(rom: rom, location: 0)
        field.romAnimLoops = romAnimLoops
        var durations: [[String: Any]] = []
        for c in input.durations {
            guard let pack = packs[c.pack] else { throw CTEventError("no pack \(c.pack)") }
            field.vm.wram = WRAMModel()
            field.vm.load(pack: pack)
            load(c.regions, into: &field.vm.wram)
            let s = c.slot
            var x = c.y, rows: [[Int]] = [], done: Int?, stop: String?
            for f in 0..<c.frames {
                var carry = 0
                var runs = false
                if field.vm.wram[WRAM.objUnk1001 + s] != 0 {
                    field.vm.wram[WRAM.objUnk1001 + s] &-= 1
                    runs = field.vm.wram[WRAM.objUnk1001 + s] == 0
                } else {
                    runs = true
                }
                if runs {
                    field.vm.wram.setWord(WRAM.objCur, s)
                    switch field.vm.execute(at: x) {
                    case .go(let next, let c):
                        carry = c ? 1 : 0
                        if next != x { done = f }
                        x = next
                    case .unmodelled(let why), .halted(let why):
                        stop = why
                    }
                    field.vm.wram[WRAM.objUnk1001 + s] = field.vm.wram[WRAM.objUnk1000 + s]
                }
                if stop != nil { break }
                field.vm.wram.setWord(WRAM.objCur, s)
                field.moveStep(s)
                field.animTick(s)
                let w = field.vm.wram
                rows.append([x, carry, w.word(WRAM.objPosX + s), w.word(WRAM.objPosY + s), Int(w[WRAM.objMoveFrames + s]),
                             Int(w[WRAM.objAnimTimer + s]), Int(w[WRAM.objAnimColumn + s]), Int(w[WRAM.objXAnimLoops + s]),
                             Int(w[WRAM.objAnimMode + s])])
                if done != nil { break }
            }
            var r: [String: Any] = ["id": c.id, "frames": rows]
            if let done { r["done"] = done }
            if let stop { r["stop"] = stop }
            durations.append(r)
        }
        var formations: [[String: Any]] = []
        for c in input.formations {
            var w = WRAMModel()
            load(c.regions, into: &w)
            let (listed, enemies) = CTSceneFormation.compute(&w)
            let list = listed.map { 2 * $0 } + [0x80]               // as Field_Unk0617 wrote it
            let slots = (0..<8).map { Int(w[CTSceneFormation.objectSlots + $0]) }
            let records = (0..<(8 * CTSceneFormation.recordSize)).map { Int(w[CTSceneFormation.records + $0]) }
            formations.append(["id": c.id, "list": list, "slots": slots, "records": records, "listed": listed,
                               "enemies": enemies.map { [$0.record, $0.object, $0.enemyId, $0.flags] }])
        }
        return try JSONSerialization.data(withJSONObject: ["fields": frameFields, "durations": durations, "formations": formations],
                                          options: [.sortedKeys])
    }
}
