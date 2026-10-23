// CTFieldProbes.swift — the leader's collision as the ROM runs it, on the
// map page ($1D00) like the camera (CTFieldScroll.swift):
//
//   Map_Unk8A6D          ($C0:8A6D) the frame's step against the leader's box:
//                                   the object in the way, the corners of the
//                                   moved box, the slides around a corner,
//                                   the diagonal cases
//   Map_ProbeHitsObj     ($C0:9923) an object near the probe (Field_UnkEB)
//   Map_ProbeTileAttrs   ($C0:9AA1) the probed tile's bytes (a treasure blocks)
//   Map_ProbeTileLevel   ($C0:9AD3) the half of the tile the probe is in, its level
//   Map_ProbeLevelBlocked ($C0:9C37) that level against Field_Unk55
//   Map_StepTileEffects  ($C0:9C5C) the commit: exits (ExitRom, bank $E5), the
//                                   tile-animation request, level, priority, push
//   Map_InitEntryTile    ($C0:9DC3) the entry tile's level at a location load
//
// The arithmetic keeps the ROM's carries (an ADC after an SBC with no CLC
// lands a probe one unit over; Map_ProbeHitsObj's differences can come out
// one smaller) and its index widths: after a probe the leader's slot is
// read 8- or 16-bit as the last callee left X.
import Foundation

extension WRAM {
    public static let mapExitRec0 = 0x7E1D04
    public static let mapUnk1D2EHi = 0x7E1D2F, mapUnk1D30Hi = 0x7E1D31
    public static let mapPushSpeed = 0x7E1D52, mapSlopeTest = 0x7E1D54, mapProbeFracY4 = 0x7E1D56
    public static let mapProbeHiBits = 0x7E1D58, mapProbeAttrA = 0x7E1D5A, mapProbeAttrB = 0x7E1D5C
    public static let mapProbeMoveFlags = 0x7E1D5E, mapProbeShape = 0x7E1D60
    public static let mapLeaderX = 0x7E1D62, mapLeaderY = 0x7E1D64
    public static let mapProbeX = 0x7E1D66, mapProbeTileX = 0x7E1D67, mapProbeY = 0x7E1D68, mapProbeTileY = 0x7E1D69
    public static let mapProbeLevel = 0x7E1D6A, mapProbeNoLevel = 0x7E1D6C
    public static let mapProbePrio = 0x7E1D6E, mapProbePrioHi = 0x7E1D6F
    public static let mapDestX = 0x7E1D70, mapDestTileX = 0x7E1D71, mapNextRowY = 0x7E1D72, mapNextRowTileY = 0x7E1D73
    public static let fieldTileAnimX = dpField + 0x5B, fieldTileAnimY = dpField + 0x5C
    public static let fieldUnkAB16 = dpField + 0xAB
}

extension CTEventVM {
    static let boxHalfW = 0x70, boxMidY = 0x40, boxHeight = 0x70

    /// 16-bit ADC / SBC with the carry they take and leave.
    private func adc(_ a: Int, _ b: Int, _ c: inout Bool) -> Int {
        let r = a + b + (c ? 1 : 0)
        c = r > 0xFFFF
        return r & 0xFFFF
    }

    private func sbc(_ a: Int, _ b: Int, _ c: inout Bool) -> Int {
        let r = a - b - (c ? 0 : 1)
        c = r >= 0
        return r & 0xFFFF
    }

    private func word(_ a: Int) -> Int { wram.word(a) }
    private func setWord(_ a: Int, _ v: Int) { wram.setWord(a, v & 0xFFFF) }

    // MARK: Map_ProbeHitsObj

