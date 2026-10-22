// CTEventVM+Characters.swift — the opcodes that make an object a playable
// character or a sprite: $80 and the one-byte $57/$5C/$62/$68/$6A/$6C/$6D
// (Evt_InitCharCommon), $81 (Evt_LoadSpriteRec), $82 and $83 (Evt_InitWramSprite,
// graphics unpacked to bank $7F through Decomp_ToWram). As the ROM handlers do
// them; the records and pointers they read are the ROM's (bank $E4).
import Foundation

extension CTEventVM {
    static let characterOps: [UInt8: Int] = [0x57: 0, 0x5C: 1, 0x62: 2, 0x68: 4, 0x6A: 3, 0x6C: 5, 0x6D: 6]
    static let sprRec = 0xE4F000, npcSprRec = 0xE4F023, enemySprRec = 0xE4F600

    /// A byte through a 24-bit pointer in WRAM plus Y (`LDA [dp],Y`: the sum carries into the bank).
    func indirect(_ pointer: Int, _ y: Int) -> UInt8 {
        let p = Int(wram[pointer]) | Int(wram[pointer + 1]) << 8 | Int(wram[pointer + 2]) << 16
        return read((p + (y & 0xFFFF)) & 0xFFFFFF)
    }
    func indirectWord(_ pointer: Int, _ y: Int) -> Int { Int(indirect(pointer, y)) | Int(indirect(pointer, y + 1)) << 8 }

    /// Evt_Op80_InitCharObj and the one-byte opcodes: Chr_ObjSlot[char] = Obj_Cur, then Evt_InitCharCommon.
    func initCharacter(_ op: UInt8, _ y: Int) -> Outcome {
        let char: Int, last: Int
        if op == 0x80 { char = data(y + 1); last = y + 1 } else { char = Self.characterOps[op]!; last = y }
        if char <= 6 { wram[WRAM.chrObjSlot + char] = wram[WRAM.objCur] }
        wram[WRAM.evtCharId] = UInt8(char)
        return initCharCommon(char: UInt8(char), last: last)
    }

    /// Evt_InitCharCommon: a party member's object (leader, member 2, member 3) or one never queued.
    func initCharCommon(char: UInt8, last: Int) -> Outcome {
        let c = objCur
        guard let k = (0..<3).first(where: { wram[WRAM.partyMembers + $0] == char }) else {
            wram[WRAM.objUnk1100 + c] = 0x80                       // Obj_Unk1100Skip
            wram[WRAM.objUnk1101 + c] = char
            return .go(x: last + 1, carry: true)
        }
        wram[WRAM.objUnk1100 + c] = UInt8(k)
        wram[WRAM.objUnk1C80 + c] = 0
        wram[WRAM.objUnk1A81 + c] = 1                              // Obj_Unk1A81On
        wram[WRAM.objUnk1B01 + c] = 1                              // Obj_Unk1B01Solid
        wram[WRAM.objUnk1101 + c] = char
        wram.setWord([WRAM.partyObjSlot, WRAM.partyObjSlot1, WRAM.partyObjSlot2][k], c)
        let next = loadSpriteRec(record: Int(char), y: last)
        if k > 0, wram[WRAM.objQUnk78] != 0 {
            wram[WRAM.objQUnk78] = 2                               // ObjQ_Unk78Head
            wram[WRAM.objAnimTimer + c] = 0
        }
        wram.setWord(WRAM.objTileSlot + 1 + k, c)
        wram.setWord(WRAM.objVramTile + c, [0x0008, 0x0020, 0x0028][k])     // EvtChar_VramTile0-2
        wram.setWord(WRAM.objTileRecOfs + c, [0x0000, 0x0020, 0x0040][k])
        wram[WRAM.objUnk1000 + c] = wram[WRAM.objUnk1000 + c] & 0x80 | 1    // EvtChar_ScriptPeriod
        if k == 0 || wram[WRAM.partyObjSlot] & 0x80 != 0 {
            if k > 0 { for i in 0..<3 { wram[WRAM.fieldUnkAB + i] = 0 } }
            wram[WRAM.objTileX + c] = wram[WRAM.locEntryX]
            wram[WRAM.objTileY + c] = wram[WRAM.locEntryY]
            let facing = wram[WRAM.locEntryFacing]
            wram[WRAM.objFacing + c] = facing & 0x03
            wram[WRAM.objPosY + c] = facing & 0x08 != 0 ? 0x7F : 0xFF       // EvtChar_SubYUpper / Lower
            wram[WRAM.objPosX + c] = facing & 0x04 != 0 ? 0x00 : 0x80
            return .go(x: next, carry: true)
        }
        for i in 0..<3 { wram[WRAM.fieldUnkAB + i] = 0 }
        let leader = Int(wram[WRAM.partyObjSlot]), me = wram.word([0, WRAM.partyObjSlot1, WRAM.partyObjSlot2][k])
        wram.setWord(WRAM.objPosX + me, wram.word(WRAM.objPosX + leader))
        wram.setWord(WRAM.objPosY + me, wram.word(WRAM.objPosY + wram.word(WRAM.partyObjSlot)))
        wram.setWord(WRAM.objVelX + me, 0)
        wram[WRAM.objFacing + me] = wram[WRAM.objFacing + wram.word(WRAM.partyObjSlot)]
        return .go(x: next, carry: true)
    }

