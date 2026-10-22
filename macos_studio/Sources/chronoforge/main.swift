// chronoforge — CLI: validate / render-tileset / decode-sample / lzss.
import Foundation
import ChronoForgeCore
import ChronoForgeMetal

// MARK: Paths

func repoRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["CHRONOFORGE_REPO"] {
        return URL(fileURLWithPath: env)
    }
    // Compile-time package location: this file is macos_studio/Sources/chronoforge/main.swift
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("..").standardizedFileURL
}
func cleanROM() -> URL { repoRoot().appendingPathComponent("re_workspace/ct_clean.sfc") }
func dataAssetsCSV() -> URL {
    repoRoot().appendingPathComponent("re_workspace/refs/ChronoRET/symbols/data_assets.csv")
}

func snesPC(_ addr: String) -> Int? {
    // "$C3:1200" -> ((bank & 0x3F) << 16) | addr  (HiROM)
    let parts = addr.replacingOccurrences(of: "$", with: "").split(separator: ":")
    guard parts.count == 2, let b = Int(parts[0], radix: 16), let a = Int(parts[1], radix: 16) else { return nil }
    return ((b & 0x3F) << 16) | a
}

struct CorpusBlock {
    let label: String
    let pcStart: Int
    let pcEnd: Int
    let mode: Int          // 11 | 12
    let expectedSize: Int
}

func loadCorpus() -> [CorpusBlock] {
    guard let text = try? String(contentsOf: dataAssetsCSV(), encoding: .utf8) else { return [] }
    var out: [CorpusBlock] = []
    for line in text.split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 7, cols[4] == "packed" else { continue }
        guard let s = snesPC(cols[1]), let e = snesPC(cols[2]) else { continue }
        let spec = cols[6]
        let mode = spec.contains("lz11") ? 11 : (spec.contains("lz12") ? 12 : 0)
        guard mode != 0,
              let arrow = spec.firstIndex(of: ">"),
              let n = Int(spec[spec.index(after: arrow)...].filter { $0.isNumber }) else { continue }
        out.append(CorpusBlock(label: cols[0], pcStart: s, pcEnd: e, mode: mode, expectedSize: n))
    }
    return out
}

// MARK: Commands

func cmdValidate(_ args: [String]) -> Int32 {
    guard let path = args.first else {
        FileHandle.standardError.write("usage: chronoforge validate <ctproj>\n".data(using: .utf8)!)
        return 2
    }
    do {
        let proj = try CTProject.load(from: URL(fileURLWithPath: path))
        let issues = Validator.validate(proj)
        for i in issues { print(i.description) }
        let errs = issues.filter { $0.severity == .error }.count
        print("\(errs) error(s), \(issues.count - errs) warning(s) — \(Validator.isValid(issues) ? "VALID" : "INVALID")")
        return Validator.isValid(issues) ? 0 : 1
    } catch {
        print("load failed: \(error)")
        return 1
    }
}

let defaultPalette16: [BGR555] = (0..<16).map { i in
    let v = UInt8(i * 17)
    return BGR555(r5: v >> 3, g5: v >> 3, b5: v >> 3)
}

func renderTileGrid(indices: [UInt8], tilesWide: Int, palette: [BGR555], out: URL) -> Int32 {
    let tiles = indices.count / 64
    let cols = tilesWide * 8
    let rows = max(1, (tiles + tilesWide - 1) / tilesWide) * 8
    var rgba = [UInt8](repeating: 0, count: cols * rows * 4)
    for t in 0..<tiles {
        let tx = (t % tilesWide) * 8, ty = (t / tilesWide) * 8
        for r in 0..<8 {
            for c in 0..<8 {
                let idx = Int(indices[t * 64 + r * 8 + c]) & 15
                let col = palette[idx].srgb
                let o = ((ty + r) * cols + tx + c) * 4
                rgba[o] = col.r; rgba[o + 1] = col.g; rgba[o + 2] = col.b; rgba[o + 3] = 255
            }
        }
    }
    do {
        let png = try PNG.writeRGBA(width: cols, height: rows, rgba: rgba)
        try png.write(to: out)
        print("wrote \(out.path) (\(tiles) tiles, \(cols)x\(rows))")
        return 0
    } catch {
        print("render failed: \(error)")
        return 1
    }
}

