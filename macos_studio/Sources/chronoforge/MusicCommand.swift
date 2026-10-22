import Foundation
import ChronoForgeCore

private let musicUsage = """
usage: chronoforge music list <rom.sfc>
       chronoforge music disasm <rom.sfc> <song> [--out song.ctsong]
       chronoforge music asm <song.ctsong> [--out song.bin]
       chronoforge music verify-rom <rom.sfc>
       chronoforge music spc-info <snapshot.spc> [--out info.json]
       chronoforge music driver-check <rom.sfc> [--ipl ipl.rom] [--out report.json]
       chronoforge music song-load <rom.sfc> <song> [--ipl ipl.rom] [--out report.json]
       chronoforge music render <rom.sfc> <song> [--seconds N] [--ipl ipl.rom] [--out song.wav] [--spc start.spc]
       chronoforge music spc-render <snapshot.spc> [--seconds N] [--ipl ipl.rom] [--voices MASK] [--counter N]
                                                [--timers-first] [--out song.wav]
       chronoforge music play <rom.sfc> <song> [--seconds N] [--ipl ipl.rom] [--volume V]
       chronoforge music events <rom.sfc|song.ctsong> [song] [--json] [--steps N]
       chronoforge music edit <song.ctsong> <roundtrip|semitone|length|delete|insert|control> ... [--out song.ctsong]
       chronoforge music verify-model <rom.sfc> [--driver-steps N] [--songs a,b,...]
       chronoforge music import <rom.sfc> --project <p.ctproj> [--songs a,b,...]
       chronoforge music new --project <p.ctproj> --song N --samples a,b,... [--tracks SLOT[:OCTAVE],...]
                             [--steps N] [--tempo $XX] [--edl N] [--out audio/songs/new.ctsong]
       chronoforge music budget <rom.sfc> [--songs a,b,...]
       chronoforge music sample-check <clean.sfc> <built.sfc> <song> <sample> [--frames N] [--out probe.json]

driver-check --ipl uploads the boot blocks through the supplied 64-byte S-SMP
IPL image instead of copying them into ARAM. No IPL image is bundled.
song-load boots the driver the same way, then sends the song and its samples
through the driver's transfer protocol and verifies ARAM against the ROM.
render does the same load, then records N seconds (default 10, at most 300)
of 32 kHz stereo 16-bit PCM from the S-DSP as a WAV; with --out the JSON
report goes to standard output, and --spc saves the state rendering starts
from as an SPC snapshot. spc-render renders a snapshot through the same S-DSP;
--voices mixes only the voices whose bits are set (muted voices still run);
--counter starts the S-DSP rate counter at N (default 0, the reset value),
which SPC files do not store; --timers-first steps the timers before the CPU's
access in each clock (default: access first), libgme's order for those ties.
play does render's load and plays the song live on the default output for N
seconds (default 10) at volume V (0 to 1, default 1), as the Studio does, then
reports the seconds played and any buffer underruns as JSON.
events prints the event model's timeline (docs/music_tracker.md): each track's
notes, rests and commands at the song step they happen, up to its song loop
(--steps N runs N steps instead, through loops). edit changes a listing by
line number (see `music edit` alone for its forms) and checks that it still
assembles. verify-model reads every ROM song into the model and writes it back
byte for byte; --driver-steps also plays each on the emulated driver and
compares its key-ons and step timing with the model's over N steps.
import writes each ROM song's listing to audio/songs/songNN.ctsong and lists it in rom.songs.
new writes a template listing (docs/music_tracker.md, "Composing"): a header on track 0, then
each track's sample (slot k of --samples plays sample $20 + k), volume, pan, octave and
transpose 10 (note 12 x octave + index), and rests --steps long (default 768) that loop; it is
listed in rom.songs as song N, which it replaces. budget prints each song's sequence and
sample ARAM against its echo buffer. sample-check loads <song> of the built ROM on the driver
(booted from the clean ROM), waits for a voice to key on <sample> and checks its directory
entry, ARAM bytes, words, pitch (Spc_NotePitch) and the samples the S-DSP decodes for it.
"""