    /// Evt_Op81_InitSprite.
    func initSprite(_ y: Int) -> Outcome {
        let c = objCur, record = UInt8(data(y + 1))
        wram[WRAM.objUnk1100 + c] = 3                              // Obj_Unk1100Kind3
        wram[WRAM.objUnk1B01 + c] = 1
        wram[WRAM.objUnk1101 + c] = record
        return .go(x: loadSpriteRec(record: Int(record), y: y + 1), carry: true)
    }

    /// The record fields Evt_LoadSpriteRec and opcodes $82/$83 share: frames, palette, animation, size.
    func loadRecordFields(base: Int, recOfs: Int) {
        let c = objCur
        let frames = Int(read(base + 1 + recOfs))                  // SprRec_Frames
        wram.setWord(WRAM.evtSprIdx, frames)
        wram.setWord(WRAM.objFrameOfs + c, indirectWord(WRAM.fieldE4Ptr1, frames * 3))
        wram[WRAM.objFrameBank + c] = indirect(WRAM.fieldE4Ptr1, frames * 3 + 2)
        let pal = Int(read(base + 2 + recOfs))                     // SprRec_Pal x Pal_ObjColorBytes
        wram.setWord(WRAM.objPalSrc + c, pal * 0x18)
        let anim = Int(read(base + 3 + recOfs)) * 2                // SprRec_Anim
        let first = indirectWord(WRAM.fieldE4Ptr2, anim), next = indirectWord(WRAM.fieldE4Ptr2, anim + 2)
        wram.setWord(WRAM.objAnimFacingStride + c, ((next - first) & 0xFFFF) >> 2)
        wram.setWord(WRAM.objAnimFrameTbl + c, first)
        wram.setWord(WRAM.objAnimTimeTbl + c, indirectWord(WRAM.fieldE4Ptr3, anim))
        wram[WRAM.objSprSize + c] = read(base + 4 + recOfs)
    }

    /// Evt_LoadSpriteRec (A = the record, Y = the byte before the next opcode): X comes back.
    func loadSpriteRec(record: Int, y: Int) -> Int {
        let c = objCur, saved = (y + 1) & 0xFFFF, recOfs = record * 5
        wram.setWord(WRAM.evtOpSavedPos, saved)
        wram.setWord(WRAM.evtSprRecOfs, recOfs)
        loadRecordFields(base: Self.sprRec, recOfs: recOfs)
        let gfx = Int(read(Self.sprRec + recOfs))                 // SprRec_Gfx
        wram.setWord(WRAM.evtSprIdx, gfx)
        wram.setWord(WRAM.objGfxOfs + c, indirectWord(WRAM.fieldE4Ptr0, gfx * 3))
        wram[WRAM.objGfxBank + c] = indirect(WRAM.fieldE4Ptr0, gfx * 3 + 2)
        wram.setWord(WRAM.objPrioLow + c, 0x2020)                  // EvtSpr_PrioInit
        wram[WRAM.objAnimRow + c] = 0
        wram[WRAM.objAnimColumn + c] = 0
        wram[WRAM.objFacing + c] = 1                               // Obj_FacingDown
        return saved
    }

