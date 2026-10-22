// CTLocationRender.swift — a location drawn the way the field draws it: the
// PPU registers from its header (Ppu_SetBgLayout, Ppu_ApplyMapScreens), its
// layers streamed into the field's 64x32 tilemaps around the camera
// (LocLoad_DrawMap), characters and palette from its tilesets
// (CTTilesets), and the structural checks an edited map must pass.
import Foundation

public enum LocationScene {
    /// Which parts of the picture are on (the Studio's layer toggles).
    public struct Show: Equatable, Sendable {
        public var bg1 = true, bg2 = true, bg3 = true, obj = true, colorMath = true
        public init(bg1: Bool = true, bg2: Bool = true, bg3: Bool = true, obj: Bool = true, colorMath: Bool = true) {
            self.bg1 = bg1; self.bg2 = bg2; self.bg3 = bg3; self.obj = obj; self.colorMath = colorMath
        }
        var mask: UInt8 { (bg1 ? 1 : 0) | (bg2 ? 2 : 0) | (bg3 ? 4 : 0) | (obj ? 0x10 : 0) }
    }

    /// Everything a location's picture reads besides the map.
    public struct Assets: Sendable {
        public var t12: Tileset?, t3: Tileset?, palette: Tileset?
        public var t12Tiles: [[UInt8]], t3Tiles: [[UInt8]], animTiles: [[UInt8]]
        public init(t12: Tileset? = nil, t3: Tileset? = nil, palette: Tileset? = nil, t12Tiles: [[UInt8]] = [],
                    t3Tiles: [[UInt8]] = [], animTiles: [[UInt8]] = []) {
            self.t12 = t12; self.t3 = t3; self.palette = palette
            self.t12Tiles = t12Tiles; self.t3Tiles = t3Tiles; self.animTiles = animTiles
        }
    }

    public static func tileset3ID(_ m: GameMap) -> String? {
        guard let t = m.location?.tileset3, t != CTMapROM.none else { return nil }
        return CTTilesets.id3(t)
    }

    public static func paletteID(_ m: GameMap, project: CTProject) -> String? {
        if let p = m.location?.palette { return CTTilesets.idPalette(p) }
        return project.tilesets[m.tileset]?.preview?.palette
    }

