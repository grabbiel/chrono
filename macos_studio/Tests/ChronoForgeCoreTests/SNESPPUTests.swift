// SNESPPUTests.swift — the CPU reference PPU against pixels derived by hand
// from the documented rules (docs/ppu.md): priority order, BG3 priority bit,
// tiles/tilemaps/scroll, OBJ order and per-line limits, color math, per-line
// register tables, brightness.
import XCTest
@testable import ChronoForgeCore

/// VRAM layout shared by the scenes: BG1/BG2/BG3 tilemaps at words
/// 0000h/0400h/0800h, 4bpp BG chars at 1000h, 2bpp BG chars at 2000h, OBJ
/// chars at 4000h (OBSEL base 2).
enum PPUScene {
    static let bgChars4 = 0x1000, bgChars2 = 0x2000, objChars = 0x4000

    static func solid(_ index: UInt8) -> [UInt8] { [UInt8](repeating: index, count: 64) }

    /// Mode 1, BG1-3 tilemaps/chars as above, BG scroll -1 so tile rows line
    /// up with output rows (line 0 is scanline 1), OBJ chars at 4000h.
    static func frame(height: Int = 224) -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = 0x01
        r.bg[0] = PPUBGRegisters(sc: 0x00, charBase: 1, vofs: 0x3FF)
        r.bg[1] = PPUBGRegisters(sc: 0x04, charBase: 1, vofs: 0x3FF)
        r.bg[2] = PPUBGRegisters(sc: 0x08, charBase: 2, vofs: 0x3FF)
        r.bg[3] = PPUBGRegisters(sc: 0x0C, charBase: 2, vofs: 0x3FF)
        r.obsel = 0x02
        var f = PPUFrame(height: height, registers: r)
        f.storeTiles(solid(0) + solid(1) + solid(2) + solid(3), bpp: 4, atWord: bgChars4)
        f.storeTiles(solid(0) + solid(1) + solid(2) + solid(3), bpp: 2, atWord: bgChars2)
        f.storeTiles(solid(0) + solid(1) + solid(2) + solid(3), bpp: 4, atWord: objChars)
        return f
    }

    static func setMap(_ f: inout PPUFrame, bg: Int, tx: Int, ty: Int, _ entry: UInt16) {
        f.vram[bg * 0x400 + ty * 32 + tx] = entry
    }

    static func fillMap(_ f: inout PPUFrame, bg: Int, _ entry: UInt16) {
        for i in 0..<1024 { f.vram[bg * 0x400 + i] = entry }
    }
}

extension Array where Element == UInt8 {
    /// The BGR555 word of an RGBA8 pixel rendered at full brightness.
    func word(_ x: Int, _ y: Int) -> UInt16 {
        let o = (y * PPUFrame.width + x) * 4
        return UInt16(self[o] >> 3) | UInt16(self[o + 1] >> 3) << 5 | UInt16(self[o + 2] >> 3) << 10
    }
}

func bgr(_ r: Int, _ g: Int, _ b: Int) -> UInt16 { BGR555(r5: UInt8(r), g5: UInt8(g), b5: UInt8(b)).word }

final class SNESPPUTests: XCTestCase {
    // MARK: Tiles and tilemaps

    func testPlanarTileLayoutFollowsFullsnes() {
        var f = PPUFrame()
        var tile = [UInt8](repeating: 0, count: 64)
        tile[0] = 1          // row 0, col 0: plane 0 -> byte 00h bit 7
        tile[1] = 2          // row 0, col 1: plane 1 -> byte 01h bit 6
        tile[8 + 7] = 4      // row 1, col 7: plane 2 -> byte 12h bit 0
        tile[7 * 8 + 3] = 8  // row 7, col 3: plane 3 -> byte 1Fh bit 4
        f.storeTiles(tile, bpp: 4, atWord: 0x100)
        XCTAssertEqual(f.vram[0x100], 0x4080)
        XCTAssertEqual(f.vram[0x100 + 9], 0x0001)
        XCTAssertEqual(f.vram[0x100 + 15], 0x1000)
        XCTAssertEqual(f.vram[0x100 + 1], 0)
        var g = PPUFrame()
        g.storeTiles(tile.map { $0 & 3 }, bpp: 2, atWord: 0x200)
        XCTAssertEqual(g.vram[0x200], 0x4080)
        XCTAssertEqual(g.vram[0x208], 0, "a 2bpp tile is 8 words")
    }

