// CTDialogueTests.swift — the dialogue box decode and layout against
// ct_dialogue.py's synthetic vectors, the box through PPUReferenceRenderer
// with a hand-made font and frame, the page and overflow helpers, and (local
// ROM) every corpus table's first messages laid out and a page rendered.
import XCTest
import CryptoKit
@testable import ChronoForgeCore

final class CTDialogueTests: XCTestCase {
    struct Vectors: Decodable {
        struct Region: Decodable { var at: String; var hex: String }
        struct Settings: Decodable {
            var names: [[UInt8]], party: [Int], item: Int, args: [UInt8], numHex: Bool, place: Int, press: Int
        }
        struct Layout: Decodable {
            var message: Int, settings: Int
            var frames: Int, glyphs: Int, glyphFrames: [Int], pens: [Int], lines: [Int], keyFrames: [Int]
            var pageCodes: [Int], uploads: Int, uploadDigest: String
        }
        var schema: String
        var textAt: String
        var messageStride: Int
        var regions: [Region]
        var settings: [Settings]
        var layouts: [Layout]
    }

    func vectors() throws -> (Vectors, [String: Any], [UInt8]) {
        let data = try resourceData("dialogue/dialogue_vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: data)
        XCTAssertEqual(v.schema, "ct-dialogue-vectors/1")
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var image = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        for r in v.regions {
            let at = CTDialogueROM.pc(try XCTUnwrap(CTSpriteROM.parseSNES(r.at)))
            let b = CTSpritesTests.bytes(r.hex)
            image.replaceSubrange(at..<(at + b.count), with: b)
        }
        return (v, raw, image)
    }

    static func sha(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    static func wordsLE(_ rows: [[UInt16]]) -> [UInt8] {
        var out: [UInt8] = []
        for row in rows {
            for w in row {
                out.append(UInt8(w & 0xFF))
                out.append(UInt8(w >> 8))
            }
        }
        return out
    }

    func testLayoutsMatchThePythonVectors() throws {
        let (v, _, image) = try vectors()
        let mem = CTDialogueMemory(rom: image)
        let textAt = try XCTUnwrap(CTSpriteROM.parseSNES(v.textAt))
        XCTAssertEqual(v.layouts.count, 16)
        for want in v.layouts {
            let s = v.settings[want.settings]
            let settings = CTDialogueSettings(names: s.names, party: s.party, item: s.item, args: s.args,
                                              numHex: s.numHex, place: s.place, press: s.press)
            let at = textAt + v.messageStride * want.message
            let got = try CTDialogueLayout(mem: mem, text: at, settings: settings).summary
            let label = "message \(want.message) settings \(want.settings)"
            XCTAssertEqual(got.frames, want.frames, label)
            XCTAssertEqual(got.glyphs, want.glyphs, label)
            XCTAssertEqual(got.glyphFrames, want.glyphFrames, label)
            XCTAssertEqual(got.pens, want.pens, label)
            XCTAssertEqual(got.lines, want.lines, label)
            XCTAssertEqual(got.keyFrames, want.keyFrames, label)
            XCTAssertEqual(got.pageCodes, want.pageCodes, label)
            XCTAssertEqual(got.uploads, want.uploads, label)
            XCTAssertEqual(got.uploadDigest, want.uploadDigest, label)
        }
    }

    func testFontMatchesThePythonVectors() throws {
        let (_, raw, image) = try vectors()
        let mem = CTDialogueMemory(rom: image)
        let font = try XCTUnwrap(raw["font"] as? [String: Any])
        let codes: [Int] = Array(0xA0..<0x100) + Array(0x100..<0x120)
        XCTAssertEqual(CTDialogueFont.digest(mem, codes: codes), font["digest"] as? String)
        let a0: [Int] = CTDialogueFont.pixels(mem, 0xA0).flatMap { $0.map { Int($0) } }
        XCTAssertEqual(a0, font["glyphA0"] as? [Int])
        let w101: [Int] = CTDialogueFont.pixels(mem, 0x101).flatMap { $0.map { Int($0) } }
        XCTAssertEqual(w101, font["glyph101"] as? [Int])
        let widths: [Int] = (0xA0..<0x100).map { CTDialogueFont.width(mem, $0) }
        XCTAssertEqual(widths, font["widths"] as? [Int])
    }

    func testWindowMatchesThePythonVectors() throws {
        let (_, raw, image) = try vectors()
        let mem = CTDialogueMemory(rom: image)
        let window = try XCTUnwrap(raw["window"] as? [String: Any])
        let palette: [Int] = CTDialogueWindow.palette(mem, style: 3).dropFirst().map { Int($0 ?? 0) }
        XCTAssertEqual(palette, window["palette3"] as? [Int])
        let (tiles, alt) = CTDialogueWindow.frameSet(mem, style: 5)
        XCTAssertEqual(Self.sha(tiles + alt), window["frame5"] as? String)
        XCTAssertEqual(Self.sha(Self.wordsLE(CTDialogueWindow.frameTilemap())), window["frameTilemap"] as? String)
        XCTAssertEqual(Self.sha(Self.wordsLE(CTDialogueWindow.textTilemap())), window["textTilemap"] as? String)
        let grad: [[Int]] = CTDialogueWindow.gradient().map { [Int($0.0), Int($0.1)] }
        XCTAssertEqual(grad, window["gradient"] as? [[Int]])
        let bands = try XCTUnwrap(window["band"] as? [String: Any])
        for (n, place) in [(4, 1), (12, 2), (40, 1)] {
            let want = try XCTUnwrap(bands["\(n),\(place)"] as? [Any])
            let (first, lines) = CTDialogueWindow.band(n: n, place: place)
            XCTAssertEqual(first, want[0] as? Int)
            let wantLines = try XCTUnwrap(want[1] as? [[Any]])
            XCTAssertEqual(lines.count, wantLines.count)
            for (k, line) in lines.enumerated() {
                let w = wantLines[k]
                XCTAssertEqual(Int(line.tm), w[0] as? Int)
                let math: Int? = w[1] as? Int
                XCTAssertEqual(line.cgadsub.map { Int($0) }, math)
                XCTAssertEqual(Int(line.coldata), w[2] as? Int)
            }
        }
    }

    // MARK: A hand-made font and frame through the PPU

    /// Glyph $A0: pixel (r, c) = (r + c) % 4; width 12. Frame style 0: every pixel colour 1.
    static func handMade() -> [UInt8] {
        var image = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        func put(_ long: Int, _ bytes: [UInt8]) {
            let at = CTDialogueROM.pc(long)
            image.replaceSubrange(at..<(at + bytes.count), with: bytes)
        }
        var left = [UInt8](repeating: 0, count: 24)
        var right = [UInt8](repeating: 0, count: 24)
        for r in 0..<12 {
            for c in 0..<12 {
                let v = (r + c) % 4
                for plane in 0..<2 where v >> plane & 1 == 1 {
                    if c < 8 {
                        left[2 * r + plane] |= UInt8(0x80 >> c)
                    } else {
                        right[2 * r + plane] |= UInt8(0x80 >> (c - 8))
                    }
                }
            }
        }
        put(CTDialogueROM.font + 24 * 0xA0, left)
        put(CTDialogueROM.fontRight + 24 * 0x50, right)       // even glyph: the high nibbles
        put(CTDialogueROM.widths, [12])
        put(CTDialogueROM.frameSrcs, [0x10, 0x9E])
        var frame: [UInt8] = []
        for _ in 0..<20 {
            for row in 0..<8 {
                _ = row
                frame += [0xFF, 0x00]                       // plane 0 set, plane 1 clear
            }
            frame += [UInt8](repeating: 0, count: 16)       // planes 2/3 clear: colour 1
        }
        put(0xFF9E10, frame)
        put(CTDialogueROM.palSets + 2, [0x4A, 0x29])        // colour 1 = (10, 10, 10)
        put(0xC80000, [0xA0, 0x00])
        return image
    }

    func testHandMadeGlyphAndFrameOnScreen() throws {
        let image = Self.handMade()
        let settings = CTDialogueSettings(place: 1, press: 3)
        let layout = try CTDialogueLayout(mem: CTDialogueMemory(rom: image), text: 0xC80000, settings: settings)
        XCTAssertEqual(layout.glyphs.map(\.pen), [CTDialogueROM.penLeft])
        let at = try XCTUnwrap(layout.pageFrame(0))
        let box = CTDialogueBox(rom: image, style: 0, backdrop: 0x001F)
        let rgba = box.render(layout, at: at)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            let o = (y * 256 + x) * 4
            return Array(rgba[o..<(o + 3)])
        }
        let greys: [UInt16] = [0, 0x0C63, 0x18C6, 0x739C]
        // Text line 0: glyph rows on screen lines 18-29 (BG3 V -$0F), pen 8.
        for r in 0..<12 {
            for c in 0..<12 {
                let v = (r + c) % 4
                guard v != 0 else { continue }
                let w = greys[v]
                let want: [UInt8] = [UInt8(w & 31), UInt8(w >> 5 & 31), UInt8(w >> 10 & 31)].map {
                    PPUReferenceRenderer.output8(Int($0), brightness: 15)
                }
                XCTAssertEqual(pixel(8 + c, 18 + r), want, "glyph pixel \(r),\(c)")
            }
        }
        // The frame behind: colour 1 (10, 10, 10) plus the gradient's first steps (+8, +7, ...).
        let first = CTDialogueROM.bandCentre[1]! - (CTDialogueROM.openSize - 1)
        XCTAssertEqual(first, 8)
        let plus8 = PPUReferenceRenderer.output8(18, brightness: 15)
        XCTAssertEqual(pixel(100, 8), [plus8, plus8, plus8])
        let plus7 = PPUReferenceRenderer.output8(17, brightness: 15)
        XCTAssertEqual(pixel(100, 13), [plus7, plus7, plus7])
        // Outside the band: the backdrop (red).
        XCTAssertEqual(pixel(100, 7), [255, 0, 0])
        XCTAssertEqual(pixel(100, 88), [255, 0, 0])
        XCTAssertEqual(CTDialogueBox.boxLines(place: 1), 8..<88)
        XCTAssertEqual(CTDialogueBox.boxLines(place: 2), 131..<211)
        // Before the window opens nothing shows.
        let closed = box.render(layout, at: 0)
        XCTAssertEqual(Array(closed[((40 * 256 + 100) * 4)..<((40 * 256 + 100) * 4 + 3)]), [255, 0, 0])
    }

    func testPagesKeysAndOverflow() throws {
        let image = Self.handMade()
        let mem = CTDialogueMemory(rom: image)
        // Two pages (a page-after-key code), then 21 glyphs of 12 pixels: past x 248.
        var message: [UInt8] = [0xA0, 0x0B, 0xA0]
        message += [UInt8](repeating: 0xA0, count: 20)
        message.append(0)
        let layout = try CTDialogueLayout.bytes(message, rom: mem.rom, settings: CTDialogueSettings(press: 2))
        XCTAssertEqual(layout.pageCount, 2)
        XCTAssertEqual(layout.events.filter { $0.kind == .key }.count, 2)
        let p0 = try XCTUnwrap(layout.pageFrame(0)), p1 = try XCTUnwrap(layout.pageFrame(1))
        XCTAssertLessThan(p0, p1)
        XCTAssertNil(layout.pageFrame(2))
        let over = layout.overflows
        XCTAssertEqual(over.first?.page, 1)
        XCTAssertEqual(over.first?.pen, 8 + 12 * 20)      // ends at 260: past 248 and the 8-bit pen
        XCTAssertTrue(over.first?.wraps ?? false)
        XCTAssertEqual(layout.frames.last?.state, 0)
        let opens: [Int] = layout.frames.map(\.open)
        XCTAssertEqual(opens.max(), CTDialogueROM.openSize - 1)
    }

    func testWaitsAreFifteenFramesAUnit() throws {
        let image = Self.handMade()
        let plain = try CTDialogueLayout.bytes([0xA0, 0xA0, 0], rom: image, settings: CTDialogueSettings())
        let waited = try CTDialogueLayout.bytes([0xA0, 3, 2, 0xA0, 0], rom: image, settings: CTDialogueSettings())
        let gap = waited.glyphs[1].frame - waited.glyphs[0].frame
        XCTAssertGreaterThan(gap, 2 * CTDialogueROM.waitUnit)
        XCTAssertEqual(plain.glyphs[1].frame - plain.glyphs[0].frame, 1)
    }

    // MARK: Local ROM

    func testCorpusTablesLayOutAndRender() throws {
        let rom = [UInt8](try Repo.romData())
        let mem = CTDialogueMemory(rom: rom)
        XCTAssertEqual(CTDialogueFont.glyphCodes.count, 608)
        let widths: [Int] = (0xA0..<0x100).map { CTDialogueFont.width(mem, $0) }
        XCTAssertLessThanOrEqual(widths.max() ?? 99, 11)
        var laidOut = 0
        for table in [0xD8D000, 0xF70000, 0xF74900] {
            for index in 0..<8 {
                let at = CTDialogueLayout.messageAddress(rom: rom, table: table, index: index)
                guard let layout = try? CTDialogueLayout(mem: mem, text: at, settings: .placeholder()) else { continue }
                XCTAssertEqual(layout.frames.last?.state, 0)
                laidOut += 1
            }
        }
        XCTAssertGreaterThan(laidOut, 8)
        let at = CTDialogueLayout.messageAddress(rom: rom, table: 0xD8D000, index: 0)
        let layout = try CTDialogueLayout(mem: mem, text: at, settings: .placeholder())
        let page = try XCTUnwrap(layout.pageFrame(0))
        let rgba = CTDialogueBox(mem: mem).render(layout, at: page)
        var lit = 0
        for y in CTDialogueBox.boxLines(place: 1) {
            for x in 0..<256 where rgba[(y * 256 + x) * 4] | rgba[(y * 256 + x) * 4 + 1] != 0 { lit += 1 }
        }
        XCTAssertGreaterThan(lit, 256)
    }
}
