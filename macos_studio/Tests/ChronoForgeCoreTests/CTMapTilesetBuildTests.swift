// CTMapTilesetBuildTests.swift — rom.maps and rom.tilesets: the MapProps,
// ExitRom and cycle-list encoders on synthetic data, the refusals, the
// validator, and with the local ROM the identical rebuild of every map and
// tileset and the encoders reproducing every ROM table.
import XCTest
@testable import ChronoForgeCore

final class CTMapTilesetBuildTests: XCTestCase {
    static let zeroProps = CTMapROM.Props(size1: 0, size3: 0, move2: 0, move3: 0, screens: 0, colorMath: 0, sizes: [],
                                          layer3Plane: false, halfRate2: false, ownStep2: false, ownStep3: false,
                                          planes: [:], hiBits: [], attrA: [], attrB: [])

    /// A 32 x 16 map with a 16 x 16 layer 2 and a layer 3, metatiles past 255 on both layers.
    func syntheticMap() -> GameMap {
        let w = 32, h = 16
        var hi = [UInt8](repeating: 0x04, count: w * h), a = [UInt8](repeating: 0, count: w * h), b = hi
        var l1 = (0..<(w * h)).map { $0 % 200 }, l2 = (0..<256).map { ($0 * 3) % 256 }
        l1[5] |= 0x100; hi[5] |= 1
        l2[17] |= 0x100; hi[1 * w + 1] |= 2                        // layer-2 cell (1, 1) is layer-1 tile 1 * w + 1
        for k in 100..<140 { a[k] = 0x05; b[k] = 0x92 }
        let props = CTTilePropsPlane(width: w, height: h, hiBits: hi, attrA: a, attrB: b)
        return GameMap(id: "loc_007", name: "Synthetic", tileset: "t12_01", width: w, height: h,
                       layers: [.init(bg: 1, metatiles: l1), .init(bg: 2, metatiles: l2, width: 16, height: 16),
                                .init(bg: 3, metatiles: (0..<256).map { $0 }, width: 16, height: 16)],
                       exits: [.init(x: 3, y: 4, map: "loc_009", toX: 5, toY: 6, span: 2, vertical: true, facing: 3)],
                       triggers: [],
                       location: .init(music: 7, tileset12: 1, tileset3: 0, palette: 2, events: 9, unk06: 0, limits: [0x80, 0, 0, 0]),
                       settings: .init(screens: 0x17, colorMath: 0x22, move2: 0x11, halfRate2: true, ownStep3: true),
                       tileProps: props.json, treasure: [.init(x: 1, y: 2, contents: 0x8010)],
                       rom: .init(location: 7, record: "$F6:0062", mapProps: 3, packedAt: "$F0:0000", packedBytes: 1,
                                  unpackedBytes: 1, staleTiles: 0, exitsAt: nil, treasureList: 7, treasureAt: nil))
    }

    // MARK: No ROM

    func testMapPropsFromAProjectMapUnpackToIt() throws {
        let m = syntheticMap()
        let p = try CTMapPatch.props(m, base: Self.zeroProps)
        XCTAssertEqual(p.size1, 0x01 | 0x00 | 0x00)                   // 32 wide, 16 high; layer 2 16 x 16
        XCTAssertEqual(p.size3, 0x80 | 0x40 | 0x20)                   // a layer-3 plane, half rate, layer 3's own step
        let q = try CTMapROM.parseProps(CTMapROM.packProps(p))
        XCTAssertTrue(CTMapPatch.sameContent(p, q))
        XCTAssertEqual(q.planes[1], m.layers[0].metatiles)
        XCTAssertEqual(q.planes[2], m.layers[1].metatiles)
        XCTAssertEqual(q.planes[3], m.layers[2].metatiles)
        XCTAssertEqual(q.staleTiles, 0)
        XCTAssertGreaterThan(q.runs, 0, "equal triples pack as runs")
        XCTAssertEqual(CTMapPatch.validate(m), [])
        let record = try CTMapPatch.record(m, base: CTMapROM.header([UInt8](repeating: 0, count: CTROMBuilder.romSize), 7), entry: 0x123)
        XCTAssertEqual(record, [7, 1, 0, 2, 0x23, 0x01, 0, 0, 9, 0, 0x80, 0, 0, 0])
    }

