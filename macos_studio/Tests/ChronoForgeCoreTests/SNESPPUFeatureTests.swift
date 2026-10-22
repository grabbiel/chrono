// SNESPPUFeatureTests.swift — the CPU reference PPU's slice 2 features
// against pixels derived by hand from the documented rules (docs/ppu.md):
// mid-frame memory writes, mosaic, BG modes 2-6, offset-per-tile, direct
// color, Mode 7 and EXTBG, hi-res, interlace and the overscan border.
import XCTest
@testable import ChronoForgeCore

/// Scenes for the slice 2 tests. Every CGRAM word equals its index, so a
/// rendered pixel's BGR555 word is the CGRAM index it came from.
enum FeatureScene {
    static let bg1Chars = 0x2000, bg2Chars = 0x4000, objChars = 0x6000

    static func solid(_ index: UInt8) -> [UInt8] { [UInt8](repeating: index, count: 64) }

    /// A gradient tile: pixel (col, row) is 1 + (col + row) % 15.
    static let gradient: [UInt8] = {
        var tile = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 {
            let value: Int = 1 + (i % 8 + i / 8) % 15
            tile[i] = UInt8(value)
        }
        return tile
    }()

    /// BG1/BG2/BG3 tilemaps at 0000h/0400h/0800h, BG1 chars at 2000h, BG2
    /// chars at 4000h, OBJ chars at 6000h; VOFS -1 so tile rows line up with
    /// output rows.
    static func frame(mode: UInt8, height: Int = 224) -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = mode
        r.bg[0] = PPUBGRegisters(sc: 0x00, charBase: 2, vofs: 0x3FF)
        r.bg[1] = PPUBGRegisters(sc: 0x04, charBase: 4, vofs: 0x3FF)
        r.bg[2] = PPUBGRegisters(sc: 0x08, charBase: 4, vofs: 0x3FF)
        r.obsel = 0x03
        var f = PPUFrame(height: height, registers: r)
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        return f
    }

    static func setMap(_ f: inout PPUFrame, bg: Int, tx: Int, ty: Int, _ entry: UInt16) {
        f.vram[bg * 0x400 + ty * 32 + tx] = entry
    }

    static func fillMap(_ f: inout PPUFrame, bg: Int, _ entry: UInt16) {
        for i in 0..<1024 { f.vram[bg * 0x400 + i] = entry }
    }

    /// Mode 7 with tile 1 = pixel 1 + col + row * 8 on every map cell and
    /// M7VOFS -1, so screen (x, y) shows texel (x, y).
    static func mode7() -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = 0x07
        r.tm = 0x01
        r.m7vofs = -1
        var f = PPUFrame(registers: r)
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        let tile = (0..<64).map { UInt8(1 + $0) }
        f.storeMode7Tiles(tile, firstTile: 1)
        for y in 0..<128 { for x in 0..<128 { f.setMode7Tile(x: x, y: y, tile: 1) } }
        return f
    }

    static func texel(_ x: Int, _ y: Int) -> UInt16 { UInt16(1 + (x & 7) + (y & 7) * 8) }
}

extension PPUImage {
    func word(_ x: Int, _ y: Int) -> UInt16 {
        let o = (y * width + x) * 4
        let r = UInt16(rgba[o] >> 3), g = UInt16(rgba[o + 1] >> 3), b = UInt16(rgba[o + 2] >> 3)
        return r | g << 5 | b << 10
    }
}

final class SNESPPUFeatureTests: XCTestCase {
    // MARK: Mid-frame writes

    func testMidFrameCGRAMWritesMakeAGradient() {
        var f = FeatureScene.frame(mode: 0x01)
        for line in 0..<224 { f.writeCGRAM(line: line, index: 0, color: UInt16(line & 31)) }
        let out = PPUReferenceRenderer.render(f)
        for line in [0, 1, 31, 100, 223] { XCTAssertEqual(out.word(5, line), UInt16(line & 31), "line \(line)") }
    }