func cmdMusic(_ args: [String]) -> Int32 {
    if let operation = args.first, ["import", "new", "budget", "sample-check"].contains(operation) { return cmdMusicGame(args) }
    let operations = ["list", "disasm", "asm", "verify-rom", "spc-info", "driver-check", "song-load", "render", "spc-render", "play"]
    if let operation = args.first, ["events", "edit", "verify-model"].contains(operation) { return cmdMusicModel(args) }
    guard let operation = args.first, operations.contains(operation) else {
        print(musicUsage); return 2
    }
    let rendering = ["render", "spc-render", "play"].contains(operation)
    var positional: [String] = [], out: String?, ipl: String?, spc: String?, seconds: String?, voices: String?, counter: String?, volume: String?
    var timersFirst = false
    var i = 1
    while i < args.count {
        let option = args[i]
        if option == "--timers-first" && operation == "spc-render" { timersFirst = true; i += 1; continue }
        if option == "--out" || (option == "--ipl" && ["driver-check", "song-load", "render", "spc-render", "play"].contains(operation))
            || (option == "--seconds" && rendering) || (option == "--spc" && operation == "render")
            || (["--voices", "--counter"].contains(option) && operation == "spc-render")
            || (option == "--volume" && operation == "play") {
            guard i + 1 < args.count else { print("missing value for \(option)"); return 2 }
            switch option {
            case "--out": out = args[i + 1]
            case "--ipl": ipl = args[i + 1]
            case "--spc": spc = args[i + 1]
            case "--voices": voices = args[i + 1]
            case "--counter": counter = args[i + 1]
            case "--volume": volume = args[i + 1]
            default: seconds = args[i + 1]
            }
            i += 2
        } else { positional.append(args[i]); i += 1 }
    }
    guard positional.count == (["disasm", "song-load", "render", "play"].contains(operation) ? 2 : 1) else { print(musicUsage); return 2 }
    func same(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath() == URL(fileURLWithPath: b).resolvingSymlinksInPath()
    }
    let inputs = [positional[0]] + (ipl.map { [$0] } ?? [])
    for output in [out, spc].compactMap({ $0 }) where inputs.contains(where: { same(output, $0) }) {
        print("output must differ from input"); return 2
    }
    if let out, let spc, same(out, spc) { print("--out and --spc must differ"); return 2 }
    var renderSeconds = 10.0
    if let seconds {
        guard let value = Double(seconds), value.isFinite, value > 0, value <= SPCRender.maxSeconds else {
            print("--seconds must be a number above 0 and at most \(Int(SPCRender.maxSeconds))"); return 2
        }
        renderSeconds = value
    }
    var playVolume: Float = 1
    if let volume {
        guard let value = Float(volume), (0...1).contains(value) else { print("--volume must be from 0 to 1"); return 2 }
        playVolume = value
    }
    var options = SPCRender.Options()
    options.timersBeforeAccess = timersFirst
    if let counter {
        guard let value = songNumber(counter), (0..<SDSP.counterPeriod).contains(value) else {
            print("--counter must be from 0 to $77FF (decimal or $hex)"); return 2
        }
        options.counter = value
    }
    if let voices {
        guard let value = songNumber(voices), (0...0xFF).contains(value) else {
            print("--voices must be a voice bit mask from 0 to 255 (decimal or $hex)"); return 2
        }
        options.voices = UInt8(value)
    }
    func emit(_ data: Data) throws {
        if let out { try data.write(to: URL(fileURLWithPath: out), options: .atomic) }
        else { FileHandle.standardOutput.write(data) }
    }
    do {
        switch operation {
        case "render", "spc-render", "play":
            let iplROM = try ipl.map { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) }
            if let iplROM, iplROM.count != 64 {
                print("IPL image must be exactly 64 bytes (got \(iplROM.count))"); return 2
            }
            if operation == "spc-render" {
                let snapshot = try SPCFile(data: Data(contentsOf: URL(fileURLWithPath: positional[0])))
                let pcm = try SPCRender.render(snapshot: snapshot, seconds: renderSeconds, iplROM: iplROM, options: options)
                try emit(SPCRender.wav(pcm))
                if out != nil {
                    print(#"{"format": "spc-render/1", "frames": \#(pcm.count / 2), "pcm_sha256": "\#(CTEventPack.sha256(pcm.withUnsafeBytes { Array($0) }))"}"#)
                }
                return 0
            }
            guard let song = songNumber(positional[1]) else { print("song must be a number (decimal or $hex)"); return 2 }
            if operation == "play" {
                let rom = try readROM(positional[0])
                return MainActor.assumeIsolated {
                    playLive(String(format: "song $%02X", song), seconds: renderSeconds, volume: playVolume) {
                        try SPCStream.ctSong(rom: rom, song: song, iplROM: iplROM)
                    }
                }
            }
            let render = try CTSPCRender.render(rom: try readROM(positional[0]), song: song, seconds: renderSeconds, iplROM: iplROM)
            if let spc { try render.snapshot.encode().write(to: URL(fileURLWithPath: spc), options: .atomic) }
            try emit(SPCRender.wav(render.pcm))
            if out != nil { FileHandle.standardOutput.write(try CTProject.jsonEncoder.encode(render.report)) }
            return 0
        case "driver-check", "song-load":
            let iplROM = try ipl.map { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) }
            if let iplROM, iplROM.count != 64 {
                print("IPL image must be exactly 64 bytes (got \(iplROM.count))"); return 2
            }
            if operation == "song-load" {
                guard let song = songNumber(positional[1]) else { print("song must be a number (decimal or $hex)"); return 2 }
                let report = try CTSPCTransfer.loadSong(rom: try readROM(positional[0]), song: song, iplROM: iplROM)
                try emit(CTProject.jsonEncoder.encode(report))
                return report.passed ? 0 : 1
            }
            let report = try CTSPCDriver.check(rom: try readROM(positional[0]), iplROM: iplROM)
            try emit(CTProject.jsonEncoder.encode(report))
            return report.passed ? 0 : 1
        case "spc-info":
            struct Info: Encodable {
                let format = "spc/0.30"
                let registers: SPC700.Registers
                let ramSHA256, dspSHA256, extraRAMSHA256: String
                let trailingBytes: Int
            }
            let snapshot = try SPCFile(data: Data(contentsOf: URL(fileURLWithPath: positional[0])))
            let info = Info(registers: snapshot.registers, ramSHA256: CTEventPack.sha256(snapshot.ram),
                            dspSHA256: CTEventPack.sha256(snapshot.dsp), extraRAMSHA256: CTEventPack.sha256(snapshot.extraRAM),
                            trailingBytes: snapshot.trailer.count)
            try emit(CTProject.jsonEncoder.encode(info))
        case "list":
            for s in try CTSong.romSongs(try readROM(positional[0])) {
                let song = try CTSong(data: s.data)
                let tracks = song.tracks.prefix(8).filter { $0 != song.noTrack }.count
                print(String(format: "song $%02X  $%02X:%04X  %5d bytes  %d tracks%@", s.index, s.pointer >> 16, s.pointer & 0xFFFF,
                             s.data.count, tracks, s.data.count >= CTSongISA.songRoom ? "  (reaches the $2F00 block)" : ""))
            }
        case "disasm":
            let rom = try readROM(positional[0])
            let songs = try CTSong.romSongs(rom)
            guard let n = songNumber(positional[1]), songs.indices.contains(n) else {
                print("song must be 0-\(songs.count - 1) (or $00-$\(String(format: "%02X", songs.count - 1)))"); return 2
            }
            let s = songs[n]
            let title = String(format: "song $%02X ($%02X:%04X, %d bytes)", n, s.pointer >> 16, s.pointer & 0xFFFF, s.data.count)
            try emit(Data(try CTSongListing.render(try CTSong(data: s.data), title: title,
                                                   tables: CTSongTables.rom(rom, song: n)).utf8))
        case "asm":
            let text = try String(contentsOf: URL(fileURLWithPath: positional[0]), encoding: .utf8)
            let (data, tables) = try CTSongListing.assembleSong(text)
            if out != nil { try emit(Data(data)) }
            let set = [tables.samples.map { "samples \($0.count)" }, tables.echo.map { _ in "echo" },
                       tables.drums.map { _ in "drum kit" }].compactMap { $0 }
            print("\(data.count) bytes, sha256 \(CTEventPack.sha256(data))" + (set.isEmpty ? "" : "; tables: " + set.joined(separator: ", ")))
        default:
            var exact = 0
            let rom = try readROM(positional[0])
            let songs = try CTSong.romSongs(rom)
            for s in songs {
                let tables = CTSongTables.rom(rom, song: s.index)
                let listing = try CTSongListing.render(try CTSong(data: s.data), tables: tables)
                let back = try CTSongListing.assembleSong(listing)
                let same = back.data == s.data && back.tables == tables
                    && tables.rows(song: s.index).allSatisfy { Array(rom[$0.pc..<($0.pc + $0.bytes.count)]) == $0.bytes }
                if same { exact += 1 }
                print(#"{"song": \#(s.index), "data_sha256": "\#(CTEventPack.sha256(s.data))", "listing_sha256": "\#(CTEventPack.sha256(Array(listing.utf8)))", "byte_exact": \#(same)}"#)
            }
            print("\(exact)/\(songs.count) songs byte-exact")
            return exact == songs.count ? 0 : 1
        }
        return 0
    } catch {
        print("music \(operation) failed: \(error)"); return 1
    }
}