    func testTileFlipsPaletteAndHiddenFirstLine() {
        var f = PPUScene.frame()
        f.setAllLines { $0.tm = 0x01; $0.bg[0].vofs = 0 }
        // Pattern tile 4: pixel (col, row) has index row * 2 + (col < 4 ? 1 : 2).
        var pattern = [UInt8](repeating: 0, count: 64)
        for row in 0..<8 { for col in 0..<8 { pattern[row * 8 + col] = UInt8(row * 2 + (col < 4 ? 1 : 2)) } }
        f.storeTiles(pattern, bpp: 4, atWord: PPUScene.bgChars4 + 4 * 16)
        for i in 0..<128 { f.cgram[i] = UInt16(i) }
        PPUScene.setMap(&f, bg: 0, tx: 0, ty: 0, PPUFrame.tilemapEntry(tile: 4, palette: 2))
        PPUScene.setMap(&f, bg: 0, tx: 1, ty: 0, PPUFrame.tilemapEntry(tile: 4, palette: 3, hflip: true))
        PPUScene.setMap(&f, bg: 0, tx: 2, ty: 0, PPUFrame.tilemapEntry(tile: 4, palette: 3, vflip: true))
        let out = PPUReferenceRenderer.render(f)
        // VOFS 0: output line 0 is scanline 1, so it shows tile row 1.
        XCTAssertEqual(out.word(0, 0), 32 + 2 + 1)
        XCTAssertEqual(out.word(7, 0), 32 + 2 + 2)
        XCTAssertEqual(out.word(0, 6), 32 + 14 + 1)
        XCTAssertEqual(out.word(0, 7), 0, "tile row 8 is the empty row below")
        XCTAssertEqual(out.word(8, 0), 48 + 2 + 2, "hflip: column 0 shows column 7")
        XCTAssertEqual(out.word(15, 0), 48 + 2 + 1)
        XCTAssertEqual(out.word(16, 0), 48 + 12 + 1, "vflip: row 1 shows row 6")
    }

    func testScrollWrapsAndScreenSizes() {
        var f = PPUScene.frame()
        f.setAllLines { $0.tm = 0x01 }
        for i in 0..<16 { f.cgram[i] = UInt16(i) }
        // Markers: SC0 (0,0) colour 1, SC1 (0,0) colour 2, SC2 colour 3.
        f.vram[0x000] = PPUFrame.tilemapEntry(tile: 1)
        f.vram[0x400] = PPUFrame.tilemapEntry(tile: 2)
        f.vram[0x800] = PPUFrame.tilemapEntry(tile: 3)
        func at(_ sc: UInt8, hofs: UInt16, vofs: UInt16) -> UInt16 {
            var g = f
            g.setAllLines { $0.bg[0].sc = sc; $0.bg[0].hofs = hofs; $0.bg[0].vofs = vofs }
            return PPUReferenceRenderer.render(g).word(0, 0)
        }
        // vofs is one less than the target row: line 0 is scanline 1.
        XCTAssertEqual(at(0, hofs: 256, vofs: 0x3FF), 1, "32x32 repeats every 256 pixels")
        XCTAssertEqual(at(1, hofs: 256, vofs: 0x3FF), 2, "64x32: tile column 32 is SC1")
        XCTAssertEqual(at(1, hofs: 512, vofs: 0x3FF), 1, "64x32 wraps at 512")
        XCTAssertEqual(at(1, hofs: 0, vofs: 255), 1, "64x32 repeats vertically")
        XCTAssertEqual(at(2, hofs: 0, vofs: 255), 2, "32x64: tile row 32 is SC1")
        XCTAssertEqual(at(2, hofs: 256, vofs: 0x3FF), 1)
        XCTAssertEqual(at(3, hofs: 0, vofs: 255), 3, "64x64: tile row 32 is SC2")
        XCTAssertEqual(at(3, hofs: 256, vofs: 0x3FF), 2)
        XCTAssertEqual(at(3, hofs: 1023, vofs: 0x3FF), 0, "x = -1 wraps to column 63")
    }

    func testSixteenPixelTilesUseNPlus1AndNPlus16() {
        var f = PPUScene.frame()
        f.setAllLines { $0.tm = 0x01; $0.bgmode = 0x11 }
        for i in 0..<16 { f.cgram[i] = UInt16(i) }
        // Tiles 20h, 21h, 30h, 31h solid 1, 2, 3, 4.
        f.storeTiles(PPUScene.solid(1) + PPUScene.solid(2), bpp: 4, atWord: PPUScene.bgChars4 + 0x20 * 16)
        f.storeTiles(PPUScene.solid(3) + PPUScene.solid(4), bpp: 4, atWord: PPUScene.bgChars4 + 0x30 * 16)
        PPUScene.setMap(&f, bg: 0, tx: 0, ty: 0, PPUFrame.tilemapEntry(tile: 0x20))
        PPUScene.setMap(&f, bg: 0, tx: 1, ty: 0, PPUFrame.tilemapEntry(tile: 0x20, hflip: true, vflip: true))
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual([out.word(0, 0), out.word(8, 0), out.word(0, 8), out.word(15, 15)], [1, 2, 3, 4])
        XCTAssertEqual([out.word(16, 0), out.word(24, 0), out.word(16, 8), out.word(24, 8)], [4, 3, 2, 1])
    }

