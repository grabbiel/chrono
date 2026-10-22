// CTCharactersTests.swift — playable-character records: the level curve
// against the Python rule's vectors, the record codec, the project model
// (old files still load), the builder's checks on a synthetic ROM, and with
// the local ROM: import then build is identical, an edit writes only its
// fields, refusals.
import XCTest
@testable import ChronoForgeCore

final class CTCharactersTests: XCTestCase {
    private typealias Record = CharacterDef.Record
    private typealias Growth = CharacterDef.Growth

    private struct Vectors: Decodable {
        struct Case: Decodable {
            let record: String
            let growth: PyGrowth
            let curve: [[Int]]
        }
        struct PyGrowth: Decodable {
            let hp: [[Int]]
            let mp: [[Int]]
            let stats: [String: Int]
        }
        let columns: [String]
        let expToLevel: [Int]
        let cases: [Case]
    }
    private static let pyStats = ["power", "stamina", "speed", "magic", "hit", "evade", "magic_defense"]

    private func growth(_ g: Vectors.PyGrowth) -> Growth {
        func row(_ r: [[Int]]) -> [Growth.Step] { r.map { .init(toLevel: $0[0], gain: $0[1]) } }
        return .init(hp: row(g.hp), mp: row(g.mp), stats: .init(Self.pyStats.map { g.stats[$0]! }))
    }

