// CTTilesetsTests.swift — the location tileset decode against ct_tilesets.py's
// synthetic vectors, the palette and tile animation simulators, the Tileset
// extension (old files load and save unchanged), the metatile PPU scene
// against a direct decode, and (local ROM) the import of every tileset.
import XCTest
@testable import ChronoForgeCore

final class CTTilesetsTests: XCTestCase {
    struct Vectors: Decodable {
        struct Region: Decodable { var at: String; var hex: String }
        struct Meta: Decodable { var at: String; var mode: Int; var packed: Int; var length: Int }
        struct Upload: Decodable {
            var slot: Int, pack: Int?, vram: Int, firstTile: Int, tiles: Int
            var at: String?, packed: Int?, unpacked: Int?, ownTiles: Int?
        }
        struct AnimPack: Decodable { var slot: Int, pack: Int, at: String, packed: Int, unpacked: Int, wram: String }
        struct TileAnim: Decodable { var kind: Int, vram: Int, steps: [Int], sources: [Int] }
        struct TileAnims: Decodable { var set: Int, at: String, end: String, records: [TileAnim?] }
        struct Preview: Decodable { var palette: Int?, tileset3: Int? }
        struct Run: Decodable { var first: Int, hex: String }
        struct List: Decodable { var at: String, packs: [Int?] }
        struct T12: Decodable {
            var index: Int, bpp: Int, list: List, meta: Meta, metatiles: [[UInt16]], uploads: [Upload]
            var knownTiles: [[Int]], animWram: [AnimPack], animKnown: [[Int]], tileAnims: TileAnims
            var preview: Preview, tileIndices: [Run], animIndices: String, frameRuns: [[Int]]
        }
        struct T3: Decodable {
            var index: Int, meta: Meta, metatiles: [[UInt16]], uploads: [Upload], knownTiles: [[Int]], tileIndices: [Run]
        }
        struct Cycle: Decodable {
            var byte0: Int, kind: Int, name: String, first: Int, count: Int, delay: Int
            var offset: Int?, bank: Int?, order: [Int]?, frames: Int?, colours: [[UInt16]]?
        }
        struct Cycles: Decodable { var at: String, end: String, records: [Cycle?] }
        struct Tick: Decodable { var tick: Int, cgram: [UInt16] }
        struct Pal: Decodable { var index: Int, at: String, rows: [[UInt16]], cycles: Cycles, ticks: [Tick] }
        var schema: String
        var regions: [Region]
        var tileset12: [T12]
        var tileset3: [T3]
        var palettes: [Pal]
    }

