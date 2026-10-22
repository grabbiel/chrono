// CTEnemiesTests.swift — enemies: the AI script parser and assembler against
// the Python twin's synthetic vectors, the stat/reward/name codecs, the
// project model (old files still load), the checks, the script writer's
// refusals and budget, and with the local ROM: every script round-trips,
// import then build is identical, an edit writes only its fields, refusals,
// and edited scripts go back in place or into bank $CC's padding.
import XCTest
@testable import ChronoForgeCore

final class CTEnemiesTests: XCTestCase {
    private typealias Enemy = CharacterDef.Enemy

    private struct Vectors: Decodable {
        struct Case: Decodable { let bytes: String; let text: String }
        let actLengths: [Int]
        let cases: [Case]
        let rejected: [String]
    }

    private func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = [], chars = Array(hex)
        var i = 0
        while i + 1 < chars.count { out.append(UInt8(String(chars[i...(i + 1)]), radix: 16)!); i += 2 }
        return out
    }

    private func synthetic(id: Int = 7) -> Enemy {
        let stats = [UInt8](0..<UInt8(CTEnemyROM.statsSize)).map { $0 &+ 3 }
        var raw = stats
        raw[0x16] = 2                                           // an attack record that exists
        return CTEnemyROM.decode(stats: raw, reward: [0x34, 0x12, 0x78, 0x56, 0x10, 0x20, 0x09], id: id)
    }

    func testAIVectorsRoundTripAndReject() throws {
        let v = try JSONDecoder().decode(Vectors.self, from: try resourceData("enemies/ai_vectors.json"))
        XCTAssertEqual(v.cases.count, 40)
        for c in v.cases {
            let data = bytes(hex: c.bytes)
            XCTAssertEqual(try CTEnemyAI.text(data, at: 0, lengths: v.actLengths), c.text)
            XCTAssertEqual(try CTEnemyAI.assemble(text: c.text, lengths: v.actLengths), data, c.text)
        }
        for text in v.rejected {
            XCTAssertThrowsError(try CTEnemyAI.assemble(text: text, lengths: v.actLengths), text)
        }
    }

    func testParserRefusesWhatTheGameWouldCut() throws {
        let lengths = try JSONDecoder().decode(Vectors.self, from: try resourceData("enemies/ai_vectors.json")).actLengths
        // an action argument of $FE: the game's byte scan would end the block there
        XCTAssertThrowsError(try CTEnemyAI.parse([0, 0, 0, 0, 0xFE, 0x09, 0xFE, 0xFE, 0xFF, 0xFF], at: 0, lengths: lengths))
        // a test part of three bytes
        XCTAssertThrowsError(try CTEnemyAI.parse([0, 0, 0, 0xFE, 0xFE, 0xFF, 0xFF], at: 0, lengths: lengths))
        let (parts, end) = try CTEnemyAI.parse([0, 0, 0, 0, 0xFE, 0x04, 0x09, 0x00, 0xFE, 0xFF, 0xFF], at: 0, lengths: lengths)
        XCTAssertEqual(end, 11)
        XCTAssertEqual(CTEnemyAI.assemble(parts), [0, 0, 0, 0, 0xFE, 0x04, 0x09, 0x00, 0xFE, 0xFF, 0xFF])
        let text = "main\n  block\n    test $17 Chance percent=$32 b2=$00 b3=$00  ; half the time\n" +
            "    act $09 Leave action=$05\nreaction\nend\n"
        XCTAssertEqual(try CTEnemyAI.assemble(text: text, lengths: lengths), [0x17, 0x32, 0, 0, 0xFE, 0x09, 0x05, 0xFE, 0xFF, 0xFF])
        XCTAssertThrowsError(try CTEnemyAI.assemble(text: text.replacingOccurrences(of: "Leave", with: "Attack"), lengths: lengths))
    }

    func testStatRewardAndNameCodecs() throws {
        let e = synthetic()
        XCTAssertEqual(e.hp, 3 | 4 << 8)
        XCTAssertEqual(e.level, 5)
        XCTAssertEqual(e.status, [6, 7, 8, 9, 10])
        XCTAssertEqual(e.stats.values, Array(11...18))
        XCTAssertEqual(e.affinity.values, Array(19...22))
        XCTAssertEqual([e.immunity, e.flags15, e.attackId], [23, 24, 2])
        XCTAssertEqual(e.reward, .init(exp: 0x1234, gold: 0x5678, drop: 0x10, charm: 0x20, techPoints: 9))
        var raw = [UInt8](0..<UInt8(CTEnemyROM.statsSize)).map { $0 &+ 3 }
        raw[0x16] = 2
        XCTAssertEqual(CTEnemyROM.encode(stats: e), raw)
        XCTAssertEqual(CTEnemyROM.encode(reward: e.reward), [0x34, 0x12, 0x78, 0x56, 0x10, 0x20, 0x09])
        XCTAssertEqual(CTEnemyROM.statBytes(e).map(\.count), CTEnemyROM.statFields.map(\.size))
        XCTAssertEqual(CTEnemyROM.statFields.reduce(0) { $0 + $1.size }, CTEnemyROM.statsSize)
        XCTAssertEqual(CTEnemyROM.rewardFields.reduce(0) { $0 + $1.size }, CTEnemyROM.rewardSize)

        let name = try CTEnemyROM.encodeName("Rat A")
        XCTAssertEqual(name.count, 11)
        XCTAssertEqual(name.last, CTEnemyROM.blank)
        XCTAssertEqual(CTEnemyROM.decodeName(name[...]), "Rat A")
        XCTAssertThrowsError(try CTEnemyROM.encodeName("Twelve chars"))
        XCTAssertEqual(CTEnemyROM.affinityText(4), "x4/4")
        XCTAssertEqual(CTEnemyROM.affinityText(0x84), "absorb x4/4")
        XCTAssertEqual(CTEnemyROM.affinityText(0x48), "x4/6")
        XCTAssertEqual(CTEnemyROM.affinityText(0), "none (0 damage)")
    }

    func testChecks() {
        XCTAssertNoThrow(try CTEnemyROM.check(synthetic(), name: "Rat A"))
        func refuse(_ change: (inout Enemy) -> Void, name: String? = nil, _ text: String, line: UInt = #line) {
            var e = synthetic()
            change(&e)
            XCTAssertThrowsError(try CTEnemyROM.check(e, name: name), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse({ $0.hp = 0x8000 }, "0-32767")
        refuse({ $0.level = 100 }, "not 0-99")
        refuse({ $0.stats.speed = 256 }, "Speed 256")
        refuse({ $0.affinity.fire = -1 }, "fire affinity")
        refuse({ $0.status = [0, 0] }, "5 bytes")
        refuse({ $0.attackId = 23 }, "not 0-22")
        refuse({ $0.reward.drop = 0xF2 }, "below $F2")
        refuse({ $0.reward.exp = 0x10000 }, "0-65535")
        refuse({ $0.enemyId = 255 }, "0-254")
        refuse({ $0.enemyId = 251 }, name: "X", "only ids 0-250")
        refuse({ _ in }, name: "Much too long", "the most is 11")
        refuse({ _ in }, name: "Rat ", "reads back as")
        refuse({ _ in }, name: "{gEF}Rat", "reads back as")
    }

    func testOldProjectFilesStillLoadAndEnemyRecordsRoundTrip() throws {
        let project = try CTProject.load(from: fixtureURL())
        let rat = try XCTUnwrap(project.characters["rat_a"])
        XCTAssertNil(rat.enemy)
        XCTAssertEqual(project.project.rom?.enemies ?? [], [])
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: try CTProject.jsonEncoder.encode(rat)) as? [String: Any]).keys
        XCTAssertFalse(keys.contains("enemy"))
        XCTAssertFalse(String(decoding: try CTProject.jsonEncoder.encode(Project.ROMBuild()), as: UTF8.self).contains("enemies"))

        var edited = project
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctenemies-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        edited.url = dir
        var c = rat
        c.enemy = synthetic()
        c.enemy!.ai = .init(address: "$CC:9000", text: "main\nreaction\nend\n")
        edited.characters["rat_a"] = c
        edited.project.rom = .init(enemies: ["rat_a"])
        try edited.save()
        let loaded = try CTProject.load(from: dir)
        XCTAssertEqual(loaded.characters["rat_a"], c)
        XCTAssertEqual(loaded.project.rom?.enemies, ["rat_a"])
        XCTAssertTrue(Validator.validate(loaded).filter { $0.severity == .error && $0.gate == 4 }.isEmpty)

        var bad = loaded
        bad.characters["rat_a"]!.enemy!.level = 120
        bad.project.rom!.enemies.append("robo")
        let issues = Validator.validate(bad).filter { $0.gate == 4 }.map(\.message)
        XCTAssertTrue(issues.contains { $0.contains("not 0-99") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("no enemy record") }, "\(issues)")
    }

    // MARK: Script write-back (synthetic)

    private let lengths = CTEnemyAIPatch.listedLengths
    private let plain = "main\n  block\n    test $00 Always b1=$00 b2=$00 b3=$00\n" +
        "    act $01 Attack id=$01 target=$03 arg=$00\nreaction\nend\n"

    func testWriterRefusesWhatTheGameCannotStep() throws {
        let bytes = try CTEnemyAIPatch.assemble(text: plain, lengths: lengths)
        XCTAssertEqual(bytes, [0, 0, 0, 0, 0xFE, 0x01, 0x01, 0x03, 0x00, 0xFE, 0xFF, 0xFF])
        func refuse(_ text: String, _ message: String, line: UInt = #line) {
            XCTAssertThrowsError(try CTEnemyAIPatch.assemble(text: text, lengths: lengths), line: line) { error in
                XCTAssertTrue("\(error)".contains(message), "\(error)", line: line)
            }
        }
        refuse(plain.replacingOccurrences(of: "end\n", with: ""), "no end line")
        refuse(plain.replacingOccurrences(of: "test $00 Always b1=$00", with: "test $17 Chance percent=$FF"), "holds $FF")
        refuse(plain.replacingOccurrences(of: "target=$03", with: "target=$39"), "past BattleAi_TargetTable")
        refuse(plain.replacingOccurrences(of: "act $01 Attack id=$01 target=$03 arg=$00", with: "act $03 Nop03"), "no act $03")
        refuse(plain.replacingOccurrences(of: "act $01 Attack id=$01 target=$03 arg=$00", with: "act $05 ChooseRepeat"), "no act $05")
        refuse(plain.replacingOccurrences(of: "act $01 Attack id=$01 target=$03 arg=$00", with: "act $09 Leave action=$FE"), "$FE or $FF")
        refuse(plain.replacingOccurrences(of: "test $00 Always", with: "test $29 Always"), "no test $29")
        XCTAssertEqual(try CTEnemyAIPatch.assemble(text: plain.replacingOccurrences(of: "\n", with: "\r\n"), lengths: lengths), bytes)
        // a comment after end, and end with a comment, still end the script
        XCTAssertEqual(try CTEnemyAIPatch.assemble(text: plain.replacingOccurrences(of: "end\n", with: "end ; done\n"),
                                                   lengths: lengths), bytes)
    }

    func testSharersAndPlan() throws {
        let spans: [Int: Range<Int>] = [1: 10..<20, 2: 15..<30, 3: 30..<40]
        XCTAssertEqual(CTEnemyAIPatch.sharers(spans), [1: [2], 2: [1]])
        let bytes = try CTEnemyAIPatch.assemble(text: plain, lengths: lengths)
        let hash = CTEventPack.sha256(bytes)
        typealias Script = CharacterDef.Enemy.Script
        XCTAssertEqual(CTEnemyAIPatch.plan(Script(address: "$CC:9000", text: plain), bytes: bytes), .unknown)
        XCTAssertEqual(CTEnemyAIPatch.plan(Script(address: "$CC:9000", size: 12, shared: [], sha256: hash), bytes: bytes), .unchanged)
        XCTAssertEqual(CTEnemyAIPatch.plan(Script(address: "$CC:9000", size: 12, shared: [], sha256: "x"), bytes: bytes), .inPlace)
        XCTAssertEqual(CTEnemyAIPatch.plan(Script(address: "$CC:9000", size: 11, shared: [], sha256: "x"), bytes: bytes), .relocated)
        XCTAssertEqual(CTEnemyAIPatch.plan(Script(address: "$CC:9000", size: 40, shared: [4], sha256: "x"), bytes: bytes), .relocated)

        var project = try CTProject.load(from: fixtureURL())
        var c = project.characters["rat_a"]!
        c.enemy = synthetic()
        c.enemy!.ai = Script(address: "$CC:9000", text: plain, size: 8, shared: [], sha256: "x")
        project.characters["rat_a"] = c
        project.project.rom = .init(enemies: ["rat_a"])
        XCTAssertEqual(CTEnemyAIPatch.budget(project).used, 12)
        project.characters["rat_a"]!.enemy!.ai!.text = "main\nend\n"
        XCTAssertEqual(CTEnemyAIPatch.budget(project).broken, ["rat_a"])
        XCTAssertTrue(Validator.validate(project).contains { $0.gate == 4 && $0.message.contains("AI") }, "\(Validator.validate(project))")
        project.characters["rat_a"]!.enemy!.ai!.text = "main\n" + String(repeating: "  block\n    test $00 Always $00 $00 $00\n" +
            "    act $01 Attack id=$01 target=$03 arg=$00\n", count: 100) + "reaction\nend\n"
        XCTAssertGreaterThan(CTEnemyAIPatch.budget(project).used, CTEnemyAIPatch.freeBytes)
        XCTAssertTrue(Validator.validate(project).contains { $0.gate == 4 && $0.message.contains("bank $CC") },
                      "\(Validator.validate(project))")
    }

    // MARK: Local ROM

    private func clean() throws -> [UInt8] { [UInt8](try Repo.romData()) }

    private func importedProject(_ rom: [UInt8]) throws -> CTProject {
        var project = try CTProject.load(from: fixtureURL())
        try CTEnemyROM.importEnemies(rom: rom, into: &project)
        return project
    }

    func testEveryROMScriptRoundTrips() throws {
        let rom = try clean()
        let lengths = CTEnemyROM.actLengths(rom: rom)
        let bank = Array(rom[CTEnemyROM.aiBankPC..<(CTEnemyROM.aiBankPC + 0x10000)])
        var parsed = 0
        for id in 0..<256 {
            let at = Int(rom[CTEnemyROM.aiPointersPC + 2 * id]) | Int(rom[CTEnemyROM.aiPointersPC + 2 * id + 1]) << 8
            guard let (_, end) = try? CTEnemyAI.parse(bank, at: at, lengths: lengths) else { continue }
            let text = try CTEnemyAI.text(bank, at: at, lengths: lengths)
            XCTAssertEqual(try CTEnemyAI.assemble(text: text, lengths: lengths), Array(bank[at..<end]), "enemy \(id)")
            parsed += 1
        }
        XCTAssertEqual(parsed, 255)                             // the Python twin's count (ct_enemies.py check)
    }

    func testImportThenBuildIsIdentical() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        let ids = project.project.rom?.enemies ?? []
        XCTAssertEqual(ids.count, CTEnemyROM.count)
        XCTAssertEqual(ids.first, CTEnemyROM.fileID(0))
        XCTAssertEqual(project.characters[ids[1]]?.kind, "enemy")
        XCTAssertEqual(project.characters["rat_a"]?.enemy, nil)          // the legacy file is left alone
        for id in ids {
            let c = try XCTUnwrap(project.characters[id]), e = try XCTUnwrap(c.enemy)
            XCTAssertNoThrow(try CTEnemyROM.check(e, name: CTEnemyROM.writableName(c)), id)
            XCTAssertEqual(c.level, e.level)
        }
        XCTAssertTrue(Validator.validate(project).filter { $0.severity == .error && $0.gate == 4 }.isEmpty)
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        XCTAssertEqual(built, rom)
        XCTAssertEqual(report.writes, [])
        XCTAssertEqual(report.enemies?.count, CTEnemyROM.count)
        XCTAssertEqual(report.enemies?.first?.address, "$CC:4700")
        XCTAssertNil(report.enemies?.first { $0.name != nil })
    }

    func testEditedEnemyWritesOnlyItsFields() throws {
        let rom = try clean()
        var project = try importedProject(rom)
        let id = CTEnemyROM.fileID(5)
        var c = project.characters[id]!
        c.enemy!.hp = c.enemy!.hp == 1 ? 2 : c.enemy!.hp - 1
        c.enemy!.stats.magic ^= 1
        c.enemy!.reward.gold ^= 0x100
        c.name = "Edited"
        project.characters[id] = c
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        let stats = CTEnemyROM.statsPC(5), reward = CTEnemyROM.rewardPC(5), name = CTEnemyROM.namePC(5)
        let differing = Set((0..<rom.count).filter { rom[$0] != built[$0] })
        let checksum = Set(CTROMLayout.complementPC..<(CTROMLayout.complementPC + 4))
        let allowed = Set([stats, stats + 1, stats + 0x0A, reward + 3]).union(name..<(name + CTEnemyROM.nameSize))
        XCTAssertTrue(differing.subtracting(checksum).isSubset(of: allowed))
        XCTAssertTrue(differing.contains(stats + 0x0A) && differing.contains(reward + 3))
        XCTAssertEqual(report.writes.map(\.what).filter { $0 != "checksum" },
                       ["enemy \(id) hp", "enemy \(id) magic", "enemy \(id) gold", "enemy \(id) name"])
        var expected = c.enemy!
        expected.ai = nil; expected.attack = nil
        let got = CTEnemyROM.decode(stats: Array(built[stats..<(stats + CTEnemyROM.statsSize)]),
                                    reward: Array(built[reward..<(reward + CTEnemyROM.rewardSize)]), id: 5)
        XCTAssertEqual(got, expected)
        XCTAssertEqual(CTEnemyROM.name(rom: built, id: 5), "Edited")
        XCTAssertEqual(CTROMBuilder.checksum(built), report.checksum)
        XCTAssertEqual(report.enemies?.first { $0.id == id }?.name, "Edited")
    }

    func testBuilderEnemyRefusals() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        let a = CTEnemyROM.fileID(1), b = CTEnemyROM.fileID(2)
        func refuse(_ change: (inout CTProject) -> Void, _ text: String, line: UInt = #line) {
            var p = project
            change(&p)
            XCTAssertThrowsError(try CTROMBuilder.build(base: rom, project: p), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse({ $0.characters[a]!.enemy!.hp = 40000 }, "0-32767")
        refuse({ $0.characters[a]!.enemy!.reward.charm = 0xF5 }, "below $F2")
        refuse({ $0.characters[a]!.name = "A name too long" }, "the most is 11")
        refuse({ $0.characters[b]!.enemy!.enemyId = 1 }, "record 1 is built twice")
        refuse({ $0.project.rom!.enemies.append("nobody") }, "no characters/nobody.json")
        refuse({ $0.project.rom!.enemies.append("robo") }, "has no enemy record")
        refuse({ $0.project.rom!.enemies.append(a) }, "built twice")
    }

    func testImportRecordsScriptFactsAndSharedScripts() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        let lengths = CTEnemyROM.actLengths(rom: rom)
        XCTAssertEqual(lengths, CTEnemyAIPatch.listedLengths)
        let spans = CTEnemyAIPatch.spans(rom: rom, lengths: lengths)
        XCTAssertEqual(spans.count, 255)
        XCTAssertNil(spans[127])
        let shared = CTEnemyAIPatch.sharers(spans)
        XCTAssertEqual(shared[98], [97])
        let ai = try XCTUnwrap(project.characters[CTEnemyROM.fileID(98)]?.enemy?.ai)
        XCTAssertEqual(ai.shared, [97])
        XCTAssertEqual(ai.size, spans[98]?.count)
        let budget = CTEnemyAIPatch.budget(project, lengths: lengths)
        XCTAssertEqual(budget.used, 0)
        XCTAssertEqual(budget.unknown, [])
        XCTAssertEqual(budget.broken, [])
    }

    func testEditedScriptsGoInPlaceOrIntoBankCCPadding() throws {
        let rom = try clean()
        var project = try importedProject(rom)
        let lengths = CTEnemyROM.actLengths(rom: rom)
        let spans = CTEnemyAIPatch.spans(rom: rom, lengths: lengths)
        let shared = CTEnemyAIPatch.sharers(spans)
        let fails = "  block\n    test $04 EnemyIdPresent b1=$00 id=$EE absent=$00\n    act $0F Message byte=$02\n"
        let small = "main\n  block\n    test $00 Always b1=$00 b2=$00 b3=$00\n    act $09 Leave action=$01\nreaction\nend\n"
        let smallBytes = try CTEnemyAIPatch.assemble(text: small, lengths: lengths)
        let inPlace = try XCTUnwrap((1..<CTEnemyROM.count).first { id in
            id != 98 && id != 97 && shared[id] == nil && (spans[id]?.count ?? 0) >= smallBytes.count
        })
        project.characters[CTEnemyROM.fileID(inPlace)]!.enemy!.ai!.text = small
        project.characters[CTEnemyROM.fileID(98)]!.enemy!.ai!.text = small
        let grown = "main\n" + String(repeating: fails, count: 40) + "reaction\nend\n"
        project.characters[CTEnemyROM.fileID(5)]!.enemy!.ai!.text = grown
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        let scripts = try XCTUnwrap(report.enemyScripts)
        XCTAssertEqual(scripts.map(\.enemyId).sorted(), [5, 98, inPlace].sorted())
        var placements: [Int: String] = [:]
        for s in scripts { placements[s.enemyId] = s.placement }
        XCTAssertEqual(placements, [inPlace: "original", 98: "free", 5: "free"])
        let bank = Array(built[CTEnemyAIPatch.bankPC..<(CTEnemyAIPatch.bankPC + 0x10000)])
        for s in scripts {
            let at = CTEnemyAIPatch.pointer(built, s.enemyId)
            XCTAssertEqual(CTEnemyAIPatch.bankPC + at, s.pc)
            XCTAssertEqual(try CTEnemyAI.text(bank, at: at, lengths: lengths), s.text)
            if s.placement == "free" {
                XCTAssertTrue((CTEnemyAIPatch.freePC..<CTEnemyAIPatch.freeEnd).contains(s.pc))
            }
        }
        XCTAssertEqual(scripts.first { $0.enemyId == inPlace }?.pc, spans[inPlace]?.lowerBound)
        // Every other script (97 among them) is unchanged byte for byte, and only these bytes differ.
        for (id, span) in spans where ![5, 98, inPlace].contains(id) {
            XCTAssertEqual(CTEnemyAIPatch.pointer(built, id), CTEnemyAIPatch.pointer(rom, id))
            XCTAssertEqual(Array(built[span]), Array(rom[span]), "enemy \(id)")
        }
        XCTAssertEqual(CTEnemyAIPatch.pointer(built, 127), CTEnemyAIPatch.pointer(rom, 127))
        var allowed = Set(CTROMLayout.complementPC..<(CTROMLayout.complementPC + 4))
        for s in scripts { allowed.formUnion(s.pc..<(s.pc + s.bytes)) }
        for id in [5, 98] { allowed.formUnion((CTEnemyROM.aiPointersPC + 2 * id)..<(CTEnemyROM.aiPointersPC + 2 * id + 2)) }
        let differing = Set((0..<rom.count).filter { rom[$0] != built[$0] })
        XCTAssertTrue(differing.isSubset(of: allowed))
        XCTAssertEqual(report.relocations?.count, 2)
    }

    func testBuilderScriptRefusals() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        let a = CTEnemyROM.fileID(1)
        func refuse(_ text: String, _ message: String, line: UInt = #line) {
            var p = project
            p.characters[a]!.enemy!.ai!.text = text
            XCTAssertThrowsError(try CTROMBuilder.build(base: rom, project: p), line: line) { error in
                XCTAssertTrue("\(error)".contains(message), "\(error)", line: line)
            }
        }
        refuse(plain.replacingOccurrences(of: "target=$03", with: "target=$39"), "past BattleAi_TargetTable")
        refuse(plain.replacingOccurrences(of: "end\n", with: ""), "no end line")
        let huge = "main\n" + String(repeating: "  block\n    test $00 Always $00 $00 $00\n    act $01 Attack id=$01 target=$03 arg=$00\n",
                                         count: 100) + "reaction\nend\n"
        refuse(huge, "no room")
        var p = project
        let unparsed = CTEnemyROM.fileID(127)
        XCTAssertNil(p.characters[unparsed]!.enemy!.ai!.text)
        p.characters[unparsed]!.enemy!.ai!.text = plain
        XCTAssertThrowsError(try CTROMBuilder.build(base: rom, project: p)) { error in
            XCTAssertTrue("\(error)".contains("does not lead to a script"), "\(error)")
        }
    }
}
