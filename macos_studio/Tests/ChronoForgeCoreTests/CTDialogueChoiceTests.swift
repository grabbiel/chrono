// CTDialogueChoiceTests.swift — the box's place, Sub_1ADF's cursor steps and
// Irq_DrawChoiceCursor's VRAM writes against ct_boxchoice.py's vectors, and
// the cursor on screen in the hand-made box of CTDialogueTests.
import XCTest
@testable import ChronoForgeCore

final class CTDialogueChoiceTests: XCTestCase {
    struct Vectors: Decodable {
        struct Cursor: Decodable { var row: Int; var after: Int; var writes: [[Int]] }
        var schema: String
        var opcodes: [String: Int]
        var places: [[Int]]
        var walks: [Walk]
        var subs: [[Int]]
        var cursors: [Cursor]

        struct Walk: Decodable {
            var operand: Int, trail: [Int]
            init(from decoder: Decoder) throws {
                var c = try decoder.unkeyedContainer()
                operand = try c.decode(Int.self)
                trail = try c.decode([Int].self)
            }
        }
    }

    func vectors() throws -> Vectors {
        let v = try JSONDecoder().decode(Vectors.self, from: try resourceData("dialogue/choice_vectors.json"))
        XCTAssertEqual(v.schema, "ct-choice-vectors/1")
        return v
    }

    func testPlacesMatchThePythonVectors() throws {
        let v = try vectors()
        for (hex, unk30) in v.opcodes {
            let op = try XCTUnwrap(Int(hex, radix: 16))
            XCTAssertEqual(CTBoxPlace.opcodeUnk30[op], unk30, hex)
        }
        XCTAssertEqual(CTBoxPlace.opcodeUnk30.count, v.opcodes.count)
        XCTAssertGreaterThan(v.places.count, 50)
        for p in v.places {
            XCTAssertEqual(CTBoxPlace.place(unk30: p[0], screenY: p[1]), p[2], "\(p)")
        }
        XCTAssertEqual(CTBoxPlace.place(opcode: 0xBB, screenY: 0x40), CTBoxPlace.bottom)
        XCTAssertEqual(CTBoxPlace.place(opcode: 0xC0, screenY: 0xC0), CTBoxPlace.top)
        XCTAssertEqual(CTBoxPlace.place(opcode: 0xC2, screenY: 0xC0), CTBoxPlace.bottom)
        XCTAssertNil(CTBoxPlace.place(opcode: 0xB8, screenY: 0))
        XCTAssertTrue(CTBoxPlace.followsSpeaker(opcode: 0xC0))
        XCTAssertFalse(CTBoxPlace.followsSpeaker(opcode: 0xC3))
    }

    func testSub1ADFMatchesThePythonVectors() throws {
        let v = try vectors()
        XCTAssertGreaterThan(v.subs.count, 400)
        for s in v.subs {
            let got = CTChoice.sub1ADF(f62: s[0], f63: s[1], f64: s[2], f65: s[3], f66: s[4], f6: s[5], f7: s[6],
                                       f8: s[7], f34: s[8])
            XCTAssertEqual([got.f62, got.f63, got.f66, got.f34], Array(s[9..<13]), "\(s)")
        }
        for w in v.walks {
            let choice = CTChoice(operand: w.operand)
            var cursor = choice.first
            var trail = [cursor]
            let keys: [CTChoice.Key?] = [.down, .down, .down, .down, .up, .up, .up, .up, .up, nil]
            for k in keys {
                cursor = choice.step(cursor, k)
                trail.append(cursor)
            }
            XCTAssertEqual(trail, w.trail, "operand \(w.operand)")
        }
        // Operand $06: lines 1-2.
        let c = CTChoice(operand: 0x06)
        XCTAssertEqual([c.first, c.last], [1, 2])
        XCTAssertEqual(c.step(2, .down), 1)
        XCTAssertEqual(c.step(1, .up), 2)
    }

    func testCursorWritesMatchThePythonVectors() throws {
        let v = try vectors()
        for want in v.cursors {
            let got = CTChoiceCursor.writes(row: want.row)
            XCTAssertEqual(got.after, want.after, "row \(want.row)")
            XCTAssertEqual(got.writes.map { [$0.address, Int($0.word)] }, want.writes, "row \(want.row)")
        }
    }

    func testCursorOnScreenInTheBox() throws {
        var image = CTDialogueTests.handMade()
        // A synthetic cursor: all four characters colour 3 (both planes set).
        let at = CTDialogueROM.pc(CTChoiceROM.gfx)
        image.replaceSubrange(at..<(at + CTChoiceROM.gfxBytes), with: [UInt8](repeating: 0xFF, count: CTChoiceROM.gfxBytes))
        let mem = CTDialogueMemory(rom: image)
        // Three short lines ($05 new line), then the end.
        let message: [UInt8] = [0xA0, 0x05, 0xA0, 0x05, 0xA0, 0x00]
        let layout = try CTDialogueLayout.bytes(message, rom: image, settings: CTDialogueSettings(place: 1, press: 3))
        let first = try XCTUnwrap(CTChoiceCursor.firstFrame(layout))
        let end = try XCTUnwrap(layout.pageFrame(0))
        XCTAssertLessThanOrEqual(first, end)
        XCTAssertEqual(layout.frames[first].state, 7)
        let box = CTDialogueBox(mem: mem, style: 0, backdrop: 0x001F)
        let grey = PPUReferenceRenderer.output8(Int(0x739C & 31), brightness: 15)
        for row in 0..<3 {
            let rgba = box.render(layout, at: end, cursor: row)
            func pixel(_ x: Int, _ y: Int) -> [UInt8] {
                let o = (y * 256 + x) * 4
                return Array(rgba[o..<(o + 3)])
            }
            // Text line j: tile rows from screen line 14 + 16 j; the cursor at columns 2-3 (x 16-31).
            // The band shows BG3 from line 18 on (TM: its first 10 lines BG1 only), so line 0's
            // cursor loses its top 4 lines, as the text does.
            let bg3From = CTDialogueBox.boxLines(place: 1).lowerBound + 10
            XCTAssertEqual(bg3From, 18)
            for y in 0..<16 where 14 + 16 * row + y >= bg3From {
                for x in 16..<32 { XCTAssertEqual(pixel(x, 14 + 16 * row + y), [grey, grey, grey], "row \(row) \(x),\(y)") }
            }
            if row == 0 { XCTAssertNotEqual(pixel(20, 15), [grey, grey, grey]) }
            let other = (row + 1) % 3
            XCTAssertNotEqual(pixel(24, 14 + 16 * other + 8), [grey, grey, grey], "row \(other) has no cursor")
        }
        // Before the end wait: no cursor.
        let early = box.render(layout, at: max(0, first - 2), cursor: 0)
        let o = ((14 + 8) * 256 + 24) * 4
        XCTAssertNotEqual(Array(early[o..<(o + 3)]), [grey, grey, grey])
        XCTAssertEqual(CTChoiceCursor.pixels(mem).flatMap { $0 }.filter { $0 == 3 }.count, 256)
    }
}
