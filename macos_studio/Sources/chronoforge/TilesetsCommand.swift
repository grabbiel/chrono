import Foundation
import ChronoForgeCore

private let tilesetsUsage = """
usage: chronoforge tilesets import <rom.sfc> --project <project.ctproj> [--t12 N ...] [--t3 N ...] [--pal N ...]
       chronoforge tilesets show <project.ctproj> [id] [--palette pal_NN] [--frame N] [--png out.png] [--scale K]
       chronoforge tilesets verify <rom.sfc> --project <project.ctproj>
         import: every Tileset12 / Tileset3 / Palette value a location uses (or the ones given)
         show --png: the metatiles, 16 per row, through the PPU at field frame N (animations run)
         verify: the project's t12_NN / t3_NN / pal_NN against a fresh decode of the ROM
"""

func cmdTilesets(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show", "verify"].contains(operation) else {
        print(tilesetsUsage); return 2
    }
    var positional: [String] = [], options: [String: String] = [:], picks: [String: [Int]] = [:]
    var i = 1
    while i < args.count {
        if ["--project", "--palette", "--frame", "--png", "--scale", "--t12", "--t3", "--pal"].contains(args[i]) {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            if ["--t12", "--t3", "--pal"].contains(args[i]) {
                guard let n = Int(args[i + 1]), (0..<255).contains(n) else { print("\(args[i]) takes 0-254"); return 2 }
                picks[args[i], default: []].append(n)
            } else {
                options[args[i]] = args[i + 1]
            }
            i += 2
        } else {
            positional.append(args[i]); i += 1
        }
    }
    do {
        switch operation {
        case "import":
            guard positional.count == 1, let path = options["--project"] else { print(tilesetsUsage); return 2 }
            var project = try CTProject.load(from: URL(fileURLWithPath: path))
            let picked = !picks.isEmpty
            let ids = try CTTilesets.importTilesets(rom: try readROM(positional[0]), into: &project,
                                                    tileset12: picked ? picks["--t12"] ?? [] : nil,
                                                    tileset3: picked ? picks["--t3"] ?? [] : nil,
                                                    palettes: picked ? picks["--pal"] ?? [] : nil)
            try project.save()
            for id in ids { print(summary(project.tilesets[id]!)) }
            print("imported \(ids.count) tilesets into \(path)")
        case "verify":
            guard positional.count == 1, let path = options["--project"] else { print(tilesetsUsage); return 2 }
            let project = try CTProject.load(from: URL(fileURLWithPath: path))
            let result = try CTTilesets.verify(rom: try readROM(positional[0]), project: project)
            for p in result.problems { print("FAIL \(p)") }
            print("\(result.checked - Set(result.problems.map { $0.prefix { $0 != ":" } }).count) of \(result.checked) tilesets match the ROM")
            return result.problems.isEmpty ? 0 : 1
        default:
            guard (1...2).contains(positional.count) else { print(tilesetsUsage); return 2 }
            let project = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
            guard positional.count == 2 else {
                for ts in project.tilesets.values.sorted(by: { $0.id < $1.id }) { print(summary(ts)) }
                return 0
            }
            guard let ts = project.tilesets[positional[1]] else { print("no tileset \(positional[1])"); return 1 }
            print(summary(ts))
            details(ts)
            guard let out = options["--png"] else { return 0 }
            guard let sheet = ts.sheet else { print("\(ts.id) has no sheet to draw"); return 1 }
            let paletteID = options["--palette"] ?? ts.preview?.palette
            let palette = paletteID.flatMap { project.tilesets[$0] }
            if let paletteID, palette == nil { print("no palette tileset \(paletteID)"); return 1 }
            let tiles = SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: sheet)))
            let animTiles = try ts.animSheet.map { SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: $0))) } ?? []
            var player = TilesetPlayer(tileset: ts, palette: palette, cgram: TilesetScene.cgram(palette))
            player.advance(to: max(0, Int(options["--frame"] ?? "0") ?? 0))
            let scale = max(1, min(8, Int(options["--scale"] ?? "2") ?? 2))
            let rgba = stitched(ts, tiles: tiles, animTiles: animTiles, player: player)
            let h = TilesetScene.rows(ts) * 16
            var big = [UInt8](repeating: 0, count: 256 * scale * h * scale * 4)
            for y in 0..<(h * scale) {
                for x in 0..<(256 * scale) {
                    let src = ((y / scale) * 256 + x / scale) * 4, dst = (y * 256 * scale + x) * 4
                    big.replaceSubrange(dst..<(dst + 4), with: rgba[src..<(src + 4)])
                }
            }
            try PNG.writeRGBA(width: 256 * scale, height: h * scale, rgba: big).write(to: URL(fileURLWithPath: out))
            print("wrote \(out): \(ts.metatiles.count) metatiles at frame \(player.frame) in \(palette?.id ?? "gray") at \(scale)x")
        }
        return 0
    } catch {
        print("tilesets \(operation) failed: \(error)")
        return 1
    }
}

