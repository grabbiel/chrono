// CTStoryTests.swift — the story-flag scan, registry, era graph and preview path.
import XCTest
@testable import ChronoForgeCore

final class CTStoryTests: XCTestCase {
    /// A one-object pack: every function slot points at the script.
    private func pack(_ script: [UInt8]) throws -> CTEventPack {
        var bytes: [UInt8] = [1]
        for _ in 0..<16 { bytes += [32, 0] }
        return try CTEventPack(bytes: bytes + script)
    }
    private let bitSet: [UInt8] = [1, 2, 4, 8, 16, 32, 64, 128] + [UInt8](repeating: 0, count: 8)

    func testAccessesDecodeTheHandlersOperands() throws {
        let p = try pack([0x65, 0x83, 0x10,  0x66, 0x02, 0x7F,  0x16, 0x05, 0x20, 0x86, 0x01,  0x00,
                          0x56, 0x07, 0x34, 0x01,  0x56, 0x07, 0x00, 0x02,  0x4A, 0x40, 0x00, 0x7F, 0x09,  0x00])
        XCTAssertEqual(CTStory.accesses(p, at: 32, bitSet: bitSet),
                       [.init(kind: .set, addr: 0x110, bit: 3, width: 1, mask: 8)])        // bit 7: the $0100 page
        XCTAssertEqual(CTStory.accesses(p, at: 35, bitSet: bitSet).first?.addr, 0x7F)
        XCTAssertEqual(CTStory.accesses(p, at: 35, bitSet: bitSet).first?.kind, .clear)
        XCTAssertEqual(CTStory.accesses(p, at: 38, bitSet: bitSet),
                       [.init(kind: .test, addr: 0x105, bit: 5, width: 1, cmp: "and", value: 0x20)])
        XCTAssertEqual(CTStory.accesses(p, at: 44, bitSet: bitSet), [.init(kind: .write, addr: 0x134, bit: nil, width: 1)])
        XCTAssertEqual(CTStory.accesses(p, at: 48, bitSet: bitSet), [])                    // $7F:0200: not story memory
        XCTAssertEqual(CTStory.accesses(p, at: 52, bitSet: bitSet), [.init(kind: .write, addr: 0x40, bit: nil, width: 1)])
    }

    func testBitNumbersPastBitSetHaveNoSingleBit() throws {
        let p = try pack([0x65, 0x09, 0x01, 0x00])
        let a = CTStory.accesses(p, at: 32, bitSet: bitSet)
        XCTAssertEqual(a.first?.bit, nil)
        XCTAssertEqual(a.first?.mask, 0)
    }

    func testGuardsHoldOnEveryPathToAWarp() throws {
        // $16 7F:0005 & 1 → falls to Warp (it held), jumps to SetLoc (it failed).
        let p = try pack([0x16, 0x05, 0x01, 0x06, 0x06,  0xE0, 0x10, 0x00, 3, 4,  0xDD, 0x20, 0x00, 5, 6,  0x00])
        let g = CTStory.guards(p)
        XCTAssertEqual(g[37]?.map { [$0.addr, $0.bit ?? -1, $0.holds ? 1 : 0] }, [[5, 0, 1]])
        XCTAssertEqual(g[42]?.map(\.holds), [false])
        let w = CTStory.warp(p, at: 37, site: .init(entry: 0, locations: [7], offset: 37, opcode: 0xE0, functions: []),
                             guards: g[37]!)
        XCTAssertEqual([w.dest, w.x, w.y], [0x10, 3, 4])
    }

    func testFunctionZeroGoesOnPastItsFirstReturnOnly() throws {
        var bytes: [UInt8] = [1, 32, 0, 40, 0]                  // function 0 at $20, function 1 at $28
        for _ in 2..<16 { bytes += [40, 0] }
        bytes += [0x65, 0x00, 0x01,  0x00,  0x66, 0x00, 0x01,  0x00,  0x65, 0x01, 0x01,  0xB2]
        let p = try CTEventPack(bytes: bytes)
        let reach = CTStory.functionReach(p)
        XCTAssertEqual(reach[32], [[0, 0]])
        XCTAssertEqual(reach[36], [[0, 0]])                     // after the first $00
        XCTAssertEqual(reach[40]?.first, [0, 1])                // past the second: only function 1 (and the slots sharing it)
        XCTAssertFalse(reach[40]!.contains([0, 0]))
    }

