// CTFieldScroll.swift — the field camera as the ROM moves it, all on the map
// page ($1D00, cleared by LocLoad_ClearPage1D00 when a location loads):
//
//   Map_InitOrigin   ($C0:74A6) the origin for the entry tile, inside the limits
//   Map_Unk9175      ($C0:9175) the leader's steps, kept unless it is at a limit
//   Map_Unk99DE      ($C0:99DE) the camera's steps, dropped at the map's edge and
//                               while the leader is on the near side of the
//                               screen's middle (Map_StepStop*)
//   Map_Unk91AC      ($C0:91AC) $E7's scroll-to, the shake, and the three sets of
//                               1/16-pixel accumulators split into whole pixels
//   Map_Scroll1*     ($C0:944B-$C0:950E) layer 1's scroll words, fine counters
//                               and tile origin, a pixel at a time
//   Field_Unk885A    ($C0:885A) DefaultHandler's step to a 16-pixel boundary
//                               before a map redraw
//
// The camera is the view's top-left: Map_TileOriginX x 8 + (Map_Unk1D87 & 7),
// as Obj_CalcScreenPos reads it (ObjScr_ViewX). The camera moves only by
// the frame's step (the D-pad, a pushing tile, a scroll-to or the
// redraw step), so after `$E7` it stays put until the leader walks past
// the screen's middle. Layers 2 and 3 (Map_Scroll2*, Map_Scroll3*) and the
// edge builders are not run.
import Foundation

extension WRAM {
    public static let mapScrollToMode = 0x7E1D00, mapScrollToDone = 0x7E1D01
    public static let mapScrollToX = 0x7E1D02, mapScrollToY = 0x7E1D03
    public static let mapPage = 0x7E1D00
    /// Map_Drift1X ... Map_Drift3Y: set k, axis a at + 2k + a.
    public static let mapDrift1X = 0x7E1D24
    public static let mapOwnStepFlags = 0x7E1D36, mapOwnStep2X = 0x7E1D37
    /// Map_Acc1X ... Map_Acc3Y (+ 2k + a) and Map_Move1XNeg ... Map_Move3YPos
    /// (+ 4k + 2a, Pos one above Neg).
    public static let mapAcc1X = 0x7E1D3B, mapMove1XNeg = 0x7E1D41
    public static let mapDriftTimer = 0x7E1D4D, mapShakeX = 0x7E1D4E, mapShakeY = 0x7E1D4F
    public static let mapStepTestN = 0x7E1D52, mapStepTestN2 = 0x7E1D54, mapOriginTest = 0x7E1D52
    public static let mapStepCount = 0x7E1D66
    public static let mapEdgeRowYInc = 0x7E1D74, mapEdgeRowYDec = 0x7E1D75
    public static let mapEdgeColXInc = 0x7E1D76, mapEdgeColXDec = 0x7E1D77
    /// Layer 1's scroll words (pixels, 16-bit) and fine counters (0-$0F in a 16-pixel cell).
    public static let mapScroll1X = 0x7E1D87, mapScroll1Y = 0x7E1D89
    public static let mapFine1X = 0x7E1D93, mapFine1Y = 0x7E1D96
    public static let mapUnk1D12 = 0x7E1D12, mapUnk1D14 = 0x7E1D14, mapUnk1D16 = 0x7E1D16, mapUnk1D18 = 0x7E1D18
    public static let mapBgColBias = 0x7E1D99
    public static let mapUnk0BC9 = 0x7E0BC9, engUnk0400 = 0x7E0400
}

extension CTEventVM {
    static let stepPos: UInt8 = 0x10, stepNeg: UInt8 = 0xF0

    /// The camera's top-left in pixels (ObjScr_ViewX/Y).
    public var cameraPixels: (x: Int, y: Int) {
        (wram.word(WRAM.mapTileOriginX) * 8 + Int(wram[WRAM.mapScroll1X] & 7),
         wram.word(WRAM.mapTileOriginY) * 8 + Int(wram[WRAM.mapScroll1Y] & 7))
    }

