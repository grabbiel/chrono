// CTSpritePatchTests.swift — `rom.sprites` write-back over ct_sprites.py's
// synthetic sets (no ROM data): an unedited set writes nothing, edits decode
// back, refusals; the validator's rom.sprites checks; and (local ROM) an
// unedited import of all seven sets rebuilds the clean ROM.
import XCTest
@testable import ChronoForgeCore

final class CTSpritePatchTests: XCTestCase {
    func synthetic() throws -> [UInt8] {
        let v = try JSONDecoder().decode(CTSpritesTests.Vectors.self, from: resourceData("sprites/sprite_vectors.json"))
        var image = [UInt8](repeating: 0, count: CTROMBuilder.romSize)
        for r in v.regions {
            let at = CTSpriteROM.pc(try XCTUnwrap(CTSpriteROM.parseSNES(r.at)))
            let b = CTSpritesTests.bytes(r.hex)
            image.replaceSubrange(at..<(at + b.count), with: b)
        }
        return image
    }

    func request(_ image: [UInt8], set c: Int) -> CTSpritePatch.Request {
        let d = CTSpriteROM.decode(rom: image, set: c)
        let sheet = SpriteSheet.tiles(CTSpriteROM.sheet(d))
        return CTSpritePatch.Request(sprite: CTSpriteROM.spriteDef(d, id: "s\(c)"), sheet: sheet)
    }

    func apply(_ writes: [CTSpritePatch.Write], to image: [UInt8]) -> [UInt8] {
        var out = image
        for w in writes { out.replaceSubrange(w.pc..<(w.pc + w.bytes.count), with: w.bytes) }
        return out
    }

    func testUneditedSetsWriteNothing() throws {
        let image = try synthetic()
        let (writes, report) = try CTSpritePatch.writes([request(image, set: 0), request(image, set: 1)], base: image)
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(report.map(\.set), [0, 1])
        XCTAssertEqual(report.map(\.changed), [[], []])
        XCTAssertNil(report[0].sharedWith)
        let d = CTSpriteROM.decode(rom: image, set: 1)
        XCTAssertEqual(report[1].frameCount, d.frames.count)
        XCTAssertEqual(report[1].tilesSHA256, CTEventPack.sha256(d.tiles.flatMap { $0 }))
    }

    func testEditsDecodeBack() throws {
        let image = try synthetic()
        var r = request(image, set: 0)
        let tileCount = r.sprite.rom!.tileCount
        // A tile's pixels, a cell (tile and mirror) and an OBJ offset, a frame id, a row's durations, a colour.
        r.sheet[3][0] = (r.sheet[3][0] + 1) % 16
        r.sheet[3][63] = 7
        r.sprite.frames[2].cells![5] = (tileCount - 1) | CTSpriteROM.hflip
        r.sprite.frames[2].tiles[3].x = -100
        r.sprite.frames[2].tiles[0].y = 90
        let a = try XCTUnwrap(r.sprite.animations.firstIndex { $0.row == 0 && $0.facing == 2 })
        let newId = (r.sprite.animations[a].frames[0] + 1) % r.sprite.frames.count
        r.sprite.animations[a].frames[0] = newId
        let newDuration = r.sprite.animations[a].durations[0] % 200 + 1
        for i in r.sprite.animations.indices where r.sprite.animations[i].row == 0 {
            r.sprite.animations[i].durations[0] = newDuration
        }
        r.sprite.palettes![0][4] = "7FFF"
        let (writes, report) = try CTSpritePatch.writes([r], base: image)
        XCTAssertEqual(report[0].changed, ["tiles", "frames", "animations", "palette"])
        XCTAssertEqual(report[0].changedTiles, [3])
        let whats = Set(writes.map(\.what))
        XCTAssertEqual(whats, ["sprite s0 tile 3", "sprite s0 frame 2", "sprite s0 frame ids r00.left",
                               "sprite s0 durations r00", "sprite s0 palette"])
        let d = CTSpriteROM.decode(rom: apply(writes, to: image), set: 0)
        XCTAssertEqual(TileDecoder.decodeIndices(d.tiles[3], depth: .bpp4), r.sheet[3])
        XCTAssertEqual(d.frames[2].cells, r.sprite.frames[2].cells)
        let pieces: [SpriteDef.Point] = r.sprite.frames[2].tiles.map { SpriteDef.Point(x: $0.x, y: $0.y) }
        XCTAssertEqual(d.frames[2].pieces, pieces)
        XCTAssertEqual(d.animations, r.sprite.animations)
        XCTAssertEqual(d.palette[3], 0x7FFF)
        XCTAssertEqual(report[0].frameList[2].pieces[3], [-100, r.sprite.frames[2].tiles[3].y])
    }

