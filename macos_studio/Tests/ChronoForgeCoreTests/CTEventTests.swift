// CTEventTests.swift — CT event packs: table-driven decode, listing round trip,
// assembler refusals and Studio scene lowering (no ROM), plus every ROM pack.
import XCTest
@testable import ChronoForgeCore

final class CTEventTests: XCTestCase {
    /// One object; every function at $0020.
    private func pack(_ code: [UInt8], objects: Int = 1) -> [UInt8] {
        let start = objects * 32
        return [UInt8(objects)] + Array(repeating: [UInt8(start & 255), UInt8(start >> 8)], count: 16 * objects).flatMap { $0 } + code
    }

    func testDecodeFollowsJumpsConditionsAndInitContinuation() throws {
        // $20: SetMemBit; IfMemByte -> $2E; Msg; Return; Halt (after init); $2E: Yield; JumpBack -> $2E
        let bytes = pack([0x65, 0x02, 0x03, 0x16, 0x03, 0x04, 0x06, 0x07, 0xBB, 0x00, 0x00, 0xB2,
                          0x99, 0x99, 0xB1, 0x11, 0x02])
        let p = try CTEventPack(bytes: bytes)
        XCTAssertEqual(p.instructions.keys.sorted(), [0x20, 0x23, 0x28, 0x2A, 0x2B, 0x2E, 0x2F])
        XCTAssertEqual(p.instructions[0x23]?.jumpTarget, 0x2E)
        XCTAssertEqual(p.instructions[0x2F]?.jumpTarget, 0x2E)
        XCTAssertEqual(p.instructions[0x2F]?.flow, .jump)
        XCTAssertTrue(p.entries.contains(0x2B), "opcode after init's $00 is where the object goes on")
        XCTAssertEqual(p.dataByteCount, 2)
        let program = CTEventListing.program(p)
        XCTAssertEqual(program.items.filter { if case .bytes = $0 { return true }; return false }, [.bytes([0x99, 0x99])])
        let text = CTEventListing.render(program)
        XCTAssertTrue(text.contains("Op16_IfMemByte $03 $04 $06 ->L_002E"), text)
        XCTAssertEqual(try CTEventListing.parse(text), program)
        XCTAssertEqual(try program.assemble(), bytes)
    }

    func testVariableLengthOpcodesFromTheirOperands() throws {
        // $4E CopyData: length = 4 + its length word; $88 kind $8x: 2 + word; $F1 0: 2 bytes.
        let bytes = pack([0x4E, 0x00, 0x30, 0x7E, 0x05, 0x00, 0xAA, 0xBB, 0xCC,
                          0x88, 0x81, 0x04, 0x00, 0x11, 0x22,
                          0xF1, 0x00, 0x00, 0xB2])
        let p = try CTEventPack(bytes: bytes)
        XCTAssertEqual(p.instructions.keys.sorted(), [0x20, 0x29, 0x2F, 0x31, 0x32])
        XCTAssertEqual(p.instructions[0x20]?.length, 9)
        XCTAssertEqual(p.instructions[0x29]?.length, 6)
        XCTAssertEqual(p.instructions[0x2F]?.length, 2)
        XCTAssertEqual(p.dataByteCount, 0)
        XCTAssertEqual(try CTEventListing.program(p).assemble(), bytes)
        // A length word whose low byte carries: 4 + $01FE, not (4 + $FE) | $100.
        let long = pack([0x4E, 0x00, 0x30, 0x7E, 0xFE, 0x01] + [UInt8](repeating: 0x11, count: 0x1FE - 2) + [0x00, 0xB2])
        XCTAssertEqual(try CTEventPack(bytes: long).instructions[0x20]?.length, 0x202)
    }

    func testJumpIntoOperandsIsAnInnerLabel() throws {
        // $20 JumpFwd n=0 lands on its own operand byte, read as $00 Return.
        let bytes = pack([0x10, 0x00, 0xB2])
        let p = try CTEventPack(bytes: bytes)
        XCTAssertEqual(p.layout.inner, [0x21: 0x20])
        XCTAssertEqual(p.layout.primary, [0x20, 0x22])
        let text = CTEventListing.render(CTEventListing.program(p))
        XCTAssertTrue(text.contains("Op10_JumpFwd ->L_0021\n    @inner +1 L_0021"), text)
        XCTAssertEqual(try CTEventListing.parse(text).assemble(), bytes)
    }

