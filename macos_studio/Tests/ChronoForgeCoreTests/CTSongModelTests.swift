// CTSongModelTests.swift — the ct-song/1 event model: lossless listing items,
// the timeline (steps, loops, legato, drums, wait), the tempo map, tracker
// edits, and (with the local ROM) every song round trip and driver key-ons.
import XCTest
@testable import ChronoForgeCore

final class CTSongModelTests: XCTestCase {
    /// A synthetic listing: `bodies[k]` is track k's statements under label T<k>.
    private func listing(_ bodies: [String], extra: String = "") -> String {
        let tracks = (0..<16).map { i in "@track \(i < 8 ? "A" : "B") \(i % 8) \(i < bodies.count ? "T\(i)" : "-")" }
        let code = bodies.enumerated().map { k, body in "T\(k):\n" + body }.joined(separator: "\n")
        return (["; synthetic", "@origin $1000", "@notrack $FFFF"] + tracks).joined(separator: "\n") + "\n" + code + "\n" + extra
    }

    private func timeline(_ text: String, _ options: CTSongTimeline.Options = .init()) throws -> CTSongTimeline {
        try CTSongTimeline(CTSongDocument(listing: text), options: options)
    }

    func testDocumentWritesBackItsTextAndBytes() throws {
        let text = listing(["""
            tempo $40        ; a comment
            octave $04
          note C# 48
            tie 24
            rest 96
            jump ->T0
        """, "    end"])
        let doc = CTSongDocument(listing: text)
        XCTAssertEqual(doc.listing, text)
        XCTAssertEqual(try doc.assemble().data, try CTSongListing.assemble(text))
        XCTAssertEqual(doc.trackLabels.prefix(3), ["T0", "T1", nil])
        XCTAssertEqual(doc.statement(doc.labels["T0"]! + 3), .note(semitone: 1, steps: 48))
        // A line the model does not understand stays text, and the assembler reports it.
        let bad = CTSongDocument(listing: text.replacingOccurrences(of: "rest 96", with: "rest 95"))
        XCTAssertTrue(bad.items.contains(.text("    rest 95")))
        XCTAssertThrowsError(try bad.assemble())
    }

    func testTimelineStepsNotesTiesRestsAndWait() throws {
        let t = try timeline(listing(["""
            octave $04
            note C 48
            tie 24
            rest 12
            transpose $02
            wait $05
            note E 3
            octave_up
            note B 6
            end
        """]))
        let notes = t.tracks[0].notes
        XCTAssertEqual(notes.map(\.start), [0, 84, 89])
        XCTAssertEqual(notes.map(\.length), [72, 5, 6])
        XCTAssertEqual(notes.map(\.number), [48 - 10, 48 + 4 + 2 - 10, 60 + 11 + 2 - 10])
        XCTAssertEqual(notes[0].ties.count, 1)
        XCTAssertEqual(t.tracks[0].stop, "end")
        XCTAssertEqual(t.tracks[0].endStep, 95)
        XCTAssertEqual(CTSongTimeline.noteName(49), "C#4")
    }

    func testLoopsBranchAndLoopJumpFollowTheDriver() throws {
        // loop_start n plays n + 1 passes; loop_jump leaves on the given pass;
        // branch jumps only when !Spc_SongCond (0 at a song start) >= v & $0F.
        let t = try timeline(listing(["""
            loop_start $02
            note C 12
            loop_jump $02 ->OUT
            note D 12
            loop_end
        OUT:
            branch $01 ->T0
            branch $00 ->SKIP
            note E 96
        SKIP:
            note F 24
            end
        """]))
        let semitones = t.tracks[0].notes.map(\.semitone)
        XCTAssertEqual(semitones, [0, 2, 0, 5])
        var cond = CTSongTimeline.Options()
        cond.songCondition = 1
        XCTAssertThrowsError(try timeline(listing(["""
            branch $01 ->T0
            end
        """]), cond))  // jumps to itself forever without a note
    }

