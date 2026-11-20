// CTEventVM+Inventory.swift — the item and gold opcodes ($C7 $C9 $CA $CB $CC
// $CD $CE $D7) and the party-membership opcodes ($CF $D0 $D1 $D2 $D3 $D4
// $D6), with the services they call: BankC1_RunService's inventory and gold
// services ($C1:CFC2, through BankC1_Entry8003) and Menu_RunCommand's party
// and item-count commands ($C2:8C36, through BankC2_Entry8004). Each is a
// twin of the ChronoRET routine named beside it, down to the service's own
// bookkeeping bytes (Battle_SvcArg, Menu_CmdChar, ...), which the handler
// check compares too. Menu_RunCommand ends every command with Menu_Unk834D
// (the active members' weapon records, BankFF_UnkF958, Menu_Unk82E1): that
// refresh is not modelled; the VM counts it in `menuRefreshes`.
import Foundation

extension CTEventVM {
    /// A change to the party, the inventory or the gold, as an opcode made it.
    public struct StateChange: Equatable, Sendable {
        public var slot: Int, offset: Int, opcode: UInt8
        public var what: String
    }

    func note(_ y: Int, _ what: String) {
        changes.append(StateChange(slot: objCur, offset: y, opcode: UInt8(data(y)), what: what))
    }

    // MARK: BankC1_RunService ($C1:CFC2): the inventory and the gold

    /// BankC1_FindItem: the item's id when an entry holds it, else 0.
    func svcFindItem(_ item: Int) -> UInt8 {
        wram.setWord(WRAM.svcArg, item)
        if item == 0 { return 0 }
        for x in 0..<0x100 where wram[WRAM.invIds + x] == UInt8(item & 0xFF) { return wram[WRAM.invIds + x] }
        return 0
    }

    /// BankC1_AddItem: one more of the item (at most 99), or the first empty
    /// entry seen gets it (entry 0 when there is none).
    func svcAddItem(_ item: Int) -> UInt8 {
        wram.setWord(WRAM.svcArg, item)
        if item == 0 { return 0 }
        let id = UInt8(item & 0xFF)
        wram.setWord(WRAM.svcSlot, 0)
        wram[WRAM.svcSlotFound] = 0
        for x in 0..<0x100 {
            if wram[WRAM.invIds + x] == 0, wram[WRAM.svcSlotFound] == 0 {
                wram.setWord(WRAM.svcSlot, x)
                wram[WRAM.svcSlotFound] &+= 1
            }
            if wram[WRAM.invIds + x] == id {
                let n = wram[WRAM.invCounts + x]
                if n >= 99 { return 0 }
                wram[WRAM.invCounts + x] = n + 1
                return n + 1
            }
        }
        let x = wram.word(WRAM.svcSlot)
        wram[WRAM.invIds + x] = id
        wram[WRAM.invCounts + x] &+= 1
        return wram[WRAM.invCounts + x]
    }

    /// BankC1_RemoveItem: one fewer of the item; the entry emptied at 0.
    func svcRemoveItem(_ item: Int) -> UInt8 {
        wram.setWord(WRAM.svcArg, item)
        if item == 0 { return 0 }
        for x in 0..<0x100 where wram[WRAM.invIds + x] == UInt8(item & 0xFF) {
            let n = wram[WRAM.invCounts + x]
            if n == 0 { return 0 }
            wram[WRAM.invCounts + x] = n - 1
            if n - 1 != 0 { return n - 1 }
            wram[WRAM.invIds + x] = 0
            return 0xFF
        }
        return 0
    }

    /// BankC1_HasGold: $FF when the gold is at least the amount.
    func svcHasGold(_ amount: Int) -> UInt8 {
        wram.setWord(WRAM.svcArg, amount)
        if amount == 0 || wram.word(WRAM.gold) >= amount || wram[WRAM.goldHi] != 0 { return 0xFF }
        return 0
    }

    /// BankC1_AddGold: the 24-bit sum, its high byte held at $98 and the whole
    /// at 9,999,999 when the low word is past $967F (the ROM's quirk kept).
    func svcAddGold(_ amount: Int) -> UInt8 {
        wram.setWord(WRAM.svcArg, amount)
        if amount == 0 { return 0xFF }
        let sum = wram.word(WRAM.gold) + amount
        wram.setWord(WRAM.gold, sum & 0xFFFF)
        if sum > 0xFFFF { wram[WRAM.goldHi] &+= 1 }
        guard wram[WRAM.goldHi] >= 0x98 else { return 0xFF }
        wram[WRAM.goldHi] = 0x98
        guard wram.word(WRAM.gold) >= 0x9680 else { return 0xFF }
        wram.setWord(WRAM.gold, 0x967F)
        return 0
    }

