import Foundation
import ChronoForgeCore

private let mapsUsage = """
usage: chronoforge maps import <rom.sfc> --project <project.ctproj> [--loc N ...]
       chronoforge maps show <project.ctproj> [id]
       chronoforge maps render <project.ctproj> <id> --out out.png [--frame N] [--scale K] [--camera X,Y]
                               [--hide bg1,bg2,bg3,obj,math]
       chronoforge maps verify <rom.sfc> --project <project.ctproj>
       chronoforge maps chest list <project.ctproj> [id]
       chronoforge maps chest add <project.ctproj> <id> --at X,Y (--item N | --gold G | --empty) [--index K]
       chronoforge maps chest move <project.ctproj> <id> <k> --at X,Y [--item N | --gold G | --empty]
       chronoforge maps chest remove <project.ctproj> <id> <k>
       chronoforge maps new-location <project.ctproj> --from <id> --number N [--name S]
                                     [--entrance <id> --at X,Y --to X,Y [--facing F]] [--list]
       chronoforge maps rom-list <project.ctproj> [id ...] [--remove] [--base rom.sfc]
         import: every location's map (or the ones given) as maps/loc_NNN, with the tilesets and
                 palettes they use that the project lacks
         show: the maps, or one map's header, screens, layers, tile properties, exits and treasure
         render: the whole map (or one 256x224 picture at --camera) through the PPU at field frame N
         verify: the imported maps against a fresh decode, and every map's structural checks
         chest: a map's chests with the flag each gets in a build of the whole project; add, move
                (the flag stays) or remove one (every later chest's flag moves)
         new-location: a location the game never loads (448, 452-455, 461-463) made from an imported
                map, with an exit at X,Y of the entrance map leading to its tile X,Y; --list puts both
                in rom.maps
         rom-list: the maps a ROM build writes, or puts ids in (takes them out with --remove); with
                --base, a dry run: free space left, TreasureRom, the chests' flags, or the refusal
"""

func cmdMaps(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show", "render", "verify", "chest", "new-location", "rom-list"].contains(operation) else {
        print(mapsUsage); return 2
    }
    if ["chest", "new-location", "rom-list"].contains(operation) { return cmdMapsEdit(operation, Array(args.dropFirst())) }
    var positional: [String] = [], options: [String: String] = [:], locations: [Int] = []
    var i = 1
    while i < args.count {
        if ["--project", "--out", "--frame", "--scale", "--camera", "--hide", "--loc"].contains(args[i]) {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            if args[i] == "--loc" {
                guard let n = Int(args[i + 1]), (0..<CTMapROM.locCount).contains(n) else { print("--loc takes 0-511"); return 2 }
                locations.append(n)
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
            guard positional.count == 1, let path = options["--project"] else { print(mapsUsage); return 2 }
            var project = try CTProject.load(from: URL(fileURLWithPath: path))
            let before = Set(project.tilesets.keys)
            let ids = try CTMaps.importMaps(rom: try readROM(positional[0]), into: &project,
                                            locations: locations.isEmpty ? nil : locations)
            try project.save()
            for id in ids { print(summary(project.maps[id]!)) }
            let added = project.tilesets.count - before.count
            print("imported \(ids.count) maps into \(path)" + (added > 0 ? " (and \(added) tilesets and palettes)" : ""))
        case "verify":
            guard positional.count == 1, let path = options["--project"] else { print(mapsUsage); return 2 }
            let project = try CTProject.load(from: URL(fileURLWithPath: path))
            let result = try CTMaps.verify(rom: try readROM(positional[0]), project: project)
            for p in result.problems { print("FAIL \(p)") }
            let differ = Set(result.problems.filter { $0.hasSuffix("differ from the ROM") }.map { $0.prefix { $0 != ":" } }).count
            let structural = result.problems.filter { !$0.hasSuffix("differ from the ROM") }.count
            print("\(result.checked - differ) of \(result.checked) imported maps match the ROM; " +
                  "\(structural) structural problems in \(project.maps.count) maps")
            return result.problems.isEmpty ? 0 : 1
        case "render":
            guard positional.count == 2, let out = options["--out"] else { print(mapsUsage); return 2 }
            let project = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
            guard let m = project.maps[positional[1]] else { print("no map \(positional[1])"); return 1 }
            let assets = try LocationScene.assets(for: m, project: project)
            var player = assets.t12.map { TilesetPlayer(tileset: $0, palette: assets.palette, cgram: TilesetScene.cgram(assets.palette)) }
            let n = max(0, Int(options["--frame"] ?? "0") ?? 0)
            player?.advance(to: n)
            let cgram = player?.cgram ?? TilesetScene.cgram(assets.palette)
            let hidden = Set((options["--hide"] ?? "").split(separator: ",").map(String.init))
            let show = LocationScene.Show(bg1: !hidden.contains("bg1"), bg2: !hidden.contains("bg2"), bg3: !hidden.contains("bg3"),
                                          obj: !hidden.contains("obj"), colorMath: !hidden.contains("math"))
            var picture: (width: Int, height: Int, rgba: [UInt8])
            if let camera = options["--camera"] {
                let xy = camera.split(separator: ",").compactMap { Int($0) }
                guard xy.count == 2 else { print("--camera takes X,Y"); return 2 }
                let c = LocationScene.clampCamera(m, x: xy[0], y: xy[1])
                let f = LocationScene.frame(m, assets: assets, cgram: cgram, cameraX: c.x, cameraY: c.y, frame: n,
                                            animFrames: player?.animator.frames, show: show)
                picture = (256, 224, PPUReferenceRenderer.render(f))
            } else {
                picture = LocationScene.render(m, assets: assets, cgram: cgram, frame: n,
                                               animFrames: player?.animator.frames, show: show)
            }
            let scale = max(1, min(4, Int(options["--scale"] ?? "1") ?? 1))
            var big = [UInt8](repeating: 0, count: picture.width * scale * picture.height * scale * 4)
            for y in 0..<(picture.height * scale) {
                for x in 0..<(picture.width * scale) {
                    let src = ((y / scale) * picture.width + x / scale) * 4, dst = (y * picture.width * scale + x) * 4
                    big.replaceSubrange(dst..<(dst + 4), with: picture.rgba[src..<(src + 4)])
                }
            }
            try PNG.writeRGBA(width: picture.width * scale, height: picture.height * scale, rgba: big)
                .write(to: URL(fileURLWithPath: out))
            let r = LocationScene.registers(m, show: show)
            print(String(format: "wrote %@: %@ %dx%d at frame %d, TM $%02X TS $%02X CGADSUB $%02X, palette %@",
                         out, m.id, picture.width, picture.height, n, r.tm, r.ts, r.cgadsub, assets.palette?.id ?? "gray"))
        default:
            guard (1...2).contains(positional.count) else { print(mapsUsage); return 2 }
            let project = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
            guard positional.count == 2 else {
                for m in project.maps.values.sorted(by: { $0.id < $1.id }) { print(summary(m)) }
                return 0
            }
            guard let m = project.maps[positional[1]] else { print("no map \(positional[1])"); return 1 }
            print(summary(m))
            details(m, project: project)
        }
        return 0
    } catch {
        print("maps \(operation) failed: \(error)")
        return 1
    }
}

