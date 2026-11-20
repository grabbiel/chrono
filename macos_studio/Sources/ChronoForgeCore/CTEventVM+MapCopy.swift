// CTEventVM+MapCopy.swift — Evt_OpE4_CopyMapRegion / Evt_OpE5_CopyMapRegionRedraw
// and the copy they ask for, Field_UnkAF4E ($C0:AF4E) with
// Map_CopyRegionPlane: a rectangle of map tiles copied within the WRAM map
// planes (row stride $100), plane by plane as Field_Unk44's bits select.
// `$E4` copies at once; `$E5` sets SceneFlag_MapRedraw and the field's
// DefaultHandler copies and redraws the layers on a later frame.
import Foundation

extension WRAM {
    /// Map_TileProps (layer 1's tiles), Map_Layer2Tiles, Map_Layer3Tiles: the low
    /// 8 bits of each map tile's metatile, row << 8 | column (bit 8 of layers 1
    /// and 2 in Map_TileHiBits bits 0 and 1).
    public static let mapLayer1Tiles = 0x7E3000, mapLayer2Tiles = 0x7E3040, mapLayer3Tiles = 0x7E3080
    public static let mapCopySrcX = dpField + 0x3E, mapCopyEndX = dpField + 0x40, mapCopyDstX = dpField + 0x42
    public static let fieldUnk44 = dpField + 0x44, fieldMapRedrawSel = dpField + 0x45
}

extension CTEventVM {
    /// Field_Unk44's plane bits (MapCopy_L1 ... MapCopy_L2Bit8) and the planes
    /// copied whole, in the routine's order.
    static let mapCopyPlanes: [(bit: UInt8, plane: Int)] = [
        (0x01, WRAM.mapLayer1Tiles), (0x02, WRAM.mapLayer2Tiles), (0x04, WRAM.mapLayer3Tiles),
        (0x08, WRAM.mapTileHiBits), (0x10, WRAM.mapTileAttrA), (0x20, WRAM.mapTileAttrB),
    ]

    /// The rectangle `$E4`/`$E5` set up: MapCopy_SrcX/Y, EndX/Y, DstX/Y and Field_Unk44.
    func mapCopySetup(_ y: Int) {
        for i in 0..<6 { wram[WRAM.mapCopySrcX + i] = UInt8(data(y + 1 + i)) }
        wram[WRAM.fieldUnk44] = UInt8(data(y + 7))
    }

    func mapCopyOp(_ op: UInt8, _ y: Int) -> Outcome {
        mapCopySetup(y)
        if op == 0xE4 {
            copyMapRegion()
        } else {
            wram[WRAM.fieldMapRedrawSel] = wram[WRAM.fieldUnk44] & 0x07     // MapCopy_LayerBits
            wram[WRAM.fieldSceneFlags] |= 0x20                              // SceneFlag_MapRedraw
        }
        return .go(x: y + 8, carry: false)
    }

    /// Field_UnkAF4E: the copy, by Field_Unk44's bits (nothing when it is 0).
    /// Returns the layers whose tiles it changed (1-3), for the picture.
    @discardableResult
    public func copyMapRegion() -> Set<Int> {
        let sel = wram[WRAM.fieldUnk44]
        var layers: Set<Int> = []
        guard sel != 0 else { return layers }
        let src = wram.word(WRAM.mapCopySrcX), dst = wram.word(WRAM.mapCopyDstX)
        let width = Int(wram[WRAM.mapCopyEndX] &- wram[WRAM.mapCopySrcX])
        let rows = Int(wram[WRAM.mapCopyEndX + 1] &- wram[WRAM.mapCopySrcX + 1])
        for (k, p) in Self.mapCopyPlanes.enumerated() where sel & p.bit != 0 {
            copyRegionPlane(src: src, dst: dst, width: width, rows: rows, plane: p.plane & 0xFFFF)
            if k < 3 { layers.insert(k + 1) }
            if k == 3 { layers.formUnion([1, 2]) }
        }
        for (bit, mask, layer) in [(UInt8(0x40), UInt8(0x01), 1), (UInt8(0x80), UInt8(0x02), 2)] where sel & bit != 0 {
            copyHiBit(src: src, dst: dst, width: width, rows: rows, mask: mask)
            layers.insert(layer)
        }
        var cells: [Int] = []
        for r in 0...rows { for i in 0...width { cells.append((dst + r * 0x100 + i) & 0xFFFF) } }
        mapCopies.append(MapCopy(layers: layers, cells: cells))
        return layers
    }

    /// Map_CopyRegionPlane: one MVN of width + 1 bytes per row in bank $7E, rows
    /// + 1 rows, $100 apart, top down and left to right (an overlap reads bytes
    /// already copied, as the ROM does).
    func copyRegionPlane(src: Int, dst: Int, width: Int, rows: Int, plane: Int) {
        var x = (src + plane) & 0xFFFF, yy = (dst + plane) & 0xFFFF
        for _ in 0...rows {
            for i in 0...width {
                wram[0x7E0000 | ((yy + i) & 0xFFFF)] = wram[0x7E0000 | ((x + i) & 0xFFFF)]
            }
            x = (x + 0x100) & 0xFFFF; yy = (yy + 0x100) & 0xFFFF
        }
    }

    /// Field_UnkAF4E's bit copies: one Map_TileHiBits bit per tile, the
    /// destination's other bits kept; each row restarts at the first column.
    func copyHiBit(src: Int, dst: Int, width: Int, rows: Int, mask: UInt8) {
        var x = src, yy = dst
        let srcCol = src & 0xFF, dstCol = dst & 0xFF
        for _ in 0...rows {
            for i in 0...width {
                let from = WRAM.mapTileHiBits + ((x + i) & 0xFFFF), to = WRAM.mapTileHiBits + ((yy + i) & 0xFFFF)
                wram[to] = wram[to] & ~mask | wram[from] & mask
            }
            x = ((x + width + 0x100) & 0xFF00) | srcCol
            yy = ((yy + width + 0x100) & 0xFF00) | dstCol
        }
    }
}
