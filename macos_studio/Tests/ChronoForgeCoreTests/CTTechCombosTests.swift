// CTTechCombosTests.swift — combinations (repurposing a record, the field
// menu's copies, the capacity refusal), tech names and descriptions. ROM-free
// on a synthetic image; with the local ROM: a repurposed record, a rename and
// a new description build, decode back and write only their bytes.
import XCTest
@testable import ChronoForgeCore

final class CTTechCombosTests: XCTestCase {
    /// A synthetic image with consistent combination tables: 15 pairs, 10 trios,
    /// each record's techs on their own user set (7 + i, 22 + j), singles on 0-6.
    private func syntheticROM() -> [UInt8] {
        var rom = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        func put(_ at: Int, _ bytes: [Int]) { for (i, b) in bytes.enumerated() { rom[at + i] = UInt8(b) } }
        let pairs = (0..<6).flatMap { a in ((a + 1)..<6).map { [a, $0] } }      // 15 pairs of 0-5
        let trios = [[0, 1, 2], [0, 1, 3], [0, 1, 4], [0, 2, 3], [0, 2, 4], [1, 2, 3], [1, 2, 4], [1, 3, 4], [2, 3, 4], [0, 3, 4]]
        for c in 0..<7 {
            put(CTTechROM.userSetsPC + 3 * c, [c, 255, 255])
            for k in 0..<8 { put(CTTechROM.recPC + 11 * (1 + 8 * c + k), [c, 0, 0x40, 0, 0, 1 + 8 * c + k, 0x80, 0x80]) }
        }
        var req = 0x27FA, rec = CTTechROM.combosPC
        for (i, who) in (pairs + trios).enumerated() {
            let count = i < 15 ? 3 : 1, first = i < 15 ? 0x39 + 3 * i : 0x66 + i - 15
            let m = who.reduce(0) { $0 | 0x80 >> $1 }
            put(rec, [m, first, count, req & 0xFF, req >> 8])
            put(CTTechROM.userSetsPC + 3 * (7 + i), who + (who.count == 2 ? [255] : []))
            for k in 0..<count {
                put(0x0C0000 + req, (0..<3).map { $0 < who.count ? 1 + ($0 + k) % 8 : 0xFF })
                put(CTTechROM.recPC + 11 * (first + k), [7 + i, 0, 0x40, 0, 0] + who.map { 1 + 8 * $0 + k } + (who.count == 2 ? [0x80] : []))
                req += 3
            }
            if i < 15 {
                put(CTTechCombos.byteMembersPC + 7 + i, [m])
                put(CTTechCombos.menuTilesPC + 6 * i, (0..<3).flatMap { k in who.map { 1 + 8 * $0 + k } })
            } else {
                put(CTTechCombos.lineBitsPC + i - 15, [m])
                put(CTTechCombos.lineTilesPC + 3 * (i - 15), who.map { 1 + 8 * $0 })
            }
            rec += 5
        }
        rom[rec] = 0xFF
        for a in 1..<CTTechROM.areaCount {
            let at = 0x2B14 + 4 * (a - 1)
            put(CTTechROM.areaPtrsPC + 2 * a, [at & 0xFF, at >> 8])
            put(0x0C0000 + at, [1, 1, 0, 9])
        }
        for p in 0..<CTTechROM.partCount { put(CTTechROM.mpCostPC + p, [p % 30]) }
        put(CTTechCombos.comboMembersPC, [0x62, 0x32, 0x1C, 0x64, 0x58])
        return rom
    }

    private func apply(_ s: TechSystemDef, to base: [UInt8]) -> [UInt8] {
        var rom = base
        for w in CTTechROM.writes(s, rom: base) { rom.replaceSubrange(w.pc..<(w.pc + w.bytes.count), with: w.bytes) }
        return rom
    }

