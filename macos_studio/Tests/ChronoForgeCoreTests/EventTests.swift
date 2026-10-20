import XCTest
@testable import ChronoForgeCore

final class EventTests: XCTestCase {
    func testLongDialogueDoesNotTrapOrChangeLiteralTokens() {
        for text in [String(repeating: "雪", count: 1000),
                     "e" + String(repeating: "\u{301}", count: 500),
                     "\\{name:" + String(repeating: "é", count: 300) + "}",
                     "{name:robo}", "\\{name:robo}", "\\{wait}\n\\{br}"] {
            XCTAssertEqual(TextCodec.decode(TextCodec.encode(text)), text)
        }
    }

    func testArchivePreservesObjectAndRejectsUnrecognizedFormats() throws {
        let scene = EventScene(object: 7, funcs: [EventFunc(index: 0, stmts: [.nop])])
        let data = try EventSceneArchive.encode(scene)
        XCTAssertEqual(Array(data), [0x43, 0x46, 0x53, 0x43, 1, 7, 1, 0, 0, 255])
        XCTAssertEqual(try EventSceneArchive.decode(data), scene)
        for invalid in [Data(), Data([0, 1, 2, 3, 4, 5, 6]), Data([0x43, 0x46, 0x53, 0x43, 2, 0, 0]),
                        Data([0x43, 0x46, 0x53, 0x43, 1, 16, 0]), data + Data([0])] {
            XCTAssertThrowsError(try EventSceneArchive.decode(invalid))
        }
    }

    func testWindowsLineEndingsAndComments() throws {
        let scene = try EventDSL.parse("# title\r\nobj 0 { // header\r\n func 0 { nop }\r\n}")
        XCTAssertEqual(scene.funcs.first?.stmts, [.nop])
        XCTAssertThrowsError(try EventDSL.parse("obj 0 {\r\n func 0 {\r\n  invalid } }")) { error in
            XCTAssertEqual((error as? EventDSLError)?.line, 3)
        }
    }

    func testLegacyFixtureDSLMatchesJSON() throws {
        let base = try fixtureURL().appendingPathComponent("scenes/intro.event")
        let doc = try JSONDecoder().decode(SceneDoc.self, from: Data(contentsOf: base.appendingPathExtension("json")))
        let scene = try EventDSL.parse(String(contentsOf: base.appendingPathExtension("dsl"), encoding: .utf8))
        XCTAssertEqual(scene.funcs, doc.scene.funcs)
        XCTAssertEqual(scene.object, doc.scene.object)
    }

    func testConditionalWithoutElseAndFollowingStatement() throws {
        let funcs = [EventFunc(index: 0, stmts: [
            .ifFlag(symbol: "ready", then: [.wait(frames: 7)], else: []), .text(stringID: "next")])]
        // Fixed golden encoding, independent of the compiler.
        let bytes: [UInt8] = [1, 0, 7, 5, 114, 101, 97, 100, 121, 1, 7, 0, 9, 4, 4, 110, 101, 120, 116, 255]
        XCTAssertEqual(try EventBytecode.compile(funcs), bytes)
        XCTAssertEqual(try EventBytecode.decompile(bytes), funcs)
    }

    func testAllOperationsAndEscapedUnicodeRoundTrip() throws {
        let scene = EventScene(object: 15, funcs: [EventFunc(index: 0, stmts: [
            .nop, .wait(frames: 65535), .setFlag(symbol: "flag"), .clearFlag(symbol: "flag"),
            .text(stringID: "雪 \"quoted\"\n\\ # //"), .call(map: "map #1", funcIndex: 15),
            .ifFlag(symbol: "flag", then: [.ifFlag(symbol: "b", then: [], else: [.nop])], else: [.wait(frames: 0)]),
            .jump(funcIndex: 0)])])
        let source = EventDSL.format(scene)
        XCTAssertEqual(try EventDSL.parse(source), scene)
        XCTAssertEqual(EventDSL.format(try EventDSL.parse(source)), source)
        XCTAssertEqual(try EventBytecode.decompile(EventBytecode.compile(scene.funcs)), scene.funcs)
    }

    func testSyntaxErrorsHaveSourceLocations() throws {
        XCTAssertThrowsError(try EventDSL.parse("obj 0 {\n func 0 {\n  dance\n }\n}")) { error in
            guard let diagnostic = error as? EventDSLError else { return XCTFail("wrong error") }
            XCTAssertEqual(diagnostic.line, 3)
            XCTAssertEqual(diagnostic.column, 3)
            XCTAssertTrue(diagnostic.message.contains("dance"))
        }
        for text in ["", "obj 0 { func 0 {", "obj 16 {}", "obj 0 { func 0 {} func 0 {} }",
                     "obj 0 {} garbage", "obj 0 { func 0 { wait -1 } }",
                     "obj 0 { func 0 { text \"unterminated } }", "obj 0 { func 0 { jump func1 } }"] {
            XCTAssertThrowsError(try EventDSL.parse(text), text)
        }
        let deep = "obj 0 { func 0 { " + String(repeating: "if f { ", count: 66) + String(repeating: "} ", count: 68)
        XCTAssertThrowsError(try EventDSL.parse(deep))
    }

    func testCommentsAndWhitespace() throws {
        let source = "# comment\nobj 0 { // header\n func 0 { call map#1 // call\n nop }\n}"
        XCTAssertEqual(try EventDSL.parse(source).funcs[0].stmts, [.call(map: "map", funcIndex: 1), .nop])
    }

