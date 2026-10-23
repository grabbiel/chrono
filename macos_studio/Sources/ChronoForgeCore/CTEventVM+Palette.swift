// CTEventVM+Palette.swift — the palette opcodes and what runs their
// records: Evt_Op88_ObjPalAnim, Evt_Op2E_PalAnim and Evt_Op33_SetPalette
// ($C0:4892, $C0:4A4E, $C0:3711) set up FieldAnimB records ($0520, 12 of
// 12 bytes) or copy colours into Pal_Buf ($7E:2000, the palette) and
// Pal_CgramBuf ($7E:2200, what the NMI sends to CGRAM); PalAnim_TickAll
// ($FD:E39C, FdVec_FFF7 in Field_EndOfFrame) runs the records every frame.
// The sprite palette slots (Obj_PalSlot, $0B80) are claimed as an object
// comes into view (Obj_Unk7170, $C0:7170) and given back as it leaves
// (Obj_Unk734C, $C0:734C); a claim copies the object's 12 colours from
// bank $E4 into its row.
import Foundation

extension WRAM {
    public static let palBuf = 0x7E2000, palSpriteRows = 0x7E2100, palCgramBuf = 0x7E2200
    public static let fieldAnimB = 0x7E0520, fieldAnimBSize = 12, fieldAnimBCount = 12
    public static let objXPalAnimRec = 0x7F0B80
    public static let objPalPrev = 0x7E0B00, objPalNext = 0x7E0B01, objPalSlot = 0x7E0B80
}

extension CTEventVM {
    static let palBank7F = 0x7F2001 & 0xFFFF                 // Evt_DataAddr
    static let palAnimRom = 0xF60000, locPalRom = 0xF624C0, locPalSetBytes = 0xD2

    /// FieldAnimB record `rec` (an offset from $0520), field `f` (.Unk0 = 0 ... .Ptr = 9).
    func animB(_ rec: Int, _ f: Int) -> Int { WRAM.fieldAnimB + rec + f }

    /// A write through DB=$00: WRAM's low mirror only (the rest of bank $00 is I/O and ROM).
    func lowWrite(_ a: Int, _ v: UInt8) {
        if a & 0xFFFF < 0x2000 { wram[0x7E0000 | (a & 0xFFFF)] = v }
    }

    /// Evt_FindFreeAnimB: the first of records 0-7 with .Unk0 = 0.
    func findFreeAnimB() -> Int? {
        (0..<8).map { $0 * WRAM.fieldAnimBSize }.first { wram[animB($0, 0)] == 0 }
    }

    /// One MVN of `count` + 1 bytes from `src` (24-bit, the bank fixed) to
    /// bank $7E at `dst`; both addresses wrap inside their banks.
    func moveBlock(from src: Int, to dst: Int, count: Int) {
        let bank = src & 0xFF0000
        for i in 0...count {
            let at = 0x7E0000 | ((dst + i) & 0xFFFF)
            wram[at] = read(bank | ((src + i) & 0xFFFF))
            if (0x7E2200..<0x7E2400).contains(at) { paletteWrites.insert((at - WRAM.palCgramBuf) >> 1) }
        }
    }

    /// The colour copy Obj_PalSlotFixed and its kin end with: the 12 colours
    /// at Obj_PalSrc in bank $E4 to colours 1-12 of the object's row
    /// (Obj_OamAttr x 16) in Pal_Buf, then in Pal_CgramBuf.
    func copyObjPalette(_ cur: Int, attr: UInt8) {
        let dst = (Int(attr) * 16 + 2 + (WRAM.palSpriteRows & 0xFFFF)) & 0xFFFF
        let src = 0xE40000 | wram.word(WRAM.objPalSrc + cur)
        moveBlock(from: src, to: dst, count: 0x17)
        moveBlock(from: src, to: dst + 0x200, count: 0x17)
    }

    /// .Unk7 / .Unk8 from d: its high nibble twice, its low nibble twice.
    func setAnimSpeeds(_ rec: Int, _ d: Int) {
        wram[animB(rec, 7)] = UInt8(d & 0xF0 | d >> 4)
        wram[animB(rec, 8)] = UInt8((d & 0x0F) << 4 | d & 0x0F)
    }