    func testMenuCostsDecodeAndRoundTrip() throws {
        let rom = syntheticROM()
        let s = try CTTechROM.decode(rom: rom, codec: nil)
        XCTAssertNoThrow(try CTTechROM.check(s))
        XCTAssertEqual(s.combos[0].menuCosts, [[1, 9], [2, 10], [3, 11]])
        XCTAssertEqual(s.combos[15].menuCosts, [[1, 9, 17]])
        XCTAssertEqual(s.rocks?.count, 5)
        XCTAssertEqual(apply(s, to: rom), rom)
        let m = CTTechCombos.members(of: 0x3A, in: s)
        XCTAssertEqual(m.map(\.char), [0, 1])
        XCTAssertEqual(m.map(\.part), [2, 10])
        XCTAssertEqual(m.map(\.mp), m.map(\.menuMP))
    }

    func testRepurposeWritesMembersSetsAndTheMenusCopies() throws {
        let rom = syntheticROM()
        let base = try CTTechROM.decode(rom: rom, codec: nil)
        var s = base
        try CTTechCombos.repurpose(&s, record: 4, members: [6, 1])        // (0, 5) -> (1, 6)
        XCTAssertEqual(s.combos[4].mask, 0x42)
        XCTAssertEqual(s.userSets[11], [1, 6, 255])
        XCTAssertNoThrow(try CTTechROM.check(s))
        XCTAssertNoThrow(try CTTechROM.check(s, against: base))
        try CTTechCombos.setMenuCost(&s, tech: 0x45, member: 6, index: 70)
        try CTTechCombos.setPart(&s, tech: 0x45, member: 6, part: 71)
        let built = apply(s, to: rom)
        let changed = Set((0..<rom.count).filter { built[$0] != rom[$0] })
        XCTAssertEqual(changed, [CTTechROM.combosPC + 20, CTTechCombos.byteMembersPC + 11,
                                 CTTechROM.userSetsPC + 33, CTTechROM.userSetsPC + 34,
                                 CTTechCombos.menuTilesPC + 25, CTTechROM.recPC + 11 * 0x45 + 6])
        XCTAssertEqual(try CTTechROM.decode(rom: built, codec: nil), s)
        // The new members learn through the rule's tables.
        let t = CTTechPoints.tables(s)
        XCTAssertTrue(t.combos.contains { $0.mask == 0x42 })
        // Refusals: a trio's place, a mask already used, a set shared with another record, no room.
        var x = base
        XCTAssertThrowsError(try CTTechCombos.repurpose(&x, record: 4, members: [1, 2, 3])) { XCTAssertTrue("\($0)".contains("pair")) }
        XCTAssertThrowsError(try CTTechCombos.repurpose(&x, record: 4, members: [0, 1])) { XCTAssertTrue("\($0)".contains("record 0")) }
        x.techs[0x45].userSet = 7
        XCTAssertThrowsError(try CTTechCombos.repurpose(&x, record: 4, members: [1, 6])) { XCTAssertTrue("\($0)".contains("shared")) }
        var more = base
        more.combos.append(.init(mask: 0x0E, first: 0x70, requirements: [[1, 1, 1]], menuCosts: nil))
        XCTAssertThrowsError(try CTTechROM.check(more)) { XCTAssertTrue("\($0)".contains("rock combinations")) }
        // Members changed without their sets: refused.
        var half = base
        half.combos[4].mask = 0x42
        XCTAssertThrowsError(try CTTechROM.check(half, against: base)) { XCTAssertTrue("\($0)".contains("user set")) }
    }

