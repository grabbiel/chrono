// CTNPCSpritesTests.swift — the NPC sprite decode against ct_npc_sprites.py's
// synthetic vectors (no ROM data), the field clock against the vectors' runs of
// the Python twin of Obj_AnimTickAndQueue / Obj_AnimFrameLookup, the sprite def
// shape, and (local ROM) the import of every NPC record the event packs load.
import XCTest
@testable import ChronoForgeCore

final class CTNPCSpritesTests: XCTestCase {
    struct Vectors: Decodable {
        struct Fields: Decodable { var gfx: Int; var frames: Int; var palette: Int; var anim: Int; var size: Int; var sizeByte: Int }
        struct Layout: Decodable { var index: Int; var columns: Int; var rows: Int; var objs: Int; var recordBytes: Int }
        struct Tiles: Decodable { var pointer: String; var count: Int; var mode: Int; var packedBytes: Int }
        struct Anims: Decodable { var frameIds: String; var durations: String; var rows: Int; var stride: Int }
        struct Anim: Decodable {
            var id: String; var row: Int; var facing: Int; var frames: [Int]; var durations: [Int]
            var end: String; var markerDuration: Int?
        }
        struct NPC: Decodable {
            var record: Int
            var fields: Fields
            var layout: Layout
            var tiles: Tiles
            var frames: CTSpritesTests.Vectors.Block
            var palette: CTSpritesTests.Vectors.Palette
            var animations: Anims
            var frameList: [CTSpritesTests.Vectors.Frame]
            var animationList: [Anim]
            var slotTile: Int
            var tileIndices: String
        }
        struct Clock: Decodable { var ids: [Int]; var durations: [Int]; var mode: Int; var loops: Int; var ticks: [[Int]] }
        var schema: String
        var regions: [CTSpritesTests.Vectors.Region]
        var npcs: [NPC]
        var clocks: [Clock]
    }

