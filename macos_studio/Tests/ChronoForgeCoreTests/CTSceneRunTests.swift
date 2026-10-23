// CTSceneRunTests.swift — the Scene Director's VM timeline (CTSceneRun): bars
// from handler runs, flags by name, the battle hand-off's enemy list on a
// synthetic WRAM, and (with the local ROM) locations run headless against the
// field's own trace, story flags that turn a branch, and named battles.
import XCTest
@testable import ChronoForgeCore

final class CTSceneRunTests: XCTestCase {
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

    /// The VM run frame by frame with the same recording CTSceneRun keeps.
    private func steps(_ p: CTEventPack, frames: Int) -> [CTSceneRun.Step] {
        let vm = CTEventVM(pack: p)
        var out: [CTSceneRun.Step] = [], frame = -1
        vm.trace = { e in
            var s = CTSceneRun.Step(frame: frame, object: e.slot / 2, offset: e.offset, opcode: Int(e.opcode), level: 7,
                                    next: nil, carry: false, stop: nil)
            switch e.outcome {
            case .go(let x, let c): s.next = x; s.carry = c
            case .unmodelled(let why), .halted(let why): s.stop = why
            }
            out.append(s)
        }
        vm.initObjects()
        for f in 0..<frames { frame = f; vm.frame() }
        return out
    }

    func testAWaitIsABarAsLongAsItsRunsOnTheScriptTimer() throws {
        // $AD 3: wait three runs; the object runs every 4 frames (Obj_Unk1000 = 4), then $B2 holds.
        let p = try pack([0xAD, 0x03, 0xB2])
        let (lanes, _) = CTSceneRun.derive(steps(p, frames: 40), pack: p)
        let bars = try XCTUnwrap(lanes.first).bars
        let wait = try XCTUnwrap(bars.first { $0.opcode == 0xAD })
        XCTAssertEqual(wait.start, 0)
        XCTAssertEqual(wait.end, 12)
        XCTAssertEqual(wait.runs, 4)
        XCTAssertEqual(wait.duration, 12)
        let hold = try XCTUnwrap(bars.last)
        XCTAssertEqual(hold.opcode, 0xB2)
        XCTAssertNil(hold.end)
        XCTAssertEqual(hold.start, 12)
    }

    func testConditionsRecordWhetherTheyJumped() throws {
        // $18 v o: on when $7F:0000 < v, else jump. With $7F:0000 = 0, $18 $01 goes on; $18 $00 jumps.
        let p = try pack([0x18, 0x01, 0x02, 0x18, 0x00, 0x02, 0xB2, 0xB2])
        let (lanes, branches) = CTSceneRun.derive(steps(p, frames: 4), pack: p)
        let bars = try XCTUnwrap(lanes.first).bars
        let conditions = bars.filter { $0.opcode == 0x18 }
        XCTAssertEqual(conditions.map(\.jumped), [false, true])
        XCTAssertEqual(branches.map(\.jumped), [false, true])
        XCTAssertEqual(branches.first?.frame, 0)
    }

    func testAConditionThatYieldsFirstStillRecordsItsJump() throws {
        // Steps by hand: the $18 at $21 yields once (X stays), then jumps on its next run.
        let p = try pack([0x18, 0x00, 0x02, 0xB2, 0xB2, 0xB2])
        func step(_ frame: Int, _ offset: Int, _ next: Int) -> CTSceneRun.Step {
            CTSceneRun.Step(frame: frame, object: 0, offset: offset, opcode: Int(p.bytes[offset]), level: 7,
                            next: next, carry: false, stop: nil)
        }
        let target = try XCTUnwrap(p.instructions[0x21]?.jumpTarget)
        let (lanes, branches) = CTSceneRun.derive([step(0, 0x21, 0x21), step(4, 0x21, target)], pack: p)
        let bar = try XCTUnwrap(lanes.first?.bars.first)
        XCTAssertEqual(bar.runs, 2)
        XCTAssertEqual(bar.end, 4)
        XCTAssertEqual(bar.jumped, true)
        XCTAssertEqual(branches.map(\.jumped), [true])
    }

    func testAnUnmodelledOpcodeEndsTheLaneWithTheReason() throws {
        let p = try pack([0xAD, 0x01, 0xD2] + Array(repeating: 0, count: 8))
        let (lanes, _) = CTSceneRun.derive(steps(p, frames: 20), pack: p)
        let lane = try XCTUnwrap(lanes.first)
        XCTAssertNotNil(lane.stopped)
        XCTAssertTrue(lane.stopped?.contains("no model") ?? false)
        XCTAssertEqual(lane.bars.last?.stop, lane.stopped)
        XCTAssertEqual(lane.bars.last?.end, lane.stoppedAt)
    }