    /// Map_ProbeHitsObj: the highest slot (from Evt_ObjCount x 2 down to 2,
    /// 8-bit) with Obj_Unk0F00 set, Obj_Unk1100 bit 7 clear and not a party
    /// member whose position is within $E0 of Map_ProbeX/Y both ways; C=1
    /// when it is solid. The differences take the carry the CPX / CMP left.
    func probeHitsObj() -> Bool {
        setWord(WRAM.fieldUnkEB, 0x0080)
        var x = Int(wram[WRAM.evtObjCount] << 1)
        let party = [WRAM.partyObjSlot, WRAM.partyObjSlot1, WRAM.partyObjSlot2].map { Int(wram[$0]) }
        let px = word(WRAM.mapProbeX), py = word(WRAM.mapProbeY)
        repeat {
            if wram[WRAM.objUnk0F00 + x] != 0, wram[WRAM.objUnk1100 + x] & 0x80 == 0, !party.contains(x) {
                var c = x >= party[2]                                     // the last CPX
                let solid = wram[WRAM.objUnk1B01 + x] & 0x01 != 0
                wram[WRAM.fieldUnkEB] = UInt8(x)
                if near(sbc(word(WRAM.objPosY + x), py, &c)) {
                    c = false                                             // the CMP's
                    if near(sbc(word(WRAM.objPosX + x), px, &c)) { return solid }
                }
            }
            x = (x - 2) & 0xFF
        } while x != 0
        wram[WRAM.fieldUnkEB] = 0x80
        return false
    }

    /// Below Map_ObjNear ($E0) as a signed 16-bit difference.
    private func near(_ d: Int) -> Bool {
        let m = d & 0x8000 != 0 ? (0x10000 - d) & 0xFFFF : d
        return m < 0xE0
    }

    // MARK: The tile probes

    /// Map_ProbeTileAttrs (`treasure` true) / Map_ProbeTileAttrsAny: the
    /// tile row << 8 | column masked with Map_ColMask1/RowMask1; C=1 (true)
    /// on a treasure tile, nothing read.
    func probeTileAttrs(_ rowColumn: Int, treasure: Bool) -> Bool {
        let i = rowColumn & word(WRAM.mapColMask1)
        if treasure, wram[WRAM.mapTreasureIdx + i] & 0x80 == 0 { return true }
        wram[WRAM.mapProbeHiBits] = wram[WRAM.mapTileHiBits + i]
        wram[WRAM.mapProbeAttrA] = wram[WRAM.mapTileAttrA + i]
        wram[WRAM.mapProbeAttrB] = wram[WRAM.mapTileAttrB + i]
        return false
    }

    /// Map_ProbeTileLevel: the half of the tile Map_ProbeX/Y's fractions
    /// fall in (the slope tables Map_SlopeShift/Base/Side at $C0:9BF5 read
    /// from the ROM), its level, "no level" bit and OAM priorities; shape
    /// $1E cuts a nonzero Map_Unk1D30 to ±$10.
    func probeTileLevel() {
        for a in [WRAM.mapProbeMoveFlags, WRAM.mapProbeShape, WRAM.mapProbeLevel, WRAM.mapProbeNoLevel, WRAM.mapProbePrio] {
            wram[a] = 0
        }
        let x = wram[WRAM.mapProbeX], y = wram[WRAM.mapProbeY]
        wram[WRAM.mapProbeFracY4] = y >> 2
        let shape = (wram[WRAM.mapProbeHiBits] & 0xFC) >> 2
        var halfB = false
        if shape == 1 {
            halfB = true
        } else if shape >= 2 {
            let s = shape - 2
            wram[WRAM.mapProbeShape] = s
            if s < 0x16 {
                let shift = rom.count > 0x009C36 ? rom[0x009BF5 + Int(s)] : 0x01
                let n = Int(shift & 0x7F)                                 // LSR / DEY / BNE: 0 runs 256 times
                var v = n == 0 || n > 7 ? 0 : x >> n
                if shift & 0x80 != 0 { v ^= 0xFF }
                wram[WRAM.mapSlopeTest] = v
                let base = rom.count > 0x009C36 ? rom[0x009C0B + Int(s)] : 0
                let side = rom.count > 0x009C36 ? rom[0x009C21 + Int(s)] : 0
                let t = base &+ v &- wram[WRAM.mapProbeFracY4]
                wram[WRAM.mapSlopeTest] = t
                halfB = (side ^ t) & 0x80 != 0
            } else {
                let xLeft = x & 0x80 == 0, yTop = y & 0x80 == 0
                switch s {
                case 0x16: halfB = xLeft
                case 0x17: halfB = yTop
                case 0x18: halfB = xLeft && !yTop
                case 0x19: halfB = !xLeft && !yTop
                case 0x1A: halfB = !xLeft && yTop
                case 0x1B: halfB = xLeft && yTop
                case 0x1C:
                    wram[WRAM.mapProbeMoveFlags] = 0x04
                    let sy = wram[WRAM.mapUnk1D30]
                    if sy != 0 { wram[WRAM.mapUnk1D30] = sy & 0x80 != 0 ? Self.stepNeg : Self.stepPos }
                default: break
                }
            }
        }
        let a = wram[WRAM.mapProbeAttrA], b = wram[WRAM.mapProbeAttrB]
        if halfB {
            wram[WRAM.mapProbeLevel] = (b & 0x18) >> 3; wram[WRAM.mapProbeNoLevel] = b & 0x20
        } else {
            wram[WRAM.mapProbeLevel] = b & 0x03; wram[WRAM.mapProbeNoLevel] = b & 0x04
        }
        wram[WRAM.mapProbePrio] = (a >> 2) & 0x10 | 0x20
        wram[WRAM.mapProbePrioHi] = (b >> 2) & 0x10 | 0x20
    }