    /// Evt_InitWramSprite: the part opcodes $82 and $83 share before their records.
    func initWramSprite(kind: UInt8, y: Int) -> Int {
        let c = objCur
        wram[WRAM.objUnk1100 + c] = kind
        wram[WRAM.objUnk1101 + c] = UInt8(data(y + 1))
        wram.setWord(WRAM.objGfxOfs + c, wram.word(WRAM.objQUnk71))
        wram.setWord(WRAM.objPrioLow + c, 0x2020)
        wram[WRAM.objGfxBank + c] = 0x7F
        wram[WRAM.objFacing + c] = 1
        wram[WRAM.objAnimRow + c] = 0
        wram[WRAM.objAnimColumn + c] = 0
        let saved = y + 2
        wram.setWord(WRAM.evtOpSavedPos, saved)
        wram[WRAM.objUnk1B01 + c] = 1
        return saved
    }

    /// Evt_FindOrAddUnk0920: (found, the owner's slot) or nil when the list is full (a halt).
    func findOrAddGraphics(key: UInt8) -> (found: Bool, owner: Int)? {
        wram[WRAM.evtUnk0920Key] = key
        for i in 0..<16 where wram[WRAM.evtUnk0920 + i] == key { return (true, Int(wram[WRAM.evtUnk0930 + i])) }
        for i in 0..<16 where wram[WRAM.evtUnk0920 + i] == 0xFF {
            wram[WRAM.evtUnk0920 + i] = key
            wram[WRAM.evtUnk0930 + i] = wram[WRAM.objCur]
            return (false, 0)
        }
        return nil
    }

    /// FieldBtlObj[0-2].GfxOfs = ObjQ_Unk71, by ObjQ_Unk73 (CMP #1: below / equal / above, signed).
    func noteBattleGraphics() {
        let n = wram[WRAM.objQUnk73], k = (n &- 1) & 0x80 != 0 ? 0 : n == 1 ? 1 : 2
        wram.setWord(WRAM.fieldBtlObjGfxOfs(k), wram.word(WRAM.objQUnk71))
    }

    /// Decomp_ToWram from the 24-bit pointer at Field_E4Ptr0 + key x 3 to bank $7F at ObjQ_Unk71;
    /// ObjQ_Unk71 then moves past it. nil when the packed data does not decode (or overflows the bank).
    func unpackGraphics(key: Int, battleNote: Bool) -> Outcome? {
        let y = key * 3
        wram.setWord(WRAM.decompSrc, indirectWord(WRAM.fieldE4Ptr0, y))
        wram.setWord(WRAM.decompDest, wram.word(WRAM.objQUnk71))
        if battleNote { noteBattleGraphics() }
        wram[WRAM.decompSrcBank] = indirect(WRAM.fieldE4Ptr0, y + 2)
        wram[WRAM.decompDestBank] = 0x7F
        let src = Int(wram[WRAM.decompSrcBank]) << 16 | wram.word(WRAM.decompSrc)
        guard let pc = Self.romOffset(src), pc < rom.count else {
            return .unmodelled(String(format: "graphics at $%06X are not in the ROM image", src))
        }
        let packed = Array(rom[pc..<min(rom.count, pc + 0x10000)])
        guard let out = try? LZSS.decompress(packed, maxOutput: 0x10000).out else {
            return .unmodelled(String(format: "graphics at $%06X do not unpack", src))
        }
        let dest = wram.word(WRAM.decompDest)
        for (i, b) in out.enumerated() { wram[0x7F0000 | ((dest + i) & 0xFFFF)] = b }
        wram.setWord(WRAM.decompOutLen, out.count & 0xFFFF)
        let end = (wram.word(WRAM.objQUnk71) + out.count) & 0xFFFF
        wram.setWord(WRAM.objQUnk71, end)
        if (end - 0x8000) & 0x8000 != 0 {
            return .halted("sprite graphics run past the end of bank $7F (Halt_ColorWramGfxFull)")
        }
        return nil
    }

    /// Evt_Op82_InitWramSprite.
    func initNpcSprite(_ y: Int) -> Outcome {
        let c = objCur, saved = initWramSprite(kind: 4, y: y)
        let recOfs = data(y + 1) * 5
        wram.setWord(WRAM.evtSprRecOfs, recOfs)
        loadRecordFields(base: Self.npcSprRec, recOfs: recOfs)
        let key = read(Self.npcSprRec + recOfs)
        guard let (found, owner) = findOrAddGraphics(key: key) else {
            return .halted("Evt_Unk0920 has no free entry (Halt_ColorUnk0920Full)")
        }
        if found {
            wram.setWord(WRAM.objGfxOfs + c, wram.word(WRAM.objGfxOfs + owner))
            noteBattleGraphics()
        } else {
            wram.setWord(WRAM.evtSprIdx, Int(key))
            if let stop = unpackGraphics(key: Int(key), battleNote: true) { return stop }
        }
        wram[WRAM.objQUnk73] &+= 1
        return .go(x: saved, carry: true)
    }

