// CTFieldRuntimeTests.swift — the embedded runtime: the party-control
// handler and its field hooks on a synthetic pack, input scripts, and (with
// the local ROM) locations run headless: talking, blocking, a warp that keeps
// WRAM, the debugger's flag log and breakpoints, and the picture.
import XCTest
@testable import ChronoForgeCore

final class CTFieldRuntimeTests: XCTestCase {
    /// One object whose function 0 is `script` after its init's $00.
    private func pack(_ script: [UInt8]) throws -> CTEventPack {
        let start = 0x20
        var bytes: [UInt8] = [1]
        for f in 0..<16 {
            let at = f == 0 ? start : start + 1
            bytes += [UInt8(at & 0xFF), UInt8(at >> 8)]
        }
        bytes += [0x00] + script
        return try CTEventPack(bytes: bytes)
    }

    func testPartyControlAsksTheFieldAndStays() throws {
        let vm = CTEventVM(pack: try pack([0xB0, 0x00]))
        vm.initObjects()
        vm.wram[WRAM.objUnk1100] = 0
        vm.wram[WRAM.fieldUnkEB] = 6
        var asked: [CTEventVM.PartyRequest] = []
        vm.party = { asked.append($0) }
        vm.runSteps(slot: 0)
        let expected: [CTEventVM.PartyRequest] = [.step(kind: 0, slot: 0), .touch(target: 6)]
        XCTAssertEqual(asked, expected)
        XCTAssertEqual(vm.wram[WRAM.objMoveFrames], 1)
        XCTAssertEqual(vm.wram.word(WRAM.objScriptPos), 0x21)
        let saved = vm.wram.word(WRAM.evtOpSavedPos)
        XCTAssertEqual(saved, 0x21)
    }

    func testPartyControlWaitsForTheScrollStepAndSkipsOtherKinds() throws {
        let vm = CTEventVM(pack: try pack([0xB0, 0x00]))
        vm.initObjects()
        var asked: [CTEventVM.PartyRequest] = []
        vm.party = { asked.append($0) }
        vm.wram[WRAM.fieldUnk38] = 1
        vm.wram[WRAM.objUnk1100] = 0
        vm.runSteps(slot: 0)
        vm.wram[WRAM.fieldUnk38] = 0
        vm.wram[WRAM.objUnk1100] = 4
        vm.runSteps(slot: 0)
        XCTAssertEqual(asked, [])
        XCTAssertEqual(vm.wram[WRAM.objMoveFrames], 0)
        vm.wram[WRAM.objUnk1100] = 2
        vm.wram[WRAM.fieldUnkEB] = 6
        vm.runSteps(slot: 0)
        let expected: [CTEventVM.PartyRequest] = [.step(kind: 2, slot: 0)]
        XCTAssertEqual(asked, expected)
    }

    func testPartyControlOnceMovesOn() throws {
        let vm = CTEventVM(pack: try pack([0xAF, 0x00]))
        vm.initObjects()
        vm.wram[WRAM.objUnk1100] = 1
        let outcome = vm.execute(at: 0x21)
        XCTAssertEqual(outcome, .go(x: 0x22, carry: false))
    }

    func testInputScripts() throws {
        let s = try CTFieldInput.parse("0-2 right+b; 5 a  # talk\n7-8 up")
        XCTAssertEqual(s.held(at: 1), [.right, .b])
        XCTAssertEqual(s.held(at: 5), [.a])
        XCTAssertEqual(s.held(at: 4), [])
        XCTAssertEqual(s.held(at: 8), [.up])
        XCTAssertEqual(s.lastFrame, 8)
        XCTAssertThrowsError(try CTFieldInput.parse("3 jump"))
        XCTAssertThrowsError(try CTFieldInput.parse("5-2 a"))
        XCTAssertThrowsError(try CTFieldInput.parse("right"))
    }

    // MARK: ROM

    private func rom() throws -> [UInt8] {
        var rom = [UInt8](try Repo.romData())
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        return rom
    }

    private func run(_ field: CTFieldRuntime, _ script: String, frames: Int) throws {
        let s = try CTFieldInput.parse(script)
        for f in 0..<frames { try field.step(input: s.held(at: f)) }
    }

    func testTalkingOpensAndClosesAMessage() throws {
        let field = try CTFieldRuntime(rom: try rom(), location: 7)
        try field.start()
        try run(field, "0-19 up; 20 a", frames: 45)
        XCTAssertEqual(field.messages.count, 1)
        let m = try XCTUnwrap(field.messages.first)
        XCTAssertEqual(m.slot, 16)
        XCTAssertNil(m.error)
        XCTAssertNotNil(field.dialogue)
        let leader = Int(field.vm.wram[WRAM.partyObjSlot])
        XCTAssertEqual(field.vm.wram[WRAM.objFacing + leader], 0)
        // A press every 10 frames pages the box to its end; no press after.
        let pages = try CTFieldInput.parse("50 a; 60 a; 70 a; 80 a")
        for f in 45..<89 { try field.step(input: pages.held(at: f)) }
        XCTAssertNil(field.dialogue)
        XCTAssertEqual(field.messages.count, 1)
        XCTAssertEqual(field.messages.first?.closedAt, 82)
        XCTAssertEqual(field.vm.wram[WRAM.fieldUnk29], 0)
    }

