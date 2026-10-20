// CTProjTests.swift — fixture loads, all 6 gates pass, corruption is caught.
import XCTest
@testable import ChronoForgeCore

final class CTProjTests: XCTestCase {
    var fixture: URL!

    override func setUpWithError() throws {
        fixture = try fixtureURL()
    }

    func testFixtureLoads() throws {
        let p = try CTProject.load(from: fixture)
        XCTAssertEqual(p.project.name, "My Game")
        XCTAssertEqual(p.project.schema, "ctproj/1")
        XCTAssertEqual(p.characters.count, 2)
        XCTAssertEqual(p.sprites.count, 1)
        XCTAssertEqual(p.items.count, 1)
        XCTAssertEqual(p.techs.count, 1)
        XCTAssertEqual(p.tracks.count, 1)
        XCTAssertEqual(p.samples.count, 1)
        XCTAssertEqual(p.tilesets.count, 1)
        XCTAssertEqual(p.maps.count, 2)
        XCTAssertEqual(p.scenes.count, 1)
        XCTAssertEqual(p.dialogue.strings.count, 3)
    }

    func testFixturePassesAllSixGates() throws {
        let p = try CTProject.load(from: fixture)
        let issues = Validator.validate(p)
        let errors = issues.filter { $0.severity == .error }
        XCTAssertTrue(errors.isEmpty, "unexpected errors:\n" + errors.map(\.description).joined(separator: "\n"))
        XCTAssertTrue(Validator.isValid(issues))
    }

    /// Corrupt one reference -> validator reports it (gate 1).
    func testCorruptedReferenceIsReported() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Corrupt-\(UUID().uuidString).ctproj")
        try copyFixture(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let projURL = tmp.appendingPathComponent("project.json")
        var p = try CTProject.load(from: tmp)
        p.project.start.map = "nowhere"
        try CTProject.jsonEncoder.encode(p.project).write(to: projURL)
        let reloaded = try CTProject.load(from: tmp)
        let issues = Validator.validate(reloaded)
        XCTAssertTrue(issues.contains { $0.gate == 1 && $0.severity == .error
            && $0.message.contains("nowhere") },
            "validator missed the corrupted start.map reference")
    }

    /// Corrupt an OAM budget (gate 2).
    func testOAMBudgetEnforced() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("OAM-\(UUID().uuidString).ctproj")
        try copyFixture(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var p = try CTProject.load(from: tmp)
        var sprite = p.sprites["robo"]!
        sprite.frames[0].tiles = (0..<600).map { _ in sprite.frames[0].tiles[0] }
        p.sprites["robo"] = sprite
        try CTProject.jsonEncoder.encode(sprite)
            .write(to: tmp.appendingPathComponent("sprites/robo.sprite.json"))
        let issues = Validator.validate(try CTProject.load(from: tmp))
        XCTAssertTrue(issues.contains { $0.gate == 2 && $0.severity == .error })
    }

    /// Save -> load round-trip keeps the document equal.
    func testSaveLoadRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("RT-\(UUID().uuidString).ctproj")
        try copyFixture(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let loaded = try CTProject.load(from: tmp)
        try loaded.save()
        let again = try CTProject.load(from: tmp)
        XCTAssertEqual(loaded.project, again.project)
        XCTAssertEqual(loaded.characters, again.characters)
        XCTAssertEqual(loaded.sprites, again.sprites)
        XCTAssertEqual(loaded.maps, again.maps)
        XCTAssertEqual(loaded.scenes, again.scenes)
        XCTAssertEqual(loaded.dialogue, again.dialogue)
    }

    /// Gate 5: text codec round-trip on the fixture strings directly.
    func testTextCodecRoundTrip() throws {
        let p = try CTProject.load(from: fixture)
        for (k, v) in p.dialogue.strings {
            XCTAssertEqual(TextCodec.decode(TextCodec.encode(v)), v, "string \(k)")
        }
    }

    /// Gate 4: bytecode round-trip on the fixture scene directly.
    func testEventBytecodeRoundTrip() throws {
        let p = try CTProject.load(from: fixture)
        let sc = p.scenes["intro"]!
        let code = try EventBytecode.compile(sc.scene.funcs)
        let back = try EventBytecode.decompile(code)
        XCTAssertEqual(back, sc.scene.funcs)
    }

    /// Gate 1 PNG checks: fixture sprite sheet is mode P, 4bpp, <=16 colors.
    func testFixtureSheetPNGFormat() throws {
        let p = try CTProject.load(from: fixture)
        let png = try PNG.readIndexed(url: p.fileURL(relative: "sprites/robo.png"))
        XCTAssertEqual(png.bitDepth, 4)
        XCTAssertLessThanOrEqual(png.colorsUsed, 16)
        XCTAssertEqual(png.width, 16)
    }

    private func copyFixture(to dst: URL) throws {
        try FileManager.default.copyItem(at: fixture, to: dst)
    }
}
