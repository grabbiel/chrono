// CTSamplePatchTests.swift — project samples and composed songs in the ROM
// (docs/sfx_lab.md, docs/music_tracker.md). Fixtures are generated tones and
// template listings; the ROM tests read the local clean ROM.
import XCTest
@testable import ChronoForgeCore

final class CTSamplePatchTests: XCTestCase {
    /// A looping sine with an ADSR, as the SFX Lab saves it.
    func tone(frequency: Double = 440, rate: Int = 32000) throws -> (file: [UInt8], meta: SampleMeta) {
        let report = try SFXSynth.encode(SynthSpec(wave: .sine, frequency: frequency, rate: rate, loop: true))
        var meta = report.meta
        meta.adsr = [15, 7, 7, 0]
        return (SFXImport.fileBytes(report.encoded.blocks), meta)
    }

    func request(_ id: String, replace: Int?, songs: [Int], rate: Int = 32000, root: Int = 60) throws -> CTSamplePatch.Request {
        let (file, meta) = try tone(rate: rate)
        let (brr, loop) = try CTSamplePatch.gameBytes(file: file, meta: meta)
        let tune = try XCTUnwrap(CTSampleTuning.solve(rate: rate, rootNote: root))
        return .init(id: id, replace: replace, brr: brr, loopOffset: loop, tuning: tune.tuning,
                     adsr: try XCTUnwrap(CTSamplePatch.adsrWord(meta)), songs: songs, tune: tune)
    }

    // MARK: Synthetic