/// The whole metatile sheet: PPU frames at each 224-line scroll, stacked.
private func stitched(_ ts: Tileset, tiles: [[UInt8]], animTiles: [[UInt8]], player: TilesetPlayer) -> [UInt8] {
    let h = TilesetScene.rows(ts) * 16
    var out = [UInt8](repeating: 0, count: 256 * h * 4)
    var y0 = 0
    while y0 < h {
        let scroll = min(y0, max(0, h - 224))
        var f = TilesetScene.frame(ts, tiles: tiles, cgram: player.cgram, scrollY: scroll)
        TilesetScene.applyTileAnimations(&f, ts, animTiles: animTiles, frames: player.animator.frames)
        let rgba = PPUReferenceRenderer.render(f)
        for y in y0..<min(h, scroll + 224) {
            let src = (y - scroll) * 256 * 4
            out.replaceSubrange(y * 256 * 4..<((y + 1) * 256 * 4), with: rgba[src..<(src + 256 * 4)])
        }
        y0 = scroll + 224
    }
    return out
}

private func summary(_ ts: Tileset) -> String {
    let source = ts.rom.map { " (\($0.family) \($0.index), \($0.locations.count) locations)" } ?? ""
    if ts.kind == "palette" {
        return "\(ts.id): palette, \(ts.palettes?.count ?? 0) rows, \(ts.paletteCycles?.count ?? 0) cycles\(source)"
    }
    let b = TilesetBudget(ts)
    return "\(ts.id): \(ts.kind ?? "tiles") \(ts.bpp)bpp, \(ts.metatiles.count) metatiles, \(b.known) characters set, " +
        "\(b.bytes) B uploaded, \(ts.tileAnimations?.count ?? 0) tile animations\(source)"
}

private func details(_ ts: Tileset) {
    if let v = ts.vram {
        print(String(format: "  characters at VRAM $%04X:", v.charBase))
        for s in v.slots {
            let pack = s.pack.map { "pack \($0) from \(s.source ?? "?")" } ?? "unused"
            let own = s.ownTiles.map { $0 < s.tiles ? ", \($0) its own (the rest: an earlier pack's)" : "" } ?? ""
            print(String(format: "    slot %d: VRAM $%04X, characters %d-%d, ", s.slot, s.vram, s.firstTile, s.firstTile + s.tiles - 1) + pack + own)
        }
        print("  set: " + v.known.map { "\($0.firstTile)-\($0.firstTile + $0.tiles - 1)" }.joined(separator: ", "))
    }
    if ts.kind != "palette" {
        let b = TilesetBudget(ts)
        print("  metatiles name \(b.named) characters" +
              (b.namedUnknown.isEmpty ? "" : "; \(b.namedUnknown.count) outside the set ones (VRAM holds other data there)"))
    }
    for a in ts.tileAnimations ?? [] {
        print("  tile animation: characters \(a.tile)-\(a.tile + a.tiles - 1), frames \(a.frames.map(String.init).joined(separator: " ")), " +
              "steps \(a.steps.map { String(format: "$%02X", $0) }.joined(separator: " "))")
    }
    for c in ts.paletteCycles ?? [] {
        let what = c.order.map { ", order \($0.map(String.init).joined(separator: " "))" } ?? ""
        print(String(format: "  cycle %@: colours $%02X-$%02X every %d frames", c.kind, c.first,
                     c.first + c.count - (c.kind.hasPrefix("rotate") ? 0 : 1), c.delay == 0 ? 256 : c.delay) +
              (c.frames.map { ", \($0.count) frames" } ?? "") + what)
    }
    if let p = ts.preview { print("  preview: palette \(p.palette ?? "-"), layer 3 \(p.layer3 ?? "-")") }
    if let r = ts.rom {
        print("  rom: table \(r.table)" + (r.list.map { ", list \($0)" } ?? "") + (r.animations.map { ", animations \($0)" } ?? "") +
              ", locations " + r.locations.prefix(12).map(String.init).joined(separator: " ") + (r.locations.count > 12 ? " …" : ""))
    }
}