    private func scan() -> CTStory.Scan {
        func ref(_ op: Int, _ kind: CTStory.Kind, _ addr: Int, _ bit: Int?, loc: Int, width: Int = 1) -> CTStory.Reference {
            .init(site: .init(entry: 1, locations: [loc], offset: 40, opcode: op, functions: [[0, 1]]),
                  access: .init(kind: kind, addr: addr, bit: bit, width: width))
        }
        return CTStory.Scan(references: [ref(0x65, .set, 0x10, 3, loc: 4), ref(0x16, .test, 0x10, 3, loc: 5),
                                         ref(0x66, .clear, 0x110, 0, loc: 4), ref(0x59, .write, 0x20, nil, loc: 6, width: 2)],
                            warps: [], instructions: 9, packs: 1)
    }

    func testRegistryEntriesSymbolsAndUnusedBytes() {
        let r = CTStoryRegistry.build(scan: scan(), code: [
            CodeReference(addr: 0x30, width: 1, access: "write", status: "code-proven", where_: "asm/x.asm:3",
                          mnemonic: "STA", routine: "R", source: "asm/x.asm:3"),
            CodeReference(addr: 0x40, width: 1, access: "read", status: "pattern-matched", where_: "$C5:0000",
                          mnemonic: "LDA", routine: nil, source: nil)], romSHA256: "x")
        XCTAssertEqual(r.entries.map(\.symbol), ["flag_7F0010_3", "var_7F0020", "var_7F0021", "var_7F0030", "flag_7F0110_0"])
        XCTAssertEqual(r.entries[0].counts, ["set": 1, "test": 1])
        XCTAssertEqual(r.entries[0].locations, [4, 5])
        XCTAssertEqual(r.entries[3].code.first?.status, "code-proven")
        XCTAssertTrue(r.unused.contains("7F:0040"))           // a pattern match alone does not use a byte
        XCTAssertFalse(r.unused.contains("7F:0021"))          // the word write's second byte
        XCTAssertEqual(r.unused.count, 512 - 5)
        XCTAssertEqual(r.totals.references, 4)
    }

    func testRegistryFlagsResolveAndKeepMaintainerWork() throws {
        var r = CTStoryRegistry.build(scan: scan(), code: [], romSHA256: "x")
        var project = Project(name: "t", engine: .init(base: "", rom_sha256: ""), start: .init(map: "", x: 0, y: 0, era: ""),
                              eras: [], flags: [Project.Flag(symbol: "MINE", bank: "story", addr: "7F:0003", bit: 2)],
                              encounters: [])
        XCTAssertThrowsError(try r.annotate(symbol: "flag_7F0010_3", name: "MINE", notes: nil, project: project))
        XCTAssertThrowsError(try r.annotate(symbol: "flag_7F0010_3", name: "bad name", notes: nil, project: project))
        try r.annotate(symbol: "flag_7F0010_3", name: "MET_GUARD", notes: "set at location 4", project: project)
        r.sync(into: &project)
        XCTAssertEqual(project.flags.map(\.symbol), ["MINE", "flag_7F0010_3", "MET_GUARD", "flag_7F0110_0"])
        let resolve = CTEventLowering.flagResolver(project.flags)
        XCTAssertEqual(try resolve("MET_GUARD").m, 0x10)
        let page = try resolve("flag_7F0110_0")
        XCTAssertEqual([Int(page.m), page.page ? 1 : 0, Int(page.bit)], [0x10, 1, 0])
        // A rebuild keeps the name and notes; a second sync replaces only registry flags.
        let again = CTStoryRegistry.build(scan: scan(), code: [], romSHA256: "x", previous: r)
        XCTAssertEqual(again.entries[0].name, "MET_GUARD")
        XCTAssertEqual(again.entries[0].notes, "set at location 4")
        again.sync(into: &project)
        XCTAssertEqual(project.flags.count, 4)
        XCTAssertNil(project.flags[0].origin)
        // The scene language and its checks see the registry symbols.
        let scene = try EventDSL.parse("obj 0 { func 0 { set_flag MET_GUARD if flag_7F0110_0 { nop } } }")
        XCTAssertEqual(EventReferences.issues(in: scene, flags: Set(project.flags.map(\.symbol)), strings: [], maps: [],
                                              scenes: [:]), [])
    }

