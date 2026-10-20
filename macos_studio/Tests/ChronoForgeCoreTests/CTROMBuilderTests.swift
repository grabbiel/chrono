// CTROMBuilderTests.swift — the .sfc builder: identical rebuild of every event
// pack, a lowered scene with its message table, refusals, and free space.
import XCTest
@testable import ChronoForgeCore

final class CTROMBuilderTests: XCTestCase {
    private func clean() throws -> [UInt8] {
        guard let rom = try? [UInt8](Repo.romData()) else { throw XCTSkip("local ROM not present") }
        return rom
    }

    private func unpack(_ rom: [UInt8], _ entry: Int) throws -> [UInt8] {
        try CTEventROM.unpack(rom: rom, entry: try CTEventROM.entries(rom: rom)[entry])
    }

    // MARK: No ROM

    func testFreeSpacePrefersExactStartsAndNeverSplitsAcrossRanges() {
        var space = FreeSpace()
        space.add(0x10000..<0x10010, reclaimed: false)
        space.add(0x20000..<0x20100, reclaimed: true)
        XCTAssertEqual(space.total, 0x110)
        XCTAssertNil(space.allocate(0x11, reclaimed: false))
        XCTAssertEqual(space.allocate(0x08, reclaimed: false), 0x10000)
        XCTAssertEqual(space.allocate(0x08, reclaimed: false), 0x10008)
        XCTAssertNil(space.allocate(1, reclaimed: false))
        XCTAssertFalse(space.allocate(4, at: 0x20004))
        XCTAssertTrue(space.allocate(4, at: 0x20000))
        XCTAssertEqual(space.allocate(0xFC, reclaimed: true), 0x20004)
        XCTAssertEqual(space.total, 0)
    }

    func testChecksumFieldsDoNotCountTowardTheSum() {
        var rom = [UInt8](repeating: 1, count: 0x10000)
        let before = CTROMBuilder.checksum(rom)
        rom[CTROMLayout.checksumPC] = 0x55; rom[CTROMLayout.complementPC + 1] = 0x99
        XCTAssertEqual(CTROMBuilder.checksum(rom), before)
        XCTAssertEqual(before, (0x10000 - 4 + 0xFF * 2) & 0xFFFF)
    }

    func testLayoutRegionsAreInsideOneBank() {
        XCTAssertEqual(CTROMLayout.freeRegions.count, 66)
        XCTAssertEqual(CTROMLayout.freeRegions.reduce(0) { $0 + $1.size }, 62_206)
        for r in CTROMLayout.freeRegions { XCTAssertEqual(r.pc >> 16, (r.end - 1) >> 16) }
    }

    func testValidatorChecksROMBuildSettings() throws {
        var project = try CTProject.load(from: fixtureURL())
        project.project.rom = .init(eventPacks: [
            .init(entry: 0, scenes: ["intro"]), .init(entry: 23, scenes: ["nope"]),
            .init(entry: 23, listing: "events/missing.ctevents"), .init(entry: 30)])
        let messages = Validator.validate(project).filter { $0.path.hasPrefix("project.json rom") }.map(\.description)
        for expected in ["entry 0", "not an Evt_PackPtrs entry", "do not lower", "scene \"nope\" not found",
                         "entry built twice", "missing.ctevents not found", "exactly one of scenes or listing"] {
            XCTAssertTrue(messages.contains { $0.contains(expected) }, "\(expected) not in \(messages)")
        }
    }

    // MARK: ROM

    func testCleanChecksumIsReproduced() throws {
        let rom = try clean()
        let stored = Int(rom[CTROMLayout.checksumPC]) | Int(rom[CTROMLayout.checksumPC + 1]) << 8
        XCTAssertEqual(CTROMBuilder.checksum(rom), stored)
    }

    /// Every event pack rebuilt from its own listing gives back the ROM byte
    /// for byte: same unpacked bytes, the original packer, the same places.
    func testRebuildingEveryPackFromItsListingIsIdentical() throws {
        let rom = try clean()
        var requests: [CTROMBuilder.Request] = []
        for entry in 0..<CTEventROM.pointerCount where !CTROMLayout.notEventPackEntries.contains(entry) {
            let text = CTEventListing.render(CTEventListing.program(try CTEventPack(bytes: try unpack(rom, entry))))
            requests.append(.init(entry: entry, source: "listing", bytes: try CTEventListing.parse(text).assemble()))
        }
        XCTAssertEqual(requests.count, 488)
        let (built, report) = try CTROMBuilder.build(base: rom, requests: requests, textProfile: nil)
        XCTAssertEqual(CTEventPack.sha256(built), CTTextProfile.romHash)
        XCTAssertEqual(report.writes, [])
        XCTAssertEqual(Set(report.packs.map(\.placement)), ["original", "shared"])
    }

