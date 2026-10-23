import Foundation
import ChronoForgeCore

private let spritesUsage = """
usage: chronoforge sprites import <rom.sfc> --project <project.ctproj> [--set N ...] [--enemy N ...] [--npc N ...]
                                  [--family pc|enemy|npc ...]
         (no selector: the 7 playable characters and every enemy; --family npc: every NPC record the
          event packs load; with --set, --enemy, --npc or --family, only those)
       chronoforge sprites show <project.ctproj | rom.sfc> [sprite] [--frame N] [--onion N]
                                [--png out.png] [--scale K]
         <sprite>: a project sprite id; from a ROM a name (crono ... magus), 0-6, enemy_NNN or npc_NNN
"""

/// A sprite with its sheet tiles and palette, from a project or decoded from a ROM.
private struct LoadedSprite {
    var sprite: SpriteDef
    var sheet: [[UInt8]]
    var palette: [BGR555]
}

private func loadSprites(_ path: String) throws -> [LoadedSprite] {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        let project = try CTProject.load(from: URL(fileURLWithPath: path))
        return try project.sprites.values.sorted { $0.id < $1.id }.map { s in
            let png = try PNG.readIndexed(url: project.fileURL(relative: s.sheet))
            return LoadedSprite(sprite: s, sheet: SpriteSheet.tiles(png), palette: png.palette)
        }
    }
    let rom = try readROM(path)
    var out = (0..<CTSpriteROM.sets).map { c in
        let d = CTSpriteROM.decode(rom: rom, set: c)
        let sheet = CTSpriteROM.sheet(d)
        return LoadedSprite(sprite: CTSpriteROM.spriteDef(d, id: CTSpriteROM.names[c]),
                            sheet: SpriteSheet.tiles(sheet), palette: sheet.palette)
    }
    for i in 0..<CTEnemySpriteROM.ids {
        let d = try CTEnemySpriteROM.decode(rom: rom, id: i)
        let sheet = CTEnemySpriteROM.sheet(d)
        out.append(LoadedSprite(sprite: CTEnemySpriteROM.spriteDef(d, id: CTEnemySpriteROM.id(i)),
                                sheet: SpriteSheet.tiles(sheet), palette: sheet.palette))
    }
    for (r, field) in try CTNPCSpriteROM.usage(rom: rom).sorted(by: { $0.key < $1.key }) {
        let d = try CTNPCSpriteROM.decode(rom: rom, record: r)
        let sheet = CTNPCSpriteROM.sheet(d)
        out.append(LoadedSprite(sprite: CTNPCSpriteROM.spriteDef(d, id: CTNPCSpriteROM.id(r), field: field),
                                sheet: SpriteSheet.tiles(sheet), palette: sheet.palette))
    }
    return out
}

/// "1 2 3 … (40)": the first `n` numbers of a list and its length.
private func shortList(_ xs: [Int], _ n: Int = 12) -> String {
    let head = xs.prefix(n).map(String.init).joined(separator: " ")
    return xs.count > n ? "\(head) … (\(xs.count))" : head
}

