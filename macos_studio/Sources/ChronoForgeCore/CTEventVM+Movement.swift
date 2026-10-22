// CTEventVM+Movement.swift — the movement opcodes ($92 WalkDir, $9C MoveDir,
// $96 WalkToTile, $A0 MoveToTile) and the routines they share, as the ROM has
// them: Obj_CalcDirection (Rom_AngleTable), Obj_SetVelocityChecked (the
// Rom_SineTable256 step, the probe of the tile it leads to, the random turn
// off a blocked tile), Evt_FindSolidObjInFront, Obj_Unk305D (centring on a
// tile), Obj_SetMoveAnim and Obj_SetStandAnim. The step itself (Obj_PosX/Y +=
// Obj_VelX/Y while Obj_MoveFrames counts down) is the field's, not an opcode's.
import Foundation

extension CTEventVM {
    static let dirToFacing = 0x00F700, sineTable = 0x00F800, angleTable = 0x00F300, randomTable = 0x00FE00
    static let objDirection = WRAM.dpField + 0xEE

    var direction: Int {
        get { Int(wram[Self.objDirection]) }
        set { wram[Self.objDirection] = UInt8(newValue & 0xFF) }
    }

    /// Obj_CalcDirection from (fromX, fromY) to (toX, toY), tiles: Obj_Direction, 256 steps a turn.
    func calcDirection(fromX: UInt8, fromY: UInt8, toX: UInt8, toY: UInt8) {
        wram[0x7E01F0] = fromX; wram[0x7E01F1] = fromY; wram[0x7E01F2] = toX; wram[0x7E01F3] = toY
        wram[Self.objDirection + 1] = 0
        var rise: UInt8, run: UInt8, base: Int
        if toY >= fromY {
            if toX >= fromX { rise = toY &- fromY; run = toX &- fromX; base = 0 }
            else { run = toY &- fromY; rise = fromX &- toX; base = 0x40 }
        } else {
            if toX >= fromX { run = fromY &- toY; rise = toX &- fromX; base = 0xC0 }
            else { rise = fromY &- toY; run = fromX &- toX; base = 0x80 }
        }
        wram[0x7E01F7] = rise; wram[0x7E01F6] = run
        let r = Int(run), s = Int(rise), index: Int
        if r & 0x40 != 0 || s & 0x40 != 0 {
            let runPart: Int = (r & 0x7F) >> 2
            index = runPart | (s & 0x7C) << 3
        } else if r & 0x20 != 0 || s & 0x20 != 0 {
            let runPart: Int = (r & 0x3F) >> 1
            index = runPart | (s & 0x3E) << 4
        } else {
            index = (r & 0x1F) | (s & 0x1F) << 5
        }
        direction = base + Int(read(Self.angleTable + index))
    }

    /// One axis of the step: the high byte of speed x |sine|, with the sine's sign.
    func velocityPart(speed: UInt8, angle: Int) -> UInt8 {
        let a = angle & 0xFF, s = read(Self.sineTable + a)
        if a < 0x80 {
            let product: Int = Int(speed) * Int(s)
            return UInt8(product >> 8)
        }
        let product: Int = Int(speed) * Int(0 &- s)
        let magnitude = UInt8(product >> 8)
        return 0 &- magnitude
    }