    /// Map_ProbeLevelBlocked against Field_Unk55 (3: any level).
    func probeLevelBlocked() -> Bool {
        let cur = wram[WRAM.fieldUnk55]
        if wram[WRAM.mapProbeNoLevel] != 0 { return cur == 3 }
        let level = wram[WRAM.mapProbeLevel]
        if level == 0 { return true }
        return !(level == 3 || level == cur || cur == 3)
    }

    /// Map_Unk8A6D's .test_probe: (C, a treasure).
    private func testProbe(_ wide: inout Bool) -> (blocked: Bool, chest: Bool) {
        let at = word(WRAM.mapProbeY) & 0xFF00 | Int(wram[WRAM.mapProbeTileX])
        if probeTileAttrs(at, treasure: true) { wide = true; return (true, true) }
        wide = false
        probeTileLevel()
        return (probeLevelBlocked(), false)
    }

    // MARK: Map_StepTileEffects

    /// Map_StepTileEffects: the leader's new point (Map_LeaderX/Y plus the
    /// steps); a blocked tile stops both steps; else the exit test (unless a
    /// warp is pending), the tile-animation tile one row on, the level and
    /// priorities, and the push.
    func stepTileEffects() {
        var c = false
        let px = adc(word(WRAM.mapLeaderX), word(WRAM.mapUnk1D2E), &c)
        setWord(WRAM.mapProbeX, px); setWord(WRAM.mapDestX, px)
        c = false
        let py = adc(word(WRAM.mapLeaderY), word(WRAM.mapUnk1D30), &c)
        setWord(WRAM.mapProbeY, py)
        setWord(WRAM.mapNextRowY, word(WRAM.mapUnk1D30) & 0x80 != 0 ? py - 0x100 : py + 0x100)
        _ = probeTileAttrs(py & 0xFF00 | px >> 8, treasure: false)
        probeTileLevel()
        if probeLevelBlocked() { setWord(WRAM.mapUnk1D2E, 0); setWord(WRAM.mapUnk1D30, 0); return }
        var wide = false
        if wram[WRAM.fieldSceneFlags] & 0x80 == 0 {
            wide = true
            let ty = wram[WRAM.mapProbeTileY], tx = wram[WRAM.mapProbeTileX]
            let i = Int(ty & wram[WRAM.mapRowMask1]) << 8 | Int(tx & wram[WRAM.mapColMask1])
            let idx = wram[WRAM.mapTileExitIdx + i]
            if idx & 0x80 == 0, let rec = exitRecord(Int(idx)) { exitTest(rec, tx: tx, ty: ty) }
        }
        var i = Int(wram[WRAM.mapNextRowTileY] & wram[WRAM.mapRowMask1]) << 8 | Int(wram[WRAM.mapDestTileX] & wram[WRAM.mapColMask1])
        if !wide { i &= 0xFF }                                          // 8-bit X after a pending warp (quirk)
        if wram[WRAM.mapTileAttrA + i] & 0x10 != 0 {
            wram[WRAM.fieldTileAnimX] = UInt8(i & 0xFF)
            if wide { wram[WRAM.fieldTileAnimY] = UInt8(i >> 8) }
            wram[WRAM.fieldSceneFlags] |= 0x10
        }
        if wram[WRAM.mapProbeNoLevel] == 0 {
            wram[WRAM.fieldUnk55] = wram[WRAM.mapProbeLevel]
            let leader = Int(wram[WRAM.partyObjSlot])
            wram[WRAM.objPrioLow + leader] = wram[WRAM.mapProbePrio]
            wram[WRAM.objPrioHigh + leader] = wram[WRAM.mapProbePrioHi]
        }
        wram[WRAM.mapUnk1D34] = wram[WRAM.mapProbeMoveFlags]
        let a = wram[WRAM.mapProbeAttrA]
        let speed: UInt8
        switch a & 0x0C {
        case 0: wram[WRAM.mapUnk1D2A] = 0; wram[WRAM.mapUnk1D2B] = 0; return
        case 0x04: speed = 0x08
        case 0x08: speed = 0x10
        default: speed = 0x20
        }
        wram[WRAM.mapPushSpeed] = speed
        wram[WRAM.mapUnk1D34] |= 0x08
        switch a & 3 {
        case 0: wram[WRAM.mapUnk1D2B] = 0 &- speed; wram[WRAM.mapUnk1D2A] = 0
        case 1: wram[WRAM.mapUnk1D2B] = speed; wram[WRAM.mapUnk1D2A] = 0
        case 2: wram[WRAM.mapUnk1D2A] = 0 &- speed; wram[WRAM.mapUnk1D2B] = 0
        default: wram[WRAM.mapUnk1D2A] = speed; wram[WRAM.mapUnk1D2B] = 0
        }
    }