func cmdSprites(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show"].contains(operation) else {
        print(spritesUsage); return 2
    }
    var positional: [String] = [], options: [String: String] = [:], sets: [Int] = [], enemies: [Int] = []
    var npcs: [Int] = [], families: Set<String> = []
    var i = 1
    while i < args.count {
        if ["--project", "--frame", "--onion", "--png", "--scale", "--set", "--enemy", "--npc", "--family"].contains(args[i]) {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            if args[i] == "--npc" {
                guard let n = Int(args[i + 1]) else { print("--npc takes a record 7-255"); return 2 }
                npcs.append(n)
            } else if args[i] == "--family" {
                guard ["pc", "enemy", "npc"].contains(args[i + 1]) else { print("--family takes pc, enemy or npc"); return 2 }
                families.insert(args[i + 1])
            } else if args[i] == "--enemy" {
                guard let n = Int(args[i + 1]) else { print("--enemy takes 0-254"); return 2 }
                enemies.append(n)
            } else if args[i] == "--set" {
                guard let n = Int(args[i + 1]) ?? CTSpriteROM.names.firstIndex(of: args[i + 1]) else {
                    print("--set takes 0-6 or a name"); return 2
                }
                sets.append(n)
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
            guard positional.count == 1, let path = options["--project"] else { print(spritesUsage); return 2 }
            var project = try CTProject.load(from: URL(fileURLWithPath: path))
            let rom = try readROM(positional[0])
            let all = sets.isEmpty && enemies.isEmpty && npcs.isEmpty && families.isEmpty
            var ids: [String] = []
            if families.contains("pc") && sets.isEmpty { sets = Array(0..<CTSpriteROM.sets) }
            if all || !sets.isEmpty {
                let wanted: [Int] = all ? Array(0..<CTSpriteROM.sets) : sets
                ids = try CTSpriteROM.importSprites(rom: rom, into: &project, sets: wanted)
            }
            var foes: (ids: [String], fieldOnly: [Int]) = ([], [])
            if all || !enemies.isEmpty || families.contains("enemy") {
                let wanted: [Int]? = all || (families.contains("enemy") && enemies.isEmpty) ? nil : enemies
                foes = try CTEnemySpriteROM.importSprites(rom: rom, into: &project, ids: wanted)
            }
            var people: [String] = []
            if !npcs.isEmpty || families.contains("npc") {
                let wanted: [Int]? = npcs.isEmpty ? nil : npcs
                people = try CTNPCSpriteROM.importSprites(rom: rom, into: &project, records: wanted)
            }
            try project.save()
            for id in ids {
                let s = project.sprites[id]!
                print("\(id): set \(s.rom!.set), \(s.rom!.tileCount) tiles, \(s.frames.count) frames, " +
                      "\(s.animations.count) animations -> \(s.sheet)")
            }
            if !foes.ids.isEmpty {
                var layouts = [0, 0, 0, 0]
                for id in foes.ids { layouts[project.sprites[id]!.rom!.layout ?? 0] += 1 }
                let counts = layouts.map(String.init).joined(separator: "/")
                let large = foes.fieldOnly.map(String.init).joined(separator: " ")
                print("enemies: \(foes.ids.count) sprites (frame layouts 0/1/2/3: \(counts)) -> sprites/enemy_NNN.*" +
                      (foes.fieldOnly.isEmpty ? "" : "; layout 3 as the field shows it, read-only: " + large))
            }
            if !people.isEmpty {
                var sizes = [0, 0]
                var packs = Set<Int>(), locations = Set<Int>()
                for id in people {
                    let s = project.sprites[id]!
                    sizes[s.rom!.layout ?? 0] += 1
                    packs.formUnion(s.field?.packs ?? [])
                    locations.formUnion(s.field?.locations ?? [])
                }
                print("npcs: \(people.count) sprites (size classes 0/1: \(sizes[0])/\(sizes[1])), loaded by " +
                      "\(packs.count) event packs at \(locations.count) locations -> sprites/npc_NNN.*")
            }
            let linked = project.characters.values.filter { c in c.sprite.map((ids + foes.ids).contains) ?? false }.map(\.id).sorted()
            if !linked.isEmpty { print("characters with these sprites: \(linked.joined(separator: " "))") }
        default:
            guard (1...2).contains(positional.count) else { print(spritesUsage); return 2 }
            let all = try loadSprites(positional[0])
            guard positional.count == 2 else {
                for l in all {
                    let s = l.sprite
                    let stream = s.stream.map { ", streams \($0.columns) x \($0.rows) cells at OBJ tile \($0.baseTile)" } ?? ""
                    let source = s.rom.map { ", from set \($0.set) (\($0.frames))" } ?? ""
                    let used = s.field.map { ", loaded by \($0.packs.count) packs at \($0.locations.count) locations" } ?? ""
                    print("\(s.id): \(s.frames.count) frames, \(s.animations.count) animations, \(l.sheet.count) sheet tiles\(stream)\(source)\(used)")
                }
                return 0
            }
            let key = positional[1]
            guard let l = all.first(where: { $0.sprite.id == key || $0.sprite.rom.map { String($0.set) == key } ?? false }) else {
                print("no sprite \(key)"); return 1
            }
            let s = l.sprite
            let f = Int(options["--frame"] ?? "0") ?? -1
            guard s.frames.indices.contains(f) else { print("\(s.id) has frames 0-\(s.frames.count - 1)"); return 1 }
            var o = SpriteScene.Options()
            if let onion = options["--onion"] {
                guard let n = Int(onion), s.frames.indices.contains(n) else { print("no onion frame \(onion)"); return 1 }
                o.onionFrame = n
            }
            print("\(s.id) frame \(f) of \(s.frames.count)")
            if let field = s.field {
                print("  field size byte \(field.size); event packs \(shortList(field.packs)); locations \(shortList(field.locations))")
            }
            for (n, t) in s.frames[f].tiles.enumerated() {
                print(String(format: "  OBJ %d: x %4d y %4d tile %3d %@ pal %d prio %d%@%@", n, t.x, t.y,
                             SpriteScene.objTile(s, t), t.size16 ? "16x16" : "8x8  ", t.pal, t.priority ?? CTSpriteROM.priority,
                             t.hflip ? " hflip" : "", t.vflip ? " vflip" : ""))
            }
            if let cells = s.frames[f].cells, let st = s.stream {
                for r in 0..<st.rows {
                    print("  cells row \(r): " + (0..<st.columns).map { c in
                        let w = r * st.columns + c < cells.count ? cells[r * st.columns + c] : 0
                        return String(format: "%04X", w)
                    }.joined(separator: " "))
                }
            }
            let b = SpriteScene.budget(s, frame: f, options: o)
            print("  budget: \(b.objs) OAM entries, \(b.tiles) OBJ tiles" +
                  (s.stream == nil ? "" : ", \(b.streamedTiles) streamed tiles") +
                  "; worst line \(b.maxOBJsOnALine)/\(PPUOBJEvaluator.maxOBJsPerLine) OBJs, " +
                  "\(b.maxSliversOnALine)/\(PPUOBJEvaluator.maxSliversPerLine) slivers" +
                  (b.rangeOver ? ", range over" : "") + (b.timeOver ? ", time over" : ""))
            let using = s.animations.filter { $0.frames.contains(f) }.map(\.id)
            if !using.isEmpty { print("  in animations: \(using.prefix(12).joined(separator: " "))\(using.count > 12 ? " …" : "")") }
            if let out = options["--png"] {
                let scale = max(1, min(8, Int(options["--scale"] ?? "4") ?? 4))
                let rgba = PPUReferenceRenderer.render(SpriteScene.frame(s, frame: f, sheet: l.sheet, sheetPalette: l.palette, options: o))
                var boxes = [SpriteScene.bounds(s, frame: f, options: o)]
                if let n = o.onionFrame { boxes.append(SpriteScene.bounds(s, frame: n, options: o)) }
                let found = boxes.compactMap { $0 }
                let x0 = found.map(\.x).min() ?? 0, y0 = found.map(\.y).min() ?? 0
                let x1 = found.map { $0.x + $0.w }.max() ?? 8, y1 = found.map { $0.y + $0.h }.max() ?? 8
                let w = (x1 - x0) * scale, h = (y1 - y0) * scale
                var crop = [UInt8](repeating: 0, count: w * h * 4)
                for y in 0..<h {
                    for x in 0..<w {
                        let src = ((y0 + y / scale) * PPUFrame.width + x0 + x / scale) * 4
                        crop.replaceSubrange((y * w + x) * 4..<((y * w + x) * 4 + 4), with: rgba[src..<(src + 4)])
                    }
                }
                try PNG.writeRGBA(width: w, height: h, rgba: crop).write(to: URL(fileURLWithPath: out))
                print("wrote \(out): \(x1 - x0) x \(y1 - y0) PPU pixels at \(scale)x, origin at " +
                      "(\(o.originX - x0), \(o.originY - y0))")
            }
        }
        return 0
    } catch {
        print("sprites \(operation) failed: \(error)")
        return 1
    }
}