    func testCompilerRejectsLossyValues() {
        for stmt: EventStmt in [.wait(frames: -1), .wait(frames: 65536), .call(map: "x", funcIndex: 256),
                                .text(stringID: ""), .text(stringID: String(repeating: "é", count: 128)),
                                .jump(funcIndex: 1)] {
            XCTAssertThrowsError(try EventBytecode.compile([EventFunc(index: 0, stmts: [stmt])]))
        }
        XCTAssertThrowsError(try EventBytecode.compile([EventFunc(index: 0, stmts: []), EventFunc(index: 0, stmts: [])]))
        XCTAssertThrowsError(try EventBytecode.validate(EventScene(object: -1, funcs: [])))
    }

    func testMalformedBytecodeFailsClosed() throws {
        let valid = try EventBytecode.compile([EventFunc(index: 0, stmts: [.ifFlag(symbol: "f", then: [.nop], else: [.wait(frames: 2)])])])
        for count in 0..<valid.count { XCTAssertThrowsError(try EventBytecode.decompile(Array(valid.prefix(count)))) }
        for malformed: [UInt8] in [valid + [0], [1,0,4,1,0xFF,0xFF], [1,0,8,255], [1,0,9,255],
                                    [1,0,42,255], [2,0,255,0,255], [1,16,255]] {
            XCTAssertThrowsError(try EventBytecode.decompile(malformed))
        }
    }

    func testNestedReferencesAreValidatedInBothBranches() throws {
        var project = try CTProject.load(from: fixtureURL())
        project.scenes["intro"]!.scene.funcs = [EventFunc(index: 0, stmts: [
            .ifFlag(symbol: "MET_LAYLA", then: [.text(stringID: "missing_text")], else: [
                .ifFlag(symbol: "missing_flag", then: [.call(map: "missing_map", funcIndex: 0)], else: [])])])]
        let errors = Validator.validate(project).filter { $0.gate == 1 }.map(\.message).joined()
        for missing in ["missing_text", "missing_flag", "missing_map"] { XCTAssertTrue(errors.contains(missing)) }
    }

    func testPreviewBranchTimingAndFlags() throws {
        let scene = try EventDSL.parse("""
        obj 0 { func 0 {
          set_flag ready
          if ready { wait 30 text greeting } else { wait 99 }
          clear_flag ready
          jump func1
          wait 500
        } func 1 { wait 2 } }
        """)
        let result = try EventPreview.run(scene, dialogue: ["greeting": "Hello"])
        XCTAssertEqual(result.elapsedFrames, 32)
        XCTAssertEqual(result.flags, [])
        XCTAssertEqual(result.entries.first(where: { $0.detail == "Hello" })?.frame, 30)
        XCTAssertEqual(result.entries.last?.function, 1)
        XCTAssertEqual(result.stopReason, "Function completed")
        let conditional = try EventDSL.parse("obj 0 { func 0 { if ready { wait 4 } else { wait 9 } } }")
        XCTAssertEqual(try EventPreview.run(conditional, flags: ["ready"]).elapsedFrames, 4)
        XCTAssertEqual(try EventPreview.run(conditional).elapsedFrames, 9)
    }

    func testPreviewStopsAtExternalCallsAndBoundsLoops() throws {
        let loop = try EventDSL.parse("obj 0 { func 0 { jump func0 } }")
        let result = try EventPreview.run(loop, stepLimit: 7)
        XCTAssertEqual(result.entries.count, 7)
        XCTAssertTrue(result.stopReason.contains("Step limit"))
        let call = try EventDSL.parse("obj 0 { func 0 { call map#1 wait 99 } }")
        let boundary = try EventPreview.run(call)
        XCTAssertEqual(boundary.elapsedFrames, 0)
        XCTAssertTrue(boundary.stopReason.contains("external call"))
        XCTAssertThrowsError(try EventPreview.run(loop, entry: 1))
        XCTAssertThrowsError(try EventPreview.run(loop, stepLimit: 0))
    }

    func testProjectLoadsAuthoritativeDSLAndSavesBothForms() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Scene-\(UUID()).ctproj")
        try FileManager.default.copyItem(at: fixtureURL(), to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let sourceURL = tmp.appendingPathComponent("scenes/intro.event.dsl")
        try "obj 1 { func 0 { wait 42 } }".write(to: sourceURL, atomically: true, encoding: .utf8)
        var p = try CTProject.load(from: tmp)
        XCTAssertEqual(p.scenes["intro"]!.scene.object, 1)
        XCTAssertEqual(p.scenes["intro"]!.scene.funcs[0].stmts, [.wait(frames: 42)])
        XCTAssertTrue(p.scenes["intro"]!.scene.layout.isEmpty)
        p.scenes["intro"]!.scene.layout = [NodeMeta(nodeID: 0, x: 100, y: 200)]
        try p.save()
        let reloaded = try CTProject.load(from: tmp)
        XCTAssertEqual(reloaded.scenes, p.scenes)
        XCTAssertTrue(Validator.isValid(Validator.validate(reloaded)))
        let doc = try JSONDecoder().decode(SceneDoc.self, from: Data(contentsOf: tmp.appendingPathComponent("scenes/intro.event.json")))
        XCTAssertEqual(doc.scene, p.scenes["intro"]!.scene)
        // Invalid edits must fail before any project file is changed.
        let before = try Data(contentsOf: tmp.appendingPathComponent("project.json"))
        p.project.name = "must not be saved"
        p.scenes["intro"]!.scene.object = 256
        XCTAssertThrowsError(try p.save())
        XCTAssertEqual(try Data(contentsOf: tmp.appendingPathComponent("project.json")), before)
        try "obj 0 { broken }".write(to: sourceURL, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try CTProject.load(from: tmp))
    }
}