private func cmdMapsEdit(_ operation: String, _ args: [String]) -> Int32 {
    var positional: [String] = [], options: [String: String] = [:], flags: Set<String> = []
    var i = 0
    while i < args.count {
        if ["--at", "--item", "--gold", "--index", "--from", "--number", "--name", "--entrance", "--to", "--facing",
            "--base"].contains(args[i]) {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            options[args[i]] = args[i + 1]; i += 2
        } else if ["--empty", "--list", "--remove"].contains(args[i]) {
            flags.insert(args[i]); i += 1
        } else {
            positional.append(args[i]); i += 1
        }
    }
    func xy(_ key: String) throws -> (Int, Int) {
        let v = (options[key] ?? "").split(separator: ",").compactMap { Int($0) }
        guard v.count == 2 else { throw CTROMBuildError("\(key) takes X,Y") }
        return (v[0], v[1])
    }
    func contents() throws -> CTTreasure.Contents? {
        if let item = options["--item"] {
            let digits = item.hasPrefix("$") ? String(item.dropFirst()) : item.hasPrefix("0x") ? String(item.dropFirst(2)) : nil
            guard let n = digits.map({ Int($0, radix: 16) }) ?? Int(item) else { throw CTROMBuildError("--item takes a number ($hex or decimal)") }
            return .item(n)
        }
        if let gold = options["--gold"] {
            guard let g = Int(gold) else { throw CTROMBuildError("--gold takes an amount") }
            return .gold(g)
        }
        return flags.contains("--empty") ? .empty : nil
    }
    var sub = ""
    if operation == "chest", !positional.isEmpty { sub = positional.removeFirst() }
    do {
        guard let path = positional.first else { print(mapsUsage); return 2 }
        var project = try CTProject.load(from: URL(fileURLWithPath: path))
        switch operation {
        case "chest":
            if sub == "list" {
                let numbers = CTTreasure.projectNumbers(project)
                let ids = positional.count > 1 ? [positional[1]] : project.maps.keys.sorted()
                for id in ids {
                    guard let m = project.maps[id] else { print("no map \(id)"); return 1 }
                    guard !(m.treasure ?? []).isEmpty else { continue }
                    print(chestLines(m, flags: numbers?[id]))
                }
                if let total = CTTreasure.projectTotal(project) {
                    print("\(total) of \(CTTreasure.flagCount) chest flags in a build of every location")
                } else {
                    print("flags: not every location has a map (maps import to number them)")
                }
                return 0
            }
            guard positional.count >= 2, var m = project.maps[positional[1]] else { print(mapsUsage); return 2 }
            switch sub {
            case "add":
                guard let what = try contents() else { print("chest add takes --item, --gold or --empty"); return 2 }
                let (x, y) = try xy("--at")
                try CTTreasure.add(&m, x: x, y: y, contents: what, at: options["--index"].flatMap { Int($0) })
            case "move", "remove":
                guard positional.count == 3, let k = Int(positional[2]) else { print(mapsUsage); return 2 }
                if sub == "remove" {
                    try CTTreasure.remove(&m, k)
                } else {
                    let (x, y) = try xy("--at")
                    try CTTreasure.move(&m, k, x: x, y: y, contents: try contents())
                }
            default:
                print(mapsUsage); return 2
            }
            if let total = CTTreasure.projectTotal(project, replacing: m), total > CTTreasure.flagCount {
                print("refused: a build of every location would need \(total) chest flags; Treasure_Flags has \(CTTreasure.flagCount)")
                return 1
            }
            project.maps[m.id] = m
            try project.save()
            print(chestLines(m, flags: CTTreasure.projectNumbers(project)?[m.id]))
        case "new-location":
            guard positional.count == 1, let from = options["--from"], let number = options["--number"].flatMap({ Int($0) }) else {
                print(mapsUsage); return 2
            }
            var entrance: CTNewLocation.Entrance?
            if let at = options["--entrance"] {
                let (x, y) = try xy("--at"), (tx, ty) = try xy("--to")
                entrance = .init(map: at, x: x, y: y, toX: tx, toY: ty, facing: options["--facing"].flatMap { Int($0) } ?? 0)
            }
            let ids = try CTNewLocation.create(in: &project, from: from, number: number, entrance: entrance,
                                               name: options["--name"], list: flags.contains("--list"))
            try project.save()
            let m = project.maps[ids[0]]!
            print(summary(m))
            print("  copied from \(from): its header, MapProps (a free Map_PropsPtrs slot when built), exits, event pack " +
                  "and chests (with flags of their own)")
            if let e = entrance { print("  entrance: \(e.map) (\(e.x),\(e.y)) -> \(m.id) (\(e.toX),\(e.toY))") }
            if flags.contains("--list") { print("  listed in rom.maps: \(ids.joined(separator: ", "))") }
        default:
            let ids = Array(positional.dropFirst())
            if !ids.isEmpty {
                let changed = try CTMapList.set(ids, listed: !flags.contains("--remove"), in: &project)
                try project.save()
                let verb: String = flags.contains("--remove") ? "took out of" : "put in"
                let what: String = changed.isEmpty ? "nothing (already so)" : changed.joined(separator: ", ")
                print("\(verb) rom.maps: \(what)")
            }
            let listed = CTMapList.listed(project)
            let names: String = listed.isEmpty ? "" : " (\(listed.joined(separator: ", ")))"
            print("rom.maps: \(listed.count) maps\(names)")
            if let base = options["--base"] {
                let b = CTMapList.budget(base: try readROM(base), project: project)
                if let refusal = b.refusal {
                    print("refused: \(refusal)")
                    return 1
                }
                print("a build would leave \(b.freeBytesLeft ?? 0) bytes of free space")
                if let t = b.treasure {
                    let from: String = t.from.map { (f: String) -> String in " from \(f)" } ?? ""
                    let flagsLeft: String = "\(t.flagsLeft) of \(CTTreasure.flagCount) flags left"
                    print("TreasureRom: \(t.records) records (\(flagsLeft)) at \(t.address), \(t.placement)\(from), \(t.renumbered) chests renumbered")
                    for e in t.evicted ?? [] {
                        let entries: String = e.entries.map { (n: Int) -> String in String(n) }.joined(separator: ", ")
                        print("  moves MapProps entry \(entries) \(e.from) -> \(e.to)")
                    }
                } else {
                    print("TreasureRom: unchanged")
                }
                for (id, f) in b.flags.sorted(by: { $0.key < $1.key }) where !f.isEmpty {
                    print("  \(id) chest flags \(f.map(String.init).joined(separator: ", "))")
                }
            }
        }
        return 0
    } catch {
        print("maps \(operation) failed: \(error)")
        return 1
    }
}

