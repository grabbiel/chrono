import Foundation
import ChronoForgeCore

private let musicUsage = """
usage: chronoforge music list <rom.sfc>
       chronoforge music disasm <rom.sfc> <song> [--out song.ctsong]
       chronoforge music asm <song.ctsong> [--out song.bin]
       chronoforge music verify-rom <rom.sfc>
       chronoforge music spc-info <snapshot.spc> [--out info.json]
       chronoforge music driver-check <rom.sfc> [--ipl ipl.rom] [--out report.json]

driver-check --ipl uploads the boot blocks through the supplied 64-byte S-SMP
IPL image instead of copying them into ARAM. No IPL image is bundled.
"""

func cmdMusic(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["list", "disasm", "asm", "verify-rom", "spc-info", "driver-check"].contains(operation) else {
        print(musicUsage); return 2
    }
    var positional: [String] = [], out: String?, ipl: String?
    var i = 1
    while i < args.count {
        if args[i] == "--out" || (args[i] == "--ipl" && operation == "driver-check") {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            if args[i] == "--out" { out = args[i + 1] } else { ipl = args[i + 1] }
            i += 2
        } else { positional.append(args[i]); i += 1 }
    }
    guard positional.count == (operation == "disasm" ? 2 : 1) else { print(musicUsage); return 2 }
    if let out, ([positional[0]] + (ipl.map { [$0] } ?? [])).contains(where: {
        URL(fileURLWithPath: out).resolvingSymlinksInPath() == URL(fileURLWithPath: $0).resolvingSymlinksInPath()
    }) {
        print("output must differ from input"); return 2
    }
    func emit(_ data: Data) throws {
        if let out { try data.write(to: URL(fileURLWithPath: out), options: .atomic) }
        else { FileHandle.standardOutput.write(data) }
    }
    do {
        switch operation {
        case "driver-check":
            let iplROM = try ipl.map { [UInt8](try Data(contentsOf: URL(fileURLWithPath: $0))) }
            if let iplROM, iplROM.count != 64 {
                print("IPL image must be exactly 64 bytes (got \(iplROM.count))"); return 2
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
            guard let n = Int(positional[1].hasPrefix("$") ? String(positional[1].dropFirst()) : positional[1],
                              radix: positional[1].hasPrefix("$") ? 16 : 10), songs.indices.contains(n) else {
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