    func testABarLeftUnfinishedEndsWhereTheObjectWentElsewhere() throws {
        let p = try pack([0xAD, 0x10, 0xB2])
        let s: [CTSceneRun.Step] = [
            .init(frame: 0, object: 0, offset: 0x21, opcode: 0xAD, level: 7, next: 0x21, carry: false, stop: nil),
            .init(frame: 4, object: 0, offset: 0x21, opcode: 0xAD, level: 7, next: 0x21, carry: false, stop: nil),
            .init(frame: 5, object: 0, offset: 0x23, opcode: 0xB2, level: 1, next: 0x23, carry: false, stop: nil),
        ]
        let bars = CTSceneRun.derive(s, pack: p).lanes[0].bars
        XCTAssertEqual(bars[0].end, 5)
        XCTAssertTrue(bars[0].interrupted)
        XCTAssertEqual(bars[0].runs, 2)
        XCTAssertEqual(bars[1].level, 1)
    }

    func testFlagsByNameAddressAndBit() throws {
        let entry = CTStoryRegistry.Entry(symbol: "F_0010_3", addr: "7F:0010", bit: 3, name: "MET_SOMEONE", notes: nil,
                                          counts: [:], locations: [], references: [], code: [])
        let registry = CTStoryRegistry(romSHA256: "", entries: [entry], unused: [],
                                       totals: .init(packs: 0, instructions: 0, references: 0, warps: 0, codeReferences: 0))
        let named = try CTSceneRun.flag("MET_SOMEONE=1", registry: registry)
        XCTAssertEqual(named.address, 0x7F0010)
        XCTAssertEqual(named.bit, 3)
        let bySymbol = try CTSceneRun.flag("F_0010_3=0", registry: registry)
        XCTAssertEqual(bySymbol.value, 0)
        let byte = try CTSceneRun.flag("$7F0123=$12", registry: nil)
        XCTAssertEqual(byte.address, 0x7F0123)
        XCTAssertEqual(byte.value, 0x12)
        let bit = try CTSceneRun.flag("7F:0040.7=1", registry: nil)
        XCTAssertEqual(bit.address, 0x7F0040)
        XCTAssertEqual(bit.bit, 7)
        XCTAssertThrowsError(try CTSceneRun.flag("7F:0300=1", registry: nil))      // past the story bytes
        XCTAssertThrowsError(try CTSceneRun.flag("7F:0040.2=2", registry: nil))    // a bit is 0 or 1
        XCTAssertThrowsError(try CTSceneRun.flag("NOBODY=1", registry: registry))
        var w = WRAMModel()
        CTSceneRun.apply(named, to: &w)
        CTSceneRun.apply(byte, to: &w)
        XCTAssertEqual(w[0x7F0010], 0x08)
        XCTAssertEqual(w[0x7F0123], 0x12)
    }

    /// Three objects: slot 2 a kind-5 enemy on screen, slot 4 kind 6 off the
    /// screen's left column, slot 6 (one past the last object) kind 5 on screen.
    func testTheBattleListAndRecordsFollowTheHandOff() {
        var w = WRAMModel()
        w[WRAM.evtObjCount] = 3
        w[WRAM.mapTileOriginX] = 0x10; w[WRAM.mapTileOriginY] = 0x20     // origin column 8, row $10
        func object(_ s: Int, kind: UInt8, tile: (Int, Int), vram: UInt8, id: UInt8, visible: UInt8 = 1, flags: UInt8 = 0) {
            w[WRAM.objUnk1100 + s] = kind
            w[WRAM.objTileX + s] = UInt8(tile.0); w[WRAM.objTileY + s] = UInt8(tile.1)
            w[WRAM.objVramTile + s] = vram
            w[WRAM.objUnk1101 + s] = id
            w[WRAM.objUnk0F00 + s] = visible
            w[WRAM.objUnk1A81 + s] = flags
        }
        object(0, kind: 5, tile: (10, 0x12), vram: 0x40, id: 9)          // slot 0 is never looked at
        object(2, kind: 5, tile: (10, 0x12), vram: 0x50, id: 0x21)
        object(4, kind: 6, tile: (8, 0x12), vram: 0x60, id: 0x22)        // tile X - origin = 0: off
        object(6, kind: 5, tile: (0x16, 0x1D), vram: 0x40, id: 0x23, visible: 0, flags: 0x80)
        let (listed, enemies) = CTSceneFormation.compute(&w)
        XCTAssertEqual(listed, [3, 1])
        XCTAssertEqual(enemies.map(\.record), [0, 1])
        XCTAssertEqual(enemies.map(\.enemyId), [0x23, 0x21])
        XCTAssertEqual(enemies[0].flags & 0x80, 0x80)
        XCTAssertEqual(w[CTSceneFormation.records + 5], 0x23)             // BattleEnemyInit.Id of record 0
        XCTAssertEqual(w[CTSceneFormation.records + 12 + 5], 0x21)
        XCTAssertEqual(w[CTSceneFormation.records + 24 + 5], 0xFF)        // record 2 empty
        XCTAssertEqual(w[CTSceneFormation.objectSlots], 6)
        XCTAssertEqual(w[CTSceneFormation.objectSlots + 1], 2)
        XCTAssertEqual(w[CTSceneFormation.objectList + 2], 0x80)
    }