    func testWritesTakeEffectFromTheirLineInLineThenQueueOrder() {
        var f = FeatureScene.frame(mode: 0x01)
        f.cgram[0] = 7
        f.writeCGRAM(line: 100, index: 0, color: 9)
        f.writeCGRAM(line: 50, index: 0, color: 8)
        f.writeCGRAM(line: 100, index: 0, color: 10)   // later in the queue: wins on line 100
        f.writeCGRAM(line: -5, index: 1, color: 3)      // before line 0
        let memory = f.memoryByLine()
        XCTAssertEqual(memory[0].cgram[0], 7)
        XCTAssertEqual(memory[0].cgram[1], 3)
        XCTAssertEqual(memory[49].cgram[0], 7)
        XCTAssertEqual(memory[50].cgram[0], 8)
        XCTAssertEqual(memory[100].cgram[0], 10)
        XCTAssertEqual(memory[223].cgram[0], 10)
        XCTAssertEqual(f.cgram[0], 7, "the frame's own memory is unchanged")
        XCTAssertEqual(f.linesChanging(.cgram), [0, 50, 100])
        XCTAssertEqual(f.linesChanging(.vram), [])
    }

    func testMidFrameVRAMAndOAMWrites() {
        var f = FeatureScene.frame(mode: 0x01)
        f.setAllLines { $0.tm = 0x11 }
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(1) + FeatureScene.solid(2), bpp: 4,
                     atWord: FeatureScene.bg1Chars)
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(3), bpp: 4, atWord: FeatureScene.objChars)
        FeatureScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1))
        f.setOBJ(0, x: 100, y: 0, tile: 1, priority: 3)
        // Line 80: BG1's map cell (0, 10) changes to tile 2; line 120: OBJ 0 moves to y 120.
        f.writeVRAM(line: 80, address: 10 * 32, word: PPUFrame.tilemapEntry(tile: 2))
        f.writeOAM(line: 120, address: 1, byte: 120)
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(0, 79), 1, "row 79 is map row 9")
        XCTAssertEqual(out.word(0, 80), 2, "map row 10 after the VRAM write")
        XCTAssertEqual(out.word(100, 7), 128 + 3, "the OBJ at y 0 covers lines 0-7")
        XCTAssertEqual(out.word(100, 119), 1, "no OBJ before the OAM write")
        XCTAssertEqual(out.word(100, 121), 128 + 3, "the OBJ at y 120 after the write")
    }

    // MARK: Mosaic

    func testMosaicBlocksShowTheirTopLeftPixel() {
        var f = FeatureScene.frame(mode: 0x01)
        f.setAllLines { $0.tm = 0x03; $0.mosaic = 0x31 }   // 4x4, BG1 only
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.gradient, bpp: 4, atWord: FeatureScene.bg1Chars)
        FeatureScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1))
        let out = PPUReferenceRenderer.render(f)
        func gradient(_ x: Int, _ y: Int) -> UInt16 { UInt16(1 + (x % 8 + y % 8) % 15) }
        for (x, y) in [(0, 0), (3, 3), (5, 2), (7, 7), (13, 9), (255, 223)] {
            XCTAssertEqual(out.word(x, y), gradient(x - x % 4, y - y % 4), "(\(x), \(y))")
        }
        f.setAllLines { $0.mosaic = 0x32 }   // BG2 only: BG1 is untouched
        let off = PPUReferenceRenderer.render(f)
        XCTAssertEqual(off.word(5, 2), gradient(5, 2))
        f.setAllLines { $0.mosaic = 0x01 }   // 1x1 is no mosaic
        XCTAssertEqual(PPUReferenceRenderer.render(f).word(5, 2), gradient(5, 2))
    }

    func testMosaicSizeChangeFinishesTheCurrentBlock() {
        var lines = [PPURegisters](repeating: PPURegisters(), count: 12)
        for i in 0..<12 { lines[i].mosaic = i < 4 ? 0x20 : 0x10 }   // size 3, then 2 from line 4
        // Blocks: 0-2 and 3-5 (size 3, the size when the block began), then 6-7, 8-9, 10-11.
        XCTAssertEqual(PPUMosaic.verticalIndices(lines), [0, 1, 2, 0, 1, 2, 0, 1, 0, 1, 0, 1])
    }

    // MARK: BG modes 2-6

    enum Slot: Equatable { case bg(Int, Int), obj(Int) }

    /// Like slice 1's pairwise check: every pair of slots overlaps in its own
    /// 8x8 block and the front one must show. Low/high BG slots use tiles
    /// 2-3 / 4-5 (16-pixel hi-res tiles use N and N+1, so an empty entry's
    /// tiles 0 and 1 are both blank).
    func checkPairwiseOrder(mode: UInt8, frontToBack: [Slot], file: StaticString = #filePath, line: UInt = #line) {
        var f = FeatureScene.frame(mode: mode)
        f.setAllLines { $0.tm = 0x13 }
        let m = Int(mode & 7)
        let bpps = [PPULayering.bpp(mode: m, bg: 0), PPULayering.bpp(mode: m, bg: 1)]
        for n in 0..<2 where bpps[n] != 0 {
            let high: UInt8 = bpps[n] == 8 ? 2 : 1
            var tiles = FeatureScene.solid(0) + FeatureScene.solid(0)
            tiles += FeatureScene.solid(1) + FeatureScene.solid(1)
            tiles += FeatureScene.solid(high) + FeatureScene.solid(high)
            f.storeTiles(tiles, bpp: bpps[n], atWord: n == 0 ? FeatureScene.bg1Chars : FeatureScene.bg2Chars)
        }
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(1), bpp: 4, atWord: FeatureScene.objChars)
        func entry(_ n: Int, _ p: Int) -> UInt16 {
            let palette = bpps[n] == 8 ? 0 : (bpps[n] == 2 ? 2 + p : n * 2 + p)
            return PPUFrame.tilemapEntry(tile: p == 0 ? 2 : 4, palette: palette, priority: p == 1)
        }
        func color(_ s: Slot) -> UInt16 {
            switch s {
            case .obj(let p): return UInt16(128 + p * 16 + 1)
            case .bg(let n, let p):
                if bpps[n] == 8 { return UInt16(p + 1) }
                return bpps[n] == 2 ? UInt16((2 + p) * 4 + 1) : UInt16((n * 2 + p) * 16 + 1)
            }
        }
        func layer(_ s: Slot) -> Int { if case .bg(let n, _) = s { return n }; return 4 }
        var objIndex = 0
        var expected: [(Int, Int, UInt16)] = []
        for (i, a) in frontToBack.enumerated() {
            for (j, b) in frontToBack.enumerated() where layer(a) != layer(b) {
                for s in [a, b] {
                    switch s {
                    case .bg(let n, let p): FeatureScene.setMap(&f, bg: n, tx: j, ty: i, entry(n, p))
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
            XCTAssertEqual(out.word(x, y), c, "mode \(m) block (\(x / 8), \(y / 8))", file: file, line: line)
        }
    }

    func testModes2To5PriorityOrder() {
        let order: [Slot] = [.obj(3), .bg(0, 1), .obj(2), .bg(1, 1), .obj(1), .bg(0, 0), .obj(0), .bg(1, 0)]
        for mode: UInt8 in [0x02, 0x03, 0x04, 0x05] { checkPairwiseOrder(mode: mode, frontToBack: order) }
    }

    func testMode6PriorityOrder() {
        checkPairwiseOrder(mode: 0x06, frontToBack: [.obj(3), .bg(0, 1), .obj(2), .obj(1), .bg(0, 0), .obj(0)])
    }

    func testBitDepthsAndPaletteIndices() {
        // Mode 3 BG1 is 8bpp (CGRAM = pixel), BG2 4bpp; mode 4 BG2 is 2bpp with
        // pal * 4 + c; BG3 holds OPT data in modes 2, 4 and 6 and is not drawn.
        var f = FeatureScene.frame(mode: 0x03)
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(0xB5), bpp: 8, atWord: FeatureScene.bg1Chars)
        FeatureScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 3))
        f.setAllLines { $0.tm = 0x01 }
        XCTAssertEqual(PPUReferenceRenderer.render(f).word(0, 0), 0xB5)
        var g = FeatureScene.frame(mode: 0x04)
        g.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(3), bpp: 2, atWord: FeatureScene.bg2Chars)
        FeatureScene.fillMap(&g, bg: 1, PPUFrame.tilemapEntry(tile: 1, palette: 5))
        g.setAllLines { $0.tm = 0x02 }
        XCTAssertEqual(PPUReferenceRenderer.render(g).word(0, 0), 5 * 4 + 3)
        var h = FeatureScene.frame(mode: 0x02)
        h.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(1), bpp: 4, atWord: FeatureScene.bg2Chars)
        FeatureScene.fillMap(&h, bg: 2, PPUFrame.tilemapEntry(tile: 1))
        h.setAllLines { $0.tm = 0x04 }
        XCTAssertEqual(PPUReferenceRenderer.render(h).word(0, 0), 0, "BG3 is not displayed in mode 2")
    }

    func testDirectColorInModes3And4() {
        var f = FeatureScene.frame(mode: 0x03)
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(0xC7), bpp: 8, atWord: FeatureScene.bg1Chars)
        FeatureScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1, palette: 5))
        FeatureScene.setMap(&f, bg: 0, tx: 1, ty: 0, PPUFrame.tilemapEntry(tile: 0, palette: 5))
        f.setAllLines { $0.tm = 0x01; $0.cgwsel = 0x01 }
        f.cgram[0] = bgr(1, 2, 3)
        let out = PPUReferenceRenderer.render(f)
        // BBGGGRRR = 11 000 111, palette bgr = 101: R 111 1 0, G 000 0 0, B 11 1 00.
        XCTAssertEqual(out.word(0, 0), bgr(30, 0, 28))
        XCTAssertEqual(PPUReferenceRenderer.directColor(0xC7, palette: 5), bgr(30, 0, 28))
        XCTAssertEqual(PPUReferenceRenderer.directColor(0x38, palette: 2), bgr(0, 30, 0))
        XCTAssertEqual(out.word(8, 0), bgr(1, 2, 3), "pixel 0 is transparent, not black")
        f.setAllLines { $0.bgmode = 0x04 }
        XCTAssertEqual(PPUReferenceRenderer.render(f).word(0, 0), bgr(30, 0, 28), "mode 4 BG1")
    }

    // MARK: Offset-per-tile

    /// Mode 2 or 4 with BG1 tile (tx, ty) showing color (ty % 8) * 16 + 1 + tx % 15
    /// (mode 2: 4bpp tile 1 + tx % 15 in palette ty % 8; mode 4: 8bpp tile of
    /// that number); BG3's map holds the offsets.
    func optFrame(mode: UInt8) -> PPUFrame {
        var f = FeatureScene.frame(mode: mode)
        f.setAllLines { $0.tm = 0x01 }
        let count = mode == 4 ? 128 : 16
        var tiles: [UInt8] = []
        for k in 0..<count { tiles += FeatureScene.solid(UInt8(k)) }
        f.storeTiles(tiles, bpp: mode == 4 ? 8 : 4, atWord: FeatureScene.bg1Chars)
        for ty in 0..<32 {
            for tx in 0..<32 {
                let entry = mode == 4
                    ? PPUFrame.tilemapEntry(tile: 1 + tx % 15 + 16 * (ty % 8))
                    : PPUFrame.tilemapEntry(tile: 1 + tx % 15, palette: ty % 8)
                FeatureScene.setMap(&f, bg: 0, tx: tx, ty: ty, entry)
            }
        }
        f.setAllLines { $0.bg[2].vofs = 0; $0.bg[2].hofs = 0 }
        return f
    }

    func decode(_ w: UInt16) -> (tx: Int, ty: Int) { (Int(w & 15) - 1, Int(w >> 4)) }

    func testOffsetPerTileReplacesScrollFromTheSecondColumn() {
        var f = optFrame(mode: 0x02)
        FeatureScene.setMap(&f, bg: 2, tx: 0, ty: 0, 0x2000 | 5 * 8 | 7)     // column 1: HOFS 40 (low bits ignored)
        FeatureScene.setMap(&f, bg: 2, tx: 2, ty: 1, 0x2000 | 16 - 1)        // column 3: VOFS 15
        FeatureScene.setMap(&f, bg: 2, tx: 4, ty: 0, 0x4000 | 8)             // column 5: BG2 only
        FeatureScene.setMap(&f, bg: 2, tx: 5, ty: 0, 0x6000 | 8)             // column 6: both
        var out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(decode(out.word(0, 0)).tx, 0, "column 0 keeps BG1HOFS")
        XCTAssertEqual(decode(out.word(8, 0)).tx, 6, "column 1: HOFS 40 shows tile 1 + 5")
        XCTAssertEqual(decode(out.word(16, 0)).tx, 2, "no bit 13: no change")
        XCTAssertEqual(decode(out.word(24, 0)).ty, 2, "column 3: VOFS 15, line 0 shows map row 2")
        XCTAssertEqual(decode(out.word(24, 0)).tx, 3)
        XCTAssertEqual(decode(out.word(40, 0)).tx, 5, "bit 14 applies to BG2, not BG1")
        XCTAssertEqual(decode(out.word(48, 0)).tx, 7, "bits 13 and 14: BG1 too")
        // BG1 fine scroll 3: column 0 is x 0-4; x 5 is column 1, and keeps the low 3 bits.
        f.setAllLines { $0.bg[0].hofs = 3 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(decode(out.word(4, 0)).tx, 0)
        XCTAssertEqual(decode(out.word(5, 0)).tx, 6, "(5 + 43) / 8 = 6")
        // BG3HOFS 16 shifts the offset row by two entries: column 1 reads entry 2.
        f.setAllLines { $0.bg[0].hofs = 0; $0.bg[2].hofs = 16 + 5 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(decode(out.word(8, 0)).tx, 1, "entry 2 has no bit 13")
        XCTAssertEqual(decode(out.word(8, 0)).ty, 2, "entry 2 of the VOFS row: VOFS 15")
        XCTAssertEqual(decode(out.word(24, 0)).tx, 3, "column 3 reads entry 4, which is BG2's")
    }

    func testMode4OffsetPerTileBit15PicksTheDirection() {
        var f = optFrame(mode: 0x04)
        FeatureScene.setMap(&f, bg: 2, tx: 0, ty: 0, 0x2000 | 5 * 8)            // column 1: horizontal
        FeatureScene.setMap(&f, bg: 2, tx: 1, ty: 0, 0xA000 | 16 - 1)           // column 2: vertical
        FeatureScene.setMap(&f, bg: 2, tx: 1, ty: 1, 0x2000 | 9 * 8)            // a second row is not read
        let out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(decode(out.word(8, 0)).tx, 6, "column 1: horizontal entry")
        XCTAssertEqual(decode(out.word(16, 0)).ty, 2, "column 2: vertical entry, VOFS 15")
        XCTAssertEqual(decode(out.word(16, 0)).tx, 2, "a vertical entry keeps HOFS; the second row is unused")
    }

    // MARK: Mode 7

    func testMode7IdentityScrollScaleAndFlips() {
        var f = FeatureScene.mode7()
        var out = PPUReferenceRenderer.render(f)
        for (x, y) in [(0, 0), (3, 5), (9, 17), (255, 223)] { XCTAssertEqual(out.word(x, y), FeatureScene.texel(x, y)) }
        f.setAllLines { $0.m7hofs = 3; $0.m7vofs = 1 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(0, 0), FeatureScene.texel(3, 2), "scroll moves the view")
        f.setAllLines { $0.m7hofs = 0; $0.m7vofs = -1; $0.m7a = 0x0200 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(3, 0), FeatureScene.texel(6, 0), "A = 2: two texels per pixel")
        f.setAllLines { $0.m7a = 0x0100; $0.m7sel = 0x01 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(0, 0), FeatureScene.texel(255, 0), "H flip: x XOR FFh")
        f.setAllLines { $0.m7sel = 0x02; $0.m7vofs = 0 }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(0, 0), FeatureScene.texel(0, 254), "V flip: (line + 1) XOR FFh")
    }

    func testMode7ShearAndTheSixBitTruncation() {
        var f = FeatureScene.mode7()
        f.setAllLines { $0.m7b = 0x0080 }   // half a texel right per line down
        var out = PPUReferenceRenderer.render(f)
        // VRAM.X = ((B * -1) & ~3Fh) + ((B * (line + 1)) & ~3Fh) + 100h * x = 100h * x + 80h * line.
        for (x, y) in [(0, 0), (0, 1), (0, 2), (5, 7), (5, 9)] {
            XCTAssertEqual(out.word(x, y), FeatureScene.texel(x + y / 2, y), "(\(x), \(y))")
        }
        // B = FFh: on line 0, (FFh * -1) & ~3Fh = -100h and (FFh * 1) & ~3Fh = C0h, so
        // VRAM.X = 100h * x - 40h: x 1 shows texel 0 (without truncation it would be 1).
        f.setAllLines { $0.m7b = 0x00FF }
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(1, 0), FeatureScene.texel(0, 0))
    }

    func testMode7ScreenOverAndTheMap() {
        var f = FeatureScene.mode7()
        f.storeMode7Tiles(FeatureScene.solid(100), firstTile: 0)
        f.storeMode7Tiles(FeatureScene.solid(70), firstTile: 2)
        f.setMode7Tile(x: 1, y: 0, tile: 2)
        f.cgram[0] = 0x7C00
        f.setAllLines { $0.m7hofs = -8 }   // x 0-7 are left of the map, x 8-15 the map's column 0
        let wrap = PPUReferenceRenderer.render(f)
        XCTAssertEqual(wrap.word(0, 0), FeatureScene.texel(0, 0), "over 0: wraps to column 127")
        XCTAssertEqual(wrap.word(16, 0), 70, "map cell (1, 0) is tile 2")
        f.setAllLines { $0.m7sel = 0x40 }
        XCTAssertEqual(PPUReferenceRenderer.render(f).word(0, 0), FeatureScene.texel(0, 0), "over 1 wraps too")
        f.setAllLines { $0.m7sel = 0x80 }
        XCTAssertEqual(PPUReferenceRenderer.render(f).word(0, 0), 0x7C00, "over 2: transparent")
        f.setAllLines { $0.m7sel = 0xC0 }
        let fill = PPUReferenceRenderer.render(f)
        XCTAssertEqual(fill.word(0, 0), 100, "over 3: tile 0")
        XCTAssertEqual(fill.word(8, 0), FeatureScene.texel(0, 0), "inside the map is unchanged")
    }

    func testMode7PerLineMatrixMosaicAndDirectColor() {
        var f = FeatureScene.mode7()
        for line in 0..<224 { f.lines[line].m7hofs = Int16(line) }   // an HDMA-style per-line table
        var out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(0, 10), FeatureScene.texel(10, 10))
        f.setAllLines { $0.m7hofs = 0; $0.mosaic = 0x21 }   // 3x3 on BG1
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual(out.word(5, 5), FeatureScene.texel(3, 3))
        XCTAssertEqual(out.word(2, 7), FeatureScene.texel(0, 6))
        var g = FeatureScene.mode7()
        g.storeMode7Tiles(FeatureScene.solid(0xC7), firstTile: 1)
        g.setAllLines { $0.cgwsel = 0x01 }
        XCTAssertEqual(PPUReferenceRenderer.render(g).word(0, 0), bgr(28, 0, 24), "direct color, no palette bits")
    }

    func testMode7EXTBGPriorityAndOrder() {
        var f = FeatureScene.mode7()
        f.storeMode7Tiles(FeatureScene.solid(0x85), firstTile: 1)
        f.cgram[0] = 0x7FFF
        f.cgram[0x05] = 0x0005; f.cgram[0x85] = 0x0085
        func pixel(tm: UInt8, setini: UInt8) -> UInt16 {
            var g = f
            g.setAllLines { $0.tm = tm; $0.setini = setini }
            return PPUReferenceRenderer.render(g).word(0, 0)
        }
        XCTAssertEqual(pixel(tm: 0x01, setini: 0), 0x85, "BG1 uses all 8 bits")
        XCTAssertEqual(pixel(tm: 0x02, setini: 0), 0x7FFF, "no BG2 without EXTBG")
        XCTAssertEqual(pixel(tm: 0x02, setini: 0x40), 0x05, "EXTBG BG2: bits 6-0")
        XCTAssertEqual(pixel(tm: 0x03, setini: 0x40), 0x05, "bit 7 set: BG2 high, in front of BG1")
        f.storeMode7Tiles(FeatureScene.solid(0x05), firstTile: 1)
        f.cgram[0x05] = 0x0123
        XCTAssertEqual(pixel(tm: 0x01, setini: 0x40), 0x0123)
        f.cgram[0x05] = 0x0005
        // BG2 low is behind BG1, and the same CGRAM entry; check against OBJs instead.
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(1), bpp: 4, atWord: FeatureScene.objChars)
        func objOver(_ priority: Int, tm: UInt8, pixel: UInt8) -> UInt16 {
            var g = f
            g.storeMode7Tiles(FeatureScene.solid(pixel), firstTile: 1)
            g.setOBJ(0, x: 0, y: 0, tile: 1, priority: priority)
            g.setAllLines { $0.tm = tm; $0.setini = 0x40; $0.obsel = 0x03 }
            return PPUReferenceRenderer.render(g).word(0, 0)
        }
        // Mode 7: S3 S2 2H S1 1 S0 2L.
        XCTAssertEqual(objOver(0, tm: 0x11, pixel: 0x85), 0x85, "BG1 in front of OBJ 0")
        XCTAssertEqual(objOver(1, tm: 0x11, pixel: 0x85), 129, "OBJ 1 in front of BG1")
        XCTAssertEqual(objOver(1, tm: 0x12, pixel: 0x85), 0x05, "BG2 high in front of OBJ 1")
        XCTAssertEqual(objOver(2, tm: 0x12, pixel: 0x85), 129, "OBJ 2 in front of BG2 high")
        XCTAssertEqual(objOver(0, tm: 0x12, pixel: 0x05), 129, "OBJ 0 in front of BG2 low")
    }

    // MARK: Hi-res

    /// Mode 5 with BG1 (4bpp) tile pairs 1/2 solid 1 and 2, BG2 (2bpp) solid 3.
    func hiresFrame() -> PPUFrame {
        var f = FeatureScene.frame(mode: 0x05)
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(1) + FeatureScene.solid(2), bpp: 4,
                     atWord: FeatureScene.bg1Chars)
        f.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(3) + FeatureScene.solid(3), bpp: 2,
                     atWord: FeatureScene.bg2Chars)
        FeatureScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1))
        FeatureScene.fillMap(&f, bg: 1, PPUFrame.tilemapEntry(tile: 1))
        return f
    }

    func testModes5And6DrawSixteenHalfPixelTiles() {
        var f = hiresFrame()
        f.setAllLines { $0.tm = 0x01; $0.ts = 0x01 }
        let image = PPUReferenceRenderer.renderImage(f)
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual((0..<16).map { image.word($0, 0) }, [UInt16](repeating: 1, count: 8) + [UInt16](repeating: 2, count: 8),
                       "tile N is the left 8 half-pixels, N+1 the right 8")
        f.setAllLines { $0.bg[0].hofs = 1 }
        let scrolled = PPUReferenceRenderer.renderImage(f)
        XCTAssertEqual(scrolled.word(5, 0), 1)
        XCTAssertEqual(scrolled.word(6, 0), 2, "HOFS counts in 2 half-pixels")
        let main = PPUReferenceRenderer.render(f)
        XCTAssertEqual(main.count, 256 * 224 * 4)
        XCTAssertEqual(main.word(2, 0), 1)
        XCTAssertEqual(main.word(3, 0), 2, "256-wide: the main screen's odd half-pixel")
        f.setAllLines { $0.bgmode = 0x06; $0.tm = 0x03 }
        XCTAssertEqual(PPUReferenceRenderer.renderImage(f).word(6, 0), 2, "mode 6 too")
    }

    func testHiresPutsTheSubScreenOnEvenColumns() {
        var f = hiresFrame()
        f.setAllLines { $0.tm = 0x01; $0.ts = 0x02; $0.fixedColor = BGR555(word: 0x1111) }
        f.cgram[0] = 0x7000
        var image = PPUReferenceRenderer.renderImage(f)
        XCTAssertEqual([image.word(0, 0), image.word(1, 0)], [3, 1], "even: sub (BG2), odd: main (BG1)")
        f.setAllLines { $0.ts = 0 }
        image = PPUReferenceRenderer.renderImage(f)
        XCTAssertEqual(image.word(0, 0), 0x7000, "transparent sub: CGRAM 0, not the fixed color")
        // Pseudo 512 in mode 1: BGs stay 256-wide, the sub screen still takes even columns.
        var g = FeatureScene.frame(mode: 0x01)
        g.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(1), bpp: 4, atWord: FeatureScene.bg1Chars)
        g.storeTiles(FeatureScene.solid(0) + FeatureScene.solid(2), bpp: 4, atWord: FeatureScene.bg2Chars)
        FeatureScene.fillMap(&g, bg: 0, PPUFrame.tilemapEntry(tile: 1))
        FeatureScene.fillMap(&g, bg: 1, PPUFrame.tilemapEntry(tile: 1))
        g.setAllLines { $0.tm = 0x01; $0.ts = 0x02; $0.setini = 0x08 }
        g.lines[10].setini = 0
        image = PPUReferenceRenderer.renderImage(g)
        XCTAssertEqual([image.word(0, 0), image.word(1, 0), image.word(2, 0)], [2, 1, 2])
        XCTAssertEqual([image.word(0, 10), image.word(1, 10)], [1, 1], "a normal line repeats each pixel")
        XCTAssertEqual(PPUReferenceRenderer.renderImage(g, options: PPURenderOptions(highResolution: false)).width, 256)
        g.setAllLines { $0.setini = 0 }
        XCTAssertEqual(PPUReferenceRenderer.renderImage(g).width, 256, "no hi-res line: 256 wide")
    }

    func testHiresMosaicCountsFullPixels() {
        var f = hiresFrame()
        f.setAllLines { $0.tm = 0x01; $0.ts = 0x01; $0.mosaic = 0x01 }   // 1x1, BG1
        let image = PPUReferenceRenderer.renderImage(f)
        // Each pair of half-pixels shows the even one: x 3 (half-pixels 6, 7) shows 6, x 4 shows 8.
        XCTAssertEqual([image.word(7, 0), image.word(8, 0), image.word(9, 0)], [1, 2, 2])
        XCTAssertEqual(image.word(1, 0), 1)
    }

    // MARK: Interlace

    func testInterlacedModes5And6UseHalfLines() {
        var f = FeatureScene.frame(mode: 0x05)
        // Tile pair 1/2: pixel index 1 + row.
        let rows = (0..<64).map { UInt8(1 + $0 / 8) }
        f.storeTiles(FeatureScene.solid(0) + rows + rows, bpp: 4, atWord: FeatureScene.bg1Chars)
        FeatureScene.fillMap(&f, bg: 0, PPUFrame.tilemapEntry(tile: 1))
        f.setAllLines { $0.tm = 0x01; $0.setini = 0x01; $0.bg[0].vofs = 0x3FE }
        XCTAssertEqual((0..<4).map { PPUReferenceRenderer.render(f).word(0, $0) }, [1, 3, 5, 7], "field 0: even half-lines")
        f.field = 1
        XCTAssertEqual((0..<4).map { PPUReferenceRenderer.render(f).word(0, $0) }, [2, 4, 6, 8], "field 1: odd half-lines")
        f.setAllLines { $0.setini = 0 }
        XCTAssertEqual(PPUReferenceRenderer.render(f).word(0, 2), 2, "without interlace: line 2 shows row 1")
    }

    func testOBJInterlaceHalvesOBJHeight() {
        var f = FeatureScene.frame(mode: 0x01)
        f.setAllLines { $0.tm = 0x10; $0.setini = 0x02 }   // OBSEL size 0: 8x8 / 16x16
        // A 16x16 OBJ whose row r has index 1 + r % 8, tiles 1, 2, 17, 18.
        let rows = (0..<64).map { UInt8(1 + $0 / 8) }
        f.storeTiles(FeatureScene.solid(0) + rows + rows, bpp: 4, atWord: FeatureScene.objChars)
        f.storeTiles(rows + rows, bpp: 4, atWord: FeatureScene.objChars + 17 * 16)
        f.setOBJ(0, x: 0, y: 20, tile: 1, large: true)
        var out = PPUReferenceRenderer.render(f)
        XCTAssertEqual((20..<29).map { out.word(0, $0) }, [129, 131, 133, 135, 129, 131, 133, 135, 0])
        f.field = 1
        out = PPUReferenceRenderer.render(f)
        XCTAssertEqual((20..<24).map { out.word(0, $0) }, [130, 132, 134, 136])
        XCTAssertEqual(PPUOBJEvaluator.evaluate(oam: f.oam, registers: f.lines[28], line: 28, field: 1).slivers.count, 0)
    }

    func testWeaveInterleavesFields() {
        let even = PPUImage(width: 1, height: 2, rgba: [1, 1, 1, 255, 2, 2, 2, 255])
        let odd = PPUImage(width: 1, height: 2, rgba: [3, 3, 3, 255, 4, 4, 4, 255])
        let woven = PPUImage.weave(even: even, odd: odd)
        XCTAssertEqual(woven.height, 4)
        XCTAssertEqual([woven.rgba[0], woven.rgba[4], woven.rgba[8], woven.rgba[12]], [1, 3, 2, 4])
    }

    // MARK: Overscan border

    func testOverscanBorderIsBlackAroundThePicture() {
        var f = FeatureScene.frame(mode: 0x01)
        f.cgram[0] = 0x7FFF
        let image = PPUReferenceRenderer.renderImage(f, options: PPURenderOptions(overscanBorder: true))
        XCTAssertEqual([image.width, image.height], [256, 239])
        XCTAssertEqual(image.word(0, 7), 0, "8 border lines above a 224-line picture")
        XCTAssertEqual(image.word(0, 8), 0x7FFF)
        XCTAssertEqual(image.word(255, 231), 0x7FFF)
        XCTAssertEqual(image.word(0, 232), 0, "7 border lines below")
        XCTAssertEqual(image.rgba[3], 255)
        var tall = FeatureScene.frame(mode: 0x01, height: 239)
        tall.cgram[0] = 0x7FFF
        let full = PPUReferenceRenderer.renderImage(tall, options: PPURenderOptions(overscanBorder: true))
        XCTAssertEqual([full.word(0, 0), full.word(0, 238)], [0x7FFF, 0x7FFF], "239 lines fill the area")
    }
}