    func testTheLeaderWalksAndStopsAtABlockedTile() throws {
        let field = try CTFieldRuntime(rom: try rom(), location: 1)
        try field.start()
        let leader = Int(field.vm.wram[WRAM.partyObjSlot])
        let y0 = field.vm.wram.word(WRAM.objPosY + leader)
        try run(field, "0-59 down", frames: 1)
        let y1 = field.vm.wram.word(WRAM.objPosY + leader)
        XCTAssertEqual(y1 - y0, 0x10)
        XCTAssertEqual(field.vm.wram[WRAM.objFacing + leader], 1)
        let rest = try CTFieldInput.parse("0-59 down")
        for f in 1..<60 { try field.step(input: rest.held(at: f)) }
        let y60 = field.vm.wram.word(WRAM.objPosY + leader)
        XCTAssertEqual(y60 - y0, 0x60)
        XCTAssertEqual(field.vm.wram[WRAM.mapUnk1D33], 0)
    }

    func testAnExitWarpsAndKeepsWRAM() throws {
        let field = try CTFieldRuntime(rom: try rom(), location: 74)
        try field.start()
        field.vm.wram[0x7F01FE] = 0x5A
        try run(field, "0-59 up", frames: 60)
        let w = try XCTUnwrap(field.warps.first)
        XCTAssertEqual(w.from, 74)
        XCTAssertEqual(w.to, 77)
        XCTAssertEqual(w.frame, 32)
        XCTAssertEqual(field.location, 77)
        XCTAssertEqual(field.vm.wram[0x7F01FE], 0x5A)
        XCTAssertEqual(field.vm.wram.word(WRAM.locId), 77)
        XCTAssertEqual(field.vm.wram.word(WRAM.locReturnId), 74)
    }

    func testDebuggerLogsFlagChangesAndStopsOnBreakpoints() throws {
        let field = try CTFieldRuntime(rom: try rom(), location: 29)
        let dbg = CTFieldDebugger(field: field)
        dbg.breakpoints = [.flag(address: 0x7F0190, bit: 0)]
        try field.start()
        let hit = try XCTUnwrap(try dbg.step(input: []))
        XCTAssertEqual(hit.breakpoint, .flag(address: 0x7F0190, bit: 0))
        XCTAssertEqual(hit.opcode, 0x65)
        let change = try XCTUnwrap(dbg.changes.first { $0.address == 0x7F0190 })
        XCTAssertEqual(change.old, 0)
        XCTAssertEqual(change.new, 1)
        XCTAssertEqual(change.object, hit.object)

        let field2 = try CTFieldRuntime(rom: try rom(), location: 7)
        let dbg2 = CTFieldDebugger(field: field2)
        try field2.start()
        let leader = Int(field2.vm.wram[WRAM.partyObjSlot])
        let at = field2.vm.wram.word(WRAM.objScriptPos + leader)
        dbg2.breakpoints = [.instruction(offset: at, object: leader / 2)]
        let hit2 = try XCTUnwrap(try dbg2.run(frames: 10, script: .init(entries: [])))
        XCTAssertEqual(hit2.object, leader / 2)
        XCTAssertEqual(hit2.offset, at)
        XCTAssertEqual(field2.frameCount, 1)
    }

    func testThePictureDrawsTheObjects() throws {
        let field = try CTFieldRuntime(rom: try rom(), location: 7)
        try field.start()
        try run(field, "0-19 up; 20 a", frames: 40)
        let (picture, sprites) = CTFieldPicture.frame(field, base: nil)
        XCTAssertGreaterThanOrEqual(sprites.count, 5)
        let leader = Int(field.vm.wram[WRAM.partyObjSlot]) / 2
        XCTAssertTrue(sprites.contains { $0.object == leader })
        XCTAssertEqual(picture.lines[0].obsel, 0)
        let rgba = try XCTUnwrap(CTFieldPicture.dialogue(field))
        let alphas: [Int] = Array(stride(from: 3, to: rgba.count, by: 4))
        let alpha: Int = alphas.filter { rgba[$0] != 0 }.count
        XCTAssertGreaterThan(alpha, 256 * 40)
        XCTAssertLessThan(alpha, 256 * 224)
    }

    func testSummaryNamesTheLimitations() throws {
        let field = try CTFieldRuntime(rom: try rom(), location: 1)
        try field.start()
        try run(field, "0-9 left", frames: 10)
        let s = field.summary()
        XCTAssertEqual(s.location, 1)
        XCTAssertEqual(s.frames, 10)
        XCTAssertEqual(s.limitations, CTFieldRuntime.limitations)
        XCTAssertEqual(s.objects.count, field.vm.pack.objectCount)
    }
}