/// A song number as `disasm`, `song-load` and `render` take it: decimal or `$` hex.
private func songNumber(_ text: String) -> Int? {
    text.hasPrefix("$") ? Int(text.dropFirst(), radix: 16) : Int(text)
}

// MARK: - The event model (events, edit, verify-model)

private let editUsage = """
usage: chronoforge music edit <song.ctsong> roundtrip
       chronoforge music edit <song.ctsong> semitone <line> <C..B>
       chronoforge music edit <song.ctsong> length <line> <steps> [--shift]
       chronoforge music edit <song.ctsong> delete <line>
       chronoforge music edit <song.ctsong> insert <track> <step> <note, e.g. C#4> <steps>
       chronoforge music edit <song.ctsong> control <line> <sample|volume|pan|...> <$XX>
Lines are the listing's line numbers (a note's line for length and delete).
--out writes the edited listing (default: standard output); roundtrip reads
the listing into the model and checks it writes back the same text and bytes.
"""

private struct EventJSON: Encodable {
    let step: Int, line: Int, kind: String, text: String
    var length: Int?, note: String?, number: Int?, sample: Int?, volume: Int?, pan: Int?
    var keyOn: Bool?, drum: Bool?, pass: Int?
}

private struct TrackJSON: Encodable {
    let track: Int, stop: String, endStep: Int
    let loopStart: Int?, loopEnd: Int?
    let notes: Int
    let events: [EventJSON]
}

