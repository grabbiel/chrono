// CTEventVMOpcodesTests.swift — the opcode families slice 3 models, on
// synthetic packs and WRAM: items and gold ($C7-$CE, $D7) through
// BankC1_RunService's services, and party membership ($CF-$D4, $D6) through
// Menu_RunCommand's party commands, the party walks ($D9, $DA), the map
// region copies ($E4, $E5), the palettes ($2E, $33, $88) with
// PalAnim_TickAll and the palette slots, and the timed and variable steps
// ($7A, $97-$9A, $9D-$9F, $A1). The ROM handlers themselves are compared
// by re_workspace/tools/ct_event_vm.py check.
import XCTest
@testable import ChronoForgeCore

final class CTEventVMOpcodesTests: XCTestCase {
    /// One object whose function 0 is `script` (at $21) after its init's $00.
    private func vm(_ script: [UInt8]) throws -> CTEventVM {
        var bytes: [UInt8] = [1]
        for f in 0..<16 {
            let at = f == 0 ? 0x20 : 0x21
            bytes += [UInt8(at & 0xFF), UInt8(at >> 8)]
        }
        bytes += [0x00] + script + [UInt8](repeating: 0, count: 16)   // jumps land on $00s
        let vm = CTEventVM(pack: try CTEventPack(bytes: bytes))
        vm.initObjects()
        for k in 0..<9 { vm.wram[WRAM.menuPartyOrder + k] = 0x80 }
        return vm
    }