    /// The kind $8x copy both opcodes end with: the word n at `at`, then n - 2
    /// colour bytes (MVN from bank $7F) to Pal_CgramBuf and Pal_Buf from colour
    /// `first`. X past the colour bytes.
    func palCopy(first: Int, at: Int) -> Outcome {
        let colOfs = (first & 0xFF) * 2
        let count = (dataWord(at) - 3) & 0xFFFF
        let src = (at + 2 + Self.palBank7F) & 0xFFFF
        moveBlock(from: 0x7F0000 | src, to: colOfs + (WRAM.palCgramBuf & 0xFFFF), count: count)
        moveBlock(from: 0x7F0000 | src, to: colOfs + (WRAM.palBuf & 0xFFFF), count: count)
        return .go(x: (src + count + 1 - Self.palBank7F) & 0xFFFF, carry: true)
    }

    /// Evt_Op88_ObjPalAnim: palette animations on Obj_Cur's own palette.
    func objPalAnim(_ y: Int) -> Outcome {
        wram.setWord(WRAM.evtOpSavedPos, y)
        let kind = data(y + 1), cur = wram.word(WRAM.objCur)
        let base = ((Int(wram[WRAM.objOamAttr + cur]) << 3) + 0x80) & 0xFF   // EvtPal_Base: its colour 0
        if kind == 0 {                                                   // .restore
            let rec = wram.word(WRAM.objXPalAnimRec + cur)
            if rec & 0x8000 == 0 {
                wram.setWord(WRAM.objXPalAnimRec + cur, 0xFFFF)
                lowWrite(WRAM.fieldAnimB + rec, 0)
                copyObjPalette(cur, attr: wram[WRAM.objOamAttr + cur])
            }
            return .go(x: y + 2, carry: true)
        }
        if kind == 0x20 || kind == 0x30 {                                // .linked
            guard let rec = findFreeAnimB() else { return .go(x: y + 4, carry: false) }
            wram.setWord(WRAM.objXPalAnimRec + cur, rec)
            let c = data(y + 2)
            wram[animB(rec, 0)] = UInt8(kind)
            wram[animB(rec, 5)] = UInt8(data(y + 3)); wram[animB(rec, 4)] = 0
            wram[animB(rec, 2)] = UInt8(c & 0x0F); wram[animB(rec, 1)] = UInt8(((c >> 4) + base) & 0xFF)
            return .go(x: y + 4, carry: true)
        }
        switch kind & 0xF0 {
        case 0x40, 0x50:                                                 // .cycle
            guard let rec = findFreeAnimB() else { return .go(x: y + 5, carry: false) }
            let c = data(y + 2)
            wram[animB(rec, 0)] = UInt8(kind & 0xF0); wram[animB(rec, 6)] = UInt8(kind & 0x0F)
            wram[animB(rec, 5)] = UInt8(data(y + 4)); wram[animB(rec, 4)] = 0; wram[animB(rec, 3)] = 8
            wram[animB(rec, 2)] = UInt8(c & 0x0F); wram[animB(rec, 1)] = UInt8(((c >> 4) + base) & 0xFF)
            setAnimSpeeds(rec, data(y + 3))
            return .go(x: y + 5, carry: true)
        case 0x80:                                                       // .copy
            return palCopy(first: kind & 0x0F | base, at: y + 2)
        default:
            return .go(x: y + 2, carry: true)
        }
    }

    /// Evt_Op2E_PalAnim: kinds $4x/$5x and $8x with absolute colour numbers.
    func palAnim(_ y: Int) -> Outcome {
        wram.setWord(WRAM.evtOpSavedPos, y)
        let kind = data(y + 1)
        switch kind & 0xF0 {
        case 0x40, 0x50:
            guard let rec = findFreeAnimB() else { return .go(x: y + 6, carry: false) }
            wram[animB(rec, 0)] = UInt8(kind & 0xF0); wram[animB(rec, 6)] = UInt8(kind & 0x0F)
            wram[animB(rec, 1)] = UInt8(data(y + 2)); wram[animB(rec, 2)] = UInt8(data(y + 3))
            wram[animB(rec, 5)] = UInt8(data(y + 5)); wram[animB(rec, 4)] = 0; wram[animB(rec, 3)] = 8
            setAnimSpeeds(rec, data(y + 4))
            return .go(x: y + 6, carry: true)
        case 0x80:
            return palCopy(first: data(y + 2), at: y + 3)
        default:
            return .go(x: y + 2, carry: true)
        }
    }