    private func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = [], chars = Array(hex)
        while chars.count >= 2 { out.append(UInt8(String(chars[0..<2]), radix: 16)!); chars.removeFirst(2) }
        return out
    }

    private func synthetic(level: Int = 5) -> Record {
        .init(charId: 2, level: level, exp: 300, expToNext: 40, hp: 100, maxHp: 120, mp: 9, maxMp: 10,
              stats: .init([10, 11, 12, 13, 14, 15, 16]), growthBase: .init([5, 6, 0, 9, 7, 8, 4]),
              equipment: .init(helmet: 0x7C, armor: 0x5B, weapon: 0x01, accessory: 0x95), techPoints: 7,
              techPointsToNext: 3)
    }

    // MARK: No ROM

    func testCurveMatchesThePythonRuleVectors() throws {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("characters/curve_vectors.json"))
        XCTAssertEqual(v.columns, CTLevelCurve.columns)
        XCTAssertEqual(v.cases.count, 24)
        for (n, c) in v.cases.enumerated() {
            let raw = bytes(hex: c.record)
            XCTAssertEqual(raw.count, CTCharacterROM.recordSize)
            let curve = try CTLevelCurve.curve(CTCharacterROM.decode(record: raw), growth: growth(c.growth),
                                               expToLevel: v.expToLevel)
            XCTAssertEqual(curve.map(CTLevelCurve.row), c.curve, "case \(n)")
        }
    }

    func testRecordCodecWritesOnlyTheDecodedFields() {
        var rng = SystemRandomNumberGenerator()
        let base = (0..<CTCharacterROM.recordSize).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let record = synthetic()
        let raw = CTCharacterROM.encode(record, over: base)
        var decoded = CTCharacterROM.decode(record: raw)
        XCTAssertEqual(decoded.charId, Int(base[0]))
        decoded.charId = record.charId
        XCTAssertEqual(decoded, record)
        let written = Set(CTCharacterROM.writableFields.flatMap { $0.offset..<($0.offset + $0.size) })
        XCTAssertEqual(written.count, 0x50 - 1 - 2 - 14 - 26)          // char id, +$01, +$19-$26, +$36-$4F
        for i in 0..<CTCharacterROM.recordSize where !written.contains(i) { XCTAssertEqual(raw[i], base[i], "+\(i)") }
        XCTAssertEqual(CTCharacterROM.encode(CTCharacterROM.decode(record: raw), over: raw), raw)
        // The growth base is stored in the growth order.
        XCTAssertEqual(Array(raw[0x2F..<0x36]), [5, 6, 0, 7, 8, 9, 4])
        let rows = CTCharacterROM.encodeGrowth(.init(hp: [.init(toLevel: 99, gain: 3)] + Array(repeating: .init(toLevel: 0, gain: 0), count: 3),
                                                     mp: Array(repeating: .init(toLevel: 99, gain: 1), count: 4),
                                                     stats: .init([1, 2, 3, 4, 5, 6, 7])))
        XCTAssertEqual(rows.stats, [1, 2, 3, 5, 6, 4, 7])
        XCTAssertEqual(rows.hp, [99, 3, 0, 0, 0, 0, 0, 0])
    }

    func testLevelUpRule() throws {
        let g = Growth(hp: [.init(toLevel: 10, gain: 12), .init(toLevel: 40, gain: 20), .init(toLevel: 99, gain: 30), .init(toLevel: 0, gain: 0)],
                       mp: [.init(toLevel: 20, gain: 1), .init(toLevel: 99, gain: 2), .init(toLevel: 0, gain: 0), .init(toLevel: 0, gain: 0)],
                       stats: .init([150, 120, 0, 45, 90, 60, 30]))
        let table = [0] + (1..<99).map { 10 * $0 } + [0]
        let v = try CTLevelCurve.levelUp(synthetic(), growth: g, expToLevel: table)
        XCTAssertEqual([v.level, v.exp, v.expToNext, v.maxHp, v.maxMp], [6, 340, 60, 132, 11])
        XCTAssertEqual(v.stats.values, [5 + 7, 6 + 6, 12, 9 + 2, 7 + 4, 8 + 3, 4 + 1])
        // The 8-bit sum wraps, speed is capped at 50, HP and MP at 999 and 99.
        var hi = synthetic(level: 70)
        hi.growthBase = .init([99, 0, 0, 0, 0, 0, 0]); hi.stats = .init([1, 1, 77, 1, 1, 1, 1]); hi.maxHp = 990; hi.maxMp = 90
        let w = try CTLevelCurve.levelUp(hi, growth: .init(hp: Array(repeating: .init(toLevel: 99, gain: 255), count: 4),
                                                           mp: Array(repeating: .init(toLevel: 99, gain: 50), count: 4),
                                                           stats: .init([255, 0, 0, 0, 0, 0, 0])), expToLevel: table)
        XCTAssertEqual([w.stats.power, w.stats.speed, w.maxHp, w.maxMp], [(99 + 255 * 70 / 100) & 0xFF, 50, 999, 99])
        // The experience cap as coded.
        XCTAssertEqual(CTLevelCurve.addExp(0x97FFFF, 1), 0x980000)
        XCTAssertEqual(CTLevelCurve.addExp(0x989600, 0x100), 0x98967F)
        XCTAssertEqual(CTLevelCurve.addExp(0x98967F, 0xFFFF), 0x98967E)
        // A row that does not reach the level, and level 99, are refused.
        var short = g; short.hp = Array(repeating: .init(toLevel: 20, gain: 1), count: 4)
        XCTAssertThrowsError(try CTLevelCurve.levelUp(synthetic(level: 50), growth: short, expToLevel: table))
        XCTAssertThrowsError(try CTLevelCurve.levelUp(synthetic(level: 99), growth: g, expToLevel: table))
        XCTAssertEqual(try CTLevelCurve.curve(synthetic(level: 97), growth: g, expToLevel: table).map(\.level), [97, 98, 99])
        XCTAssertEqual(CTLevelCurve.expAt(level: 4, expToLevel: table).exp, 10 + 20 + 30)
        XCTAssertEqual(CTLevelCurve.expAt(level: 4, expToLevel: table).toNext, 40)
        XCTAssertEqual(Set(CTLevelCurve.offCurve(synthetic(), growth: g).keys), [0, 1, 3, 4, 5, 6])
    }

    func testOldProjectFilesStillLoadAndNewFieldsRoundTrip() throws {
        let project = try CTProject.load(from: fixtureURL())
        let robo = try XCTUnwrap(project.characters["robo"])
        XCTAssertNil(robo.pc)
        XCTAssertNil(project.party)
        XCTAssertEqual(project.project.rom?.characters ?? [], [])
        let legacy = String(decoding: try CTProject.jsonEncoder.encode(robo), as: UTF8.self)
        XCTAssertFalse(legacy.contains("\"pc\"") || legacy.contains("\"growth\""))
        XCTAssertFalse(String(decoding: try CTProject.jsonEncoder.encode(Project.ROMBuild()), as: UTF8.self).contains("characters"))

        var edited = project
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctchars-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        edited.url = dir
        var c = robo
        c.pc = synthetic()
        c.growth = .init(hp: Array(repeating: .init(toLevel: 99, gain: 9), count: 4),
                         mp: Array(repeating: .init(toLevel: 99, gain: 1), count: 4), stats: .init([1, 2, 0, 3, 4, 5, 6]))
        edited.characters["robo"] = c
        edited.party = PartyDef(expToLevel: (0...99).map { $0 }, equipment: [.init(id: 1, name: "Stick", slot: "weapon", equipMask: 0x80)])
        edited.project.rom = .init(characters: ["robo"])
        try edited.save()
        let loaded = try CTProject.load(from: dir)
        XCTAssertEqual(loaded.characters["robo"], c)
        XCTAssertEqual(loaded.party, edited.party)
        XCTAssertEqual(loaded.project.rom?.characters, ["robo"])
    }

    /// A synthetic 4 MiB image with made-up item categories, tables and masks.
    private func syntheticItemROM() -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        let bounds: [UInt8] = [0, 10, 20, 30, 40, 50]
        rom.replaceSubrange(CTCharacterROM.itemBoundsPC..<(CTCharacterROM.itemBoundsPC + 6), with: bounds)
        for c in 0..<4 {
            let table = 0x8000 + 0x100 * c
            rom[CTCharacterROM.itemTablesAPC + 2 * c] = UInt8(table & 0xFF)
            rom[CTCharacterROM.itemTablesAPC + 2 * c + 1] = UInt8(table >> 8)
            rom[CTCharacterROM.itemSizesAPC + c] = 5
            for i in 0..<10 { rom[0x0C0000 + table + 5 * i + 3] = i == 9 ? 0x00 : 0x20 | 0x80 >> (i % 7) }
        }
        return rom
    }

    func testChecksOnASyntheticROM() throws {
        let rom = syntheticItemROM()
        XCTAssertEqual([0, 9, 10, 25, 39, 45].map { CTCharacterROM.category(of: $0, rom: rom) }, [0, 0, 1, 2, 3, 4])
        XCTAssertEqual(CTCharacterROM.equipMask(of: 12, rom: rom), 0x20 | 0x20)
        XCTAssertEqual(CTCharacterROM.equipMask(of: 45, rom: rom), 0)
        // id 2 (bit $20) can equip every item but the last of each category.
        var ok = synthetic()
        ok.equipment = .init(helmet: 21, armor: 11, weapon: 1, accessory: 31)
        let rows = Growth(hp: Array(repeating: .init(toLevel: 99, gain: 9), count: 4),
                          mp: Array(repeating: .init(toLevel: 99, gain: 1), count: 4), stats: .init([1, 2, 0, 3, 4, 5, 6]))
        XCTAssertNoThrow(try CTCharacterROM.check(ok, growth: rows, rom: rom))
        func refuse(_ change: (inout Record, inout Growth) -> Void, _ text: String, line: UInt = #line) {
            var r = ok, g = rows
            change(&r, &g)
            XCTAssertThrowsError(try CTCharacterROM.check(r, growth: g, rom: rom), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse({ r, _ in r.charId = 7 }, "0-6")
        refuse({ r, _ in r.level = 0 }, "not 1-99")
        refuse({ r, _ in r.level = 100 }, "not 1-99")
        refuse({ r, _ in r.exp = 10_000_000 }, "0-9,999,999")
        refuse({ r, _ in r.hp = 121 }, "HP <= max HP")
        refuse({ r, _ in r.maxHp = 1000; r.hp = 1 }, "max HP <= 999")
        refuse({ r, _ in r.maxMp = 100 }, "max MP <= 99")
        refuse({ r, _ in r.stats.speed = 100 }, "speed 100")
        refuse({ r, _ in r.growthBase.hit = 120 }, "growth base hit")
        refuse({ r, _ in r.techPoints = 1 << 24 }, "24 bits")
        refuse({ r, _ in r.equipment.weapon = 12 }, "not a weapon")
        refuse({ r, _ in r.equipment.helmet = 29 }, "not equippable")
        refuse({ r, _ in r.equipment.accessory = 300 }, "not a accessory")
        refuse({ _, g in g.hp = Array(repeating: .init(toLevel: 98, gain: 1), count: 4) }, "must reach level 99")
        refuse({ _, g in g.mp = [.init(toLevel: 99, gain: 1)] }, "4 steps")
        refuse({ _, g in g.stats.magic = 256 }, "0-255")
    }

    // MARK: Local ROM

    private func clean() throws -> [UInt8] { [UInt8](try Repo.romData()) }

    private func importedProject(_ rom: [UInt8]) throws -> CTProject {
        var project = try CTProject.load(from: fixtureURL())
        try CTCharacterROM.importCharacters(rom: rom, into: &project)
        return project
    }

    func testImportThenBuildIsIdentical() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        XCTAssertEqual(project.project.rom?.characters, CTCharacterROM.names)
        XCTAssertEqual(project.characters["robo"]?.pc?.charId, 3)             // the legacy file is updated
        XCTAssertEqual(project.characters["robo"]?.level, project.characters["robo"]?.pc?.level)
        XCTAssertEqual(project.party?.expToLevel.count, 100)
        XCTAssertEqual(Set(project.party?.equipment.map(\.slot) ?? []), Set(CTCharacterROM.slots))
        for id in CTCharacterROM.names {
            let c = try XCTUnwrap(project.characters[id]), r = try XCTUnwrap(c.pc)
            XCTAssertNoThrow(try CTCharacterROM.check(r, growth: c.growth, rom: rom), id)
            XCTAssertEqual(try CTLevelCurve.curve(r, growth: c.growth!, expToLevel: project.party!.expToLevel).last?.level, 99)
        }
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        XCTAssertEqual(built, rom)
        XCTAssertEqual(report.writes, [])
        XCTAssertEqual(report.characters?.map(\.id), CTCharacterROM.names)
        XCTAssertEqual(report.characters?.map(\.address), (0..<7).map { String(format: "$CC:%04X", 0x50 * $0) })
    }

    func testEditedCharacterWritesOnlyItsFields() throws {
        let rom = try clean()
        var project = try importedProject(rom)
        var robo = project.characters["robo"]!
        robo.pc!.stats.power += 1
        robo.pc!.maxHp += 5
        robo.pc!.exp += 0x10000
        robo.growth!.hp[0].gain += 1
        robo.growth!.stats.magic += 1
        project.characters["robo"] = robo
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        let record = CTCharacterROM.recordPC(3)
        let hpRow = CTCharacterROM.hpGrowthPC + 8 * 3, statRow = CTCharacterROM.statGrowthPC + 7 * 3
        let differing = Set((0..<rom.count).filter { rom[$0] != built[$0] })
        let checksum = Set(CTROMLayout.complementPC..<(CTROMLayout.complementPC + 4))
        XCTAssertEqual(differing.subtracting(checksum), [record + 0x0B, record + 0x05, record + 0x15, hpRow + 1, statRow + 5])
        XCTAssertEqual(report.writes.map(\.what).filter { $0 != "checksum" },
                       ["character robo max HP", "character robo power", "character robo exp",
                        "character robo HP growth", "character robo stat growth"])
        XCTAssertEqual(CTCharacterROM.decode(record: Array(built[record..<(record + 0x50)])), robo.pc)
        XCTAssertEqual(CTCharacterROM.decodeGrowth(rom: built, id: 3), robo.growth)
        XCTAssertEqual(CTROMBuilder.checksum(built), report.checksum)
        XCTAssertEqual(report.characters?.first { $0.id == "robo" }?.record, robo.pc)
    }

    func testBuilderCharacterRefusals() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        func refuse(_ change: (inout CTProject) -> Void, _ text: String, line: UInt = #line) {
            var p = project
            change(&p)
            XCTAssertThrowsError(try CTROMBuilder.build(base: rom, project: p), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse({ $0.characters["crono"]!.pc!.level = 0 }, "not 1-99")
        refuse({ $0.characters["crono"]!.pc!.equipment.weapon = project.characters["marle"]!.pc!.equipment.weapon },
               "not equippable by crono")
        refuse({ $0.characters["crono"]!.pc!.equipment.weapon = project.characters["crono"]!.pc!.equipment.armor },
               "is not a weapon")
        refuse({ $0.characters["crono"]!.growth!.hp = Array(repeating: .init(toLevel: 50, gain: 1), count: 4) }, "reach level 99")
        refuse({ $0.characters["crono"]!.pc = project.characters["marle"]!.pc }, "record 1 is built twice")
        refuse({ $0.project.rom!.characters.append("nobody") }, "no characters/nobody.json")
        refuse({ $0.project.rom!.characters.append("rat_a") }, "has no pc record")
        refuse({ $0.project.rom!.characters.append("crono") }, "built twice")
        var modified = rom; modified[0x0C0000 + 0x0B] ^= 1
        XCTAssertThrowsError(try CTROMBuilder.build(base: modified, project: project)) { error in
            XCTAssertTrue("\(error)".contains("unmodified"), "\(error)")
        }
    }
}