    /// BankC1_RemoveGold: the amount off the gold unless there is less.
    func svcRemoveGold(_ amount: Int) -> UInt8 {
        wram.setWord(WRAM.svcArg, amount)
        if amount == 0 { return 0xFF }
        let low = wram.word(WRAM.gold), left = (low - amount) & 0xFFFF
        wram.setWord(WRAM.svcSlot, left)
        if low < amount {
            if wram[WRAM.goldHi] == 0 { return 0 }
            wram[WRAM.goldHi] -= 1
        }
        wram.setWord(WRAM.gold, left)
        return 0xFF
    }

    func goldText() -> String {
        String(Int(wram[WRAM.goldHi]) << 16 | wram.word(WRAM.gold))
    }

    // MARK: Menu_RunCommand ($C2:8C36): the party order and the item count

    /// Menu_RunCommand with Y and X as the handler leaves them (their low
    /// bytes reach Menu_CmdChar and Menu_ItemId): the command's result.
    func menuCommand(_ command: Int, y: Int, x: Int) -> UInt8 {
        wram[WRAM.menuCmdChar] = UInt8(y & 0xFF)
        wram[WRAM.menuItemId] = UInt8(x & 0xFF)
        let result: UInt8
        switch command {
        case 0: result = menuFindListed(limit: 3).result
        case 1: result = menuAddToParty()
        case 2: result = menuPartyToReserve()
        case 3: result = menuFindListed(limit: 9).result
        case 4: result = menuAddToReserve()
        case 5: result = menuUnlist()
        default: result = menuItemCount()
        }
        wram[WRAM.menuCmdResult] = result
        menuRefreshes += 1                                          // Menu_Unk834D
        return result
    }

    var menuChar: UInt8 { wram[WRAM.menuCmdChar] }

    /// Menu_CmdFindListed (Menu_CmdFindInParty with 3): 0 and the position, or $FF.
    func menuFindListed(limit: UInt8) -> (result: UInt8, position: Int) {
        wram[WRAM.menuCmdLimit] = limit
        for p in 0..<Int(limit) where wram[WRAM.menuPartyOrder + p] == menuChar { return (0, p) }
        return (0xFF, Int(limit))
    }

    /// Menu_CmdJoin: the character at position p, its BankFF_CharBits bit in Menu_Unk29AF.
    func menuJoin(_ p: Int) -> UInt8 {
        wram[WRAM.menuUnk29AF] |= charBit(Int(menuChar))
        wram[WRAM.menuPartyOrder + p] = menuChar
        return menuChar
    }

    /// BankFF_CharBits ($FF:F9BB): $80 >> n for characters 0-7, then 0.
    func charBit(_ n: Int) -> UInt8 {
        if rom.isEmpty { return n < 8 ? UInt8(0x80 >> n) : 0 }
        return read(0xFFF9BB + n)
    }

    /// Menu_CmdPushReserve: `a` at position 3, the reserve shifted down to its first empty place.
    func menuPushReserve(_ a: UInt8) -> UInt8 {
        var a = a
        for p in 3..<9 {
            let old = wram[WRAM.menuPartyOrder + p]
            wram[WRAM.menuPartyOrder + p] = a
            a = old
            if a & 0x80 != 0 { break }
        }
        return a
    }

    func menuAddToParty() -> UInt8 {
        _ = menuUnlist()
        for p in 0..<3 where wram[WRAM.menuPartyOrder + p] & 0x80 != 0 { return menuJoin(p) }
        let third = wram[WRAM.menuPartyOrder + 2]
        wram[WRAM.menuPartyOrder + 2] = menuChar
        return menuPushReserve(third)
    }

    func menuPartyToReserve() -> UInt8 {
        let (found, p) = menuFindListed(limit: 3)
        if found != 0 { return found }
        for q in p..<2 { wram[WRAM.menuPartyOrder + q] = wram[WRAM.menuPartyOrder + q + 1] }
        wram[WRAM.menuPartyOrder + 2] |= 0x80
        return menuPushReserve(menuChar)
    }

    func menuAddToReserve() -> UInt8 {
        if menuFindListed(limit: 9).result == 0 { return 0 }
        for p in 3..<9 where wram[WRAM.menuPartyOrder + p] & 0x80 != 0 { return menuJoin(p) }
        return wram[WRAM.menuPartyOrder + 8]
    }

