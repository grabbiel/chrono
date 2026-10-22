// CTSpritesTests.swift — the PC sprite decode against ct_sprites.py's
// synthetic vectors, the PPU scene against the vectors' composed frames,
// the indexed PNG writer, the SpriteDef extension, and (local ROM) the import.
import XCTest
@testable import ChronoForgeCore

final class CTSpritesTests: XCTestCase {
    struct Vectors: Decodable {
        struct Region: Decodable { var at: String; var hex: String }
        struct Block: Decodable { var address: String; var count: Int }
        struct Palette: Decodable { var address: String; var colours: [String] }
        struct Anims: Decodable { var frameIds: String; var durations: String; var rows: Int }
        struct Frame: Decodable { var cells: [Int]; var pieces: [[Int]] }
        struct Anim: Decodable { var id: String; var row: Int; var facing: Int; var frames: [Int]; var durations: [Int] }
        struct Composed: Decodable { var frame: Int; var left: Int; var top: Int; var width: Int; var height: Int; var indices: String }
        struct Set: Decodable {
            var set: Int
            var tiles: Block
            var frames: Block
            var palette: Palette
            var animations: Anims
            var frameList: [Frame]
            var animationList: [Anim]
            var composed: [Composed]
            var tileIndices: String
        }
        var schema: String
        var regions: [Region]
        var sets: [Set]
    }