    func testItemsAreAddedCountedAndRemoved() throws {
        let v = try vm([0xCA, 0x10, 0xCA, 0x10, 0xC9, 0x10, 0x0B, 0xD7, 0x10, 0x03, 0xCB, 0x10, 0xCB, 0x10, 0xC9, 0x10, 0x05])
        v.wram[WRAM.invIds] = 0x22; v.wram[WRAM.invCounts] = 4         // entry 0 holds another item
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x23, carry: true))
        XCTAssertEqual(v.wram[WRAM.invIds + 1], 0x10)                   // the first empty entry
        XCTAssertEqual(v.wram[WRAM.invCounts + 1], 1)
        _ = v.execute(at: 0x23)
        XCTAssertEqual(v.wram[WRAM.invCounts + 1], 2)
        XCTAssertEqual(v.execute(at: 0x25), .go(x: 0x28, carry: true))  // held: the next opcode
        XCTAssertEqual(v.execute(at: 0x28), .go(x: 0x2B, carry: true))
        XCTAssertEqual(v.wram[WRAM.eventWord(3)], 2)                    // the count to event word 3
        XCTAssertEqual(v.wram.word(WRAM.menuItemSlot), 1)
        _ = v.execute(at: 0x2B)
        _ = v.execute(at: 0x2D)
        XCTAssertEqual(v.wram[WRAM.invIds + 1], 0)                      // emptied at 0
        XCTAssertEqual(v.execute(at: 0x2F), .go(x: 0x31 + 5, carry: true))   // not held: the jump
        XCTAssertEqual(v.changes.map(\.opcode), [0xCA, 0xCA, 0xCB, 0xCB])
        XCTAssertEqual(v.menuRefreshes, 1)
    }

    func testAFullCountAndAFullInventory() throws {
        let v = try vm([0xCA, 0x10, 0xCA, 0x33])
        v.wram[WRAM.invIds + 5] = 0x10; v.wram[WRAM.invCounts + 5] = 99
        for k in 0..<0x100 where k != 5 { v.wram[WRAM.invIds + k] = UInt8(0x40 + k % 0x80) }
        _ = v.execute(at: 0x21)
        XCTAssertEqual(v.wram[WRAM.invCounts + 5], 99)                  // 99 stays
        v.wram[WRAM.invCounts] = 7
        _ = v.execute(at: 0x23)
        XCTAssertEqual(v.wram[WRAM.invIds], 0x33)                       // no empty entry: entry 0 is overwritten
        XCTAssertEqual(v.wram[WRAM.invCounts], 8)
    }

    func testGoldIsCappedAndNotOverdrawn() throws {
        let v = try vm([0xCD, 0x30, 0x75, 0xCE, 0x10, 0x27, 0xCC, 0x01, 0x00, 0x05])
        v.wram.setWord(WRAM.gold, 0x967F); v.wram[WRAM.goldHi] = 0x98   // 9,999,999
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x24, carry: true))
        XCTAssertEqual(Int(v.wram[WRAM.goldHi]) << 16 | v.wram.word(WRAM.gold), 0x980BAF)   // the ROM's drop under the cap
        v.wram.setWord(WRAM.gold, 0x0100); v.wram[WRAM.goldHi] = 0
        _ = v.execute(at: 0x24)                                          // 10,000 off 256: nothing changes
        XCTAssertEqual(v.wram.word(WRAM.gold), 0x0100)
        XCTAssertEqual(v.execute(at: 0x27), .go(x: 0x2B, carry: true))   // at least 1
        v.wram.setWord(WRAM.gold, 0)
        XCTAssertEqual(v.execute(at: 0x27), .go(x: 0x2A + 5, carry: true))
    }

    func testJoiningTheReserveAndTheParty() throws {
        let v = try vm([0xD0, 0x04, 0xCF, 0x04, 0x05, 0xD2, 0x04, 0x05, 0xD3, 0x04, 0xD2, 0x04, 0x05])
        v.wram[WRAM.menuPartyOrder] = 0; v.wram[WRAM.menuPartyOrder + 1] = 1
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x23, carry: false))
        XCTAssertEqual(v.wram[WRAM.menuPartyOrder + 3], 4)               // the first empty reserve place
        XCTAssertEqual(v.wram[WRAM.menuUnk29AF], 0x08)                   // BankFF_CharBits for character 4
        XCTAssertEqual(v.execute(at: 0x23), .go(x: 0x26, carry: true))   // listed
        XCTAssertEqual(v.execute(at: 0x26), .go(x: 0x28 + 5, carry: true))   // not in the party
        v.wram[WRAM.chrObjSlot + 4] = 0x0A
        v.wram[WRAM.partyObjSlot] = 0; v.wram[WRAM.partyObjSlot1] = 0x80; v.wram[WRAM.partyObjSlot2] = 0x80
        _ = v.execute(at: 0x29)
        XCTAssertEqual((0..<4).map { v.wram[WRAM.menuPartyOrder + $0] }, [0, 1, 4, 0x84])   // its reserve place emptied
        XCTAssertEqual(v.wram[WRAM.partyObjSlot1], 0x0A)                 // its object is member 2
        XCTAssertEqual(v.wram[WRAM.objQUnk78], 1)
        XCTAssertEqual(v.execute(at: 0x2B), .go(x: 0x2E, carry: true))
    }

    func testTheLeaderLeavesAndTheOthersMoveUp() throws {
        let v = try vm([0xD4, 0x02])
        for (k, c) in [UInt8(2), 0, 5].enumerated() { v.wram[WRAM.menuPartyOrder + k] = c }
        for (k, slot) in [UInt8(2), 4, 6].enumerated() {
            v.wram[WRAM.partyObjSlot + 2 * k] = slot
            v.wram[WRAM.objUnk1101 + Int(slot)] = [2, 0, 5][k]
        }
        for i in 0..<0x60 { v.wram[WRAM.palPartyRow0 + i] = UInt8(i) }
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x23, carry: true))   // the matching CMP's C=1
        XCTAssertEqual(v.wram[WRAM.objUnk1100 + 2], 3)
        XCTAssertEqual(v.wram[WRAM.objUnk1100 + 4], 0)
        XCTAssertEqual(v.wram[WRAM.objUnk1100 + 6], 1)
        XCTAssertEqual([v.wram[WRAM.partyObjSlot], v.wram[WRAM.partyObjSlot1], v.wram[WRAM.partyObjSlot2]], [4, 6, 0x80])
        XCTAssertEqual(v.wram[WRAM.palPartyRow0], 0x20)                  // rows 6, 7 moved up to 5, 6
        XCTAssertEqual(v.wram[WRAM.palPartyRow1], 0x40)
        XCTAssertEqual((0..<4).map { v.wram[WRAM.menuPartyOrder + $0] }, [0, 5, 0x85, 2])   // the third place keeps its old id under bit 7
        XCTAssertEqual(v.wram[WRAM.menuItemId], 0x00)                     // X after the palette MVNs: $2200
    }

    func testDroppingAnObjectEmptiesItsPlaceOnly() throws {
        let v = try vm([0xD6, 0x05])
        for (k, slot) in [UInt8(2), 4, 6].enumerated() {
            v.wram[WRAM.partyObjSlot + 2 * k] = slot
            v.wram[WRAM.objUnk1101 + Int(slot)] = [2, 5, 5][k]
            v.wram[WRAM.partyMembers + k] = [2, 5, 5][k]
        }
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x23, carry: true))
        XCTAssertEqual([v.wram[WRAM.partyObjSlot], v.wram[WRAM.partyObjSlot1], v.wram[WRAM.partyObjSlot2]], [2, 0x80, 6])
        XCTAssertEqual((0..<3).map { v.wram[WRAM.partyMembers + $0] }, [2, 0x80, 5])
        XCTAssertEqual(v.wram[WRAM.objUnk1100 + 4], 3)
        XCTAssertEqual(v.menuRefreshes, 0)                                // no command
    }

    func testAMapRegionIsCopiedNowOrAtTheNextRedraw() throws {
        // copy columns 2-3 of rows 1-2 to column 8, row 5: layer 1 and its bit 8
        let v = try vm([0xE4, 2, 1, 3, 2, 8, 5, 0x41, 0xE5, 2, 1, 3, 2, 8, 5, 0x02])
        for r in 1...2 { for c in 2...3 { v.wram[WRAM.mapLayer1Tiles + r << 8 + c] = UInt8(0x10 * r + c) } }
        v.wram[WRAM.mapTileHiBits + 0x0103] = 0x03                       // bit 8 of layers 1 and 2
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x29, carry: false))
        XCTAssertEqual(v.wram[WRAM.mapLayer1Tiles + 0x0508], 0x12)
        XCTAssertEqual(v.wram[WRAM.mapLayer1Tiles + 0x0609], 0x23)
        XCTAssertEqual(v.wram[WRAM.mapTileHiBits + 0x0509], 0x01)         // layer 1's bit only
        XCTAssertEqual(v.mapCopies.last?.layers, [1])
        XCTAssertEqual(v.mapCopies.last?.cells.count, 4)
        XCTAssertEqual(v.execute(at: 0x29), .go(x: 0x31, carry: false))
        XCTAssertEqual(v.wram[WRAM.fieldSceneFlags] & 0x20, 0x20)          // SceneFlag_MapRedraw
        XCTAssertEqual(v.wram[WRAM.fieldMapRedrawSel], 0x02)
        XCTAssertEqual(v.mapCopies.count, 1)                              // nothing copied yet
        XCTAssertEqual(v.copyMapRegion(), [2])
    }

    func testTheGatherWaitsForTheOthers() throws {
        let v = try vm([0xDA])
        v.wram[WRAM.partyObjSlot] = 0; v.wram[WRAM.partyObjSlot1] = 2; v.wram[WRAM.partyObjSlot2] = 0x80
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x21, carry: false))   // sent: wait here
        XCTAssertEqual(v.wram.word(WRAM.objScriptPos + 2), CTEventVM.redirectPos)
        XCTAssertEqual(v.wram[WRAM.fieldUnk7F03FE], 2)                    // one sent of two
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x21, carry: false))
        v.wram[WRAM.fieldUnk7F03FE] = 3                                   // its block's arrival
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x22, carry: true))
        XCTAssertEqual(v.wram[WRAM.fieldUnk54] & 0x01, 0)
    }

    func testColoursAreCopiedAndACycleRecordIsSetUp() throws {
        let v = try vm([0x2E, 0x80, 0x10, 0x06, 0x00, 0x11, 0x22, 0x33, 0x44, 0x2E, 0x45, 0x20, 0x04, 0x37, 0x02])
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x2A, carry: true))   // n = 6: four colour bytes
        XCTAssertEqual((0..<4).map { v.wram[WRAM.palCgramBuf + 0x20 + $0] }, [0x11, 0x22, 0x33, 0x44])
        XCTAssertEqual((0..<4).map { v.wram[WRAM.palBuf + 0x20 + $0] }, [0x11, 0x22, 0x33, 0x44])
        XCTAssertEqual(v.paletteWrites, [0x10, 0x11])
        XCTAssertEqual(v.execute(at: 0x2A), .go(x: 0x30, carry: true))
        let rec = (0..<9).map { v.wram[WRAM.fieldAnimB + $0] }
        XCTAssertEqual(rec, [0x40, 0x20, 0x04, 0x08, 0x00, 0x02, 0x05, 0x33, 0x77])
        for k in 0..<8 { v.wram[WRAM.fieldAnimB + 12 * k] = 0x10 }       // records 0-7 taken
        XCTAssertEqual(v.execute(at: 0x2A), .go(x: 0x30, carry: false))  // dropped
    }

    func testAnObjectsRecordIsLinkedAndUndone() throws {
        let v = try vm([0x88, 0x20, 0x31, 0x04, 0x88, 0x00])
        v.wram[WRAM.objOamAttr] = 0x0A                                   // palette slot 5: colour 0 = $D0
        v.wram.setWord(WRAM.objXPalAnimRec, 0xFFFF)
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x25, carry: true))
        XCTAssertEqual((0..<6).map { v.wram[WRAM.fieldAnimB + $0] }, [0x20, 0xD3, 0x01, 0x00, 0x00, 0x04])
        XCTAssertEqual(v.wram.word(WRAM.objXPalAnimRec), 0)
        v.wram[WRAM.palSpriteRows + 5 * 0x20 + 2] = 0x55
        XCTAssertEqual(v.execute(at: 0x25), .go(x: 0x27, carry: true))
        XCTAssertEqual(v.wram[WRAM.fieldAnimB], 0)                        // freed
        XCTAssertEqual(v.wram.word(WRAM.objXPalAnimRec), 0xFFFF)
        XCTAssertEqual(v.wram[WRAM.palSpriteRows + 5 * 0x20 + 2], 0)       // the 12 colours again (bank $E4: none here)
    }

    func testTheTickRotatesAndFades() throws {
        let v = try vm([])
        let up: [UInt8] = [0x30, 4, 2, 0, 0, 1], fade: [UInt8] = [0x50, 8, 1, 0x40, 0, 1, 0, 0x80, 0x00]
        for (i, b) in up.enumerated() { v.wram[WRAM.fieldAnimB + i] = b }
        for (i, b) in fade.enumerated() { v.wram[WRAM.fieldAnimB + 12 + i] = b }
        for c in 4...6 { v.wram.setWord(WRAM.palBuf + 2 * c, c - 3) }
        v.wram.setWord(WRAM.palBuf + 16, 0x7FFF)
        v.palAnimTick()
        XCTAssertEqual((4...6).map { v.wram.word(WRAM.palBuf + 2 * $0) }, [3, 1, 2])   // rotated up, the top wrapping
        XCTAssertEqual(v.wram.word(WRAM.palCgramBuf + 16), 0x1CE7)        // white x $40 / 256
        XCTAssertEqual(v.wram[WRAM.fieldAnimB + 12 + 7], 0x40)
        v.palAnimTick()
        XCTAssertEqual(v.wram.word(WRAM.palCgramBuf + 16), 0)             // level 0, not yet ended
        XCTAssertEqual(v.wram[WRAM.fieldAnimB + 12], 0x50)
        v.palAnimTick()
        XCTAssertEqual(v.wram[WRAM.fieldAnimB + 12], 0)                   // past the target: ended
    }

    func testLoadingALocationStopsThePreviousPaletteAnimations() throws {
        let v = try vm([])
        // Active fades in both script-allocated and reserved records. Colour 4
        // is in the preserved row 0, so a stale record visibly changes it.
        let record: [UInt8] = [0x50, 4, 1, 0x40, 0, 1, 0, 0x80, 0, 0x12, 0x34, 0x56]
        for k in 0..<WRAM.fieldAnimBCount {
            let at = WRAM.fieldAnimB + k * WRAM.fieldAnimBSize
            for (i, b) in record.enumerated() { v.wram[at + i] = b }
        }
        v.wram.setWord(WRAM.palBuf + 8, 0x7FFF)
        v.loadLocationPalette(0)
        for k in 0..<WRAM.fieldAnimBCount {
            let at = WRAM.fieldAnimB + k * WRAM.fieldAnimBSize
            XCTAssertEqual(v.wram[at], 0)
            XCTAssertEqual((1..<WRAM.fieldAnimBSize).map { v.wram[at + $0] }, Array(record.dropFirst()))
        }
        let colours = (0..<0x200).map { v.wram[WRAM.palCgramBuf + $0] }
        v.palAnimTick()
        v.palAnimTick()
        XCTAssertEqual((0..<0x200).map { v.wram[WRAM.palCgramBuf + $0] }, colours)
        XCTAssertTrue(v.paletteWrites.isEmpty)
    }

    func testPaletteSlotsAreClaimedSharedAndGivenBack() throws {
        let v = try vm([])
        for s in 0..<8 { v.wram[WRAM.objPalSlot + s] = 0x80 }
        for x in [2, 4] { v.wram[WRAM.objUnk1100 + x] = 3; v.wram.setWord(WRAM.objPalSrc + x, 0x1234) }
        v.wram[WRAM.objUnk1100 + 6] = 0
        v.wram.setWord(WRAM.objCur, 2)
        XCTAssertEqual(v.claimPaletteSlot(), true)
        XCTAssertEqual(v.wram[WRAM.objPalSlot], 2)
        v.wram.setWord(WRAM.objCur, 4)
        XCTAssertEqual(v.claimPaletteSlot(), true)                        // the same colours: shared
        XCTAssertEqual([v.wram[WRAM.objPalSlot], v.wram[WRAM.objPalPrev + 4], v.wram[WRAM.objPalNext + 2]], [4, 2, 4])
        XCTAssertEqual(v.wram[WRAM.objOamAttr + 4], 0)
        v.wram.setWord(WRAM.objCur, 6)
        XCTAssertEqual(v.claimPaletteSlot(), true)                        // kind 0: slot 5
        XCTAssertEqual(v.wram[WRAM.objOamAttr + 6], 0x0A)
        v.wram.setWord(WRAM.objCur, 4)
        v.releasePaletteSlot()
        XCTAssertEqual([v.wram[WRAM.objPalSlot], v.wram[WRAM.objPalNext + 2]], [2, 0x80])
        v.wram.setWord(WRAM.objCur, 2)
        v.releasePaletteSlot()
        XCTAssertEqual(v.wram[WRAM.objPalSlot], 0x80)                     // free again
        v.wram[WRAM.fieldUnk54] = 0x80
        XCTAssertNil(v.claimPaletteSlot())                                // Field_Unk54 bit 7: no slots
    }

    func testStepsFromEventWordsAndTimedSteps() throws {
        let v = try vm([0x9D, 0x01, 0x02, 0x98, 0x40, 0x06])
        v.wram[WRAM.eventWord(1)] = 0x40; v.wram[WRAM.eventWord(2)] = 5
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x21, carry: false))
        XCTAssertEqual(v.wram.word(WRAM.dpField + 0xEE), 0x40)          // Obj_Direction from event word 1
        XCTAssertEqual(v.wram[WRAM.objMoveFrames], 5)
        XCTAssertEqual(v.wram[WRAM.objUnk1A80], 1)
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x21, carry: false))   // still moving
        v.wram[WRAM.objMoveFrames] = 0
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x24, carry: true))
        XCTAssertEqual(v.wram[WRAM.objUnk1A80], 0)
        v.wram[WRAM.objUnk1100 + 0x40] = 0x80                            // the target is not there: done
        XCTAssertEqual(v.execute(at: 0x24), .go(x: 0x27, carry: true))
    }

    func testAnArcLandsWhereItStarted() throws {
        let v = try vm([0x7A, 0x05, 0x05, 0x04])
        // no ROM here: no sine or angle table, so no step and g frames
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x21, carry: false))
        XCTAssertEqual(v.wram[WRAM.objMoveFrames], 4)
        XCTAssertEqual(v.wram[WRAM.objArcGravity], 4)
        XCTAssertEqual(v.wram.word(WRAM.objVelY), 0xFFF8)                // 4 x 4 / 2 up
        XCTAssertEqual([v.wram[WRAM.objUnk1A80], v.wram[WRAM.objArcMode]], [1, 1])
        v.wram[WRAM.objMoveFrames] = 0
        XCTAssertEqual(v.execute(at: 0x21), .go(x: 0x25, carry: true))
        XCTAssertEqual([v.wram[WRAM.objUnk1A80], v.wram[WRAM.objArcMode]], [0, 0])
        XCTAssertEqual(CTEventVM.quotientLow(10 << 8, 4), 0x80)          // 640 frames keep their low byte
        XCTAssertEqual(CTEventVM.quotientLow(10 << 8, 0), 0xFF)
    }

    func testTheStepOntoAnObjectReadsYAfterItsXStep() throws {
        let v = try vm([])
        v.wram.setWord(WRAM.objPosX, 0x0480); v.wram.setWord(WRAM.objPosY, 0x0080)
        // slot $80 (an empty party place) reads its X from $7E1880, slot 0's Y ($0080, left of
        // $0480), and its Y from $7E1900-01, Obj_VelX of slots 0 and 1: $0000 before the X step, $00F0 after
        XCTAssertTrue(v.stepOntoObject(0x80))
        XCTAssertEqual(v.wram[WRAM.objVelX], 0xF0)
        XCTAssertEqual(v.wram[WRAM.objVelY], 0x10)                        // $F0 > $80: down, as the ROM reads it
    }
}