func cmdRenderTileset(_ args: [String]) -> Int32 {
    var outPath = "out.png"
    var target: String?
    var tilesetID: String?
    var i = 0
    while i < args.count {
        switch args[i] {
        case "--out": i += 1; outPath = args[i]
        case "--tileset": i += 1; tilesetID = args[i]
        default: target = args[i]
        }
        i += 1
    }
    guard let target else {
        FileHandle.standardError.write("usage: chronoforge render-tileset <ctproj|rom> --out out.png [--tileset id]\n".data(using: .utf8)!)
        return 2
    }
    let isROM: Bool
    if target == "rom" { isROM = true }
    else if let attrs = try? FileManager.default.attributesOfItem(atPath: target),
            let size = attrs[.size] as? Int, size > 100_000 { isROM = true }
    else { isROM = target.hasSuffix(".sfc") || target.hasSuffix(".smc") }
    if isROM {
        // ROM smoke test: decode a corpus block and render its first tiles.
        let romURL = target == "rom" ? cleanROM() : URL(fileURLWithPath: target)
        guard let rom = try? Data(contentsOf: romURL) else {
            print("cannot read \(romURL.path)"); return 1
        }
        let blocks = loadCorpus()
        guard let first = blocks.first(where: { $0.expectedSize >= 1024 }) ?? blocks.first else {
            print("corpus empty"); return 1
        }
        let romBytes = [UInt8](rom)
        let src = Array(romBytes[first.pcStart...first.pcEnd])
        guard let (out, mode) = try? LZSS.decompress(src), out.count == first.expectedSize else {
            print("corpus block \(first.label) failed to match expected size"); return 1
        }
        print("ROM smoke: \(first.label) mode lz\(mode.rawValue) -> \(out.count) B (expected \(first.expectedSize))")
        return renderTileGrid(indices: TileDecoder.decodeIndices(out, depth: .bpp4),
                              tilesWide: 16, palette: defaultPalette16,
                              out: URL(fileURLWithPath: outPath))
    }
    do {
        let proj = try CTProject.load(from: URL(fileURLWithPath: target))
        let ts: Tileset
        if let id = tilesetID, let found = proj.tilesets[id] { ts = found }
        else {
            guard let first = proj.tilesets.values.sorted(by: { $0.id < $1.id }).first else {
                print("no tilesets"); return 1
            }
            ts = first
        }
        let indices = try proj.tileIndices(of: ts)
        return renderTileGrid(indices: indices, tilesWide: 16,
                              palette: defaultPalette16, out: URL(fileURLWithPath: outPath))
    } catch {
        print("render-tileset failed: \(error)"); return 1
    }
}

func cmdDecodeSample(_ args: [String]) -> Int32 {
    var outPath = "out.wav"
    var file: String?
    var i = 0
    while i < args.count {
        if args[i] == "--out" { i += 1; outPath = args[i] } else { file = args[i] }
        i += 1
    }
    guard let file, let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
        FileHandle.standardError.write("usage: chronoforge decode-sample <brrfile> --out out.wav\n".data(using: .utf8)!)
        return 2
    }
    let dec = BRR.decodeBlob([UInt8](data))
    do {
        try WAV.writeWav(samples: dec.samples, rate: 32000).write(to: URL(fileURLWithPath: outPath))
        print("decoded \(dec.blocks) BRR blocks -> \(dec.samples.count) samples -> \(outPath)")
        return 0
    } catch { print("write failed: \(error)"); return 1 }
}

