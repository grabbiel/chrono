// CTNPCSpritePatchTests.swift — `rom.sprites` write-back of ct-npc sprites over
// ct_npc_sprites.py's synthetic NPC records (no ROM data): an unedited request
// writes nothing; frames, animations, palette and a repacked pack decode back;
// a pack that outgrows its span moves into free space; one sharer pass covers
// NPC and enemy records; the ROM-free checks and the Validator's rules.
import XCTest
@testable import ChronoForgeCore

final class CTNPCSpritePatchTests: XCTestCase {
    // Synthetic records: 7 (graphics 20, frame set 20, palette 4, animation set 3, class 0),
    // 8 (graphics 21, frame set 21, palette 5, animation set 4, class 1) and 9 (graphics 20,
    // frame set 20, palette 6, animation set 4, size byte 4). Records 7 and 9 share pack 20
    // and frame set 20; animation sets 3 and 4 are PC sets' (the synthetic PC image's).
    func image() throws -> [UInt8] { try CTNPCSpritesTests().vectors().1 }

    func request(_ image: [UInt8], _ r: Int) throws -> CTSpritePatch.Request {
        let d = try CTNPCSpriteROM.decode(rom: image, record: r)
        let sheet = SpriteSheet.tiles(CTNPCSpriteROM.sheet(d))
        return CTSpritePatch.Request(sprite: CTNPCSpriteROM.spriteDef(d, id: CTNPCSpriteROM.id(r), field: nil), sheet: sheet)
    }

    func enemyRequest(_ image: [UInt8], _ i: Int) throws -> CTSpritePatch.Request {
        let d = try CTEnemySpriteROM.decode(rom: image, id: i)
        let sheet = SpriteSheet.tiles(CTEnemySpriteROM.sheet(d))
        return CTSpritePatch.Request(sprite: CTEnemySpriteROM.spriteDef(d, id: CTEnemySpriteROM.id(i)), sheet: sheet)
    }

    struct Result {
        var rom: [UInt8]
        var enemies: [CTEnemySpritePatch.ReportSprite]
        var npcs: [CTNPCSpritePatch.ReportSprite]
        var writes: [String]
        var moves: [String]
    }

    func build(_ requests: [CTSpritePatch.Request], image: [UInt8], space: inout FreeSpace) throws -> Result {
        var out = image, whats: [String] = [], moves: [String] = []
        let report = try CTEnemySpritePatch.applyAll(requests, base: image, built: image, pcListed: [:], space: &space,
                                                     write: { bytes, pc, what in
                                                         out.replaceSubrange(pc..<(pc + bytes.count), with: bytes)
                                                         whats.append(what)
                                                     }, relocated: { what, _, _, _ in moves.append(what) })
        return Result(rom: out, enemies: report.enemies, npcs: report.npcs, writes: whats, moves: moves)
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
        let requests = try [7, 8, 9].map { try request(image, $0) }
        let r = try build(requests, image: image)
        XCTAssertTrue(r.writes.isEmpty)
        XCTAssertEqual(r.rom, image)
        XCTAssertTrue(r.enemies.isEmpty)
        XCTAssertEqual(r.npcs.map(\.set), [7, 8, 9])
        XCTAssertEqual(r.npcs.map(\.changed), [[], [], []])
        XCTAssertEqual(r.npcs.map(\.layout), [0, 1, 0])
        XCTAssertEqual(r.npcs[1].stride, 12)
        XCTAssertNil(r.npcs[0].pack)
    }

