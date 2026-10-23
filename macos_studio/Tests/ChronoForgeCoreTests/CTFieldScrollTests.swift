// CTFieldScrollTests.swift — the camera routines on synthetic map pages: the
// centre-line rule of Map_StepStop*, a scroll-to arriving on a 16-pixel
// boundary, the accumulators' split, and Field_Unk885A's step to the cell
// boundary. The ROM routines themselves are compared by
// `ct_event_vm.py routines` (mapLeaderSteps ... mapRecentre).
import XCTest
@testable import ChronoForgeCore

final class CTFieldScrollTests: XCTestCase {
    /// A 64 x 64 metatile map, the view at tile column `x` / row `y` (8-pixel
    /// units), the leader in slot 0 at screen `screen`.
    private func vm(x: UInt8 = 0x20, y: UInt8 = 0x20, screen: (UInt8, UInt8) = (0x80, 0x88)) throws -> CTEventVM {
        let v = CTEventVM(pack: try CTEventPack(bytes: [0]))
        v.wram[WRAM.mapLimitLeft] = 0; v.wram[WRAM.mapLimitRight] = 0x3F
        v.wram[WRAM.mapLimitTop] = 0; v.wram[WRAM.mapLimitBottom] = 0x3F
        v.wram[WRAM.mapTileOriginX] = x; v.wram[WRAM.mapUnk1D0C] = x + 0x20
        v.wram[WRAM.mapTileOriginY] = y; v.wram[WRAM.mapUnk1D10] = y + 0x1C
        v.wram[WRAM.partyObjSlot] = 0
        v.wram[WRAM.objScreenX] = screen.0; v.wram[WRAM.objScreenY] = screen.1
        return v
    }

    private func frame(_ v: CTEventVM, step: (UInt8, UInt8) = (0, 0)) {
        v.wram[WRAM.mapUnk1D2E] = step.0; v.wram[WRAM.mapUnk1D30] = step.1
        v.dropCameraSteps(); v.accumulateScroll(); v.stepScroll()
    }

    func testTheCameraFollowsOnlyPastTheScreensMiddle() throws {
        let v = try vm(screen: (0x80, 0x88))
        frame(v, step: (0x10, 0x10))                                    // at the middle: both dropped
        XCTAssertEqual(v.cameraPixels.x, 0x100); XCTAssertEqual(v.cameraPixels.y, 0x100)
        v.wram[WRAM.objScreenX] = 0x81; v.wram[WRAM.objScreenY] = 0x89
        frame(v, step: (0x10, 0x10))
        XCTAssertEqual(v.cameraPixels.x, 0x101); XCTAssertEqual(v.cameraPixels.y, 0x101)
        frame(v, step: (0xF0, 0xF0))                                    // back while right of / below it: dropped
        XCTAssertEqual(v.cameraPixels.x, 0x101); XCTAssertEqual(v.cameraPixels.y, 0x101)
        v.wram[WRAM.objScreenX] = 0x7F; v.wram[WRAM.objScreenY] = 0x87
        frame(v, step: (0xE0, 0xE0))                                    // running: 2 pixels
        XCTAssertEqual(v.cameraPixels.x, 0xFF); XCTAssertEqual(v.cameraPixels.y, 0xFF)
        XCTAssertEqual(v.wram[WRAM.mapTileOriginX], 0x1F)
        XCTAssertEqual(v.wram[WRAM.mapUnk1D0C], 0x3F)
    }

    func testTheCameraStopsAtTheMapsEdge() throws {
        let v = try vm(x: 0x60, screen: (0xC0, 0x88))                   // 1D0C / 2 = $40 > the right limit
        frame(v, step: (0x10, 0))
        XCTAssertEqual(v.cameraPixels.x, 0x300)
        v.wram[WRAM.mapUnk1D0C] = 0x7E; v.wram[WRAM.mapTileOriginX] = 0x5E   // at the limit: up to fine $0F
        for _ in 0..<20 { frame(v, step: (0x10, 0)) }
        XCTAssertEqual(v.wram[WRAM.mapFine1X], 0x0F)
        XCTAssertEqual(v.cameraPixels.x, 0x5E * 8 + 15)
    }

    func testAScrollToArrivesOnASixteenPixelBoundary() throws {
        let v = try vm()
        v.wram[WRAM.mapScrollToMode] = 1
        v.wram[WRAM.mapScrollToX] = 0x22; v.wram[WRAM.mapScrollToY] = 0x1E
        var frames = 0
        while v.wram[WRAM.mapScrollToMode] == 1 && frames < 100 { frame(v); frames += 1 }
        XCTAssertEqual(v.wram[WRAM.mapScrollToMode], 2)
        XCTAssertEqual(frames, 17)                                      // 16 pixels each way, then the arrival
        XCTAssertEqual(v.cameraPixels.x, 0x110); XCTAssertEqual(v.cameraPixels.y, 0xF0)
        XCTAssertEqual(v.wram[WRAM.mapScrollToDone], 0)
    }

    func testTheAccumulatorsKeepTheirRemainder() throws {
        let v = try vm()
        v.wram[WRAM.mapDrift1X] = 0x08; v.wram[WRAM.mapDriftTimer] = 2
        v.wram[WRAM.mapOwnStepFlags] = 0x02; v.wram[WRAM.mapOwnStep2X] = 0xF8
        v.wram[WRAM.mapUnk1D2E] = 0x10
        v.accumulateScroll()
        XCTAssertEqual(v.wram[WRAM.mapMove1XNeg + 1], 1)                // set 1: $18 = 1 pixel, $8 left
        XCTAssertEqual(v.wram[WRAM.mapAcc1X], 0x08)
        XCTAssertEqual(v.wram[WRAM.mapMove1XNeg + 4], 0)                // set 2: its own -$08 only
        XCTAssertEqual(v.wram[WRAM.mapAcc1X + 2], 0xF8)
        v.accumulateScroll()
        XCTAssertEqual(v.wram[WRAM.mapMove1XNeg + 4], 1)                // -$10: a pixel back
        XCTAssertEqual(v.wram[WRAM.mapDrift1X], 0)                      // the timer ran out
    }

    func testTheRedrawStepEndsOnTheCellBoundary() throws {
        let v = try vm(screen: (0x90, 0x40))
        v.wram[WRAM.mapFine1X] = 5; v.wram[WRAM.mapScroll1X] = 5
        v.wram[WRAM.fieldUnk38] = 1
        var frames = 0
        while v.wram[WRAM.fieldUnk38] != 0 && frames < 40 { v.recentreStep(); frames += 1 }
        XCTAssertEqual(frames, 12)                                      // 11 pixels right, then done
        XCTAssertEqual(v.wram[WRAM.mapFine1X], 0)
        XCTAssertEqual(v.wram[WRAM.mapTileOriginX], 0x22)
    }
}