func cmdLZSS(_ args: [String]) -> Int32 {
    guard let op = args.first, op == "decompress" || op == "compress" else {
        FileHandle.standardError.write("usage: chronoforge lzss <decompress|compress> <file> [--mode 11|12] [--out file]\n".data(using: .utf8)!)
        return 2
    }
    var file: String?
    var mode = 12
    var outPath: String?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--mode": i += 1; mode = Int(args[i]) ?? 12
        case "--out": i += 1; outPath = args[i]
        default: file = args[i]
        }
        i += 1
    }
    guard let file, let data = try? Data(contentsOf: URL(fileURLWithPath: file)) else {
        print("cannot read input file"); return 2
    }
    let src = [UInt8](data)
    let bridge = LibCTCodec.shared
    let out: [UInt8]
    if op == "decompress" {
        if let c = bridge.lzssDecompress(src) {
            let m = LZSS.detectMode(in: src)?.rawValue ?? 0
            print("decompressed lz\(m) via libctcodec: \(src.count) -> \(c.count) B")
            out = c
        } else if let (outBytes, m) = try? LZSS.decompress(src) {
            print("decompressed lz\(m.rawValue) via swift fallback: \(src.count) -> \(outBytes.count) B")
            out = outBytes
        } else {
            print("decompress failed"); return 1
        }
    } else {
        guard mode == 11 || mode == 12 else { print("--mode must be 11 or 12"); return 2 }
        if let c = bridge.lzssCompress(src, mode: mode) {
            print("compressed lz\(mode) via libctcodec: \(src.count) -> \(c.count) B")
            out = c
        } else {
            guard let packed = LZSS.compress(src, mode: mode == 11 ? .lz11 : .lz12) else {
                print("compress failed: more than 65,535 bytes"); return 1
            }
            out = packed
            print("compressed lz\(mode) via swift fallback: \(src.count) -> \(out.count) B")
        }
    }
    let dest = outPath ?? (file + (op == "decompress" ? ".out" : ".lz\(mode)"))
    do { try Data(out).write(to: URL(fileURLWithPath: dest)); print("wrote \(dest)"); return 0 }
    catch { print("write failed: \(error)"); return 1 }
}

// MARK: main

let args = Array(CommandLine.arguments.dropFirst())
let cmd = args.first ?? "help"
let rest = Array(args.dropFirst())
switch cmd {
case "validate":        exit(cmdValidate(rest))
case "scene":           exit(cmdScene(rest))
case "text":            exit(cmdText(rest))
case "event":           exit(cmdEvent(rest))
case "render-tileset":  exit(cmdRenderTileset(rest))
case "decode-sample":   exit(cmdDecodeSample(rest))
case "lzss":            exit(cmdLZSS(rest))
case "rom":             exit(cmdRom(rest))
case "music":           exit(cmdMusic(rest))
case "characters":      exit(cmdCharacters(rest))
case "enemies":         exit(cmdEnemies(rest))
case "sprites":         exit(cmdSprites(rest))
case "tilesets":        exit(cmdTilesets(rest))
case "maps":            exit(cmdMaps(rest))
case "items":           exit(cmdItems(rest))
case "sfx":             exit(cmdSFX(rest))
case "story":           exit(cmdStory(rest))
default:
    print("""
    chronoforge — ChronoForge Studio CLI
    usage:
      chronoforge validate <ctproj>
      chronoforge text <profile|encode|decode|message|build|verify-corpus> <input>
                       [--profile profile.json] [--out file]
      chronoforge text <preview|font|fit> <rom> ...              (the in-game dialogue box)
      chronoforge event <list|disasm|asm|verify-rom|lower> ...   (CT event packs)
      chronoforge rom <build|info|locations> ...                 (.sfc builder)
      chronoforge characters <import|show|curve> ...             (playable-character records)
      chronoforge enemies <import|show|verify> ...               (enemy stats, rewards, names, AI scripts)
      chronoforge sprites <import|show> ...                      (playable-character sprites)
      chronoforge tilesets <import|show|verify> ...              (location tilesets and palettes)
      chronoforge maps <import|show|render|verify> ...           (location maps: layers, collision, exits)
      chronoforge items <import|show> ...                        (item, gear and consumable tables)
      chronoforge sfx <encode|synth|info|render> ...             (BRR samples: WAV import, synth, S-DSP render)
      chronoforge story <flags|graph|check|import|annotate> ...  (story flag registry and world graph)
      chronoforge music <list|disasm|asm|verify-rom|spc-info|driver-check|song-load|render|spc-render|play|events|edit|verify-model> ...
      chronoforge scene <compile|decompile|preview> <input> [--out file] [--project path]
      chronoforge scene <raise|graph|timeline> <rom.sfc> <location> ...   (a location's event pack as a scene)
                        [--entry 0] [--flag symbol] [--steps 1000]
      chronoforge render-tileset <ctproj|rom> --out out.png [--tileset id]
      chronoforge decode-sample <brrfile> --out out.wav
      chronoforge lzss <decompress|compress> <file> [--mode 11|12] [--out file]
    """)
    exit(cmd == "help" ? 0 : 2)
}
