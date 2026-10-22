// CTTechsTests.swift — the tech system: the tech-point rule against the
// Python rule's vectors, the ROM codec on a synthetic ROM (decode, write back,
// one edit writes only its bytes), the checks and read-only fields, the
// project model and the Validator, and with the local ROM: import then build
// is identical, an edit writes only its bytes, refusals.
import XCTest
@testable import ChronoForgeCore

final class CTTechsTests: XCTestCase {
    private struct Vectors: Decodable {
        struct Case: Decodable {
            let charTechs: [[Int]]
            let tpCost: [[Int]]
            let tpAfter: Int
            let needsUnlock: [Int]
            let combos: [TechSystemDef.Combo]
            let state: CTTechPoints.State
            let steps: [Step]
        }
        struct Step: Decodable {
            let award: Int
            let state: CTTechPoints.State
        }
        let schema: String
        let cases: [Case]
    }

    // MARK: No ROM

    func testTechPointsMatchThePythonRuleVectors() throws {
        let v = try JSONDecoder().decode(Vectors.self, from: resourceData("techs/tp_vectors.json"))
        XCTAssertEqual(v.schema, "ct-tech-point-vectors/1")
        XCTAssertEqual(v.cases.count, 12)
        var learned = 0, combos = 0
        for (n, c) in v.cases.enumerated() {
            let unlock = Set(c.needsUnlock)
            let tables = CTTechPoints.Tables(charTechs: c.charTechs, tp: Array(c.tpCost.joined()) + [c.tpAfter],
                                             needsUnlock: (0..<CTTechROM.count).map { unlock.contains($0) }, combos: c.combos)
            var state = c.state
            for (k, step) in c.steps.enumerated() {
                let next = try CTTechPoints.award(state, tables: tables, award: step.award)
                XCTAssertEqual(next, step.state, "case \(n) step \(k)")
                learned += next.counts.reduce(0, +) - state.counts.reduce(0, +)
                combos += zip(next.comboBits, state.comboBits).map { ($0 ^ $1).nonzeroBitCount }.reduce(0, +)
                state = step.state
            }
        }
        XCTAssertGreaterThan(learned, 50)
        XCTAssertGreaterThan(combos, 10)
    }

    func testTechPointRuleQuirks() throws {
        // One character, singles costing 5 then 90: an award of 7 pays the 5,
        // then (the quirk) the award again against the new need 90 - 2.
        let combos = [TechSystemDef.Combo(mask: 0xC0, first: 0x39, requirements: [[1, 1, 255], [2, 1, 255], [3, 3, 255]])]
        var tp = [Int](repeating: 100, count: 57)
        tp[0] = 5; tp[1] = 90
        let t = CTTechPoints.Tables(charTechs: (0..<7).map { [1 + 8 * $0, 8] }, tp: tp,
                                    needsUnlock: [Bool](repeating: false, count: CTTechROM.count), combos: combos)
        let slot = CTTechPoints.Slot(char: 0, flags: 0x80, tp: 0, toNext: 5)
        let start = CTTechPoints.State(counts: [0, 1, 0, 0, 0, 0, 0], bits1: [0, 0x80, 0, 0, 0, 0, 0],
                                       comboBits: [Int](repeating: 0, count: 30), unlock: 0,
                                       slots: [slot, CTTechPoints.Slot(char: 1, flags: 0, tp: 0, toNext: 1000), nil])
        let s = try CTTechPoints.award(start, tables: t, award: 7)
        XCTAssertEqual(s.counts[0], 1)
        XCTAssertEqual(s.slots[0]?.toNext, 90 - 2 - 7)
        XCTAssertEqual(s.slots[0]?.tp, 7)
        XCTAssertEqual(s.comboBits[0], 0x80)             // crono 1 and marle 1 meet the first double
        // The total's cap, and a full character is skipped (no total added).
        var capped = start
        capped.slots[0]!.tp = 0x989600
        XCTAssertEqual(try CTTechPoints.award(capped, tables: t, award: 0x100).slots[0]?.tp, CTTechPoints.totalCap)
        var full = start
        full.slots[0]!.flags |= CTTechROM.allTechsBit
        XCTAssertEqual(try CTTechPoints.award(full, tables: t, award: 50).slots[0], full.slots[0])
        // A single that needs the unlock stops the payments until the bit is set.
        var locked = t
        locked.needsUnlock[2] = true
        var two = start
        two.counts[0] = 1; two.bits1[0] = 0x80; two.slots[0]!.toNext = 0
        XCTAssertEqual(try CTTechPoints.award(two, tables: locked, award: 500).counts[0], 1)
        two.unlock = 1
        XCTAssertGreaterThan(try CTTechPoints.award(two, tables: locked, award: 500).counts[0], 1)
        XCTAssertEqual(CTTechPoints.comboMasks([0, nil, 2]), [0x20, 0x80, 0xA0, 0xA0])
        XCTAssertThrowsError(try CTTechPoints.award(start, tables: t, award: 0x10000))
    }

