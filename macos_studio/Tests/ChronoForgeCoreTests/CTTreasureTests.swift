// CTTreasureTests.swift — TreasureRom rebuilt whole and new locations: the
// flag numbering, the offset words, the limits, placement in place / grown /
// refused on a synthetic ROM, the chest edits, CTNewLocation, the validator;
// with the local ROM a build that grows TreasureRom (moving a MapProps pack
// out of bank $F5) and creates location 448.
import XCTest
@testable import ChronoForgeCore

final class CTTreasureTests: XCTestCase {
    typealias Record = CTTreasure.Record

    /// A zero ROM whose TreasureRom holds `lists` from offset $F402, as the game lays it out.
    func syntheticROM(_ lists: [[Record]]) -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        let words = CTTreasure.words(lists, start: 0xF402), body = CTTreasure.records(lists)
        rom.replaceSubrange(CTTreasure.wordsPC..<(CTTreasure.wordsPC + words.count), with: words)
        let at = CTMapROM.pc(CTMapROM.treasureBank + 0xF402)
        rom.replaceSubrange(at..<(at + body.count), with: body)
        return rom
    }

    func lists(_ some: [Int: [Record]]) -> [[Record]] {
        (0..<CTMapROM.locCount).map { some[$0] ?? [] }
    }

    func map(_ i: Int, treasure: [GameMap.Treasure] = [], list: Int? = nil) -> GameMap {
        GameMap(id: CTMaps.id(i), name: "Location \(i)", tileset: "", width: 16, height: 16,
                layers: [.init(bg: 1, metatiles: Array(repeating: 0, count: 256)),
                         .init(bg: 2, metatiles: Array(repeating: 0, count: 256), width: 16, height: 16)], exits: [], triggers: [],
                tileProps: CTTilePropsPlane(width: 16, height: 16, hiBits: Array(repeating: 0, count: 256),
                                            attrA: Array(repeating: 0, count: 256), attrB: Array(repeating: 0, count: 256)).json,
                treasure: treasure,
                rom: .init(location: i, record: CTMapROM.snes(CTMapROM.locRom + CTMapROM.locBytes * i), mapProps: 1,
                           packedAt: "$F0:0000", packedBytes: 1, unpackedBytes: 1, staleTiles: 0, exitsAt: nil,
                           treasureList: list ?? i, treasureAt: nil))
    }

    // MARK: No ROM

    func testFlagsAreRecordPlacesAndWordsFollowTheLists() {
        let l = lists([0: [Record(tile: 0x2F2F, contents: 0)], 2: [Record(tile: 0x0201, contents: 5), Record(tile: 0x0302, contents: 0x8010)],
                       3: [Record(tile: 0, contents: 2)], 5: [Record(tile: 0x0404, contents: 0x4000)]])
        let n = CTTreasure.numbers(l)
        XCTAssertEqual(n[0], [0])
        XCTAssertEqual(n[2], [1, 2])
        XCTAssertEqual(n[3], [3], "a redirect record takes a number too")
        XCTAssertEqual(n[5], [4])
        let w = CTTreasure.words(l, start: 0xF402)
        XCTAssertEqual(w.count, 2 * CTTreasure.wordCount)
        func word(_ i: Int) -> Int { Int(w[2 * i]) | Int(w[2 * i + 1]) << 8 }
        XCTAssertEqual([word(0), word(1), word(2), word(3), word(4), word(5), word(6), word(512)],
                       [0xF402, 0xF406, 0xF406, 0xF40E, 0xF412, 0xF412, 0xF416, 0xF416])
        XCTAssertEqual(Array(CTTreasure.records(l).prefix(8)), [0x2F, 0x2F, 0, 0, 0x01, 0x02, 0x05, 0x00])
        XCTAssertTrue(CTTreasure.isRedirect(l[3]))
        let rom = syntheticROM(l)
        XCTAssertEqual(CTTreasure.lists(rom), l)
        XCTAssertEqual(CTTreasure.start(rom), 0xF402)
    }

    func testTheLimitsAreRefused() {
        let tooMany = lists([1: Array(repeating: Record(tile: 0x0101, contents: 1), count: 100),
                             2: Array(repeating: Record(tile: 0x0101, contents: 1), count: 100),
                             3: Array(repeating: Record(tile: 0x0101, contents: 1), count: 100),
                             4: Array(repeating: Record(tile: 0x0101, contents: 1), count: 100),
                             5: Array(repeating: Record(tile: 0x0101, contents: 1), count: 113)])
        XCTAssertThrowsError(try CTTreasure.check(tooMany)) { XCTAssertTrue("\($0)".contains("513 records")) }
        let long = lists([7: Array(repeating: Record(tile: 0x0101, contents: 1), count: 129)])
        XCTAssertThrowsError(try CTTreasure.check(long)) { XCTAssertTrue("\($0)".contains("at most 128")) }
        XCTAssertNoThrow(try CTTreasure.check(lists([7: Array(repeating: Record(tile: 0x0101, contents: 1), count: 128)])))
    }

    func testTheBlockStaysGrowsOrIsRefused() throws {
        let base = lists([0: [Record(tile: 0x2F2F, contents: 0)], 4: [Record(tile: 0x0101, contents: 1), Record(tile: 0x0202, contents: 2)]])
        let rom = syntheticROM(base)
        let at = CTMapROM.pc(CTMapROM.treasureBank + 0xF402)
        var writes: [(String, Int, [UInt8])] = []
        func write(_ b: [UInt8], _ pc: Int, _ what: String) { writes.append((what, pc, b)) }
        var space = FreeSpace()
        XCTAssertNil(try CTTreasure.apply(lists: base, base: rom, keep: [], space: &space, write: write, relocated: { _, _, _, _ in }))
        XCTAssertTrue(writes.isEmpty, "unchanged lists write nothing")

        var removed = base
        removed[4].removeFirst()
        removed[9] = [Record(tile: 0x0303, contents: 3)]           // the same count: in place
        let r = try XCTUnwrap(try CTTreasure.apply(lists: removed, base: rom, keep: [], space: &space, write: write,
                                                   relocated: { _, _, _, _ in }))
        XCTAssertEqual(r.placement, "original")
        XCTAssertEqual(r.pc, at)
        XCTAssertEqual(r.records, 3)
        XCTAssertEqual(r.renumbered, 1, "location 4's second chest is now its first: flag 2 -> 1")
        XCTAssertEqual(r.flagsLeft, 509)
        XCTAssertEqual(writes.map(\.0), ["TreasureRom_LocOfs", "TreasureRom"])

        var grown = base
        grown[4].append(Record(tile: 0x0505, contents: 0x8001))
        space = FreeSpace()
        space.add((at + 12)..<(at + 64), reclaimed: false)
        let g = try XCTUnwrap(try CTTreasure.apply(lists: grown, base: rom, keep: [], space: &space, write: write,
                                                   relocated: { _, _, _, _ in }))
        XCTAssertEqual(g.placement, "grown")
        XCTAssertEqual(g.bytes, 16)
        XCTAssertNil(g.evicted)

        space = FreeSpace()
        XCTAssertThrowsError(try CTTreasure.apply(lists: grown, base: rom, keep: [], space: &space, write: write,
                                                  relocated: { _, _, _, _ in })) {
            XCTAssertTrue("\($0)".contains("bank $F5 has no room"), "\($0)")
        }
    }

    func testChestEditsKeepTheirRules() throws {
        var m = map(26, treasure: [.init(x: 3, y: 3, contents: 0xCA)])
        XCTAssertEqual(CTTreasure.Contents.gold(200).word, 0x8064)
        XCTAssertEqual(CTTreasure.Contents(word: 0x8064), .gold(200))
        XCTAssertEqual(CTTreasure.Contents.empty.word, 0x4000)
        XCTAssertNotNil(CTTreasure.Contents.gold(201).problem)
        XCTAssertNotNil(CTTreasure.Contents.item(0x1F0).problem)
        try CTTreasure.add(&m, x: 4, y: 5, contents: .gold(200), at: 0)
        XCTAssertEqual(m.treasure?.map(\.contents), [0x8064, 0xCA])
        XCTAssertThrowsError(try CTTreasure.add(&m, x: 0, y: 0, contents: .empty)) { XCTAssertTrue("\($0)".contains("tile 0,0")) }
        XCTAssertThrowsError(try CTTreasure.add(&m, x: 3, y: 3, contents: .empty)) { XCTAssertTrue("\($0)".contains("already")) }
        XCTAssertThrowsError(try CTTreasure.add(&m, x: 16, y: 3, contents: .empty)) { XCTAssertTrue("\($0)".contains("off the")) }
        try CTTreasure.move(&m, 1, x: 9, y: 9, contents: .item(5))
        XCTAssertEqual(m.treasure?[1].x, 9)
        XCTAssertEqual(m.treasure?[1].contents, 5)
        try CTTreasure.remove(&m, 0)
        XCTAssertEqual(m.treasure?.count, 1)
        var redirected = map(109, treasure: [.init(x: 1, y: 1, contents: 1)], list: 302)
        XCTAssertThrowsError(try CTTreasure.remove(&redirected, 0)) { XCTAssertTrue("\($0)".contains("edit that map")) }
        var full = map(5, treasure: (0..<128).map { .init(x: $0 % 16, y: 1 + $0 / 16, contents: 1) })
        XCTAssertThrowsError(try CTTreasure.add(&full, x: 15, y: 15, contents: .empty)) { XCTAssertTrue("\($0)".contains("128 chests")) }
    }

    func testProjectFlagsNumberEveryLocation() throws {
        var project = try CTProject.load(from: fixtureURL())
        XCTAssertNil(CTTreasure.projectNumbers(project), "the fixture's maps do not cover the 512 locations")
        for i in 0..<CTMapROM.locCount { project.maps[CTMaps.id(i)] = map(i) }
        project.maps[CTMaps.id(0)]!.treasure = [.init(x: 47, y: 47, contents: 0)]
        project.maps[CTMaps.id(3)]!.treasure = [.init(x: 1, y: 1, contents: 1), .init(x: 2, y: 1, contents: 2)]
        project.maps[CTMaps.id(4)] = map(4, treasure: [.init(x: 1, y: 1, contents: 1), .init(x: 2, y: 1, contents: 2)], list: 3)
        project.maps[CTMaps.id(9)]!.treasure = [.init(x: 5, y: 5, contents: 5)]
        let n = try XCTUnwrap(CTTreasure.projectNumbers(project))
        XCTAssertEqual(n["loc_003"], [1, 2])
        XCTAssertEqual(n["loc_004"], [1, 2], "a redirected map shows its target's flags")
        XCTAssertEqual(n["loc_009"], [4], "after location 4's redirect record (3)")
        var edited = project.maps["loc_003"]!
        edited.treasure!.removeFirst()
        XCTAssertEqual(CTTreasure.projectNumbers(project, replacing: edited)?["loc_009"], [3])
        XCTAssertEqual(CTTreasure.projectTotal(project), 5)
    }

    func testNewLocationsCopyTheirSourceAndAreChecked() throws {
        XCTAssertEqual(CTNewLocation.problems(number: 448, from: 29), [])
        XCTAssertFalse(CTNewLocation.problems(number: 449, from: 29).isEmpty)
        XCTAssertFalse(CTNewLocation.problems(number: 452, from: 448).isEmpty)
        XCTAssertFalse(CTNewLocation.problems(number: 452, from: 505).isEmpty)
        var project = try CTProject.load(from: fixtureURL())
        var source = map(29, treasure: [.init(x: 2, y: 2, contents: 7)])
        source.exits = [.init(x: 5, y: 5, map: "loc_028", toX: 45, toY: 10, span: 0, vertical: false, facing: 0, facingBit7: false)]
        project.maps["loc_029"] = source
        project.maps["loc_028"] = map(28)
        project.maps["loc_448"] = map(448)
        let ids = try CTNewLocation.create(in: &project, from: "loc_029", number: 448,
                                           entrance: .init(map: "loc_028", x: 6, y: 7, toX: 6, toY: 6), list: true)
        XCTAssertEqual(ids, ["loc_448", "loc_028"])
        let m = try XCTUnwrap(project.maps["loc_448"])
        XCTAssertEqual(m.rom?.location, 448)
        XCTAssertEqual(m.rom?.treasureList, 448)
        XCTAssertEqual(m.rom?.createdFrom, 29)
        XCTAssertEqual(m.rom?.record, "$F6:" + String(format: "%04X", (CTMapROM.locRom + CTMapROM.locBytes * 448) & 0xFFFF))
        XCTAssertEqual(m.exits, source.exits)
        XCTAssertEqual(m.treasure, source.treasure)
        XCTAssertEqual(project.maps["loc_028"]?.exits.last?.map, "loc_448")
        XCTAssertEqual(project.project.rom?.maps, ["loc_448", "loc_028"])
        XCTAssertEqual(CTMapPatch.validate(m), [])
        XCTAssertThrowsError(try CTNewLocation.create(in: &project, from: "loc_029", number: 448)) {
            XCTAssertTrue("\($0)".contains("already created"))
        }
        XCTAssertThrowsError(try CTNewLocation.create(in: &project, from: "loc_448", number: 452)) {
            XCTAssertTrue("\($0)".contains("imported from the ROM"))
        }
        XCTAssertThrowsError(try CTNewLocation.create(in: &project, from: "loc_029", number: 452,
                                                      entrance: .init(map: "loc_028", x: 60, y: 0, toX: 0, toY: 0))) {
            XCTAssertTrue("\($0)".contains("off the map"))
        }
    }

    func testValidatorChecksChestsAndNewLocations() throws {
        var project = try CTProject.load(from: fixtureURL())
        project.maps["loc_028"] = map(28)
        project.maps["loc_452"] = map(452)
        project.maps["loc_028"]!.exits = [.init(x: 1, y: 1, map: "loc_452", toX: 0, toY: 0, span: 0, vertical: false,
                                                facing: 0, facingBit7: false)]
        project.maps["loc_109"] = map(109, treasure: [.init(x: 1, y: 1, contents: 1)], list: 302)
        project.maps["loc_302"] = map(302, treasure: [.init(x: 2, y: 2, contents: 1)])
        project.project.rom = .init(maps: ["loc_028", "loc_109"])
        let gate4: [ValidationIssue] = Validator.validate(project).filter { (v: ValidationIssue) -> Bool in v.gate == 4 }
        let messages: [String] = gate4.map(\.description)
        for expected in ["a location the game never loads that this build leaves out", "must match them (edit loc_302)"] {
            XCTAssertTrue(messages.contains { $0.contains(expected) }, "\(expected) not in \(messages)")
        }
    }

    // MARK: Local ROM

    /// Added chests that outgrow TreasureRom's span and a new location 448 from location 29 with an entrance
    /// on 28: the build moves the records into a bank-$F5 MapProps pack's span (the pack moved verbatim),
    /// numbers the flags from the new word 0, and location 448 decodes as location 29 does.
    func testAGrownTreasureRomAndANewLocationBuild() throws {
        guard let data = try? Repo.romData() else { throw XCTSkip("local ROM not present") }
        var rom = [UInt8](data)
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        var project = try CTProject.load(from: fixtureURL())
        _ = try CTMaps.importMaps(rom: rom, into: &project)
        try CTTreasure.add(&project.maps["loc_026"]!, x: 20, y: 20, contents: .gold(200), at: 1)
        try CTTreasure.add(&project.maps["loc_026"]!, x: 21, y: 20, contents: .item(0xA5))
        try CTNewLocation.create(in: &project, from: "loc_029", number: 448,
                                 entrance: .init(map: "loc_028", x: 46, y: 9, toX: 6, toY: 6, facing: 11), list: true)
        try CTTreasure.add(&project.maps["loc_448"]!, x: 7, y: 8, contents: .item(0xC4))
        try CTMapList.set(["loc_026"], listed: true, in: &project)
        let mapIssues: [ValidationIssue] = Validator.validate(project).filter { (v: ValidationIssue) -> Bool in v.gate == 4 && v.path.hasPrefix("maps/") }
        XCTAssertEqual(mapIssues.map(\.description), [String]())
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        let t = try XCTUnwrap(report.treasureRom)
        XCTAssertEqual(t.placement, "moved")
        XCTAssertEqual(t.records, 252)
        XCTAssertEqual(t.evicted?.count, 1)
        let e = try XCTUnwrap(t.evicted?.first)
        let from = CTMapROM.pc(CTMapROM.propsPointer(rom, e.entries[0]))
        XCTAssertEqual(Array(built[e.pc..<(e.pc + e.bytes)]), Array(rom[from..<(from + e.bytes)]), "the pack moved verbatim")
        for entry in e.entries { XCTAssertEqual(CTMapROM.pc(CTMapROM.propsPointer(built, entry)), e.pc) }
        let after = CTTreasure.lists(built), before = CTTreasure.lists(rom)
        XCTAssertEqual(after[26].count, before[26].count + 2)
        XCTAssertEqual(after[448].map(\.contents), [0xC4])
        XCTAssertEqual(CTMapROM.pc(CTMapROM.treasureBank + CTTreasure.start(built)), t.pc)
        let flags = report.maps?.first { $0.id == "loc_448" }?.flags
        XCTAssertEqual(flags, [CTTreasure.numbers(after)[448][0]])
        let d = try CTMapROM.decode(built, 448), s = try CTMapROM.decode(rom, 29)
        XCTAssertTrue(CTMapPatch.sameContent(d.props, s.props))
        XCTAssertNotEqual(d.entry, s.entry, "a free Map_PropsPtrs slot")
        XCTAssertEqual(d.header.tileset12, s.header.tileset12)
        XCTAssertEqual(d.header.events, s.header.events)
        let entrance = try CTMapROM.decode(built, 28).exits.last
        XCTAssertEqual(entrance?.dest, 448)
    }
}