    // MARK: Map_InitOrigin

    /// Map_InitOrigin without its tail (Sub_C07F9A's edge addresses).
    public func initOrigin() {
        initOriginX(); initOriginY()
        if wram[WRAM.mapUnk0BC9] & 0x80 != 0 {
            let x = (wram[WRAM.mapTileOriginX] >> 1) & 0xFE, y = wram[WRAM.mapTileOriginY] >> 1
            wram[WRAM.mapUnk1D12] = x; wram[WRAM.mapUnk1D14] = x &+ 0x20
            wram[WRAM.mapUnk1D16] = y; wram[WRAM.mapUnk1D18] = y &+ 0x1C
        }
        for i in 0..<6 { wram[WRAM.mapBgColBias + i] = 0 }
    }

    /// Map_InitOriginX: the entry column 8 metatiles from the left edge,
    /// inside Map_Unk1D1A-1D1B; only the low bytes are written.
    func initOriginX() {
        initOrigin(entry: wram[WRAM.locEntryX], low: wram[WRAM.mapLimitLeft], high: wram[WRAM.mapLimitRight],
                   below: 8, span: 0x20, origin: WRAM.mapTileOriginX, bound: WRAM.mapUnk1D0C)
    }

    /// Map_InitOriginY: the entry row 8 metatiles below the top edge, 6 above
    /// the bottom (Map_OriginLeadYBelow), inside Map_Unk1D1C-1D1D.
    func initOriginY() {
        initOrigin(entry: wram[WRAM.locEntryY], low: wram[WRAM.mapLimitTop], high: wram[WRAM.mapLimitBottom],
                   below: 6, span: 0x1C, origin: WRAM.mapTileOriginY, bound: WRAM.mapUnk1D10)
    }

    private func initOrigin(entry: UInt8, low: UInt8, high: UInt8, below: UInt8, span: UInt8, origin: Int, bound: Int) {
        let test = low &+ 8
        wram[WRAM.mapOriginTest] = test
        if entry <= test {
            wram[origin] = low << 1; wram[bound] = (low << 1) &+ span
            return
        }
        wram[origin] = (entry &- 8) << 1
        if (high &- below) < entry {
            wram[bound] = (high &+ 1) << 1
            wram[origin] = wram[bound] &- span
        } else {
            wram[bound] = wram[origin] &+ span
        }
    }

    // MARK: Map_Unk9175

    /// Map_Unk9175: Map_Unk1D32/1D33 = the frame's X/Y steps unless the
    /// leader's tile is at Map_Unk1D1A-1D1D in that direction (the leader's
    /// slot as a 16-bit index, $80 for none).
    public func limitLeaderSteps() {
        wram[WRAM.mapUnk1D32] = 0; wram[WRAM.mapUnk1D33] = 0
        let leader = Int(wram[WRAM.partyObjSlot])
        let tx = wram[WRAM.objTileX + leader], ty = wram[WRAM.objTileY + leader]
        let sx = wram[WRAM.mapUnk1D2E], sy = wram[WRAM.mapUnk1D30]
        if sx != 0 {
            let past = sx & 0x80 != 0 ? wram[WRAM.mapLimitLeft] >= tx : tx >= wram[WRAM.mapLimitRight]
            if !past { wram[WRAM.mapUnk1D32] = sx }
        }
        if sy != 0 {
            let past = sy & 0x80 != 0 ? (wram[WRAM.mapLimitTop] &+ 1) >= ty : ty >= (wram[WRAM.mapLimitBottom] &+ 1)
            if !past { wram[WRAM.mapUnk1D33] = sy }
        }
    }

    // MARK: Map_Unk99DE