    /// The tilesets, palette and sheets a map's picture needs, from the project.
    public static func assets(for m: GameMap, project: CTProject) throws -> Assets {
        func tiles(_ ts: Tileset?) throws -> [[UInt8]] {
            guard let ts, ts.sheet != nil || ts.blob != nil else { return [] }
            let flat = try project.tileIndices(of: ts)
            return stride(from: 0, to: flat.count, by: 64).map { Array(flat[$0..<min(flat.count, $0 + 64)]) }
        }
        let t12 = project.tilesets[m.tileset].flatMap { $0.kind == "bg3" ? nil : $0 }
        let t3 = tileset3ID(m).flatMap { project.tilesets[$0] } ?? project.tilesets[m.tileset].flatMap { $0.kind == "bg3" ? $0 : nil }
        let anim = try t12?.animSheet.map { SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: $0))) } ?? []
        return Assets(t12: t12, t3: t3, palette: paletteID(m, project: project).flatMap { project.tilesets[$0] },
                      t12Tiles: try tiles(t12), t3Tiles: try tiles(t3), animTiles: anim)
    }

    // MARK: Registers

    /// TM, TS and CGADSUB of a map: from its settings as the game computes them;
    /// a hand-made map without settings shows its layers and OBJ on the main screen.
    public static func screens(_ m: GameMap) -> (tm: UInt8, ts: UInt8, cgadsub: UInt8) {
        guard let s = m.settings else {
            let bgs = m.layers.reduce(0) { $0 | ((1...3).contains($1.bg) ? 1 << ($1.bg - 1) : 0) }
            return (UInt8(bgs | 0x10), 0, 0)
        }
        return CTMapROM.screens(s.screens, colorMath: s.colorMath, tileset3: m.location?.tileset3 ?? 0)
    }

    /// The field's registers for a map (before scroll): mode 1 with BG3 high,
    /// BG1/2 characters at $1000 and BG3's at $5000, tilemaps $6000/$6800/$7000
    /// at 64x32, CGWSEL adding the sub screen, COLDATA black, and the map's
    /// TM, TS and CGADSUB (masked by `show`).
    public static func registers(_ m: GameMap, show: Show = Show()) -> PPURegisters {
        var r = PPURegisters()
        r.bgmode = CTMapROM.bgmode
        r.writeBG12NBA(CTMapROM.bg12nba)
        r.writeBG34NBA(CTMapROM.bg34nba)
        for k in 0..<3 { r.bg[k].sc = UInt8(CTMapROM.tilemaps[k] >> 8 | 1) }
        let s = screens(m)
        r.tm = s.tm & show.mask
        r.ts = s.ts & show.mask
        r.cgwsel = CTMapROM.cgwsel
        r.cgadsub = show.colorMath ? s.cgadsub : 0
        r.writeCOLDATA(CTMapROM.coldata)
        return r
    }

    /// A layer's scroll (pixels) for a camera: layer 2 at half rate when the map
    /// says so (Map_InitOrigin), a layer that moves by its own step only stays
    /// at its origin (0) and drifts step/16 pixels a frame (Map_Unk91AC).
    public static func scroll(_ m: GameMap, layer: Int, cameraX: Int, cameraY: Int, frame: Int = 0) -> (x: Int, y: Int) {
        // The camera is taken as the entry origin: Map_InitOrigin starts a half-rate
        // layer 2 at half of it, and Map_Unk91AC adds a layer's own step every
        // frame (the own-step bits only drop the camera's later steps).
        guard let s = m.settings, layer > 1 else { return (cameraX, cameraY) }
        let step = CTMapROM.ownStep(layer == 2 ? s.move2 : s.move3)
        let half = layer == 2 && s.halfRate2
        return ((half ? cameraX / 2 : cameraX) + step.x * frame / 16, (half ? cameraY / 2 : cameraY) + step.y * frame / 16)
    }

    public static func layerSize(_ m: GameMap, _ l: GameMap.Layer) -> CTMapROM.Size {
        CTMapROM.Size(width: l.width ?? m.width, height: l.height ?? m.height)
    }

    /// The camera kept inside the map's limits (pixels of the top-left corner).
    public static func clampCamera(_ m: GameMap, x: Int, y: Int) -> (x: Int, y: Int) {
        (min(max(0, x), max(0, m.width * 16 - 256)), min(max(0, y), max(0, m.height * 16 - 224)))
    }

    // MARK: The picture

    /// One field picture at a camera: the three layers streamed into the
    /// tilemaps the way the field keeps them (only the cells on screen; a
    /// 48-cell layer's wrap past its edge shows nothing), tile animations and
    /// the CGRAM given, and a 16x16 OBJ placeholder on each treasure.
    public static func frame(_ m: GameMap, assets a: Assets, cgram: [UInt16], cameraX: Int, cameraY: Int,
                             frame n: Int = 0, animFrames: [Int]? = nil, show: Show = Show()) -> PPUFrame {
        var f = PPUFrame(registers: registers(m, show: show))
        if !a.t12Tiles.isEmpty {
            f.storeTiles(Array(a.t12Tiles.prefix(CTTilesetROM.window).joined()), bpp: 4, atWord: CTTilesetROM.bg12Char)
        }
        if !a.t3Tiles.isEmpty {                              // the BG3 upload is $1000 bytes: 256 characters
            f.storeTiles(Array(a.t3Tiles.prefix(256).joined()).map { $0 & 3 }, bpp: 2, atWord: CTTilesetROM.bg3Char)
        }
        if let t12 = a.t12, let frames = animFrames {
            TilesetScene.applyTileAnimations(&f, t12, animTiles: a.animTiles, frames: frames)
        }
        f.cgram = cgram
        for l in m.layers where (1...3).contains(l.bg) {
            guard let ts = l.bg == 3 ? a.t3 : a.t12 else { continue }
            let k = l.bg - 1, size = layerSize(m, l)
            let sc = scroll(m, layer: l.bg, cameraX: cameraX, cameraY: cameraY, frame: n)
            let colMask = CTMapROM.wrapMask(size.width), rowMask = CTMapROM.wrapMask(size.height)
            f.setAllLines {
                $0.bg[k].hofs = UInt16(sc.x & 0x3FF)
                $0.bg[k].vofs = UInt16((sc.y - 1) & 0x3FF)
            }
            let base = CTMapROM.tilemaps[k]
            for ty in (sc.y >> 3)...((sc.y + 223) >> 3) {
                for tx in (sc.x >> 3)...((sc.x + 255) >> 3) {
                    let mx = (tx >> 1) & colMask, my = (ty >> 1) & rowMask
                    var word: UInt16 = 0
                    if mx < size.width, my < size.height, my * size.width + mx < l.metatiles.count {
                        let mt = l.metatiles[my * size.width + mx]
                        if mt >= 0, mt < ts.metatiles.count {
                            let chips = ts.metatiles[mt].chips
                            let q = (tx & 1) + 2 * (ty & 1)
                            if q < chips.count { word = chips[q].word }
                        }
                    }
                    f.vram[(base + (tx & 32 != 0 ? 0x400 : 0) + (ty & 31) * 32 + (tx & 31)) & 0x7FFF] = word
                }
            }
        }
        // OBJ placeholders: a 16x16 ring (tiles 0, 1, 16, 17 at OBSEL 0) on each treasure.
        var ring = [UInt8](repeating: 0, count: 256)
        for y in 0..<16 { for x in 0..<16 where (x == 1 || x == 14 || y == 1 || y == 14) && (1...14).contains(x) && (1...14).contains(y) {
            ring[y * 16 + x] = 15 } }
        for (t, (tx, ty)) in [(0, (0, 0)), (1, (8, 0)), (16, (0, 8)), (17, (8, 8))] {
            f.storeTiles((0..<64).map { ring[(ty + $0 / 8) * 16 + tx + $0 % 8] }, bpp: 4, atWord: t * 16)
        }
        f.setAllLines { $0.obsel = 0x00 }
        for (i, t) in (m.treasure ?? []).prefix(128).enumerated() {
            let x = t.x * 16 - cameraX, y = t.y * 16 - cameraY
            guard (-16..<256).contains(x), (-16..<224).contains(y) else { continue }
            f.setOBJ(i, x: x, y: y & 0xFF, tile: 0, palette: 0, priority: 2, large: true)
        }
        return f
    }

    /// The whole of layer 1's area as RGBA: field pictures at successive
    /// cameras, stitched. Layers 2 and 3 scroll as they would with that camera.
    public static func render(_ m: GameMap, assets a: Assets, cgram: [UInt16], frame n: Int = 0,
                              animFrames: [Int]? = nil, show: Show = Show()) -> (width: Int, height: Int, rgba: [UInt8]) {
        let w = m.width * 16, h = m.height * 16
        var out = [UInt8](repeating: 0, count: w * h * 4)
        var y0 = 0
        while y0 < h {
            let cy = min(y0, max(0, h - 224))
            var x0 = 0
            while x0 < w {
                let cx = min(x0, max(0, w - 256))
                let rgba = PPUReferenceRenderer.render(frame(m, assets: a, cgram: cgram, cameraX: cx, cameraY: cy,
                                                             frame: n, animFrames: animFrames, show: show))
                for y in y0..<min(h, cy + 224) {
                    let src = ((y - cy) * 256 + (x0 - cx)) * 4, cols = min(w, cx + 256) - x0
                    let dst = (y * w + x0) * 4
                    out.replaceSubrange(dst..<(dst + cols * 4), with: rgba[src..<(src + cols * 4)])
                }
                x0 = cx + 256
            }
            y0 = cy + 224
        }
        return (w, h, out)
    }

    // MARK: Checks

    /// What an edited (or imported) map must hold: layer cell counts, metatile
    /// numbers inside their tables, tile properties the size of layer 1 with
    /// HiBits bits 0/1 equal to the layers' bit 8, and ROM sizes for maps that
    /// came from the ROM.
    public static func invariants(_ m: GameMap, project: CTProject) -> [String] {
        var out: [String] = []
        let t12 = project.tilesets[m.tileset]
        let t3 = tileset3ID(m).flatMap { project.tilesets[$0] }
        let romSizes: Set<Int> = [16, 32, 48, 64]
        for l in m.layers {
            let s = layerSize(m, l)
            // A hand-made layer without its own size predates sizes: only its metatiles are checked.
            if l.width != nil || m.rom != nil, l.metatiles.count != s.cells { out.append("layer \(l.bg) has \(l.metatiles.count) cells for \(s.width) x \(s.height)") }
            if m.rom != nil, !romSizes.contains(s.width) || !romSizes.contains(s.height) {
                out.append("layer \(l.bg) is \(s.width) x \(s.height): the ROM's layers are 16, 32, 48 or 64 each way")
            }
            let limit = l.bg == 3 ? (t3?.metatiles.count ?? (m.rom != nil ? 256 : nil)) : (t12?.metatiles.count ?? (m.rom != nil ? 512 : nil))
            if let limit, let bad = l.metatiles.first(where: { $0 < 0 || $0 >= limit }) {
                out.append("layer \(l.bg) names metatile \(bad) of \(limit)")
            }
        }
        if let tp = m.tileProps {
            guard let plane = CTTilePropsPlane(tp) else { return out + ["tile properties are not \(tp.width) x \(tp.height) hex bytes"] }
            if (tp.width, tp.height) != (m.width, m.height) { out.append("tile properties are \(tp.width) x \(tp.height), layer 1 \(m.width) x \(m.height)") }
            for l in m.layers where l.bg <= 2 {
                let s = layerSize(m, l), bit: UInt8 = l.bg == 1 ? 1 : 2
                var bad = 0
                for y in 0..<min(s.height, plane.height) {
                    for x in 0..<min(s.width, plane.width) where y * s.width + x < l.metatiles.count {
                        if (l.metatiles[y * s.width + x] >= 256) != (plane.hiBits[y * plane.width + x] & bit != 0) { bad += 1 }
                    }
                }
                if bad > 0 { out.append("\(bad) layer-\(l.bg) cells disagree with HiBits bit \(l.bg - 1)") }
            }
        }
        return out
    }
}