    /// Evt_Op33_SetPalette: Obj_OamAttr = slot x 2 & $0E and the object's
    /// colours into that row, the slot not claimed; Field_Unk54 bit 7 set.
    func setPalette(_ y: Int) -> Outcome {
        wram[WRAM.fieldUnk54] |= 0x80
        wram.setWord(WRAM.evtOpSavedPos, y + 2)
        let cur = wram.word(WRAM.objCur)
        let attr = UInt8(data(y + 1) << 1 & 0x0E)
        wram[WRAM.objOamAttr + cur] = attr
        copyObjPalette(cur, attr: attr)
        return .go(x: y + 2, carry: true)
    }

    // MARK: Palette slots

    /// Obj_Unk7170: Obj_Cur's palette slot by its Obj_Unk1100 kind (unless
    /// Field_Unk54 bit 7): 0-2 slots 5-7 (Obj_PalSlotFixed), 5 and 6 slots
    /// 1-3 (Obj_Unk72B4), 3, 4 and 7-11 slots 0-4 (Obj_PalSlotAny). Nil when
    /// nothing ran, else the handler's carry (claimed or shared).
    @discardableResult
    public func claimPaletteSlot() -> Bool? {
        guard wram[WRAM.fieldUnk54] & 0x80 == 0 else { return nil }
        let cur = Int(wram[WRAM.objCur])
        let kind = Int(wram[WRAM.objUnk1100 + cur])
        guard kind & 0x80 == 0, kind < 12 else { return nil }
        if kind < 3 { return claimFixedSlot(cur, slot: 5 + kind) }
        return claimSharedSlot(cur, slots: kind == 5 || kind == 6 ? 1..<4 : 0..<5)
    }

    func samePalette(_ owner: Int, _ cur: Int) -> Bool {
        wram.word(WRAM.objPalSrc + owner) == wram.word(WRAM.objPalSrc + cur)
    }

    /// .claim: Obj_PalSlot + `at` = Obj_Cur, Obj_OamAttr = `at` x 2 & $0E, the colours.
    func claimSlot(_ cur: Int, at: Int) -> Bool {
        wram[WRAM.objPalSlot + at] = UInt8(cur)
        let attr = UInt8(at << 1 & 0x0E)
        wram[WRAM.objOamAttr + cur] = attr
        copyObjPalette(cur, attr: attr)
        return true
    }

    /// Chained after `owner` (it has the same colours).
    func chainPalette(_ cur: Int, after owner: Int) {
        wram[WRAM.objPalPrev + cur] = UInt8(owner); wram[WRAM.objPalNext + cur] = 0x80
        wram[WRAM.objPalNext + owner] = UInt8(cur)
    }

    /// Obj_PalSlotFixed. Quirk kept: a shared slot is claimed at the owner's
    /// offset, not the slot's.
    func claimFixedSlot(_ cur: Int, slot: Int) -> Bool {
        let owner = Int(wram[WRAM.objPalSlot + slot])
        if owner & 0x80 != 0 {
            wram[WRAM.objPalPrev + cur] = 0x80; wram[WRAM.objPalNext + cur] = 0x80
            return claimSlot(cur, at: slot)
        }
        guard samePalette(owner, cur) else { return false }
        chainPalette(cur, after: owner)
        return claimSlot(cur, at: owner)
    }

    /// Obj_PalSlotAny / Obj_Unk72B4: share a taken slot with the same colours,
    /// else take the first free one.
    func claimSharedSlot(_ cur: Int, slots: Range<Int>) -> Bool {
        for s in slots {
            let owner = Int(wram[WRAM.objPalSlot + s])
            if owner & 0x80 == 0, samePalette(owner, cur) {
                chainPalette(cur, after: owner)
                return claimSlot(cur, at: s)
            }
        }
        for s in slots where wram[WRAM.objPalSlot + s] & 0x80 != 0 {
            wram[WRAM.objPalPrev + cur] = 0x80; wram[WRAM.objPalNext + cur] = 0x80
            return claimSlot(cur, at: s)
        }
        return false
    }