    /// Obj_SetVelocityChecked: Obj_VelX/Y (low bytes) from Obj_Speed and
    /// Obj_Direction, and the tile priorities of the tile the step leads to.
    /// When that tile blocks (Obj_Unk1C80 bit 0, Map_TileAttrB bit 7) it turns
    /// once to a random direction (RandomTable); blocked again, it stands still.
    func setVelocityChecked() {
        let c = Int(wram[WRAM.objCur])
        wram[WRAM.objVelX + c] = 0
        wram[WRAM.objVelY + c] = 0
        let speed = wram[WRAM.objSpeed + c]
        var retried = false
        while true {
            let vy = velocityPart(speed: speed, angle: direction)
            let vx = velocityPart(speed: speed, angle: direction + 0x40)
            wram[0x7E01DB] = vy; wram[0x7E01DD] = vx
            if vx == 0 && vy == 0 { return }                           // .store with 0, 0
            let xHi: Int = vx & 0x80 != 0 ? 0xFF00 : 0
            let yHi: Int = vy & 0x80 != 0 ? 0xFF00 : 0
            let newX = (wram.word(WRAM.objPosX + c) + (xHi | Int(vx))) & 0xFFFF
            let newY = (wram.word(WRAM.objPosY + c) + (yHi | Int(vy))) & 0xFFFF
            wram.setWord(0x7E01DF, newX)
            let tile = (newY & 0xFF00 | newX >> 8) & wram.word(0x7E1D1E)      // Map_ColMask1
            let attrA = wram[0x7E7000 + tile], attrB = wram[0x7E7040 + tile]
            wram[0x7E01E1] = attrA; wram[0x7E01E5] = attrB
            if attrB & 0x80 != 0, retried || wram[WRAM.objUnk1C80 + c] & 0x01 != 0 {
                if retried {                                           // .stop
                    wram[0x7E01DB] = 0; wram[0x7E01DD] = 0
                    wram[WRAM.objVelX + c] = 0
                    wram[WRAM.objVelY + c] = 0
                    return
                }
                let k = WRAM.dpField + 0xF8                            // Field_Unk0400Copy
                wram[k] &+= 1
                direction = Int(read(Self.randomTable + Int(wram[k])))
                retried = true
                continue
            }
            let flags = wram[WRAM.objOamFlags + c]
            if flags & 0x80 != 0 {
                wram[WRAM.objPrioHigh + c] = (attrB & 0x40) >> 2 | 0x20
                wram[WRAM.objPrioLow + c] = (attrA & 0x40) >> 2 | 0x20
            } else {
                wram[0x7E01D9] = flags
                wram[WRAM.objPrioHigh + c] = flags & 0x30
                wram[WRAM.objPrioLow + c] = (flags << 4) & 0x30
            }
            wram[WRAM.objVelX + c] = vx
            wram[WRAM.objVelY + c] = vy
            return
        }
    }

    /// Obj_SetMoveAnim: row 0/1/6 (stand/walk/run) by |Obj_VelX| + |Obj_VelY|, in animation mode 0.
    func setMoveAnim() {
        let c = Int(wram[WRAM.objCur])
        let mode = wram[WRAM.objAnimMode + c]
        if mode == 3 {
            if wram[WRAM.objAnimRow + c] != 0xFF { wram[WRAM.objAnimMode + c] = 1; return }
            wram[WRAM.objAnimMode + c] = 0
        } else if mode != 0 {
            return
        }
        let vx = wram[WRAM.objVelX + c], vy = wram[WRAM.objVelY + c]
        let ax = vx & 0x80 != 0 ? 0 &- vx : vx, ay = vy & 0x80 != 0 ? 0 &- vy : vy
        wram[0x7E01D9] = ax
        let sum = ax &+ ay
        let row: UInt8 = sum == 0 ? 0 : sum < 0x20 ? 1 : wram[WRAM.objUnk1100 + c] >= 4 ? 1 : 6
        setAnimRow(c, row)
    }

    /// Obj_SetStandAnim.
    func setStandAnim() {
        let c = Int(wram[WRAM.objCur])
        if wram[WRAM.objAnimMode + c] == 0 { setAnimRow(c, 0) }
    }

    func setAnimRow(_ c: Int, _ row: UInt8) {
        if wram[WRAM.objAnimRow + c] == row { return }
        wram[WRAM.objAnimRow + c] = row
        wram[WRAM.objAnimColumn + c] = 0
        wram[WRAM.objAnimTimer + c] = 0
    }