    func testProjectFlagsStayBackwardCompatible() throws {
        let old = #"{"symbol":"MET_LAYLA","bank":"story","addr":"7F:0003","bit":2}"#
        let flag = try JSONDecoder().decode(Project.Flag.self, from: Data(old.utf8))
        XCTAssertNil(flag.origin)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(String(decoding: try encoder.encode(flag), as: UTF8.self),
                       #"{"addr":"7F:0003","bank":"story","bit":2,"symbol":"MET_LAYLA"}"#)   // no new keys when absent
    }

    func testEraGraphGroupsByNearestBankC2Location() {
        func warp(_ from: Int, _ to: Int, _ kind: String = "warp") -> CTStory.Warp {
            .init(site: .init(entry: 2, locations: [from], offset: 50, opcode: 0xE0, functions: []), kind: kind,
                  dest: to, x: 1, y: 2, facing: 0, guards: [])
        }
        let g = CTEraGraph.build(warps: [warp(1, 0x1F0), warp(2, 1), warp(3, 0x1F1), warp(4, 3), warp(2, 4), warp(5, 5),
                                         warp(6, 0x1F0), warp(6, 0x1F1), warp(7, 6), warp(8, 9, "setPrevLoc")])
        XCTAssertEqual(g.groups.map(\.seed), [0x1F0, 0x1F1])
        XCTAssertEqual(g.group(of: 2)?.seed, 0x1F0)
        XCTAssertEqual(g.group(of: 4)?.seed, 0x1F1)
        XCTAssertNil(g.group(of: 6))                       // a tie
        XCTAssertNil(g.group(of: 5))                       // no path to a seed
        XCTAssertFalse(g.edges.contains { $0.from == 8 })
        XCTAssertTrue(g.edges.first { $0.from == 2 && $0.to == 4 }!.crossGroup)
        var named = g
        named.groups[0].name = "Group A"
        XCTAssertEqual(CTEraGraph.build(warps: [warp(1, 0x1F0)], previous: named).groups[0].name, "Group A")
    }

    func testARaisedPathPreviewsAndLowersBack() throws {
        // set 7F:0010 bit 3, an unrelated opcode, clear 7F:0110 bit 0, then a jump ends the path.
        let p = try pack([0x65, 0x03, 0x10,  0x0D, 0x01,  0x66, 0x80, 0x10,  0x10, 0x01,  0x00])
        let registry = CTStoryRegistry.build(scan: scan(), code: [], romSHA256: "x")
        let (scene, changes, end) = try XCTUnwrap(CTStory.raisePath(p, start: 32, registry: registry))
        XCTAssertEqual(changes, ["set flag_7F0010_3", "clear flag_7F0110_0"])
        XCTAssertEqual(end, 40)
        XCTAssertEqual(try EventPreview.run(scene).flags, ["flag_7F0010_3"])
        XCTAssertEqual(try EventScheduler.run(scenes: ["s": scene], entryScene: "s").flags, ["flag_7F0010_3"])
        let lowered = try CTEventLowering.lower(scenes: [scene], flag: CTEventLowering.flagResolver(registry.projectFlags))
        let first = try CTEventPack(bytes: lowered.bytes).functions[0][0]
        XCTAssertEqual(Array(lowered.bytes[(first + 1)..<(first + 9)]), Array(p.bytes[33..<41]))
    }

    // MARK: ROM

    func testROMScanReconcilesWithThePythonTwin() throws {
        let rom = [UInt8](try Repo.romData())
        let scan = try CTStory.scan(rom: rom)
        XCTAssertEqual([scan.packs, scan.instructions, scan.references.count, scan.warps.count], [461, 142_702, 7055, 663])
        let registry = CTStoryRegistry.build(scan: scan, code: [], romSHA256: CTEventPack.sha256(rom))
        XCTAssertEqual(registry.entries.filter(\.isBit).count, 852)
        XCTAssertEqual(512 - registry.unused.count, 219)
        let graph = CTEraGraph.build(warps: scan.warps)
        XCTAssertEqual([graph.edges.count, graph.groups.count, graph.groups.reduce(0) { $0 + $1.locations.count }], [718, 8, 120])
    }

    func testROMPathSetsTheRecordedFlagsInThePreview() throws {
        let rom = [UInt8](try Repo.romData())
        let registry = CTStoryRegistry.build(scan: try CTStory.scan(rom: rom), code: [], romSHA256: "")
        let check = try CTStory.previewCheck(rom: rom, registry: registry)
        XCTAssertTrue(check.passed, "\(check)")
        XCTAssertFalse(check.expectedFlags.isEmpty)
    }

    func testROMImportIntoAProjectValidates() throws {
        let rom = [UInt8](try Repo.romData())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("story-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("MyGame.ctproj")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Repo.root.appendingPathComponent("macos_studio/Tests/ChronoForgeCoreTests/Resources/MyGame.ctproj"), to: url)
        var project = try CTProject.load(from: url)
        let (registry, _) = try CTStory.importStory(rom: rom, project: &project)
        let reloaded = try CTProject.load(from: url)
        XCTAssertEqual(reloaded.project.flags.filter { $0.origin == "story" }.count, registry.projectFlags.count)
        XCTAssertTrue(reloaded.project.flags.contains { $0.symbol == "MET_LAYLA" && $0.origin == nil })
        XCTAssertTrue(Validator.isValid(Validator.validate(reloaded)))
        XCTAssertEqual(try CTStoryRegistry.load(project: url), registry)
    }
}