    /// A deterministic generator (no ROM data).
    private struct Gen {
        var x: UInt64
        mutating func next(_ n: Int) -> Int {
            x = x &* 6364136223846793005 &+ 1442695040888963407
            return Int(x >> 33) % n
        }
    }

    /// A 4 MiB image with made-up tech tables in the ROM's places and valid ranges.
    private func syntheticTechROM() -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        var g = Gen(x: 0x7EC4)
        func put(_ at: Int, _ bytes: [Int]) { for (i, b) in bytes.enumerated() { rom[at + i] = UInt8(b) } }
        for t in 0..<CTTechROM.count {
            put(CTTechROM.infoPC + 2 * t, [g.next(0x21) | (g.next(4) == 0 ? 0x80 : 0), g.next(12)])
            put(CTTechROM.recPC + 11 * t, [g.next(52) | (g.next(3) == 0 ? 0x80 : 0), g.next(256), g.next(256),
                                           (g.next(5) == 0 ? 0 : 0x80 >> g.next(4)) | g.next(16), g.next(256)]
                + (0..<3).map { _ in g.next(72) | (g.next(3) == 0 ? 0x80 : 0) } + (0..<3).map { _ in g.next(57) })
            put(CTTechROM.actPC + 7 * t, [g.next(128), g.next(256), g.next(256), g.next(80), g.next(256), g.next(256), g.next(256)])
        }
        for p in 0..<CTTechROM.partCount {
            put(CTTechROM.mpCostPC + p, [g.next(100)])
            put(CTTechROM.effectsPC + 12 * p, [g.next(45)] + (0..<11).map { _ in g.next(256) })
        }
        for i in 0..<56 { put(CTTechROM.tpCostPC + 2 * i, [g.next(256), g.next(256)]) }
        for s in 0..<CTTechROM.userSetCount { put(CTTechROM.userSetsPC + 3 * s, [g.next(7), g.next(7), 0xFF]) }
        let pairs = (0..<7).flatMap { a in ((a + 1)..<7).map { [a, $0] } }
        let trios = (0..<7).flatMap { a in ((a + 1)..<7).flatMap { b in ((b + 1)..<7).map { [a, b, $0] } } }
        var req = 0x27FA, rec = CTTechROM.combosPC
        for (i, who) in (Array(pairs.prefix(15)) + Array(trios.prefix(10))).enumerated() {
            let count = i < 15 ? 3 : 1, first = i < 15 ? 0x39 + 3 * i : 0x66 + i - 15
            put(rec, [who.reduce(0) { $0 | 0x80 >> $1 }, first, count, req & 0xFF, req >> 8])
            for _ in 0..<count {
                put(0x0C0000 + req, (0..<3).map { $0 < who.count ? 1 + g.next(8) : 0xFF })
                req += 3
            }
            rec += 5
        }
        rom[rec] = 0xFF
        for a in 1..<CTTechROM.areaCount {
            let at = 0x2B14 + 4 * (a - 1)
            put(CTTechROM.areaPtrsPC + 2 * a, [at & 0xFF, at >> 8])
            put(0x0C0000 + at, [1, g.next(7), g.next(7), g.next(256)])
        }
        let counts = (0..<7).map { _ in g.next(9) }
        put(CTTechROM.statePC, counts + counts.map(CTTechROM.topBits)
            + (0..<30).map { i in i < 15 ? (g.next(8) << 5) : g.next(2) << 7 })
        return rom
    }

    private func apply(_ system: TechSystemDef, to base: [UInt8]) -> [UInt8] {
        var rom = base
        for w in CTTechROM.writes(system, rom: base) { rom.replaceSubrange(w.pc..<(w.pc + w.bytes.count), with: w.bytes) }
        return rom
    }

    func testCodecRoundTripsAndAnEditWritesOnlyItsBytes() throws {
        let rom = syntheticTechROM()
        let system = try CTTechROM.decode(rom: rom, codec: nil)
        XCTAssertEqual(system.techs.count, 0x75)
        XCTAssertEqual(system.combos.count, 25)
        XCTAssertEqual(system.areas.count, 12)
        XCTAssertNoThrow(try CTTechROM.check(system))
        XCTAssertNoThrow(try CTTechROM.check(system, against: system))
        // The record +$02 bit 4 follows the counts (8 = all learned); the rest is the base.
        var expectFlags = rom
        for c in 0..<7 where system.learned.counts[c] == 8 { expectFlags[CTCharacterROM.recordPC(c) + 2] |= 0x10 }
        XCTAssertEqual(apply(system, to: rom), expectFlags)

        var edited = system
        edited.techs[5].targetMode = (system.techs[5].targetMode + 1) % 0x21
        edited.techs[5].element = system.techs[5].element == "fire" ? "water" : "fire"
        edited.techs[5].parts[1] = (system.techs[5].parts[1] + 1) % 72
        edited.techs[9].needsUnlock.toggle()
        edited.techs[9].anim.script = (system.techs[9].anim.script + 1) % 128
        edited.parts[3].effect.power = (system.parts[3].effect.power + 1) % 256
        edited.parts[4].mp = (system.parts[4].mp + 1) % 100
        edited.tpCost[2][4] = (system.tpCost[2][4] + 0x101) % 0x10000
        edited.combos[0].requirements[1][0] = system.combos[0].requirements[1][0] % 8 + 1
        edited.learned.counts[1] = 8
        edited.learned.bits1[1] = 0xFF
        let built = apply(edited, to: expectFlags)
        let changed = Set((0..<rom.count).filter { built[$0] != expectFlags[$0] })
        let rec5 = CTTechROM.recPC + 55, rec9 = CTTechROM.recPC + 99
        var expect: Set<Int> = [CTTechROM.infoPC + 10, rec5 + 3, rec5 + 6, rec9, CTTechROM.actPC + 63,
                                CTTechROM.effectsPC + 36 + 9, CTTechROM.mpCostPC + 4,
                                CTTechROM.tpCostPC + 2 * (8 * 2 + 4), CTTechROM.tpCostPC + 2 * (8 * 2 + 4) + 1,
                                0x0C27FA + 3]
        if system.learned.counts[1] != 8 {
            expect.formUnion([CTTechROM.statePC + 1, CTTechROM.statePC + 8, CTCharacterROM.recordPC(1) + 2])
        }
        XCTAssertEqual(changed, expect)
        var decoded = try CTTechROM.decode(rom: built, codec: nil)
        XCTAssertEqual(decoded, edited)
        // Read-only bits stay the base's.
        XCTAssertEqual(built[rec5 + 3] & 0x0F, rom[rec5 + 3] & 0x0F)
        XCTAssertEqual(built[rec9] & 0x7F, rom[rec9] & 0x7F)
        decoded.learned.counts[1] = 7
        XCTAssertThrowsError(try CTTechROM.check(decoded))          // bits1 no longer the count's top bits
    }

    func testChecksRefuseInvalidAndReadOnlyValues() throws {
        let system = try CTTechROM.decode(rom: syntheticTechROM(), codec: nil)
        func refuse(_ change: (inout TechSystemDef) -> Void, _ text: String, line: UInt = #line) {
            var s = system
            change(&s)
            XCTAssertThrowsError(try { try CTTechROM.check(s); try CTTechROM.check(s, against: system) }(), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse({ $0.schema = "ct-techs/2" }, "schema")
        refuse({ $0.techs.removeLast() }, "techs 0-$74")
        refuse({ $0.techs[3].targetMode = 0x21 }, "target mode")
        refuse({ $0.techs[3].area = 12 }, "area 12")
        refuse({ $0.techs[3].element = "earth" }, "element earth")
        refuse({ $0.techs[3].parts[0] = 72 }, "below 72")
        refuse({ $0.techs[3].parts[2] = 0x80 | 72 }, "below 72")
        refuse({ $0.techs[3].modifiers[1] = 57 }, "below 57")
        refuse({ $0.techs[3].anim.script = 128 }, "script 128")
        refuse({ $0.techs[3].anim.frames = 80 }, "frames 80")
        refuse({ $0.parts[2].mp = 100 }, "MP 100")
        refuse({ $0.parts[2].effect.type = 45 }, "effect type 45")
        refuse({ $0.parts[2].effect.power = 256 }, "0-255")
        refuse({ $0.tpCost[6][7] = 0x10000 }, "0-65535")
        refuse({ $0.tpCost[6].removeLast() }, "7 rows of 8")
        refuse({ $0.combos[0].requirements[0][0] = 9 }, "1-8 per member")
        refuse({ $0.combos[0].requirements[0][2] = 1 }, "255 for a pair's third")
        refuse({ $0.combos[20].requirements[0][2] = 0 }, "1-8 per member")
        refuse({ $0.learned.counts[0] = 9; $0.learned.bits1[0] = 0xFF }, "0-8")
        refuse({ $0.learned.bits1[2] ^= 0x01 }, "top bits")
        refuse({ $0.learned.comboBits[0] |= 0x10 }, "past its techs")
        refuse({ $0.learned.comboBits[20] |= 0x40 }, "past its techs")
        refuse({ $0.techs[7].userSet = ($0.techs[7].userSet + 1) % 52 }, "read-only")
        refuse({ $0.techs[7].flags ^= 1 }, "read-only")
        refuse({ $0.techs[7].attr ^= 1 }, "read-only")
        refuse({ $0.techs[7].anim.gfxA ^= 1 }, "script and frames")
        refuse({ $0.combos[2].mask ^= 0x01 }, "read-only")
        refuse({ $0.combos[2].requirements.removeLast(); $0.learned.comboBits[2] &= 0xC0 }, "read-only")
        refuse({ $0.userSets[0][0] = ($0.userSets[0][0] + 1) % 7 }, "user sets are read-only")
        refuse({ $0.areas[1][0].size ^= 1 }, "areas are read-only")
        var renamed = system
        renamed.techs[1].name = "Renamed"
        XCTAssertNoThrow(try CTTechROM.check(renamed, against: system))      // names are never written
    }

    func testProjectModelAndValidator() throws {
        var project = try CTProject.load(from: fixtureURL())
        XCTAssertNil(project.techSystem)
        XCTAssertFalse(project.project.rom?.techs ?? false)
        XCTAssertFalse(String(decoding: try CTProject.jsonEncoder.encode(Project.ROMBuild()), as: UTF8.self).contains("techs"))
        let decoded = try CTProject.jsonDecoder.decode(Project.ROMBuild.self, from: Data(#"{"eventPacks": [], "techs": true}"#.utf8))
        XCTAssertTrue(decoded.techs)

        func issues(_ p: CTProject) -> [String] {
            Validator.validate(p).filter { $0.gate == 4 && ($0.path.contains("rom ") || $0.path.contains("tech") || $0.path.hasPrefix("characters/")) }
                .map(\.description)
        }
        // goal: rom.characters must name files with a pc record, once each, in range
        project.project.rom = .init(characters: ["robo", "nobody", "robo"])
        var found = issues(project)
        XCTAssertTrue(found.contains { $0.contains("rom character robo") && $0.contains("no pc record") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("nobody") && $0.contains("no characters/nobody.json") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("character built twice") }, "\(found)")
        var robo = project.characters["robo"]!
        robo.pc = .init(charId: 3, level: 0, exp: 0, expToNext: 0, hp: 1, maxHp: 1, mp: 0, maxMp: 0,
                        stats: .init([1, 1, 1, 1, 1, 1, 1]), growthBase: .init([1, 1, 0, 1, 1, 1, 1]),
                        equipment: .init(helmet: 3, armor: 2, weapon: 1, accessory: 4), techPoints: 0, techPointsToNext: 7)
        project.characters["robo"] = robo
        project.party = PartyDef(expToLevel: (0...99).map { $0 }, equipment: [
            .init(id: 1, name: "W", slot: "weapon", equipMask: 0x10), .init(id: 2, name: "A", slot: "armor", equipMask: 0x10),
            .init(id: 3, name: "H", slot: "helmet", equipMask: 0x10), .init(id: 4, name: "X", slot: "accessory", equipMask: 0x10)])
        project.project.rom = .init(characters: ["robo"], techs: true)
        found = issues(project)
        XCTAssertTrue(found.contains { $0.contains("characters/robo.json") && $0.contains("not 1-99") }, "\(found)")
        XCTAssertTrue(found.contains { $0.contains("no tech_system.json") }, "\(found)")
        project.characters["robo"]!.pc!.level = 1
        var system = try CTTechROM.decode(rom: syntheticTechROM(), codec: nil)
        system.learned.counts[3] = 2
        system.learned.bits1[3] = 0xC0
        system.tpCost[3][2] = 9
        project.techSystem = system
        found = issues(project)
        XCTAssertTrue(found.contains { $0.contains("[warning]") && $0.contains("is not the cost of single 3 (9)") }, "\(found)")
        XCTAssertFalse(found.contains { $0.contains("[error]") }, "\(found)")
        project.techSystem!.techs[2].area = 40
        XCTAssertTrue(issues(project).contains { $0.contains("tech_system.json") && $0.contains("area 40") })

        // tech_system.json saves and loads.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cttechs-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        project.url = dir
        project.techSystem = system
        try project.save()
        let loaded = try CTProject.load(from: dir)
        XCTAssertEqual(loaded.techSystem, system)
        XCTAssertEqual(loaded.project.rom?.techs, true)
    }

    // MARK: Local ROM

    private func clean() throws -> [UInt8] { [UInt8](try Repo.romData()) }

    private func importedProject(_ rom: [UInt8]) throws -> CTProject {
        var project = try CTProject.load(from: fixtureURL())
        try CTCharacterROM.importCharacters(rom: rom, into: &project)
        try CTTechROM.importTechs(rom: rom, into: &project)
        return project
    }

    func testImportThenBuildIsIdentical() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        let system = try XCTUnwrap(project.techSystem)
        XCTAssertEqual(project.project.rom?.techs, true)
        XCTAssertEqual(system.techs.count, CTTechROM.count)
        XCTAssertTrue(system.techs.dropFirst().allSatisfy { !$0.name.isEmpty })
        XCTAssertNoThrow(try CTTechROM.check(system))
        for c in 0..<7 {
            XCTAssertEqual(Set((0..<8).flatMap { system.users(of: 1 + 8 * c + $0) }), [c])
        }
        for (i, combo) in system.combos.enumerated() {
            for k in 0..<combo.requirements.count {
                XCTAssertEqual(system.users(of: combo.first + k).sorted(), combo.members, "record \(i)")
            }
        }
        let gate4 = Validator.validate(project).filter { $0.gate == 4 && ($0.path.contains("rom ") || $0.path.contains("tech")) }
        XCTAssertEqual(gate4.map(\.description), [])
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        XCTAssertEqual(built, rom)
        XCTAssertEqual(report.writes, [])
        XCTAssertEqual(report.techs, system)
    }

    func testEditedTechWritesOnlyItsBytes() throws {
        let rom = try clean()
        var project = try importedProject(rom)
        project.project.rom = .init(techs: true)
        var s = project.techSystem!
        let tech = 3, part = s.techs[tech].parts[0] & 0x7F
        s.techs[tech].targetMode = s.techs[tech].targetMode == 7 ? 8 : 7
        s.parts[part].effect.power = (s.parts[part].effect.power + 1) % 256
        s.tpCost[0][1] += 1
        s.combos[0].requirements[0][1] = s.combos[0].requirements[0][1] % 8 + 1
        project.techSystem = s
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        let differing = Set((0..<rom.count).filter { rom[$0] != built[$0] })
        let checksum = Set(CTROMLayout.complementPC..<(CTROMLayout.complementPC + 4))
        let req = 0x0C0000 + Int(rom[CTTechROM.combosPC + 3]) | Int(rom[CTTechROM.combosPC + 4]) << 8
        let tp = CTTechROM.tpCostPC + 2
        let tpBytes: Set<Int> = Set([tp, tp + 1].filter { rom[$0] != built[$0] })
        XCTAssertEqual(differing.subtracting(checksum),
                       Set([CTTechROM.infoPC + 2 * tech, CTTechROM.effectsPC + 12 * part + 9, req + 1]).union(tpBytes))
        XCTAssertEqual(report.writes.map(\.what).filter { $0 != "checksum" },
                       [String(format: "tech $%02X target", tech), "part \(part) effect", "TechTpCost", "combination $39 requirements"])
        let codec = try CTTextCodec(profile: project.textProfile ?? CTTextProfile.fromROM(Data(rom)))
        XCTAssertEqual(try CTTechROM.decode(rom: built, codec: codec), s)
        XCTAssertEqual(CTROMBuilder.checksum(built), report.checksum)
    }

    func testBuilderTechRefusals() throws {
        let rom = try clean()
        let project = try importedProject(rom)
        func refuse(_ change: (inout CTProject) -> Void, _ text: String, line: UInt = #line) {
            var p = project
            change(&p)
            XCTAssertThrowsError(try CTROMBuilder.build(base: rom, project: p), line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", line: line)
            }
        }
        refuse({ $0.techSystem!.techs[1].targetMode = 0x21 }, "target mode")
        refuse({ $0.techSystem!.techs[1].userSet += 1 }, "read-only")
        refuse({ $0.techSystem!.combos[0].mask ^= 0x01 }, "read-only")
        refuse({ $0.techSystem!.learned.counts[0] += 1 }, "top bits")
        refuse({ $0.techSystem = nil }, "needs tech_system.json")
    }

    /// The area routines' tests (CTTechTargets) on hand-placed battlers.
    func testTargetZones() throws {
        typealias P = CTTechTargets.Point
        XCTAssertEqual(CTTechTargets.modes.count, CTTechROM.targetModes)
        XCTAssertEqual(CTTechTargets.shapes.count, 7)
        XCTAssertEqual(CTTechTargets.params.count, 7)
        var at: [P?] = Array(repeating: nil, count: 11)
        at[0] = P(x: 128, y: 200); at[1] = P(x: 40, y: 200); at[2] = P(x: 216, y: 200)
        at[3] = P(x: 128, y: 100)                       // the centre
        at[4] = P(x: 176, y: 100)                       // 3 cells right: 9 <= 9
        at[5] = P(x: 192, y: 100)                       // 4 cells: 16 > 9
        at[6] = P(x: 128, y: 132)                       // 2 cells down; the row's edge (+$20)
        at[7] = P(x: 128, y: 133)                       // past the row
        // Circle: in cells, inclusive, the centre first.
        XCTAssertEqual(CTTechTargets.hits(.init(.circle(centre: 3, size: 9)), positions: at), [3, 4, 6, 7])
        XCTAssertEqual(CTTechTargets.hits(.init(.circle(centre: 3, size: 4)), positions: at), [3, 6, 7])
        // The 8-bit sum wraps: 15 cells across and 7 down is $112 -> $12.
        var far = at
        far[8] = P(x: 128 + 15 * 16, y: 100 + 7 * 16)
        XCTAssertTrue(CTTechTargets.hits(.init(.circle(centre: 3, size: 0x19)), positions: far).contains(8))
        XCTAssertFalse(CTTechTargets.hits(.init(.circle(centre: 3, size: 0x11)), positions: far).contains(8))
        // Row: y within ±$20 of the centre's, inclusive.
        XCTAssertEqual(CTTechTargets.hits(.init(.row(centre: 3)), positions: at), [3, 4, 5, 6])
        // The party's triangle takes in enemies only.
        var tri: [P?] = Array(repeating: nil, count: 11)
        tri[0] = P(x: 20, y: 200); tri[1] = P(x: 128, y: 20); tri[2] = P(x: 236, y: 200)
        tri[3] = P(x: 128, y: 150); tri[4] = P(x: 20, y: 20)
        XCTAssertEqual(CTTechTargets.hits(.init(.partyTriangle), positions: tri), [3])
        // Line: a strip from the source past the aim, or a box ending at it.
        var line: [P?] = Array(repeating: nil, count: 11)
        line[0] = P(x: 20, y: 100)
        line[3] = P(x: 120, y: 100)                     // the aim
        line[4] = P(x: 200, y: 110)                     // beyond, 10 px off the line
        line[5] = P(x: 80, y: 130)                      // 30 px off
        line[6] = P(x: 10, y: 100)                      // behind the source
        XCTAssertEqual(CTTechTargets.hits(.init(.line(source: 0, aim: 3, size: 2, box: false)), positions: line), [3, 4])
        XCTAssertEqual(CTTechTargets.hits(.init(.line(source: 0, aim: 3, size: 2, box: true)), positions: line), [3])
        XCTAssertEqual(CTTechTargets.hits(.init(.line(source: 0, aim: 3, size: 4, box: true)), positions: line), [3, 5])
        // Menu modes: their handlers' zones and lists.
        let party: [Int?] = [0, 3, 6]
        XCTAssertEqual(CTTechTargets.menu(0x0B, caster: 0, target: 5, party: party).zone,
                       .init(.line(source: 0, aim: 5, size: 2, box: false)))
        XCTAssertEqual(CTTechTargets.menu(0x0D, caster: 0, target: 5, party: party).zone,
                       .init(.line(source: 1, aim: 5, size: 2, box: false)))   // the PC with id 3
        XCTAssertNil(CTTechTargets.menu(0x0D, caster: 0, target: 5, party: [0, 1, 2]).zone)
        XCTAssertEqual(CTTechTargets.menu(0x1A, caster: 0, target: 5, party: party).zone, .init(.circle(centre: 5, size: 0x19)))
        XCTAssertEqual(CTTechTargets.menu(0x1B, caster: 0, target: 5, party: party).zone, .init(.circle(centre: 2, size: 0x19)))
        XCTAssertEqual(CTTechTargets.menu(0x08, caster: 0, target: 5, party: party).slots, Array(3..<11))
        XCTAssertEqual(CTTechTargets.menu(0x15, caster: 1, target: 5, party: party).slots, [1])
        // Area records: centre and aim by parameter set, the variant bit, a position query.
        let area = { (shape: Int, param: Int, size: Int) in TechSystemDef.Area(shape: shape, param: param, size: size) }
        XCTAssertEqual(CTTechTargets.zone(area(0, 0, 0x82), users: [1, 2], caster: 0, target: 6),
                       .init(.line(source: 1, aim: 6, size: 2, box: true)))
        XCTAssertEqual(CTTechTargets.zone(area(1, 5, 0x10), users: [0], caster: 0, target: 6),
                       .init(.circle(centre: 0, size: 0x10)))
        XCTAssertEqual(CTTechTargets.zone(area(2, 2, 0x04), users: [0], caster: 0, target: 6),
                       .init(.circle(centre: 4, size: 0)))                    // centre from the size byte
        XCTAssertEqual(CTTechTargets.zone(area(6, 1, 0x10), users: [0], caster: 0, target: 1),
                       .init(.row(centre: 1), scansParty: true))              // a PC target scans the party
        XCTAssertNil(CTTechTargets.zone(area(1, 0x81, 0x10), users: [0], caster: 0, target: 6))
    }
}
