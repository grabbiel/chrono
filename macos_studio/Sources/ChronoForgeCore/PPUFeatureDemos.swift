// PPUFeatureDemos.swift — synthetic PPU pictures for the slice 2 features
// (docs/ppu.md), for the Studio's PPU Demos window and `chronoforge ppu
// demos`: an HDMA CGRAM gradient, mosaic, offset-per-tile, direct color,
// Mode 7 and EXTBG, hi-res, pseudo 512, interlace and the overscan border.
// Every tile, map and palette is generated here; none comes from a ROM.
import Foundation

extension PPUPreviewScenes {
    public enum Demo: String, CaseIterable, Sendable, Identifiable {
        case hdmaGradient = "HDMA CGRAM gradient"
        case mosaic = "Mosaic"
        case offsetPerTile = "Offset-per-tile"
        case directColor = "Direct color"
        case mode7 = "Mode 7"
        case extbg = "Mode 7 EXTBG"
        case hires = "Hi-res (mode 5)"
        case pseudoHires = "Pseudo 512"
        case interlace = "Interlace"
        case overscan = "Overscan border"

        public var id: String { rawValue }
        /// A short file-name-safe name.
        public var slug: String {
            switch self {
            case .hdmaGradient: return "gradient"
            case .mosaic: return "mosaic"
            case .offsetPerTile: return "opt"
            case .directColor: return "direct"
            case .mode7: return "mode7"
            case .extbg: return "extbg"
            case .hires: return "hires"
            case .pseudoHires: return "pseudo512"
            case .interlace: return "interlace"
            case .overscan: return "overscan"
            }
        }
    }

    /// How the demo is drawn: 512 columns where it has hi-res lines, and the
    /// border for the overscan demo.
    public static func options(_ d: Demo) -> PPURenderOptions {
        PPURenderOptions(highResolution: true, overscanBorder: d == .overscan)
    }

    /// The demo at animation frame `n`.
    public static func demo(_ d: Demo, frame n: Int = 0) -> PPUFrame {
        var f = demoBase(d)
        animate(d, &f, frame: n)
        return f
    }

    /// A five-bit rainbow: color `i` of `n` around the hue circle.
    public static func rainbow(_ i: Int, of n: Int) -> UInt16 {
        let h = (i % n) * 6 * 31 / n
        let x = h % 31
        let (r, g, b): (Int, Int, Int)
        switch h / 31 {
        case 0: (r, g, b) = (31, x, 0)
        case 1: (r, g, b) = (31 - x, 31, 0)
        case 2: (r, g, b) = (0, 31, x)
        case 3: (r, g, b) = (0, 31 - x, 31)
        case 4: (r, g, b) = (x, 0, 31)
        default: (r, g, b) = (31, 0, 31 - x)
        }
        return BGR555(r5: UInt8(r), g5: UInt8(g), b5: UInt8(b)).word
    }

