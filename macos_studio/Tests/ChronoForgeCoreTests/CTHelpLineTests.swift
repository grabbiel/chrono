// CTHelpLineTests.swift — the menu help line against ct_helpline.py's
// synthetic vectors, its picture through PPUReferenceRenderer, and (local
// ROM) every item and tech description laid out and checked to fit.
import XCTest
@testable import ChronoForgeCore

final class CTHelpLineTests: XCTestCase {
    struct Vectors: Decodable {
        struct Region: Decodable { var at: String; var hex: String }
        struct Settings: Decodable {
            var names: [[UInt8]], party: [Int], item: Int, args: [UInt8], numHex: Bool, place: Int, press: Int
        }
        struct Line: Decodable {
            var place: String, text: Int, settings: Int
            var error: String?
            var frames: Int?, glyphs: Int?, pens: [Int]?, lines: Int?, right: Int?, rightX: Int?
            var wraps: Bool?, pastRow: Bool?, fits: Bool?, uploads: Int?
            var uploadDigest: String?, rows: String?, pixels: String?
        }
        var schema: String
        var table: String
        var regions: [Region]
        var settings: [Settings]
        var lines: [Line]
    }

    func vectors() throws -> (Vectors, CTDialogueMemory) {
        let data = try resourceData("dialogue/helpline_vectors.json")
        let v = try JSONDecoder().decode(Vectors.self, from: data)
        XCTAssertEqual(v.schema, "ct-helpline-vectors/1")
        var image = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        for r in v.regions {
            let at = CTDialogueROM.pc(try XCTUnwrap(CTSpriteROM.parseSNES(r.at)))
            let b = CTSpritesTests.bytes(r.hex)
            image.replaceSubrange(at..<(at + b.count), with: b)
        }
        return (v, CTDialogueMemory(rom: image))
    }

    func testLinesMatchThePythonVectors() throws {
        let (v, mem) = try vectors()
        let table = try XCTUnwrap(CTSpriteROM.parseSNES(v.table))
        XCTAssertEqual(v.lines.count, 24)
        for want in v.lines {
            let s = v.settings[want.settings]
            let settings = CTDialogueSettings(names: s.names, party: s.party, item: s.item, args: s.args,
                                              numHex: s.numHex, place: s.place, press: s.press)
            let place = try XCTUnwrap(CTHelpLine.Place(rawValue: want.place))
            let text = (table & 0xFF0000) | mem.word(table + 2 * want.text)
            let label = "\(want.place) text \(want.text) settings \(want.settings)"
            if let error = want.error {
                XCTAssertThrowsError(try CTHelpLine(mem: mem, text: text, place: place, settings: settings), label) { e in
                    XCTAssertEqual("\(e)", error, label)
                }
                continue
            }
            let got = try CTHelpLine(mem: mem, text: text, place: place, settings: settings).summary
            XCTAssertEqual(got.frames, want.frames, label)
            XCTAssertEqual(got.glyphs, want.glyphs, label)
            XCTAssertEqual(got.pens, want.pens, label)
            XCTAssertEqual(got.lines, want.lines, label)
            XCTAssertEqual(got.right, want.right, label)
            XCTAssertEqual(got.rightX, want.rightX, label)
            XCTAssertEqual(got.wraps, want.wraps, label)
            XCTAssertEqual(got.pastRow, want.pastRow, label)
            XCTAssertEqual(got.fits, want.fits, label)
            XCTAssertEqual(got.uploads, want.uploads, label)
            XCTAssertEqual(got.uploadDigest, want.uploadDigest, label)
            XCTAssertEqual(got.rows, want.rows, label)
            XCTAssertEqual(got.pixels, want.pixels, label)
        }
    }

    func testPictureThroughThePPU() throws {
        let (v, mem) = try vectors()
        let table = try XCTUnwrap(CTSpriteROM.parseSNES(v.table))
        let line = try CTHelpLine(mem: mem, text: (table & 0xFF0000) | mem.word(table), place: .item)
        let colours: [UInt16] = [0x1234, 0x001F, 0x03E0, 0x7C00]
        let backdrop: UInt16 = 0x2108
        let rgba = line.renderStrip(backdrop: backdrop, colours: colours)
        XCTAssertEqual(rgba.count, 256 * 16 * 4)
        let pix = line.pixels()
        var seen: [UInt8: [UInt8]] = [:]
        var lit = 0
        for y in 0..<16 {
            for x in 0..<256 {
                let i = (y * 256 + x) * 4
                let c = Array(rgba[i..<(i + 3)])
                let k = pix[y][x]
                if let prior = seen[k] {
                    XCTAssertEqual(prior, c, "index \(k) at \(x),\(y)")
                } else {
                    seen[k] = c
                }
                if k != 0 { lit += 1 }
            }
        }
        XCTAssertGreaterThan(lit, 50)
        XCTAssertEqual(Set(seen.values.map { $0.description }).count, seen.count, "each index its own colour")
        // Glyph $A0 ("A") at pen 8: screen x 24, glyph rows at lines 4-15.
        let first = line.glyphs[0]
        let glyph = CTDialogueFont.pixels(mem, first.glyph)
        for y in 0..<12 { XCTAssertEqual(Array(pix[4 + y][24..<(24 + first.width)]), Array(glyph[y][0..<first.width])) }
        XCTAssertEqual(CTHelpLine.Place.item.row, 2)
        XCTAssertEqual(CTHelpLine.Place.tech.row, 21)
    }

    func testEditedTextOverlaysTheROM() throws {
        let (_, mem) = try vectors()
        let one = try CTHelpLine.bytes([0xA0, 0xA1, 0x00], rom: mem.rom, place: .tech)
        XCTAssertEqual(one.glyphs.count, 2)
        XCTAssertTrue(one.fits)
        XCTAssertEqual(Set(one.uploads.filter { !$0.glyphs }.map { $0.dest }), [0x6AA0])
        let two = try CTHelpLine.bytes([0xA0, 0x05, 0xA1, 0x00], rom: mem.rom, place: .item)
        XCTAssertEqual(two.lineCount, 2)
        XCTAssertFalse(two.fits)
    }

    func testEveryROMDescriptionFits() throws {
        let rom = [UInt8](try Repo.romData())
        let mem = CTDialogueMemory(rom: rom)
        for place in CTHelpLine.Place.allCases {
            var widest = 0
            for index in 0..<place.count {
                let at = CTHelpLine.stringAddress(mem, place: place, index: index)
                let line = try CTHelpLine(mem: mem, text: at, place: place)
                XCTAssertTrue(line.fits, "\(place) \(index)")
                widest = max(widest, line.right)
                XCTAssertEqual(CTHelpLine.description(mem, place: place, index: index).isEmpty, line.frames <= 1)
            }
            XCTAssertGreaterThan(widest, 150)
        }
        let (backdrop, colours) = CTHelpLine.palette(mem)
        XCTAssertEqual(colours.count, 4)
        _ = backdrop
    }
}