private func chestLines(_ m: GameMap, flags: [Int]?) -> String {
    var lines = ["\(m.id): \(m.treasure?.count ?? 0) chests"]
    for (k, t) in (m.treasure ?? []).enumerated() {
        let what: String
        switch CTTreasure.Contents(word: t.contents) {
        case .gold(let g): what = "\(g) G"
        case .empty: what = "nothing"
        case .item(let n): what = String(format: "item $%03X", n)
        }
        let flag = flags.flatMap { $0.indices.contains(k) ? " flag \($0[k])" : nil } ?? ""
        lines.append("  chest \(k): (\(t.x),\(t.y)) \(what)\(flag)")
    }
    return lines.joined(separator: "\n")
}

private func summary(_ m: GameMap) -> String {
    let layers = m.layers.map { l -> String in
        let s = LocationScene.layerSize(m, l)
        return "BG\(l.bg) \(s.width)x\(s.height)"
    }.joined(separator: ", ")
    let source = m.rom.map { " (location \($0.location), MapProps \($0.mapProps))" } ?? ""
    return "\(m.id): \(m.tileset.isEmpty ? "no tileset" : m.tileset), \(layers), \(m.exits.count) exits, " +
        "\(m.treasure?.count ?? 0) treasure\(source)"
}

private func details(_ m: GameMap, project: CTProject) {
    if let l = m.location {
        print(String(format: "  header: music $%02X, Tileset12 %@, Tileset3 %@, palette %d, events %d", l.music,
                     l.tileset12 == CTMapROM.none ? "none" : "\(l.tileset12)", l.tileset3 == CTMapROM.none ? "none" : "\(l.tileset3)",
                     l.palette, l.events))
        let lim = l.limits
        print(lim[0] & CTMapROM.limitsNone != 0 ? "  camera limits: layer 1's edges"
              : "  camera limits: columns \(lim[0])-\(lim[2]), rows \(lim[1])-\(lim[3])")
    }
    let r = LocationScene.registers(m)
    print(String(format: "  PPU: BGMODE $%02X, BG1SC $%02X BG2SC $%02X BG3SC $%02X, TM $%02X TS $%02X CGWSEL $%02X CGADSUB $%02X",
                 r.bgmode, r.bg[0].sc, r.bg[1].sc, r.bg[2].sc, r.tm, r.ts, r.cgwsel, r.cgadsub))
    if let s = m.settings {
        let s2 = CTMapROM.ownStep(s.move2), s3 = CTMapROM.ownStep(s.move3)
        print("  scroll: layer 2 \(s.halfRate2 ? "half rate" : s.ownStep2 ? "own step only" : "with the camera"), " +
              "step \(s2.x),\(s2.y)/16 px; layer 3 \(s.ownStep3 ? "own step only" : "with the camera"), step \(s3.x),\(s3.y)/16 px")
    }
    if let tp = m.tileProps, let plane = CTTilePropsPlane(tp) {
        var walk: [String: Int] = [:], push = 0, overhead = 0, objects = 0, shapes: Set<Int> = []
        for y in 0..<plane.height {
            for x in 0..<plane.width {
                let t = plane[x, y]
                walk[t.walkA.rawValue, default: 0] += 1
                push += t.pushSpeed > 0 ? 1 : 0
                overhead += t.overheadLow || t.overheadHigh ? 1 : 0
                objects += t.blocksObjects ? 1 : 0
                shapes.insert(t.shape)
            }
        }
        print("  tiles (half A): " + walk.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ") +
              "; push \(push), overhead \(overhead), object walls \(objects), \(shapes.count) shapes")
    }
    for (n, e) in m.exits.enumerated() {
        let span = (e.span ?? 0) > 0 ? " +\(e.span!) \(e.vertical == true ? "down" : "across")" : ""
        print("  exit \(n): (\(e.x),\(e.y))\(span) -> \(e.map) (\(e.toX),\(e.toY)) facing \(e.facing ?? 0)")
    }
    for (n, t) in (m.treasure ?? []).enumerated() {
        let what: String
        switch CTMapROM.TreasureKind(contents: t.contents) {
        case .gold(let g): what = "\(g) G"
        case .empty: what = "nothing"
        case .item(let i): what = String(format: "item $%03X", i)
        }
        print("  treasure \(n): (\(t.x),\(t.y)) \(what)")
    }
    for p in LocationScene.invariants(m, project: project) { print("  CHECK \(p)") }
    if let r = m.rom {
        print("  rom: record \(r.record), MapProps \(r.mapProps) at \(r.packedAt) (\(r.packedBytes) B -> \(r.unpackedBytes) B)" +
              (r.staleTiles > 0 ? ", \(r.staleTiles) tiles past the map's end" : "") +
              (r.treasureList != r.location ? ", treasure list of location \(r.treasureList)" : ""))
    }
}