    func testAssemblerRefusals() throws {
        let funcs = [Array(repeating: CTEventProgram.Target.label("A"), count: 16)]
        func program(_ items: [CTEventProgram.Item]) -> CTEventProgram {
            CTEventProgram(objectCount: 1, functions: funcs, items: items)
        }
        let cases: [(String, [CTEventProgram.Item])] = [
            ("takes", [.label("A"), .op(0x65, [.byte(1)])]),                                     // 3-byte opcode
            ("undefined label", [.label("A"), .op(0x10, [.label("B")])]),
            ("not a jump", [.label("A"), .op(0x65, [.label("A"), .byte(0)])]),
            ("unused opcode", [.label("A"), .op(0x01, [])]),
            ("defined twice", [.label("A"), .label("A"), .op(0xB2, [])]),
            ("reached as an opcode", [.label("A"), .op(0x10, [.label("B")]), .label("B"), .bytes([0xB2])]),
            ("bytes away", [.label("A"), .op(0x10, [.label("B")]), .bytes([UInt8](repeating: 0, count: 300)),
                            .label("B"), .op(0xB2, [])]),
            ("inside", [.label("A"), .inner(1, "X"), .op(0xB2, [])]),
        ]
        for (expected, items) in cases {
            XCTAssertThrowsError(try program(items).assemble(), expected) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(expected): \(error)")
            }
        }
        XCTAssertThrowsError(try CTEventListing.parse("@objects 1\n@func 0 0 A\nA:\n Op00_Return\n"))   // 15 functions missing
        XCTAssertThrowsError(try CTEventListing.parse("@objects 1\nNotAnOpcode\n"))
        XCTAssertThrowsError(try CTEventPack(bytes: []))
        XCTAssertThrowsError(try CTEventPack(bytes: [2] + [UInt8](repeating: 0, count: 10)))
    }

    // MARK: Lowering

    /// Lowered code is all reached except dead `$00 Return` / `$B2 Halt`
    /// epilogues (after an unconditional jump, or a halt only init could reach).
    private func assertOnlyEpiloguesUnreached(_ bytes: [UInt8], file: StaticString = #filePath, line: UInt = #line) throws {
        let pack = try CTEventPack(bytes: bytes)
        for y in pack.unreachedOffsets {
            XCTAssertTrue([0x00, 0xB2].contains(bytes[y + 1]), String(format: "$%04X unreached", y), file: file, line: line)
        }
    }

    private func flag(_ symbol: String) throws -> (m: UInt8, page: Bool, bit: UInt8) {
        switch symbol {
        case "F": return try CTEventLowering.memoryBit(addr: "7F:0003", bit: 2, symbol: symbol)
        case "P": return try CTEventLowering.memoryBit(addr: "7F:0105", bit: 7, symbol: symbol)
        default: throw CTEventError("unknown flag \(symbol)")
        }
    }

    func testLoweringGoldenBytesAndRelocation() throws {
        let scene = EventScene(object: 0, funcs: [
            EventFunc(index: 0, stmts: [.setFlag(symbol: "F"),
                                        .ifFlag(symbol: "F", then: [.text(stringID: "a")], else: [.wait(frames: 300)]),
                                        .jump(funcIndex: 1)]),
            EventFunc(index: 1, stmts: [.clearFlag(symbol: "F"), .nop, .text(stringID: "b")]),
        ])
        let out = try CTEventLowering.lower(scenes: [scene], flag: flag)
        let header: [UInt8] = [0x20, 0x00, 0x38, 0x00] + Array(repeating: [0x3F, 0x00], count: 14).flatMap { $0 }
        let code: [UInt8] = [
            0xB8, 0x00, 0x00, 0x00,             // $20 SetMsgPtr (relocated later)
            0x65, 0x02, 0x03,                   // $24 set bit 2 of $7F:0003
            0x16, 0x03, 0x04, 0x06, 0x05,       // $27 if $7F:0003 & $04 else -> $30
            0xBB, 0x00,                         // $2C message 0
            0x10, 0x05,                         // $2E -> $34
            0xAD, 0xFF, 0xAD, 0x2D,             // $30 wait 255 + 45 runs
            0x10, 0x03,                         // $34 -> func 1 at $38
            0x00, 0xB2,                         // $36 return; halt
            0x66, 0x02, 0x03, 0xBB, 0x01, 0x00, 0xB2,   // $38 func 1
            0x00, 0xB2,                         // $3F unused functions
        ]
        XCTAssertEqual(out.bytes, [1] + header + code)
        XCTAssertEqual(out.messages, ["a", "b"])
        XCTAssertEqual(out.relocations, [.init(offset: 0x22, size: 3, kind: "messageTable")])
        try assertOnlyEpiloguesUnreached(out.bytes)
        XCTAssertEqual(try CTEventPack(bytes: out.bytes).unreachedOffsets, [0x36, 0x37, 0x40])
        XCTAssertEqual(try CTEventListing.parse(out.listing).assemble(), out.bytes)
    }

    func testLoweringSlotsPagesAndBackwardJumps() throws {
        let scene = EventScene(object: 2, funcs: [
            EventFunc(index: 1, stmts: [.ifFlag(symbol: "P", then: [.setFlag(symbol: "P")], else: [])]),
            EventFunc(index: 3, stmts: [.jump(funcIndex: 1)]),
        ])
        let out = try CTEventLowering.lower(scenes: [scene], flag: flag)
        let p = try CTEventPack(bytes: out.bytes)
        XCTAssertEqual(p.objectCount, 3)
        XCTAssertTrue(out.relocations.isEmpty)
        XCTAssertFalse(out.bytes.contains(0xB8))
        let code = Array(out.bytes[(1 + p.headerSize)...])
        // Objects 0 and 1 are placeholders: return, halt.
        XCTAssertEqual(Array(code[0..<4]), [0x00, 0xB2, 0x00, 0xB2])
        XCTAssertEqual(Array(code[4..<9]), [0x16, 0x05, 0x80, 0x86, 0x04])   // page bit in cmp, $7F:0105
        XCTAssertEqual(Array(code[9..<12]), [0x65, 0x87, 0x05])               // page bit in the bit operand
        XCTAssertEqual(code[14], 0x11, "jump back to func 1")
        XCTAssertEqual(p.instructions[p.headerSize + 14]?.jumpTarget, p.functions[2][1])
        try assertOnlyEpiloguesUnreached(out.bytes)
    }

    func testLoweringRefusals() throws {
        func lower(_ stmts: [EventStmt], object: Int = 0) throws {
            _ = try CTEventLowering.lower(scenes: [EventScene(object: object, funcs: [EventFunc(index: 0, stmts: stmts)])],
                                          flag: flag)
        }
        XCTAssertThrowsError(try lower([.call(map: "overworld", funcIndex: 1)]))
        XCTAssertThrowsError(try lower([.setFlag(symbol: "missing")]))
        XCTAssertThrowsError(try lower([.jump(funcIndex: 4)]))
        XCTAssertThrowsError(try lower([.nop], object: 16))
        XCTAssertThrowsError(try lower([.ifFlag(symbol: "F", then: Array(repeating: .wait(frames: 1), count: 200), else: [])]))
        XCTAssertThrowsError(try lower([.text(stringID: "x")] + (0..<256).map { .text(stringID: "m\($0)") }))
        XCTAssertThrowsError(try CTEventLowering.memoryBit(addr: "7F:0200", bit: 0, symbol: "x"))
        XCTAssertThrowsError(try CTEventLowering.memoryBit(addr: "7E:0000", bit: 0, symbol: "x"))
        XCTAssertThrowsError(try CTEventLowering.memoryBit(addr: "7F:0000", bit: 8, symbol: "x"))
        let a = EventScene(object: 1, funcs: [EventFunc(index: 0, stmts: [])])
        XCTAssertThrowsError(try CTEventLowering.lower(scenes: [a, a], flag: flag))
    }

    func testFixtureSceneWithMapCallIsRefusedButLocalSceneLowers() throws {
        var project = try CTProject.load(from: fixtureURL())
        XCTAssertThrowsError(try CTEventLowering.lower(project: project, scenes: ["intro"])) { error in
            XCTAssertTrue("\(error)".contains("cross-map"), "\(error)")
        }
        var scene = project.scenes["intro"]!
        scene.scene.funcs[0].stmts.removeAll { if case .call = $0 { return true }; return false }
        project.scenes["intro"] = scene
        let out = try CTEventLowering.lower(project: project, scenes: ["intro"])
        XCTAssertEqual(out.messages, ["greeting", "shop", "intro"])
        try assertOnlyEpiloguesUnreached(out.bytes)
    }

    // MARK: ROM (skipped without the user's ROM)

    func testEveryROMPackMatchesTheHandlerTracedManifest() throws {
        guard let rom = try? [UInt8](Repo.romData()) else { throw XCTSkip("local ROM not present") }
        let manifest = Repo.root.appendingPathComponent("re_workspace/manifests/event_pack_verification.json")
        struct Doc: Decodable {
            struct Pack: Decodable {
                let label: String; let pointerIndices: [Int]; let sha256: String
                let objects: Int?; let instructions: Int?; let dataBytes: Int?; let instructionDigest: String?
            }
            let packs: [Pack]; let nonEventPointerIndices: [Int]
        }
        let doc = try JSONDecoder().decode(Doc.self, from: Data(contentsOf: manifest))
        XCTAssertEqual(doc.packs.count, 462)
        let entries = try CTEventROM.entries(rom: rom)
        XCTAssertEqual(entries.count, 513)
        var instructions = 0
        for record in doc.packs where record.objects != nil {
            let bytes = try CTEventROM.unpack(rom: rom, entry: entries[record.pointerIndices[0]])
            XCTAssertEqual(CTEventPack.sha256(bytes), record.sha256, record.label)
            let pack = try CTEventPack(bytes: bytes)
            XCTAssertEqual(pack.instructionDigest, record.instructionDigest, record.label)
            XCTAssertEqual(pack.dataByteCount, record.dataBytes, record.label)
            XCTAssertEqual(try CTEventListing.program(pack).assemble(), bytes, record.label)
            instructions += pack.instructions.count
        }
        XCTAssertGreaterThan(instructions, 50_000)
    }
}
