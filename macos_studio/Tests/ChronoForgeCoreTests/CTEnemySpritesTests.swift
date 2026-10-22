// CTEnemySpritesTests.swift — the enemy sprite decode against ct_sprites.py's
// synthetic enemy vectors (no ROM data), the PPU scene against the vectors'
// composed frames, the OBJ assembly, the Enemies view's hook, and (local ROM)
// the import of every enemy.
import XCTest
@testable import ChronoForgeCore

final class CTEnemySpritesTests: XCTestCase {
    struct Vectors: Decodable {
        struct Tiles: Decodable { var pointer: String; var source: String; var count: Int }
        struct Layout: Decodable { var index: Int; var columns: Int; var rows: Int; var objs: Int; var recordBytes: Int }
        struct Enemy: Decodable {
            var id: Int
            var layout: Layout
            var tiles: Tiles
            var frames: CTSpritesTests.Vectors.Block
            var palette: CTSpritesTests.Vectors.Palette
            var animations: CTSpritesTests.Vectors.Anims
            var frameList: [CTSpritesTests.Vectors.Frame]
            var animationList: [CTSpritesTests.Vectors.Anim]
            var composed: CTSpritesTests.Vectors.Composed
            var tileIndices: String
        }
        var schema: String
        var regions: [CTSpritesTests.Vectors.Region]
        var enemies: [Enemy]
    }