    func testBadMapsAreRefused() {
        func refusal(_ change: (inout GameMap) -> Void) -> String {
            var m = syntheticMap()
            change(&m)
            return CTMapPatch.validate(m).joined(separator: " | ")
        }
        XCTAssertTrue(refusal { $0.layers[1].width = 20 }.contains("each side is 16, 32, 48 or 64"))
        XCTAssertTrue(refusal { $0.layers[0].metatiles[5] ^= 0x100 }.contains("disagree"))
        XCTAssertTrue(refusal { $0.layers[1].metatiles[200] = 0x105 }.contains("HiBits bit 1"))
        XCTAssertTrue(refusal { $0.layers[2].metatiles[0] = 300 }.contains("not 0-255"))
        XCTAssertTrue(refusal { m in
            var t = CTTilePropsPlane(m.tileProps!)!
            t.hiBits[3] = 0x80
            m.tileProps = t.json
        }.contains("starts a run"))
        XCTAssertTrue(refusal { $0.exits[0].map = "loc_512" }.contains("is not loc_000-loc_511"))
        XCTAssertTrue(refusal { $0.location!.tileset12 = 2 }.contains("is not the one its location record loads"))
        XCTAssertTrue(refusal { $0.location!.palette = 88 }.contains("palette 88"))
        XCTAssertTrue(refusal { $0.treasure = [.init(x: 0, y: 0, contents: 5)] }.contains("redirect"))
        XCTAssertTrue(refusal { $0.rom = nil }.contains("no rom.location"))
    }

    func testExitBlockHoldsOffsetWordsThenRecords() throws {
        let a: [UInt8] = [1, 2, 3, 4, 5, 6, 7], b: [UInt8] = [8, 9, 10, 11, 12, 13, 14]
        var lists = [[[UInt8]]](repeating: [], count: CTMapROM.locCount)
        lists[0] = [a]; lists[2] = [b, a]
        let block = CTMapPatch.exitBlock(lists)
        let word = { (i: Int) in Int(block[2 * i]) | Int(block[2 * i + 1]) << 8 }
        XCTAssertEqual(block.count, 2 * 513 + 21)
        XCTAssertEqual([word(0), word(1), word(2), word(3), word(512)], [0x402, 0x409, 0x409, 0x417, 0x417])
        XCTAssertEqual(Array(block[0x409..<0x410]), b)
        XCTAssertEqual(try CTMapPatch.exitBytes(syntheticMap().exits[0], map: "x"), [3, 4, 0x82, 9, 0x06, 5, 6])
    }

    func testCycleListsEncodeAsTheLoaderReadsThem() throws {
        let cycles = [Tileset.PaletteCycle(kind: "rotate-down", first: 0x21, count: 3, delay: 4),
                      Tileset.PaletteCycle(kind: "list-frames", first: 0x31, count: 1, delay: 2,
                                           frames: [["0x001F"], ["0x7C00"]], order: [0, 1, 1])]
        let list = try CTTilesetPatch.cycleList(cycles, id: "pal_99") { _ in 0x7568 }
        XCTAssertEqual(list, [0x20, 0x21, 3, 4, 0x82, 0x31, 1, 2, 0x68, 0x75, 0xF6, 0, 1, 1, 0, 0, 0, 0])
        XCTAssertEqual(try CTTilesetPatch.frameBytes(cycles[1], id: "pal_99"), [0x1F, 0, 0, 0x7C])
        XCTAssertThrowsError(try CTTilesetPatch.cycleList([.init(kind: "rotate-up", first: 2, count: 3, delay: 1)], id: "p") { _ in 0 })
        XCTAssertThrowsError(try CTTilesetPatch.cycleList([.init(kind: "fade", first: 20, count: 3, delay: 1)], id: "p") { _ in 0 })
        var ts = Tileset(id: "pal_03", kind: "palette", palettes: [[String]](repeating: [String](repeating: "0x0000", count: 16), count: 8),
                         rom: .init(family: "ct-locpal", index: 3, table: "$F6:2736"))
        XCTAssertEqual(CTTilesetPatch.validate(ts), [])
        XCTAssertEqual(try CTTilesetPatch.paletteBytes(ts).count, CTTilesetROM.palSetBytes)
        ts.palettes![2][3] = "0x8000"
        XCTAssertTrue(CTTilesetPatch.validate(ts).joined().contains("is not a BGR555 word"))
        ts.rom!.index = 4
        XCTAssertTrue(CTTilesetPatch.validate(ts).joined().contains("does not name this palette"))
    }