    func testLoweredSceneWithMessagesIsWrittenAndPointedTo() throws {
        let rom = try clean()
        var project = try CTProject.load(from: fixtureURL())
        var scene = project.scenes["intro"]!
        scene.scene.funcs[0].stmts.removeAll { if case .call = $0 { return true }; return false }
        project.scenes["intro"] = scene
        project.dialogue.strings = ["greeting": "Hello there!{line}Welcome to the Tyrano Dome.",
                                    "shop": "Welcome! Buy something!", "intro": "A giant robot whirs quietly."]
        project.textProfile = try CTTextProfile.fromROM(Data(rom))
        project.project.rom = .init(eventPacks: [.init(entry: 23, scenes: ["intro"])])
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)

        let lowered = try CTEventLowering.lower(project: project, scenes: ["intro"])
        let table = try XCTUnwrap(report.messageTables.first)
        XCTAssertEqual(report.packs.count, 1)
        let pack = report.packs[0]
        XCTAssertEqual(pack.messageTable, table.address)
        // The pointer, the unpacked pack with its relocated $B8, and the table.
        let entry = try CTEventROM.entries(rom: built)[23]
        XCTAssertEqual(entry.pc, pack.pc)
        var expected = lowered.bytes
        let relocation = lowered.relocations[0].offset
        expected[relocation..<(relocation + 3)] = [UInt8(table.pc & 255), UInt8(table.pc >> 8 & 255), UInt8(0xC0 | table.pc >> 16)]
        XCTAssertEqual(try unpack(built, 23), expected)
        let codec = try CTTextCodec(profile: project.textProfile!)
        for (i, id) in lowered.messages.enumerated() {
            let p = table.pc + 2 * i
            let string = table.pc & 0xFF0000 | Int(built[p]) | Int(built[p + 1]) << 8
            let end = built[string...].firstIndex(of: 0)!
            XCTAssertEqual(try codec.decode(Array(built[string...end])),
                           try codec.decode(codec.compileMessage(project.dialogue.strings[id]!)), id)
        }
        // Old stream reused (nothing else pointed at it); header fixed; nothing else moved.
        XCTAssertEqual(pack.placement, "original")
        XCTAssertEqual(CTROMBuilder.checksum(built), report.checksum)
        XCTAssertEqual(Int(built[CTROMLayout.checksumPC]) | Int(built[CTROMLayout.checksumPC + 1]) << 8, report.checksum)
        let written = report.writes.flatMap { $0.pc..<($0.pc + $0.length) }
        let differing = (0..<rom.count).filter { rom[$0] != built[$0] }
        XCTAssertTrue(Set(differing).isSubset(of: Set(written)))
        let before = try CTEventROM.entries(rom: rom), after = try CTEventROM.entries(rom: built)
        for i in 0..<CTEventROM.pointerCount where i != 23 { XCTAssertEqual(before[i], after[i]) }
    }

    func testRefusals() throws {
        let rom = try clean()
        let ok = try unpack(rom, 23)
        func refuse(_ requests: [CTROMBuilder.Request], base: [UInt8]? = nil, _ text: String,
                    file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try CTROMBuilder.build(base: base ?? rom, requests: requests, textProfile: nil),
                                 file: file, line: line) { error in
                XCTAssertTrue("\(error)".contains(text), "\(error)", file: file, line: line)
            }
        }
        refuse([.init(entry: 0, source: "t", bytes: ok)], "does not point at an event pack")
        refuse([.init(entry: 600, source: "t", bytes: ok)], "not 0-512")
        refuse([.init(entry: 23, source: "t", bytes: ok), .init(entry: 23, source: "t", bytes: ok)], "built twice")
        var modified = rom; modified[0x200000] ^= 1
        refuse([.init(entry: 23, source: "t", bytes: ok)], base: modified, "unmodified")
        refuse([.init(entry: 23, source: "t", bytes: [UInt8](repeating: 0, count: 0x1701))], "the game accepts")
        refuse([.init(entry: 23, source: "t", bytes: [0x0D, 0x0A] + [UInt8](repeating: 0, count: 500))], "LocLoad_CheckEvtData")
        refuse([.init(entry: 23, source: "t", bytes: [1, 2, 3])], "entry 23:")
        refuse([.init(entry: 23, source: "t", bytes: ok, messages: [("a", "Hi")], relocations: [1])], "text profile")
        // Incompressible packs until the free space runs out.
        var rng = SystemRandomNumberGenerator()
        let big = (0..<12).map { i -> CTROMBuilder.Request in
            let head = [UInt8(1)] + [UInt8](repeating: 0, count: 32) + [0x00, 0xB2]
            let noise = (0..<(0x1700 - head.count)).map { _ in UInt8.random(in: 0...255, using: &rng) }
            return .init(entry: 23 + i, source: "t", bytes: head + noise)
        }
        refuse(big, "no free space")
    }
}