    /// Obj_Unk734C: Obj_Cur out of its slot's chain (unless Field_Unk54 bit 7).
    public func releasePaletteSlot() {
        guard wram[WRAM.fieldUnk54] & 0x80 == 0 else { return }
        let cur = Int(wram[WRAM.objCur])
        let next = Int(wram[WRAM.objPalNext + cur]), prev = Int(wram[WRAM.objPalPrev + cur])
        let slot = Int(wram[WRAM.objOamAttr + cur] >> 1)
        switch (next & 0x80 != 0, prev & 0x80 != 0) {
        case (true, true): wram[WRAM.objPalSlot + slot] = 0x80
        case (true, false): wram[WRAM.objPalSlot + slot] = UInt8(prev); wram[WRAM.objPalNext + prev] = 0x80
        case (false, true): wram[WRAM.objPalPrev + next] = 0x80
        case (false, false): wram[WRAM.objPalPrev + next] = UInt8(prev); wram[WRAM.objPalNext + prev] = UInt8(next)
        }
    }

    // MARK: PalAnim_TickAll

    /// PalAnim_TickAll: each record's .Unk4 counts to .Unk5; then kinds 1 and
    /// 8 step their frame (.Unk3, wrapping after .Unk0 & $0F) and the kind
    /// acts on its colours.
    public func palAnimTick() {
        for k in 0..<WRAM.fieldAnimBCount {
            let r = k * WRAM.fieldAnimBSize
            let t = wram[animB(r, 4)] &+ 1
            wram[animB(r, 4)] = t
            guard t == wram[animB(r, 5)] else { continue }
            wram[animB(r, 4)] = 0
            let kind = wram[animB(r, 0)] & 0xF0
            if kind == 0x10 || kind == 0x80 {
                let f = wram[animB(r, 3)] &+ 1
                wram[animB(r, 3)] = f
                if (wram[animB(r, 0)] & 0x0F) &+ 1 == f { wram[animB(r, 3)] = 0 }
            }
            switch wram[animB(r, 0)] >> 4 {
            case 0: break
            case 1: copyRomFrame(r, frame: Int(wram[animB(r, 3)]))
            case 2: rotate(r, up: false)
            case 3: rotate(r, up: true)
            case 4: fade(r, white: true)
            case 5: fade(r, white: false)
            case 6: pulse(r, white: true)
            case 7: pulse(r, white: false)
            default:                                                    // PalAnim_CopyListFrame
                let ptr = (Int(wram[animB(r, 3)]) + wram.word(animB(r, 9))) & 0xFFFF
                copyRomFrame(r, frame: Int(read(Int(wram[animB(r, 11)]) << 16 | ptr)))
            }
        }
    }

    func cgramWrite(_ x: Int, _ v: Int) {
        let at = WRAM.palCgramBuf + (x & 0xFFFF)
        wram[at] = UInt8(v & 0xFF); wram[at + 1] = UInt8(v >> 8 & 0xFF)
        paletteWrites.insert(((x & 0xFFFF) >> 1) & 0xFF)
    }

    func palBufWord(_ x: Int) -> Int { wram.word(WRAM.palBuf + (x & 0xFFFF)) }

    /// A loop count Y from an 8-bit field: 0 runs 65,536 times (DEY, BNE).
    static func loops(_ n: UInt8) -> Int { n == 0 ? 0x10000 : Int(n) }

    /// PalAnim_CopyRomFrame / PalAnim_CopyListFrame: .Unk2 colours from
    /// PalAnimRom + .Unk6/.Unk7 + frame x (.Unk2 x 2 & $FF) to Pal_CgramBuf from colour .Unk1.
    func copyRomFrame(_ r: Int, frame: Int) {
        var dest = Int(wram[animB(r, 1)]) * 2 + (WRAM.palCgramBuf & 0xFFFF)
        let stride: Int = Int(wram[animB(r, 2)] &* 2)
        var x: Int = (wram.word(animB(r, 6)) + frame * stride) & 0xFFFF
        for _ in 0..<Self.loops(wram[animB(r, 2)]) {
            // Typed lets: CI's older type checker (Xcode 26.6) is slow on Int(...) mixed with | and <<.
            let lo: Int = Int(read(Self.palAnimRom + x)), hi: Int = Int(read(Self.palAnimRom + x + 1))
            let v: Int = lo | hi << 8
            let next: Int = (dest + 1) & 0xFFFF
            wram[0x7E0000 | dest] = UInt8(v & 0xFF); wram[0x7E0000 | next] = UInt8(v >> 8)
            if (0x2200..<0x2400).contains(dest) { paletteWrites.insert((dest - 0x2200) >> 1) }
            dest = (dest + 2) & 0xFFFF; x = (x + 2) & 0xFFFF
        }
    }