    /// Evt_Op83_InitEnemySprite.
    func initEnemySprite(_ y: Int) -> Outcome {
        let c = objCur, saved = initWramSprite(kind: 5, y: y)
        let recOfs = data(y + 1) * 10                              // EvtSpr_EnemyRecBytes
        wram.setWord(WRAM.evtSprRecOfs, recOfs)
        loadRecordFields(base: Self.enemySprRec, recOfs: recOfs)
        let key = read(Self.enemySprRec + recOfs)
        wram[WRAM.evtUnk0920Key] = key
        if wram[WRAM.objUnk1101 + c] >= 0xF8 {                     // EvtSpr_RomGfxMin: ROM graphics as they are
            wram.setWord(WRAM.evtSprIdx, Int(key))
            wram.setWord(WRAM.objGfxOfs + c, indirectWord(WRAM.fieldE4Ptr0, Int(key) * 3))
            wram[WRAM.objGfxBank + c] = indirect(WRAM.fieldE4Ptr0, Int(key) * 3 + 2)
        } else {
            guard let (found, owner) = findOrAddGraphics(key: key) else {
                return .halted("Evt_Unk0920 has no free entry (Halt_ColorUnk0920Full)")
            }
            if found {
                wram.setWord(WRAM.objGfxOfs + c, wram.word(WRAM.objGfxOfs + owner))
            } else {
                wram.setWord(WRAM.evtSprIdx, Int(key))
                if let stop = unpackGraphics(key: Int(key), battleNote: false) { return stop }
            }
        }
        // .tile_slot: the OBJ tile slot from the operand after n (8-bit index)
        let arg = UInt8(data(saved))
        wram[WRAM.evtSprSlotArg] = arg
        let t = Int((arg & 0x7F) &+ 1)
        wram[WRAM.objTileSlot + t] = wram[WRAM.objCur]
        wram[WRAM.evtSprIdx] = UInt8(t)
        let cur8 = Int(wram[WRAM.objCur])
        let pairTiles: Int = (t & 0xFE) << 4
        let oddTiles: Int = (t & 1) << 3
        wram.setWord(WRAM.objVramTile + cur8, pairTiles + oddTiles)
        wram.setWord(WRAM.objTileRecOfs + cur8, t << 5)
        if wram[WRAM.objSprSize + cur8] & 0x03 >= 3 {
            wram[WRAM.fieldUnkAEObj] = UInt8(cur8)
            loadLargeObject(cur8)
        }
        if arg & 0x80 != 0 { wram[WRAM.objUnk1100 + cur8] = 6 }   // Obj_Unk1100Kind6
        return .go(x: saved + 1, carry: true)
    }

    /// Spr_LoadLargeObj: Obj_TileBuf, Obj_LastFrame and the 24 SprTile layout
    /// records ($7F:4BC0 + Obj_TileRecOfs) from the frame data's position pairs
    /// (LargeObj_LayoutOfs). Its tile copies to the $7F:3800 buffer (SprBuf,
    /// uploaded by DMA) are not modelled: the runtime draws from the graphics.
    func loadLargeObject(_ c: Int) {
        wram.setWord(WRAM.objTileBuf + c, 0x3800)                  // SprBuf_Base
        wram[WRAM.objLastFrame + c] = 0
        let frames = Int(wram[WRAM.objFrameBank + c]) << 16 | wram.word(WRAM.objFrameOfs + c)
        let records = wram.word(WRAM.objTileRecOfs + c)
        for i in 0..<24 {
            let pair = 0xC0 + 2 * i
            let ox = read((frames + pair) & 0xFFFFFF)               // [Spr_FramePtr],Y
            let oy = read((frames + pair + 1) & 0xFFFFFF)
            let at = 0x7F4BC0 + records + 8 * i                    // SprTile[i]
            wram[at + 2] = ox
            wram[at + 3] = ox & 0x80 != 0 ? 0xFF : 0
            wram[at + 4] = oy
            let rowBase: UInt8 = [0x40, 0x60, 0x80][i / 8]         // LargeObj_TileRow0-2
            wram[at + 6] = rowBase + UInt8(2 * (i % 8))
            wram[at + 7] = 0x22                                    // LargeObj_Attr
        }
    }
}
