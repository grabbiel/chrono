// CTDrumKitTests.swift — the @drum kit (docs/music_tracker.md): its bytes, the
// listing edit, the model in drum mode, and the driver on the ROM's kits and
// on an edited kit built through rom.songs. Fixtures are template listings;
// the driver tests read the local clean ROM.
import XCTest
@testable import ChronoForgeCore

final class CTDrumKitTests: XCTestCase {
    /// A template song on samples [1, 2] with track 0 in drum mode.
    func drumListing(kit: CTDrumKit, pads: [(step: Int, pad: Int)]) throws -> String {
        let o = CTSongTemplate.Options(samples: [1, 2], tracks: [.init(slot: 0, octave: 4)], steps: 384)
        let template = try CTSongTemplate.listing(o).replacingOccurrences(of: "    transpose $0A\nLOOP0:",
                                                                          with: "    transpose $0A\n    drums_on\nLOOP0:")
        var doc = CTSongDocument(listing: template)
        doc.setDrumKit(kit)
        for (step, pad) in pads {
            let timeline = try CTSongTimeline(doc, tables: doc.tables)
            // Octave 4 at transpose $0A: number 48 + i is index i, the pad.
            _ = try doc.insertNote(track: 0, step: step, number: 48 + pad, steps: 24, timeline: timeline)
        }
        return doc.listing
    }

    func kit() throws -> CTDrumKit {
        var pads = [CTDrumKit.Pad](repeating: .init(), count: 12)
        pads[0] = .init(sample: 0x20, note: 0x3C, pan: 0x40)
        pads[5] = .init(sample: 0x21, note: 0x48, pan: 0x10)
        pads[7] = .init(sample: 0x20, note: 0x30, pan: 0x80)
        return try CTDrumKit(pads: pads)
    }

    // MARK: Synthetic

