// CTMapsTests.swift — the location map decode against ct_maps.py's synthetic
// vectors (planes, tile properties, exits, treasure, screens), the tile
// property bits, the GameMap extension (old map files load and save
// unchanged), the field scene's registers, scroll and tilemaps against a
// direct decode, and (local ROM) the import, verify and render of every map.
import XCTest
@testable import ChronoForgeCore

final class CTMapsTests: XCTestCase {
    struct Vectors: Decodable {
        struct Region: Decodable { var at: String; var hex: String }
        struct Limits: Decodable, Equatable { var left: Int, top: Int, right: Int, bottom: Int }
        struct Header: Decodable {
            var at: String, music: Int, tileset12: Int, tileset3: Int, palette: Int, mapProps: Int, unk06: Int, events: Int
            var limits: Limits
        }
        struct Props: Decodable {
            var at: String, entry: Int, mode: Int, packedBytes: Int, length: Int, used: Int, entries: Int, runs: Int
            var staleTiles: Int, size1: Int, size3: Int, move2: Int, move3: Int, screens: Int, colorMath: Int
            var layer3Plane: Bool, halfRate2: Bool, ownStep2: Bool, ownStep3: Bool
        }
        struct Exit: Decodable {
            var at: String, x: Int, y: Int, span: Int, vertical: Bool, dest: Int, facing: Int, destFlag: Bool
            var destX: Int, destY: Int, unusedBits: Int
        }
        struct TreasureRecord: Decodable { var at: String, x: Int, y: Int, contents: Int, kind: String, item: Int?, amount: Int? }
        struct Treasure: Decodable { var list: Int, records: [TreasureRecord] }
        struct Location: Decodable {
            var id: Int, header: Header, limits: Limits, fromRecord: Bool, props: Props
            var sizes: [String: [Int]], masks: [String: [Int]], steps: [String: [Int]], ppu: [String: Int]
            var exits: [Exit], exitTiles: [[Int]], treasure: Treasure
            var planes: [String: [Int]], hiBits: [Int], attrA: [Int], attrB: [Int]
            var image: String, unpacked: Int
        }
        var schema: String
        var regions: [Region]
        var locations: [Location]
    }

