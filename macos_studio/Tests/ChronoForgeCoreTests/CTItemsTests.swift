// CTItemsTests.swift — the item tables: the menu's equipment-stat rule
// against the Python rule's vectors, names, the ROM codec on a synthetic ROM
// (decode, write back), the checks and read-only fields, the project model
// and the Validator, and with the local ROM: import then build is identical,
// edits write only their bytes and read back, refusals.
import XCTest
@testable import ChronoForgeCore

final class CTItemsTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            let statOrder: [Int]
            let statCaps: [Int]
            let boosts: [Int]
            let char5Attack: [Int]
            let sortKeys: [Int]
            let info4: [Int]
            let rows: [Row]
        }
        struct Row: Decodable {
            let record: [UInt8]
            let derived: [Int]
            let word3: Int
        }
        let schema: String
        let cases: [Case]
    }

    // MARK: No ROM

    func testEquipStatsMatchThePythonRuleVectors() throws {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("items/stat_vectors.json"))
        XCTAssertEqual(v.schema, "ct-item-stat-vectors/1")
        XCTAssertEqual(v.cases.count, 6)
        var rows = 0, capped = 0, formulas = Set<Int>()
        for (n, c) in v.cases.enumerated() {
            let tables = CTEquipStats.Tables(sortKeys: c.sortKeys, info4: c.info4, boosts: c.boosts, statOrder: c.statOrder,
                                             statCaps: c.statCaps, char5Attack: c.char5Attack)
            for (k, row) in c.rows.enumerated() {
                let got = try CTEquipStats.compute(record: row.record, tables: tables)
                XCTAssertEqual(got.derived, row.derived, "case \(n) row \(k)")
                XCTAssertEqual(got.hp, row.word3, "case \(n) row \(k)")
                rows += 1
                if got.stats.enumerated().contains(where: { $0.element == c.statCaps[c.statOrder.firstIndex(of: $0.offset)!] }) { capped += 1 }
                formulas.insert(Int(row.record[0]) & 7)
            }
        }
        XCTAssertEqual(rows, 6 * 14)
        XCTAssertGreaterThan(capped, 5)
        XCTAssertTrue(formulas.isSuperset(of: [0, 1, 5]), "\(formulas)")
    }

    func testEquipStatsRefusesTablesTheRuleWouldReadPast() {
        var record = [UInt8](repeating: 0, count: 0x50)
        record[0x2A] = 0x95
        var info4 = [Int](repeating: 0, count: CTItemROM.count)
        info4[0x95] = 23
        let tables = CTEquipStats.Tables(sortKeys: Array(repeating: 0, count: 256), info4: info4,
                                         boosts: Array(repeating: 0, count: 23), statOrder: Array(0..<7),
                                         statCaps: Array(repeating: 99, count: 7), char5Attack: Array(repeating: 0, count: 100))
        XCTAssertThrowsError(try CTEquipStats.compute(record: record, tables: tables))
        XCTAssertThrowsError(try CTEquipStats.compute(record: [0], tables: tables))
    }

    func testNames() throws {
        let bytes = try CTItemROM.encodeName("Ab 9{gF5}")
        XCTAssertEqual(bytes.count, 10)
        XCTAssertEqual(Array(bytes.prefix(5)), [0xA0, 0xBB, 0xFF, 0xDD, 0xF5])
        XCTAssertEqual(Array(bytes.suffix(5)), Array(repeating: 0xEF, count: 5))
        XCTAssertEqual(CTItemROM.decodeName(bytes[...]), "Ab 9{gF5}")
        XCTAssertEqual(CTItemROM.decodeName([0x05, 0xA1][...]), "{g05}B")
        XCTAssertThrowsError(try CTItemROM.encodeName("ABCDEFGHIJK"))     // 11 glyphs
        XCTAssertThrowsError(try CTItemROM.encodeName("é"))
        XCTAssertThrowsError(try CTItemROM.encodeName("{g05}"))           // not a glyph
        XCTAssertEqual(CTItemROM.fileID(0x01, name: "Wood  Sword!"), "01_wood_sword")
        XCTAssertEqual(CTItemROM.fileID(0xF1, name: " "), "f1_none")
    }

    /// A blank image with only the layout tables the codec reads (no ROM data).
    private func syntheticItemROM() -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        let a = [0x06A4, 0x08C0, 0x0986, 0x0A1C, 0x0ABC], b = [0x0262, 0x047E, 0x04E1, 0x052C, 0x05CC]
        for c in 0..<5 {
            rom[CTItemROM.tablesAPC + 2 * c] = UInt8(a[c] & 0xFF); rom[CTItemROM.tablesAPC + 2 * c + 1] = UInt8(a[c] >> 8)
            rom[CTItemROM.tablesBPC + 2 * c] = UInt8(b[c] & 0xFF); rom[CTItemROM.tablesBPC + 2 * c + 1] = UInt8(b[c] >> 8)
            rom[CTItemROM.sizesAPC + c] = UInt8(CTItemROM.sizesA[c]); rom[CTItemROM.sizesBPC + c] = UInt8(CTItemROM.sizesB[c])
        }
        for i in 0..<7 { rom[CTItemROM.statOrderPC + i] = UInt8(6 - i); rom[CTItemROM.statCapsPC + i] = 99 }
        for i in 0..<CTItemROM.count {
            rom[CTItemROM.namesPC + 11 * i + 1] = 0xA0
            for k in 2..<11 { rom[CTItemROM.namesPC + 11 * i + k] = CTItemROM.pad }
        }
        return rom
    }

    private func apply(_ w: [(pc: Int, bytes: [UInt8], what: String)], to base: [UInt8]) -> [UInt8] {
        var rom = base
        for x in w { rom.replaceSubrange(x.pc..<(x.pc + x.bytes.count), with: x.bytes) }
        return rom
    }

    /// Every editable field of one item per category set to a distinct value.
    private func edited(_ items: [ItemDef]) -> [ItemDef] {
        items.map { i in
            var i = i
            let n = i.rom!.itemId, c = CTItemROM.category(of: n)
            i.price = n * 37 & 0xFFFF
            i.name = String(format: "N%02X", n)
            i.rom!.flags = [0x00, 0x14, 0x04, 0x82, 0x1C][c]
            if c < 4 { i.rom!.equip = n & 0xFE }
            if c < 3 { i.rom!.boost = n % 23; i.rom!.elementBonus = n }
            if c == 4 { i.rom!.targetMode = n & 0x3F }
            for (k, f) in CTItemROM.statFields[i.kind]!.enumerated() { i.stats![f] = (n + 3 * k) & 0xFF }
            if c < 3 { i.stats!["modifier"] = n % 57 }
            if c == 1 || c == 2 { i.stats!["modifierOn"] = n & 1 }
            if c == 3 { i.stats!["special"] = 0x40; i.stats!["specialArg"] = n % 23 }
            return i
        }
    }

    func testCodecWritesWhatDecodeReads() throws {
        let base = syntheticItemROM()
        let (items, tables) = try CTItemROM.decode(rom: base, codec: nil)
        XCTAssertEqual(items.count, CTItemROM.count)
        XCTAssertEqual(items.map(\.kind).filter { $0 == "weapon" }.count, 0x5A)
        XCTAssertEqual(tables.statOrder, CharacterDef.StatBlock.names.reversed())
        XCTAssertNil(items[0].description)
        XCTAssertEqual(items[0].rom?.equip, 0); XCTAssertNil(items[0xBC].rom?.equip)
        XCTAssertNotNil(items[0xBC].rom?.targetMode); XCTAssertNil(items[0x95].rom?.boost)

        let changed = edited(items)
        var newTables = tables
        newTables.boosts[5] = .init(stats: ["magicDefense", "power"], amount: 7)   // in stat order, bit 7 down
        XCTAssertNoThrow(try CTItemROM.check(changed, tables: newTables))
        let w = try CTItemROM.writes(changed, tables: newTables, rom: base, codec: nil)
        let built = apply(w, to: base)
        let (back, backTables) = try CTItemROM.decode(rom: built, codec: nil)
        XCTAssertEqual(back.map { var i = $0; i.id = ""; return i }, changed.map { var i = $0; i.id = ""; return i })
        XCTAssertEqual(back.map(\.id)[0x5B], "5b_n5b")
        XCTAssertEqual(backTables, newTables)
        XCTAssertEqual(newTables.word(5), 0x80 >> 6 | 0x80 >> 0 | 7 << 8)
        // One item's edit writes only its bytes.
        var one = items
        one[0x7C].stats!["defence"] = 9
        let diff = zip(base, apply(try CTItemROM.writes(one, tables: nil, rom: base, codec: nil), to: base))
            .enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertEqual(diff, [CTItemROM.recordB(base, 0x7C)])
        XCTAssertThrowsError(try CTItemROM.writes([with(items[1]) { $0.description = "x" }], tables: nil, rom: base, codec: nil))
    }

    private func with(_ i: ItemDef, _ change: (inout ItemDef) -> Void) -> ItemDef { var i = i; change(&i); return i }

    func testChecksRefuseInvalidAndReadOnlyValues() throws {
        let base = try CTItemROM.decode(rom: syntheticItemROM(), codec: nil)
        let items = edited(base.items)
        XCTAssertNoThrow(try CTItemROM.check(items, tables: base.tables))
        func refuse(_ n: Int, _ change: (inout ItemDef) -> Void, _ text: String, line: UInt = #line) {
            var list = items
            change(&list[n])
            XCTAssertThrowsError(try CTItemROM.check(list, tables: nil), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse(1, { $0.kind = "armor" }, "is not its category")
        refuse(1, { $0.rom!.flags = 0x21 }, "bits 0, 5 or 6")
        refuse(1, { $0.price = 0x10000 }, "price")
        refuse(1, { $0.price = nil }, "price none")
        refuse(1, { $0.rom!.equip = 0x81 }, "past 6")
        refuse(0xBD, { $0.rom!.equip = 0x80 }, "on a consumable")
        refuse(1, { $0.rom!.boost = 23 }, "boost 23")
        refuse(0x95, { $0.rom!.boost = 1 }, "for weapons, armour and helmets only")
        refuse(1, { $0.rom!.targetMode = 0 }, "for consumables only")
        refuse(1, { $0.stats!["modifier"] = 57 }, "modifier 57")
        refuse(0x5B, { $0.stats!["modifierOn"] = 2 }, "modifierOn")
        refuse(0x95, { $0.stats!["specialArg"] = 23 }, "specialArg")
        refuse(1, { $0.stats!["extra"] = 0 }, "stats need exactly")
        refuse(1, { $0.stats!["attack"] = 256 }, "bytes")
        refuse(1, { $0.name = "ABCDEFGHIJK" }, "the most is 10")
        refuse(1, { $0.rom!.itemId = 0xF2 }, "0-$F1")
        XCTAssertThrowsError(try CTItemROM.check([items[1], items[1]], tables: nil)) { XCTAssertTrue("\($0)".contains("twice")) }

        func refuseTables(_ change: (inout ItemTablesDef) -> Void, _ text: String, line: UInt = #line) {
            var t = base.tables
            change(&t)
            XCTAssertThrowsError(try CTItemROM.check([], tables: t), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuseTables({ $0.boosts[0].amount = 1 }, "boost 0 is no boost")
        refuseTables({ $0.boosts[3].stats = ["luck"] }, "distinct stat names")
        refuseTables({ $0.boosts[3].stats = ["power", "power"] }, "distinct stat names")
        refuseTables({ $0.boosts[3].amount = 256 }, "not 0-255")
        refuseTables({ $0.boosts.removeLast() }, "23 entries")

        var icon = items
        icon[2].rom!.icon += 1
        XCTAssertThrowsError(try CTItemROM.check(icon, tables: nil, against: base)) { XCTAssertTrue("\($0)".contains("icon")) }
        var order = base.tables
        order.statCaps[0] = 98
        XCTAssertThrowsError(try CTItemROM.check([], tables: order, against: base)) { XCTAssertTrue("\($0)".contains("read-only")) }
        XCTAssertNoThrow(try CTItemROM.check(items, tables: base.tables, against: base))
    }

    func testProjectModelAndValidator() throws {
        var project = try CTProject.load(from: fixtureURL())
        // An older item file (no rom record) still loads and validates.
        XCTAssertNil(project.items["cat_lick"]?.rom)
        XCTAssertNil(project.itemTables)
        XCTAssertFalse(String(decoding: try CTProject.jsonEncoder.encode(Project.ROMBuild()), as: UTF8.self).contains("items"))
        let decoded = try CTProject.jsonDecoder.decode(Project.ROMBuild.self, from: Data(#"{"eventPacks": [], "items": true}"#.utf8))
        XCTAssertTrue(decoded.items)
        XCTAssertFalse(String(decoding: try CTProject.jsonEncoder.encode(project.items["cat_lick"]!), as: UTF8.self).contains("rom"))

        func issues(_ p: CTProject) -> [String] {
            Validator.validate(p).filter { $0.gate == 4 && ($0.path.contains("rom ") || $0.path.contains("item")) }.map(\.description)
        }
        project.project.rom = .init(items: true)
        XCTAssertTrue(issues(project).contains { $0.contains("no ROM items or item_tables.json") })
        let base = try CTItemROM.decode(rom: syntheticItemROM(), codec: nil)
        let items = edited(base.items)
        project.items[items[1].id] = items[1]
        project.items[items[0x5B].id] = items[0x5B]
        project.itemTables = base.tables
        XCTAssertEqual(issues(project), [])
        var dup = items[0x5B]
        dup.id = "copy"
        dup.stats!["modifierOn"] = 3
        project.items["copy"] = dup
        project.itemTables!.boosts[0].amount = 2
        let found = issues(project)
        XCTAssertTrue(found.contains { $0.contains("items/copy.json") && $0.contains("is also items/") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("items/copy.json") && $0.contains("modifierOn") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("item_tables.json") && $0.contains("boost 0") }, "\(found)")

        // item_tables.json and the item records save and load.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctitems-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        project.url = dir
        project.items["copy"] = nil
        project.itemTables = base.tables
        try project.save()
        let loaded = try CTProject.load(from: dir)
        XCTAssertEqual(loaded.itemTables, base.tables)
        XCTAssertEqual(loaded.items[items[1].id], items[1])
        XCTAssertEqual(loaded.project.rom?.items, true)
    }

    // MARK: Local ROM

    private func clean() throws -> [UInt8] { [UInt8](try Repo.romData()) }

    private func importedProject(_ rom: [UInt8]) throws -> CTProject {
        var project = try CTProject.load(from: fixtureURL())
        try CTItemROM.importItems(rom: rom, into: &project)
        return project
    }

    func testImportThenBuildIsIdentical() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        XCTAssertEqual(project.project.rom?.items, true)
        let romItems = project.items.values.filter { $0.rom != nil }
        XCTAssertEqual(romItems.count, CTItemROM.count)
        XCTAssertNotNil(project.items["cat_lick"])                      // project-only items are kept
        XCTAssertTrue(romItems.allSatisfy { $0.description != nil })
        XCTAssertGreaterThan(romItems.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count, 200)
        XCTAssertNoThrow(try CTItemROM.check(Array(romItems), tables: project.itemTables))
        let gate4 = Validator.validate(project).filter { $0.gate == 4 && ($0.path.contains("rom ") || $0.path.contains("item")) }
        XCTAssertEqual(gate4.map(\.description), [])
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        XCTAssertEqual(built, rom)
        XCTAssertEqual(report.writes, [])
        XCTAssertEqual(report.items?.count, CTItemROM.count)
        XCTAssertEqual(report.itemTables, project.itemTables)
    }

    func testEditedItemsWriteOnlyTheirBytesAndReadBack() throws {
        let rom = try clean()
        var project = try importedProject(rom)
        var ids: [Int: String] = [:]
        for i in project.items.values { if let r = i.rom { ids[r.itemId] = i.id } }
        let weapon = ids[0x02]!, armor = ids[0x5C]!, potion = ids[0xBD]!
        project.items[weapon]!.price = (project.items[weapon]!.price! + 1) & 0xFFFF
        project.items[armor]!.stats!["defence"] = (project.items[armor]!.stats!["defence"]! + 1) & 0xFF
        project.items[armor]!.name = "Test Mail"
        project.items[potion]!.description = "A test description."
        project.itemTables!.boosts[1].amount ^= 1
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        let whats = report.writes.map(\.what)
        XCTAssertEqual(whats, ["item $02 record A", "item $5C record B", "item $5C name", "ItemBoosts", "item descriptions", "checksum"])
        let a = CTItemROM.recordA(rom, 0x02), b = CTItemROM.recordB(rom, 0x5C)
        let differing = Set((0..<rom.count).filter { rom[$0] != built[$0] })
        let allowed = Set(a + 1...a + 2).union([b]).union(CTItemROM.namesPC + 11 * 0x5C + 1..<CTItemROM.namesPC + 11 * 0x5D)
            .union(CTItemROM.boostsPC + 3...CTItemROM.boostsPC + 3).union(CTItemROM.descPC..<CTItemROM.descEnd)
            .union(CTROMLayout.complementPC..<CTROMLayout.complementPC + 4)
        XCTAssertTrue(differing.isSubset(of: allowed), "\(differing.subtracting(allowed).sorted().prefix(8))")
        let codec = try CTTextCodec(profile: project.textProfile ?? CTTextProfile.fromROM(Data(rom)))
        let (back, tables) = try CTItemROM.decode(rom: built, codec: codec)
        for i in back { XCTAssertEqual(i.price, project.items[ids[i.rom!.itemId]!]!.price, String(format: "$%02X", i.rom!.itemId)) }
        XCTAssertEqual(back[0x5C].name, "Test Mail")
        XCTAssertEqual(back[0x5C].stats, project.items[armor]!.stats)
        XCTAssertEqual(back[0xBD].description, "A test description.")
        let before = try CTItemROM.decode(rom: rom, codec: codec)
        for n in 0..<CTItemROM.count where n != 0xBD { XCTAssertEqual(back[n].description, before.items[n].description) }
        XCTAssertEqual(tables, project.itemTables)
        XCTAssertEqual(CTROMBuilder.checksum(built), report.checksum)
    }

    func testBuilderItemRefusals() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        let first = project.items.values.first { $0.rom?.itemId == 0x01 }!.id
        func refuse(_ change: (inout CTProject) -> Void, _ text: String, line: UInt = #line) {
            var p = project
            change(&p)
            XCTAssertThrowsError(try CTROMBuilder.build(base: rom, project: p), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse({ $0.items[first]!.rom!.icon ^= 1 }, "read-only")
        refuse({ $0.itemTables!.char5Attack[0] += 1 }, "read-only")
        refuse({ $0.items[first]!.stats!["attack"] = 300 }, "bytes")
        refuse({ $0.items[first]!.description = String(repeating: "Wide words. ", count: 400) }, "descriptions take")
        refuse({ $0.items = $0.items.filter { $0.value.rom == nil }; $0.itemTables = nil }, "needs ROM items")
    }

    /// The equipment twin on the ROM's own tables: the defence and attack it
    /// computes follow the decoded sort keys (no ROM bytes asserted).
    func testEquipStatsOnTheImportedTables() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        let tables = CTEquipStats.tables(items: Array(project.items.values), tables: project.itemTables!)
        XCTAssertEqual(tables.boosts.count, CTItemROM.boostCount)
        var rec = [UInt8](repeating: 0, count: 0x50)
        rec[0x0B] = 10; rec[0x0C] = 10
        rec[0x27] = 0x7C; rec[0x28] = 0x5C; rec[0x29] = 0x02; rec[0x2A] = 0xBC   // no accessory boost in id $BC
        let r = try CTEquipStats.compute(record: rec, tables: tables)
        XCTAssertEqual(r.defence, min(10 + tables.sortKeys[0x7C] + tables.sortKeys[0x5C], 0xFF))
        XCTAssertEqual(r.attack, min((5 * tables.sortKeys[0x02] + 12 * r.stats[0]) / 9, 0xFF))
    }
}
