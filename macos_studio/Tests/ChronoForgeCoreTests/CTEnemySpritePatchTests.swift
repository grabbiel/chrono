// CTEnemySpritePatchTests.swift — `rom.sprites` write-back of ct-enemy sprites
// over ct_sprites.py's synthetic enemy records (no ROM data): an unedited
// request writes nothing; frames, palette, record fields and a repacked pack
// decode back; a pack that outgrows its span moves into free space with its
// pointer rewritten; the sharer rule; PC-owned parts; the ROM-free checks;
// and (local ROM) an unedited import of every enemy rebuilds the clean ROM.
import XCTest
@testable import ChronoForgeCore

final class CTEnemySpritePatchTests: XCTestCase {
    // Synthetic records: 0 (graphics 10, frame set 10, palette 1, layout 0), 1 (graphics 11,
    // frame set 11, palette 2 = PC set 1's, layout 1), 2 (graphics 10, frame set 12, palette 0,
    // layout 2) and $F8 (PC set 0's parts). Records 0 and 2 share pack 10.
    func image() throws -> [UInt8] { try CTEnemySpritesTests().vectors().1 }

    func request(_ image: [UInt8], _ i: Int) throws -> CTSpritePatch.Request {
        let d = try CTEnemySpriteROM.decode(rom: image, id: i)
        let sheet = SpriteSheet.tiles(CTEnemySpriteROM.sheet(d))
        return CTSpritePatch.Request(sprite: CTEnemySpriteROM.spriteDef(d, id: CTEnemySpriteROM.id(i)), sheet: sheet)
    }

    struct Result {
        var rom: [UInt8]
        var report: [CTEnemySpritePatch.ReportSprite]
        var writes: [String]
        var moves: [String]
    }

    func build(_ requests: [CTSpritePatch.Request], image: [UInt8], built: [UInt8]? = nil, pcListed: [Int: String] = [:],
               space: inout FreeSpace) throws -> Result {
        var out = built ?? image, whats: [String] = [], moves: [String] = []
        let report = try CTEnemySpritePatch.apply(requests, base: image, built: built ?? image, pcListed: pcListed, space: &space,
                                                  write: { bytes, pc, what in
                                                      out.replaceSubrange(pc..<(pc + bytes.count), with: bytes)
                                                      whats.append(what)
                                                  }, relocated: { what, _, _, _ in moves.append(what) })
        return Result(rom: out, report: report, writes: whats, moves: moves)
    }

    func build(_ requests: [CTSpritePatch.Request], image: [UInt8]) throws -> Result {
        var space = FreeSpace()
        return try build(requests, image: image, space: &space)
    }