    func vectors() throws -> (Vectors, [UInt8]) {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("sprites/enemy_sprite_vectors.json"))
        XCTAssertEqual(v.schema, "ct-enemy-sprite-vectors/1")
        var image = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        for r in v.regions {
            let at = CTSpriteROM.pc(try XCTUnwrap(CTSpriteROM.parseSNES(r.at)))
            let b = CTSpritesTests.bytes(r.hex)
            image.replaceSubrange(at..<(at + b.count), with: b)
        }
        return (v, image)
    }

    func testDecodeMatchesThePythonVectors() throws {
        let (v, image) = try vectors()
        XCTAssertEqual(v.enemies.map(\.layout.index), [0, 1, 2, 0])
        for want in v.enemies {
            let d = try CTEnemySpriteROM.decode(rom: image, id: want.id)
            XCTAssertEqual(d.layout, want.layout.index)
            XCTAssertEqual(CTSpriteROM.snes(d.tilesAt), want.tiles.pointer)
            XCTAssertEqual(d.packed, want.tiles.source == "packed")
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
            // Rows built step by step: CI's older type checker (Xcode 26.6) gives up on long literal chains.
            var gotRows: [[Int]] = [], wantRows: [[Int]] = []
            for a in d.animations {
                var row: [Int] = [a.row ?? -1, a.facing ?? -1]
                row.append(contentsOf: a.frames); row.append(-1); row.append(contentsOf: a.durations)
                gotRows.append(row)
            }
            for a in want.animationList {
                var row: [Int] = [a.row, a.facing]
                row.append(contentsOf: a.frames); row.append(-1); row.append(contentsOf: a.durations)
                wantRows.append(row)
            }
            XCTAssertEqual(gotRows, wantRows)
            XCTAssertEqual(TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4),
                           CTSpritesTests.bytes(want.tileIndices))
        }
    }

    func testPPUSceneDrawsTheVectorsComposedFrames() throws {
        let (v, image) = try vectors()
        for want in v.enemies {
            let d = try CTEnemySpriteROM.decode(rom: image, id: want.id)
            var s = CTEnemySpriteROM.spriteDef(d, id: CTEnemySpriteROM.id(want.id))
            s.palettes = [CTSpritesTests.probe]
            let sheet = TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4).chunked(64)
            let c = want.composed
            var o = SpriteScene.Options()
            o.originX = 128; o.originY = 112; o.backdrop = 0x0000
            let rgba = PPUReferenceRenderer.render(SpriteScene.frame(s, frame: c.frame, sheet: sheet, sheetPalette: [],
                                                                     options: o))
            let expected = CTSpritesTests.bytes(c.indices)
            var mismatches = 0, drawn = 0
            for y in 0..<224 {
                for x in 0..<256 {
                    let off = (y * 256 + x) * 4
                    let got = CTSpritesTests.probeIndex(rgba[off..<(off + 4)]) ?? 0
                    let cx = x - 128 - c.left, cy = y - 112 - c.top
                    let inside = cx >= 0 && cx < c.width && cy >= 0 && cy < c.height
                    let wanted = inside ? Int(expected[cy * c.width + cx]) : 0
                    if got != wanted { mismatches += 1 }
                    if wanted != 0 { drawn += 1 }
                }
            }
            XCTAssertEqual(mismatches, 0, "enemy \(want.id) frame \(c.frame)")
            XCTAssertGreaterThan(drawn, 0, "enemy \(want.id)")
        }
    }

    func testOBJAssemblyAndSpriteDef() throws {
        XCTAssertEqual(CTEnemySpriteROM.pieceCells(0, columns: 8), [0, 1, 8, 9])
        XCTAssertEqual(CTEnemySpriteROM.pieceCells(3, columns: 8), [6, 7, 14, 15])
        XCTAssertEqual(CTEnemySpriteROM.pieceCells(5, columns: 8), [18, 19, 26, 27])
        XCTAssertEqual(CTEnemySpriteROM.pieceCells(7, columns: 16), [14, 15, 30, 31])
        let (_, image) = try vectors()
        let d = try CTEnemySpriteROM.decode(rom: image, id: 2)
        let s = CTEnemySpriteROM.spriteDef(d, id: "tall")
        XCTAssertEqual(s.rom?.family, CTEnemySpriteROM.family)
        XCTAssertEqual(s.rom?.set, 2)
        XCTAssertEqual(s.rom?.layout, 2)
        XCTAssertEqual(s.rom?.packed, true)
        XCTAssertEqual(s.stream, SpriteDef.Stream(columns: 8, rows: 6, baseTile: CTEnemySpriteROM.slotTile))
        let tiles: [Int] = s.frames[0].tiles.map(\.tile)
        XCTAssertEqual(tiles, [0, 2, 4, 6, 32, 34, 36, 38, 64, 66, 68, 70])
        XCTAssertEqual(s.palettes?[0].count, 16)
        XCTAssertEqual(s.palettes?[0].first, BGR555(word: 0).hex)
        // An animation naming a frame past the block is left out.
        var short = d
        short.frames.removeLast()
        let kept = CTEnemySpriteROM.spriteDef(short, id: "short").animations
        let named: [Bool] = kept.map { $0.frames.allSatisfy { $0 < short.frames.count } }
        XCTAssertFalse(named.contains(false))
        XCTAssertLessThan(kept.count, d.animations.count)
        // The schema keeps the new ROMSource fields.
        let back = try JSONDecoder().decode(SpriteDef.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.rom?.layout, 2)
        XCTAssertEqual(back.rom?.packed, true)
    }

    func testEnemiesViewHookFindsTheSprite() throws {
        let (_, image) = try vectors()
        var project = try CTProject.load(from: fixtureURL())
        var s = CTEnemySpriteROM.spriteDef(try CTEnemySpriteROM.decode(rom: image, id: 1), id: "foe")
        project.sprites["foe"] = s
        let stats = [UInt8](repeating: 0, count: CTEnemyROM.statsSize)
        let reward = [UInt8](repeating: 0, count: CTEnemyROM.rewardSize)
        var c = CharacterDef(id: "slime", name: "Slime", kind: "enemy")
        c.enemy = CTEnemyROM.decode(stats: stats, reward: reward, id: 1)
        XCTAssertEqual(CTEnemySpriteROM.sprite(for: c, in: project)?.id, "foe")
        c.enemy?.enemyId = 2
        XCTAssertNil(CTEnemySpriteROM.sprite(for: c, in: project))
        c.sprite = "foe"
        XCTAssertEqual(CTEnemySpriteROM.sprite(for: c, in: project)?.id, "foe")
        XCTAssertEqual(CTEnemySpriteROM.restFrame(s), s.animations[0].frames[0])
        s.animations = []
        XCTAssertEqual(CTEnemySpriteROM.restFrame(s), 0)
    }

    /// Local ROM: every enemy of layouts 0-2 imports, saves, validates and
    /// draws its rest frame; layout 3 is left out; rom.sprites refuses them.
    func testImportEveryEnemy() throws {
        let rom = [UInt8](try Repo.romData())
        let raw = rom.count == CTROMBuilder.romSize + 512 ? Array(rom.dropFirst(512)) : rom
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctenemysprites-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let (ids, skipped) = try CTEnemySpriteROM.importSprites(rom: rom, into: &project)
        XCTAssertEqual(ids.count + skipped.count, CTEnemySpriteROM.ids)
        XCTAssertEqual(skipped, [111, 147, 215])
        try project.save()
        let loaded = try CTProject.load(from: dir)
        let issues = Validator.validate(loaded).filter { $0.path.hasPrefix("sprites/") }
        XCTAssertTrue(issues.isEmpty, "\(issues.prefix(5))")
        var layouts = [0, 0, 0]
        for id in ids {
            let s = try XCTUnwrap(loaded.sprites[id])
            layouts[s.rom?.layout ?? 0] += 1
        }
        XCTAssertEqual(layouts, [150, 77, 25])
        for i in [0, 26, 117, 200, 253] {
            let d = try CTEnemySpriteROM.decode(rom: raw, id: i)
            let s = try XCTUnwrap(loaded.sprites[CTEnemySpriteROM.id(i)])
            XCTAssertEqual(s.frames.count, d.frames.count)
            let sheet = SpriteSheet.tiles(try PNG.readIndexed(url: loaded.fileURL(relative: s.sheet)))
            let o = SpriteScene.Options()
            let rgba = PPUReferenceRenderer.render(SpriteScene.frame(s, frame: CTEnemySpriteROM.restFrame(s), sheet: sheet,
                                                                     sheetPalette: [], options: o))
            var lit = 0
            var k = 0
            while k < rgba.count {
                if rgba[k] != rgba[0] || rgba[k + 1] != rgba[1] || rgba[k + 2] != rgba[2] { lit += 1 }
                k += 4
            }
            XCTAssertGreaterThan(lit, 0, "enemy \(i)")
        }
        // Enemy sprites are read-only: rom.sprites refuses them.
        var building = loaded
        building.project.rom = Project.ROMBuild(sprites: ["enemy_000"])
        XCTAssertThrowsError(try CTROMBuilder.build(base: raw, project: building)) { error in
            XCTAssertTrue("\(error)".contains("is not ct-pc"), "\(error)")
        }
    }
}