    /// Exit record `idx`: `exitRecords` (none past their end), else the
    /// ExitRom record (bank $E5) at Map_ExitRec0 + idx x 7.
    private func exitRecord(_ idx: Int) -> [UInt8]? {
        if let records = exitRecords { return idx < records.count && records[idx].count >= 7 ? records[idx] : nil }
        let rec = 0x250000 + ((idx * 7 + word(WRAM.mapExitRec0)) & 0xFFFF)
        return rom.count > rec + 6 ? Array(rom[rec..<rec + 7]) : nil
    }

    /// The probed tile against its exit record: its column with a row less
    /// than $3F away, or its row; then Loc_Dest* and SceneFlag_Warp.
    private func exitTest(_ rec: [UInt8], tx: UInt8, ty: UInt8) {
        if rec[0] == tx {
            let d = rec[1] &- ty
            let dist = d & 0x80 != 0 ? 0 &- d : d
            guard dist < 0x3F else { return }
        } else {
            guard rec[1] == ty else { return }
        }
        let hf = rec[4]
        wram[WRAM.mapPushSpeed] = hf                                     // Map_ExitScratch
        wram[WRAM.locDestFacing] = (hf >> 1) & 0x0F | hf & 0x80
        wram[WRAM.locDestId + 1] = hf & 0x01
        wram[WRAM.locDestId] = rec[3]
        wram[WRAM.locDestX] = rec[5]; wram[WRAM.locDestX + 1] = rec[6]
        wram[WRAM.fieldSceneFlags] |= 0x80
    }

    // MARK: Map_InitEntryTile

