import Foundation
import ChronoForgeCore

private let romUsage = """
usage: chronoforge rom build <project.ctproj> --base <clean.sfc> --out <out.sfc> [--report report.json]
       chronoforge rom info <rom.sfc>
       chronoforge rom locations <rom.sfc>
"""

func readROM(_ path: String) throws -> [UInt8] {
    var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    if data.count == CTROMBuilder.romSize + 512 { data.removeFirst(512) }
    guard data.count == CTROMBuilder.romSize else { throw CTROMBuildError("expected a 4 MiB Chrono Trigger ROM") }
    return data
}

func cmdRom(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["build", "info", "locations"].contains(operation) else {
        print(romUsage); return 2
    }
    var positional: [String] = [], options: [String: String] = [:]
    var i = 1
    while i < args.count {
        if ["--base", "--out", "--report"].contains(args[i]) {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            options[args[i]] = args[i + 1]; i += 2
        } else {
            positional.append(args[i]); i += 1
        }
    }
    guard positional.count == 1 else { print(romUsage); return 2 }
    do {
        switch operation {
        case "build":
            guard let basePath = options["--base"], let out = options["--out"] else {
                print("rom build needs --base and --out"); return 2
            }
            let project = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
            let (rom, report) = try CTROMBuilder.build(base: try readROM(basePath), project: project)
            try Data(rom).write(to: URL(fileURLWithPath: out), options: .atomic)
            if let path = options["--report"] {
                try CTProject.jsonEncoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
            }
            for pack in report.packs {
                print("entry \(pack.entry): \(pack.packedBytes) packed / \(pack.unpackedBytes) bytes at \(pack.address) " +
                      "(\(pack.placement))" + (pack.messageTable.map { ", messages at \($0)" } ?? ""))
            }
            for song in report.songs {
                print(String(format: "song $%02X: %d bytes at %@ (%@)", song.song, song.bytes, song.address, song.placement))
            }
            print(String(format: "wrote %@: checksum $%04X, %d bytes of free space left", out, report.checksum, report.freeBytesLeft))
        case "info":
            let rom = try readROM(positional[0])
            let title = String(decoding: rom[0xFFC0..<0xFFD5], as: UTF8.self)
            let stored = Int(rom[CTROMLayout.checksumPC]) | Int(rom[CTROMLayout.checksumPC + 1]) << 8
            let complement = Int(rom[CTROMLayout.complementPC]) | Int(rom[CTROMLayout.complementPC + 1]) << 8
            let sum = CTROMBuilder.checksum(rom)
            print("title     \(title.trimmingCharacters(in: .whitespaces))")
            print(String(format: "map mode  $%02X, size code $%02X", rom[0xFFD5], rom[0xFFD7]))
            print(String(format: "checksum  $%04X stored, $%04X computed, complement %@", stored, sum,
                         stored ^ complement == 0xFFFF ? "ok" : "wrong"))
            print("sha256    \(CTEventPack.sha256(rom))" + (CTEventPack.sha256(rom) == CTTextProfile.romHash ? " (clean US 1.0)" : ""))
            return stored == sum && stored ^ complement == 0xFFFF ? 0 : 1
        default:
            let rom = try readROM(positional[0])
            let entries = try CTEventROM.entries(rom: rom)
            for location in 0..<CTROMLayout.locationCount {
                let p = CTROMLayout.locationPC + location * CTROMLayout.locationStride + CTROMLayout.locationEventsOffset
                let entry = Int(rom[p]) | Int(rom[p + 1]) << 8
                guard entry < entries.count else { print(String(format: "%3d  events entry %d (out of range)", location, entry)); continue }
                let address = entries[entry].snesAddress
                let kind = CTROMLayout.notEventPackEntries.contains(entry) ? "  (no event pack)" : ""
                print(String(format: "%3d  events entry %3d  $%02X:%04X%@", location, entry, address >> 16, address & 0xFFFF, kind))
            }
        }
        return 0
    } catch {
        print("rom \(operation) failed: \(error)"); return 1
    }
}
