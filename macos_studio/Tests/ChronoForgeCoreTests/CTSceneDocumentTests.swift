// CTSceneDocumentTests.swift — raising event packs into scenes: objects,
// functions, calls, map objects, the graph, the timeline through the
// scheduler, choreography edits (synthetic packs), and every ROM pack
// raised and lowered byte-exact.
import XCTest
@testable import ChronoForgeCore

final class CTSceneDocumentTests: XCTestCase {
    /// Two objects. Object 0: startup places it and returns, then halts;
    /// activate waits 16 runs and calls object 1's function 3 (wait, level 2).
    /// Object 1: a sprite placed at (10, 11); activate opens the save menu;
    /// function 3 walks, scrolls the camera and starts a battle.
    private func fixture() throws -> CTEventProgram {
        let ret = CTEventProgram.Target.label("RET")
        var f0 = [CTEventProgram.Target](repeating: ret, count: 16), f1 = f0
        f0[0] = .label("A0"); f0[1] = .label("A1")
        f1[0] = .label("B0"); f1[1] = .label("B1"); f1[3] = .label("B3")
        func op(_ o: UInt8, _ b: UInt8...) -> CTEventProgram.Item { .op(o, b.map { .byte($0) }) }
        let items: [CTEventProgram.Item] = [
            .label("A0"), op(0x8B, 0x02, 0x03), op(0x00), op(0xB2),
            .label("A1"), op(0xAD, 0x10), op(0x04, 0x02, 0x23), op(0x00),
            .label("B0"), op(0x81, 0x05), op(0x8B, 0x0A, 0x0B), op(0x00), op(0xB2),
            .label("B1"), op(0xC8, 0x02), op(0x00),
            .label("B3"), op(0x96, 0x0C, 0x0D), op(0xE7, 0x08, 0x08), op(0xD8, 0x12, 0xA0), op(0x00),
            .label("RET"), op(0x00), op(0xB2),
        ]
        return CTEventProgram(objectCount: 2, functions: [f0, f1], items: items)
    }

    private func offset(_ doc: CTSceneDocument, label: String) throws -> Int {
        try doc.program.offsets().labels[label]!
    }

    func testRaiseGivesFunctionsCallsAndMapObjects() throws {
        let bytes = try fixture().assemble()
        let doc = try CTSceneDocument.raise(bytes: bytes, location: 7, packEntry: 9)
        let a = try doc.analyze()
        XCTAssertEqual(a.objectCount, 2)
        let o0 = a.objects[0], o1 = a.objects[1]
        XCTAssertEqual(o0.functions.map(\.role).prefix(4), ["startup", "activate", "touch", "routine 3"])
        XCTAssertTrue(o0.functions[2].stub, "unused functions point at the shared return")
        XCTAssertEqual(o0.functions[1].statements.count, 3)
        XCTAssertEqual(o0.continuation.count, 1, "the halt after the startup's $00")
        XCTAssertEqual(a.calls.count, 1)
        let call = a.calls[0]
        XCTAssertEqual([call.object, call.function, call.targetObject, call.targetFunction, call.level], [0, 1, 1, 3, 2])
        XCTAssertEqual(call.mode, .wait)
        XCTAssertEqual(o1.placement?.column, 10); XCTAssertEqual(o1.placement?.row, 11)
        XCTAssertEqual(Set(o1.markers.map(\.kind)), ["sprite", "placement", "saveMenu", "battle"])
        XCTAssertEqual(o1.kind, "save point")
        let battle = o1.markers.first { $0.kind == "battle" }!
        XCTAssertEqual(battle.function, 3)
        XCTAssertTrue(battle.detail.contains("FieldBtl_EvtNoReset") && battle.detail.contains("FieldBtl_EvtUnk80"), battle.detail)
        XCTAssertEqual(a.statement(at: call.offset)?.name, "Op04_CallObjFuncWait")
        XCTAssertEqual(a.statement(at: call.offset)?.category, .call)

        let graph = CTSceneGraph(a)
        XCTAssertTrue(graph.nodes.contains(.init(object: 1, function: 3)))
        XCTAssertTrue(graph.nodes.contains(.init(object: 0, function: CTSceneGraph.continuation)))
        XCTAssertFalse(graph.nodes.contains(.init(object: 0, function: 2)), "stubs are not nodes")
        XCTAssertEqual(graph.edges.count, 1)
        XCTAssertEqual(graph.edges[0].from, .init(object: 0, function: 1))
        XCTAssertEqual(graph.edges[0].to, .init(object: 1, function: 3))
        XCTAssertTrue(graph.render().contains("obj 0 func 1 (activate) -> obj 1 func 3 (routine 3) [wait, level 2]"), graph.render())
    }