    /// Obj_Unk305D: a $10 step toward X $80 / Y $F0 within the tile; false when already there.
    func centreOnTile() -> Bool {
        let c = objCur
        wram[WRAM.objVelX + c] = 0
        wram[WRAM.objVelY + c] = 0
        let px = wram[WRAM.objPosX + c] & 0xF0, py = wram[WRAM.objPosY + c] & 0xF0
        if px == 0x80 && py == 0xF0 { return false }
        if px != 0x80 { wram[WRAM.objVelX + c] = px > 0x80 ? 0xF0 : 0x10 }
        if py != 0xF0 { wram[WRAM.objVelY + c] = py > 0xF0 ? 0xF0 : 0x10 }
        wram[WRAM.objMoveFrames + c] = 1
        return true
    }

    /// Evt_FindSolidObjInFront: a solid, queued object within a tile in front of Obj_Cur (by its facing).
    func findSolidObjectInFront(y: Int) -> Bool {
        wram[0x7E01EA] = 0
        let c = objCur
        if wram[WRAM.objUnk0F00 + c] == 0 || wram[WRAM.objUnk1C80 + c] & 0x02 == 0 { return false }
        wram.setWord(WRAM.evtOpSavedPos, y)
        let facing2 = Int(wram[WRAM.objFacing + c] << 1)
        wram[0x7E01D9] = UInt8(facing2 & 0xFF)
        let fx = wram.word(WRAM.objPosX + c), fy = wram.word(WRAM.objPosY + c)
        wram.setWord(0x7E01DB, fx); wram.setWord(0x7E01DD, fy)
        let cur8 = wram[WRAM.objCur]
        var x = Int(wram[WRAM.evtObjCount] << 1)
        while true {
            if wram[WRAM.objUnk0F00 + x] != 0, wram[WRAM.objUnk1100 + x] & 0x80 == 0, UInt8(x) != cur8,
               wram[WRAM.objUnk1B01 + x] & 0x01 != 0 {
                wram[0x7E01E9] = UInt8(x)
                let borrow = UInt8(x) < cur8 ? 1 : 0                // the carry CPX Obj_Cur left
                if inFront(facing2: facing2, other: x, fx: fx, fy: fy, borrow: borrow) { return true }
            }
            x = (x - 2) & 0xFF
            if x == 0 { return false }
        }
    }

    /// Evt_InFrontUp/Down/Left/Right (through Evt_InFrontTests): the first SBC
    /// borrows by the carry left before the call, the second after a CMP that
    /// held (C=0) borrows one more.
    func inFront(facing2: Int, other x: Int, fx: Int, fy: Int, borrow: Int) -> Bool {
        let ox = wram.word(WRAM.objPosX + x), oy = wram.word(WRAM.objPosY + x)
        let alongY = facing2 < 4
        let (along, from, across, acrossFrom) = alongY ? (oy, fy, ox, fx) : (ox, fx, oy, fy)
        var d = (along - from - borrow) & 0xFFFF
        let negativeWanted = facing2 == 0 || facing2 == 4            // up, left
        if negativeWanted {
            if d & 0x8000 == 0 { return false }
            d ^= 0xFFFF
        } else if d & 0x8000 != 0 {
            return false
        }
        if d >= 0x100 { return false }
        var e = (across - acrossFrom - 1) & 0xFFFF
        if e & 0x8000 != 0 { e ^= 0xFFFF }
        return e < 0x100
    }

    func dirToFacing(_ d: Int) -> UInt8 { read(Self.dirToFacing + (d & 0xFF)) }

    /// Evt_Op92_WalkDir and Evt_Op9C_MoveDir.
    func walkDirection(_ y: Int, animate: Bool) -> Outcome {
        let c = objCur
        if wram[WRAM.objUnk1A80 + c] != 0 {
            if wram[WRAM.objMoveFrames + c] != 0 { return .go(x: y, carry: false) }
            wram[WRAM.objUnk1A80 + c] = 0
            if animate { setStandAnim() }
            return .go(x: y + 3, carry: true)
        }
        wram.setWord(Self.objDirection, data(y + 1))
        if animate { wram[WRAM.objFacing + c] = dirToFacing(direction) }
        if !animate { wram[WRAM.objMoveFrames + c] = UInt8(data(y + 2)) }
        wram[WRAM.objXUnk7F0B00 + c] = 0x80                           // ObjX_Unk7F0B00Dir
        if animate { wram[WRAM.objMoveFrames + c] = UInt8(data(y + 2)) }
        wram[WRAM.objUnk1A80 + c] &+= 1
        wram.setWord(WRAM.evtOpSavedPos, y)
        setVelocityChecked()
        if animate { setMoveAnim() }
        return .go(x: y, carry: false)
    }