    /// PalAnim_RotateUp / RotateDown: colours .Unk1 to .Unk1 + .Unk2 move one
    /// place in Pal_Buf and Pal_CgramBuf, the end one wrapping round. The span
    /// is .Unk2 x 2 in 8 bits, and the loop tests after its step (a span of 0
    /// goes round all 64 KiB, as the ROM's does).
    func rotate(_ r: Int, up: Bool) {
        let first: Int = Int(wram[animB(r, 1)]) * 2
        let span: Int = Int(wram[animB(r, 2)] &* 2)
        let last: Int = (first + span) & 0xFFFF
        var x: Int = up ? last : first
        let end: Int = up ? first : last, step: Int = up ? -2 : 2
        let saveBuf = palBufWord(x), saveCgram = wram.word(WRAM.palCgramBuf + x)
        func put(_ base: Int, _ at: Int, _ v: Int) {
            wram[base + at] = UInt8(v & 0xFF); wram[base + at + 1] = UInt8(v >> 8)
        }
        repeat {
            let from = (x + step) & 0xFFFF
            put(WRAM.palBuf, x, palBufWord(from))
            put(WRAM.palCgramBuf, x, wram.word(WRAM.palCgramBuf + from))
            paletteWrites.insert((x >> 1) & 0xFF)
            x = from
        } while x != end
        put(WRAM.palBuf, x, saveBuf)
        put(WRAM.palCgramBuf, x, saveCgram)
        paletteWrites.insert((x >> 1) & 0xFF)
    }

    /// PalAnim_Fade (kind 5) / PalAnim_FadeWhite (kind 4): the level .Unk7
    /// steps by .Unk3 toward .Unk8, the record ending there; then the
    /// colours are scaled (or lightened) by it.
    func fade(_ r: Int, white: Bool) {
        let period = wram[animB(r, 5)], level = wram[animB(r, 7)], target = wram[animB(r, 8)], step = wram[animB(r, 3)]
        var a: UInt8
        if period & 0x80 != 0 {
            a = period
        } else if level < target {
            let sum = Int(level) + Int(step)
            if sum > 0xFF, !white { restoreColours(r); return }
            if sum > 0xFF || sum >= Int(target) {
                wram[animB(r, 0)] = 0; a = target
            } else {
                a = UInt8(sum)
            }
        } else {
            let diff = Int(level) - Int(step)
            if diff < 0, white { restoreColours(r); return }
            if diff < 0 || diff < Int(target) {
                wram[animB(r, 0)] = 0; a = target
            } else {
                a = UInt8(diff)
            }
        }
        wram[animB(r, 7)] = a
        if white { whiten(r, level: Int(a)) } else { scale(r, level: Int(a)) }
    }

    /// The .overflow / .restore copy: .Unk2 colours from Pal_Buf to Pal_CgramBuf unchanged.
    func restoreColours(_ r: Int) {
        wram[animB(r, 0)] = 0
        var x = Int(wram[animB(r, 1)]) * 2
        for _ in 0..<Self.loops(wram[animB(r, 2)]) {
            cgramWrite(x, palBufWord(x))
            x = (x + 2) & 0xFFFF
        }
    }

    /// PalAnim_Pulse (kind 7) / PalAnim_PulseWhite (kind 6): the phase .Unk7
    /// += .Unk3; h = (2|phase| & $FF) x .Unk8 >> 8; kind 7 scales by -h, kind 6 lightens by h.
    func pulse(_ r: Int, white: Bool) {
        let phase = wram[animB(r, 7)] &+ wram[animB(r, 3)]
        wram[animB(r, 7)] = phase
        let mag = phase & 0x80 != 0 ? (phase ^ 0xFF) &+ 1 : phase
        let h = (Int(mag &<< 1) * Int(wram[animB(r, 8)])) >> 8
        if white { whiten(r, level: h) } else { scale(r, level: Int((UInt8(h) ^ 0xFF) &+ 1)) }
    }