    /// Map_InitEntryTile: Field_UnkAB-AD and four ObjX bytes cleared; the
    /// entry tile probed at its bottom middle; Field_Unk55 = its level (1
    /// for 0), the leader's priorities, the followers' both Map_ProbePrioHi;
    /// Map_Unk1D34 = the probe's move flags.
    public func initEntryTile() {
        for a in [WRAM.fieldUnkAB16, WRAM.fieldUnkAB16 + 1, WRAM.fieldUnkAB16 + 2,
                  0x7F0C00, 0x7F0C80, 0x7F0D00, 0x7F0D80] { wram[a] = 0 }
        _ = probeTileAttrs(word(WRAM.locEntryX), treasure: false)
        wram[WRAM.mapProbeX] = 0x80; wram[WRAM.mapProbeY] = 0xFF
        probeTileLevel()
        let level = wram[WRAM.mapProbeLevel]
        wram[WRAM.fieldUnk55] = level == 0 ? 1 : level
        let leader = Int(wram[WRAM.partyObjSlot]), hi = wram[WRAM.mapProbePrioHi]
        wram[WRAM.objPrioLow + leader] = wram[WRAM.mapProbePrio]; wram[WRAM.objPrioHigh + leader] = hi
        for s in [WRAM.partyObjSlot1, WRAM.partyObjSlot2] {
            let slot = Int(wram[s])
            wram[WRAM.objPrioLow + slot] = hi; wram[WRAM.objPrioHigh + slot] = hi
        }
        wram[WRAM.mapUnk1D34] = wram[WRAM.mapProbeMoveFlags]
    }

    // MARK: Map_Unk8A6D

    /// Map_Unk8A6D: the frame's steps (Map_Unk1D2E X, Map_Unk1D30 Y) kept,
    /// cut or turned into a slide by the leader's box (X ±$70, Y up to
    /// -$70) against objects and tiles; a kept step is committed by
    /// Map_StepTileEffects.
    public func leaderProbes() {
        var wide = false
        let sx = wram[WRAM.mapUnk1D2E], sy = wram[WRAM.mapUnk1D30]
        switch (sx == 0 ? 0 : sx & 0x80 != 0 ? -1 : 1, sy == 0 ? 0 : sy & 0x80 != 0 ? -1 : 1) {
        case (0, 0): return
        case (1, 0): right(&wide)
        case (-1, 0): left(&wide)
        case (0, -1): up(&wide)
        case (0, 1): down(&wide)
        case (1, -1): upRight(&wide)
        case (-1, -1): upLeft(&wide)
        case (-1, 1): downLeft(&wide)
        default: downRight(&wide)
        }
    }

    /// The leader's slot as LDX.w reads it: 16-bit after Map_ProbeHitsObj or
    /// a treasure probe, else 8-bit.
    private func leaderSlot(_ wide: Bool) -> Int {
        wide ? word(WRAM.partyObjSlot) : Int(wram[WRAM.partyObjSlot])
    }

    /// Map_LeaderX/Y from the leader's position.
    private func loadLeader(_ wide: Bool) -> (x: Int, y: Int) {
        let s = leaderSlot(wide)
        let lx = word(WRAM.objPosX + s), ly = word(WRAM.objPosY + s)
        setWord(WRAM.mapLeaderX, lx); setWord(WRAM.mapLeaderY, ly)
        return (lx, ly)
    }

    private func hitsObj(_ wide: inout Bool) -> Bool {
        let r = probeHitsObj()
        wide = true
        return r
    }

    private var lx: Int { word(WRAM.mapLeaderX) }
    private var ly: Int { word(WRAM.mapLeaderY) }
    private var stepX: Int { word(WRAM.mapUnk1D2E) }
    private var stepY: Int { word(WRAM.mapUnk1D30) }
    private func probeAt(x: Int? = nil, y: Int? = nil) {
        if let x { setWord(WRAM.mapProbeX, x) }
        if let y { setWord(WRAM.mapProbeY, y) }
    }

    // .right / .left / .side_tiles