    /// Map_Unk99DE: drops the camera's X and Y steps by Map_StepStop*, with
    /// the ROM's fall-through after a dropped downward step (Map_StepStopUp
    /// then runs on what Map_StepStopDown left in A).
    public func dropCameraSteps() {
        let sx = wram[WRAM.mapUnk1D2E]
        if sx != 0 {
            let stop = sx & 0x80 == 0 ? stepStopRight(sx >> 4) : stepStopLeft((0 &- sx) >> 4)
            if stop { wram[WRAM.mapUnk1D2E] = 0 }
        }
        let sy = wram[WRAM.mapUnk1D30]
        guard sy != 0 else { return }
        var a = sy
        if sy & 0x80 == 0 {
            let (stop, left) = stepStopDown(sy >> 4)
            guard stop else { return }
            wram[WRAM.mapUnk1D30] = 0
            a = left
        }
        if stepStopUp((0 &- a) >> 4) { wram[WRAM.mapUnk1D30] = 0 }
    }

    /// The Map_StepStop* tests load the leader's slot with a 16-bit LDX (its
    /// high byte is $0198).
    private var leaderScreenX: UInt8 { wram[WRAM.objScreenX + wram.word(WRAM.partyObjSlot)] }
    private var leaderScreenY: UInt8 { wram[WRAM.objScreenY + wram.word(WRAM.partyObjSlot)] }

    /// Map_StepStopRight: C=1 (drop) at the right limit, or while the leader is left of $80.
    func stepStopRight(_ n: UInt8) -> Bool {
        wram[WRAM.mapStepTestN] = n
        let l = wram[WRAM.mapUnk1D0C] >> 1, limit = wram[WRAM.mapLimitRight]
        if l < limit { return 0x80 >= leaderScreenX }
        if l > limit { return true }
        return wram[WRAM.mapFine1X] &+ n >= 0x10
    }

    /// Map_StepStopLeft: C=1 at the left limit, or while the leader is right of $80.
    func stepStopLeft(_ n: UInt8) -> Bool {
        wram[WRAM.mapStepTestN2] = n
        let t = wram[WRAM.mapTileOriginX] >> 1, limit = wram[WRAM.mapLimitLeft]
        wram[WRAM.mapStepTestN] = t
        if limit < t { return leaderScreenX >= 0x80 }
        if limit > t { return true }
        return (wram[WRAM.mapFine1X] &- n) & 0x80 != 0
    }

    /// Map_StepStopDown: (C, the A it leaves).
    func stepStopDown(_ n: UInt8) -> (Bool, UInt8) {
        wram[WRAM.mapStepTestN] = n
        let l = wram[WRAM.mapUnk1D10] >> 1, limit = wram[WRAM.mapLimitBottom]
        if l < limit { return (0x88 >= leaderScreenY, 0x88) }
        if l > limit { return (true, l) }
        let a = wram[WRAM.mapFine1Y] &+ n
        return (a >= 0x10, a)
    }

    func stepStopUp(_ n: UInt8) -> Bool {
        wram[WRAM.mapStepTestN2] = n
        let t = wram[WRAM.mapTileOriginY] >> 1, limit = wram[WRAM.mapLimitTop]
        wram[WRAM.mapStepTestN] = t
        if limit < t { return leaderScreenY >= 0x88 }
        if limit > t { return true }
        return (wram[WRAM.mapFine1Y] &- n) & 0x80 != 0
    }

    // MARK: Map_Unk91AC

