// CTSongTests.swift — SPC700 song sequences: the ct-song/1 listing, its
// assembler's refusals, every ROM song byte-exact, and songs in the .sfc builder.
import XCTest
@testable import ChronoForgeCore

final class CTSongTests: XCTestCase {
    private func clean() throws -> [UInt8] {
        guard let rom = try? [UInt8](Repo.romData()) else { throw XCTSkip("local ROM not present") }
        return rom
    }

    private func listing(tracks: [String] = ["L_a", "L_b"], body: String? = nil) -> String {
        let lines = (0..<16).map { i in "@track \(i < 8 ? "A" : "B") \(i % 8) \(i < tracks.count ? tracks[i] : "-")" }
        return (["@origin $1000", "@notrack $FFFF"] + lines).joined(separator: "\n") + "\n" + (body ?? """
        L_a:
            tempo $40
            octave $04
            loop_start $02
        L_loop:
            note C 48
            note C# 24     ; a comment
            loop_end
            branch $01 ->L_a
            jump ->L_loop
        L_b:
            rest 192
            end
        """) + "\n"
    }

    // MARK: No ROM

    func testAssembleRenderRoundTrip() throws {
        let data = try CTSongListing.assemble(listing())
        let header: [UInt8] = [0x00, 0x10, 0xFF, 0xFF, 0x00, 0x10, 0x10, 0x10] + [UInt8](repeating: 0xFF, count: 28)
        XCTAssertEqual(data, header + [0xF0, 0x40, 0xD6, 0x04, 0xE2, 0x02, 0x04, 0x15, 0xE3,
                                       0xFA, 0x01, 0x00, 0x10, 0xF6, 0x06, 0x10, 0xB6, 0xEB])
        let song = try CTSong(data: data)
        XCTAssertEqual(try song.walk().count, 10)
        let text = try CTSongListing.render(song)
        XCTAssertTrue(text.contains("L_1006:\n    note C 48\n    note C# 24\n    loop_end\n    branch $01 ->L_1000\n    jump ->L_1006\n"), text)
        XCTAssertEqual(try CTSongListing.assemble(text), data)
    }

    func testUnreachedBytesAndWrappedAddresses() throws {
        // A track address below the origin wraps, as the driver's 16-bit move does.
        var data = try CTSongListing.assemble(listing())
        data += [0xEB]
        let text = try CTSongListing.render(try CTSong(data: data))
        XCTAssertTrue(text.hasSuffix("    end\n@bytes EB\n"), text)
        XCTAssertEqual(try CTSongListing.assemble(text), data)
        let wrapped = listing(body: "L_a:\n    end\nL_b:\n    end\n").replacingOccurrences(of: "@origin $1000", with: "@origin $FFFF")
            .replacingOccurrences(of: "@notrack $FFFF", with: "@notrack $8000")
        let song = try CTSong(data: try CTSongListing.assemble(wrapped))
        XCTAssertEqual(song.tracks[0], 0xFFFF)
        XCTAssertEqual(song.tracks[1], 0x0000)
        XCTAssertEqual(song.offset(0x0000), 0x25)
    }

    func testAssemblerRefusals() {
        let cases: [(String, String)] = [
            (listing(body: "L_a:\n    bogus\nL_b:\n    end"), "unknown statement bogus"),
            (listing(body: "L_a:\n    note C 50\nL_b:\n    end"), "length must be one of"),
            (listing(body: "L_a:\n    note H 48\nL_b:\n    end"), "expected note"),
            (listing(body: "L_a:\n    tempo\nL_b:\n    end"), "tempo takes 1 operand bytes"),
            (listing(body: "L_a:\n    jump $00 $10\nL_b:\n    end"), "with a ->LABEL address"),
            (listing(body: "L_a:\n    tempo ->L_b\nL_b:\n    end"), "is not an address"),
            (listing(body: "L_a:\n    jump ->L_x\nL_b:\n    end"), "undefined label L_x"),
            (listing(body: "L_a:\nL_a:\n    end\nL_b:\n    end"), "defined twice"),
            (listing(body: "L_a:\n    rest 48\n@bytes EB\nL_b:\n    end"), "is reached but written as data"),
            (listing(body: "L_a:\n    rest 48\nL_b:\n    end").replacingOccurrences(of: "@track B 7 -\n", with: ""), "missing @track B 7"),
            (listing(body: "L_a:\n    rest 48\nL_b:\n    end").replacingOccurrences(of: "@notrack $FFFF", with: "@notrack $1001"),
             "equals the @notrack word"),
            (listing(body: "L_a:\n    rest 48"), "undefined label L_b"),
            (listing(body: "L_a:\n    loop_jump $01 ->L_b\nL_b:\n    tempo $01"), "a track reaches $1006, outside the song"),
            (listing(body: "L_a:\n" + String(repeating: "    rest 48\n", count: CTSongISA.maxLength) + "L_b:\n    end"),
             "its transfer would reach $4700"),
        ]
        for (text, expected) in cases {
            XCTAssertThrowsError(try CTSongListing.assemble(text), expected) { error in
                XCTAssertTrue("\(error)".contains(expected), "\(error) does not contain \(expected)")
            }
        }
    }

