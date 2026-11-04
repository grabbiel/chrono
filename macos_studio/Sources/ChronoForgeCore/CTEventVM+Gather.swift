// CTEventVM+Gather.swift — Evt_OpD9_PartyWalkToTiles and Evt_OpDA_PartyGather
// ($C0:326C–$C0:353E): party members are sent off on the small scripts
// LocLoad_InitUnk7F3700 seeds at Map_Unk7F3700 (each member's position saved
// in the ObjX_Unk7F0580 table of its level, the member run at level 0), and
// the calling object waits until a counter in the event words says they
// have all arrived. The seeded scripts are ordinary opcodes ($E3 $89 $0D $0E
// $AE $95/$96 $A6 $71 $12 $11 $00), so the VM runs them as it runs the pack.
import Foundation

extension WRAM {
    /// Map_Unk7F3700: block 0 (Evt_RedirectPos, walk to the leader) and blocks
    /// 1-3 (walk to a tile: column/row at +$28, facing at +$2B of each).
    public static let mapUnk7F3700 = 0x7F3700
    public static let evtPartyWalkCount = 0x7F03FC, fieldUnk7F03FE = 0x7F03FE
    public static let objXUnk7F0C00 = 0x7F0C00, objXUnk7F0D00 = 0x7F0D00, objXUnk7F0F00 = 0x7F0F00
    public static let fieldUnkAC = dpField + 0xAC, fieldUnkAD = dpField + 0xAD
}

extension CTEventVM {
    /// Evt_Data offsets of the seeded blocks (Evt_RedirectPos, Evt_PartyWalkPos0-2).
    static let redirectPos = 0x16FF, partyWalkPos = [0x171F, 0x173F, 0x175F]

    /// LocLoad_InitUnk7F3700: the 134 bytes at $7F:3700 from LocLoad_Unk7F3700Init
    /// ($C0:5D37) with the ROM's five MVNs (each 32-byte copy reads on past its record).
    public func seedPartyBlocks() {
        guard rom.count > 0x5D6E else { return }
        let rec0 = 0x005D37, rec1 = rec0 + 25, rec4 = rec1 + 24
        let copies: [(from: Int, to: Int, count: Int)] = [(rec0, 0x3700, 32), (rec1, 0x3720, 32), (rec1, 0x3740, 32),
                                                          (rec1, 0x3760, 32), (rec4, 0x3780, 6)]
        for c in copies {
            for i in 0..<c.count { wram[0x7F0000 + c.to + i] = rom[c.from + i] }
        }
    }

    /// One member sent to a seeded block: its position saved at its level
    /// (the multiplier's level x $80 + the slot word), Obj_ScriptPos = the
    /// block, level 0. `slotWord` is Party_ObjSlot* as a 16-bit load reads it,
    /// `x` the index the handler reads the level and position with.
    func sendMember(slotWord: Int, x: Int, to pos: Int) {
        let index = (Int(wram[WRAM.objUnk1C00 + x]) * WRAM.evtPrioStride + slotWord) & 0xFFFF
        let saved = wram.word(WRAM.objScriptPos + x)
        wram[WRAM.objXSave + index] = UInt8(saved & 0xFF)
        wram[WRAM.objXSave + index + 1] = UInt8(saved >> 8)
        wram.setWord(WRAM.objScriptPos + slotWord, pos)
        let s = slotWord & 0xFF
        wram[WRAM.objUnk1C00 + s] = 0
        wram[WRAM.objUnk1A80 + s] = 0; wram[WRAM.objMoveFrames + s] = 0; wram[WRAM.objUnk1001 + s] = 0
    }

    /// The arrival bookkeeping both handlers end with: Field_UnkAC/AD =
    /// Field_UnkAB, its bytes of ObjX_Unk7F0C00/0D00/0F00 cleared.
    func gatherArrived() {
        let ab = wram[WRAM.fieldUnkAB]
        wram[WRAM.fieldUnkAC] = ab; wram[WRAM.fieldUnkAD] = ab
        for t in [WRAM.objXUnk7F0C00, WRAM.objXUnk7F0D00, WRAM.objXUnk7F0F00] { wram[t + Int(ab)] = 0 }
    }

    /// Evt_OpD9_PartyWalkToTiles: start (send each present member to its
    /// tile), wait while the count is 1-3, then wait until every present
    /// member's block has returned (Obj_Unk1C00 nonzero) and go on past the 7 bytes.
    func partyWalkToTiles(_ y: Int) -> Outcome {
        let count = wram[WRAM.evtPartyWalkCount]
        if count != 0 {
            if count < 4 { return .go(x: y, carry: false) }
            gatherArrived()
            for k in 0..<3 {
                let slot = wram[WRAM.partyObjSlot + 2 * k]
                if slot & 0x80 == 0, wram[WRAM.objUnk1C00 + Int(slot)] == 0 { return .go(x: y, carry: false) }
            }
            wram[WRAM.evtPartyWalkCount] = 0
            return .go(x: y + 7, carry: false)
        }
        wram[WRAM.fieldControlEnabled] = 0
        for k in 0..<3 {
            let at = WRAM.partyObjSlot + 2 * k
            if k > 0, wram[at] & 0x80 != 0 {
                wram[WRAM.evtPartyWalkCount] = UInt8(4 - k)              // EvtD9_Count1Sent / Count2Sent
                return .go(x: y, carry: false)
            }
            let word = wram.word(at)
            sendMember(slotWord: word, x: k == 0 ? word : Int(wram[at]), to: Self.partyWalkPos[k])
            let col = data(y + 1 + 2 * k), row = data(y + 2 + 2 * k)
            let block = WRAM.mapUnk7F3700 + 0x20 * (k + 1)
            wram[block + 0x08] = UInt8(col & 0x7F); wram[block + 0x09] = UInt8(row & 0x7F)
            let facing: UInt8 = col & 0x80 == 0 ? (row & 0x80 == 0 ? 0 : 1) : (row & 0x80 == 0 ? 2 : 3)
            wram[block + 0x0B] = facing
        }
        wram[WRAM.evtPartyWalkCount] = 1                                 // EvtD9_Count3Sent
        return .go(x: y, carry: false)
    }

    /// Evt_OpDA_PartyGather: members 2 and 3 walk to the leader (block 0);
    /// once Field_Unk7F03FE reaches 3 the handler goes on (C=1).
    func partyGather(_ y: Int) -> Outcome {
        if wram[WRAM.partyObjSlot1] & 0x80 != 0 { return .go(x: y + 1, carry: false) }
        if wram[WRAM.fieldUnk54] & 0x01 != 0 {
            if wram[WRAM.fieldUnk7F03FE] < 3 { return .go(x: y, carry: false) }
            wram[WRAM.fieldUnk54] &= ~0x01
            gatherArrived()
            return .go(x: y + 1, carry: true)
        }
        let m2 = wram.word(WRAM.partyObjSlot1)
        sendMember(slotWord: m2, x: m2 & 0xFF, to: Self.redirectPos)
        var sent = 1
        if wram[WRAM.partyObjSlot2] & 0x80 == 0 {
            let m3 = wram.word(WRAM.partyObjSlot2)
            sendMember(slotWord: m3, x: m3 & 0xFF, to: Self.redirectPos)
            sent = 2
        }
        wram[WRAM.fieldUnk7F03FE] = UInt8(3 - sent)                      // EvtDA_Count1Sent / Count2Sent
        wram[WRAM.fieldUnk54] |= 0x01                                   // Field54_Gather
        return .go(x: y, carry: false)
    }
}