    func testEditsDecodeBack() throws {
        let image = try image()
        var r = try request(image, 8)
        let n = r.sprite.rom!.tileCount
        r.sheet[5][0] = (r.sheet[5][0] + 1) % 16
        r.sprite.frames[1].cells![3] = (n - 1) | CTSpriteROM.hflip
        r.sprite.frames[1].tiles[7].x = -90
        r.sprite.palettes![0][4] = "7FFF"
        let out = try build([r], image: image)
        XCTAssertEqual(out.npcs[0].changed, ["tiles", "frames", "palette"])
        XCTAssertEqual(out.npcs[0].changedTiles, [5])
        XCTAssertEqual(out.npcs[0].pack?.placement, "original")
        XCTAssertEqual(Set(out.writes), ["sprite npc_008 graphics 21 pack", "sprite npc_008 frame 1", "sprite npc_008 palette"])
        let d = try CTNPCSpriteROM.decode(rom: out.rom, record: 8)
        XCTAssertEqual(TileDecoder.decodeIndices(d.tiles[5], depth: .bpp4), r.sheet[5])
        XCTAssertEqual(d.frames[1].cells, r.sprite.frames[1].cells)
        XCTAssertEqual(d.frames[1].pieces[7], SpriteDef.Point(x: -90, y: r.sprite.frames[1].tiles[7].y))
        XCTAssertEqual(d.palette[3], 0x7FFF)
        // The record itself is not written.
        let at = CTSpriteROM.pc(CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * 8)
        XCTAssertEqual(Array(out.rom[at..<(at + 5)]), Array(image[at..<(at + 5)]))
    }

    func testAPackThatOutgrowsItsSpanMovesToFreeSpace() throws {
        var image = try image()
        // Repack graphics 21 tightly, so noise no longer fits its span.
        let d = try CTNPCSpriteROM.decode(rom: image, record: 8)
        let tight = try XCTUnwrap(LZSS.compress(d.tiles.flatMap { $0 }, mode: d.mode))
        XCTAssertLessThan(tight.count, d.packedBytes)
        image.replaceSubrange(CTSpriteROM.pc(d.tilesAt)..<(CTSpriteROM.pc(d.tilesAt) + tight.count), with: tight)
        var r = try request(image, 8)
        var seed: UInt32 = 8
        for t in 1..<r.sheet.count {
            for k in 0..<64 {
                seed = seed &* 1_103_515_245 &+ 12345
                r.sheet[t][k] = UInt8(seed >> 16 & 15)
            }
        }
        var space = FreeSpace()
        space.add(0x300000..<0x302000, reclaimed: false)
        let out = try build([r], image: image, space: &space)
        let pack = try XCTUnwrap(out.npcs[0].pack)
        XCTAssertEqual(pack.placement, "free")
        XCTAssertEqual(pack.pc, 0x300000)
        XCTAssertGreaterThan(pack.packedBytes, pack.budget)
        XCTAssertEqual(out.moves, ["sprite npc_008 graphics 21 pack"])
        XCTAssertEqual(CTSpriteROM.u24(out.rom, CTSpriteROM.tilesPtr + 3 * 21), 0xF00000)
        let e = try CTNPCSpriteROM.decode(rom: out.rom, record: 8)
        XCTAssertEqual(e.tiles.map { TileDecoder.decodeIndices($0, depth: .bpp4) }, Array(r.sheet.prefix(e.tiles.count)))
        var none = FreeSpace()
        XCTAssertThrowsError(try build([r], image: image, space: &none)) { error in
            XCTAssertTrue("\(error)".contains("over its"), "\(error)")
        }
    }