    func refusal(_ requests: [CTSpritePatch.Request], image: [UInt8], _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try build(requests, image: image), file: file, line: line) { error in
            XCTAssertTrue("\(error)".contains(text), "\(error)", file: file, line: line)
        }
    }

    func testUneditedRequestsWriteNothing() throws {
        let image = try image()
        let requests = try [0, 1, 2, 0xF8].map { try request(image, $0) }
        let r = try build(requests, image: image)
        XCTAssertTrue(r.writes.isEmpty)
        XCTAssertEqual(r.rom, image)
        XCTAssertEqual(r.report.map(\.set), [0, 1, 2, 0xF8])
        XCTAssertEqual(r.report.map(\.changed), [[], [], [], []])
        XCTAssertNil(r.report[0].pack)
        XCTAssertEqual(r.report[1].layout, 1)
        XCTAssertEqual(r.report[1].record, CTEnemySpriteROM.battle(CTEnemySpriteROM.record(image, 1)))
    }

    func testEditsDecodeBack() throws {
        let image = try image()
        var r = try request(image, 1)
        let n = r.sprite.rom!.tileCount
        r.sheet[5][0] = (r.sheet[5][0] + 1) % 16
        r.sprite.frames[1].cells![3] = (n - 1) | CTSpriteROM.hflip
        r.sprite.frames[1].tiles[7].x = -90
        var battle = try XCTUnwrap(r.sprite.battle)
        battle.halfWidth = 200; battle.moveSpeed = 7; battle.moveDelay = 15; battle.flags ^= 0x04
        r.sprite.battle = battle
        var space = FreeSpace()
        // Palette 2 is PC set 1's: a colour edit needs that set listed and agreeing.
        var recoloured = r
        recoloured.sprite.palettes![0][4] = "7FFF"
        XCTAssertThrowsError(try build([recoloured], image: image, space: &space)) { error in
            XCTAssertTrue("\(error)".contains("belong to playable set 1"), "\(error)")
        }
        let out = try build([r], image: image, space: &space)
        XCTAssertEqual(out.report[0].changed, ["tiles", "frames", "record"])
        XCTAssertEqual(out.report[0].changedTiles, [5])
        XCTAssertEqual(out.report[0].pack?.placement, "original")
        XCTAssertEqual(Set(out.writes), ["sprite enemy_001 graphics 11 pack", "sprite enemy_001 frame 1", "sprite enemy_001 record"])
        let e = try CTEnemySpriteROM.decode(rom: out.rom, id: 1)
        XCTAssertEqual(TileDecoder.decodeIndices(e.tiles[5], depth: .bpp4), r.sheet[5])
        XCTAssertEqual(e.frames[1].cells, r.sprite.frames[1].cells)
        XCTAssertEqual(e.frames[1].pieces[7], SpriteDef.Point(x: -90, y: r.sprite.frames[1].tiles[7].y))
        XCTAssertEqual(CTEnemySpriteROM.battle(e.record), battle)
        XCTAssertEqual(e.record.size, 1)
        // The unread bit 3 of +9 and bits 4 and 6 of +4 stay.
        let at = CTSpriteROM.pc(CTEnemySpriteROM.records + 10)
        XCTAssertEqual(out.rom[at + 9] & 0x08, image[at + 9] & 0x08)
        XCTAssertEqual(out.rom[at + 4] & 0x53, image[at + 4] & 0x53)
    }

    func testAPackThatOutgrowsItsSpanMovesToFreeSpace() throws {
        var image = try image()
        // Repack graphics 11 tightly, so noise no longer fits its span.
        let d = try CTEnemySpriteROM.decode(rom: image, id: 1)
        let tight = try XCTUnwrap(LZSS.compress(d.tiles.flatMap { $0 }, mode: .lz12))
        XCTAssertLessThan(tight.count, d.packedBytes)
        image.replaceSubrange(CTSpriteROM.pc(d.tilesAt)..<(CTSpriteROM.pc(d.tilesAt) + tight.count), with: tight)
        var r = try request(image, 1)
        var seed: UInt32 = 7
        for t in 1..<r.sheet.count {
            for k in 0..<64 {
                seed = seed &* 1_103_515_245 &+ 12345
                r.sheet[t][k] = UInt8(seed >> 16 & 15)
            }
        }
        var space = FreeSpace()
        space.add(0x300000..<0x302000, reclaimed: false)
        let out = try build([r], image: image, space: &space)
        let pack = try XCTUnwrap(out.report[0].pack)
        XCTAssertEqual(pack.placement, "free")
        XCTAssertEqual(pack.pc, 0x300000)
        XCTAssertGreaterThan(pack.packedBytes, pack.budget)
        XCTAssertEqual(out.moves, ["sprite enemy_001 graphics 11 pack"])
        XCTAssertEqual(CTSpriteROM.u24(out.rom, CTSpriteROM.tilesPtr + 3 * 11), 0xF00000)
        let e = try CTEnemySpriteROM.decode(rom: out.rom, id: 1)
        XCTAssertEqual(e.tiles.map { TileDecoder.decodeIndices($0, depth: .bpp4) }, Array(r.sheet.prefix(e.tiles.count)))
        // No free space: refused.
        var none = FreeSpace()
        XCTAssertThrowsError(try build([r], image: image, space: &none)) { error in
            XCTAssertTrue("\(error)".contains("over its"), "\(error)")
        }
    }

    func testSharedPacksNeedEverySharer() throws {
        let image = try image()
        var a = try request(image, 0), b = try request(image, 2)
        a.sheet[2][9] = (a.sheet[2][9] + 3) % 16
        refusal([a], image: image, "also shown by enemy records 2")
        refusal([a, b], image: image, "want different tiles for graphics 10")
        b.sheet[2] = a.sheet[2]
        let out = try build([a, b], image: image)
        XCTAssertEqual(out.writes, ["sprite enemy_000 graphics 10 pack"])
        XCTAssertEqual(out.report[0].sharedWith, ["enemy record 2 (enemy_002): tiles"])
        XCTAssertEqual(out.report[1].changedTiles, [2])
    }

    func testPCPartsFollowTheirSet() throws {
        let image = try image()
        var foe = try request(image, 0xF8)
        foe.sprite.frames[0].tiles[1].x = 11
        refusal([foe], image: image, "belong to playable set 0")
        // With the PC set listed and the same edit, the PC write-back writes it and the enemy agrees.
        let d = CTSpriteROM.decode(rom: image, set: 0)
        var pc = CTSpritePatch.Request(sprite: CTSpriteROM.spriteDef(d, id: "crono"), sheet: SpriteSheet.tiles(CTSpriteROM.sheet(d)))
        pc.sprite.frames[0].tiles[1].x = 11
        let (pcWrites, pcReport) = try CTSpritePatch.writes([pc], base: image)
        var built = image
        for w in pcWrites { built.replaceSubrange(w.pc..<(w.pc + w.bytes.count), with: w.bytes) }
        var space = FreeSpace()
        let out = try build([foe], image: image, built: built, pcListed: [0: "crono"], space: &space)
        XCTAssertTrue(out.writes.isEmpty)
        XCTAssertEqual(out.report[0].frameList[0].pieces[1][0], 11)
        // Listed but stale: refused.
        var stale = try request(image, 0xF8)
        stale.sprite.frames[0].tiles[1].x = 12
        XCTAssertThrowsError(try build([stale], image: image, built: built, pcListed: [0: "crono"], space: &space)) { error in
            XCTAssertTrue("\(error)".contains("differ from sprite crono's as built"), "\(error)")
        }
        // An unlisted enemy view of a changed PC part is a warning (the synthetic image's empty
        // records name set 0 too, as the battle would read them).
        let warnings = CTEnemySpritePatch.staleViews(pcReport, base: image, listed: [])
        XCTAssertTrue(warnings.contains { $0.contains("frames enemy record 248 shows") }, "\(warnings.prefix(3))")
        let listed = CTEnemySpritePatch.staleViews(pcReport, base: image, listed: [0xF8])
        XCTAssertFalse(listed.contains { $0.contains("enemy record 248 ") })
        XCTAssertEqual(listed.count, warnings.count - 1)
    }

    func testRefusalsAndROMFreeChecks() throws {
        let image = try image()
        let base = try request(image, 1)
        let n = base.sprite.rom!.tileCount
        func with(_ change: (inout CTSpritePatch.Request) -> Void) -> CTSpritePatch.Request {
            var r = base
            change(&r)
            return r
        }
        refusal([with { $0.sprite.frames[0].cells![0] = n }], image: image, "is not below")
        refusal([with { $0.sprite.frames[0].cells![0] = 0x0801 }], image: image, "bits 11-13")
        refusal([with { $0.sprite.frames[0].tiles[2].tile = 2 }], image: image, "must be 16x16 at slot tile 4")
        refusal([with { $0.sprite.frames[0].tiles[0].hflip = true }], image: image, "no OAM flips")
        refusal([with { $0.sprite.frames.removeLast() }], image: image, "frames are written in place")
        refusal([with { $0.sprite.rom?.frames = "$DD:0002" }], image: image, "re-import the sprites")
        refusal([with { $0.sprite.rom?.layout = 3 }], image: image, "only frame layouts 0-2")
        refusal([with { $0.sheet[0][0] = 5 }], image: image, "blank cell")
        refusal([with { $0.sprite.battle?.moveSpeed = 8 }], image: image, "is not 0-7")
        refusal([with { $0.sprite.battle?.flags = 0x01 }], image: image, "bits 2-7 only")
        refusal([with { $0.sprite.battle?.flags ^= 0x40 }], image: image, "bits 4 and 6")
        refusal([base, base], image: image, "built twice")
        XCTAssertTrue(CTEnemySpritePatch.validate(base.sprite).isEmpty)
        var other = base.sprite
        other.rom?.family = "ct-npc"
        XCTAssertEqual(CTEnemySpritePatch.validate(other), ["rom family ct-npc is not ct-enemy"])
        XCTAssertEqual(CTEnemySpritePatch.objTile(5, columns: 16), 10)
        XCTAssertEqual(CTEnemySpritePatch.objTile(5, columns: 8), 34)
        // The schema keeps the new fields.
        let back = try JSONDecoder().decode(SpriteDef.self, from: JSONEncoder().encode(base.sprite))
        XCTAssertEqual(back.battle, base.sprite.battle)
        XCTAssertEqual(back.rom?.packedBytes, base.sprite.rom?.packedBytes)
    }

    func testValidatorChecksEnemyEntries() throws {
        let image = try image()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctenemyvalid-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        for i in [0, 2] {
            let d = try CTEnemySpriteROM.decode(rom: image, id: i)
            let s = CTEnemySpriteROM.spriteDef(d, id: CTEnemySpriteROM.id(i))
            let url = project.fileURL(relative: s.sheet)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PNG.writeIndexed(CTEnemySpriteROM.sheet(d)).write(to: url)
            project.sprites[s.id] = s
        }
        project.project.rom = Project.ROMBuild(sprites: ["enemy_000"])
        func issues() -> [ValidationIssue] { Validator.validate(project).filter { $0.path.hasPrefix("sprites/enemy_") } }
        // Pack 10 is shared with enemy_002, which is not listed: a warning.
        XCTAssertEqual(issues().map(\.severity), [.warning])
        XCTAssertTrue(issues()[0].message.contains("shares its tiles"), issues()[0].message)
        project.project.rom = Project.ROMBuild(sprites: ["enemy_000", "enemy_002"])
        XCTAssertTrue(issues().isEmpty, "\(issues())")
        project.sprites["enemy_000"]?.battle?.moveDelay = 16
        project.sprites["enemy_000"]?.frames[0].tiles[1].tile = 0
        let errors = issues().filter { $0.severity == .error }.map(\.message)
        XCTAssertEqual(errors.count, 2, "\(errors)")
        XCTAssertTrue(errors.contains { $0.contains("moveDelay 16 is not 0-15") })
        XCTAssertTrue(errors.contains { $0.contains("OBJ 1: must be 16x16 at slot tile 2") })
        // The pack budget: a sheet that no longer fits its span is a warning.
        let s = try XCTUnwrap(project.sprites["enemy_002"])
        var sheet = SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: s.sheet)))
        let budget = try XCTUnwrap(CTEnemySpritePatch.packBudget(s, sheet: sheet))
        XCTAssertLessThanOrEqual(budget.packed, budget.budget)
        for t in 1..<sheet.count { for k in 0..<64 { sheet[t][k] = UInt8((t * 7 + k * 13) % 16) } }
        XCTAssertNotNil(CTEnemySpritePatch.packBudget(s, sheet: sheet))
        XCTAssertEqual(CTEnemySpritePatch.sharers(of: s, in: project.sprites).map(\.id), ["enemy_000"])
    }

    /// Local ROM: every imported enemy and set listed rebuilds the clean ROM with no write.
    func testImportThenBuildIsIdentical() throws {
        let rom = [UInt8](try Repo.romData())
        let raw = rom.count == CTROMBuilder.romSize + 512 ? Array(rom.dropFirst(512)) : rom
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctenemypatch-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let pcs = try CTSpriteROM.importSprites(rom: rom, into: &project)
        let (ids, _) = try CTEnemySpriteROM.importSprites(rom: rom, into: &project)
        try project.save()
        var loaded = try CTProject.load(from: dir)
        loaded.project.rom = Project.ROMBuild(sprites: pcs + ids)
        let (out, report) = try CTROMBuilder.build(base: raw, project: loaded)
        XCTAssertEqual(out, raw)
        XCTAssertTrue(report.writes.isEmpty)
        XCTAssertEqual(report.enemySprites?.count, 252)
        XCTAssertNil(report.spriteWarnings)
    }
}
