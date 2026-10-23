// CTProjectAuditionTests.swift — auditions that play the project's samples
// (docs/sfx_lab.md): a scratch ROM built in memory with rom.samples and the
// audition listing, then the driver's song load. The sample is a generated
// tone; the tests read the local clean ROM.
import XCTest
@testable import ChronoForgeCore

final class CTProjectAuditionTests: XCTestCase {
    /// The largest |sample|: a loop, for CI's older type checker (Xcode 26.6).
    static func peak(_ pcm: [Int16]) -> Int {
        var top = 0
        for s in pcm { top = max(top, abs(Int(s))) }
        return top
    }

    /// A project whose rom.samples appends a looping 32 kHz tone as sample 63.
    func project() throws -> (CTProject, URL, [UInt8]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctaudition-\(UUID().uuidString).ctproj")
        try FileManager.default.copyItem(at: fixtureURL(), to: dir)
        var project = try CTProject.load(from: dir)
        let report = try SFXSynth.encode(SynthSpec(wave: .sine, frequency: 523.25, rate: 32000, loop: true))
        var meta = report.meta
        meta.adsr = [15, 7, 7, 0]
        meta.brr = "audio/samples/lead.brr"
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("audio/samples"), withIntermediateDirectories: true)
        try Data(SFXImport.fileBytes(report.encoded.blocks)).write(to: dir.appendingPathComponent(meta.brr))
        project.samples["lead"] = meta
        var spec = Project.ROMBuild()
        spec.samples = [.init(id: "lead")]
        project.project.rom = spec
        let brr = try CTROMBuilder.sampleRequest(spec.samples[0], project: project).brr
        return (project, dir, brr)
    }

    func files(_ dir: URL) -> [String] {
        (FileManager.default.enumerator(atPath: dir.path)?.allObjects as? [String] ?? []).sorted()
    }

    func testTheRackAuditionDecodesTheProjectSample() throws {
        let rom = [UInt8](try Repo.romData())
        let (project, dir, brr) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        let before = files(dir)
        // The rack of a song listing [7, 63]: slot 1 is the project sample.
        let tables = CTSongTables(samples: [7, 63], echo: [0, 0xFF])
        let listing = CTSongInstrument.audition(slot: 1, number: 60, tables: tables)
        // The playback ROM alone has no sample 63.
        XCTAssertThrowsError(try SPCStream.ctSong(rom: rom, replacing: 2, data: try CTSongListing.assembleSong(listing).data, tables: tables))

        let scratch = try CTProjectAudition.rom(base: rom, project: project, listing: listing, song: 2)
        let probe = try CTSampleProbe.run(clean: rom, built: scratch, song: 2, sample: 63, frames: 2048)
        let failed: [String] = probe.checks.filter { !$0.passed }.map { $0.name }
        XCTAssertTrue(probe.passed, "\(failed)")
        XCTAssertEqual(probe.voice, 0)
        XCTAssertEqual(probe.decodedSamples, min(2048, brr.count / 9 * 16))
        XCTAssertEqual(probe.note, 60)

        // The stream the Studio plays loads the same bytes and sounds.
        let stream = try CTProjectAudition.stream(base: rom, project: project, listing: listing, song: 2)
        let at = probe.aram
        XCTAssertEqual(Array(stream.bus.ram[at..<(at + brr.count)]), brr)
        let pcm = try stream.render(frames: 8000)
        XCTAssertGreaterThan(Self.peak(pcm), 1000)
        // The @echo row's byte 1 is the song volume (!Spc_Unk4D): at 0 the same audition is silent.
        let quiet = CTSongInstrument.audition(slot: 1, number: 60, tables: CTSongTables(samples: [7, 63], echo: [0, 0]))
        let silent = try CTProjectAudition.stream(base: rom, project: project, listing: quiet, song: 2).render(frames: 8000)
        XCTAssertEqual(Self.peak(silent), 0)
        XCTAssertEqual(files(dir), before, "an audition writes no file")
    }

    func testADrumPadAuditionPlaysTheProjectSample() throws {
        let rom = [UInt8](try Repo.romData())
        let (project, dir, _) = try project()
        defer { try? FileManager.default.removeItem(at: dir) }
        var pads = [CTDrumKit.Pad](repeating: .init(), count: 12)
        pads[3] = .init(sample: 0x21, note: 60, pan: 0x20)
        let kit = try CTDrumKit(pads: pads)
        let listing = CTProjectAudition.pad(3, kit: kit, tables: CTSongTables(samples: [7, 63], echo: [0, 0xFF]))
        let scratch = try CTProjectAudition.rom(base: rom, project: project, listing: listing, song: 2)
        let probe = try CTSampleProbe.run(clean: rom, built: scratch, song: 2, sample: 63, frames: 1024)
        let failed: [String] = probe.checks.filter { !$0.passed }.map { $0.name }
        XCTAssertTrue(probe.passed, "\(failed)")
        XCTAssertEqual(probe.note, 60)
        let keyOns = try CTDrumKitTrace.run(clean: rom, built: scratch, song: 2, listing: listing, steps: 20)
        XCTAssertTrue(keyOns.passed, "\(keyOns.mismatches)")
        XCTAssertEqual(keyOns.keyOns.first.map { [$0.sample, $0.number, $0.pan] }, [0x21, 60, 0x40])
    }
}