    static func bytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    func vectors() throws -> (Vectors, [UInt8]) {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("sprites/sprite_vectors.json"))
        XCTAssertEqual(v.schema, "ct-sprite-vectors/1")
        var image = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        for r in v.regions {
            let at = CTSpriteROM.pc(try XCTUnwrap(CTSpriteROM.parseSNES(r.at)))
            let b = Self.bytes(r.hex)
            image.replaceSubrange(at..<(at + b.count), with: b)
        }
        return (v, image)
    }

    func testDecodeMatchesThePythonVectors() throws {
        let (v, image) = try vectors()
        XCTAssertEqual(v.sets.count, 2)
        for want in v.sets {
            let d = CTSpriteROM.decode(rom: image, set: want.set)
            XCTAssertEqual(CTSpriteROM.snes(d.tilesAt), want.tiles.address)
            XCTAssertEqual(d.tiles.count, want.tiles.count)
            XCTAssertEqual(CTSpriteROM.snes(d.framesAt), want.frames.address)
            XCTAssertEqual(d.frames.count, want.frames.count)
            XCTAssertEqual(CTSpriteROM.snes(d.paletteAt), want.palette.address)
            XCTAssertEqual(d.palette.map { BGR555(word: $0).hex }, want.palette.colours)
            XCTAssertEqual(CTSpriteROM.snes(d.frameIdsAt), want.animations.frameIds)
            XCTAssertEqual(CTSpriteROM.snes(d.durationsAt), want.animations.durations)
            XCTAssertEqual(d.rows, want.animations.rows)
            XCTAssertEqual(d.frames.map { $0.cells }, want.frameList.map { $0.cells })
            XCTAssertEqual(d.frames.map { $0.pieces.map { [$0.x, $0.y] } }, want.frameList.map { $0.pieces })
            XCTAssertEqual(d.animations.map { [$0.id] }, want.animationList.map { [$0.id] })
            XCTAssertEqual(d.animations.map { [$0.row ?? -1, $0.facing ?? -1] + $0.frames + [-1] + $0.durations },
                           want.animationList.map { [$0.row, $0.facing] + $0.frames + [-1] + $0.durations })
            XCTAssertEqual(TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4), Self.bytes(want.tileIndices))
        }
    }

    /// A palette whose 15 colours tell their index apart after rendering.
    static let probe: [String] = (0..<16).map { BGR555(r5: UInt8(2 * $0), g5: UInt8($0), b5: UInt8(31 - $0)).hex }
    static func probeIndex(_ px: ArraySlice<UInt8>) -> Int? {
        let r5 = Int(px[px.startIndex]) >> 3, g5 = Int(px[px.startIndex + 1]) >> 3, b5 = Int(px[px.startIndex + 2]) >> 3
        return r5 == 2 * g5 && b5 == 31 - g5 ? g5 : nil
    }

    func testPPUSceneDrawsTheVectorsComposedFrames() throws {
        let (v, image) = try vectors()
        for want in v.sets {
            let d = CTSpriteROM.decode(rom: image, set: want.set)
            var s = CTSpriteROM.spriteDef(d, id: "s\(want.set)")
            s.palettes = [Self.probe]
            let sheet = TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4).chunked(64)
            for c in want.composed {
                var o = SpriteScene.Options()
                o.originX = 128; o.originY = 112; o.backdrop = 0x0000
                let rgba = PPUReferenceRenderer.render(SpriteScene.frame(s, frame: c.frame, sheet: sheet, sheetPalette: [],
                                                                         options: o))
                let expected = Self.bytes(c.indices)
                var mismatches = 0
                for y in 0..<224 {
                    for x in 0..<256 {
                        let off = (y * 256 + x) * 4
                        let got = Self.probeIndex(rgba[off..<(off + 4)]) ?? 0
                        let cx = x - 128 - c.left, cy = y - 112 - c.top
                        let want = cx >= 0 && cx < c.width && cy >= 0 && cy < c.height ? Int(expected[cy * c.width + cx]) : 0
                        if got != want { mismatches += 1 }
                    }
                }
                XCTAssertEqual(mismatches, 0, "set \(want.set) frame \(c.frame)")
            }
        }
    }

    func testOnionFrameIsBehindAndDimmed() throws {
        let (_, image) = try vectors()
        let d = CTSpriteROM.decode(rom: image, set: 0)
        let s = CTSpriteROM.spriteDef(d, id: "s0")
        let sheet = TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4).chunked(64)
        var o = SpriteScene.Options()
        o.backdrop = 0
        let plain = PPUReferenceRenderer.render(SpriteScene.frame(s, frame: 1, sheet: sheet, sheetPalette: [], options: o))
        o.onionFrame = 0
        let scene = SpriteScene.frame(s, frame: 1, sheet: sheet, sheetPalette: [], options: o)
        let onion = PPUReferenceRenderer.render(scene)
        let pal = SpriteScene.palettes(s, sheetPalette: [])
        XCTAssertEqual(scene.cgram[128 + 16 * 7 + 1], SpriteScene.dim(pal[0][1], toward: 0))
        var front = 0, behind = 0
        for i in stride(from: 0, to: plain.count, by: 4) {
            let p = Array(plain[i..<(i + 3)]), q = Array(onion[i..<(i + 3)])
            if p != [0, 0, 0] { XCTAssertEqual(p, q); front += 1 } else if q != [0, 0, 0] { behind += 1 }
        }
        XCTAssertGreaterThan(front, 0)
        XCTAssertGreaterThan(behind, 0, "the onion frame shows where the frame does not")
        // The onion frame's cells live in their own slot: the current slot is untouched.
        let cur = SpriteScene.objTiles(s, frame: 1, sheet: sheet)
        for (t, px) in cur {
            var tmp = PPUFrame()
            tmp.storeTiles(px, bpp: 4, atWord: 0)
            XCTAssertEqual(Array(scene.vram[(t * 16)..<(t * 16 + 16)]), Array(tmp.vram[0..<16]), "tile \(t)")
        }
    }

    func testIndexedPNGRoundTrips() throws {
        for depth in [2, 4, 8] {
            let colours = (0..<(1 << min(depth, 4))).map { BGR555(word: UInt16($0 * 0x0421 & 0x7FFF)) }
            let tiles = (0..<19).map { t in (0..<64).map { UInt8(($0 * 7 + t) % colours.count) } }
            let png = SpriteSheet.png(tiles: tiles, palette: colours, bitDepth: depth)
            XCTAssertEqual(png.width, 128)
            XCTAssertEqual(png.height, 16)
            let back = try PNG.readIndexed(data: PNG.writeIndexed(png))
            XCTAssertEqual(back.bitDepth, depth)
            XCTAssertEqual(back.width, png.width)
            XCTAssertEqual(back.indices, png.indices)
            XCTAssertEqual(back.palette, colours)
            XCTAssertEqual(Array(SpriteSheet.tiles(back).prefix(19)), tiles)
        }
        var png = SpriteSheet.png(tiles: [[UInt8](repeating: 1, count: 64)], palette: [BGR555(word: 0), BGR555(word: 1)])
        SpriteSheet.setTile(&png, 3, (0..<64).map { UInt8($0 % 2) })
        XCTAssertEqual(SpriteSheet.tiles(png)[3][1], 1)
        XCTAssertEqual(SpriteSheet.mirrored(SpriteSheet.tiles(png)[3])[0], 1)
        XCTAssertThrowsError(try PNG.writeIndexed(IndexedPNG(width: 8, height: 8, bitDepth: 2,
                                                             palette: Array(repeating: BGR555(word: 0), count: 5),
                                                             indices: [UInt8](repeating: 0, count: 64))))
    }

    func testOldSpriteFilesStillLoadAndNewFieldsRoundTrip() throws {
        let project = try CTProject.load(from: fixtureURL())
        let robo = try XCTUnwrap(project.sprites["robo"])
        XCTAssertNil(robo.palettes)
        XCTAssertNil(robo.stream)
        XCTAssertNil(robo.frames[0].cells)
        let legacy = String(decoding: try CTProject.jsonEncoder.encode(robo), as: UTF8.self)
        for key in ["palettes", "stream", "\"rom\"", "cells", "priority", "\"row\"", "facing", "hitbox", "weapon"] {
            XCTAssertFalse(legacy.contains(key), key)
        }
        var s = robo
        s.palettes = [Self.probe]
        s.stream = .init(columns: 8, rows: 2, baseTile: 8)
        s.frames[0].cells = Array(0..<16)
        s.frames[0].hitbox = .init(x: -8, y: -32, w: 16, h: 32)
        s.frames[0].weapon = .init(x: 6, y: -12)
        s.frames[0].tiles[0].priority = 3
        s.animations[0].row = 4
        s.animations[0].facing = 2
        let back = try JSONDecoder().decode(SpriteDef.self, from: CTProject.jsonEncoder.encode(s))
        XCTAssertEqual(back, s)
    }

    func testBudgetCountsSlotTilesAndLineLimits() throws {
        let (_, image) = try vectors()
        let s = CTSpriteROM.spriteDef(CTSpriteROM.decode(rom: image, set: 0), id: "s0")
        let b = SpriteScene.budget(s, frame: 0)
        XCTAssertEqual(b.objs, 4)
        XCTAssertEqual(b.streamedTiles, 16)
        XCTAssertLessThanOrEqual(b.tiles, 16)
        XCTAssertLessThanOrEqual(b.maxOBJsOnALine, 4)
        XCTAssertFalse(b.rangeOver || b.timeOver)

        var crowd = SpriteDef(id: "crowd", sheet: "sprites/crowd.png")
        crowd.frames = [.init(tiles: (0..<40).map { SpriteDef.OAMTile(x: 6 * $0 - 120, y: 0, tile: $0 % 4) })]
        let c = SpriteScene.budget(crowd, frame: 0)
        XCTAssertEqual(c.objs, 40)
        XCTAssertEqual(c.tiles, 4)
        XCTAssertEqual(c.maxOBJsOnALine, PPUOBJEvaluator.maxOBJsPerLine)
        XCTAssertTrue(c.rangeOver)
        XCTAssertNotNil(SpriteScene.bounds(crowd, frame: 0))
    }

    func testEditingHelpers() throws {
        var s = SpriteDef(id: "e", sheet: "sprites/e.png")
        s.frames = [.init(tiles: [.init(x: -8, y: -16, tile: 0, size16: true), .init(x: 4, y: -8, tile: 4)]),
                    .init(tiles: [.init(x: 0, y: 0, tile: 1)]),
                    .init(tiles: [])]
        s.animations = [.init(id: "a", frames: [0, 1, 2, 1], durations: [2, 3, 4, 5], loop: true),
                        .init(id: "b", frames: [2, 0], durations: [1, 1], loop: false)]
        var o = SpriteScene.Options()
        o.originX = 100; o.originY = 100
        XCTAssertEqual(SpriteEditing.hit(s, frame: 0, x: 92, y: 84, options: o), 0)
        XCTAssertEqual(SpriteEditing.hit(s, frame: 0, x: 103, y: 95, options: o), 0)      // both cover it: OBJ 0 is in front
        XCTAssertEqual(SpriteEditing.hit(s, frame: 0, x: 110, y: 99, options: o), 1)
        XCTAssertNil(SpriteEditing.hit(s, frame: 0, x: 112, y: 99, options: o))
        XCTAssertNil(SpriteEditing.hit(s, frame: 9, x: 100, y: 100, options: o))

        let a = s.animations[0]
        XCTAssertEqual([0, 1, 2, 4, 5, 9, 13, 14].map { SpriteEditing.step(a, at: $0) }, [0, 0, 1, 1, 2, 3, 3, 0])
        XCTAssertEqual(SpriteEditing.step(s.animations[1], at: 50), 1)                      // not looping: holds the last

        XCTAssertEqual(SpriteEditing.duplicateFrame(&s, 1), 3)
        XCTAssertEqual(s.frames[3], s.frames[1])
        SpriteEditing.deleteFrame(&s, 1)
        XCTAssertEqual(s.frames.count, 3)
        XCTAssertEqual(s.animations[0].frames, [0, 1])
        XCTAssertEqual(s.animations[0].durations, [2, 4])
        XCTAssertEqual(s.animations[1].frames, [1, 0])

        var png = SpriteSheet.png(tiles: [[UInt8]](repeating: [UInt8](repeating: 0, count: 64), count: 17),
                                  palette: (0..<16).map { BGR555(word: UInt16($0)) })
        SpriteEditing.paint(&png, tile: 16, x: 7, y: 2, index: 0x1F)
        XCTAssertEqual(SpriteSheet.tiles(png)[16][2 * 8 + 7], 0x0F)
        SpriteEditing.paint(&png, tile: 99, x: 0, y: 0, index: 1)                          // outside: ignored
        let grown = SpriteEditing.grow(png)
        XCTAssertEqual(grown.height, png.height + 8)
        XCTAssertEqual(SpriteSheet.tiles(grown).count, 48)
        XCTAssertEqual(SpriteSheet.tiles(grown)[16], SpriteSheet.tiles(png)[16])
    }

    /// Local ROM: the import writes sheets and sprites that validate, and
    /// the PPU shows each imported frame as an independent composition of
    /// the decoded cells does.
    func testImportFromTheROM() throws {
        let rom = [UInt8](try Repo.romData())
        var project = try CTProject.load(from: fixtureURL())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctsprites-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        project.url = dir
        project.sprites["robo"] = nil
        project.characters["robo"]?.sprite = nil
        let ids = try CTSpriteROM.importSprites(rom: rom, into: &project)
        XCTAssertEqual(ids, CTSpriteROM.names)
        XCTAssertEqual(project.characters["robo"]?.sprite, "robo")
        try project.save()
        let loaded = try CTProject.load(from: dir)
        XCTAssertEqual(loaded.sprites["crono"], project.sprites["crono"])
        let issues = Validator.validate(loaded).filter { $0.path.hasPrefix("sprites/") }
        XCTAssertTrue(issues.isEmpty, "\(issues)")

        let raw = rom.count == CTROMBuilder.romSize + 512 ? Array(rom.dropFirst(512)) : rom
        for c in 0..<CTSpriteROM.sets {
            let d = CTSpriteROM.decode(rom: raw, set: c)
            var s = try XCTUnwrap(loaded.sprites[CTSpriteROM.names[c]])
            XCTAssertEqual(s.frames.count, d.frames.count)
            XCTAssertEqual(s.rom?.set, c)
            let png = try PNG.readIndexed(url: loaded.fileURL(relative: s.sheet))
            XCTAssertEqual(png.width, 128)
            let sheet = SpriteSheet.tiles(png)
            XCTAssertEqual(Array(sheet.prefix(d.tiles.count)), TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4).chunked(64))
            s.palettes = [Self.probe]
            for f in [0, d.frames.count / 2, d.frames.count - 1] {
                var o = SpriteScene.Options()
                o.originX = 128; o.originY = 112; o.backdrop = 0
                let rgba = PPUReferenceRenderer.render(SpriteScene.frame(s, frame: f, sheet: sheet, sheetPalette: [], options: o))
                let want = compose(d.frames[f], sheet: sheet)
                var bad = 0
                for y in 0..<224 {
                    for x in 0..<256 {
                        let off = (y * 256 + x) * 4
                        if (Self.probeIndex(rgba[off..<(off + 4)]) ?? 0) != (want[[x - 128, y - 112]] ?? 0) { bad += 1 }
                    }
                }
                XCTAssertEqual(bad, 0, "set \(c) frame \(f)")
                if f == 0 { XCTAssertFalse(want.isEmpty) }
            }
        }
    }

    /// OBJ n (16x16) = cells (0, 2n) (0, 2n+1) (1, 2n) (1, 2n+1) at its
    /// offset; the lower OBJ in front.
    func compose(_ f: CTSpriteROM.Frame, sheet: [[UInt8]]) -> [[Int]: Int] {
        var img: [[Int]: Int] = [:]
        for n in 0..<4 {
            for (q, k) in [2 * n, 2 * n + 1, 8 + 2 * n, 9 + 2 * n].enumerated() {
                let w = f.cells[k], t = w & 0x7FF
                guard t != 0, t < sheet.count else { continue }
                for i in 0..<64 {
                    let sx = w & 0x4000 != 0 ? 7 - i % 8 : i % 8
                    let v = Int(sheet[t][i / 8 * 8 + sx])
                    let key = [f.pieces[n].x + 8 * (q % 2) + i % 8, f.pieces[n].y + 8 * (q / 2) + i / 8]
                    if v != 0, img[key] == nil { img[key] = v }
                }
            }
        }
        return img
    }
}