    func testFreeSpaceAllocatesInsideABank() {
        var space = FreeSpace()
        space.add(0x100000..<0x100020, reclaimed: false)
        space.add(0x360000..<0x360010, reclaimed: false)
        XCTAssertEqual(space.allocate(8, reclaimed: false, bank: 0x36), 0x360000)
        XCTAssertNil(space.allocate(9, reclaimed: false, bank: 0x36))
        XCTAssertEqual(space.allocate(9, reclaimed: false), 0x100000)
    }

    func testValidatorChecksMapAndTilesetBuildSettings() throws {
        var project = try CTProject.load(from: fixtureURL())
        let hand = try XCTUnwrap(project.tilesets.keys.sorted().first)
        project.project.rom = .init(maps: ["nope", "overworld", "overworld"], tilesets: ["missing", hand])
        let messages = Validator.validate(project).filter { $0.gate == 4 }.map(\.description)
        for expected in ["no maps/nope.map.json", "map built twice", "no rom.location", "no tilesets/missing.tileset.json",
                         "no rom source"] {
            XCTAssertTrue(messages.contains { $0.contains(expected) }, "\(expected) not in \(messages)")
        }
        let data = try CTProject.jsonEncoder.encode(project.project)
        XCTAssertEqual(try JSONDecoder().decode(Project.self, from: data).rom, project.project.rom)
    }

    // MARK: Local ROM