    func testPerSongTables() throws {
        let drums = (0..<12).map { "@drum \($0) $2\($0 % 10) $4C $\($0 == 3 ? "80" : "40")" }.joined(separator: "\n")
        let text = listing().replacingOccurrences(of: "@notrack $FFFF\n", with: "@notrack $FFFF\n@samples 5 62 1\n@echo $04 $C0\n\(drums)\n")
        let (data, tables) = try CTSongListing.assembleSong(text)
        XCTAssertEqual(data, try CTSongListing.assemble(listing()))
        XCTAssertEqual(tables.samples, [5, 62, 1])
        XCTAssertEqual(tables.echo, [0x04, 0xC0])
        XCTAssertEqual(tables.drums?.count, 36)
        XCTAssertEqual(Array(tables.drums![9...11]), [0x23, 0x4C, 0x80])
        let rows = tables.rows(song: 2)
        XCTAssertEqual(rows.map(\.pc), [CTSongISA.samplesPC + 64, CTSongISA.echoPC + 4, CTSongISA.drumsPC + 72])
        XCTAssertEqual(rows[0].bytes, [5, 0, 62, 0, 1, 0] + [UInt8](repeating: 0, count: 26))
        let again = try CTSongListing.render(try CTSong(data: data), tables: tables)
        XCTAssertTrue(try CTSongListing.assembleSong(again) == (data, tables))
        let none = try CTSongListing.assembleSong(listing().replacingOccurrences(of: "@notrack $FFFF\n", with: "@notrack $FFFF\n@samples none\n@drums none\n")).tables
        XCTAssertEqual(none, CTSongTables(samples: [], drums: [UInt8](repeating: 0, count: 36)))
        XCTAssertTrue(try CTSongListing.render(try CTSong(data: data), tables: none).contains("@samples none\n@drums none\n"))
        for (line, expected) in [("@samples 0", "sample numbers 1-255"), ("@samples 256", "sample numbers 1-255"),
                                 ("@samples +5", "sample numbers 1-255"),
                                 ("@samples " + Array(repeating: "1", count: 17).joined(separator: " "), "1-16 sample numbers"),
                                 ("@echo $04", "@echo $XX $XX"), ("@drum 12 $00 $00 $00", "@drum 0-11"),
                                 ("@drum 0 $00 $00 $00", "all 12 @drum lines"),
                                 ("@drums none\n@drum 0 $00 $00 $00", "given twice"), ("@samples 1\n@samples 2", "given twice")] {
            let bad = listing().replacingOccurrences(of: "@notrack $FFFF\n", with: "@notrack $FFFF\n\(line)\n")
            XCTAssertThrowsError(try CTSongListing.assembleSong(bad), line) { XCTAssertTrue("\($0)".contains(expected), "\($0) for \(line)") }
        }
    }

    func testTransferLimit() {
        XCTAssertEqual(CTSongISA.maxLength, 9983)
        XCTAssertTrue(CTSongISA.fits(9983))
        XCTAssertFalse(CTSongISA.fits(9984))
    }