    func testOneSharerPassCoversNPCsAndEnemies() throws {
        let image = try image()
        // Pack 20: records 7 and 9.
        var a = try request(image, 7), b = try request(image, 9)
        a.sheet[3][9] = (a.sheet[3][9] + 1) % 16
        refusal([a], image: image, "also shown by $E4:F000 records 9 (NPCs)")
        b.sheet[3][9] = a.sheet[3][9]
        let both = try build([a, b], image: image)
        XCTAssertEqual(both.writes, ["sprite npc_007 graphics 20 pack"])
        XCTAssertEqual(both.npcs[0].sharedWith, ["NPC record 9 (npc_009): tiles"])
        b.sheet[3][9] = (a.sheet[3][9] + 1) % 16
        refusal([a, b], image: image, "a shared part has one content")
        // Animation set 4 is PC set 4's: an NPC edit to it needs that set.
        var c = try request(image, 8)
        let k = try XCTUnwrap(c.sprite.animations.firstIndex { $0.row == 0 })
        c.sprite.animations[k].durations[0] = c.sprite.animations[k].durations[0] % 200 + 1
        refusal([c], image: image, "belong to playable set 4")
        // Palette 5: NPC record 8 and, in this copy, enemy record 0.
        var shared = image
        shared[CTSpriteROM.pc(CTEnemySpriteROM.records) + 2] = 5
        var g = try request(shared, 8), h = try enemyRequest(shared, 0)
        g.sprite.palettes![0][2] = "1234"
        h.sprite.palettes![0][2] = "1234"
        refusal([g], image: shared, "also shown by enemy records 0")
        refusal([h], image: shared, "$E4:F000 records 8 (NPCs)")
        let all = try build([g, h], image: shared)
        XCTAssertEqual(all.writes, ["sprite enemy_000 palette"])
        XCTAssertEqual(all.enemies[0].sharedWith, ["NPC record 8 (npc_008): palette"])
        XCTAssertEqual(all.npcs[0].sharedWith, ["enemy record 0 (enemy_000): palette"])
        XCTAssertEqual(all.npcs[0].changed, ["palette"])
    }

    func testRefusalsAndROMFreeChecks() throws {
        let image = try image()
        let base = try request(image, 7)
        func refused(_ text: String, _ change: (inout CTSpritePatch.Request) -> Void, file: StaticString = #filePath, line: UInt = #line) {
            var r = base
            change(&r)
            refusal([r], image: image, text, file: file, line: line)
        }
        refused("is not an NPC record") { $0.sprite.rom!.set = 3 }
        refused("size class 2") { $0.sprite.rom!.layout = 2 }
        refused("stream must be 8 x 2 cells at slot tile 392") { $0.sprite.stream!.baseTile = 64 }
        refused("frames are written in place") { $0.sprite.frames.removeLast() }
        refused("must be 16x16 at slot tile 2") { $0.sprite.frames[0].tiles[1].tile = 4 }
        refused("run past the facing") { r in
            let i = r.sprite.animations.firstIndex { $0.row == 0 }!
            r.sprite.animations[i].frames += [0, 0, 0, 0, 0, 0, 0, 0]
            r.sprite.animations[i].durations += [1, 1, 1, 1, 1, 1, 1, 1]
        }
        refused("blank cell") { $0.sheet[0][0] = 3 }
        refused("re-import the sprites") { $0.sprite.rom!.frames = "$D0:0000" }
        refusal([base, base], image: image, "is built twice")
        var copy = base
        copy.sprite.id = "other"
        refusal([base, copy], image: image, "NPC record 7 is also sprite")
        XCTAssertTrue(CTNPCSpritePatch.validate(base.sprite).isEmpty)
        XCTAssertNotNil(CTEnemySpritePatch.packBudget(base.sprite, sheet: base.sheet))
    }

    func testValidatorChecksNPCEntries() throws {
        let image = try image()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctnpcpatch-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        for r in [7, 9] {
            let d = try CTNPCSpriteROM.decode(rom: image, record: r)
            let s = CTNPCSpriteROM.spriteDef(d, id: CTNPCSpriteROM.id(r), field: nil)
            let url = project.fileURL(relative: s.sheet)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PNG.writeIndexed(CTNPCSpriteROM.sheet(d)).write(to: url, options: .atomic)
            project.sprites[s.id] = s
        }
        project.project.rom = Project.ROMBuild(sprites: ["npc_007"])
        var issues = Validator.validate(project).filter { $0.path.hasPrefix("sprites/") }
        XCTAssertEqual(issues.filter { $0.severity == .error }.count, 0, "\(issues)")
        XCTAssertTrue(issues.contains { $0.message.contains("with sprites/npc_009") }, "\(issues)")
        project.sprites["npc_007"]!.stream!.baseTile = 0
        issues = Validator.validate(project).filter { $0.path == "sprites/npc_007.sprite.json" && $0.severity == .error }
        XCTAssertTrue(issues.contains { $0.message.contains("stream must be") }, "\(issues)")
    }
}