    func menuUnlist() -> UInt8 {
        let (found, p) = menuFindListed(limit: 9)
        if found != 0 { return found }
        wram[WRAM.menuPartyOrder + p] |= 0x80
        return wram[WRAM.menuPartyOrder + p]
    }

    /// Menu_CmdItemCount through Menu_FindItem: the count of the first entry
    /// holding Menu_ItemId with a count, else 0.
    func menuItemCount() -> UInt8 {
        let id = wram[WRAM.menuItemId]
        for x in 0..<0x100 where wram[WRAM.invIds + x] == id && wram[WRAM.invCounts + x] != 0 {
            wram.setWord(WRAM.menuItemSlot, x)
            return wram[WRAM.invCounts + x]
        }
        return 0
    }

    func partyText() -> String {
        (0..<9).map { p -> String in
            let c = wram[WRAM.menuPartyOrder + p]
            return c & 0x80 != 0 ? "-" : String(c)
        }.joined(separator: " ")
    }

    // MARK: Handlers

    /// $C9 IfHasItem / $CC IfHasGold: the next opcode when held, else the jump at `n`.
    func ifService(_ y: Int, held: Bool, n: Int) -> Outcome {
        held ? .go(x: n + 1, carry: true) : jump(from: n)
    }

    func inventoryOp(_ op: UInt8, _ y: Int) -> Outcome {
        switch op {
        case 0xC9:
            return ifService(y, held: svcFindItem(data(y + 1)) != 0, n: y + 2)
        case 0xCA, 0xC7:
            let item = op == 0xCA ? data(y + 1) : Int(wram[eventWord(data(y + 1))])
            let n = svcAddItem(item)
            note(y, n == 0 ? String(format: "item $%02X not added", item) : String(format: "item $%02X +1 (now %d)", item, n))
            return .go(x: y + 2, carry: true)
        case 0xCB:
            let item = data(y + 1), n = svcRemoveItem(item)
            note(y, n == 0 ? String(format: "item $%02X not held", item)
                 : String(format: "item $%02X -1 (now %d)", item, n == 0xFF ? 0 : Int(n)))
            return .go(x: y + 2, carry: true)
        case 0xCC:
            return ifService(y, held: svcHasGold(dataWord(y + 1)) != 0, n: y + 3)
        case 0xCD, 0xCE:
            let amount = dataWord(y + 1)
            let ok = op == 0xCD ? svcAddGold(amount) : svcRemoveGold(amount)
            let sign = op == 0xCD ? "+" : "-"
            note(y, "gold \(sign)\(amount)\(ok == 0 ? (op == 0xCD ? " (capped)" : " (not enough)") : "") = \(goldText())")
            return .go(x: y + 3, carry: true)
        default:                                                    // $D7 GetItemCount
            let count = menuCommand(0x0C, y: y, x: data(y + 1))
            wram[eventWord(data(y + 2))] = count
            return .go(x: y + 3, carry: true)
        }
    }

    func membershipOp(_ op: UInt8, _ y: Int) -> Outcome {
        let char = data(y + 1)
        switch op {
        case 0xD2, 0xCF:                                            // IfCharInParty / IfCharListed
            let found = menuCommand(op == 0xD2 ? 0 : 3, y: char, x: y + 2)
            return found == 0 ? .go(x: y + 3, carry: true) : jump(from: y + 2)
        case 0xD0, 0xD1:                                            // AddCharToReserve / UnlistChar
            _ = menuCommand(op == 0xD0 ? 4 : 5, y: char, x: y + 2)
            note(y, String(format: "character %d %@: %@", char, op == 0xD0 ? "to the reserve" : "unlisted", partyText()))
            return .go(x: y + 2, carry: false)
        case 0xD3: return addCharToParty(y, char)
        case 0xD4: return moveCharToReserve(y, char)
        default: return dropCharObj(y, char)
        }
    }

    /// Evt_OpD3_AddCharToParty: command 1, then the character's object (if
    /// any) becomes member 2, or member 3 when member 2 is there.
    func addCharToParty(_ y: Int, _ char: Int) -> Outcome {
        wram.setWord(WRAM.evtCharId, char)
        _ = menuCommand(1, y: char, x: y + 2)
        wram[WRAM.objQUnk78] = 1                                    // ObjQ_Unk78Set1
        let obj = wram[WRAM.chrObjSlot + char]
        if obj & 0x80 == 0 {
            wram[WRAM.evtCharObj] = obj
            wram[wram[WRAM.partyObjSlot1] & 0x80 != 0 ? WRAM.partyObjSlot1 : WRAM.partyObjSlot2] = obj
        }
        note(y, String(format: "character %d joins: %@", char, partyText()))
        return .go(x: y + 2, carry: false)
    }