    func testValidatorChecksSongSettings() throws {
        var project = try CTProject.load(from: fixtureURL())
        project.project.rom = .init(songs: [.init(song: 83, listing: "audio/songs/missing.ctsong"),
                                            .init(song: 2, listing: "../x.ctsong"), .init(song: 2, listing: "a.ctsong")])
        let messages = Validator.validate(project).filter { $0.path.hasPrefix("project.json rom song") }.map(\.description)
        for expected in ["not an Audio_SongTable index", "missing.ctsong not found", "must stay inside the project", "song built twice"] {
            XCTAssertTrue(messages.contains { $0.contains(expected) }, "\(expected) not in \(messages)")
        }
        let json = try JSONEncoder().encode(Project.ROMBuild(eventPacks: [.init(entry: 23, scenes: ["intro"])]))
        XCTAssertFalse(String(decoding: json, as: UTF8.self).contains("songs"))
        XCTAssertEqual(try JSONDecoder().decode(Project.ROMBuild.self, from: Data(#"{"songs":[{"song":1,"listing":"a"}]}"#.utf8)),
                       .init(songs: [.init(song: 1, listing: "a")]))
    }

    // MARK: ROM

    func testEveryROMSongIsByteExactThroughItsListing() throws {
        let songs = try CTSong.romSongs(try clean())
        XCTAssertEqual(songs.count, 83)
        var statements = 0
        for s in songs {
            let song = try CTSong(data: s.data)
            statements += try song.walk().count
            XCTAssertEqual(try CTSongListing.assemble(try CTSongListing.render(song)), s.data, "song \(s.index)")
        }
        XCTAssertEqual(statements, 71_783)
        XCTAssertEqual(songs.filter { $0.data.count >= CTSongISA.songRoom }.map(\.index), [0x3F])
    }

    func testRebuildingEverySongIsIdentical() throws {
        let rom = try clean()
        let requests = try CTSong.romSongs(rom).map { s in
            let text = try CTSongListing.render(try CTSong(data: s.data), tables: CTSongTables.rom(rom, song: s.index))
            let (data, tables) = try CTSongListing.assembleSong(text)
            return CTROMBuilder.SongRequest(song: s.index, source: "rom", data: data, tables: tables)
        }
        let (out, report) = try CTROMBuilder.build(base: rom, requests: [], songs: requests, textProfile: nil)
        XCTAssertTrue(out == rom, "rebuilt ROM differs")
        XCTAssertTrue(report.writes.isEmpty)
        XCTAssertEqual(Set(report.songs.map(\.placement)), ["original"])
    }

    func testEditedSongIsPlacedAndPointedTo() throws {
        let rom = try clean()
        let before = try CTSong.romSongs(rom)
        // Song 1 grows past its old span; song 2 shrinks and stays at home.
        let grown = try CTSongListing.render(try CTSong(data: before[1].data))
            .replacingOccurrences(of: "    echo_on\n", with: "    echo_on\n" + String(repeating: "    rest 96\n", count: 40), options: [], range: nil)
        let shrunk = listing(body: "L_a:\n    rest 192\n    end\nL_b:\n    end")
        let a = try CTSongListing.assemble(grown), b = try CTSongListing.assemble(shrunk)
        XCTAssertGreaterThan(a.count, before[1].data.count)
        let (out, report) = try CTROMBuilder.build(base: rom, requests: [], songs: [
            .init(song: 1, source: "grown", data: a), .init(song: 2, source: "shrunk", data: b)], textProfile: nil)
        let after = try CTSong.romSongs(out)
        XCTAssertEqual(after[1].data, a)
        XCTAssertEqual(after[2].data, b)
        XCTAssertEqual(after[2].pc, before[2].pc)
        XCTAssertEqual(report.songs.first { $0.song == 2 }?.placement, "original")
        XCTAssertNotEqual(report.songs.first { $0.song == 1 }?.placement, "original")
        for s in after where s.index > 2 { XCTAssertEqual(s.data, before[s.index].data) }
        XCTAssertEqual(after[0].data, before[0].data)
        XCTAssertEqual(CTROMBuilder.checksum(out), Int(out[CTROMLayout.checksumPC]) | Int(out[CTROMLayout.checksumPC + 1]) << 8)
        // Every changed byte is inside a reported write.
        for i in out.indices where out[i] != rom[i] {
            XCTAssertTrue(report.writes.contains { ($0.pc..<($0.pc + $0.length)).contains(i) }, String(format: "$%06X", i))
        }
    }

    func testBuilderSongRefusals() throws {
        let rom = try clean()
        let good = try CTSongListing.assemble(listing())
        func refusal(_ songs: [CTROMBuilder.SongRequest]) -> String {
            do { _ = try CTROMBuilder.build(base: rom, requests: [], songs: songs, textProfile: nil); return "" }
            catch { return "\(error)" }
        }
        XCTAssertTrue(refusal([.init(song: 83, source: "", data: good)]).contains("is not 0-82"))
        XCTAssertTrue(refusal([.init(song: 1, source: "", data: good, tables: .init(samples: [63]))]).contains("names sample 63; the ROM has 62"))
        XCTAssertTrue(refusal([.init(song: 1, source: "", data: good, tables: .init(echo: [1]))]).contains("@echo takes 2 bytes"))
        XCTAssertTrue(refusal([.init(song: 1, source: "", data: good), .init(song: 1, source: "", data: good)]).contains("built twice"))
        XCTAssertTrue(refusal([.init(song: 1, source: "", data: good + [UInt8](repeating: 0xEB, count: 9983))]).contains("loads below $4700"))
        var bad = good
        bad[4] = 0x00; bad[5] = 0x20                       // track A0 outside the song
        XCTAssertTrue(refusal([.init(song: 1, source: "", data: bad)]).contains("outside the song"))
    }
}
