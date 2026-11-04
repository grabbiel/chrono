// CTFieldProbesTests.swift — the leader's collision on a synthetic 16 x 16
// map of level-1 tiles: a straight step cut by a level-0 column, the corner
// slide walking up past a blocked corner (and the no-CLC carry that turns it
// into a sidestep one pixel on), an exit from the map's records with its $3F
// row limit, and Map_InitEntryTile's priorities. The ROM routines themselves
// are compared by `ct_event_vm.py routines` (mapLeaderProbes ... mapEntryTile).
import XCTest
@testable import ChronoForgeCore

final class CTFieldProbesTests: XCTestCase {
    /// Every tile level 1, no exits or treasure; the leader in slot 0 at
    /// (`x`, `y`), no followers, one other object slot (empty).
    private func vm(x: Int = 0x0880, y: Int = 0x0880) throws -> CTEventVM {
        let v = CTEventVM(pack: try CTEventPack(bytes: [0]))
        v.wram[WRAM.mapColMask1] = 0x0F; v.wram[WRAM.mapRowMask1] = 0x0F
        for r in 0..<16 {
            for c in 0..<16 {
                let i = r * WRAM.mapRowStride + c
                v.wram[WRAM.mapTileAttrB + i] = 0x01
                v.wram[WRAM.mapTileExitIdx + i] = 0x80; v.wram[WRAM.mapTreasureIdx + i] = 0x80
            }
        }
        v.wram[WRAM.fieldUnk55] = 1
        v.wram[WRAM.evtObjCount] = 2
        v.wram[WRAM.partyObjSlot] = 0; v.wram[WRAM.partyObjSlot1] = 0x80; v.wram[WRAM.partyObjSlot2] = 0x80
        v.wram.setWord(WRAM.objPosX, x); v.wram.setWord(WRAM.objPosY, y)
        return v
    }

    private func block(_ v: CTEventVM, column c: Int, row r: Int) {
        v.wram[WRAM.mapTileAttrB + r * WRAM.mapRowStride + c] = 0              // level 0
    }

    private func probe(_ v: CTEventVM, step: (UInt8, UInt8)) -> (UInt8, UInt8) {
        v.wram[WRAM.mapUnk1D2E] = step.0; v.wram[WRAM.mapUnk1D30] = step.1
        v.leaderProbes()
        return (v.wram[WRAM.mapUnk1D2E], v.wram[WRAM.mapUnk1D30])
    }

    func testAStepIntoALevelZeroColumnIsCut() throws {
        let v = try vm()
        XCTAssertTrue(probe(v, step: (0x10, 0)) == (0x10, 0))                 // the box's right edge reaches $0900
        for r in 0..<16 { block(v, column: 9, row: r) }
        XCTAssertTrue(probe(v, step: (0x10, 0)) == (0, 0))
        XCTAssertTrue(probe(v, step: (0xF0, 0)) == (0xF0, 0))                 // away from it: kept
    }

    func testWalkingUpPastABlockedCornerSlidesSideways() throws {
        // The box's top edge in row 7, its right corner in column 9 (blocked).
        var v = try vm(x: 0x089E, y: 0x0860)
        block(v, column: 9, row: 7)
        XCTAssertTrue(probe(v, step: (0, 0xF0)) == (0xF0, 0xF0))              // slide left while walking up
        // One pixel on, the slide's probe (X + $70 - $10 and the ADC's carry)
        // lands on $0900: blocked, so the Y step is dropped and it sidesteps.
        v = try vm(x: 0x089F, y: 0x0860)
        block(v, column: 9, row: 7)
        XCTAssertTrue(probe(v, step: (0, 0xF0)) == (0xF0, 0))
        // Both corners blocked: no step at all.
        v = try vm(x: 0x089E, y: 0x0860)
        block(v, column: 9, row: 7); block(v, column: 8, row: 7)
        XCTAssertTrue(probe(v, step: (0, 0xF0)) == (0, 0))
    }

    func testAnExitTileTakesItsRecordWithinTheRowLimit() throws {
        let v = try vm()
        v.wram[WRAM.mapTileExitIdx + 8 * WRAM.mapRowStride + 8] = 0
        v.exitRecords = [[8, 0x47, 0, 0x34, 0x03, 0x10, 0x20]]               // column 8, row $3F away: not taken
        _ = probe(v, step: (0, 0x10))
        XCTAssertEqual(v.wram[WRAM.fieldSceneFlags] & 0x80, 0)
        v.exitRecords = [[8, 0x46, 0, 0x34, 0x03, 0x10, 0x20]]               // $3E away
        _ = probe(v, step: (0, 0x10))
        XCTAssertEqual(v.wram[WRAM.fieldSceneFlags] & 0x80, 0x80)
        XCTAssertEqual(v.wram.word(WRAM.locDestId), 0x134)
        XCTAssertEqual(v.wram[WRAM.locDestFacing], 1)
        XCTAssertEqual(v.wram[WRAM.locDestX], 0x10); XCTAssertEqual(v.wram[WRAM.locDestX + 1], 0x20)
        v.wram[WRAM.fieldSceneFlags] = 0
        v.exitRecords = []                                                    // an index past the records: none
        _ = probe(v, step: (0, 0x10))
        XCTAssertEqual(v.wram[WRAM.fieldSceneFlags] & 0x80, 0)
    }

    func testTheEntryTileSetsTheLevelAndEveryonesPriority() throws {
        let v = try vm()
        v.wram[WRAM.partyObjSlot1] = 2; v.wram[WRAM.partyObjSlot2] = 4
        v.wram[WRAM.locEntryX] = 3; v.wram[WRAM.locEntryY] = 5
        v.wram[WRAM.mapTileAttrB + 5 * WRAM.mapRowStride + 3] = 0x40          // level 0, high priority bit
        v.initEntryTile()
        XCTAssertEqual(v.wram[WRAM.fieldUnk55], 1)                            // level 0 counts as 1
        XCTAssertEqual(v.wram[WRAM.objPrioLow], 0x20); XCTAssertEqual(v.wram[WRAM.objPrioHigh], 0x30)
        for s in [2, 4] {                                                     // the followers: Map_ProbePrioHi twice
            XCTAssertEqual(v.wram[WRAM.objPrioLow + s], 0x30); XCTAssertEqual(v.wram[WRAM.objPrioHigh + s], 0x30)
        }
    }
}
