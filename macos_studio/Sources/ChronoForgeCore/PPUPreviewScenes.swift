// PPUPreviewScenes.swift — PPU pictures for the Studio's tileset and map
// previews: tiles and tilemaps placed in VRAM the way a game would, scrolled
// with BG scroll registers.
import Foundation

public enum PPUPreviewScenes {
    /// The project format has no palettes yet: every palette is a gray ramp
    /// (16 steps for 4bpp, 4 for 2bpp) over a dark backdrop.
    public static func grayCGRAM(bpp: Int) -> [UInt16] {
        let steps = 1 << bpp
        var cgram = (0..<256).map { i -> UInt16 in
            let v = UInt8((i % steps) * 31 / (steps - 1))
            return BGR555(r5: v, g5: v, b5: v).word
        }
        cgram[0] = backdrop
        return cgram
    }

    public static let backdrop = BGR555(r5: 3, g5: 3, b5: 6).word

    /// Up to 1024 tiles at VRAM word 0 on BG1 (4bpp: mode 1, 2bpp: mode 0),
    /// 32 per row in a 32x64 tilemap at 7800h; `scrollY` in pixels. Entries
    /// past the last tile point at a blank tile.
    public static func tileBank(indices: [UInt8], bpp: Int, scrollY: Int) -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = bpp == 2 ? 0x00 : 0x01
        r.tm = 0x01
        r.bg[0] = PPUBGRegisters(sc: 0x7A, charBase: 0, vofs: UInt16((scrollY - 1) & 0x3FF))
        var f = PPUFrame(registers: r)
        let tiles = min(indices.count / 64, 1024)
        f.storeTiles(Array(indices.prefix(tiles * 64)), bpp: bpp, atWord: 0)
        let blank = PPUFrame.tilemapEntry(tile: tiles < 1024 ? tiles : 0)
        for i in 0..<2048 { f.vram[0x7800 + i] = i < tiles ? PPUFrame.tilemapEntry(tile: i) : blank }
        f.cgram = grayCGRAM(bpp: bpp)
        return f
    }

    public static func tileBankRows(_ indices: [UInt8]) -> Int { (min(indices.count / 64, 1024) + 31) / 32 }

    /// A map's layers in mode 1. Tiles (4bpp, up to 1023) at 0000h with tile
    /// 1023 left blank; a 2bpp copy of up to 511 tiles for BG3 at 6000h with
    /// tile 511 blank; 64x64 tilemaps for BG1/BG2/BG3 at 4000h/5000h/7000h.
    /// The 32x32-metatile window at the camera is written into the tilemaps,
    /// the way a game streams a large map; HOFS/VOFS place the camera (pixels).
    public static func map(_ map: GameMap, tileset ts: Tileset, indices: [UInt8],
                           cameraX: Int, cameraY: Int) -> PPUFrame {
        let blank4 = 1023, blank2 = 511
        var r = PPURegisters()
        r.bgmode = 0x01
        let hofs = UInt16(cameraX & 0x3FF), vofs = UInt16((cameraY - 1) & 0x3FF)
        r.bg[0] = PPUBGRegisters(sc: 0x43, charBase: 0, hofs: hofs, vofs: vofs)
        r.bg[1] = PPUBGRegisters(sc: 0x53, charBase: 0, hofs: hofs, vofs: vofs)
        r.bg[2] = PPUBGRegisters(sc: 0x73, charBase: 6, hofs: hofs, vofs: vofs)
        var f = PPUFrame(registers: r)
        let tiles4 = min(indices.count / 64, blank4), tiles2 = min(tiles4, blank2)
        f.storeTiles(Array(indices.prefix(tiles4 * 64)), bpp: 4, atWord: 0)
        f.storeTiles(Array(indices.prefix(tiles2 * 64)).map { $0 & 3 }, bpp: 2, atWord: 0x6000)
        f.cgram = grayCGRAM(bpp: 4)

        let mapBase = [0x4000, 0x5000, 0x7000]
        let mx0 = max(0, cameraX) / 16, my0 = max(0, cameraY) / 16
        var tm: UInt8 = 0
        for layer in map.layers where (1...3).contains(layer.bg) {
            let n = layer.bg - 1
            let limit = n < 2 ? tiles4 : tiles2
            tm |= 1 << n
            for my in my0..<(my0 + 32) {
                for mx in mx0..<(mx0 + 32) {
                    var chips: [Tileset.Chip] = []
                    if mx < map.width, my < map.height, my * map.width + mx < layer.metatiles.count {
                        let mt = layer.metatiles[my * map.width + mx]
                        if mt >= 0, mt < ts.metatiles.count { chips = ts.metatiles[mt].chips }
                    }
                    for ci in 0..<4 {
                        let tx = (mx * 2 + ci % 2) & 63, ty = (my * 2 + ci / 2) & 63
                        // 64x64 tilemap: four 32x32 screens, left-right then top-bottom.
                        let address = mapBase[n] + ((tx >> 5) + (ty >> 5) * 2) * 0x400 + (ty & 31) * 32 + (tx & 31)
                        if ci < chips.count, chips[ci].tile >= 0, chips[ci].tile < limit {
                            let c = chips[ci]
                            f.vram[address] = PPUFrame.tilemapEntry(tile: c.tile, palette: c.pal, priority: c.priority,
                                                                    hflip: c.hflip, vflip: c.vflip)
                        } else {
                            f.vram[address] = PPUFrame.tilemapEntry(tile: n < 2 ? blank4 : blank2)
                        }
                    }
                }
            }
        }
        f.setAllLines { $0.tm = tm }
        return f
    }
}