    func testNamesEncodeWithinTheMenusTiles() throws {
        let bytes = try CTTechText.encodeName("Ab Cd", icon: 0x2F)
        XCTAssertEqual(bytes.count, 11)
        XCTAssertEqual(bytes[0], 0x2F)
        XCTAssertEqual(bytes[3], 0xFF)
        XCTAssertEqual(Array(bytes[6...]), [UInt8](repeating: 0xEF, count: 5))
        XCTAssertNoThrow(try CTTechText.encodeName(String(repeating: "a", count: 11), icon: nil))
        XCTAssertThrowsError(try CTTechText.encodeName(String(repeating: "a", count: 11), icon: 0x2F)) {
            XCTAssertTrue("\($0)".contains("10 after the icon"), "\($0)")
        }
        XCTAssertThrowsError(try CTTechText.encodeName("a{gEF}", icon: nil))
        XCTAssertEqual(CTTechText.nameWidth("Abc", icon: 0x2F)?.room, 10)
    }

    // MARK: Local ROM

    private func project(_ rom: [UInt8]) throws -> CTProject {
        var p = try CTProject.load(from: fixtureURL())
        try CTTechROM.importTechs(rom: rom, into: &p)
        p.project.rom = .init(techs: true)
        return p
    }

    func testImportedDescriptionsAndUnchangedBuild() throws {
        let rom = [UInt8](try Repo.romData())
        let p = try project(rom)
        let s = try XCTUnwrap(p.techSystem)
        XCTAssertTrue(s.techs.dropFirst().allSatisfy { $0.description != nil })
        XCTAssertEqual(s.rocks?.count, 5)
        XCTAssertTrue(s.combos.allSatisfy { $0.menuCosts != nil })
        let codec = try CTTextCodec(profile: p.textProfile ?? CTTextProfile.fromROM(Data(rom)))
        XCTAssertEqual(CTTechText.check(s, codec: codec), [])
        XCTAssertEqual(try CTTechText.writes(s, rom: rom, codec: codec).map(\.what), [])
        let (built, report) = try CTROMBuilder.build(base: rom, project: p)
        XCTAssertEqual(built, rom)
        XCTAssertEqual(report.writes, [])
    }

    func testRepurposedRenamedAndDescribedBuild() throws {
        let rom = [UInt8](try Repo.romData())
        var p = try project(rom)
        var s = p.techSystem!
        // A pair record onto a pair no record has (character 6 and one of its members).
        let i = 14, old = s.combos[i].members
        try CTTechCombos.repurpose(&s, record: i, members: [old[0], 6])
        s.techs[1].name = "Zap"
        s.techs[2].description = "A new line."
        p.techSystem = s
        let (built, report) = try CTROMBuilder.build(base: rom, project: p)
        let whats = report.writes.map(\.what).filter { $0 != "checksum" }
        XCTAssertTrue(whats.contains(String(format: "combination $%02X members", s.combos[i].first)), "\(whats)")
        XCTAssertTrue(whats.contains(String(format: "combination $%02X menu members", s.combos[i].first)), "\(whats)")
        XCTAssertTrue(whats.contains("tech $01 name"), "\(whats)")
        XCTAssertTrue(whats.contains("tech descriptions"), "\(whats)")
        XCTAssertTrue(whats.allSatisfy { CTTechROM.isTechWrite($0) }, "\(whats)")
        let codec = try CTTextCodec(profile: p.textProfile ?? CTTextProfile.fromROM(Data(rom)))
        let back = try CTTechROM.decode(rom: built, codec: codec)
        XCTAssertEqual(back.combos, s.combos)
        XCTAssertEqual(back.userSets, s.userSets)
        XCTAssertEqual(back.techs[1].name, "Zap")
        XCTAssertEqual(back.techs[2].description, "A new line.")
        XCTAssertEqual(back.techs[3].description, s.techs[3].description)
        // The help line draws the new text from the built ROM's repacked table.
        let mem = CTDialogueMemory(rom: built)
        let line = try CTHelpLine(mem: mem, text: CTHelpLine.stringAddress(mem, place: .tech, index: 2), place: .tech)
        XCTAssertTrue(line.fits)
        XCTAssertEqual(CTHelpLine.description(mem, place: .tech, index: 2) + [0], try codec.compileMessage("A new line."))
    }
}