    // MARK: Priority

    enum Slot: Equatable { case bg(Int, Int), obj(Int) }

    /// Every pair of slots overlaps in its own 8x8 block; the front one must
    /// show. Slots of one layer (one pixel per layer) are not paired.
    func checkPairwiseOrder(mode: UInt8, frontToBack: [Slot], file: StaticString = #filePath, line: UInt = #line) {
        var f = PPUScene.frame()
        f.setAllLines { r in
            r.bgmode = mode
            r.tm = 0x1F
            if mode & 7 == 0 { for n in 0..<4 { r.bg[n].charBase = 2 } }
        }
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        // Colours: mode 1 BG1/BG2 index 1 (pal 0/1, 2/3), BG3 index 2 (pal 6/7);
        // mode 0 index 1 with pal = priority; OBJ index 1 with pal = priority.
        func entry(_ n: Int, _ p: Int) -> UInt16 {
            if mode & 7 == 0 { return PPUFrame.tilemapEntry(tile: 1, palette: p, priority: p == 1) }
            return n == 2 ? PPUFrame.tilemapEntry(tile: 2, palette: 6 + p, priority: p == 1)
                : PPUFrame.tilemapEntry(tile: 1, palette: n * 2 + p, priority: p == 1)
        }
        func color(_ s: Slot) -> UInt16 {
            switch s {
            case .obj(let p): return UInt16(128 + p * 16 + 1)
            case .bg(let n, let p):
                if mode & 7 == 0 { return UInt16(n * 32 + p * 4 + 1) }
                return n == 2 ? UInt16((6 + p) * 4 + 2) : UInt16((n * 2 + p) * 16 + 1)
            }
        }
        func layer(_ s: Slot) -> Int { if case .bg(let n, _) = s { return n }; return 4 }
        var objIndex = 0
        var expected: [(Int, Int, UInt16)] = []
        for (i, a) in frontToBack.enumerated() {
            for (j, b) in frontToBack.enumerated() where layer(a) != layer(b) {
                for s in [a, b] {
                    switch s {
                    case .bg(let n, let p): PPUScene.setMap(&f, bg: n, tx: j, ty: i, entry(n, p))
                    case .obj(let p):
                        f.setOBJ(objIndex, x: j * 8, y: i * 8, tile: 1, palette: p, priority: p)
                        objIndex += 1
                    }
                }
                expected.append((j * 8 + 4, i * 8 + 4, color(i < j ? a : b)))
            }
        }
        let out = PPUReferenceRenderer.render(f)
        for (x, y, c) in expected {
            XCTAssertEqual(out.word(x, y), c, "block (\(x / 8), \(y / 8))", file: file, line: line)
        }
    }

    func testMode1PriorityOrder() {
        checkPairwiseOrder(mode: 0x01, frontToBack: [.obj(3), .bg(0, 1), .bg(1, 1), .obj(2), .bg(0, 0),
                                                     .bg(1, 0), .obj(1), .bg(2, 1), .obj(0), .bg(2, 0)])
    }

    func testMode1BG3PriorityBitMovesOnlyHighBG3TilesToTheFront() {
        checkPairwiseOrder(mode: 0x09, frontToBack: [.bg(2, 1), .obj(3), .bg(0, 1), .bg(1, 1), .obj(2),
                                                     .bg(0, 0), .bg(1, 0), .obj(1), .obj(0), .bg(2, 0)])
    }

    func testMode0PriorityOrder() {
        checkPairwiseOrder(mode: 0x00, frontToBack: [.obj(3), .bg(0, 1), .bg(1, 1), .obj(2), .bg(0, 0), .bg(1, 0),
                                                     .obj(1), .bg(2, 1), .bg(3, 1), .obj(0), .bg(2, 0), .bg(3, 0)])
    }

