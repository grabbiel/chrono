import Foundation
import ChronoForgeCore

private let mapsUsage = """
usage: chronoforge maps import <rom.sfc> --project <project.ctproj> [--loc N ...]
       chronoforge maps show <project.ctproj> [id]
       chronoforge maps render <project.ctproj> <id> --out out.png [--frame N] [--scale K] [--camera X,Y]
                               [--hide bg1,bg2,bg3,obj,math]
       chronoforge maps verify <rom.sfc> --project <project.ctproj>
         import: every location's map (or the ones given) as maps/loc_NNN, with the tilesets and
                 palettes they use that the project lacks
         show: the maps, or one map's header, screens, layers, tile properties, exits and treasure
         render: the whole map (or one 256x224 picture at --camera) through the PPU at field frame N
         verify: the imported maps against a fresh decode, and every map's structural checks
"""

func cmdMaps(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show", "render", "verify"].contains(operation) else {
        print(mapsUsage); return 2
    }
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