    func testSongLoopIsFoundByItsPeriod() throws {
        let t = try timeline(listing(["""
            tempo $50
            note C 48
        LOOP:
            loop_start $01
            note D 24
            loop_end
            loop_start $07     ; left open each pass, as one ROM song does
            note E 12
            jump ->LOOP
        """]))
        let track = t.tracks[0]
        XCTAssertEqual(track.stop, "loop")
        XCTAssertEqual(track.loopStart, 48)
        XCTAssertEqual(track.loopEnd, 48 + 60)
        XCTAssertEqual(track.notes.map(\.start), [0, 48, 72, 96])
        // Unrolled, the loop keeps going to the step limit.
        let long = try timeline(listing(["    note C 48\n    jump ->T0"]), .init(untilLoop: false, maxSteps: 480))
        XCTAssertEqual(long.tracks[0].notes.count, 10)
        XCTAssertEqual(long.tracks[0].stop, "limit")
    }

    func testLegatoKeysOnOnlyItsFirstNote() throws {
        let t = try timeline(listing(["""
            legato_on
            note C 12
            note D 12
            note E 12
            rest 12
            note F 12
            legato_on
            note G 12
            unk60_on
            note A 12
            sample $20
            note B 12
            end
        """]))
        // Under legato only the first note keys on; the rest ends it; a new
        // legato_on keys on its first note again; unk60_on and sample's
        // look-ahead (which ends legato) key on.
        XCTAssertEqual(t.tracks[0].notes.map(\.keyOn), [true, false, false, true, true, true, true])
        XCTAssertEqual(t.tracks[0].notes.last?.sample, 0x20)
    }

    func testDrumModeTakesTheKitsSampleNoteAndPan() throws {
        var drums = [UInt8](repeating: 0, count: 36)
        drums[3 * 2 + 0] = 0x24; drums[3 * 2 + 1] = 0x3C; drums[3 * 2 + 2] = 0x20
        drums[3 * 4 + 0] = 0x25; drums[3 * 4 + 1] = 0x30; drums[3 * 4 + 2] = 0x80
        let text = listing(["""
            pan $40
            drums_on
            note D 12
            note E 12
            drums_off
            note C 12
            end
        """])
        let t = try CTSongTimeline(CTSongDocument(listing: text), tables: .init(drums: drums))
        let notes = t.tracks[0].notes
        XCTAssertEqual(notes.map(\.sample), [0x24, 0x25, 0x25])
        XCTAssertEqual(notes.map(\.number), [0x3C - 10, 0x30 - 10, (0 + 0 - 10) & 0xFF])
        XCTAssertEqual(notes.map(\.pan), [0x20, 0x20, 0x20])
        XCTAssertEqual(notes.map(\.drum), [true, true, false])
    }

    func testTempoMapFollowsTheAccumulator() throws {
        // Tempo byte t gives t + t x 20 / 256 per pass; a step on each carry.
        let t = try timeline(listing(["    tempo $40\n    note C 192\n    end"]))
        let map = CTSongTempoMap(t, steps: 6)
        // Start: tempo 1, accumulator $FF: step 0 in pass 0; then 69 per pass
        // from $00: carries at passes 4 (276), 8 (552), 12 (828)...
        XCTAssertEqual(map.passOfStep, [0, 4, 8, 12, 15, 19])
        XCTAssertEqual(map.seconds(atStep: 2), 8 * 42.0 / 8000.0, accuracy: 1e-9)
        XCTAssertEqual(map.step(atSeconds: map.seconds(atStep: 4)), 4)
        // A fade over 4 steps: the word moves by (target - tempo) / 4 a step.
        let f = try timeline(listing(["    tempo $40\n    tempo_fade $04 $80\n    note C 192\n    end"]))
        let fade = CTSongTempoMap(f, steps: 4)
        XCTAssertEqual(fade.passOfStep.count, 4)
        XCTAssertLessThan(fade.passOfStep[3], map.passOfStep[3])
    }

    func testDurationsCoverEveryLength() {
        XCTAssertEqual(CTSongDocument.durations(for: 72), [72])
        XCTAssertEqual(CTSongDocument.durations(for: 7), [4, 3])
        XCTAssertEqual(CTSongDocument.durations(for: 200)?.reduce(0, +), 200)
        XCTAssertNil(CTSongDocument.durations(for: 5))
        XCTAssertNil(CTSongDocument.durations(for: 1))
    }

    private let editable = """
            octave $04
            note C 24
            rest 48
            note E 24
            rest 96
            jump ->T0
        """