    func vectors() throws -> (Vectors, [UInt8]) {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("sprites/npc_sprite_vectors.json"))
        XCTAssertEqual(v.schema, "ct-npc-sprite-vectors/1")
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
        XCTAssertEqual(v.npcs.map(\.record), [7, 8, 9])
        for want in v.npcs {
            let d = try CTNPCSpriteROM.decode(rom: image, record: want.record)
            let f = want.fields
            XCTAssertEqual(d.fields, CTNPCSpriteROM.Record(gfx: f.gfx, frames: f.frames, palette: f.palette, anim: f.anim,
                                                           size: f.size, sizeByte: f.sizeByte))
            XCTAssertEqual(d.layout, want.layout.index)
            XCTAssertEqual(CTSpriteROM.snes(d.tilesAt), want.tiles.pointer)
            XCTAssertEqual(d.tiles.count, want.tiles.count)
            XCTAssertEqual(d.packedBytes, want.tiles.packedBytes)
            XCTAssertEqual(d.mode.rawValue, want.tiles.mode)
            XCTAssertEqual(CTSpriteROM.snes(d.framesAt), want.frames.address)
            XCTAssertEqual(d.frames.count, want.frames.count)
            XCTAssertEqual(CTSpriteROM.snes(d.paletteAt), want.palette.address)
            XCTAssertEqual(d.palette.map { BGR555(word: $0).hex }, want.palette.colours)
            XCTAssertEqual(CTSpriteROM.snes(d.frameIdsAt), want.animations.frameIds)
            XCTAssertEqual(CTSpriteROM.snes(d.durationsAt), want.animations.durations)
            XCTAssertEqual(d.rows, want.animations.rows)
            XCTAssertEqual(d.stride, want.animations.stride)
            XCTAssertEqual(CTNPCSpriteROM.slotTile(size: d.fields.size), want.slotTile)
            XCTAssertEqual(d.frames.map { $0.cells }, want.frameList.map { $0.cells })
            XCTAssertEqual(d.frames.map { $0.pieces.map { [$0.x, $0.y] } }, want.frameList.map { $0.pieces })
            // Rows built step by step: CI's older type checker (Xcode 26.6) gives up on long literal chains.
            var gotRows: [[Int]] = [], wantRows: [[Int]] = []
            for a in d.animations {
                var row: [Int] = [a.row ?? -1, a.facing ?? -1, a.markerDuration ?? 0]
                row.append(contentsOf: a.frames); row.append(-1); row.append(contentsOf: a.durations)
                gotRows.append(row)
            }
            for a in want.animationList {
                var row: [Int] = [a.row, a.facing, a.markerDuration ?? 0]
                row.append(contentsOf: a.frames); row.append(-1); row.append(contentsOf: a.durations)
                wantRows.append(row)
            }
            XCTAssertEqual(gotRows, wantRows, "record \(want.record)")
            XCTAssertEqual(d.animations.map(\.id), want.animationList.map(\.id))
            XCTAssertEqual(TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4),
                           CTSpritesTests.bytes(want.tileIndices))
        }
    }

    /// The Swift clock against the Python model's runs ([column, timer, frame] after each tick).
    func testFieldClockMatchesThePythonRuns() throws {
        let (v, _) = try vectors()
        XCTAssertEqual(v.clocks.count, 5)
        for c in v.clocks {
            var clock = CTNPCSpriteROM.FieldClock(ids: c.ids, durations: c.durations, mode: c.mode, loops: c.loops)
            var got: [[Int]] = []
            for _ in c.ticks {
                clock.tick()
                let column = clock.column, timer = clock.timer
                let frame = clock.frame()
                got.append([column, timer, frame])
            }
            XCTAssertEqual(got, c.ticks, "clock \(c.ids) mode \(c.mode)")
        }
    }

    func testFieldStepFollowsTheClock() {
        // Two steps of 3 and 2 frames ended by a zero duration: step 1 from tick 1, step 0 again at tick 4.
        let a = SpriteDef.Animation(id: "a", frames: [5, 6], durations: [3, 2])
        let steps: [Int] = (0..<12).map { CTNPCSpriteROM.fieldStep(a, at: $0) }
        XCTAssertEqual(steps, [0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1])
        // An $FF marker shows the first step again for its own duration.
        let m = SpriteDef.Animation(id: "m", frames: [5, 6], durations: [3, 2], markerDuration: 4)
        var clock = CTNPCSpriteROM.FieldClock(animation: m)
        var direct: [Int] = []
        for _ in 0..<20 {
            clock.tick()
            let shown = clock.column >= m.frames.count ? 0 : clock.column
            _ = clock.frame()
            direct.append(shown)
        }
        let stepped: [Int] = (1...20).map { CTNPCSpriteROM.fieldStep(m, at: $0) }
        XCTAssertEqual(stepped, direct)
        XCTAssertEqual(CTNPCSpriteROM.fieldStep(SpriteDef.Animation(id: "e", frames: [], durations: []), at: 9), 0)
    }

    func testSpriteDefShape() throws {
        let (_, image) = try vectors()
        XCTAssertEqual(CTNPCSpriteROM.tile(slot: 0x19), 0x188)
        XCTAssertEqual(CTNPCSpriteROM.tile(slot: 0x0C), 0xC0)
        XCTAssertEqual(CTNPCSpriteROM.id(7), "npc_007")
        let d = try CTNPCSpriteROM.decode(rom: image, record: 8)
        let field = SpriteDef.Field(size: 1, packs: [3, 4], locations: [10])
        let s = CTNPCSpriteROM.spriteDef(d, id: "npc_008", field: field)
        XCTAssertEqual(s.rom?.family, CTNPCSpriteROM.family)
        XCTAssertEqual(s.rom?.set, 8)
        XCTAssertEqual(s.rom?.layout, 1)
        XCTAssertEqual(s.rom?.packed, true)
        XCTAssertNil(s.rom?.stride)             // 4 x rows: only sets 74 and 76 store theirs
        XCTAssertEqual(s.stream, SpriteDef.Stream(columns: 16, rows: 2, baseTile: 0xC0))
        let tiles: [Int] = s.frames[0].tiles.map(\.tile)
        XCTAssertEqual(tiles, [0, 2, 4, 6, 8, 10, 12, 14])
        XCTAssertEqual(s.palettes?[0].count, 16)
        XCTAssertEqual(s.field, field)
        // The schema keeps the new fields.
        let back = try JSONDecoder().decode(SpriteDef.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.field?.packs, [3, 4])
        let m = SpriteDef.Animation(id: "m", frames: [1], durations: [2], markerDuration: 7)
        let mBack = try JSONDecoder().decode(SpriteDef.Animation.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(mBack.markerDuration, 7)
        // An older project without the fields still loads.
        let old = try JSONDecoder().decode(SpriteDef.Animation.self, from: Data(#"{"id":"o","frames":[1],"durations":[2],"loop":true}"#.utf8))
        XCTAssertNil(old.markerDuration)
    }

    /// Local ROM: every NPC record the event packs load imports, saves, validates
    /// and draws its first frame; unedited ones build without a write.
    func testImportEveryNPC() throws {
        let rom = [UInt8](try Repo.romData())
        let raw = rom.count == CTROMBuilder.romSize + 512 ? Array(rom.dropFirst(512)) : rom
        let usage = try CTNPCSpriteROM.usage(rom: raw)
        XCTAssertEqual(usage.count, 191)
        var pairs = 0
        var sizes = [0, 0]
        for (_, f) in usage {
            pairs += f.packs.count
            sizes[f.size & 3] += 1
            XCTAssertFalse(f.locations.isEmpty)
        }
        XCTAssertEqual(pairs, 1190)
        XCTAssertEqual(sizes, [183, 8])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctnpcsprites-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let ids = try CTNPCSpriteROM.importSprites(rom: rom, into: &project)
        XCTAssertEqual(ids.count, 191)
        try project.save()
        let loaded = try CTProject.load(from: dir)
        let issues = Validator.validate(loaded).filter { $0.path.hasPrefix("sprites/") }
        XCTAssertTrue(issues.isEmpty, "\(issues.prefix(5))")
        for r in [7, 67, 95, 218] {
            let d = try CTNPCSpriteROM.decode(rom: raw, record: r)
            let s = try XCTUnwrap(loaded.sprites[CTNPCSpriteROM.id(r)])
            XCTAssertEqual(s.frames.count, d.frames.count)
            XCTAssertEqual(s.field?.size, d.fields.sizeByte)
            let sheet = SpriteSheet.tiles(try PNG.readIndexed(url: loaded.fileURL(relative: s.sheet)))
            let rgba = PPUReferenceRenderer.render(SpriteScene.frame(s, frame: 0, sheet: sheet, sheetPalette: [],
                                                                     options: SpriteScene.Options()))
            var lit = 0
            var k = 0
            while k < rgba.count {
                if rgba[k] != rgba[0] || rgba[k + 1] != rgba[1] || rgba[k + 2] != rgba[2] { lit += 1 }
                k += 4
            }
            XCTAssertGreaterThan(lit, 0, "record \(r)")
        }
        // rom.sprites builds unedited NPC sprites without a write (CTNPCSpritePatchTests edits them).
        var building = loaded
        building.project.rom = Project.ROMBuild(sprites: ["npc_007", "npc_067"])
        let (built, report) = try CTROMBuilder.build(base: raw, project: building)
        XCTAssertEqual(built, raw)
        XCTAssertEqual(report.npcSprites?.map(\.set), [7, 67])
        XCTAssertNil(report.enemySprites)
    }
}