    func testBattleBitsAreNamed() {
        XCTAssertEqual(CTSceneFormation.describe2989(0).count, 0)
        XCTAssertEqual(CTSceneFormation.describe2989(0xA0).count, 2)
        XCTAssertTrue(CTSceneFormation.describe2989(0x08).first?.contains("not traced") ?? false)
    }

    // MARK: ROM

    private func rom() throws -> [UInt8] {
        var rom = [UInt8](try Repo.romData())
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        return rom
    }

    func testTimelineEqualsTheFieldsOwnTrace() throws {
        let rom = try rom()
        for location in [29, 7, 71] {
            var o = CTSceneRun.Options()
            o.frames = 240; o.scrollTo = false; o.skipBattles = false; o.romAnimLoops = false
            let r = try CTSceneRun.run(rom: rom, location: location, options: o)
            XCTAssertNil(r.error)
            // The same location in a plain field, its trace kept by frame.
            let field = try CTFieldRuntime(rom: rom, location: location)
            var steps: [CTSceneRun.Step] = [], frame = -1
            field.vm.trace = { e in
                var s = CTSceneRun.Step(frame: frame, object: e.slot / 2, offset: e.offset, opcode: Int(e.opcode),
                                        level: Int(field.vm.wram[WRAM.objUnk1C00 + e.slot]), next: nil, carry: false, stop: nil)
                if case .go(let x, let c) = e.outcome { s.next = x; s.carry = c } else { s.stop = "stop" }
                steps.append(s)
            }
            try field.start()
            for f in 0..<240 { frame = f; try field.step(input: []) }
            XCTAssertEqual(r.steps, steps.count, "location \(location)")
            let mine = CTSceneRun.derive(steps, pack: field.vm.pack).lanes
            XCTAssertEqual(mine.map(\.object), r.lanes.map(\.object))
            for (a, b) in zip(mine, r.lanes) {
                let ka = a.bars.map { [$0.offset, $0.start, $0.end ?? -2, $0.runs] }
                let kb = b.bars.map { [$0.offset, $0.start, $0.end ?? -2, $0.runs] }
                XCTAssertEqual(ka, kb, "location \(location) obj \(a.object)")
            }
            XCTAssertTrue(r.lanes.contains { $0.bars.contains { $0.start == -1 } }, "startups at load")
        }
    }

    func testStoryFlagsTurnABranch() throws {
        let rom = try rom()
        // Location 29 polls a story byte at load: run it with the byte clear and set.
        var results: [[Int: Bool]] = []
        for value in [0, 0xFF] {
            var o = CTSceneRun.Options()
            o.frames = 30
            o.flags = [try CTSceneRun.flag("7F:0198=\(value)", registry: nil)]
            let r = try CTSceneRun.run(rom: rom, location: 29, options: o)
            var first: [Int: Bool] = [:]
            for b in r.branches where first[b.offset] == nil { first[b.offset] = b.jumped }
            results.append(first)
        }
        let turned = results[0].filter { results[1][$0.key] != nil && results[1][$0.key] != $0.value }
        XCTAssertFalse(turned.isEmpty, "a condition on $7F:0198 decides differently")
    }

    func testABattleNamesItsEnemiesFromTheirObjects() throws {
        let rom = try rom()
        for location in [30, 226] {
            var o = CTSceneRun.Options()
            o.frames = 600
            let r = try CTSceneRun.run(rom: rom, location: location, options: o)
            let battle = try XCTUnwrap(r.battles.first, "location \(location)")
            XCTAssertFalse(battle.enemies.isEmpty)
            let analysis = CTSceneAnalysis(try CTEventPack(bytes: CTEventROM.unpack(
                rom: rom, entry: try CTEventROM.entries(rom: rom)[CTMapROM.header(rom, location).events])))
            for e in battle.enemies {
                XCTAssertNotNil(e.name)
                let marker = analysis.objects[e.object].markers.first { $0.kind == "enemySprite" }
                XCTAssertEqual(marker?.operands[0], e.enemyId, "the enemy id is its object's $83 record")
            }
            // The run goes on after the battle (taken as over at once).
            let lane = try XCTUnwrap(r.lanes.first { $0.object == battle.object })
            let d8 = try XCTUnwrap(lane.bars.first { $0.offset == battle.offset })
            XCTAssertGreaterThan(try XCTUnwrap(d8.end), battle.frame)
            let groups = CTSceneFormation.groups(analysis, rom: rom)
            XCTAssertFalse(groups.isEmpty)
        }
    }