    func testEditsKeepLaterNotesInPlace() throws {
        var doc = CTSongDocument(listing: listing([editable]))
        var t = try CTSongTimeline(doc)
        let first = t.tracks[0].notes[0]
        try doc.setLength(first, 36)                          // grows into the rest
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].notes.map(\.start), [0, 72])
        XCTAssertEqual(t.tracks[0].notes[0].length, 36)
        try doc.setLength(t.tracks[0].notes[0], 5)            // a length only `wait` makes
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].notes.map(\.start), [0, 72])
        XCTAssertEqual(t.tracks[0].notes[0].length, 5)
        XCTAssertThrowsError(try doc.setLength(t.tracks[0].notes[0], 80))   // past the next note
        try doc.setLength(t.tracks[0].notes[0], 80, shift: true)
        XCTAssertEqual(try CTSongTimeline(doc).tracks[0].notes.map(\.start), [0, 80])
        _ = try doc.assemble()
    }

    func testInsertMoveDeleteAndControls() throws {
        var doc = CTSongDocument(listing: listing([editable]))
        let before = doc.listing
        var t = try CTSongTimeline(doc)
        let item = try doc.insertNote(track: 0, step: 120, number: 48 - 10 + 7, steps: 12, timeline: t)
        t = try CTSongTimeline(doc)
        XCTAssertEqual(doc.statement(item), .note(semitone: 7, steps: 12))
        XCTAssertEqual(t.tracks[0].notes.map(\.start), [0, 72, 120])
        XCTAssertEqual(t.tracks[0].loopEnd, 192)
        // An octave above the base: octave_up / octave_down go around it.
        try doc.insertNote(track: 0, step: 24, number: 48 - 10 + 14, steps: 24, timeline: t)
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].notes.first { $0.start == 24 }?.number, 48 - 10 + 14)
        XCTAssertEqual(t.tracks[0].notes.first { $0.start == 72 }?.number, 48 - 10 + 4)
        XCTAssertThrowsError(try doc.insertNote(track: 0, step: 10, number: 40, steps: 12, timeline: t))
        // Move the inserted G to step 150 and up a semitone, then delete it.
        let g = t.tracks[0].notes.first { $0.start == 120 }!
        try doc.moveNote(g, toStep: 150, number: g.number + 1)
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].notes.map(\.start), [0, 24, 72, 150])
        XCTAssertEqual(t.tracks[0].notes[3].semitone, 8)
        try doc.deleteNote(t.tracks[0].notes[3])
        try doc.setSemitone(t.tracks[0].notes[0].item, 2)
        try doc.setControl(before: t.tracks[0].notes[0].item, "volume", 0x50)
        try doc.setControl(before: t.tracks[0].notes[0].item + 1, "volume", 0x60)   // replaces, does not stack
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].notes.map(\.start), [0, 24, 72])
        XCTAssertEqual(t.tracks[0].notes[0].volume, 0x60)
        XCTAssertEqual(t.tracks[0].notes[0].semitone, 2)
        XCTAssertEqual(doc.items.filter { if case .statement(.command(0xC4, _, _), _) = $0 { return true } else { return false } }.count, 1)
        _ = try doc.assemble()
        // Untouched lines keep their text.
        XCTAssertTrue(doc.listing.hasPrefix(before.components(separatedBy: "T0:")[0]))
    }

    func testLoopMarkers() throws {
        var doc = CTSongDocument(listing: listing([editable]))
        var t = try CTSongTimeline(doc)
        let notes = t.tracks[0].notes
        try doc.insertLoop(from: notes[0].item, through: notes[0].item + 1, passes: 3)
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].notes.map(\.start), [0, 72, 144, 216])
        let loop = t.tracks[0].events.first { $0.statement.name == "loop_start" }!.item
        try doc.setLoopPasses(loop, 2)
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].notes.count, 3)
        try doc.setSongLoop(track: t.tracks[0], at: t.tracks[0].notes[2].item)
        t = try CTSongTimeline(doc)
        XCTAssertEqual(t.tracks[0].loopStart, 144)
        XCTAssertEqual(t.tracks[0].loopEnd, 264)
        _ = try doc.assemble()
    }

    func testEchoResponseAndSettings() throws {
        // FIR0 applies to the oldest of eight buffered samples: the first echo
        // comes back EDL x 512 + 7 samples later, then again through the feedback.
        let taps: [Int8] = [127, 0, 0, 0, 0, 0, 0, 0]
        let ir = CTSongEcho.impulseResponse(taps: taps, edl: 2, efb: 64, evol: 64, samples: 4096)
        XCTAssertEqual(ir.firstIndex { $0 != 0 }, 1031)
        XCTAssertEqual(ir[1031], 127.0 / 128 * 0.5, accuracy: 1e-9)
        XCTAssertEqual(ir[2062], 127.0 / 128 * 0.5 * 127.0 / 128 * 0.5, accuracy: 1e-9)
        let flat = CTSongEcho.frequencyResponse(taps, points: 5)
        XCTAssertTrue(flat.allSatisfy { abs($0.db - 20 * log10(127.0 / 128)) < 1e-9 })
        let lowpass = CTSongEcho.frequencyResponse([0, 0, 0, 0, 32, 32, 32, 32], points: 3)
        XCTAssertGreaterThan(lowpass[0].db, lowpass[2].db + 20)
        XCTAssertEqual(CTSongEcho.buffer(edl: 5), 0xC900..<0xF100)

        var doc = CTSongDocument(listing: listing(["    echo_on\n    note C 48\n    end", "    note D 48\n    end"]))
        var timeline = try CTSongTimeline(doc)
        var echo = CTSongEcho.settings(doc, timeline)
        XCTAssertNil(echo.edl)
        XCTAssertEqual(echo.eon.prefix(3), [true, false, nil])
        try doc.setEchoDelay(4, byte1: 0xC0)
        try doc.setEcho("echo_volume", item: echo.evolItem, value: 0x30)
        try doc.setEcho("fir", item: echo.firItem, value: 2)
        try doc.setTrackEcho(timeline.tracks[1], on: true)
        timeline = try CTSongTimeline(doc)
        echo = CTSongEcho.settings(doc, timeline)
        XCTAssertEqual(echo.edl, 4)
        XCTAssertEqual(echo.songEchoByte1, 0xC0)
        XCTAssertEqual(echo.evol, 0x30)
        XCTAssertEqual(echo.firSet, 2)
        XCTAssertEqual(echo.eon.prefix(2), [true, true])
        try doc.setEcho("echo_volume", item: echo.evolItem, value: 0x10)    // the same statement changes
        XCTAssertEqual(CTSongEcho.settings(doc, try CTSongTimeline(doc)).evol, 0x10)
        XCTAssertEqual(try doc.assemble().tables.echo, [0x04, 0xC0])
    }

    func testAuditionListingPlaysOneNote() throws {
        let text = CTSongInstrument.audition(slot: 2, number: 49, steps: 100, tables: .init(samples: [5, 6, 7]))
        let doc = CTSongDocument(listing: text)
        XCTAssertEqual(try doc.assemble().tables.samples, [5, 6, 7])
        let notes = try CTSongTimeline(doc).tracks[0].notes
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].number, 49)
        XCTAssertEqual(notes[0].length, 100)
        XCTAssertEqual(notes[0].sample, 0x22)
        let tuned = CTSongInstrument(slot: 0, sample: 1, tuning: 0x0040, adsr: 0xE08F, length: 9, loopOffset: 0)
        XCTAssertEqual(tuned.pitchFactor, 1.25, accuracy: 1e-9)
        XCTAssertEqual(tuned.envelope.attack, 15)
        XCTAssertEqual(tuned.envelope.sustainLevel, 7)
        XCTAssertTrue(tuned.envelope.on)
    }

    // MARK: With the local ROM

    private func clean() throws -> [UInt8] {
        guard let rom = try? [UInt8](Repo.romData()) else { throw XCTSkip("local ROM not present") }
        return rom
    }

    func testEveryROMSongRoundTripsThroughTheModel() throws {
        let rom = try clean()
        for s in try CTSong.romSongs(rom) {
            let tables = CTSongTables.rom(rom, song: s.index)
            let listing = try CTSongListing.render(try CTSong(data: s.data), tables: tables)
            let doc = CTSongDocument(listing: listing)
            XCTAssertEqual(doc.listing, listing, "song \(s.index)")
            let back = try doc.assemble()
            XCTAssertEqual(back.data, s.data, "song \(s.index)")
            XCTAssertEqual(back.tables, tables, "song \(s.index)")
            let timeline = try CTSongTimeline(doc, tables: tables)
            for track in timeline.tracks where track.stop != "none" {
                XCTAssertTrue(["loop", "end"].contains(track.stop), "song \(s.index) track \(track.index): \(track.stop)")
            }
        }
    }

    func testROMEchoAndInstrumentTables() throws {
        let rom = try clean()
        let sets = try CTSongEcho.firSets(rom: rom)
        XCTAssertEqual(sets.count, 4)
        XCTAssertTrue(sets.allSatisfy { $0.count == 8 })
        for song in [1, 8] {
            let tables = CTSongTables.rom(rom, song: song)
            let doc = CTSongDocument(listing: try CTSongListing.render(try CTSong(data: CTSong.romSongs(rom)[song].data), tables: tables))
            let echo = CTSongEcho.settings(doc, try CTSongTimeline(doc, tables: tables))
            XCTAssertEqual(echo.edl, Int(tables.echo![0] & 0x0F))
            let rack = try CTSongInstrument.rack(rom: rom, samples: tables.samples!)
            XCTAssertEqual(rack.map(\.sample), tables.samples)
            // The rack's words are the ones a song load sends (CTSPCTransfer.Plan).
            let plan = try CTSPCTransfer.Plan(rom: rom, song: song)
            let paramA = plan.transfers.first { $0.label == "parameters A" }!.bytes
            let paramB = plan.transfers.first { $0.label == "parameters B" }!.bytes
            for i in rack {
                XCTAssertEqual(Int(i.tuning), Int(paramA[2 * i.slot]) | Int(paramA[2 * i.slot + 1]) << 8)
                XCTAssertEqual(Int(i.adsr), Int(paramB[2 * i.slot]) | Int(paramB[2 * i.slot + 1]) << 8)
                XCTAssertEqual(i.length, plan.samples[i.slot].length)
                XCTAssertLessThan(i.loopOffset, i.length)
            }
        }
    }

    /// Key-ons per voice and the pass of every step, model against the driver:
    /// legato, unk60 and wait (song 1), drums and loop_jump (8), branch (24),
    /// tempo fades and wait (29).
    func testModelKeyOnsAndStepTimingMatchTheDriver() throws {
        let rom = try clean()
        for song in [1, 8, 24, 29] {
            let tables = CTSongTables.rom(rom, song: song)
            let doc = CTSongDocument(listing: try CTSongListing.render(try CTSong(data: CTSong.romSongs(rom)[song].data), tables: tables))
            let trace = try CTSongDriverTrace.trace(rom: rom, song: song, steps: 160)
            let comparison = try CTSongDriverTrace.compare(doc, tables: tables, trace: trace)
            XCTAssertTrue(comparison.mismatches.isEmpty, "song \(song): \(comparison.mismatches)")
            XCTAssertEqual(comparison.passMismatches, 0, "song \(song)")
            XCTAssertGreaterThan(comparison.driverKeyOns.reduce(0, +), 0, "song \(song)")
        }
    }

    /// An edit plays on the driver as the model says: a note put into a rest
    /// and a lengthened note, in place of ROM song 2.
    func testEditedSongPlaysAsTheModelSays() throws {
        let rom = try clean()
        let tables = CTSongTables.rom(rom, song: 2)
        var doc = CTSongDocument(listing: try CTSongListing.render(try CTSong(data: CTSong.romSongs(rom)[2].data), tables: tables))
        var timeline = try CTSongTimeline(doc, tables: tables)
        // The first rest of 24 steps or more that is played once and not shared.
        var placed: (track: Int, rest: CTSongTimeline.Event)?
        search: for t in timeline.tracks {
            for rest in t.events where rest.statement.isRest && rest.length >= 24 && rest.step > 0 && rest.step < 120 {
                if (try? doc.insertNote(track: t.index, step: rest.step, number: rest.offset + 3, steps: 12, timeline: timeline)) != nil {
                    placed = (t.index, rest); break search
                }
            }
        }
        let (track, rest) = try XCTUnwrap(placed)
        timeline = try CTSongTimeline(doc, tables: tables)
        XCTAssertTrue(timeline.tracks[track].notes.contains { $0.start == rest.step && $0.length == 12 })
        let (data, edited) = try doc.assemble()
        let trace = try CTSongDriverTrace.trace(rom: rom, song: 2, replacing: data, tables: edited, steps: 140)
        let comparison = try CTSongDriverTrace.compare(doc, tables: edited, trace: trace)
        XCTAssertTrue(comparison.passed, "\(comparison.mismatches)")
        XCTAssertTrue(trace.keyOns.contains { $0.step == rest.step && $0.voices & (1 << track) != 0 })
    }
}