    func testValidatorChecksSampleSettings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctsamples-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let (file, meta) = try tone()
        let samplesDir = dir.appendingPathComponent("audio/samples")
        try FileManager.default.createDirectory(at: samplesDir, withIntermediateDirectories: true)
        for id in ["tone", "gain", "big"] {
            var m = meta
            m.brr = "audio/samples/\(id).brr"
            if id == "gain" { m.adsr = nil; m.gain = 0x7F }
            if id == "big" { m.loop = false; m.loopStartSample = nil; m.loopEndSample = nil }
            // About 44 KB of silence: more than fits between $4700 and the echo buffer at $F100.
            let silence: [UInt8] = [UInt8](repeating: 0, count: 9 * 4900) + [1, 0, 0, 0, 0, 0, 0, 0, 0]
            let bytes: [UInt8] = id == "big" ? SFXImport.fileBytes(silence) : file
            try Data(bytes).write(to: samplesDir.appendingPathComponent("\(id).brr"))
            project.samples[id] = m
        }
        // A composed song whose own list is the tone; a second song over budget.
        let songsDir = dir.appendingPathComponent("audio/songs")
        try FileManager.default.createDirectory(at: songsDir, withIntermediateDirectories: true)
        let listing = try CTSongTemplate.listing(.init(samples: [1], tracks: [.init(slot: 0)], steps: 96))
        try Data(listing.utf8).write(to: songsDir.appendingPathComponent("a.ctsong"))
        let long = listing.replacingOccurrences(of: "LOOP0:\n", with: "LOOP0:\n" + String(repeating: "    note C 96\n", count: 12000))
        try Data(long.utf8).write(to: songsDir.appendingPathComponent("b.ctsong"))
        var spec = Project.ROMBuild()
        spec.songs = [.init(song: 5, listing: "audio/songs/a.ctsong"), .init(song: 6, listing: "audio/songs/b.ctsong")]
        spec.samples = [.init(id: "tone", songs: [5]), .init(id: "big", songs: [5]), .init(id: "gain"),
                        .init(id: "tone", replace: 3), .init(id: "missing"), .init(id: "x2", replace: 70, songs: [90])]
        project.samples["x2"] = project.samples["tone"]
        project.project.rom = spec
        let messages: [String] = Validator.validate(project).filter { $0.path.hasPrefix("project.json rom") }.map(\.description)
        let expected = ["sample listed twice", "ADSR envelopes only", "no audio/samples/missing.json", "replace takes one of the ROM's samples",
                        "song 90 is not an Audio_SongTable index", "its transfer would reach $4700",
                        "project samples alone take"]
        for e in expected {
            XCTAssertTrue(messages.contains { $0.contains(e) }, "\(e) not in \(messages)")
        }
        // Without the bad entries the settings are valid.
        project.project.rom?.samples = [.init(id: "tone", songs: [5])]
        project.project.rom?.songs = [.init(song: 5, listing: "audio/songs/a.ctsong")]
        let rest: [ValidationIssue] = Validator.validate(project).filter { $0.path.hasPrefix("project.json rom") }
        XCTAssertTrue(rest.isEmpty, "\(rest)")
    }

    func testPitchFormulaFollowsTheDriversSteps() {
        // t = 0, h = 0: the table word, shifted by the octave's distance from 4.
        XCTAssertEqual(CTSampleTuning.pitch(note: 48, tuning: 0), 0x0879)
        XCTAssertEqual(CTSampleTuning.pitch(note: 71, tuning: 0), 0x2000)
        XCTAssertEqual(CTSampleTuning.pitch(note: 36, tuning: 0), 0x0879 >> 1)
        // t below $80 adds P x t / 256 to P; from $80 up it is P x t / 256 alone.
        let p = 0x0879, t = 0x40
        XCTAssertEqual(CTSampleTuning.pitch(note: 48, tuning: t), p + (p >> 8) * t + (((p & 0xFF) * t) >> 8))
        XCTAssertEqual(CTSampleTuning.pitch(note: 48, tuning: 0xC0), (p >> 8) * 0xC0 + (((p & 0xFF) * 0xC0) >> 8))
        // The fine tune adds to the low byte, wrapping.
        XCTAssertEqual(CTSampleTuning.pitch(note: 48, tuning: 0x70, fine: 0x20), CTSampleTuning.pitch(note: 48, tuning: 0x90))
        // The high byte adds under 0.4%.
        let low = CTSampleTuning.pitch(note: 50, tuning: 0x70), high = CTSampleTuning.pitch(note: 50, tuning: 0xFF70)
        XCTAssertGreaterThan(high, low)
        XCTAssertLessThan(Double(high - low) / Double(low), 0.004)
    }

    func testTuningFromARate() throws {
        for (rate, root) in [(32000, 60), (16000, 48), (22050, 60), (11025, 36), (44100, 72)] {
            let s = try XCTUnwrap(CTSampleTuning.solve(rate: rate, rootNote: root), "\(rate) at \(root)")
            XCTAssertEqual(CTSampleTuning.pitch(note: root, tuning: s.tuning), s.pitch)
            // Above octave 4 the octave shift leaves steps of 2^(octave - 4) pitch units.
            XCTAssertLessThan(abs(s.cents), 2.5, "\(rate) Hz at \(root): \(s.cents) cents")
        }
        // A 32 kHz sample cannot sound at its own pitch on note 36: the tuning byte covers x0.5 to x1.5.
        XCTAssertNil(CTSampleTuning.solve(rate: 32000, rootNote: 36))
        let roots = try XCTUnwrap(CTSampleTuning.roots(rate: 32000))
        XCTAssertTrue(roots.contains(60) && !roots.contains(36))
        XCTAssertEqual(CTSampleTuning.defaultRoot(rate: 32000), 60)
        XCTAssertTrue(CTSampleTuning.roots(rate: 8000)!.contains(CTSampleTuning.defaultRoot(rate: 8000)))
    }

    func testRequestChecks() throws {
        let good = try request("tone", replace: nil, songs: [1])
        XCTAssertNoThrow(try CTSamplePatch.check(good))
        func with(brr: [UInt8]? = nil, loop: Int? = nil, adsr: Int? = nil, replace: Int?? = nil, songs: [Int]? = nil,
                  strict: Bool = true) -> CTSamplePatch.Request {
            .init(id: "x", replace: replace ?? good.replace, brr: brr ?? good.brr, loopOffset: loop ?? good.loopOffset,
                  tuning: good.tuning, adsr: adsr ?? good.adsr, songs: songs ?? good.songs, strict: strict)
        }
        var early = good.brr
        early[0] |= 1
        var unended = good.brr
        unended[unended.count - 9] &= 0xFC
        for (r, message) in [(with(brr: Array(good.brr.dropLast())), "whole 9-byte"),
                             (with(brr: early), "end flag before"), (with(brr: unended), "no end flag"),
                             (with(loop: 4), "loop offset"), (with(adsr: 0xE060), "ADSR1 bit 7"),
                             (with(replace: 63), "replace takes"), (with(songs: [1, 1]), "named twice")] {
            XCTAssertThrowsError(try CTSamplePatch.check(r), message) { XCTAssertTrue("\($0)".contains(message), "\($0)") }
        }
        // Bytes kept as they are may carry loop flags on any block.
        var flagged = good.brr
        flagged[0] |= 2
        XCTAssertNoThrow(try CTSamplePatch.check(with(brr: flagged, strict: false)))
    }

    func testGameBytesAreWhatThePreviewPlays() throws {
        let (file, meta) = try tone()
        let (brr, loop) = try CTSamplePatch.gameBytes(file: file, meta: meta)
        let played = try SPCStream.playedBlocks(file: file, meta: meta)
        XCTAssertEqual(brr, played.brr)
        XCTAssertEqual(loop, 9 * played.loopBlock)
        XCTAssertEqual(brr[brr.count - 9] & 3, 3)
        XCTAssertTrue(stride(from: 0, to: brr.count - 9, by: 9).allSatisfy { brr[$0] & 3 == 0 })
    }

    func testTemplateListing() throws {
        let text = try CTSongTemplate.listing(.init(samples: [5, 9], tracks: [.init(slot: 0), .init(slot: 1, octave: 3)], steps: 384))
        let (data, tables) = try CTSongListing.assembleSong(text)
        XCTAssertEqual(tables.samples, [5, 9])
        XCTAssertEqual(tables.echo, [0, 0])
        var doc = CTSongDocument(listing: text)
        let timeline = try CTSongTimeline(doc, tables: tables)
        XCTAssertEqual(timeline.tracks[0].endStep, 384)
        // A note goes into the rests; the template's notes sound 12 x octave + index.
        _ = try doc.insertNote(track: 0, step: 0, number: 60, steps: 48, timeline: timeline)
        _ = try doc.insertNote(track: 1, step: 96, number: 43, steps: 24, timeline: try CTSongTimeline(doc, tables: tables))
        let after = try CTSongTimeline(doc, tables: tables)
        XCTAssertEqual(after.tracks[0].notes.first.map { [$0.start, $0.length] }, [0, 48])
        XCTAssertEqual(after.tracks[1].notes.first.map { [$0.start, $0.length] }, [96, 24])
        XCTAssertGreaterThan(try doc.assemble().data.count, data.count)
        XCTAssertThrowsError(try CTSongTemplate.rests(2))
        XCTAssertThrowsError(try CTSongTemplate.listing(.init(samples: [5], tracks: [.init(slot: 1)])))
    }

    func testBudgetArithmetic() {
        let fits = CTSongBudget.budget(song: 3, sequenceBytes: 4000, samples: [1, 2], lengths: [9000, 9000], start: 0x4901, edl: 5)
        XCTAssertTrue(fits.fits)
        XCTAssertTrue(fits.reachesEffectsBlock)
        XCTAssertEqual(fits.echoStart, 0xF100 - 5 * 0x800)
        let over = CTSongBudget.budget(song: 3, sequenceBytes: 100, samples: [1], lengths: [0xF100 - 0x4901 - 2 * 0x800 + 1],
                                       start: 0x4901, edl: 2)
        XCTAssertFalse(over.fits)
        XCTAssertTrue(over.problem?.contains("1 bytes into the echo buffer") ?? false, over.problem ?? "")
        let long = CTSongBudget.budget(song: 3, sequenceBytes: CTSongISA.maxLength + 1, samples: [], lengths: [], start: 0x4901, edl: 0)
        XCTAssertTrue(long.problem?.contains("below $4700") ?? false)
    }

    // MARK: The ROM

    func clean() throws -> [UInt8] { [UInt8](try Repo.romData()) }

    func testPitchTableIsTheDrivers() throws {
        let ram = try CTSPCDriver.bootImage(rom: try clean()).ram
        XCTAssertEqual((0..<12).map { Int(ram[0x1D6D + 2 * $0]) | Int(ram[0x1D6E + 2 * $0]) << 8 }, CTSampleTuning.pitchTable)
    }

    /// Spc_NotePitch itself, run on the SPC700 from the driver's boot image,
    /// gives CTSampleTuning.pitch for notes, tuning words and fine tunes.
    func testPitchFormulaIsTheDriversNotePitch() throws {
        let image = try CTSPCDriver.bootImage(rom: try clean()).ram
        let bus = try SSMPBus(ram: image, dsp: SDSP())
        let cpu = SPC700(bus: bus)
        let sentinel: UInt16 = 0x0003
        var runs = 0
        for note in stride(from: 0, through: 107, by: 5) {
            for t in stride(from: 0, through: 0xFF, by: 3) {
                for h in [0, 1, 0x55, 0xFF] {
                    for fine in [0, 0x90] {
                        let x = 2 * (runs % 8), tuning = h << 8 | t
                        bus.write(0x00A6, UInt8(x))                               // !Spc_CurTrack
                        bus.write(UInt16(0xF380 + x), UInt8(t)); bus.write(UInt16(0xF381 + x), UInt8(h))
                        bus.write(UInt16(0xF3A0 + x), UInt8(fine))
                        bus.write(0x01F0, UInt8(sentinel & 0xFF)); bus.write(0x01F1, UInt8(sentinel >> 8))
                        cpu.restore(.init(pc: 0x06BD, a: UInt8(note), x: UInt8(x), sp: 0xEF))
                        var steps = 0
                        while cpu.registers.pc != sentinel && steps < 400 { cpu.step(); steps += 1 }
                        XCTAssertEqual(cpu.registers.pc, sentinel)
                        let got = Int(bus.read(0x00B5)) | Int(bus.read(0x00B6)) << 8
                        let want = CTSampleTuning.pitch(note: note, tuning: tuning, fine: fine)
                        if got != want { XCTFail("note \(note) tuning \(String(tuning, radix: 16)) fine \(fine): driver \(got), formula \(want)"); return }
                        runs += 1
                    }
                }
            }
        }
        print("Spc_NotePitch: \(runs) of \(runs) driver runs equal CTSampleTuning.pitch")
    }

    func testTheROMsSampleTables() throws {
        let rom = try clean()
        XCTAssertEqual(try CTSampleTables.locate(rom), CTSampleTables.rom)
        // In bank $C7, the long operands into the four tables are exactly the twelve sites.
        let range = 0xC70AEA..<0xC70D18
        var hits: [Int] = []
        for at in 0x070000..<0x07FFFD where CTSampleTables.opcodes.contains(rom[at]) {
            let operand = Int(rom[at + 1]) | Int(rom[at + 2]) << 8 | Int(rom[at + 3]) << 16
            if range.contains(operand) { hits.append(at + 1) }
        }
        XCTAssertEqual(hits, CTSampleTables.sites.map(\.operand).sorted())
        let entries = try (1...62).map { try CTSampleTables.rom.entry(rom, $0) }
        XCTAssertTrue(entries.allSatisfy { $0.length % 9 == 0 && $0.adsr & 0x80 != 0 })
        // Every ROM song fits its budget (the closest leaves 16 bytes).
        let budgets = try (0..<CTSongISA.romSongCount).map { try CTSongBudget.of(rom: rom, song: $0) }
        XCTAssertTrue(budgets.allSatisfy(\.fits))
        XCTAssertEqual(budgets.map(\.freeBytes).min(), 16)
    }

    /// Every ROM sample written back as it is (and every song from its
    /// listing) builds the clean ROM again.
    func testUnchangedImportRebuildsIdentical() throws {
        let rom = try clean()
        let tables = CTSampleTables.rom
        let samples = try (1...62).map { n -> CTSamplePatch.Request in
            let e = try tables.entry(rom, n)
            return .init(id: "rom_\(n)", replace: n, brr: tables.brr(rom, e), loopOffset: e.loopOffset, tuning: e.tuning,
                         adsr: e.adsr, songs: [], strict: false)
        }
        let songs = try CTSong.romSongs(rom).map { s -> CTROMBuilder.SongRequest in
            let listing = try CTSongListing.render(try CTSong(data: s.data), tables: CTSongTables.rom(rom, song: s.index))
            let (data, t) = try CTSongListing.assembleSong(listing)
            return .init(song: s.index, source: "listing", data: data, tables: t)
        }
        let (built, report) = try CTROMBuilder.build(base: rom, requests: [], songs: songs, samples: samples, textProfile: nil)
        XCTAssertEqual(CTEventPack.sha256(built), CTEventPack.sha256(rom))
        XCTAssertEqual(report.writes, [])
        XCTAssertEqual(report.samples?.count, 62)
        XCTAssertTrue(report.samples!.allSatisfy { $0.placement == "original" })
        XCTAssertEqual(report.budgets?.count, CTSongISA.romSongCount)
    }

    /// A composed song plays a replaced and an appended sample on the real
    /// driver: the load puts both in ARAM, and each voice's pitch and decoded
    /// samples are the ROM tables' words and BRR.
    func testReplacedAndAppendedSamplesPlayInAComposedSong() throws {
        let rom = try clean()
        let song = 2
        let replaced = try request("lead", replace: 7, songs: [])
        let appended = try request("bass", replace: nil, songs: [], rate: 16000, root: 48)
        let o = CTSongTemplate.Options(samples: [7, 63], tracks: [.init(slot: 0, octave: 5), .init(slot: 1, octave: 4)], steps: 384)
        let template = try CTSongTemplate.listing(o)
        var doc = CTSongDocument(listing: template)
        var tables = try CTSongListing.assembleSong(template).tables
        _ = try doc.insertNote(track: 0, step: 0, number: 60, steps: 96, timeline: try CTSongTimeline(doc, tables: tables))
        _ = try doc.insertNote(track: 1, step: 0, number: 48, steps: 96, timeline: try CTSongTimeline(doc, tables: tables))
        let (data, edited) = try doc.assemble()
        tables = edited
        let (built, report) = try CTROMBuilder.build(base: rom, requests: [], songs: [.init(song: song, source: "template", data: data, tables: tables)],
                                                     samples: [replaced, appended], textProfile: nil)
        let located = try CTSampleTables.locate(built)
        XCTAssertEqual(located.count, 63)
        XCTAssertEqual(report.sampleTables?.count, 63)
        let numbers: [Int]? = report.samples?.map { $0.number }
        XCTAssertEqual(numbers, [7, 63])
        XCTAssertEqual(report.samples?.first?.placement, "original")
        // Unedited entries keep their bytes and words where the code now reads them.
        for n in [1, 8, 62] {
            let a = try CTSampleTables.rom.entry(rom, n), b = try located.entry(built, n)
            XCTAssertEqual([a.pointer, a.length, a.loopOffset, a.tuning, a.adsr], [b.pointer, b.length, b.loopOffset, b.tuning, b.adsr])
        }
        for (number, r) in [(7, replaced), (63, appended)] {
            let probe = try CTSampleProbe.run(clean: rom, built: built, song: song, sample: number, frames: 2048)
            let failed: [String] = probe.checks.filter { !$0.passed }.map { $0.name }
            XCTAssertTrue(probe.passed, "\(failed)")
            XCTAssertEqual(probe.decodedSamples, min(2048, r.brr.count / 9 * 16))
            XCTAssertEqual(probe.pitch, r.tune?.pitch)
            XCTAssertEqual(probe.playedRate ?? 0, Double(r.tune!.rate), accuracy: Double(r.tune!.rate) * 0.002)
        }
    }

    func testStudioBudgetAndRackAreTheBuilds() throws {
        let rom = try clean()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctsamples-\(UUID().uuidString).ctproj")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let (file, meta) = try tone(rate: 16000)
        var m = meta
        m.brr = "audio/samples/tone.brr"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio/samples"), withIntermediateDirectories: true)
        try Data(file).write(to: dir.appendingPathComponent(m.brr))
        project.samples["tone"] = m
        var spec = Project.ROMBuild()
        spec.samples = [.init(id: "tone", songs: [2, 0x10], rootNote: 48)]
        project.project.rom = spec
        // Before the build: the clean ROM and the project.
        let planned: [CTSongBudget] = try [2, 0x10].map { try CTProjectSamples.budget(rom: rom, project: project, song: $0) }
        let rack = try CTProjectSamples.rack(rom: rom, samples: planned[0].samples, project: project)
        // The build, and the built ROM's own tables.
        let (built, report) = try CTROMBuilder.build(base: rom, project: project)
        XCTAssertEqual(report.budgets, planned)
        let after: [CTSongBudget] = try [2, 0x10].map { try CTSongBudget.of(rom: built, song: $0) }
        XCTAssertEqual(after, planned)
        XCTAssertEqual(rack, try CTSongInstrument.rack(rom: built, samples: planned[0].samples))
        XCTAssertEqual(rack.last?.sample, 63)
    }

    func testOverBudgetEditsAreRefused() throws {
        let rom = try clean()
        // Song $27 leaves 16 bytes below its echo buffer.
        let big = try request("big", replace: nil, songs: [0x27])
        XCTAssertThrowsError(try CTROMBuilder.build(base: rom, requests: [], samples: [big], textProfile: nil)) {
            XCTAssertTrue("\($0)".contains("into the echo buffer"), "\($0)")
        }
        // The same id twice.
        XCTAssertThrowsError(try CTROMBuilder.build(base: rom, requests: [], samples: [try request("d", replace: 3, songs: []),
                                                                                        try request("d", replace: nil, songs: [])],
                                                    textProfile: nil)) { XCTAssertTrue("\($0)".contains("listed twice"), "\($0)") }
        // A seventeenth sample does not fit a song's list.
        let full = try (0..<CTSongISA.romSongCount).first { CTSongTables.rom(rom, song: $0).samples?.count == 16 }
        if let full {
            XCTAssertThrowsError(try CTROMBuilder.build(base: rom, requests: [], samples: [try request("x", replace: nil, songs: [full])],
                                                        textProfile: nil)) { XCTAssertTrue("\($0)".contains("16 samples"), "\($0)") }
        }
        // A song built from a listing gets the sample after its own @samples row.
        let listing = try CTSongTemplate.listing(.init(samples: [1], tracks: [.init(slot: 0)], steps: 96))
        let (data, tables) = try CTSongListing.assembleSong(listing)
        let (built, report) = try CTROMBuilder.build(base: rom, requests: [], songs: [.init(song: 5, source: "t", data: data, tables: tables)],
                                                     samples: [try request("y", replace: nil, songs: [5])], textProfile: nil)
        XCTAssertEqual(CTSongTables.rom(built, song: 5).samples, [1, 63])
        XCTAssertEqual(report.sampleLists, [.init(song: 5, samples: [1, 63])])
        XCTAssertEqual(report.budgets?.map { $0.song }, [5])
    }
}