    func testRefusals() throws {
        let image = try synthetic()
        let base = request(image, set: 0)
        let tileCount = base.sprite.rom!.tileCount
        let two = try XCTUnwrap(base.sprite.animations.firstIndex { $0.frames.count >= 2 })
        let cases: [(String, (inout CTSpritePatch.Request) -> Void)] = [
            ("is not below the set", { $0.sprite.frames[0].cells![0] = tileCount }),
            ("bits 11-13", { $0.sprite.frames[0].cells![0] = 0x1001 }),
            ("no OAM flips", { $0.sprite.frames[0].tiles[1].vflip = true }),
            ("16x16 at slot tile 2", { $0.sprite.frames[0].tiles[1].tile = 4 }),
            ("one palette", { $0.sprite.frames[0].tiles[1].pal = 1 }),
            ("signed byte pair", { $0.sprite.frames[0].tiles[0].y = -129 }),
            ("is not 1-255", { $0.sprite.animations[0].durations[0] = 0 }),
            ("is not below", { $0.sprite.animations[0].frames[0] = 0xFF }),
            ("always loop", { $0.sprite.animations[0].loop = false }),
            ("only colours 1-12", { $0.sprite.palettes![0][13] = "0001" }),
            ("frames are written in place", { $0.sprite.frames.removeLast() }),
            ("would not read back as given", { r in
                r.sprite.animations[two].frames.removeLast(); r.sprite.animations[two].durations.removeLast()
            }),
            ("would not read back as given", { r in r.sprite.animations.remove(at: two) }),
            ("blank cell", { $0.sheet[0][9] = 1 }),
            ("the sheet has", { $0.sheet = Array($0.sheet.prefix(10)) }),
            ("re-import", { $0.sprite.rom!.palette = "$E4:0018" }),
            ("is not 0-6", { $0.sprite.rom!.set = 7 }),
        ]
        for (message, change) in cases {
            var r = base
            change(&r)
            XCTAssertThrowsError(try CTSpritePatch.writes([r], base: image), message) { error in
                XCTAssertTrue("\(error)".contains(message), "\(message): \(error)")
            }
        }
        // The same set twice.
        var other = base
        other.sprite.id = "again"
        XCTAssertThrowsError(try CTSpritePatch.writes([base, other], base: image)) { error in
            XCTAssertTrue("\(error)".contains("set 0 is built twice"), "\(error)")
        }
    }

    func testValidatorChecksROMSprites() throws {
        var project = try CTProject.load(from: fixtureURL())
        let image = try synthetic()
        var s = request(image, set: 1).sprite
        s.id = "synth"
        s.frames[0].tiles[0].hflip = true
        project.sprites["synth"] = s
        project.project.rom = Project.ROMBuild(sprites: ["synth", "missing", "synth"])
        let issues = Validator.validate(project).filter { $0.gate == 4 }.map { "\($0.path): \($0.message)" }
        XCTAssertTrue(issues.contains { $0.contains("rom sprite missing") && $0.contains("no sprites/missing.sprite.json") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("sprite built twice") }, "\(issues)")
        XCTAssertTrue(issues.contains { $0.contains("sprites/synth.sprite.json") && $0.contains("no OAM flips") }, "\(issues)")
        // rom.sprites round-trips and stays out of project.json when empty.
        let data = try JSONEncoder().encode(Project.ROMBuild(sprites: ["crono"]))
        XCTAssertEqual(try JSONDecoder().decode(Project.ROMBuild.self, from: data).sprites, ["crono"])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(Project.ROMBuild()), as: UTF8.self).contains("sprites"))
    }

    /// Local ROM: importing all seven sets and building them gives the clean ROM, and an edit writes only its record.
    func testImportThenBuildIsIdentical() throws {
        let rom = [UInt8](try Repo.romData())
        let raw = rom.count == CTROMBuilder.romSize + 512 ? Array(rom.dropFirst(512)) : rom
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctspritepatch-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let ids = try CTSpriteROM.importSprites(rom: raw, into: &project)
        project.project.rom = Project.ROMBuild(sprites: ids)
        let (built, report) = try CTROMBuilder.build(base: raw, project: project)
        XCTAssertTrue(built == raw)
        XCTAssertTrue(report.writes.isEmpty)
        XCTAssertEqual(report.sprites?.count, 7)
        project.sprites["lucca"]!.frames[4].tiles[2].x += 3
        let (edited, report2) = try CTROMBuilder.build(base: raw, project: project)
        XCTAssertEqual(report2.writes.map(\.what), ["sprite lucca frame 4", "checksum"])
        XCTAssertEqual(CTSpriteROM.decode(rom: edited, set: 2).frames[4].pieces[2].x,
                       project.sprites["lucca"]!.frames[4].tiles[2].x)
    }
}