    func testScrollToMovesTheCameraToItsTopLeftTile() throws {
        let rom = try rom()
        // Any location whose run reaches $E7 and finishes it: the camera ends on column x 16, row x 16.
        var checked = 0
        for location in [30, 226, 29, 6, 19, 49] {
            var o = CTSceneRun.Options()
            o.frames = 600
            let r = try CTSceneRun.run(rom: rom, location: location, options: o)
            let pack = try CTEventPack(bytes: CTEventROM.unpack(rom: rom, entry: try CTEventROM.entries(rom: rom)[CTMapROM.header(rom, location).events]))
            for lane in r.lanes {
                for b in lane.bars where b.opcode == 0xE7 {
                    guard let end = b.end, b.stop == nil, !b.interrupted else { continue }
                    let col = Int(pack.bytes[b.offset + 2]), row = Int(pack.bytes[b.offset + 3])
                    let cam = try XCTUnwrap(r.cameraAt(end))
                    XCTAssertEqual(cam.x, col * 16, "location \(location) $\(String(b.offset, radix: 16))")
                    XCTAssertEqual(cam.y, row * 16)
                    checked += 1
                }
            }
        }
        if checked == 0 { throw XCTSkip("no sampled location finishes a scroll-to in 600 frames") }
    }
    func testDirectionMovesAreChoreographyPointsWithTheirSpeed() throws {
        // $92 before any $89 walks at Obj_Unk1A00Init's $10; after $89 $30 at $30. $96 stays a tile target.
        let p = try pack([0x92, 0x40, 0x08, 0x89, 0x30, 0x9C, 0xC0, 0x04, 0x96, 0x05, 0x06, 0xB2])
        let points = try XCTUnwrap(CTSceneChoreography.extract(p).first).points
        XCTAssertEqual(points.map(\.kind), [.direction, .direction, .walk])
        XCTAssertEqual(points.map(\.angle), [0x40, 0xC0, nil])
        XCTAssertEqual(points.map(\.frames), [8, 4, nil])
        XCTAssertEqual(points.map(\.speed), [0x10, 0x30, nil])
        var doc = try CTSceneDocument.raise(bytes: p.bytes)
        XCTAssertThrowsError(try doc.addPoint(.direction, column: 1, row: 1, after: nil, object: 0, function: 1))
    }

    func testADirectionPathEndsWhereTheHandlerMovesTheObject() throws {
        let rom = try rom()
        // $92 angle frames from tile (64, 64), run by the duration harness's frame loop
        // (handler, then Obj_MoveStep); the path the Map draws must end where it does.
        for (angle, frames, speed) in [(0x00, 24, 0x10), (0x40, 16, 0x20), (0xA0, 30, 0x10), (0xE0, 12, 0x30)] {
            let p = try pack([0x92, UInt8(angle), UInt8(frames), 0xB2])
            func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
            let regions: [[Any]] = [
                [0x7E1100, "04"], [WRAM.objUnk1000, "01"], [WRAM.objSpeed, hex([UInt8(speed)])],
                [WRAM.objPosX, "8040"], [WRAM.objPosY, "8040"], [WRAM.objXUnk7F0B00, "80"],
            ]
            let input: [String: Any] = [
                "packs": ["p": hex(p.bytes)], "formations": [Any](),
                "durations": [["id": 0, "pack": "p", "y": 0x21, "slot": 0, "frames": 300, "regions": regions]],
            ]
            let out = try CTSceneRunVectors.run(rom: rom, casesJSON: JSONSerialization.data(withJSONObject: input))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
            let rows = try XCTUnwrap((json["durations"] as? [[String: Any]])?.first?["frames"] as? [[Int]])
            let last = try XCTUnwrap(rows.last)
            let (dx, dy) = CTSceneChoreography.directionDelta(angle: angle, frames: frames, speed: speed, rom: rom)
            let label = "angle $\(String(angle, radix: 16)) frames \(frames) speed \(speed)"
            XCTAssertEqual(Double(last[2] - 0x4080) / 256, dx, label)
            XCTAssertEqual(Double(last[3] - 0x4080) / 256, dy, label)
        }
    }
}
