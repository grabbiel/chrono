// CTEventVM+Party.swift — Evt_OpB0_PartyControl / Evt_OpAF_PartyControlOnce:
// the party members' scripts hand each frame to the field's party routines.
// The VM models the handler; the routines themselves (Party_Unk9E29 leader
// step, Party_UnkA26B/A2CE followers, Evt_StartTargetFunc2 touch start) are
// field work, run through `party` when a field is attached.
import Foundation

extension CTEventVM {
    /// What a party-control step asks the field to do this frame.
    public enum PartyRequest: Equatable, Sendable {
        /// Party_Unk9E29 (kind 0), Party_UnkA26B (kind 1), Party_UnkA2CE (kind 2).
        case step(kind: Int, slot: Int)
        /// Evt_StartTargetFunc2 for the object Field_UnkEB names (kind 0 only).
        case touch(target: Int)
    }

    func partyControl(_ y: Int) -> Outcome {
        if wram[WRAM.fieldUnk38] != 0 { return .go(x: y, carry: false) }
        wram.setWord(WRAM.evtOpSavedPos, y)                        // EvtCtl_SavedY
        let kind = Int(wram[WRAM.objUnk1100 + objCur])
        guard kind <= 2 else { return .go(x: y, carry: false) }
        wram[WRAM.objMoveFrames + objCur] = 1
        party?(.step(kind: kind, slot: objCur))
        if kind == 0, wram[WRAM.fieldUnkEB] & 0x80 == 0 {           // Evt_HasActionTarget
            party?(.touch(target: Int(wram[WRAM.fieldUnkEB])))
        }
        return .go(x: y, carry: false)
    }
}
