// PPUPreviewScenesTests.swift — the Studio tile-bank and map pictures put
// each tile and metatile chip where the layout says, through the reference PPU.
import XCTest
@testable import ChronoForgeCore

final class PPUPreviewScenesTests: XCTestCase {
    func gray(_ index: Int, bpp: Int) -> UInt16 {
        let v = index * 31 / ((1 << bpp) - 1)
        return bgr(v, v, v)
    }

    func testTileBankLayoutScrollAndBlankTail() {
        // 40 solid tiles: tile t has colour (t % 15) + 1.
        let indices = (0..<40).flatMap { t in [UInt8](repeating: UInt8(t % 15 + 1), count: 64) }
        var out = PPUReferenceRenderer.render(PPUPreviewScenes.tileBank(indices: indices, bpp: 4, scrollY: 0))
        XCTAssertEqual(out.word(0, 0), gray(1, bpp: 4))
        XCTAssertEqual(out.word(31 * 8 + 7, 7), gray(31 % 15 + 1, bpp: 4), "tile 31 ends row 0")
        XCTAssertEqual(out.word(7 * 8, 8), gray(39 % 15 + 1, bpp: 4), "tile 39 is row 1, column 7")
        XCTAssertEqual(out.word(8 * 8, 8), PPUPreviewScenes.backdrop, "after the last tile: blank")
        XCTAssertEqual(out.word(0, 16), PPUPreviewScenes.backdrop, "rows past the bank: blank")
        XCTAssertEqual(PPUPreviewScenes.tileBankRows(indices), 2)
        out = PPUReferenceRenderer.render(PPUPreviewScenes.tileBank(indices: indices, bpp: 4, scrollY: 8))
        XCTAssertEqual(out.word(0, 0), gray(32 % 15 + 1, bpp: 4), "scrolled one row: tile 32 on top")
        // 2bpp banks use mode 0 and a 4-step ramp.
        let two = (0..<3).flatMap { t in [UInt8](repeating: UInt8(t + 1), count: 64) }
        out = PPUReferenceRenderer.render(PPUPreviewScenes.tileBank(indices: two, bpp: 2, scrollY: 0))
        XCTAssertEqual([out.word(0, 0), out.word(8, 0), out.word(16, 0)], [gray(1, bpp: 2), gray(2, bpp: 2), gray(3, bpp: 2)])
    }

    func testMapChipsLayersFlipsAndCamera() {
        // Tiles 0-3 solid 1-4; tile 4 has colour 5 in its left column only.
        var indices = (0..<4).flatMap { t in [UInt8](repeating: UInt8(t + 1), count: 64) }
        indices += (0..<64).map { $0 % 8 == 0 ? 5 : 0 }
        func chip(_ tile: Int, hflip: Bool = false, priority: Bool = false) -> Tileset.Chip {
            Tileset.Chip(tile: tile, pal: 0, hflip: hflip, vflip: false, priority: priority)
        }
        let ts = Tileset(id: "t", sheet: nil, blob: nil, bpp: 4, tileCount: 5, metatiles: [
            Tileset.Metatile(chips: [chip(0), chip(1), chip(2), chip(3)]),
            Tileset.Metatile(chips: [chip(4), chip(4, hflip: true), chip(4), chip(4)]),
            Tileset.Metatile(chips: [chip(1), chip(1), chip(1), chip(1)]),
        ], collision: [])
        // 3x2 metatiles: BG1 = [0 1 99 / 1 0 0] (99 = none), BG3 = all metatile 2.
        let map = GameMap(id: "m", name: "m", tileset: "t", width: 3, height: 2, layers: [
            GameMap.Layer(bg: 1, metatiles: [0, 1, 99, 1, 0, 0]),
            GameMap.Layer(bg: 3, metatiles: [2, 2, 2, 2, 2, 2]),
        ], exits: [], triggers: [])
        var out = PPUReferenceRenderer.render(PPUPreviewScenes.map(map, tileset: ts, indices: indices, cameraX: 0, cameraY: 0))
        XCTAssertEqual([out.word(0, 0), out.word(8, 0), out.word(0, 8), out.word(15, 15)],
                       [gray(1, bpp: 4), gray(2, bpp: 4), gray(3, bpp: 4), gray(4, bpp: 4)], "chips TL, TR, BL, BR")
        XCTAssertEqual(out.word(16, 0), gray(5, bpp: 4), "metatile 1 TL: left column")
        // BG3 shows through the transparent pixels: tile 1 (colour 2) as 2bpp is colour 2.
        XCTAssertEqual(out.word(17, 0), gray(2, bpp: 4), "BG3 behind BG1")
        XCTAssertEqual(out.word(31, 0), gray(5, bpp: 4), "metatile 1 TR is h-flipped: right column")
        XCTAssertEqual(out.word(32, 0), gray(2, bpp: 4), "no BG1 metatile: BG3 only")
        XCTAssertEqual(out.word(48, 0), PPUPreviewScenes.backdrop, "outside the map: blank")
        XCTAssertEqual(out.word(0, 32), PPUPreviewScenes.backdrop)
        // The camera scrolls: x 16 puts metatile 1 at the left edge.
        out = PPUReferenceRenderer.render(PPUPreviewScenes.map(map, tileset: ts, indices: indices, cameraX: 16, cameraY: 16))
        XCTAssertEqual(out.word(0, 0), gray(1, bpp: 4), "metatile (1,1) is metatile 0")
        XCTAssertEqual(out.word(16, 0), gray(1, bpp: 4), "metatile (2,1) is metatile 0")
        XCTAssertEqual(out.word(32, 0), PPUPreviewScenes.backdrop)
    }

    func testMapBG3BlankTileIsBlankForLargeTilesets() {
        // 600 tiles, all solid colour 1: tile 511 is a real tile, so BG3's
        // blank must not use it; tile 1023 stays blank for BG1/BG2.
        let indices = [UInt8](repeating: 1, count: 600 * 64)
        let ts = Tileset(id: "t", sheet: nil, blob: nil, bpp: 4, tileCount: 600, metatiles: [
            Tileset.Metatile(chips: Array(repeating: Tileset.Chip(tile: 550, pal: 0, hflip: false, vflip: false,
                                                                  priority: false), count: 4)),
        ], collision: [])
        let map = GameMap(id: "m", name: "m", tileset: "t", width: 1, height: 1,
                          layers: [GameMap.Layer(bg: 3, metatiles: [0])], exits: [], triggers: [])
        let out = PPUReferenceRenderer.render(PPUPreviewScenes.map(map, tileset: ts, indices: indices, cameraX: 0, cameraY: 0))
        XCTAssertEqual(out.word(0, 0), PPUPreviewScenes.backdrop, "BG3 cannot reach tile 550: blank")
        XCTAssertEqual(out.word(100, 100), PPUPreviewScenes.backdrop)
    }
}