    /// Evt_Op96_WalkToTile and Evt_OpA0_MoveToTile.
    func walkToTile(_ y: Int, animate: Bool) -> Outcome {
        let c = objCur
        if wram[WRAM.objMoveFrames + c] != 0 { return .go(x: y, carry: false) }
        let toX = UInt8(data(y + 1)), toY = UInt8(data(y + 2))
        let fromX = wram[WRAM.objTileX + c], fromY = wram[WRAM.objTileY + c]
        wram[0x7E01F2] = toX; wram[0x7E01F3] = toY; wram[0x7E01F0] = fromX; wram[0x7E01F1] = fromY
        if fromX == toX && fromY == toY {
            if wram[WRAM.objUnk1C81 + c] & 0x01 != 0, centreOnTile() {
                if animate { setMoveAnim() }
                return .go(x: y, carry: false)
            }
            if animate { setStandAnim() }
            return .go(x: y + 3, carry: true)
        }
        calcDirection(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
        if animate { wram[WRAM.objFacing + c] = dirToFacing(direction) }
        if findSolidObjectInFront(y: y) {
            direction += 0x30                                         // Evt_BlockedTurn
            if animate { wram[WRAM.objFacing + c] = dirToFacing(direction) }
        }
        let period = wram[WRAM.objUnk1000 + c]
        wram[WRAM.objMoveFrames + c] = period
        wram[WRAM.objXUnk7F0B00 + c] = period
        wram.setWord(WRAM.evtOpSavedPos, y)
        setVelocityChecked()
        if animate { setMoveAnim() }
        return .go(x: y, carry: false)
    }

    /// Obj_Unk30B3: a $10 step onto the object in ObjFront_Other (its Obj_PosX/Y on the $10 grid); false when there.
    func stepOntoObject(_ other: Int) -> Bool {
        let c = objCur
        wram[WRAM.objVelX + c] = 0
        wram[WRAM.objVelY + c] = 0
        let cx = wram.word(WRAM.objPosX + c) & 0xFFF0, ox = wram.word(WRAM.objPosX + other) & 0xFFF0
        let cy = wram.word(WRAM.objPosY + c) & 0xFFF0, oy = wram.word(WRAM.objPosY + other) & 0xFFF0
        if cx == ox && cy == oy { return false }
        if cx != ox { wram[WRAM.objVelX + c] = ox > cx ? 0x10 : 0xF0 }
        if cy != oy { wram[WRAM.objVelY + c] = oy > cy ? 0x10 : 0xF0 }
        wram[WRAM.objMoveFrames + c] = 1
        wram[WRAM.objXUnk7F0B00 + c] = 1
        return true
    }

    /// One step toward a tile: Obj_CalcDirection, the facing, Evt_BlockedTurn
    /// when a solid object is in front, then Obj_Unk1000 frames at the new velocity.
    func stepToward(_ y: Int, fromX: UInt8, fromY: UInt8, toX: UInt8, toY: UInt8) -> Outcome {
        let c = objCur
        calcDirection(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
        wram[WRAM.objFacing + c] = dirToFacing(direction)
        if findSolidObjectInFront(y: y) {
            direction += 0x30
            wram[WRAM.objFacing + c] = dirToFacing(direction)
        }
        let period = wram[WRAM.objUnk1000 + c]
        wram[WRAM.objMoveFrames + c] = period
        wram[WRAM.objXUnk7F0B00 + c] = period
        wram.setWord(WRAM.evtOpSavedPos, y)
        setVelocityChecked()
        setMoveAnim()
        return .go(x: y, carry: false)
    }

    /// Within one tile on both axes (8-bit, so 0 and $FF are neighbours).
    func near(_ a: UInt8, _ b: UInt8) -> Bool { a == b || a &+ 1 == b || a &- 1 == b }

    /// Evt_Op94_WalkToObj / Evt_Op95_WalkToPc through Evt_Op94_Body (target slot `t`).
    func walkToObject(_ y: Int, target t: Int) -> Outcome {
        let c = objCur
        if wram[WRAM.objUnk1100 + t] & 0x80 == 0 {
            let toX = wram[WRAM.objTileX + t], toY = wram[WRAM.objTileY + t]
            wram.setWord(0x7E01E9, t)                                  // ObjFront_Other
            let fromX = wram[WRAM.objTileX + c], fromY = wram[WRAM.objTileY + c]
            wram[0x7E01F2] = toX; wram[0x7E01F3] = toY; wram[0x7E01F0] = fromX; wram[0x7E01F1] = fromY
            if !(near(fromY, toY) && near(fromX, toX)) {
                return stepToward(y, fromX: fromX, fromY: fromY, toX: toX, toY: toY)
            }
            if wram[WRAM.objUnk1C81 + c] & 0x02 != 0, stepOntoObject(t) {   // Obj1C81_OntoObj
                setMoveAnim()
                return .go(x: y, carry: false)
            }
        }
        setStandAnim()
        return .go(x: y + 2, carry: true)
    }

    /// Evt_Op8F_FollowPc: toward a party member until next to it or well inside the screen.
    func followPartyMember(_ y: Int) -> Outcome {
        let c = objCur
        if wram[WRAM.objMoveFrames + c] != 0 { return .go(x: y, carry: false) }
        let t = Int(wram[WRAM.partyObjSlot + data(y + 1)])
        if wram[WRAM.objUnk1100 + t] & 0x80 == 0 {
            let toX = wram[WRAM.objTileX + t], toY = wram[WRAM.objTileY + t]
            wram.setWord(0x7E01E9, t)
            let fromX = wram[WRAM.objTileX + c], fromY = wram[WRAM.objTileY + c]
            wram[0x7E01F2] = toX; wram[0x7E01F3] = toY; wram[0x7E01F0] = fromX; wram[0x7E01F1] = fromY
            if !(near(fromY, toY) && near(fromX, toX)) {
                let col = wram[0x7E1D0A] >> 1, row = wram[0x7E1D0E] >> 1     // Map_TileOriginX/Y / 2
                wram[0x7E01DB] = col; wram[0x7E01DD] = row
                let dx = fromX &- col, dy = fromY &- row
                if dx <= 1 || dx >= 0x0E || dy <= 1 || dy >= 0x0D {
                    return stepToward(y, fromX: fromX, fromY: fromY, toX: toX, toY: toY)
                }
            }
        }
        setStandAnim()
        return .go(x: y + 2, carry: true)
    }

    /// Evt_OpA8_FaceObj / Evt_OpA9_FacePc through Evt_OpA8_Body.
    func faceObject(_ y: Int, target t: Int) -> Outcome {
        if wram[WRAM.objUnk1100 + t] & 0x80 != 0 { return .go(x: y + 2, carry: true) }
        let c = objCur
        var toX = wram[WRAM.objTileX + t], toY = wram[WRAM.objTileY + t]
        wram.setWord(0x7E01D9, t)                                      // EvtFace_Target
        var fromX = wram[WRAM.objTileX + c], fromY = wram[WRAM.objTileY + c]
        if fromX == toX && fromY == toY {                              // the same tile: the positions within it
            fromX = wram[WRAM.objPosX + c]; fromY = wram[WRAM.objPosY + c]
            toX = wram[WRAM.objPosX + t]; toY = wram[WRAM.objPosY + t]
        }
        calcDirection(fromX: fromX, fromY: fromY, toX: toX, toY: toY)
        wram[WRAM.objFacing + c] = dirToFacing(direction)
        wram[WRAM.objAnimTimer + c] = 0
        return .go(x: y + 2, carry: false)
    }
}