    func vectors() throws -> (Vectors, [UInt8]) {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("maps/map_vectors.json"))
        XCTAssertEqual(v.schema, "ct-map-vectors/1")
        return (v, try Self.image(v.regions.map { ($0.at, $0.hex) }))
    }

    static func image(_ regions: [(String, String)], into base: [UInt8]? = nil) throws -> [UInt8] {
        var image = base ?? [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        for (at, hex) in regions {
            let pc = CTSpriteROM.pc(try XCTUnwrap(CTSpriteROM.parseSNES(at)))
            let b = CTSpritesTests.bytes(hex)
            image.replaceSubrange(pc..<(pc + b.count), with: b)
        }
        return image
    }

    /// The tileset vectors' tilesets and palettes under the map vectors' tables
    /// (both write LocRom; the maps' records win).
    func combinedImage() throws -> (Vectors, [UInt8]) {
        let (v, _) = try vectors()
        let ts = try JSONDecoder().decode(CTTilesetsTests.Vectors.self, from: resourceData("tilesets/tileset_vectors.json"))
        let base = try Self.image(ts.regions.map { ($0.at, $0.hex) })
        return (v, try Self.image(v.regions.map { ($0.at, $0.hex) }, into: base))
    }

    func testDecodeMatchesThePythonVectors() throws {
        let (v, image) = try vectors()
        XCTAssertEqual(v.locations.count, 4)
        for want in v.locations {
            let d = try CTMapROM.decode(image, want.id)
            let h = d.header, p = d.props, w = want.props
            XCTAssertEqual(CTMapROM.snes(h.at), want.header.at)
            XCTAssertEqual([h.music, h.tileset12, h.tileset3, h.palette, h.mapProps, h.unk06, h.events],
                           [want.header.music, want.header.tileset12, want.header.tileset3, want.header.palette,
                            want.header.mapProps, want.header.unk06, want.header.events])
            XCTAssertEqual(Vectors.Limits(left: d.limits.left, top: d.limits.top, right: d.limits.right, bottom: d.limits.bottom),
                           want.limits, "location \(want.id)")
            XCTAssertEqual(d.fromRecord, want.fromRecord)
            XCTAssertEqual(CTMapROM.snes(d.at), w.at)
            XCTAssertEqual([d.entry, d.mode.rawValue, d.packedBytes, p.length, p.used, p.entries, p.runs, p.staleTiles],
                           [w.entry, w.mode, w.packedBytes, w.length, w.used, w.entries, w.runs, w.staleTiles], "location \(want.id)")
            XCTAssertEqual([p.size1, p.size3, p.move2, p.move3, p.screens, p.colorMath], [w.size1, w.size3, w.move2, w.move3, w.screens, w.colorMath])
            XCTAssertEqual([p.layer3Plane, p.halfRate2, p.ownStep2, p.ownStep3], [w.layer3Plane, w.halfRate2, w.ownStep2, w.ownStep3])
            for k in 1...3 {
                XCTAssertEqual([p.sizes[k - 1].width, p.sizes[k - 1].height], want.sizes["\(k)"])
                XCTAssertEqual([d.masks[k - 1].col, d.masks[k - 1].row], want.masks["\(k)"])
                XCTAssertEqual(p.planes[k], want.planes["\(k)"], "location \(want.id) layer \(k)")
            }
            for k in 2...3 { XCTAssertEqual([d.steps[k - 2].x, d.steps[k - 2].y], want.steps["\(k)"]) }
            XCTAssertEqual(p.hiBits.map(Int.init), want.hiBits)
            XCTAssertEqual(p.attrA.map(Int.init), want.attrA)
            XCTAssertEqual(p.attrB.map(Int.init), want.attrB)
            XCTAssertEqual([Int(d.tm), Int(d.ts), Int(d.cgadsub)], [want.ppu["TM"], want.ppu["TS"], want.ppu["CGADSUB"]].map { $0! })
            XCTAssertEqual([CTMapROM.bgmode, CTMapROM.bg12nba, CTMapROM.bg34nba, CTMapROM.cgwsel, CTMapROM.coldata].map(Int.init),
                           ["BGMODE", "BG12NBA", "BG34NBA", "CGWSEL", "COLDATA"].map { want.ppu[$0]! })
            XCTAssertEqual(d.exits.map { [$0.x, $0.y, $0.span, $0.vertical ? 1 : 0, $0.dest, $0.facing, $0.destFlag ? 1 : 0,
                                          $0.destX, $0.destY, $0.unusedBits] },
                           want.exits.map { [$0.x, $0.y, $0.span, $0.vertical ? 1 : 0, $0.dest, $0.facing, $0.destFlag ? 1 : 0,
                                             $0.destX, $0.destY, $0.unusedBits] })
            XCTAssertEqual(d.exits.map { CTMapROM.snes(CTMapROM.exitOfs + $0.offset) }, want.exits.map(\.at))
            for (e, raw) in zip(d.exits, want.exits) { XCTAssertEqual(CTMapROM.ExitRecord(raw: e.raw.map(Int.init)).dest, raw.dest) }
            let tiles = CTMapROM.exitTiles(d.exits.map { ($0.x, $0.y, $0.span, $0.vertical) },
                                           colMask: d.masks[0].col, rowMask: d.masks[0].row)
            XCTAssertEqual(tiles.sorted { $0.key < $1.key }.map { [$0.key, $0.value] }, want.exitTiles, "location \(want.id)")
            XCTAssertEqual(d.treasureList, want.treasure.list)
            XCTAssertEqual(d.treasure.map { [$0.x, $0.y, $0.contents] }, want.treasure.records.map { [$0.x, $0.y, $0.contents] })
            XCTAssertEqual(d.treasure.map { CTMapROM.snes(CTMapROM.treasureBank + $0.offset) }, want.treasure.records.map(\.at))
            for (t, r) in zip(d.treasure, want.treasure.records) {
                switch CTMapROM.TreasureKind(contents: t.contents) {
                case .gold(let g): XCTAssertEqual(r.kind, "gold"); XCTAssertEqual(g, r.amount)
                case .empty: XCTAssertEqual(r.kind, "empty")
                case .item(let i): XCTAssertEqual(r.kind, "item"); XCTAssertEqual(i, r.item)
                }
            }
            // The packer gives back what the parser read.
            let image = CTSpritesTests.bytes(want.image)
            XCTAssertEqual(image.count, want.unpacked)
            let q = try CTMapROM.parseProps(CTMapROM.packProps(p))
            XCTAssertEqual(q.used, q.length)
            XCTAssertEqual(q.planes.mapValues { $0.map { $0 & 0xFF } }, p.planes.mapValues { $0.map { $0 & 0xFF } })
            XCTAssertEqual([q.hiBits, q.attrA, q.attrB], [p.hiBits, p.attrA, p.attrB])
            if p.staleTiles == 0 { XCTAssertEqual(try CTMapROM.parseProps(image), p) }
        }
        // HiBits bit 7 starts a run: the packer drops it from an edited tile instead of corrupting the triples.
        var edited = try CTMapROM.decode(image, 0).props
        edited.hiBits[0] |= 0x80
        let q = try CTMapROM.parseProps(CTMapROM.packProps(edited))
        XCTAssertEqual(q.used, q.length)
        XCTAssertEqual(q.hiBits[0], edited.hiBits[0] & 0x7F)
        XCTAssertEqual(Array(q.attrA[1...]), Array(edited.attrA[1...]))
    }

    func testFormulas() {
        XCTAssertEqual(CTMapROM.layerSizes(size1: 0x01 | 0x08 | 0x30 | 0x40, size3: 0x06).map { [$0.width, $0.height] },
                       [[32, 48], [64, 32], [48, 32]])
        XCTAssertEqual([0x10, 0x20, 0x30, 0x40].map(CTMapROM.wrapMask), [0x0F, 0x1F, 0x3F, 0x3F])
        XCTAssertTrue(CTMapROM.ownStep(0x0A | 0x90) == (-2, -1))
        XCTAssertTrue(CTMapROM.ownStep(0x73) == (4, 64))
        XCTAssertTrue(CTMapROM.screens(0xFF, colorMath: 0x82, tileset3: 0) == (0x17, 0x17, 0x82))
        XCTAssertTrue(CTMapROM.screens(0xFF, colorMath: 0x82, tileset3: CTMapROM.none) == (0x13, 0x13, 0x82))
        XCTAssertTrue(CTMapROM.screens(0x4B, colorMath: 3, tileset3: 0) == (0x13, 0x04, 3))
        // A map that ends before its triples cover layer 1 takes zeros.
        let short = [UInt8]([0, 0, 0, 0, 0x13, 0]) + [UInt8](repeating: 0, count: 512) + [0x80, 9, 9, 250]
        let p = try? CTMapROM.parseProps(short)
        XCTAssertEqual(p?.staleTiles, 6)
        XCTAssertEqual(p.map { Array($0.attrA.suffix(7)) }, [9] + [UInt8](repeating: 0, count: 6))
    }

    func testTilePropertyBits() {
        var t = CTTileProps(hiBits: 0x1E << 2 | 2, attrA: 0x4B, attrB: 0x80 | 0x40 | 0x20 | 0x02)
        XCTAssertEqual(t.shape, 0x1E); XCTAssertEqual(t.shapeName, "stair")
        XCTAssertFalse(t.layer1Bit8); XCTAssertTrue(t.layer2Bit8)
        XCTAssertEqual([t.pushDirection, t.pushSpeed, t.pushAmount], [3, 2, 0x10])
        XCTAssertTrue(t.overheadLow && t.overheadHigh && t.blocksObjects)
        XCTAssertFalse(t.animTrigger)
        XCTAssertEqual(t.levelA, 2); XCTAssertNil(t.levelB)
        XCTAssertEqual(t.walkA, .plane2); XCTAssertEqual(t.walkB, .neutral)
        t.setWalk(.solid); XCTAssertEqual(t.attrB & 7, 0); XCTAssertEqual(t.walkA, .solid)
        t.setWalk(.transition, halfB: true); XCTAssertEqual(t.levelB, 3)
        XCTAssertEqual(t.attrB & 0xC0, 0xC0, "the walk painter keeps the priority and object bits")
        t.setPush(direction: 1, speed: 3); XCTAssertEqual(t.attrA & 0x0F, 0x0D); XCTAssertEqual(t.attrA & 0xF0, 0x40)
        XCTAssertEqual(CTTileProps(hiBits: 5 << 2, attrA: 0, attrB: 0).shapeName, "slope 3")
        XCTAssertTrue(CTTileProps(hiBits: 1 << 2, attrA: 0, attrB: 0).hasHalfB)
        XCTAssertFalse(CTTileProps(hiBits: 0x1E << 2, attrA: 0, attrB: 0).hasHalfB)
        let plane = CTTilePropsPlane(width: 2, height: 1, hiBits: [1, 2], attrA: [0, 0x10], attrB: [3, 4])
        XCTAssertEqual(CTTilePropsPlane(plane.json), plane)
        XCTAssertEqual(plane[1, 0].attrA, 0x10)
        XCTAssertNil(CTTilePropsPlane(GameMap.TileProps(width: 2, height: 1, hiBits: "01", attrA: "0000", attrB: "0304")))
    }

    func testOldMapFilesLoadAndSaveUnchanged() throws {
        let old = #"{"exits":[{"map":"b","toX":1,"toY":2,"x":3,"y":4}],"height":2,"id":"a","layers":[{"bg":1,"metatiles":[0,1,2,3]}],"name":"A","tileset":"town","triggers":[],"width":2}"#
        let m = try JSONDecoder().decode(GameMap.self, from: Data(old.utf8))
        XCTAssertNil(m.location); XCTAssertNil(m.settings); XCTAssertNil(m.tileProps); XCTAssertNil(m.rom)
        XCTAssertNil(m.layers[0].width); XCTAssertNil(m.exits[0].span)
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(String(decoding: try enc.encode(m), as: UTF8.self), old)
        // The fixture's hand-made maps keep their screens: their layers and OBJ.
        let project = try CTProject.load(from: fixtureURL())
        let ow = try XCTUnwrap(project.maps["overworld"])
        XCTAssertEqual(LocationScene.screens(ow).tm, 0x13)
        XCTAssertEqual(LocationScene.invariants(ow, project: project), [])
    }

    func testRegistersAndScroll() throws {
        let (v, image) = try vectors()
        let maps = try v.locations.map { CTMaps.gameMap(try CTMapROM.decode(image, $0.id)) }
        for (m, want) in zip(maps, v.locations) {
            let r = LocationScene.registers(m)
            XCTAssertEqual([r.bgmode, r.bg[0].charBase | r.bg[1].charBase << 4, r.bg[2].charBase | r.bg[3].charBase << 4,
                            r.cgwsel, r.tm, r.ts, r.cgadsub].map(Int.init),
                           ["BGMODE", "BG12NBA", "BG34NBA", "CGWSEL", "TM", "TS", "CGADSUB"].map { want.ppu[$0]! })
            XCTAssertEqual(r.bg.prefix(3).map(\.sc), [0x61, 0x69, 0x71])
            let hidden = LocationScene.registers(m, show: .init(bg1: false, bg3: false, colorMath: false))
            XCTAssertEqual(Int(hidden.tm), want.ppu["TM"]! & ~0x05)
            XCTAssertEqual(hidden.cgadsub, 0)
        }
        // Location 1: layer 2 at half rate with its own step (-2,-1)/16 px a frame; layer 3 steps (4,2)/16 px.
        let m = maps[1]
        XCTAssertTrue(LocationScene.scroll(m, layer: 1, cameraX: 100, cameraY: 60, frame: 0) == (100, 60))
        XCTAssertTrue(LocationScene.scroll(m, layer: 2, cameraX: 100, cameraY: 60, frame: 0) == (50, 30))
        XCTAssertTrue(LocationScene.scroll(m, layer: 2, cameraX: 100, cameraY: 60, frame: 32) == (46, 28))
        XCTAssertTrue(LocationScene.scroll(m, layer: 3, cameraX: 100, cameraY: 60, frame: 8) == (102, 61))
        XCTAssertTrue(LocationScene.clampCamera(m, x: 9999, y: -5) == (32 * 16 - 256, 0))
    }

    func testImportAndSceneOnTheSyntheticTables() throws {
        let (v, image) = try combinedImage()
        var project = try CTProject.load(from: fixtureURL())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctmaps-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        project.url = dir
        project.maps["loc_001"] = GameMap(id: "loc_001", name: "Kept", tileset: "", width: 1, height: 1, layers: [], exits: [],
                                          triggers: [GameMap.Trigger(x: 1, y: 2, scene: "intro")])
        let ids = try CTMaps.importDecoded(rom: image, into: &project, locations: [0, 1, 2, 3])
        XCTAssertEqual(ids, ["loc_000", "loc_001", "loc_002", "loc_003"])
        XCTAssertEqual(project.maps["loc_001"]?.name, "Kept")
        XCTAssertEqual(project.maps["loc_001"]?.triggers.count, 1)
        for id in ["t12_00", "t12_01", "t3_00", "pal_00", "pal_01"] { XCTAssertNotNil(project.tilesets[id], id) }
        let result = try CTMaps.verify(rom: image, project: project)
        XCTAssertEqual(result.checked, 4)
        XCTAssertEqual(result.problems, [])
        // A changed exit is reported.
        var changed = project
        changed.maps["loc_000"]!.exits[0].toX += 1
        XCTAssertEqual(try CTMaps.verify(rom: image, project: changed).problems, ["loc_000: exits differ from the ROM"])
        try project.save()
        let loaded = try CTProject.load(from: dir)
        for id in ids { XCTAssertEqual(loaded.maps[id], project.maps[id], id) }

        // Location 0's picture: every visible cell's tilemap word is its metatile's chip.
        let m = try XCTUnwrap(loaded.maps["loc_000"])
        XCTAssertEqual(m.treasure?.count, v.locations[0].treasure.records.count)
        let assets = try LocationScene.assets(for: m, project: loaded)
        XCTAssertEqual(assets.t12?.id, "t12_00"); XCTAssertEqual(assets.t3?.id, "t3_00"); XCTAssertEqual(assets.palette?.id, "pal_00")
        let f = LocationScene.frame(m, assets: assets, cgram: TilesetScene.cgram(assets.palette), cameraX: 0, cameraY: 0, frame: 0)
        for (k, l) in m.layers.enumerated() {
            let ts = try XCTUnwrap(k == 2 ? assets.t3 : assets.t12)
            let s = LocationScene.layerSize(m, l)
            for ty in 0..<28 {
                for tx in 0..<32 {
                    let mt = l.metatiles[(ty >> 1 & (s.height - 1)) * s.width + (tx >> 1 & (s.width - 1))]
                    let chips = ts.metatiles[mt].chips, q = (tx & 1) + 2 * (ty & 1)
                    let want: UInt16 = q < chips.count ? chips[q].word : 0
                    XCTAssertEqual(f.vram[CTMapROM.tilemaps[k] + ty * 32 + tx], want, "layer \(k + 1) cell \(tx),\(ty)")
                }
            }
        }
        XCTAssertEqual(f.lines[0].bg[0].vofs, 0x3FF, "VOFS is the scroll minus 1")
        var planar = PPUFrame()
        planar.storeTiles(assets.t12Tiles[0], bpp: 4, atWord: 0)
        XCTAssertEqual(Array(f.vram[0x1000..<0x1010]), Array(planar.vram[0..<16]))
        let rgba = PPUReferenceRenderer.render(f)
        XCTAssertEqual(rgba.count, 256 * 224 * 4)
        let whole = LocationScene.render(m, assets: assets, cgram: TilesetScene.cgram(assets.palette), frame: 0)
        XCTAssertEqual([whole.width, whole.height], [256, 256])
        XCTAssertEqual(Array(whole.rgba[0..<(256 * 4)]), Array(rgba[0..<(256 * 4)]), "the stitched picture starts with the camera's")
        XCTAssertEqual(LocationScene.invariants(m, project: loaded), [])
        let issues = Validator.validate(loaded).filter { $0.path.hasPrefix("maps/loc_") && !$0.message.contains("exit to missing map") }
        XCTAssertTrue(issues.isEmpty, "\(issues)")
    }

    // MARK: Local ROM

    func testImportVerifyAndRenderEveryLocation() throws {
        let rom = [UInt8](try Repo.romData())
        var project = try CTProject.load(from: fixtureURL())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctmaps-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        project.url = dir
        let ids = try CTMaps.importMaps(rom: rom, into: &project)
        XCTAssertEqual(ids.count, 512)
        XCTAssertEqual(project.tilesets[CTMaps.noTileset], CTMaps.emptyTileset)
        try project.save()
        let loaded = try CTProject.load(from: dir)
        let raw = rom.count == CTROMBuilder.romSize + 512 ? Array(rom.dropFirst(512)) : rom
        let result = try CTMaps.verify(rom: raw, project: loaded)
        XCTAssertEqual(result.checked, 512)
        XCTAssertEqual(result.problems, [])
        let issues = Validator.validate(loaded).filter { $0.path.hasPrefix("maps/") || $0.path.hasPrefix("tilesets/") }
        XCTAssertTrue(issues.isEmpty, "\(issues.prefix(5))")
        // Every map's tile properties and props round-trip through the packer.
        var stale: Set<Int> = [], treasure = 0, exits = 0
        for i in 0..<CTMapROM.locCount {
            let d = try CTMapROM.decode(raw, i)
            if d.props.staleTiles > 0 { stale.insert(d.entry) }
            treasure += d.treasureList == i ? d.treasure.count : 0
            exits += d.exits.count
            let q = try CTMapROM.parseProps(CTMapROM.packProps(d.props))
            XCTAssertEqual([q.hiBits, q.attrA, q.attrB], [d.props.hiBits, d.props.attrA, d.props.attrB], "location \(i)")
        }
        XCTAssertEqual(stale, [29, 58, 98, 191, 193], "the MapProps entries that end before their triples do")
        XCTAssertEqual(exits, 814)
        XCTAssertEqual(treasure, 244, "the chest records, location 0's dummy one among them")
        // Location 1 (Truce houses): field registers and a picture with some of every layer.
        let m = try XCTUnwrap(loaded.maps["loc_001"])
        let r = LocationScene.registers(m)
        XCTAssertEqual([r.tm, r.ts, r.cgadsub], [0x13, 0x04, 0x03])
        let assets = try LocationScene.assets(for: m, project: loaded)
        let f = LocationScene.frame(m, assets: assets, cgram: TilesetScene.cgram(assets.palette), cameraX: 0, cameraY: 0, frame: 0)
        let rgba = PPUReferenceRenderer.render(f)
        XCTAssertGreaterThan(Set(stride(from: 0, to: rgba.count, by: 4).map { Int(rgba[$0]) << 16 | Int(rgba[$0 + 1]) << 8 | Int(rgba[$0 + 2]) }).count, 32)
    }
}