    func testLoweringAndJSONAreByteExact() throws {
        let bytes = try fixture().assemble()
        let doc = try CTSceneDocument.raise(bytes: bytes, location: 7, packEntry: 9)
        XCTAssertEqual(try doc.lower(), bytes)
        let json = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(CTSceneDocument.self, from: json)
        XCTAssertEqual(back, doc)
        XCTAssertEqual(try back.lower(), bytes)
        XCTAssertEqual(back.location, 7)
        let text = String(decoding: json, as: UTF8.self)
        XCTAssertTrue(text.contains("\"op\":\"Op96_WalkToTile\""), text)
        XCTAssertThrowsError(try JSONDecoder().decode(CTSceneDocument.self, from: Data(text.replacingOccurrences(of: "ct-scene\\/1", with: "ct-scene\\/9").utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(CTSceneDocument.self, from: Data(text.replacingOccurrences(of: "Op96_WalkToTile", with: "Op96_Nope").utf8)))
    }

    func testAnnotatedListingParsesBackWithOffsets() throws {
        let doc = try CTSceneDocument.raise(bytes: try fixture().assemble())
        let (text, offsets) = try doc.annotatedListing(title: "fixture")
        XCTAssertEqual(try CTEventListing.parse(text), doc.program)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        XCTAssertEqual(lines.count - 1, offsets.count)
        XCTAssertTrue(text.contains("; ── obj 1 func 3 (routine 3)"), text)
        let walk = try doc.analyze().statements.first { $0.opcode == 0x96 }!
        let line = offsets.firstIndex(of: walk.offset)!
        XCTAssertTrue(lines[line].contains("Op96_WalkToTile $0C $0D"), String(lines[line]))
    }

    func testEditsReassembleAndFailedEditsChangeNothing() throws {
        var doc = try CTSceneDocument.raise(bytes: try fixture().assemble())
        let walk = try doc.analyze().statements.first { $0.opcode == 0x96 }!.offset
        try doc.insert(0xAA, [0x03], after: walk)
        var a = try doc.analyze()
        XCTAssertEqual(a.statement(at: walk + 3)?.name, "OpAA_SetAnimRow")
        try doc.setOperands(at: walk, [0x01, 0x02])
        XCTAssertEqual(try doc.analyze().statement(at: walk)?.operands, [1, 2])
        try doc.insert(0xBB, [0x00], atStartOf: 1, function: 3)
        a = try doc.analyze()
        XCTAssertEqual(a.statement(at: a.objects[1].functions[3].entry)?.name, "OpBB_Msg")
        try doc.remove(at: a.objects[1].functions[3].entry)
        XCTAssertEqual(try doc.analyze().statement(at: a.objects[1].functions[3].entry)?.opcode, 0x96)

        let before = doc
        XCTAssertThrowsError(try doc.insert(0x10, [0x00], after: walk), "jumps need labels")
        XCTAssertThrowsError(try doc.setOperands(at: walk, [0x01]), "operand count")
        XCTAssertThrowsError(try doc.insert(0x96, [0x01], after: walk), "the handler takes 2 operand bytes")
        XCTAssertThrowsError(try doc.insert(0x01, [], after: walk), "unused opcode")
        XCTAssertThrowsError(try doc.remove(at: walk + 1), "not an opcode start")
        XCTAssertEqual(doc, before)
    }

    func testDuplicateObjectIsAPlacedCopy() throws {
        var doc = try CTSceneDocument.raise(bytes: try fixture().assemble())
        let k = try doc.duplicateObject(1, placeAt: (3, 4))
        XCTAssertEqual(k, 2)
        let a = try doc.analyze()
        XCTAssertEqual(a.objectCount, 3)
        XCTAssertEqual(a.objects[2].placement?.column, 3); XCTAssertEqual(a.objects[2].placement?.row, 4)
        XCTAssertEqual(a.objects[1].placement?.column, 10, "the original stays")
        XCTAssertEqual(a.objects[2].kind, "save point")
        XCTAssertEqual(a.objects[2].markers.map(\.kind), a.objects[1].markers.map(\.kind))
        XCTAssertTrue(a.objects[2].functions[2].stub)
        // The copy round-trips like any pack.
        let bytes = try doc.lower()
        XCTAssertEqual(try CTSceneDocument.raise(bytes: bytes).lower(), bytes)
    }

    func testTimelineRunsEveryObjectAndMapsOffsets() throws {
        let pack = try CTEventPack(bytes: try fixture().assemble())
        let a = CTSceneAnalysis(pack)
        let r = try CTSceneTimeline.run(pack, trigger: .init(object: 0, function: 1))
        let lane0 = r.lanes.first { $0.object == 0 }!.events, lane1 = r.lanes.first { $0.object == 1 }!.events
        let wait = lane0.first { $0.category == .wait }!
        XCTAssertEqual(wait.duration, 16); XCTAssertEqual(wait.function, 1); XCTAssertEqual(wait.level, 1)
        XCTAssertEqual(a.statement(at: wait.offset!)?.opcode, 0xAD)
        let call = lane0.first { $0.category == .call }!
        XCTAssertEqual(call.frame, 16, "after 16 frames of waiting")
        XCTAssertTrue(call.detail.contains("obj01 starts func 3 at level 2"), call.detail)
        let f3 = lane1.filter { $0.function == 3 }
        XCTAssertEqual(f3.map(\.category), [.move, .camera, .battle])
        XCTAssertEqual(f3.map { a.statement(at: $0.offset!)!.opcode }, [0x96, 0xE7, 0xD8])
        XCTAssertTrue(f3.allSatisfy { $0.level == 2 && $0.frame >= 16 })
        XCTAssertTrue(lane1.contains { $0.function == 0 && $0.category == .sprite }, "startups run at load")
        XCTAssertEqual(r.stopReason, "All objects idle")
        XCTAssertTrue(CTSceneTimeline.render(r).contains("battle: OpD8_StartBattle $12 $A0"))
        XCTAssertThrowsError(try CTSceneTimeline.run(pack, trigger: .init(object: 0, function: 5)))
    }

    func testSchedulerTraceCountsStatementsPerInvocation() throws {
        let scenes = ["a": EventScene(object: 0, funcs: [EventFunc(index: 0, stmts: [.nop, .wait(frames: 2), .nop, .jump(funcIndex: 1)]),
                                                         EventFunc(index: 1, stmts: [.nop, .nop])])]
        let (result, steps) = try EventScheduler.trace(scenes: scenes, starts: [.init(scene: "a", function: 0, level: 7)])
        XCTAssertEqual(result.entries.map(\.function), [0, 0, 0, 0, 1, 1])
        XCTAssertEqual(steps, [0, 1, 2, 3, 0, 1])
        XCTAssertEqual(try EventScheduler.run(scenes: scenes, entryScene: "a"), result)
    }

    func testChoreographyPointsAndTheirEdits() throws {
        var doc = try CTSceneDocument.raise(bytes: try fixture().assemble())
        var points = CTSceneChoreography.extract(try doc.pack())
        XCTAssertEqual(points[0].points.map(\.kind), [.place])
        XCTAssertEqual(points[1].points.map(\.kind), [.place, .walk, .camera])
        XCTAssertEqual(points[1].points.map { [$0.column, $0.row] }, [[10, 11], [12, 13], [8, 8]])
        let walk = points[1].points[1]
        try doc.movePoint(at: walk.offset, column: 20, row: 21)
        try doc.addPoint(.move, column: 22, row: 23, after: walk.offset, object: 1, function: 3)
        try doc.addPoint(.camera, column: 1, row: 1, after: nil, object: 0, function: 1)
        points = CTSceneChoreography.extract(try doc.pack())
        XCTAssertEqual(points[1].points.map(\.kind), [.place, .walk, .move, .camera])
        XCTAssertEqual(points[1].points[1].column, 20)
        XCTAssertEqual(points[1].points[2].row, 23)
        XCTAssertEqual(points[0].points.map(\.kind), [.place, .camera])
        XCTAssertThrowsError(try doc.movePoint(at: try doc.analyze().objects[1].functions[1].entry, column: 1, row: 1))
    }

    func testMenuArgumentsFollowTheFieldHandOff() {
        XCTAssertEqual(CTSceneAnalysis.menu(0).bankArgument, 5)
        XCTAssertEqual(CTSceneAnalysis.menu(0).mode, 0x07)
        XCTAssertEqual(CTSceneAnalysis.menu(2).mode, 0x0B)
        XCTAssertTrue(CTSceneAnalysis.isSaveMenu(2))
        XCTAssertFalse(CTSceneAnalysis.isSaveMenu(0))
        XCTAssertEqual(CTSceneAnalysis.menu(1).mode, 0x0E)
        XCTAssertEqual(CTSceneAnalysis.menu(0x85).mode, 0x0C)
        XCTAssertEqual(CTSceneAnalysis.menu(0x85).list, 5)
        XCTAssertEqual(CTSceneAnalysis.menu(0xC3).bankArgument, 3)
    }

    func testStudioChoreographyLowersThroughTheVerifier() throws {
        var scene = EventScene(object: 0, funcs: [EventFunc(index: 0, stmts: [.nop])])
        try SceneChoreography.append(.walk, column: 5, row: 6, to: &scene, function: 0)
        try SceneChoreography.append(.camera, column: 1, row: 2, to: &scene, function: 0)
        try SceneChoreography.appendAnimation(row: 3, loops: 2, to: &scene, function: 0)
        try SceneChoreography.appendAnimation(row: 4, once: true, to: &scene, function: 0)
        XCTAssertThrowsError(try SceneChoreography.append(.walk, column: 300, row: 0, to: &scene, function: 0))
        XCTAssertThrowsError(try SceneChoreography.append(.walk, column: 1, row: 0, to: &scene, function: 4))
        let out = try CTEventLowering.lower(scenes: [scene], flag: { _ in throw CTEventError("no flags") })
        let pack = try CTEventPack(bytes: out.bytes)
        XCTAssertEqual(Set(pack.instructions.values.map(\.opcode)).intersection([0x96, 0xE7, 0xB7, 0xAB]), [0x96, 0xE7, 0xB7, 0xAB])
        let text = EventDSL.format(scene)
        XCTAssertEqual(try EventDSL.parse(text), scene)
    }

    // MARK: ROM

    /// The non-empty packs tools/ct_event_packs.py recorded, by their first pointer.
    private func romPacks() throws -> (rom: [UInt8], packs: [(entry: Int, bytes: [UInt8])]) {
        let rom = [UInt8](try Repo.romData())
        struct Manifest: Decodable {
            struct Pack: Decodable { let pointerIndices: [Int]; let objects: Int? }
            let packs: [Pack]
        }
        let url = Repo.root.appendingPathComponent("re_workspace/manifests/event_pack_verification.json")
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let entries = try CTEventROM.entries(rom: rom)
        let packs = try manifest.packs.filter { $0.objects != nil }.map { p in
            (p.pointerIndices[0], try CTEventROM.unpack(rom: rom, entry: entries[p.pointerIndices[0]]))
        }
        return (rom, packs)
    }

    func testEveryROMPackRaisesAndLowersByteExact() throws {
        let (_, packs) = try romPacks()
        XCTAssertEqual(packs.count, 461, "non-empty event packs (event_pack_verification.json)")
        var objects = 0, calls = 0
        for (entry, bytes) in packs {
            let doc = try CTSceneDocument.raise(bytes: bytes, packEntry: entry)
            let back = try JSONDecoder().decode(CTSceneDocument.self, from: try JSONEncoder().encode(doc))
            XCTAssertEqual(try back.lower(), bytes, "pack \(entry)")
            let (text, _) = try doc.annotatedListing()
            XCTAssertEqual(try CTEventListing.parse(text).assemble(), bytes, "pack \(entry) listing")
            let a = try doc.analyze()
            objects += a.objectCount; calls += a.calls.count
            XCTAssertLessThanOrEqual(a.objectCount, CTSceneDocument.maximumObjects)
        }
        XCTAssertGreaterThan(objects, 461)
        XCTAssertGreaterThan(calls, 0)
    }

    func testEveryROMPackRunsOnTheTimeline() throws {
        let (_, packs) = try romPacks()
        var located = 0
        for (entry, bytes) in packs {
            let pack = try CTEventPack(bytes: bytes)
            let r = try CTSceneTimeline.run(pack, frameLimit: 60, stepLimit: 4000)
            let events = r.lanes.flatMap(\.events)
            located += events.filter { $0.offset != nil }.count
            XCTAssertTrue(events.allSatisfy { $0.offset.map { pack.instructions[$0] != nil } ?? true }, "pack \(entry)")
        }
        XCTAssertGreaterThan(located, 0)
    }

    func testROMLocationsFindTheirPacksAndMapObjects() throws {
        let (rom, packs) = try romPacks()
        var saves = 0, battles = 0
        for (_, bytes) in packs {
            let a = CTSceneAnalysis(try CTEventPack(bytes: bytes))
            saves += a.objects.filter { $0.markers.contains { $0.kind == "saveMenu" } }.count
            battles += a.objects.filter { $0.markers.contains { $0.kind == "battle" } }.count
        }
        XCTAssertGreaterThan(saves, 0, "objects opening the save-slot menu")
        XCTAssertGreaterThan(battles, 0, "objects starting a battle")
        // Location 1's LocRom field +8 names its pack, which raises.
        let entry = CTMapROM.header(rom, 1).events
        let bytes = try CTEventROM.unpack(rom: rom, entry: try CTEventROM.entries(rom: rom)[entry])
        XCTAssertGreaterThan(try CTSceneDocument.raise(bytes: bytes, location: 1, packEntry: entry).analyze().objectCount, 0)
    }
}