    /// One channel through the multiplier: its high byte of value x level.
    static func scaled(_ v: Int, _ level: Int) -> Int { ((v & 0xFF) * level) >> 8 }

    /// PalAnim_ApplyLevel's Scale routines by .Unk6 (0 RGB, 1 GB, 2 RB, 3 B,
    /// 4 RG, 5 G, 6+ R): each scaled channel x level / 256, the others kept.
    func scale(_ r: Int, level: Int) {
        let which = Int(wram[animB(r, 6)])
        let (red, green, blue) = [(true, true, true), (false, true, true), (true, false, true), (false, false, true),
                                  (true, true, false), (false, true, false)][safe: which] ?? (true, false, false)
        var x = Int(wram[animB(r, 1)]) * 2
        for _ in 0..<Self.loops(wram[animB(r, 2)]) {
            let c = palBufWord(x)
            let r5 = red ? Self.scaled(c & 0x1F, level) & 0x1F : c & 0x001F
            let g5 = green ? (Self.scaled((c & 0x03E0) >> 2, level) & 0xF8) << 2 : c & 0x03E0
            let b5 = blue ? (Self.scaled(c >> 8 & 0x7C, level) & 0x7C) << 8 : c & 0x7C00
            cgramWrite(x, r5 | g5 | b5)
            x = (x + 2) & 0xFFFF
        }
    }

    /// One channel lightened: c + (mask - c) x level / 256 (8-bit add), masked.
    static func whitened(_ c: Int, mask: Int, _ level: Int) -> Int { (c + scaled(c ^ mask, level)) & 0xFF & mask }

    /// PalAnim_ApplyWhiteLevel's Whiten routines by .Unk6 (0 RGB, 1 R, 2 G,
    /// 3 RG, 4 B, 5 RB, 6+ GB). Quirks kept: R and B write one byte of the
    /// colour (the other keeps Pal_CgramBuf's), RG drops blue and GB drops red.
    func whiten(_ r: Int, level: Int) {
        let which = Int(wram[animB(r, 6)])
        var x = Int(wram[animB(r, 1)]) * 2
        for _ in 0..<Self.loops(wram[animB(r, 2)]) {
            let c = palBufWord(x), lo = c & 0xFF, hi = c >> 8
            let red = Self.whitened(lo & 0x1F, mask: 0x1F, level)
            let blue = Self.whitened(hi & 0x7C, mask: 0x7C, level) << 8
            let green = Self.whitened((c & 0x03E0) >> 2, mask: 0xF8, level) << 2
            let cg = WRAM.palCgramBuf + (x & 0xFFFF)
            switch which {
            case 0: cgramWrite(x, red | green | blue)
            case 1: cgramWrite(x, red | lo & 0xE0 | Int(wram[cg + 1]) << 8)
            case 2: cgramWrite(x, c & 0x7C1F | green)
            case 3: cgramWrite(x, red | green)
            case 4: cgramWrite(x, Int(wram[cg]) | blue | (hi & 0x03) << 8)
            case 5: cgramWrite(x, red | blue | c & 0x03E0)
            default: cgramWrite(x, green | blue)
            }
            x = (x + 2) & 0xFFFF
        }
    }

    // MARK: Location load

    /// LocLoad_Unk7084 and Pal_LoadUnkRow0's copy: colours 1-15 of Pal_Buf rows
    /// 1-7 from LocPal_Rom entry `palette`, then all of Pal_Buf to Pal_CgramBuf.
    public func loadLocationPalette(_ palette: Int) {
        let src = Self.locPalRom + Self.locPalSetBytes * palette
        for row in 0..<7 {
            for i in 0..<0x1E { wram[WRAM.palBuf + 0x22 + 0x20 * row + i] = read(src + 0x1E * row + i) }
        }
        for i in 0..<0x200 { wram[WRAM.palCgramBuf + i] = wram[WRAM.palBuf + i] }
        for s in 0..<8 { wram[WRAM.objPalSlot + s] = 0x80 }                   // Field_ResetUnk0B80
        paletteWrites = []
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