private func modelDocument(_ path: String, song: String?) throws -> (CTSongDocument, CTSongTables?, String) {
    if path.hasSuffix(".ctsong") {
        let doc = CTSongDocument(listing: try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8))
        return (doc, doc.tables, (path as NSString).lastPathComponent)
    }
    let rom = try readROM(path)
    let songs = try CTSong.romSongs(rom)
    guard let song, let n = songNumber(song), songs.indices.contains(n) else {
        throw CTSongError("song must be 0-\(songs.count - 1)")
    }
    let tables = CTSongTables.rom(rom, song: n)
    let listing = try CTSongListing.render(try CTSong(data: songs[n].data), tables: tables)
    return (CTSongDocument(listing: listing), tables, String(format: "song $%02X", n))
}

private func eventsJSON(_ track: CTSongTimeline.Track) -> [EventJSON] {
    let notes = Dictionary(track.notes.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
    return track.events.map { e in
        var j = EventJSON(step: e.step, line: e.item + 1, kind: e.statement.name,
                          text: e.statement.text.trimmingCharacters(in: .whitespaces))
        if e.length > 0 { j.length = e.length }
        if case .note = e.statement, let n = notes[e.step], n.item == e.item {
            j.length = n.length; j.note = CTSongTimeline.noteName(n.number); j.number = n.number
            j.sample = n.sample; j.volume = n.volume; j.pan = n.pan; j.keyOn = n.keyOn; j.drum = n.drum; j.pass = n.pass
        }
        return j
    }
}

func cmdMusicModel(_ args: [String]) -> Int32 {
    let operation = args[0]
    var positional: [String] = [], out: String?, json = false, shift = false, steps: Int?, driverSteps: Int?, only: [Int]?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--json" where operation == "events": json = true; i += 1
        case "--shift" where operation == "edit": shift = true; i += 1
        case "--out" where operation == "edit", "--steps" where operation == "events",
             "--driver-steps" where operation == "verify-model", "--songs" where operation == "verify-model":
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            let value = args[i + 1]
            switch args[i] {
            case "--out": out = value
            case "--steps", "--driver-steps":
                guard let n = Int(value), (1...200_000).contains(n) else { print("\(args[i]) must be 1-200000"); return 2 }
                if args[i] == "--steps" { steps = n } else { driverSteps = n }
            default:
                let numbers = value.split(separator: ",").map { songNumber(String($0)) }
                guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { print("--songs takes song numbers a,b,..."); return 2 }
                only = numbers.map { $0! }
            }
            i += 2
        default: positional.append(args[i]); i += 1
        }
    }
    do {
        switch operation {
        case "events":
            guard (1...2).contains(positional.count) else { print(musicUsage); return 2 }
            let (doc, tables, title) = try modelDocument(positional[0], song: positional.count > 1 ? positional[1] : nil)
            var options = CTSongTimeline.Options()
            if let steps { options = .init(untilLoop: false, maxSteps: steps) }
            let timeline = try CTSongTimeline(doc, tables: tables, options: options)
            let tracks = timeline.tracks.filter { $0.stop != "none" }
            if json {
                let out = tracks.map { t in
                    TrackJSON(track: t.index, stop: t.stop, endStep: t.endStep, loopStart: t.loopStart, loopEnd: t.loopEnd,
                              notes: t.notes.count, events: eventsJSON(t))
                }
                FileHandle.standardOutput.write(try CTProject.jsonEncoder.encode(out))
                print()
                return 0
            }
            print("\(title): \(tracks.count) tracks, \(timeline.length) steps")
            for t in tracks {
                let loop = t.loopStart.map { " loop \($0)-\(t.loopEnd!)" } ?? ""
                print("track \(t.index): \(t.notes.count) notes, stops at \(t.endStep) (\(t.stop))\(loop)")
                for e in eventsJSON(t) {
                    var line = String(format: "%7d  line %5d  %@", e.step, e.line, e.text)
                    if let note = e.note {
                        line += "  ; \(note) \(e.length!) steps" + (e.sample.map { String(format: " sample $%02X", $0) } ?? "")
                            + (e.keyOn == false ? " legato" : "") + (e.drum == true ? " drum" : "")
                    }
                    print(line)
                }
            }
            return 0
        case "edit":
            guard positional.count >= 2 else { print(editUsage); return 2 }
            let path = positional[0]
            let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            var doc = CTSongDocument(listing: text)
            let words = Array(positional.dropFirst(2))
            func line(_ s: String) throws -> Int {
                guard let n = Int(s), doc.items.indices.contains(n - 1) else { throw CTSongError("\(s) is not a line of the listing") }
                return n - 1
            }
            func note(at item: Int) throws -> CTSongTimeline.Note {
                let timeline = try CTSongTimeline(doc)
                guard let n = timeline.tracks.flatMap(\.notes).first(where: { $0.item == item }) else {
                    throw CTSongError("no track plays a note at line \(item + 1)")
                }
                return n
            }
            switch (positional[1], words.count) {
            case ("roundtrip", 0):
                let back = doc.listing
                let a = try CTSongListing.assembleSong(text), b = try doc.assemble()
                let same = back == text && a.data == b.data && a.tables == b.tables
                print("\(doc.items.count) lines; text \(back == text ? "identical" : "DIFFERENT"); "
                      + "\(b.data.count) bytes \(a.data == b.data && a.tables == b.tables ? "identical" : "DIFFERENT")")
                return same ? 0 : 1
            case ("semitone", 2):
                guard let s = CTSongISA.noteNames.firstIndex(of: words[1]) else { throw CTSongError("\(words[1]) is not C..B") }
                try doc.setSemitone(try line(words[0]), s)
            case ("length", 2):
                guard let n = Int(words[1]) else { throw CTSongError("\(words[1]) is not a step count") }
                try doc.setLength(try note(at: try line(words[0])), n, shift: shift)
            case ("delete", 1):
                try doc.deleteNote(try note(at: try line(words[0])))
            case ("insert", 4):
                guard let track = Int(words[0]), (0...7).contains(track), let step = Int(words[1]), let length = Int(words[3]),
                      let name = CTSongISA.noteNames.sorted(by: { $0.count > $1.count }).first(where: { words[2].hasPrefix($0) }),
                      let octave = Int(words[2].dropFirst(name.count)) else {
                    throw CTSongError("expected insert <track 0-7> <step> <note, e.g. C#4> <steps>")
                }
                let number = octave * 12 + CTSongISA.noteNames.firstIndex(of: name)!
                try doc.insertNote(track: track, step: step, number: number, steps: length, timeline: try CTSongTimeline(doc))
            case ("control", 3):
                guard words[2].count == 3, words[2].hasPrefix("$"), let v = UInt8(words[2].dropFirst(), radix: 16) else {
                    throw CTSongError("\(words[2]) is not a $XX byte")
                }
                try doc.setControl(before: try line(words[0]), words[1], v)
            default:
                print(editUsage); return 2
            }
            let (data, _) = try doc.assemble()
            let edited = doc.listing
            if let out { try Data(edited.utf8).write(to: URL(fileURLWithPath: out), options: .atomic) }
            else { print(edited, terminator: "") }
            FileHandle.standardError.write(Data("edited; \(data.count) bytes assemble\n".utf8))
            return 0
        default:
            guard positional.count == 1 else { print(musicUsage); return 2 }
            let rom = try readROM(positional[0])
            let songs = try CTSong.romSongs(rom)
            var exact = 0, checked = 0, passed = 0, failures = 0
            for s in songs where only?.contains(s.index) ?? true {
                let tables = CTSongTables.rom(rom, song: s.index)
                let listing = try CTSongListing.render(try CTSong(data: s.data), tables: tables)
                let doc = CTSongDocument(listing: listing)
                let back = try doc.assemble()
                let same = doc.listing == listing && back.data == s.data && back.tables == tables
                if same { exact += 1 }
                let timeline = try CTSongTimeline(doc, tables: tables)
                var line = #"{"song": \#(s.index), "byte_exact": \#(same), "steps": \#(timeline.length), "notes": \#(timeline.tracks.reduce(0) { $0 + $1.notes.count }), "stops": "\#(timeline.tracks.filter { $0.stop != "none" }.map(\.stop).joined(separator: ","))""#
                if let driverSteps, timeline.tracks.contains(where: { $0.stop != "none" }) {
                    let trace = try CTSongDriverTrace.trace(rom: rom, song: s.index, steps: driverSteps)
                    let comparison = try CTSongDriverTrace.compare(doc, tables: tables, trace: trace)
                    checked += 1
                    if comparison.passed { passed += 1 } else { failures += 1 }
                    line += #", "driver_steps": \#(driverSteps), "key_ons": \#(comparison.driverKeyOns.reduce(0, +)), "key_ons_match": \#(comparison.mismatches.isEmpty), "pass_mismatches": \#(comparison.passMismatches), "max_pass_error": \#(comparison.maxPassError)"#
                    if !comparison.mismatches.isEmpty {
                        line += #", "mismatches": [\#(comparison.mismatches.map { "\"\($0)\"" }.joined(separator: ", "))]"#
                    }
                }
                print(line + "}")
            }
            let total = only.map { o in songs.filter { o.contains($0.index) }.count } ?? songs.count
            print("\(exact) of \(total) songs byte-exact through the model" + (driverSteps != nil ? "; \(passed) of \(checked) match the driver" : ""))
            return exact == total && failures == 0 ? 0 : 1
        }
    } catch {
        print("music \(operation) failed: \(error)"); return 1
    }
}