    /// Every map and every tileset imported, listed in rom.maps / rom.tilesets
    /// and built gives the clean ROM byte for byte, and the encoders the build
    /// uses reproduce every ROM table from the import.
    func testEveryMapAndTilesetRebuildsFromItsImport() throws {
        guard let data = try? Repo.romData() else { throw XCTSkip("local ROM not present") }
        var rom = [UInt8](data)
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        var project = try CTProject.load(from: fixtureURL())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctbuild-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        project.url = dir
        let maps = try CTMaps.importMaps(rom: rom, into: &project)
        try CTTilesets.importTilesets(rom: rom, into: &project)
        let tilesets = project.tilesets.filter { $0.value.rom != nil }.keys.sorted()
        project.project.rom = .init(maps: maps, tilesets: tilesets)
        try project.save()
        let loaded = try CTProject.load(from: dir)
        XCTAssertEqual(Validator.validate(loaded).filter {
            $0.gate == 4 && ($0.path.hasPrefix("project.json rom") || $0.path.hasPrefix("maps/") || $0.path.hasPrefix("tilesets/"))
        }.map(\.description), [])
        let (built, report) = try CTROMBuilder.build(base: rom, project: loaded)
        XCTAssertEqual(CTEventPack.sha256(built), CTTextProfile.romHash)
        XCTAssertEqual(report.writes, [])
        XCTAssertNil(report.relocations)
        XCTAssertEqual(report.maps?.count, 512)
        XCTAssertEqual(Set(report.maps?.map(\.placement) ?? []), ["unchanged"])
        XCTAssertEqual(report.tilesets?.count, tilesets.count)
        XCTAssertEqual(report.tilesets?.allSatisfy { $0.changed.isEmpty && $0.blocks.isEmpty }, true)

        // The encoders on every ROM table: MapProps content, ExitRom, palette sets, cycle lists, metatiles.
        for i in 0..<CTMapROM.locCount {
            let d = try CTMapROM.decode(rom, i)
            let p = try CTMapPatch.props(loaded.maps[CTMaps.id(i)]!, base: d.props)
            XCTAssertTrue(CTMapPatch.sameContent(try CTMapROM.parseProps(CTMapROM.packProps(p)), d.props), "location \(i)")
            XCTAssertEqual(try CTMapPatch.record(loaded.maps[CTMaps.id(i)]!, base: d.header, entry: d.entry),
                           Array(rom[CTMapROM.pc(d.header.at)..<(CTMapROM.pc(d.header.at) + 14)]), "location \(i)")
        }
        let exits = (0..<CTMapROM.locCount).map { i in
            try! loaded.maps[CTMaps.id(i)]!.exits.map { try CTMapPatch.exitBytes($0, map: "") }
        }
        XCTAssertEqual(CTMapPatch.exitBlock(exits), CTMapPatch.baseExitBlock(rom))
        var exactLists = 0
        for (id, ts) in loaded.tilesets.sorted(by: { $0.key < $1.key }) where ts.rom?.family == "ct-locpal" {
            let p = ts.rom!.index
            let at = CTTilesetROM.pc(CTTilesetROM.locPal + CTTilesetROM.palSetBytes * p)
            XCTAssertEqual(try CTTilesetPatch.paletteBytes(ts), Array(rom[at..<(at + CTTilesetROM.palSetBytes)]), id)
            let d = CTTilesetROM.decodePalette(rom, p)
            let old = d.cycles.compactMap { $0 }
            let list = try CTTilesetPatch.cycleList(ts.paletteCycles ?? [], id: id) { old[$0].offset! }
            for (i, c) in (ts.paletteCycles ?? []).enumerated() where c.frames != nil {
                let f = try CTTilesetPatch.frameBytes(c, id: id), src = CTTilesetROM.pc(CTTilesetROM.palAnimRom + old[i].offset!)
                XCTAssertEqual(f, Array(rom[src..<(src + f.count)]), "\(id) cycle \(i) frames")
            }
            if list == Array(rom[CTTilesetROM.pc(d.cyclesAt)..<CTTilesetROM.pc(d.cyclesEnd)]) { exactLists += 1 }
            // Empty records between filled ones are not kept: the list re-decodes to the same cycles.
            var copy = rom
            copy.replaceSubrange(CTTilesetROM.pc(d.cyclesAt)..<(CTTilesetROM.pc(d.cyclesAt) + list.count), with: list)
            XCTAssertEqual(CTTilesets.paletteCycles(CTTilesetROM.animListB(copy, p).records), ts.paletteCycles ?? [], id)
            XCTAssertLessThanOrEqual(list.count, d.cyclesEnd - d.cyclesAt, id)
        }
        XCTAssertEqual(exactLists, 79, "all but 4 lists (26, 34, 75, 87: empty records between filled ones) byte for byte")
        for (id, ts) in loaded.tilesets where ts.rom?.family == "ct-loc12" || ts.rom?.family == "ct-loc3" {
            let table = try CTTilesetROM.metaTable(rom, ptrs: ts.rom!.family == "ct-loc12" ? CTTilesetROM.meta12Ptrs : CTTilesetROM.meta3Ptrs,
                                                   ts.rom!.index)
            let bytes = try CTTilesetPatch.metatileBytes(ts, count: table.metatiles.count)
            XCTAssertEqual(bytes, Array(try CTTilesetROM.unpack(rom, table.at).out.prefix(bytes.count)), id)
            XCTAssertEqual(LZSS.compress(try CTTilesetROM.unpack(rom, table.at).out, mode: table.mode),
                           Array(rom[CTTilesetROM.pc(table.at)..<(CTTilesetROM.pc(table.at) + table.packed)]),
                           "\(id): the packer rebuilds the metatile table byte for byte")
        }
    }
}