    func testMode1BG3PriorityBitPerLine() {
        var f = PPUScene.frame()
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 1, priority: true))
        PPUScene.fillMap(&f, bg: 2, PPUFrame.tilemapEntry(tile: 2, palette: 7, priority: true))
        f.setAllLines { $0.tm = 0x05 }
        for line in 100..<224 { f.lines[line].bgmode = 0x09 }
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(10, 99), 17, "bit clear: BG1 high is in front of BG3 high")
        XCTAssertEqual(out.word(10, 100), 30, "bit set: BG3 high is in front")
    }

    // MARK: OBJ

    func testOBJOrderCookieCutterAndRotation() {
        var f = PPUScene.frame()
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        f.setAllLines { $0.tm = 0x11 }
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 0))   // BG1 low, colour 1
        // OBJ 0 (priority 0, colour 129) covers OBJ 1 (priority 3, colour 177) at x 0-7.
        f.setOBJ(0, x: 0, y: 0, tile: 1, palette: 0, priority: 0)
        f.setOBJ(1, x: 4, y: 0, tile: 1, palette: 3, priority: 3)
        // OBJ 4/5/6 overlap at x 32; rotation makes 5 the front OBJ.
        f.setOBJ(4, x: 32, y: 0, tile: 1, palette: 4, priority: 3)
        f.setOBJ(5, x: 32, y: 0, tile: 2, palette: 5, priority: 3)
        f.setOBJ(6, x: 32, y: 0, tile: 3, palette: 6, priority: 3)
        var out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(2, 2), 1, "OBJ priority 0 is behind BG1 low")
        XCTAssertEqual(out.word(5, 2), 1, "OBJ 0 wins the OBJ layer over OBJ 1, then loses to BG1 low")
        XCTAssertEqual(out.word(9, 2), 177, "OBJ 1 alone: priority 3 is in front of BG1")
        XCTAssertEqual(out.word(34, 2), 128 + 4 * 16 + 1, "lowest index in front")
        f.setAllLines { $0.objFirst = 5 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(34, 2), 128 + 5 * 16 + 2, "rotation: OBJ 5 first, OBJ 4 last")
    }

    func testOBJSizesFlipsAndNameWrapping() {
        var f = PPUScene.frame()
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        f.setAllLines { $0.tm = 0x10; $0.obsel = 0x02 }   // 8x8 / 16x16, base 4000h
        // Tiles 0Fh, 00h, 1Fh, 10h solid 1-4: a 16x16 OBJ at 0Fh uses 0Fh, 00h
        // (no carry into the row nibble), 1Fh, 10h.
        f.storeTiles(PPUScene.solid(1), bpp: 4, atWord: PPUScene.objChars + 0x0F * 16)
        f.storeTiles(PPUScene.solid(2), bpp: 4, atWord: PPUScene.objChars + 0x00 * 16)
        f.storeTiles(PPUScene.solid(3), bpp: 4, atWord: PPUScene.objChars + 0x1F * 16)
        f.storeTiles(PPUScene.solid(4), bpp: 4, atWord: PPUScene.objChars + 0x10 * 16)
        f.setOBJ(0, x: 0, y: 0, tile: 0x0F, large: true)
        f.setOBJ(1, x: 32, y: 0, tile: 0x0F, hflip: true, vflip: true, large: true)
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual([out.word(0, 0), out.word(8, 0), out.word(0, 8), out.word(15, 15)], [129, 130, 131, 132])
        XCTAssertEqual([out.word(32, 0), out.word(40, 0), out.word(32, 8), out.word(47, 15)], [132, 131, 130, 129])
        XCTAssertEqual(out.word(16, 0), 0)
    }

    func testOBJNameSelectGap() {
        XCTAssertEqual(PPUOBJEvaluator.tileAddress(0x000, obsel: 0x01), 0x2000)
        XCTAssertEqual(PPUOBJEvaluator.tileAddress(0x0FF, obsel: 0x01), 0x2FF0)
        XCTAssertEqual(PPUOBJEvaluator.tileAddress(0x100, obsel: 0x01), 0x3000, "gap 0: contiguous")
        XCTAssertEqual(PPUOBJEvaluator.tileAddress(0x100, obsel: 0x11), 0x5000, "gap 2 adds 2 x 4K words")
        XCTAssertEqual(PPUOBJEvaluator.tileAddress(0x1FF, obsel: 0x1F), 0x2FF0, "E000h + 4000h + FF0h wraps at 15 bits")
        XCTAssertEqual(PPUOBJEvaluator.tileAddress(0x100, obsel: 0x07), 0x7000, "E000h + 1000h wraps at 15 bits")
    }

    func testOBJYWrapPartialLeftAndFirstLine() {
        var f = PPUScene.frame()
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        f.setAllLines { $0.tm = 0x10 }
        // A 16x16 OBJ whose rows are tiles of distinct colours: rows 0-7 use
        // tiles 1/2 (colours 1, 2), rows 8-15 tiles 11h/12h (colours 3, 4).
        f.storeTiles(PPUScene.solid(3) + PPUScene.solid(4), bpp: 4, atWord: PPUScene.objChars + 0x11 * 16)
        f.setOBJ(0, x: 100, y: 250, tile: 1, large: true)
        f.setOBJ(1, x: -4, y: 0, tile: 1)
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(100, 0), 129, "line 0 is OBJ row 6 (lines 250-255 are off-screen)")
        XCTAssertEqual(out.word(100, 1), 129, "row 7")
        XCTAssertEqual(out.word(100, 2), 131, "row 8: tile 11h")
        XCTAssertEqual(out.word(108, 2), 132, "tile 12h")
        XCTAssertEqual(out.word(100, 9), 131, "row 15")
        XCTAssertEqual(out.word(100, 10), 0)
        XCTAssertEqual(out.word(0, 0), 129, "Y=0 starts on line 0 (scanline 1)")
        XCTAssertEqual(out.word(3, 7), 129, "x=-4 shows columns 4-7 at x 0-3")
        XCTAssertEqual(out.word(4, 0), 0)
    }

    func testThirtyTwoOBJsPerLine() {
        var f = PPUScene.frame()
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        f.setAllLines { $0.tm = 0x10 }
        for i in 0..<33 { f.setOBJ(i, x: i * 7, y: 50, tile: 1) }
        let eval = PPUOBJEvaluator.evaluate(oam: f.oam, registers: f.lines[50], line: 50)
        XCTAssertTrue(eval.rangeOver)
        XCTAssertEqual(eval.slivers.count, 32)
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(31 * 7 + 1, 50), 129)
        XCTAssertEqual(out.word(32 * 7 + 6, 50), 0, "OBJ 32 is dropped")
        // OBJs at X = -256 count although they are not visible.
        var g = PPUScene.frame()
        g.setAllLines { $0.tm = 0x10 }
        for i in 0..<128 { g.cgram[i + 128] = UInt16(i + 128) }
        for i in 0..<32 { g.setOBJ(i, x: -256, y: 50, tile: 1) }
        g.setOBJ(32, x: 10, y: 50, tile: 1)
        g.setOBJ(33, x: -255, y: 50, tile: 1)   // left edge -255: off-screen, not counted
        let eg = PPUOBJEvaluator.evaluate(oam: g.oam, registers: g.lines[50], line: 50)
        XCTAssertTrue(eg.rangeOver)
        XCTAssertEqual(PPUReferenceRenderer.render(g).word(12, 50), 0)
    }

    func testThirtyFourSliversCountedFromTheLastOBJ() {
        var f = PPUScene.frame()
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        f.setAllLines { $0.tm = 0x10; $0.obsel = 0x42 }   // 8x8 / 64x64, base 4000h
        // Five 64x64 OBJs (8 slivers each); OBJ 1-4 are evaluated first (32
        // slivers), so OBJ 0 keeps only its two leftmost slivers.
        for row in 0..<8 { for col in 0..<8 {
            f.storeTiles(PPUScene.solid(1), bpp: 4, atWord: PPUScene.objChars + (row * 16 + col) * 16)
        } }
        f.setOBJ(0, x: 0, y: 0, tile: 0, palette: 0, large: true)
        f.setOBJ(1, x: 0, y: 0, tile: 0, palette: 1, large: true)
        f.setOBJ(2, x: 64, y: 0, tile: 0, palette: 2, large: true)
        f.setOBJ(3, x: 128, y: 0, tile: 0, palette: 3, large: true)
        f.setOBJ(4, x: 192, y: 0, tile: 0, palette: 4, large: true)
        let eval = PPUOBJEvaluator.evaluate(oam: f.oam, registers: f.lines[10], line: 10)
        XCTAssertTrue(eval.timeOver)
        XCTAssertFalse(eval.rangeOver)
        XCTAssertEqual(eval.slivers.filter { $0.order == 0 }.map(\.x), [0, 8])
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(15, 10), 129, "OBJ 0 sliver 2")
        XCTAssertEqual(out.word(16, 10), 145, "OBJ 0 dropped from x 16; OBJ 1 shows")
        XCTAssertEqual(out.word(255, 10), 128 + 64 + 1)
        // Off-screen slivers do not count: move OBJ 4 to x=240, only 2 slivers on screen.
        f.setOBJ(4, x: 240, y: 0, tile: 0, palette: 4, large: true)
        let moved = PPUOBJEvaluator.evaluate(oam: f.oam, registers: f.lines[10], line: 10)
        XCTAssertFalse(moved.timeOver)
        XCTAssertEqual(moved.slivers.count, 2 + 8 + 8 + 8 + 8)
    }

    // MARK: Color math

    /// One math configuration per line over BG1 (main) and BG2 (sub).
    func testColorMathPerLine() {
        var f = PPUScene.frame()
        f.cgram[0] = bgr(1, 2, 3)               // backdrop
        f.cgram[1] = bgr(20, 10, 5)             // BG1 (main)
        f.cgram[2 * 16 + 1] = bgr(15, 25, 2)    // BG2 (sub), palette 2
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 0))
        PPUScene.fillMap(&f, bg: 1, PPUFrame.tilemapEntry(tile: 1, palette: 2))
        f.setAllLines { r in
            r.tm = 0x01; r.ts = 0x02; r.cgwsel = 0x02; r.cgadsub = 0x01
            r.writeCOLDATA(0x23); r.writeCOLDATA(0x43); r.writeCOLDATA(0x9F)   // (3, 3, 31)
        }
        let cases: [(String, (inout PPURegisters) -> Void, UInt16)] = [
            ("add sub screen, clamp", { _ in }, bgr(31, 31, 7)),
            ("add half", { $0.cgadsub = 0x41 }, bgr(17, 17, 3)),
            ("subtract, clamp at 0", { $0.cgadsub = 0x81 }, bgr(5, 0, 3)),
            ("subtract half", { $0.cgadsub = 0xC1 }, bgr(2, 0, 1)),
            ("add fixed colour", { $0.cgwsel = 0x00 }, bgr(23, 13, 31)),
            ("add half fixed colour", { $0.cgwsel = 0x00; $0.cgadsub = 0x41 }, bgr(11, 6, 18)),
            ("transparent sub: fixed colour, no half", { $0.ts = 0; $0.cgadsub = 0x41 }, bgr(23, 13, 31)),
            ("sub screen OBJ disabled -> backdrop", { $0.ts = 0x10; $0.cgadsub = 0x41 }, bgr(23, 13, 31)),
            ("BG1 not enabled for math", { $0.cgadsub = 0x42 }, bgr(20, 10, 5)),
            ("force black everywhere, half ignored", { $0.cgwsel = 0xC2; $0.cgadsub = 0x41 }, bgr(15, 25, 2)),
            ("force black outside window = everywhere", { $0.cgwsel = 0x42 }, bgr(15, 25, 2)),
            ("force black inside window = nowhere", { $0.cgwsel = 0x82 }, bgr(31, 31, 7)),
            ("force black, subtract", { $0.cgwsel = 0xC2; $0.cgadsub = 0x81 }, 0),
            ("math prevented everywhere", { $0.cgwsel = 0x32 }, bgr(20, 10, 5)),
            ("math prevented outside window", { $0.cgwsel = 0x12 }, bgr(20, 10, 5)),
            ("math prevented inside window", { $0.cgwsel = 0x22 }, bgr(31, 31, 7)),
            ("backdrop on main, backdrop math on", { $0.tm = 0; $0.cgadsub = 0x20 }, bgr(16, 27, 5)),
            ("backdrop on main, backdrop math off", { $0.tm = 0; $0.cgadsub = 0x1F }, bgr(1, 2, 3)),
            ("same layer on both screens", { $0.ts = 0x01; $0.cgadsub = 0x81 }, 0),
        ]
        for (i, c) in cases.enumerated() { c.1(&f.lines[i]) }
        let out = PPUReferenceRenderer.render(f)
        for (i, c) in cases.enumerated() {
            XCTAssertEqual(out.word(100, i), c.2, c.0)
        }
        XCTAssertEqual(out.word(100, cases.count), bgr(31, 31, 7), "lines after the table keep the base registers")
    }

    func testOBJMathOnlyForPalettes4To7OnMain() {
        var f = PPUScene.frame()
        f.cgram[128 + 3 * 16 + 1] = bgr(10, 10, 10)
        f.cgram[128 + 4 * 16 + 1] = bgr(10, 10, 10)
        f.cgram[2 * 16 + 1] = bgr(4, 5, 6)
        PPUScene.fillMap(&f, bg: 1, PPUFrame.tilemapEntry(tile: 1, palette: 2))
        f.setOBJ(0, x: 0, y: 0, tile: 1, palette: 3, priority: 3)
        f.setOBJ(1, x: 8, y: 0, tile: 1, palette: 4, priority: 3)
        f.setAllLines { $0.tm = 0x10; $0.ts = 0x02; $0.cgwsel = 0x02; $0.cgadsub = 0x10 }
        var out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(2, 2), bgr(10, 10, 10), "palette 3: no math")
        XCTAssertEqual(out.word(10, 2), bgr(14, 15, 16), "palette 4: math")
        // On the sub screen any OBJ palette is an addend.
        f.setAllLines { $0.tm = 0x02; $0.ts = 0x10; $0.cgadsub = 0x02 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(2, 2), bgr(14, 15, 16))
    }

    // MARK: Windows

    /// BG1 (colour 1) over BG2 (colour 33) on the main screen; returns which
    /// of x 0...63 show BG2 because a window hides BG1 there.
    func hiddenBG1(_ configure: (inout PPURegisters) -> Void) -> [Int] {
        var f = PPUScene.frame()
        for i in 0..<64 { f.cgram[i] = UInt16(i) }
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 0))
        PPUScene.fillMap(&f, bg: 1, PPUFrame.tilemapEntry(tile: 1, palette: 2))
        f.setAllLines { $0.tm = 0x03; $0.tmw = 0x01; configure(&$0) }
        let out = PPUReferenceRenderer.render(f)
        return (0..<64).filter { out.word($0, 0) == 33 }
    }

    func testWindowEdgesInvertAndEmpty() {
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x02; $0.wh0 = 10; $0.wh1 = 20 }, Array(10...20), "inclusive edges")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x03; $0.wh0 = 10; $0.wh1 = 20 }, Array(0...9) + Array(21...63), "inverted")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x02; $0.wh0 = 20; $0.wh1 = 10 }, [], "left > right is empty")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x03; $0.wh0 = 20; $0.wh1 = 10 }, Array(0...63), "inverted empty is everywhere")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x01; $0.wh0 = 10; $0.wh1 = 20 }, [], "invert without enable does nothing")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x08; $0.wh2 = 30; $0.wh3 = 31 }, [30, 31], "window 2 alone")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x20; $0.wh0 = 10; $0.wh1 = 20 }, [], "a BG2 window does not hide BG1")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x02; $0.wh0 = 10; $0.wh1 = 20; $0.tmw = 0 }, [], "TMW off: not applied")
    }

    func testWindowLogic() {
        func logic(_ l: UInt8) -> [Int] {
            hiddenBG1 { $0.w12sel = 0x0A; $0.wh0 = 10; $0.wh1 = 30; $0.wh2 = 20; $0.wh3 = 40; $0.wbglog = l }
        }
        XCTAssertEqual(logic(0), Array(10...40), "OR")
        XCTAssertEqual(logic(1), Array(20...30), "AND")
        XCTAssertEqual(logic(2), Array(10...19) + Array(31...40), "XOR")
        XCTAssertEqual(logic(3), Array(0...9) + Array(20...30) + Array(41...63), "XNOR")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x0B; $0.wh0 = 10; $0.wh1 = 30; $0.wh2 = 20; $0.wh3 = 40; $0.wbglog = 1 },
                       Array(31...40), "AND with window 1 inverted")
        XCTAssertEqual(hiddenBG1 { $0.w12sel = 0x0A; $0.wh0 = 10; $0.wh1 = 30; $0.wh2 = 20; $0.wh3 = 40; $0.wbglog = 0x04 },
                       Array(10...40), "BG2's logic bits do not apply to BG1")
    }

    func testWindowsOnSubScreenOBJAndColour() {
        var f = PPUScene.frame()
        f.cgram[1] = bgr(10, 10, 10)                 // BG1
        f.cgram[2 * 16 + 1] = bgr(5, 6, 7)          // BG2, palette 2
        f.cgram[128 + 1] = bgr(31, 0, 0)            // OBJ palette 0
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 0))
        PPUScene.fillMap(&f, bg: 1, PPUFrame.tilemapEntry(tile: 1, palette: 2))
        f.setOBJ(0, x: 0, y: 0, tile: 1, priority: 3, large: true)   // 16x16 at x 0-15, lines 0-15
        f.setAllLines { r in
            r.tm = 0x11; r.ts = 0x02; r.cgwsel = 0x02; r.cgadsub = 0x01
            r.wh0 = 4; r.wh1 = 7
        }
        // Line 0: OBJ window (window 1) on the main screen: BG1 + BG2 shows through.
        f.lines[0].wobjsel = 0x02; f.lines[0].tmw = 0x10
        // Line 1: BG2 windowed on the sub screen only: fixed colour (0) inside, no half.
        f.lines[1].tm = 0x01; f.lines[1].w12sel = 0x20; f.lines[1].tsw = 0x02
        // Line 2: colour window, force black inside it.
        f.lines[2].tm = 0x01; f.lines[2].wobjsel = 0x20; f.lines[2].cgwsel = 0x82
        // Line 3: colour window, math prevented outside it.
        f.lines[3].tm = 0x01; f.lines[3].wobjsel = 0x20; f.lines[3].cgwsel = 0x12
        // Line 4: the colour window is window 1 XOR window 2; math prevented inside it.
        f.lines[4].tm = 0x01; f.lines[4].wobjsel = 0xA0; f.lines[4].wobjlog = 0x08
        f.lines[4].wh2 = 6; f.lines[4].wh3 = 9; f.lines[4].cgwsel = 0x22
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(3, 0), bgr(31, 0, 0), "outside the OBJ window")
        XCTAssertEqual(out.word(4, 0), bgr(15, 16, 17), "OBJ hidden: BG1 + BG2")
        XCTAssertEqual(out.word(3, 1), bgr(15, 16, 17))
        XCTAssertEqual(out.word(5, 1), bgr(10, 10, 10), "sub BG2 hidden: + fixed colour 0")
        XCTAssertEqual(out.word(3, 2), bgr(15, 16, 17))
        XCTAssertEqual(out.word(7, 2), bgr(5, 6, 7), "black + BG2")
        XCTAssertEqual(out.word(8, 2), bgr(15, 16, 17))
        XCTAssertEqual(out.word(3, 3), bgr(10, 10, 10), "outside: no math")
        XCTAssertEqual(out.word(4, 3), bgr(15, 16, 17), "inside: math")
        // XOR of [4,7] and [6,9] = 4, 5, 8, 9; math prevented there (region 2 = inside).
        XCTAssertEqual((3...10).map { out.word($0, 4) == bgr(10, 10, 10) }, [false, true, true, false, false, true, true, false])
    }

    func testPerLineWindowShape() {
        var f = PPUScene.frame()
        for i in 0..<64 { f.cgram[i] = UInt16(i) }
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 0))
        f.setAllLines { $0.tm = 0x01; $0.tmw = 0x01; $0.w12sel = 0x02 }
        // A triangle: line y hides x 100-y ... 100+y.
        for y in 0..<50 { f.lines[y].wh0 = UInt8(100 - y); f.lines[y].wh1 = UInt8(100 + y) }
        f.lines[50].wh0 = 1; f.lines[50].wh1 = 0
        let out = PPUReferenceRenderer.render(f)
        for y in [0, 10, 49] {
            XCTAssertEqual(out.word(100 - y - 1, y), 1)
            XCTAssertEqual(out.word(100 - y, y), 0)
            XCTAssertEqual(out.word(100 + y, y), 0)
            XCTAssertEqual(out.word(100 + y + 1, y), 1)
        }
        XCTAssertEqual(out.word(100, 50), 1, "empty window")
    }

    // MARK: Per-line tables and output

    func testPerLineScrollAndFixedColour() {
        var f = PPUScene.frame()
        for i in 0..<16 { f.cgram[i] = UInt16(i) }
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 0))
        PPUScene.setMap(&f, bg: 0, tx: 0, ty: 0, PPUFrame.tilemapEntry(tile: 1))
        // A one-tile column at x 0-7, shifted left by one pixel per line.
        f.setAllLines { $0.tm = 0x01; $0.cgadsub = 0x20 }
        for line in 0..<8 {
            f.lines[line].bg[0].hofs = UInt16(1024 - line)
            f.lines[line].fixedColor = BGR555(r5: 0, g5: 0, b5: UInt8(line))
        }
        let out = PPUReferenceRenderer.render(f)
        for line in 0..<8 {
            XCTAssertEqual(out.word(line, line), 1, "line \(line): column starts at x \(line)")
            XCTAssertEqual(out.word(line + 7, line), 1)
            XCTAssertEqual(out.word(line + 8, line), bgr(0, 0, line), "backdrop + fixed colour of this line")
            if line > 0 { XCTAssertEqual(out.word(line - 1, line), bgr(0, 0, line)) }
        }
    }

    func testCOLDATAWritesFromTheWikiExamples() {
        var r = PPURegisters()
        r.writeCOLDATA(0xFF)
        XCTAssertEqual(r.fixedColor.word, 0x7FFF, "white: one write")
        r.writeCOLDATA(0xE0)
        XCTAssertEqual(r.fixedColor.word, 0, "black: one write")
        r.writeCOLDATA(0x9E); r.writeCOLDATA(0x5B); r.writeCOLDATA(0x36)
        XCTAssertEqual(r.fixedColor.word, bgr(22, 27, 30), "light blue: three writes")
        r.writeCOLDATA(0x80)
        XCTAssertEqual(r.fixedColor.word, bgr(22, 27, 0), "a write changes only selected channels")
    }

    func testBrightnessForcedBlankAnd239Lines() {
        var f = PPUScene.frame(height: 239)
        f.cgram[0] = bgr(31, 16, 1)
        f.setAllLines { $0.inidisp = 0x0F }
        f.lines[1].inidisp = 0x07
        f.lines[2].inidisp = 0x00
        f.lines[3].inidisp = 0x8F
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.count, 256 * 239 * 4)
        XCTAssertEqual(Array(out[0..<4]), [255, 132, 8, 255])
        let l1 = 256 * 4
        XCTAssertEqual(Array(out[l1..<l1 + 4]), [127, 66, 4, 255], "brightness 7: x 8/16")
        XCTAssertEqual(Array(out[2 * l1..<2 * l1 + 4]), [0, 0, 0, 255], "brightness 0 is black")
        XCTAssertEqual(Array(out[3 * l1..<3 * l1 + 4]), [0, 0, 0, 255], "forced blank")
        XCTAssertEqual(out.word(0, 238), bgr(31, 16, 1))
    }

    func testMode3ReadsBG1TilesAt8bpp() {
        // Slice 1 left modes 2-7 blank; slice 2 draws them (SNESPPUFeatureTests).
        // Tile 1 at 8bpp is the 4bpp tiles 2 (planes 0-3) and 3 (planes 4-7).
        var f = PPUScene.frame()
        f.cgram[0x32] = 0x1234
        PPUScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1))
        f.setAllLines { $0.tm = 0x01; $0.bgmode = 0x03 }
        XCTAssertEqual(PPUReferenceRenderer.render(f).word(0, 0), 0x1234)
    }
}
