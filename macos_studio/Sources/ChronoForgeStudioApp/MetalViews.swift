// MetalViews.swift — NSViewRepresentable wrappers around SNESPPUView. Each
// preview is a real PPU picture: tiles and tilemaps in VRAM, scrolled with
// BG scroll registers (scroll wheel / trackpad pans).
import SwiftUI
import MetalKit
import simd
import ChronoForgeCore
import ChronoForgeMetal

/// Shared Metal device (created once) and preview palettes.
@MainActor
enum StudioMetal {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
}

/// PPU pictures for the Studio previews.
enum StudioPPUScenes {
    /// The project format has no palettes yet: every palette is a gray ramp
    /// (16 steps for 4bpp, 4 for 2bpp) over a dark backdrop.
    static func grayCGRAM(bpp: Int) -> [UInt16] {
        let steps = 1 << bpp
        var cgram = (0..<256).map { i -> UInt16 in
            let v = UInt8((i % steps) * 31 / (steps - 1))
            return BGR555(r5: v, g5: v, b5: v).word
        }
        cgram[0] = BGR555(r5: 3, g5: 3, b5: 6).word
        return cgram
    }

    /// Up to 1024 tiles at VRAM word 0, BG1 tilemap 32x64 at 7800h, 32 tiles
    /// per row; `scrollY` in pixels. 4bpp uses mode 1, 2bpp mode 0.
    static func tileBank(indices: [UInt8], bpp: Int, scrollY: Int) -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = bpp == 2 ? 0x00 : 0x01
        r.tm = 0x01
        r.bg[0] = PPUBGRegisters(sc: 0x7A, charBase: 0, vofs: UInt16((scrollY - 1) & 0x3FF))
        var f = PPUFrame(registers: r)
        let tiles = min(indices.count / 64, 1024)
        f.storeTiles(Array(indices.prefix(tiles * 64)), bpp: bpp, atWord: 0)
        for t in 0..<tiles {
            f.vram[0x7800 + t] = PPUFrame.tilemapEntry(tile: t)
        }
        f.cgram = grayCGRAM(bpp: bpp)
        return f
    }

    static func tileBankRows(_ indices: [UInt8]) -> Int { (min(indices.count / 64, 1024) + 31) / 32 }

    /// A map's layers in mode 1: tiles (4bpp) at 0000h, a 2bpp copy for BG3
    /// at 6000h, 64x64 tilemaps for BG1/BG2/BG3 at 4000h/5000h/7000h. The
    /// 32x32-metatile window at the camera is written into the tilemaps the
    /// way a game streams a large map; HOFS/VOFS place the camera.
    static func map(_ map: GameMap, tileset ts: Tileset, indices: [UInt8], cameraX: Int, cameraY: Int) -> PPUFrame {
        let blank = 1023
        var r = PPURegisters()
        r.bgmode = 0x01
        let hofs = UInt16(cameraX & 0x3FF), vofs = UInt16((cameraY - 1) & 0x3FF)
        r.bg[0] = PPUBGRegisters(sc: 0x43, charBase: 0, hofs: hofs, vofs: vofs)
        r.bg[1] = PPUBGRegisters(sc: 0x53, charBase: 0, hofs: hofs, vofs: vofs)
        r.bg[2] = PPUBGRegisters(sc: 0x73, charBase: 3, hofs: hofs, vofs: vofs)
        var f = PPUFrame(registers: r)
        let tiles = min(indices.count / 64, blank)
        f.storeTiles(Array(indices.prefix(tiles * 64)), bpp: 4, atWord: 0)
        f.storeTiles(Array(indices.prefix(min(tiles, 512) * 64)).map { $0 & 3 }, bpp: 2, atWord: 0x6000)
        f.cgram = grayCGRAM(bpp: 4)

        let mapBase = [0x4000, 0x5000, 0x7000]
        let mx0 = cameraX / 16, my0 = cameraY / 16
        var tm: UInt8 = 0
        for layer in map.layers where (1...3).contains(layer.bg) {
            let n = layer.bg - 1
            tm |= 1 << n
            for my in my0..<(my0 + 32) {
                for mx in mx0..<(mx0 + 32) {
                    var chips: [Tileset.Chip]?
                    if mx < map.width, my < map.height, my * map.width + mx < layer.metatiles.count {
                        let mt = layer.metatiles[my * map.width + mx]
                        if mt >= 0, mt < ts.metatiles.count { chips = ts.metatiles[mt].chips }
                    }
                    for ci in 0..<4 {
                        let tx = (mx * 2 + ci % 2) & 63, ty = (my * 2 + ci / 2) & 63
                        // 64x64 tilemap: four 32x32 screens, left-right then top-bottom.
                        let screen = (tx >> 5) + (ty >> 5) * 2
                        let address = mapBase[n] + screen * 0x400 + (ty & 31) * 32 + (tx & 31)
                        if let chips, ci < chips.count, chips[ci].tile < tiles, n < 2 || chips[ci].tile < 512 {
                            let c = chips[ci]
                            f.vram[address] = PPUFrame.tilemapEntry(tile: c.tile, palette: c.pal, priority: c.priority,
                                                                    hflip: c.hflip, vflip: c.vflip)
                        } else {
                            f.vram[address] = PPUFrame.tilemapEntry(tile: n < 2 ? blank : 511)
                        }
                    }
                }
            }
        }
        f.setAllLines { $0.tm = tm }
        return f
    }
}

/// Renders a tileset's tile bank on BG1 (scroll to page through it).
struct TilesetMetalView: NSViewRepresentable {
    let project: CTProject
    let tileset: Tileset

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else {
            return NSView()
        }
        view.addConstraint(NSLayoutConstraint(item: view, attribute: .height,
            relatedBy: .equal, toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: 224 * 2))
        Task { @MainActor [weak view] in
            guard let view, let indices = try? project.tileIndices(of: tileset) else { return }
            let bpp = tileset.bpp == 2 ? 2 : 4
            var scrollY = 0
            let maxScroll = max(0, StudioPPUScenes.tileBankRows(indices) * 8 - 224)
            view.picture = StudioPPUScenes.tileBank(indices: indices, bpp: bpp, scrollY: 0)
            view.onScroll = { [weak view] _, dy in
                scrollY = min(maxScroll, max(0, scrollY - Int(dy)))
                view?.picture.setAllLines { $0.bg[0].vofs = UInt16((scrollY - 1) & 0x3FF) }
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Renders a map's BG layers through the PPU, 256x224 at the camera.
struct MapMetalView: NSViewRepresentable {
    let project: CTProject
    let map: GameMap
    let ts: Tileset

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else {
            return NSView()
        }
        view.addConstraint(NSLayoutConstraint(item: view, attribute: .height,
            relatedBy: .equal, toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: 224 * 2))
        Task { @MainActor [weak view] in
            guard let view, let indices = try? project.tileIndices(of: ts) else { return }
            var camera = (x: 0, y: 0)
            let limit = (x: max(0, map.width * 16 - 256), y: max(0, map.height * 16 - 224))
            view.picture = StudioPPUScenes.map(map, tileset: ts, indices: indices, cameraX: 0, cameraY: 0)
            view.onScroll = { [weak view] dx, dy in
                camera.x = min(limit.x, max(0, camera.x - Int(dx)))
                camera.y = min(limit.y, max(0, camera.y - Int(dy)))
                view?.picture = StudioPPUScenes.map(map, tileset: ts, indices: indices,
                                                    cameraX: camera.x, cameraY: camera.y)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
