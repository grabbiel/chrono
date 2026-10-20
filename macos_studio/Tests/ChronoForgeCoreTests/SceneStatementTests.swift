// SceneStatementTests.swift — call_obj, call_pc and ct: DSL, archive, lowering, preview.
import XCTest
@testable import ChronoForgeCore

final class SceneStatementTests: XCTestCase {
    private let source = """
    obj 1 {
      func 0 {
        call_obj npc#2
        call_obj "guard"#3 start level 1
        call_pc 2#5 retry
        ct Op94_WalkToObj $06
        ct $EA $12
      }
    }
    """
    private let statements: [EventStmt] = [
        .callObject(scene: "npc", funcIndex: 2, mode: .wait, level: 4),
        .callObject(scene: "guard", funcIndex: 3, mode: .start, level: 1),
        .callMember(member: 2, funcIndex: 5, mode: .retry, level: 4),
        .ct(opcode: 0x94, operands: [0x06]),
        .ct(opcode: 0xEA, operands: [0x12]),
    ]

    private func flag(_ symbol: String) throws -> (m: UInt8, page: Bool, bit: UInt8) {
        throw CTEventError("no flags here")
    }

    func testDSLArchiveAndJSONRoundTrips() throws {
        let scene = try EventDSL.parse(source)
        XCTAssertEqual(scene.funcs[0].stmts, statements)
        let canonical = EventDSL.format(scene)
        XCTAssertTrue(canonical.contains("call_obj \"npc\"#2 wait level 4"), canonical)
        XCTAssertTrue(canonical.contains("call_pc 2#5 retry level 4"), canonical)
        XCTAssertTrue(canonical.contains("ct Op94_WalkToObj $06"), canonical)
        XCTAssertTrue(canonical.contains("ct OpEA_PlayMusic $12"), canonical)
        XCTAssertEqual(try EventDSL.parse(canonical), scene)
        XCTAssertEqual(try EventBytecode.decompile(EventBytecode.compile(scene.funcs)), scene.funcs)
        let json = try JSONEncoder().encode(scene)
        XCTAssertEqual(try JSONDecoder().decode(EventScene.self, from: json), scene)
    }

    func testDSLRefusals() {
        for bad in ["call_obj npc#2 level 7", "call_pc 3#1", "call_obj npc#16", "ct $ZZ", "ct Bogus_Op", "ct"] {
            XCTAssertThrowsError(try EventDSL.parse("obj 0 {\n func 0 {\n  \(bad)\n }\n}\n"), bad)
        }
    }

    func testLoweringCallsAndCTOpcodes() throws {
        let hero = EventScene(object: 0, funcs: [EventFunc(index: 0, stmts: [
            .callObject(scene: "npc", funcIndex: 1, mode: .wait, level: 3),
            .callObject(scene: "npc", funcIndex: 1, mode: .start, level: 0),
            .callObject(scene: "npc", funcIndex: 1, mode: .retry, level: 6),
            .callMember(member: 1, funcIndex: 2, mode: .start, level: 5),
            .callMember(member: 0, funcIndex: 15, mode: .wait, level: 4),
            .ct(opcode: 0x94, operands: [0x02]),
            .ct(opcode: 0xEA, operands: [0x12]),
        ])])
        let npc = EventScene(object: 1, funcs: [EventFunc(index: 1, stmts: [.nop])])
        let out = try CTEventLowering.lower(named: [("hero", hero), ("npc", npc)], flag: flag)
        let pack = try CTEventPack(bytes: out.bytes)
        let start = pack.functions[0][0] + 1                 // Evt_Data offset -> byte index
        XCTAssertEqual(Array(out.bytes[start..<(start + 19)]),
                       [0x04, 0x02, 0x31, 0x02, 0x02, 0x01, 0x03, 0x02, 0x61, 0x05, 0x02, 0x52, 0x07, 0x00, 0x4F,
                        0x94, 0x02, 0xEA, 0x12])
        XCTAssertEqual(Array(out.bytes[(start + 19)..<(start + 21)]), [0x00, 0xB2])
        XCTAssertNotNil(pack.instructions[pack.functions[1][1]])
    }

    func testLoweringRefusals() {
        let npc = EventScene(object: 1, funcs: [EventFunc(index: 1, stmts: [])])
        func lower(_ stmt: EventStmt, with others: [(id: String?, scene: EventScene)] = []) -> String {
            let scene = EventScene(object: 0, funcs: [EventFunc(index: 0, stmts: [stmt])])
            do { _ = try CTEventLowering.lower(named: [("hero", scene)] + others, flag: flag); return "" }
            catch { return "\(error)" }
        }
        XCTAssertTrue(lower(.callObject(scene: "npc", funcIndex: 1, mode: .wait, level: 4)).contains("not lowered into this pack"))
        XCTAssertTrue(lower(.callObject(scene: "npc", funcIndex: 2, mode: .wait, level: 4), with: [("npc", npc)]).contains("has no func 2"))
        XCTAssertTrue(lower(.ct(opcode: 0x10, operands: [0x02])).contains("control flow"))
        XCTAssertTrue(lower(.ct(opcode: 0x00, operands: [])).contains("control flow"))
        XCTAssertTrue(lower(.ct(opcode: 0xBB, operands: [0x00])).contains("text statements"))
        XCTAssertTrue(lower(.ct(opcode: 0xB8, operands: [0, 0, 0])).contains("text statements"))
        XCTAssertTrue(lower(.ct(opcode: 0x94, operands: [])).contains("takes 1 operand bytes"))
        XCTAssertTrue(lower(.ct(opcode: 0x01, operands: [])).contains("unused"))
        XCTAssertNil(CTEventLowering.ctProblem(opcode: 0x96, operands: [0x10, 0x20]))
    }

    func testPreviewGoesOnAndReferencesAreChecked() throws {
        let scene = try EventDSL.parse(source)
        let result = try EventPreview.run(scene)
        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(result.stopReason, "Function completed")
        let issues = EventReferences.issues(in: scene, flags: [], strings: [], maps: [],
                                            scenes: ["npc": EventScene(object: 2, funcs: [EventFunc(index: 0, stmts: [])])])
        XCTAssertTrue(issues.contains { $0.contains("scene \"npc\" has no func 2") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("unknown scene \"guard\"") }, "\(issues)")
    }
}