// MARK: - Composed songs in the game (import, new, budget, sample-check)

private func cmdMusicGame(_ args: [String]) -> Int32 {
    let operation = args[0]
    var positional: [String] = [], options: [String: String] = [:]
    var i = 1
    while i < args.count {
        if args[i].hasPrefix("--") {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            options[args[i]] = args[i + 1]; i += 2
        } else { positional.append(args[i]); i += 1 }
    }
    func numbers(_ key: String) throws -> [Int]? {
        guard let text = options[key] else { return nil }
        let values = text.split(separator: ",").map { songNumber(String($0)) }
        guard !values.contains(nil) else { throw CTSongError("\(key) takes numbers separated by commas") }
        return values.map { $0! }
    }
    do {
        switch operation {
        case "import":
            guard positional.count == 1, let path = options["--project"] else { print(musicUsage); return 2 }
            let rom = try readROM(positional[0])
            var p = try CTProject.load(from: URL(fileURLWithPath: path))
            let songs = try CTSong.romSongs(rom)
            let wanted = try numbers("--songs") ?? Array(songs.indices)
            var spec = p.project.rom ?? .init()
            for n in wanted {
                guard songs.indices.contains(n) else { throw CTSongError("song \(n) is not 0-\(songs.count - 1)") }
                let s = songs[n], listing = String(format: "audio/songs/song%02X.ctsong", n)
                let title = String(format: "song $%02X ($%02X:%04X, %d bytes)", n, s.pointer >> 16, s.pointer & 0xFFFF, s.data.count)
                let text = try CTSongListing.render(try CTSong(data: s.data), title: title, tables: CTSongTables.rom(rom, song: n))
                let url = p.fileURL(relative: listing)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url, options: .atomic)
                spec.songs.removeAll { $0.song == n }
                spec.songs.append(.init(song: n, listing: listing))
            }
            spec.songs.sort { $0.song < $1.song }
            p.project.rom = spec
            try p.save()
            print("imported \(wanted.count) songs into \(path) (rom.songs)")
        case "new":
            guard positional.isEmpty, let path = options["--project"], let songText = options["--song"],
                  let song = songNumber(songText), let samples = try numbers("--samples") else { print(musicUsage); return 2 }
            var tracks: [CTSongTemplate.Track] = []
            for part in (options["--tracks"] ?? "0").split(separator: ",") {
                let fields = part.split(separator: ":").map { songNumber(String($0)) }
                guard (1...2).contains(fields.count), !fields.contains(nil) else { throw CTSongError("--tracks takes SLOT[:OCTAVE],...") }
                tracks.append(fields.count == 2 ? .init(slot: fields[0]!, octave: fields[1]!) : .init(slot: fields[0]!))
            }
            var o = CTSongTemplate.Options(samples: samples, tracks: tracks)
            if let steps = options["--steps"] { guard let n = Int(steps) else { throw CTSongError("--steps takes a number") }; o.steps = n }
            if let tempo = options["--tempo"] { guard let n = songNumber(tempo) else { throw CTSongError("--tempo takes a byte") }; o.tempo = n }
            if let edl = options["--edl"] { guard let n = Int(edl) else { throw CTSongError("--edl takes 0-15") }; o.edl = n }
            let listing = options["--out"] ?? String(format: "audio/songs/song%02X.ctsong", song)
            guard !listing.hasPrefix("/"), !listing.split(separator: "/").contains("..") else {
                throw CTSongError("--out is a path inside the project")
            }
            var p = try CTProject.load(from: URL(fileURLWithPath: path))
            let text = try CTSongTemplate.listing(o, title: String(format: "new song $%02X", song))
            let url = p.fileURL(relative: listing)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            var spec = p.project.rom ?? .init()
            spec.songs.removeAll { $0.song == song }
            spec.songs.append(.init(song: song, listing: listing))
            spec.songs.sort { $0.song < $1.song }
            p.project.rom = spec
            try p.save()
            print(String(format: "wrote %@ (%d tracks, %d steps) and listed it in rom.songs as song $%02X", listing, tracks.count, o.steps, song))
        case "budget":
            guard positional.count == 1 else { print(musicUsage); return 2 }
            let rom = try readROM(positional[0])
            let count = Int(rom[CTSongISA.songCountPC])
            var over = 0
            for song in try numbers("--songs") ?? Array(0..<count) {
                let b = try CTSongBudget.of(rom: rom, song: song)
                if !b.fits { over += 1 }
                print(String(format: "song $%02X  sequence %5d of %d bytes%@  samples %2d: $%04X-$%04X, echo $%04X (EDL %2d), %6d bytes free%@",
                             song, b.sequenceBytes, b.sequenceMax, b.reachesEffectsBlock ? " (reaches $2F00)" : "", b.samples.count,
                             b.sampleStart, b.sampleEnd, b.echoStart, b.edl, b.freeBytes, b.fits ? "" : "  OVER"))
            }
            return over == 0 ? 0 : 1
        default:
            guard positional.count == 4, let song = songNumber(positional[2]), let sample = songNumber(positional[3]) else {
                print(musicUsage); return 2
            }
            let frames = Int(options["--frames"] ?? "4096") ?? 4096
            let result = try CTSampleProbe.run(clean: try readROM(positional[0]), built: try readROM(positional[1]),
                                               song: song, sample: sample, frames: frames)
            let data = try CTProject.jsonEncoder.encode(result)
            if let out = options["--out"] { try data.write(to: URL(fileURLWithPath: out), options: .atomic) }
            else { FileHandle.standardOutput.write(data); print() }
            for c in result.checks where !c.passed { print("FAILED: \(c.name)") }
            return result.passed ? 0 : 1
        }
        return 0
    } catch {
        print("music \(operation) failed: \(error)"); return 1
    }
}