    private func right(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D2EHi] = 0; wram[WRAM.mapUnk1D30Hi] = 0
        let l = loadLeader(wide)
        var c = false
        let t = adc(l.x, Self.boxHalfW, &c)
        probeAt(x: adc(t, stepX, &c), y: l.y - Self.boxMidY)
        if hitsObj(&wide) { setWord(WRAM.mapUnk1D2E, 0); return }
        sideTiles(&wide)
    }

    private func left(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D2EHi] = 0xFF; wram[WRAM.mapUnk1D30Hi] = 0
        let l = loadLeader(wide)
        probeAt(x: l.x + stepX - Self.boxHalfW, y: l.y - Self.boxMidY)
        if hitsObj(&wide) { setWord(WRAM.mapUnk1D2E, 0); return }
        sideTiles(&wide)
    }

    private func sideTiles(_ wide: inout Bool) {
        probeAt(y: ly)
        let foot = testProbe(&wide)
        if !foot.blocked {
            probeAt(y: ly - Self.boxHeight)
            if !testProbe(&wide).blocked { stepTileEffects(); return }
            // .side_slide_down: the top corner blocked
            setWord(WRAM.mapUnk1D30, 0x0010)
            probeAt(y: 0x10 + ly)
            if testProbe(&wide).blocked { setWord(WRAM.mapUnk1D2E, 0); setWord(WRAM.mapUnk1D30, 0); return }
            probeAt(y: ly - Self.boxHeight + stepY)
            if !testProbe(&wide).blocked { stepTileEffects(); return }
            // .side_down_only
            probeAt(x: word(WRAM.mapProbeX) - stepX)
            setWord(WRAM.mapUnk1D2E, 0)
            probeAt(y: ly + stepY)
            if !testProbe(&wide).blocked { stepTileEffects(); return }
            setWord(WRAM.mapUnk1D30, 0)
            return
        }
        if foot.chest { setWord(WRAM.mapUnk1D2E, 0); return }
        probeAt(y: ly - Self.boxHeight)
        if testProbe(&wide).blocked { setWord(WRAM.mapUnk1D2E, 0); return }
        // .side_slide_up
        setWord(WRAM.mapUnk1D30, 0xFFF0)
        probeAt(y: 0xFFF0 + ly)
        if !testProbe(&wide).blocked {
            probeAt(y: ly - Self.boxHeight + stepY)                      // .side_up_head
            if !testProbe(&wide).blocked { stepTileEffects(); return }
            setWord(WRAM.mapUnk1D2E, 0); setWord(WRAM.mapUnk1D30, 0)
            return
        }
        // .side_up_only
        probeAt(x: word(WRAM.mapProbeX) - stepX)
        setWord(WRAM.mapUnk1D2E, 0)
        probeAt(y: ly - Self.boxHeight + stepY)
        if !testProbe(&wide).blocked { stepTileEffects(); return }
        setWord(WRAM.mapUnk1D30, 0)
    }

    // .up / .down and their corner slides

    private func up(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D30Hi] = 0xFF; wram[WRAM.mapUnk1D2EHi] = 0
        let l = loadLeader(wide)
        probeAt(x: l.x, y: l.y - Self.boxHeight + stepY)
        if hitsObj(&wide) { wram[WRAM.mapUnk1D30] = 0; wram[WRAM.mapUnk1D30Hi] = 0; return }
        verticalTiles(&wide)
    }

    private func down(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D30Hi] = 0; wram[WRAM.mapUnk1D2EHi] = 0
        let l = loadLeader(wide)
        probeAt(x: l.x, y: l.y + stepY)
        if hitsObj(&wide) { wram[WRAM.mapUnk1D30] = 0; return }
        verticalTiles(&wide)
    }

    /// .up_tiles / .down_tiles (the same code on the probe's Y): the left
    /// corner, then the right; a slide of $10 away from a blocked corner.
    private func verticalTiles(_ wide: inout Bool) {
        probeAt(x: lx - Self.boxHalfW)
        let leftCorner = testProbe(&wide)
        if !leftCorner.blocked {
            probeAt(x: lx + Self.boxHalfW)
            let rightCorner = testProbe(&wide)
            if !rightCorner.blocked { stepTileEffects(); return }
            if rightCorner.chest { setWord(WRAM.mapUnk1D30, 0); return }
            // .up_right_blocked: slide left
            setWord(WRAM.mapUnk1D2E, 0xFFF0)
            var c = false
            let t = adc(0xFFF0, lx, &c)
            probeAt(x: adc(t, Self.boxHalfW, &c))                        // no CLC (quirk)
            if !testProbe(&wide).blocked {
                probeAt(x: lx - Self.boxHalfW + stepX)                   // .up_left_edge
                if !testProbe(&wide).blocked { stepTileEffects(); return }
                setWord(WRAM.mapUnk1D2E, 0); setWord(WRAM.mapUnk1D30, 0)
                return
            }
            sideOnly(&wide, edge: lx - Self.boxHalfW + stepX)            // .up_left_only
            return
        }
        if leftCorner.chest { setWord(WRAM.mapUnk1D30, 0); return }
        probeAt(x: lx + Self.boxHalfW)
        if testProbe(&wide).blocked { setWord(WRAM.mapUnk1D30, 0); return }
        // .up_slide_right
        setWord(WRAM.mapUnk1D2E, 0x0010)
        probeAt(x: 0x10 + lx - Self.boxHalfW)
        if !testProbe(&wide).blocked {
            var c = false                                                // .up_right_edge
            let t = adc(lx, Self.boxHalfW, &c)
            probeAt(x: adc(t, stepX, &c))
            if !testProbe(&wide).blocked { stepTileEffects(); return }
            setWord(WRAM.mapUnk1D2E, 0); setWord(WRAM.mapUnk1D30, 0)
            return
        }
        var c = false                                                    // .up_right_only
        let t = adc(lx, Self.boxHalfW, &c)
        sideOnly(&wide, edge: adc(t, stepX, &c))
    }

    /// .up_right_only / .up_left_only (and the .dn_ ones): the Y step
    /// dropped (taken off the probe), straight sideways if `edge` is free.
    private func sideOnly(_ wide: inout Bool, edge: Int) {
        probeAt(y: word(WRAM.mapProbeY) - stepY)
        setWord(WRAM.mapUnk1D30, 0)
        probeAt(x: edge)
        if !testProbe(&wide).blocked { stepTileEffects(); return }
        setWord(WRAM.mapUnk1D2E, 0)
    }

    // The diagonals: the leading corner, the other corner of the leading Y
    // edge, then the other corner of the leading X edge.

    private func upRight(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D30Hi] = 0xFF; wram[WRAM.mapUnk1D2EHi] = 0
        let l = loadLeader(wide)
        var c = false
        let t = adc(l.x, Self.boxHalfW, &c)
        probeAt(x: adc(t, stepX, &c), y: l.y - Self.boxHeight + stepY)
        if hitsObj(&wide) { setWord(WRAM.mapUnk1D30, 0); setWord(WRAM.mapUnk1D2E, 0); return }
        let lead = testProbe(&wide).blocked
        diagonal(&wide, lead: lead,
                 second: { self.lx - Self.boxHalfW + self.stepX },
                 third: { var c = false; let t = self.adc(self.lx, Self.boxHalfW, &c); return (self.adc(t, self.stepX, &c), self.ly + self.stepY) },
                 keepX: { self.right(&$0) }, keepY: { self.up(&$0) })
    }

    private func upLeft(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D30Hi] = 0xFF; wram[WRAM.mapUnk1D2EHi] = 0xFF
        let l = loadLeader(wide)
        probeAt(x: l.x - Self.boxHalfW + stepX, y: l.y - Self.boxHeight + stepY)
        if hitsObj(&wide) { setWord(WRAM.mapUnk1D30, 0); setWord(WRAM.mapUnk1D2E, 0); return }
        let lead = testProbe(&wide).blocked
        diagonal(&wide, lead: lead,
                 second: { var c = false; let t = self.adc(self.lx, Self.boxHalfW, &c); return self.adc(t, self.stepX, &c) },
                 third: { var c = true; let t = self.sbc(self.lx, Self.boxHalfW, &c); return (self.adc(t, self.stepX, &c), self.ly + self.stepY) },
                 thirdAfterTop: { (self.lx - Self.boxHalfW + self.stepX, self.ly + self.stepY) },
                 keepX: { self.left(&$0) }, keepY: { self.up(&$0) })
    }

    private func downLeft(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D30Hi] = 0; wram[WRAM.mapUnk1D2EHi] = 0xFF
        let l = loadLeader(wide)
        probeAt(x: l.x - Self.boxHalfW + stepX, y: l.y + stepY)
        if hitsObj(&wide) { setWord(WRAM.mapUnk1D30, 0); setWord(WRAM.mapUnk1D2E, 0); return }
        let lead = testProbe(&wide).blocked
        diagonal(&wide, lead: lead,
                 second: { var c = false; let t = self.adc(self.lx, Self.boxHalfW, &c); return self.adc(t, self.stepX, &c) },
                 third: { var c = true; let t = self.sbc(self.lx, Self.boxHalfW, &c); return (self.adc(t, self.stepX, &c), self.ly + self.stepY - Self.boxHeight) },
                 thirdAfterTop: { (self.lx - Self.boxHalfW + self.stepX, self.ly + self.stepY - Self.boxHeight) },
                 keepX: { self.left(&$0) }, keepY: { self.down(&$0) })
    }

    private func downRight(_ wide: inout Bool) {
        wram[WRAM.mapUnk1D30Hi] = 0; wram[WRAM.mapUnk1D2EHi] = 0
        let l = loadLeader(wide)
        probeAt(x: l.x + Self.boxHalfW + stepX, y: l.y + stepY)
        if hitsObj(&wide) { setWord(WRAM.mapUnk1D30, 0); setWord(WRAM.mapUnk1D2E, 0); return }
        let lead = testProbe(&wide).blocked
        diagonal(&wide, lead: lead,
                 second: { var c = true; let t = self.sbc(self.lx, Self.boxHalfW, &c); return self.adc(t, self.stepX, &c) },
                 third: { var c = false; let t = self.adc(self.lx, Self.boxHalfW, &c); return (self.adc(t, self.stepX, &c), self.ly + self.stepY - Self.boxHeight) },
                 thirdAfterTop: { (self.lx + Self.boxHalfW + self.stepX, self.ly + self.stepY - Self.boxHeight) },
                 keepX: { self.right(&$0) }, keepY: { self.down(&$0) })
    }

    /// The shared shape of the four diagonal cases. `second` is the X of the
    /// other corner of the leading Y edge (at the probe's Y); `third` the
    /// other corner of the leading X edge, `thirdAfterTop` the same probe as
    /// the "top / bottom blocked" path computes it (its own carries).
    private func diagonal(_ wide: inout Bool, lead: Bool, second: () -> Int, third: () -> (Int, Int),
                          thirdAfterTop: (() -> (Int, Int))? = nil,
                          keepX: (inout Bool) -> Void, keepY: (inout Bool) -> Void) {
        probeAt(x: second())
        if testProbe(&wide).blocked {
            let (x, y) = thirdAfterTop?() ?? third()
            probeAt(x: x, y: y)
            if testProbe(&wide).blocked { setWord(WRAM.mapUnk1D30, 0); setWord(WRAM.mapUnk1D2E, 0); return }
            setWord(WRAM.mapUnk1D30, 0)
            keepX(&wide)
            return
        }
        let (x, y) = third()
        probeAt(x: x, y: y)
        let thirdBlocked = testProbe(&wide).blocked
        if thirdBlocked { setWord(WRAM.mapUnk1D2E, 0); keepY(&wide); return }
        if lead { setWord(WRAM.mapUnk1D2E, 0); setWord(WRAM.mapUnk1D30, 0); return }
        stepTileEffects()
    }
}