    func vectors() throws -> (Vectors, [UInt8]) {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("tilesets/tileset_vectors.json"))
        XCTAssertEqual(v.schema, "ct-tileset-vectors/1")
        var image = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        for r in v.regions {
            let at = CTSpriteROM.pc(try XCTUnwrap(CTSpriteROM.parseSNES(r.at)))
            let b = CTSpritesTests.bytes(r.hex)
            image.replaceSubrange(at..<(at + b.count), with: b)
        }
        return (v, image)
    }

    func checkUploads(_ got: [CTTilesetROM.Upload], _ want: [Vectors.Upload], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(got.map { [$0.slot, $0.pack ?? -1, $0.vram, $0.firstTile, $0.tiles, $0.packed ?? -1, $0.unpacked ?? -1, $0.ownTiles ?? -1] },
                       want.map { [$0.slot, $0.pack ?? -1, $0.vram, $0.firstTile, $0.tiles, $0.packed ?? -1, $0.unpacked ?? -1, $0.ownTiles ?? -1] },
                       file: file, line: line)
        XCTAssertEqual(got.map { $0.at.map(CTTilesetROM.snes) }, want.map(\.at), file: file, line: line)
    }

    static func runs(_ w: CTTilesetROM.Window, bpp: Int) -> [Vectors.Run] {
        let idx = w.indices(bpp: bpp)
        return CTTilesetROM.ranges(w.knownTiles).map { r in
            Vectors.Run(first: r.lowerBound, hex: r.flatMap { idx[$0] }.map { String(format: "%02x", $0) }.joined())
        }
    }

    func testDecodeMatchesThePythonVectors() throws {
        let (v, image) = try vectors()
        XCTAssertEqual(v.tileset12.count, 2)
        for want in v.tileset12 {
            let d = try CTTilesetROM.decode12(image, want.index)
            XCTAssertEqual(d.packs, want.list.packs)
            XCTAssertEqual([CTTilesetROM.snes(d.meta.at)], [want.meta.at])
            XCTAssertEqual([d.meta.mode.rawValue, d.meta.packed, d.meta.length], [want.meta.mode, want.meta.packed, want.meta.length])
            XCTAssertEqual(d.meta.metatiles, want.metatiles)
            checkUploads(d.uploads, want.uploads)
            XCTAssertEqual(CTTilesetROM.ranges(d.window.knownTiles).map { [$0.lowerBound, $0.upperBound] }, want.knownTiles)
            let runs = Self.runs(d.window, bpp: 4)
            XCTAssertEqual(runs.map(\.first), want.tileIndices.map(\.first))
            XCTAssertEqual(runs.map(\.hex), want.tileIndices.map(\.hex))
            XCTAssertEqual(d.animPacks.map { [$0.slot, $0.pack, $0.packed, $0.unpacked] },
                           want.animWram.map { [$0.slot, $0.pack, $0.packed, $0.unpacked] })
            XCTAssertEqual(d.animPacks.map { CTTilesetROM.snes($0.at) + CTTilesetROM.snes($0.wram) }, want.animWram.map { $0.at + $0.wram })
            XCTAssertEqual(CTTilesetROM.ranges(d.anim.set).map { [$0.lowerBound, $0.upperBound] }, want.animKnown)
            XCTAssertEqual(d.anim.indices(bpp: 4).joined().map { String(format: "%02x", $0) }.joined(), want.animIndices)
            XCTAssertEqual(CTTilesetROM.snes(d.animListAt), want.tileAnims.at)
            XCTAssertEqual(CTTilesetROM.snes(d.animListEnd), want.tileAnims.end)
            XCTAssertEqual(d.tileAnims.map { $0.map { [$0.kind, $0.vram] + $0.steps + [-1] + $0.sources } },
                           want.tileAnims.records.map { $0.map { [$0.kind, $0.vram] + $0.steps + [-1] + $0.sources } })
            XCTAssertEqual(d.previewPalette, want.preview.palette)
            XCTAssertEqual(d.previewTileset3, want.preview.tileset3)
            // The animator runs the imported animations as the game's accumulator.
            let anims = CTTilesets.tileAnimations(d.tileAnims)
            var animator = TileAnimator(anims)
            var seen = [[Int]](repeating: [], count: anims.count)
            for _ in 0..<40 {
                for (i, f) in animator.frames.enumerated() { seen[i].append(f) }
                animator.upload()
            }
            XCTAssertEqual(seen, want.frameRuns.filter { !$0.isEmpty })
        }
        for want in v.tileset3 {
            let d = try CTTilesetROM.decode3(image, want.index)
            XCTAssertEqual(CTTilesetROM.snes(d.meta.at), want.meta.at)
            XCTAssertEqual(d.meta.metatiles, want.metatiles)
            checkUploads([d.upload], want.uploads)
            XCTAssertEqual(CTTilesetROM.ranges(d.window.knownTiles).map { [$0.lowerBound, $0.upperBound] }, want.knownTiles)
            XCTAssertEqual(Self.runs(d.window, bpp: 2).map(\.hex), want.tileIndices.map(\.hex))
        }
        for want in v.palettes {
            let d = CTTilesetROM.decodePalette(image, want.index)
            XCTAssertEqual(d.rows, want.rows)
            XCTAssertEqual(CTTilesetROM.snes(d.cyclesAt), want.cycles.at)
            XCTAssertEqual(CTTilesetROM.snes(d.cyclesEnd), want.cycles.end)
            XCTAssertEqual(d.cycles.map { $0.map { [$0.byte0, $0.kind, $0.first, $0.count, $0.delay, $0.offset ?? -1, $0.bank ?? -1, $0.frames ?? -1] } },
                           want.cycles.records.map { $0.map { [$0.byte0, $0.kind, $0.first, $0.count, $0.delay, $0.offset ?? -1, $0.bank ?? -1, $0.frames ?? -1] } })
            XCTAssertEqual(d.cycles.map { $0?.name }, want.cycles.records.map { $0?.name })
            XCTAssertEqual(d.cycles.map { $0?.order }, want.cycles.records.map { $0?.order })
            XCTAssertEqual(d.cycles.map { $0?.colours }, want.cycles.records.map { $0?.colours })
            // The project's cycles through PaletteCycler = the vectors' CGRAM tick by tick.
            var cycler = PaletteCycler(CTTilesets.paletteCycles(d.cycles))
            var cg = CTTilesetROM.cgram(image, want.index)
            var tick = 0
            for snap in want.ticks {
                while tick < snap.tick { cycler.tick(&cg); tick += 1 }
                XCTAssertEqual(Array(cg.prefix(128)), snap.cgram, "palette \(want.index) tick \(snap.tick)")
            }
        }
    }

    func testChipWordIsTheTilemapWord() {
        let c = Tileset.Chip(word: 0xAC05)             // vflip, priority, palette 3, tile 5
        XCTAssertEqual([c.tile, c.pal], [5, 3])
        XCTAssertEqual([c.vflip, c.priority, c.hflip], [true, true, false])
        XCTAssertEqual(c.word, 0xAC05)
        XCTAssertEqual(Tileset.Chip(word: 0x4000).hflip, true)
        for w: UInt16 in [0, 0x03FF, 0x1C00, 0x2000, 0x4000, 0x8000, 0xFFFF] { XCTAssertEqual(Tileset.Chip(word: w).word, w) }
    }

    func testOldTilesetFilesLoadAndSaveUnchanged() throws {
        let old = #"{"bpp":4,"collision":[],"id":"town","metatiles":[{"chips":[{"hflip":false,"pal":2,"priority":true,"tile":7,"vflip":false}]}],"sheet":"tilesets/town.png","tileCount":64}"#
        let ts = try JSONDecoder().decode(Tileset.self, from: Data(old.utf8))
        XCTAssertNil(ts.kind); XCTAssertNil(ts.vram); XCTAssertNil(ts.palettes); XCTAssertNil(ts.rom)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try enc.encode(ts), as: UTF8.self), old)
        // And the fixture project's tilesets still load.
        let project = try CTProject.load(from: fixtureURL())
        XCTAssertFalse(project.tilesets.isEmpty)
        XCTAssertTrue(project.tilesets.values.allSatisfy { $0.kind == nil })
    }

    func testPaletteCyclerKinds() {
        var cg = (0..<256).map { UInt16($0) }
        var down = PaletteCycler([Tileset.PaletteCycle(kind: "rotate-down", first: 0x21, count: 3, delay: 1)])
        down.tick(&cg)
        XCTAssertEqual(Array(cg[0x21...0x24]), [0x22, 0x23, 0x24, 0x21])
        var up = PaletteCycler([Tileset.PaletteCycle(kind: "rotate-up", first: 0x21, count: 3, delay: 2)])
        up.tick(&cg)
        XCTAssertEqual(Array(cg[0x21...0x24]), [0x22, 0x23, 0x24, 0x21])  // waits for its delay
        up.tick(&cg)
        XCTAssertEqual(Array(cg[0x21...0x24]), [0x21, 0x22, 0x23, 0x24])
        var list = PaletteCycler([Tileset.PaletteCycle(kind: "list-frames", first: 0x40, count: 1, delay: 1,
                                                       frames: [["0x0001"], ["0x0002"], ["0x0003"]], order: [2, 0, 1])])
        var shown: [UInt16] = []
        for _ in 0..<4 { list.tick(&cg); shown.append(cg[0x40]) }
        XCTAssertEqual(shown, [1, 2, 3, 1])                // order[1], order[2], order[0], ...
        var slow = PaletteCycler([Tileset.PaletteCycle(kind: "rom-frames", first: 0x50, count: 1, delay: 0,
                                                       frames: [["0x0011"], ["0x0012"]])])
        for _ in 0..<255 { slow.tick(&cg) }
        XCTAssertEqual(cg[0x50], 0x50)
        slow.tick(&cg)
        XCTAssertEqual(cg[0x50], 0x12)                     // delay 0 = every 256 ticks
    }

    /// A CGRAM whose 256 colours tell their index apart after rendering.
    static let probe: [UInt16] = (0..<256).map { BGR555(r5: UInt8($0 & 31), g5: UInt8($0 >> 5), b5: 17).word }
    static func probeIndex(_ px: ArraySlice<UInt8>) -> Int {
        Int(px[px.startIndex]) >> 3 | (Int(px[px.startIndex + 1]) >> 3) << 5
    }

    /// The CGRAM index the field shows at metatile pixel (x, y), from the
    /// tilemap words and tiles directly (flips, palette rows), 0 = backdrop.
    static func expectedIndex(_ ts: Tileset, tiles: [[UInt8]], metatile m: Int, x: Int, y: Int) -> Int {
        let c = ts.metatiles[m].chips[(y / 8) * 2 + x / 8]
        let px = c.hflip ? 7 - x % 8 : x % 8, py = c.vflip ? 7 - y % 8 : y % 8
        let v = Int(c.tile < tiles.count ? tiles[c.tile][py * 8 + px] : 0)
        return v == 0 ? 0 : (ts.bpp == 2 ? 4 : 16) * c.pal + v
    }

    /// Render the scene at each scroll and compare every pixel with the direct decode.
    func checkScene(_ ts: Tileset, tiles: [[UInt8]], file: StaticString = #filePath, line: UInt = #line) {
        let rows = TilesetScene.rows(ts)
        var mismatches = 0, checked = 0
        for scroll in Set([0, max(0, rows * 16 - 224)]) {
            let rgba = PPUReferenceRenderer.render(TilesetScene.frame(ts, tiles: tiles, cgram: Self.probe, scrollY: scroll))
            for sy in 0..<224 {
                let y = sy + scroll, m0 = (y / 16) * TilesetScene.perRow
                for x in 0..<256 {
                    let m = m0 + x / 16
                    let want = m < ts.metatiles.count ? Self.expectedIndex(ts, tiles: tiles, metatile: m, x: x % 16, y: y % 16) : 0
                    let at = (sy * 256 + x) * 4
                    if Self.probeIndex(rgba[at..<(at + 3)]) != want { mismatches += 1 }
                    checked += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0, "\(ts.id): \(mismatches) of \(checked) pixels differ", file: file, line: line)
    }

    func testSceneRendersTheMetatilesAsTheTilemapWordsSay() throws {
        let (_, image) = try vectors()
        var project = try CTProject.load(from: fixtureURL())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cttilesets-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        project.url = dir
        let ids = try CTTilesets.importDecoded(rom: image, into: &project)
        XCTAssertEqual(ids, ["t12_00", "t12_01", "t3_00", "pal_00", "pal_01"])
        for id in ["t12_00", "t12_01", "t3_00"] {
            let ts = try XCTUnwrap(project.tilesets[id])
            let tiles = SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: try XCTUnwrap(ts.sheet))))
            XCTAssertEqual(tiles.count, 1024)
            checkScene(ts, tiles: tiles)
            let direct = TilesetScene.cgramIndices(ts, tiles: tiles)
            XCTAssertEqual(direct.indices, (0..<(direct.width * direct.height)).map { i in
                let x = i % direct.width, y = i / direct.width
                return Self.expectedIndex(ts, tiles: tiles, metatile: y / 16 * 16 + x / 16, x: x % 16, y: y % 16)
            })
        }
        // A tile animation's frame lands on its four characters.
        let ts = try XCTUnwrap(project.tilesets["t12_00"])
        let anim = SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: try XCTUnwrap(ts.animSheet))))
        let a = try XCTUnwrap(ts.tileAnimations?.first)
        XCTAssertEqual(a.tile, (0x3290 - 0x1000) / 16)
        var f = TilesetScene.frame(ts, tiles: SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: ts.sheet!))),
                                   cgram: Self.probe)
        TilesetScene.applyTileAnimations(&f, ts, animTiles: anim, frames: [1, 0])
        var expect = PPUFrame()
        expect.storeTiles(Array(anim[a.frames[1]..<(a.frames[1] + 4)].joined()), bpp: 4, atWord: 0)
        XCTAssertEqual(Array(f.vram[0x3290..<(0x3290 + 64)]), Array(expect.vram[0..<64]))
        // The palette entry gives the scene's CGRAM.
        let cg = TilesetScene.cgram(project.tilesets["pal_00"])
        XCTAssertEqual(Array(cg[0x11..<0x20]), CTTilesetROM.paletteSet(image, 0)[0])
        try project.save()
        let loaded = try CTProject.load(from: dir)
        XCTAssertEqual(loaded.tilesets["t12_00"], project.tilesets["t12_00"])
        XCTAssertEqual(loaded.tilesets["pal_00"], project.tilesets["pal_00"])
        let issues = Validator.validate(loaded).filter { $0.path.hasPrefix("tilesets/t") || $0.path.hasPrefix("tilesets/pal") }
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    func testPlayerRestartsWhenTheFrameGoesBack() {
        let ts = Tileset(id: "t", tileAnimations: [.init(tile: 300, steps: [0x80] + [Int](repeating: 0x80, count: 7), frames: Array(0..<8))])
        let pal = Tileset(id: "p", kind: "palette", paletteCycles: [.init(kind: "rotate-down", first: 0x11, count: 2, delay: 1)])
        var p = TilesetPlayer(tileset: ts, palette: pal, cgram: (0..<256).map { UInt16($0) })
        p.advance(to: 3)
        XCTAssertEqual(Array(p.cgram[0x11...0x13]), [0x11, 0x12, 0x13])   // 3 rotations of 3 colours
        XCTAssertEqual(p.animator.accumulators, [0x200])                  // 1 upload of 4 x $80
        p.advance(to: 1)
        XCTAssertEqual(Array(p.cgram[0x11...0x13]), [0x12, 0x13, 0x11])
        XCTAssertEqual(p.animator.accumulators, [0])
    }

    // MARK: Local ROM

    func testImportFromTheROM() throws {
        let rom = [UInt8](try Repo.romData())
        var project = try CTProject.load(from: fixtureURL())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cttilesets-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        project.url = dir
        let ids = try CTTilesets.importTilesets(rom: rom, into: &project)
        XCTAssertEqual(ids.filter { $0.hasPrefix("t12_") }.count, 53)
        XCTAssertEqual(ids.filter { $0.hasPrefix("t3_") }.count, 18)
        XCTAssertEqual(ids.filter { $0.hasPrefix("pal_") }.count, 83)
        try project.save()
        let loaded = try CTProject.load(from: dir)
        let raw = rom.count == CTROMBuilder.romSize + 512 ? Array(rom.dropFirst(512)) : rom
        let result = try CTTilesets.verify(rom: raw, project: loaded)
        XCTAssertEqual(result.checked, 53 + 18 + 83)
        XCTAssertEqual(result.problems, [])
        let issues = Validator.validate(loaded).filter { $0.path.hasPrefix("tilesets/t") || $0.path.hasPrefix("tilesets/pal") }
        XCTAssertTrue(issues.isEmpty, "\(issues.prefix(5))")
        for id in ["t12_02", "t12_37", "t3_00"] {
            let ts = try XCTUnwrap(loaded.tilesets[id])
            checkScene(ts, tiles: SpriteSheet.tiles(try PNG.readIndexed(url: loaded.fileURL(relative: ts.sheet!))))
        }
        XCTAssertThrowsError(try CTTilesets.importTilesets(rom: [UInt8](repeating: 0, count: CTROMBuilder.romSize), into: &project))
    }
}