    /// The handlers' party-palette moves (MVN of one 32-byte row in bank $7E).
    func copyPaletteRow(from: Int, to: Int) {
        for i in 0..<0x20 { wram[to + i] = wram[from + i] }
    }

    /// Evt_OpD4_MoveCharToReserve, path by path; X (its low byte reaches
    /// Menu_ItemId) and C (the last CMP's) as the handler leaves them.
    func moveCharToReserve(_ y: Int, _ char: Int) -> Outcome {
        wram[WRAM.evtCharId] = UInt8(char)
        var x = y + 2, carry = false
        func test(_ slot: UInt8) -> Bool {
            x = Int(slot)
            let c = Int(wram[WRAM.objUnk1101 + x])
            carry = c >= char
            return c == char
        }
        func shiftMembers3() {                                      // .member2_shift
            wram[WRAM.partyObjSlot1] = wram[WRAM.partyObjSlot2]
            wram[WRAM.partyObjSlot2] = 0x80
            copyPaletteRow(from: WRAM.palPartyRow2, to: WRAM.palPartyRow1)
            x = (WRAM.palPartyRow2 + 0x20) & 0xFFFF
        }
        let leader = wram[WRAM.partyObjSlot], m2 = wram[WRAM.partyObjSlot1]
        if leader & 0x80 == 0, test(leader) {
            wram[WRAM.objUnk1100 + x] = 3                           // Obj_Unk1100Out
            if m2 & 0x80 == 0 {
                x = Int(m2); wram[WRAM.objUnk1100 + x] = 0
                let m3 = wram[WRAM.partyObjSlot2]
                if m3 & 0x80 == 0 { x = Int(m3); wram[WRAM.objUnk1100 + x] = 1 }
            }
            wram[WRAM.partyObjSlot] = wram[WRAM.partyObjSlot1]
            wram[WRAM.partyObjSlot1] = wram[WRAM.partyObjSlot2]
            wram[WRAM.partyObjSlot2] = 0x80
            copyPaletteRow(from: WRAM.palPartyRow1, to: WRAM.palPartyRow0)
            copyPaletteRow(from: WRAM.palPartyRow2, to: WRAM.palPartyRow1)
            x = (WRAM.palPartyRow2 + 0x20) & 0xFFFF
        } else if m2 & 0x80 != 0 {
            shiftMembers3()                                         // the quirk: no member 2
        } else if test(m2) {
            wram[WRAM.objUnk1100 + x] = 3
            let m3 = wram[WRAM.partyObjSlot2]
            if m3 & 0x80 == 0 { x = Int(m3); wram[WRAM.objUnk1100 + x] = 1 }
            shiftMembers3()
        } else {
            let m3 = wram[WRAM.partyObjSlot2]
            if m3 & 0x80 == 0, test(m3) {
                wram[WRAM.objUnk1100 + x] = 3
                wram[WRAM.partyObjSlot2] |= 0x80
            }
        }
        _ = menuCommand(2, y: char, x: x)
        note(y, String(format: "character %d to the reserve: %@", char, partyText()))
        return .go(x: y + 2, carry: carry)
    }

    /// Evt_OpD6_DropCharObj: the first member whose object is the character
    /// leaves (Obj_Unk1100 = 3) and its place is emptied; nothing moves up.
    func dropCharObj(_ y: Int, _ char: Int) -> Outcome {
        wram[WRAM.evtCharId] = UInt8(char)
        var carry = false
        for k in 0..<3 {
            let slot = wram[WRAM.partyObjSlot + 2 * k]
            if slot & 0x80 != 0 { continue }
            let c = Int(wram[WRAM.objUnk1101 + Int(slot)])
            carry = c >= char
            guard c == char else { continue }
            wram[WRAM.objUnk1100 + Int(slot)] = 3
            wram[WRAM.partyObjSlot + 2 * k] = 0x80
            wram[WRAM.partyMembers + k] = 0x80
            note(y, String(format: "character %d's object leaves party place %d", char, k + 1))
            break
        }
        return .go(x: y + 2, carry: carry)
    }
}