    /// 8x8 tile of 64 pixels from a function of (col, row).
    static func tile(_ pixel: (Int, Int) -> Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 64)
        for row in 0..<8 { for col in 0..<8 { out[row * 8 + col] = UInt8(pixel(col, row) & 0xFF) } }
        return out
    }

    /// A 4bpp brick, a diagonal stripe, a ring and a dot, tiles 1-4.
    static let demoTiles4: [UInt8] = {
        var tiles = [UInt8](repeating: 0, count: 64)
        tiles += tile { c, r in (r == 7 || (c == 0 && r < 4) || (c == 4 && r >= 4)) ? 1 : 2 + (c + r) % 3 }
        tiles += tile { c, r in 5 + ((c + r) / 2) % 4 }
        tiles += tile { c, r in
            let dx = c * 2 - 7, dy = r * 2 - 7
            let d = dx * dx + dy * dy
            return d < 20 ? 9 : (d < 45 ? 10 : 11)
        }
        tiles += tile { c, r in (c - 3) * (c - 3) + (r - 3) * (r - 3) < 5 ? 12 : 0 }
        return tiles
    }()

    static func demoCGRAM() -> [UInt16] {
        var cgram = [UInt16](repeating: 0, count: 256)
        cgram[0] = backdrop
        for p in 0..<8 {
            for c in 1..<16 { cgram[p * 16 + c] = rainbow(c * 3 + p * 5, of: 48) }
            cgram[p * 16 + 1] = BGR555(r5: 4, g5: 4, b5: 5).word
        }
        for c in 128..<256 { cgram[c] = rainbow(c, of: 64) }
        return cgram
    }

    /// Mode 1 with BG1 a tiled wall at 0000h (map 6000h, 64x32) and BG2 rings
    /// (map 6800h).
    static func layeredBase() -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = 0x01
        r.tm = 0x03
        r.bg[0] = PPUBGRegisters(sc: 0x61, charBase: 0, vofs: 0x3FF)
        r.bg[1] = PPUBGRegisters(sc: 0x69, charBase: 0, vofs: 0x3FF)
        var f = PPUFrame(registers: r)
        f.cgram = demoCGRAM()
        f.storeTiles(demoTiles4, bpp: 4, atWord: 0)
        for ty in 0..<32 {
            for tx in 0..<64 {
                let wall = ty < 14 ? 0 : (ty % 4 == 0 ? 2 : 1)
                f.vram[0x6000 + (tx >> 5) * 0x400 + ty * 32 + (tx & 31)] = PPUFrame.tilemapEntry(tile: wall, palette: (tx / 4) % 8)
                let ring = (tx + ty) % 3 == 0 ? 3 : 0
                f.vram[0x6800 + (tx >> 5) * 0x400 + ty * 32 + (tx & 31)] = PPUFrame.tilemapEntry(tile: ring, palette: (ty / 2) % 8)
            }
        }
        return f
    }

    static func demoBase(_ d: Demo) -> PPUFrame {
        switch d {
        case .hdmaGradient, .overscan: return layeredBase()
        case .mosaic:
            var f = layeredBase()
            f.setAllLines { $0.bg[0].vofs = 0x3FF - 64 }
            return f
        case .offsetPerTile: return offsetPerTileBase()
        case .directColor: return directColorBase()
        case .mode7, .extbg: return mode7Base(extbg: d == .extbg)
        case .hires, .interlace: return hiresBase(interlace: d == .interlace)
        case .pseudoHires:
            var f = layeredBase()
            f.setAllLines { $0.tm = 0x01; $0.ts = 0x02; $0.setini = 0x08 }
            return f
        }
    }

    /// Mode 2: BG1 the wall, BG3's 64x32 map at 7000h holding a sine of
    /// VOFS entries (row 1) and a sawtooth of HOFS entries (row 0) for BG1.
    static func offsetPerTileBase() -> PPUFrame {
        var f = layeredBase()
        f.setAllLines {
            $0.bgmode = 0x02; $0.tm = 0x01
            $0.bg[2] = PPUBGRegisters(sc: 0x71, charBase: 0, hofs: 0, vofs: 0)
        }
        for column in 0..<64 {
            let v = Int((sin(Double(column) * .pi / 16) * 12).rounded()) & 0x3FF
            let h = (column % 8 == 0 ? 8 : 0)
            f.vram[0x7000 + (column >> 5) * 0x400 + 32 + (column & 31)] = 0x2000 | UInt16(v)
            f.vram[0x7000 + (column >> 5) * 0x400 + (column & 31)] = h == 0 ? 0 : 0x2000 | UInt16(h)
        }
        return f
    }

    /// Mode 3: BG1 8bpp tiles 0-255 solid (tile k is pixel k), a 16x16 grid
    /// of them in palette p = row / 2; lines from 112 use CGRAM instead.
    static func directColorBase() -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = 0x03
        r.tm = 0x01
        r.cgwsel = 0x01
        r.bg[0] = PPUBGRegisters(sc: 0x70, charBase: 0, hofs: 0x3F8, vofs: 0x3FF - 8)
        var f = PPUFrame(registers: r)
        f.cgram = demoCGRAM()
        var tiles: [UInt8] = []
        for k in 0..<256 { tiles += [UInt8](repeating: UInt8(k), count: 64) }
        f.storeTiles(tiles, bpp: 8, atWord: 0)
        for ty in 0..<32 {
            for tx in 0..<32 {
                let inGrid = tx >= 1 && tx < 33 && ty >= 1 && ty < 27
                let k = inGrid ? ((ty - 1) % 13 * 32 + (tx - 1)) % 256 : 0
                f.vram[0x7000 + ty * 32 + tx] = PPUFrame.tilemapEntry(tile: k, palette: (ty / 2) % 8)
            }
        }
        for line in 112..<224 { f.lines[line].cgwsel = 0 }
        return f
    }

    /// Mode 7: a 128x128 map of four generated tiles (checker, ring, cross,
    /// stripes); EXTBG gives the rings' pixels bit 7 (in front of OBJ 0-1).
    static func mode7Base(extbg: Bool) -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = 0x07
        r.tm = extbg ? 0x12 : 0x11
        r.obsel = 0x03
        r.setini = extbg ? 0x40 : 0
        var f = PPUFrame(registers: r)
        f.cgram = demoCGRAM()
        let high = extbg ? 0x80 : 0
        var tiles: [UInt8] = []
        tiles += tile { c, r in (c / 4 + r / 4) % 2 == 0 ? 20 : 40 }
        tiles += tile { c, r in
            let d = (c * 2 - 7) * (c * 2 - 7) + (r * 2 - 7) * (r * 2 - 7)
            return d < 30 ? high | 60 : 21
        }
        tiles += tile { c, r in c == 3 || c == 4 || r == 3 || r == 4 ? 80 : 22 }
        tiles += tile { c, r in 100 + (c + r) % 8 }
        f.storeMode7Tiles(tiles)
        for y in 0..<128 {
            for x in 0..<128 { f.setMode7Tile(x: x, y: y, tile: (x / 4 + y / 4 * 3) % 4) }
        }
        f.storeTiles(tile { c, r in (c - 3) * (c - 3) + (r - 3) * (r - 3) < 10 ? 1 + (c + r) % 15 : 0 }, bpp: 4,
                     atWord: 0x6000 + 16)
        for i in 0..<16 { f.setOBJ(i, x: i * 16, y: 100 + (i % 4) * 20, tile: 1, palette: i % 8, priority: i % 4) }
        return f
    }

    /// Mode 5: BG1 4bpp 16-half-pixel tiles of one-half-pixel stripes and
    /// a checker, BG2 2bpp dots; interlaced, rows are half-lines.
    static func hiresBase(interlace: Bool) -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = interlace ? 0x15 : 0x05
        r.tm = 0x13; r.ts = 0x13
        r.setini = interlace ? 0x03 : 0
        r.obsel = 0x03
        r.bg[0] = PPUBGRegisters(sc: 0x70, charBase: 0, vofs: 0x3FF)
        r.bg[1] = PPUBGRegisters(sc: 0x74, charBase: 2, vofs: 0x3FF)
        var f = PPUFrame(registers: r)
        f.cgram = demoCGRAM()
        var tiles = [UInt8](repeating: 0, count: 64)
        tiles += tile { c, _ in c % 2 == 0 ? 2 : 0 }
        tiles += tile { c, r in (c + r) % 2 == 0 ? 3 : 4 }
        tiles += tile { _, r in r % 2 == 0 ? 5 : 6 }
        tiles += tile { c, r in (c % 4 == 0) != (r % 4 == 0) ? 7 : 0 }
        f.storeTiles(tiles, bpp: 4, atWord: 0)
        f.storeTiles(tile { _, _ in 0 } + tile { c, r in c == 7 && r == 7 ? 3 : 0 }, bpp: 2, atWord: 0x2000)
        for ty in 0..<32 {
            for tx in 0..<32 {
                let n = (tx / 2 + ty / 2) % 2 == 0 ? 1 : 3
                f.vram[0x7000 + ty * 32 + tx] = PPUFrame.tilemapEntry(tile: n, palette: (tx + ty) % 8)
                f.vram[0x7400 + ty * 32 + tx] = PPUFrame.tilemapEntry(tile: 1, palette: 1 + ty % 7)
            }
        }
        f.storeTiles(tile { c, r in (c - 3) * (c - 3) + (r - 3) * (r - 3) < 10 ? 1 + (c * 2 + r) % 15 : 0 }, bpp: 4,
                     atWord: 0x6000 + 16)
        for i in 0..<8 { f.setOBJ(i, x: 20 + i * 28, y: 150, tile: 1, palette: i, priority: 3) }
        return f
    }

    /// Change the registers (and per-line writes) for animation frame n.
    public static func animate(_ d: Demo, _ f: inout PPUFrame, frame n: Int) {
        switch d {
        case .hdmaGradient, .overscan:
            // Sky: backdrop (CGRAM 0) rewritten before every line; the wall's
            // mortar color (CGRAM 1) shimmers from line 112.
            f.writes = []
            for line in 0..<f.height {
                let t = (line + n) % 224
                let sky = BGR555(r5: UInt8(min(31, t / 7)), g5: UInt8(min(31, t / 10)), b5: UInt8(31 - min(31, t / 8)))
                f.writeCGRAM(line: line, index: 0, color: sky.word)
                if line >= 112 { f.writeCGRAM(line: line, index: 1, color: rainbow(line + n * 2, of: 96)) }
            }
            f.setAllLines { $0.bg[0].hofs = UInt16(n & 0x3FF) }
        case .mosaic:
            // A mosaic transition on BG1 only: the size climbs 1 -> 16 and back.
            let phase = n % 64
            let size = phase < 32 ? phase / 2 : 15 - (phase - 32) / 2
            f.setAllLines { $0.mosaic = UInt8(size << 4) | 0x01 }
        case .offsetPerTile:
            // Scrolling BG3 walks the offset rows: the wave moves.
            f.setAllLines { $0.bg[2].hofs = UInt16((n / 2 * 8) & 0x3FF); $0.bg[0].hofs = UInt16(n & 0x3FF) }
        case .directColor:
            f.setAllLines { $0.bg[0].vofs = UInt16((0x3FF - 8 + n / 4) & 0x3FF) }
        case .mode7, .extbg:
            let angle = Double(n) / 120
            for line in 0..<f.height {
                var l = f.lines[line]
                if d == .mode7 && line < 48 {
                    l.tm = 0x10   // sky: backdrop only
                } else {
                    let depth = d == .mode7 ? Double(line - 47) : 64
                    let scale = 64 / depth
                    l.m7a = Int16(clamping: Int((cos(angle) * scale * 256).rounded()))
                    l.m7b = Int16(clamping: Int((sin(angle) * scale * 256).rounded()))
                    l.m7c = Int16(clamping: Int((-sin(angle) * scale * 256).rounded()))
                    l.m7d = Int16(clamping: Int((cos(angle) * scale * 256).rounded()))
                }
                // Glide forward by moving the centre: M7VOFS - M7Y stays -112,
                // so the camera height (the depth scale) never changes.
                let cy = (512 - n % 1024 + 1024) % 1024
                l.m7x = 512; l.m7y = Int16(cy)
                l.m7hofs = 512 - 128; l.m7vofs = Int16(cy - 112)
                l.m7sel = 0x00
                f.lines[line] = l
            }
            if d == .mode7 {
                f.writes = []
                for line in 0..<48 { f.writeCGRAM(line: line, index: 0, color: BGR555(r5: 8, g5: UInt8(line / 3), b5: 31).word) }
                f.writeCGRAM(line: 48, index: 0, color: backdrop)
            }
            for i in 0..<16 { f.setOBJ(i, x: (i * 16 + n) % 256, y: 100 + (i % 4) * 20, tile: 1, palette: i % 8, priority: i % 4) }
        case .hires:
            f.setAllLines { $0.bg[0].hofs = UInt16((n / 4) & 0x3FF) }
        case .interlace:
            // Fields alternate every frame, as on a TV.
            f.field = n & 1
        case .pseudoHires:
            f.setAllLines { $0.bg[1].hofs = UInt16(n & 0x3FF) }
        }
    }
}