    func testBytesListingAndEdit() throws {
        let k = try kit()
        XCTAssertEqual(try CTDrumKit(bytes: k.bytes), k)
        XCTAssertEqual(k.bytes.count, 36)
        XCTAssertEqual(Array(k.bytes[15..<18]), [0x21, 0x48, 0x10])
        XCTAssertEqual(k.listingLines.count, 12)
        XCTAssertEqual(k.listingLines[5], "@drum 5 $21 $48 $10")
        XCTAssertEqual(CTDrumKit.empty.listingLines, ["@drums none"])
        XCTAssertThrowsError(try CTDrumKit(bytes: [0, 0]))
        XCTAssertThrowsError(try CTDrumKit(pads: [CTDrumKit.Pad](repeating: .init(sample: 256), count: 12)))

        let text = try drumListing(kit: k, pads: [])
        var doc = CTSongDocument(listing: text)
        XCTAssertEqual(doc.drumKit, k)
        XCTAssertFalse(text.contains("@drums none"))
        let tables = try CTSongListing.assembleSong(text).tables
        XCTAssertEqual(tables.drums, k.bytes)
        // Back to none, and again: the lines are replaced where they were.
        doc.setDrumKit(.empty)
        XCTAssertEqual(doc.drumKit, .empty)
        XCTAssertEqual(doc.listing.components(separatedBy: "@drum").count, 2)
        doc.setDrumKit(k)
        XCTAssertEqual(doc.listing, text)
        // A listing without a kit row gets one after @echo.
        var bare = CTSongDocument(listing: text.split(separator: "\n").filter { !$0.hasPrefix("@drum") }.joined(separator: "\n"))
        XCTAssertNil(bare.drumKit)
        bare.setDrumKit(k)
        let lines = bare.listing.split(separator: "\n")
        let echo = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("@echo") })
        XCTAssertEqual(lines[echo + 1], "@drum 0 $20 $3C $40")
    }

    func testPadFieldsAndProblems() throws {
        let k = try kit()
        XCTAssertEqual(k.pads[5].slot, 1)
        XCTAssertEqual(k.pads[5].number(), 0x48)
        XCTAssertEqual(k.pads[5].number(transpose: 0x0C), 0x4A)
        XCTAssertEqual(k.pads[5].panRegister, 0x20)
        XCTAssertNil(k.pads[7].panRegister)
        XCTAssertTrue(k.pads[1].isEmpty)
        XCTAssertEqual(k.problems(listed: 2), [])
        XCTAssertEqual(k.problems(listed: nil), [])
        var bad = k
        bad.pads[3] = .init(sample: 0x22, note: 0x30, pan: 0x40)
        bad.pads[4] = .init(sample: 0x10, note: 0x30, pan: 0x40)
        bad.pads[6] = .init(sample: 0x20, note: 0x80, pan: 0x40)
        let problems = bad.problems(listed: 2)
        XCTAssertEqual(problems.count, 3, "\(problems)")
        XCTAssertTrue(problems[0].contains("drum 3: sample $22 is past the song's 2 listed samples"), problems[0])
        XCTAssertTrue(problems[1].contains("drum 4: sample $10"), problems[1])
        XCTAssertTrue(problems[2].contains("drum 6: note $80"), problems[2])
    }

    func testModelPlaysThePads() throws {
        let text = try drumListing(kit: try kit(), pads: [(0, 0), (48, 5), (96, 7), (144, 0)])
        let doc = CTSongDocument(listing: text)
        let timeline = try CTSongTimeline(doc, tables: doc.tables)
        let notes = timeline.tracks[0].notes
        XCTAssertEqual(notes.map(\.start), [0, 48, 96, 144])
        XCTAssertTrue(notes.allSatisfy(\.drum))
        XCTAssertEqual(notes.map(\.sample), [0x20, 0x21, 0x20, 0x20])
        XCTAssertEqual(notes.map(\.number), [0x3C, 0x48, 0x30, 0x3C])
        // Pad 7 keeps the pan pad 5 left; pad 0 sets $40 again.
        XCTAssertEqual(notes.map(\.pan), [0x40, 0x10, 0x10, 0x40])
    }

    func testValidatorChecksKitsAndImportedSongs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctdrums-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let songs = dir.appendingPathComponent("audio/songs")
        try FileManager.default.createDirectory(at: songs, withIntermediateDirectories: true)
        // A good kit; an imported MIDI song; a bad kit on 70 (not appended) with the song volume at 0.
        try Data(try drumListing(kit: try kit(), pads: [(0, 0)]).utf8).write(to: songs.appendingPathComponent("good.ctsong"))
        let (midi, _) = try CTMIDIImport.convert(try CTMIDIFile(bytes: CTMIDIImportTests.fixture()), options: CTMIDIImportTests.options())
        try Data(midi.utf8).write(to: songs.appendingPathComponent("midi.ctsong"))
        var bad = try kit()
        bad.pads[2] = .init(sample: 0x22, note: 0x30, pan: 0x40)
        bad.pads[3] = .init(sample: 0x20, note: 0x70, pan: 0x40)
        let badText = try drumListing(kit: bad, pads: []).replacingOccurrences(of: "@samples 1 2", with: "@samples 1 70")
            .replacingOccurrences(of: "@echo $00 $FF", with: "@echo $00 $00")
        try Data(badText.utf8).write(to: songs.appendingPathComponent("bad.ctsong"))
        var spec = Project.ROMBuild()
        spec.songs = [.init(song: 2, listing: "audio/songs/good.ctsong"), .init(song: 3, listing: "audio/songs/midi.ctsong"),
                      .init(song: 4, listing: "audio/songs/bad.ctsong")]
        project.project.rom = spec
        let issues: [ValidationIssue] = Validator.validate(project).filter { $0.path.hasPrefix("project.json rom song") }
        let messages: [String] = issues.map { "\($0.path): \($0.message)" }
        XCTAssertFalse(messages.contains { $0.contains("song 2:") || $0.contains("song 3:") }, "\(messages)")
        for e in ["@samples 70 is neither", "drum 2: sample $22 is past the song's 2 listed samples", "drum 3: note $70 is outside",
                  "byte 1 (the song volume, Spc_Unk4D) is $00"] {
            XCTAssertTrue(messages.contains { $0.contains("song 4:") && $0.contains(e) }, "\(e) not in \(messages)")
        }
        let warnings = issues.filter { $0.severity == .warning }.map(\.message)
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
    }

    // MARK: The driver (local ROM)

    func clean() throws -> [UInt8] { [UInt8](try Repo.romData()) }

    /// The ROM's kits: in every song whose tracks turn drum mode on within
    /// the first steps, each drum note keys on with its pad's sample, note
    /// and pan, as Spc_DrumNote gives them.
    func testTheROMsKitsAreSpcDrumNote() throws {
        let rom = try clean()
        let songs = try CTSong.romSongs(rom)
        var traced = 0, notes = 0
        for i in songs.indices {
            let tables = CTSongTables.rom(rom, song: i)
            guard let drums = tables.drums, drums.contains(where: { $0 != 0 }) else { continue }
            let listing = try CTSongListing.render(try CTSong(data: songs[i].data), tables: tables)
            let doc = CTSongDocument(listing: listing)
            var options = CTSongTimeline.Options(untilLoop: false, maxSteps: 400)
            options.set = 0
            let timeline = try CTSongTimeline(doc, tables: tables, options: options)
            guard timeline.tracks.contains(where: { $0.notes.contains { $0.drum && $0.keyOn && $0.start < 399 } }) else { continue }
            let result = try CTDrumKitTrace.run(clean: rom, built: rom, song: i, listing: listing, steps: 400)
            XCTAssertTrue(result.passed, String(format: "song $%02X: %@", i, result.mismatches.prefix(4).joined(separator: "; ")))
            traced += 1; notes += result.matched
            if traced == 4 { break }
        }
        XCTAssertEqual(traced, 4)
        XCTAssertGreaterThan(notes, 100)
    }

    /// An edited kit, built through rom.songs: the driver keys the edited
    /// pad on with its sample, note and pan, at the model's steps.
    func testAnEditedKitBuildsAndPlays() throws {
        let rom = try clean()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctdrums-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let text = try drumListing(kit: try kit(), pads: [(0, 0), (48, 5), (96, 7), (144, 5)])
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio/songs"), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("audio/songs/drums.ctsong"))
        var spec = Project.ROMBuild()
        spec.songs = [.init(song: 2, listing: "audio/songs/drums.ctsong")]
        project.project.rom = spec
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        XCTAssertEqual(report.songs.first?.drums, try kit().bytes.map(Int.init))
        XCTAssertEqual(report.budgets?.first?.fits, true)
        XCTAssertEqual(CTSongTables.rom(built, song: 2).drums, try kit().bytes)

        let result = try CTDrumKitTrace.run(clean: rom, built: built, song: 2, listing: text, steps: 200)
        XCTAssertTrue(result.passed, "\(result.mismatches)")
        XCTAssertEqual(result.drumNotes, 4)
        let voice0: [CTDrumKitTrace.KeyOn] = result.keyOns.filter { $0.voice == 0 }
        XCTAssertEqual(voice0.map(\.step), [0, 48, 96, 144])
        XCTAssertEqual(voice0.map(\.sample), [0x20, 0x21, 0x20, 0x21])
        XCTAssertEqual(voice0.map(\.number), [0x3C, 0x48, 0x30, 0x48])
        XCTAssertEqual(voice0.map(\.pan), [0x80, 0x20, 0x20, 0x20])
    }
}