    /// Map_Unk91AC: the scroll-to steps, the shake, the accumulators and
    /// their split into whole pixels, and the drift timer.
    public func accumulateScroll() {
        if wram[WRAM.mapScrollToMode] != 0 { scrollToSteps() }
        if wram[WRAM.fieldUnkBC] != 0 {
            let e = wram[WRAM.engUnk0400]
            var x = (e & 0x04) << 2, y = (e & 0x02) << 3
            if e & 0x01 != 0 { x = 0 &- x; y = 0 &- y }
            if wram[WRAM.mapTileOriginX] == 0 { x = 0 }
            if wram[WRAM.mapTileOriginY] == 0 { y = 0 }
            wram[WRAM.mapShakeX] = x; wram[WRAM.mapShakeY] = y
        }
        let steps = [wram[WRAM.mapUnk1D2E], wram[WRAM.mapUnk1D30]], shake = [wram[WRAM.mapShakeX], wram[WRAM.mapShakeY]]
        let flags = wram[WRAM.mapOwnStepFlags]
        for k in 0..<3 {
            for a in 0..<2 {
                let acc = WRAM.mapAcc1X + 2 * k + a
                var v = wram[acc] &+ wram[WRAM.mapDrift1X + 2 * k + a]
                if k > 0 { v = v &+ wram[WRAM.mapOwnStep2X + 2 * (k - 1) + a] }
                if k == 0 || flags & UInt8(1 << k) == 0 { v = v &+ steps[a] &+ shake[a] }
                wram[acc] = v
            }
        }
        for i in 0..<6 {
            let acc = WRAM.mapAcc1X + i, move = WRAM.mapMove1XNeg + 2 * i, v = wram[acc]
            if v & 0x80 != 0 {
                wram[move] = (0 &- v) >> 4; wram[move + 1] = 0
            } else {
                wram[move + 1] = v >> 4; wram[move] = 0
            }
            let rest: UInt8
            if v & 0x0F == 0 { rest = 0 } else if v & 0x80 != 0 { rest = v | 0xF0 } else { rest = v & 0x0F }
            wram[acc] = rest
        }
        let timer = wram[WRAM.mapDriftTimer]
        if timer != 0 {
            wram[WRAM.mapDriftTimer] = timer &- 1
            if timer == 1 { for i in 0..<6 { wram[WRAM.mapDrift1X + i] = 0 } }
        }
    }

    /// Map_Unk91AC's scroll-to: ±$10 toward Map_ScrollToX/Y (in
    /// Map_TileOriginX/Y's low byte), back while the scroll word is off a
    /// 16-pixel boundary, and ScrollTo_Arrived once both axes are there.
    func scrollToSteps() {
        let tx = wram[WRAM.mapScrollToX], ox = wram[WRAM.mapTileOriginX]
        if tx != ox {
            wram[WRAM.mapUnk1D2E] = tx > ox ? Self.stepPos : Self.stepNeg
        } else if wram[WRAM.mapScroll1X] & 0x0F != 0 {
            wram[WRAM.mapUnk1D2E] = Self.stepNeg
        } else {
            wram[WRAM.mapScrollToDone] |= 0x01
        }
        let ty = wram[WRAM.mapScrollToY], oy = wram[WRAM.mapTileOriginY]
        if ty != oy {
            wram[WRAM.mapUnk1D30] = ty > oy ? Self.stepPos : Self.stepNeg
            return
        }
        if wram[WRAM.mapScroll1Y] & 0x0F != 0 { wram[WRAM.mapUnk1D30] = Self.stepNeg; return }
        wram[WRAM.mapScrollToDone] |= 0x02
        if wram[WRAM.mapScrollToDone] == 0x03 {
            wram[WRAM.mapScrollToMode] = 0x02
            wram[WRAM.mapScrollToDone] = 0
        }
    }

    // MARK: Map_Unk93E1 (layer 1)

    /// Map_Unk93E1's first part for layer 1: the edge flags cleared, then
    /// Map_Scroll1XInc, XDec, YDec, YInc.
    public func stepScroll() {
        for a in [WRAM.mapEdgeColXInc, WRAM.mapEdgeColXDec, WRAM.mapEdgeRowYInc, WRAM.mapEdgeRowYDec] { wram[a] = 0 }
        scroll1(axis: 0, rising: true); scroll1(axis: 0, rising: false)
        scroll1(axis: 1, rising: false); scroll1(axis: 1, rising: true)
    }

    /// One of Map_Scroll1XInc/XDec/YInc/YDec: a pixel at a time, the tile
    /// origin and its bound moved (low bytes) at each 8-pixel crossing of
    /// the fine counter.
    func scroll1(axis: Int, rising: Bool) {
        let count = wram[WRAM.mapMove1XNeg + 2 * axis + (rising ? 1 : 0)]
        guard count != 0 else { return }
        let word: Int = axis == 0 ? WRAM.mapScroll1X : WRAM.mapScroll1Y, fine: Int = axis == 0 ? WRAM.mapFine1X : WRAM.mapFine1Y
        let origin: Int = axis == 0 ? WRAM.mapTileOriginX : WRAM.mapTileOriginY, bound: Int = axis == 0 ? WRAM.mapUnk1D0C : WRAM.mapUnk1D10
        let xEdge: Int = rising ? WRAM.mapEdgeColXInc : WRAM.mapEdgeColXDec, yEdge: Int = rising ? WRAM.mapEdgeRowYInc : WRAM.mapEdgeRowYDec
        let edge: Int = axis == 0 ? xEdge : yEdge
        var n = count
        repeat {
            wram.setWord(word, (wram.word(word) + (rising ? 1 : 0xFFFF)) & 0xFFFF)
            var a = wram[fine]
            if rising {
                if a == 0x0F { cross(origin, bound, edge, 1); a = 0xFF }
                if a == 0x07 { cross(origin, bound, edge, 1) }
                a &+= 1
            } else {
                if a == 0 { cross(origin, bound, edge, 0xFF); a = 0x10 }
                if a == 0x08 { cross(origin, bound, edge, 0xFF) }
                a &-= 1
            }
            wram[fine] = a
            n &-= 1
        } while n != 0
        wram[WRAM.mapStepCount] = 0
    }

    private func cross(_ origin: Int, _ bound: Int, _ edge: Int, _ d: UInt8) {
        wram[origin] &+= d; wram[bound] &+= d
        wram[edge] = 0x01
    }

    // MARK: Field_Unk885A

    /// Field_Unk885A, one frame of DefaultHandler's redraw loop: step 1 sets
    /// ±$10 toward the side of the screen the leader is on for each axis
    /// whose fine counter (Map_Unk1D93 / 1D96) is off zero, step 2 keeps
    /// those steps while the counters are off zero; each frame with a step
    /// runs Map_Unk91AC and Map_Unk93E1. Field_Unk38 = 0 when it is done.
    public func recentreStep() {
        let stage = wram[WRAM.fieldUnk38]
        guard stage != 0 else { return }
        let fx = wram[WRAM.mapFine1X], fy = wram[WRAM.mapFine1Y]
        switch stage {
        case 1:
            for a in [WRAM.mapUnk1D2E, WRAM.mapUnk1D30, WRAM.mapUnk1D32, WRAM.mapUnk1D33] { wram[a] = 0 }
            let leader = Int(wram[WRAM.partyObjSlot])
            if fx != 0 { wram[WRAM.mapUnk1D2E] = wram[WRAM.objScreenX + leader] >= 0x80 ? Self.stepPos : Self.stepNeg }
            if fy != 0 {
                wram[WRAM.mapUnk1D30] = wram[WRAM.objScreenY + leader] >= 0x88 ? Self.stepPos : Self.stepNeg
            } else if fx == 0 {
                wram[WRAM.fieldUnk38] = 0
                return
            }
            accumulateScroll(); stepScroll()
            wram[WRAM.fieldUnk38] = 2
        case 2:
            wram[WRAM.mapUnk1D32] = 0; wram[WRAM.mapUnk1D33] = 0
            if fx == 0 { wram[WRAM.mapUnk1D2E] = 0 }
            if fy == 0 {
                wram[WRAM.mapUnk1D30] = 0
                if fx == 0 { wram[WRAM.fieldUnk38] = 0; return }
            }
            accumulateScroll(); stepScroll()
        default:
            wram[WRAM.fieldUnk38] = 0
        }
    }
}
