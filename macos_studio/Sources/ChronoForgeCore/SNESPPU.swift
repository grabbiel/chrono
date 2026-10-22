// SNESPPU.swift — hardware-shaped SNES PPU state and the CPU reference renderer.
//
// The renderer reads VRAM, CGRAM and OAM the way the PPU does and composes each
// visible line from that line's register set; the per-line table is what HDMA
// writes. It is the ground truth the Metal renderer (ChronoForgeMetal) must
// match pixel for pixel. Every rule, its source (nocash fullsnes, SNESdev Wiki)
// and every choice the documents leave open is listed in docs/ppu.md.
import Foundation

// MARK: - Registers

/// One BG layer's registers.
public struct PPUBGRegisters: Equatable, Sendable {
    /// BGnSC ($2107-$210A): tilemap base in 1K-word steps (bits 7-2) and
    /// screen size (bits 1-0: 32x32, 64x32, 32x64, 64x64 tiles).
    public var sc: UInt8
    /// Character base in 4K-word steps (this BG's nibble of BG12NBA/BG34NBA).
    public var charBase: UInt8
    /// BGnHOFS / BGnVOFS after both writes (10 bits each).
    public var hofs: UInt16
    public var vofs: UInt16

    public init(sc: UInt8 = 0, charBase: UInt8 = 0, hofs: UInt16 = 0, vofs: UInt16 = 0) {
        self.sc = sc; self.charBase = charBase & 15; self.hofs = hofs & 0x3FF; self.vofs = vofs & 0x3FF
    }
}

/// The PPU registers that shape one visible line. Write-twice and partial-write
/// ports are stored as the values they produce (scroll, fixed color).
public struct PPURegisters: Equatable, Sendable {
    /// INIDISP ($2100): forced blank (bit 7), master brightness (bits 3-0).
    public var inidisp: UInt8 = 0x0F
    /// OBSEL ($2101): OBJ sizes (bits 7-5), name-select gap (4-3), base (2-0).
    public var obsel: UInt8 = 0
    /// OBJ priority rotation: the OAM index drawn in front (0 = no rotation).
    /// OAMADD bit 15 set selects OBJ number (OAMADD >> 1) & 127.
    public var objFirst: UInt8 = 0
    /// BGMODE ($2105): tile sizes (bits 7-4), mode 1 BG3 priority (bit 3), mode (2-0).
    public var bgmode: UInt8 = 0x01
    /// BG1...BG4.
    public var bg: [PPUBGRegisters] = Array(repeating: PPUBGRegisters(), count: 4)
    /// TM / TS ($212C/$212D): main and sub screen layer enables (bit 4 OBJ, bits 3-0 BG4-BG1).
    public var tm: UInt8 = 0
    public var ts: UInt8 = 0
    /// CGWSEL ($2130): main black region (7-6), math-prevent region (5-4), sub-screen addend (bit 1).
    public var cgwsel: UInt8 = 0
    /// CGADSUB ($2131): subtract (7), half (6), backdrop/OBJ/BG4-BG1 math enables (5-0).
    public var cgadsub: UInt8 = 0
    /// The fixed color COLDATA ($2132) writes build up (sub-screen backdrop).
    public var fixedColor: BGR555 = BGR555(word: 0)
    /// W12SEL / W34SEL / WOBJSEL ($2123-$2125): per BG1-BG4, OBJ and the color
    /// window, a nibble of window 1 invert/enable (bits 0/1) and window 2 (bits 2/3).
    public var w12sel: UInt8 = 0
    public var w34sel: UInt8 = 0
    public var wobjsel: UInt8 = 0
    /// WH0-WH3 ($2126-$2129): window 1 and window 2 left/right edges, inclusive.
    public var wh0: UInt8 = 0
    public var wh1: UInt8 = 0
    public var wh2: UInt8 = 0
    public var wh3: UInt8 = 0
    /// WBGLOG / WOBJLOG ($212A/$212B): 2-bit window 1/2 logic (OR, AND, XOR,
    /// XNOR) per BG1-BG4, and for OBJ (bits 1-0) and the color window (bits 3-2).
    public var wbglog: UInt8 = 0
    public var wobjlog: UInt8 = 0
    /// TMW / TSW ($212E/$212F): apply the windows to main / sub screen layers.
    public var tmw: UInt8 = 0
    public var tsw: UInt8 = 0

    public init() {}

    public var mode: Int { Int(bgmode & 7) }
    public var bg3High: Bool { bgmode & 0x08 != 0 }
    public var forcedBlank: Bool { inidisp & 0x80 != 0 }
    public var brightness: Int { Int(inidisp & 15) }

    /// COLDATA write: bits 7/6/5 select blue/green/red, bits 4-0 the intensity.
    public mutating func writeCOLDATA(_ value: UInt8) {
        let v = value & 31
        var r = fixedColor.r5, g = fixedColor.g5, b = fixedColor.b5
        if value & 0x20 != 0 { r = v }
        if value & 0x40 != 0 { g = v }
        if value & 0x80 != 0 { b = v }
        fixedColor = BGR555(r5: r, g5: g, b5: b)
    }

    /// BG12NBA ($210B) / BG34NBA ($210C): one character-base nibble per BG.
    public mutating func writeBG12NBA(_ value: UInt8) {
        bg[0].charBase = value & 15; bg[1].charBase = value >> 4
    }
    public mutating func writeBG34NBA(_ value: UInt8) {
        bg[2].charBase = value & 15; bg[3].charBase = value >> 4
    }
}

// MARK: - Frame

/// Video memory plus one register set per visible line.
public struct PPUFrame: Equatable, Sendable {
    public static let width = 256
    public static let vramWords = 0x8000
    public static let oamBytes = 544

    /// 32K words; word addresses wrap at 15 bits.
    public var vram: [UInt16]
    /// 256 BGR555 words.
    public var cgram: [UInt16]
    /// 128 four-byte entries, then the 32-byte high table.
    public var oam: [UInt8]
    /// Registers for each visible line, top to bottom (224 or 239 lines).
    /// Line i is scanline i + 1: scanline 0 is never displayed.
    public var lines: [PPURegisters]

    public var height: Int { lines.count }

    /// Blank memory with every OBJ at Y=240 (below the picture for sizes up
    /// to 16 pixels in both line counts).
    public init(height: Int = 224, registers: PPURegisters = PPURegisters()) {
        precondition(height == 224 || height == 239, "the PPU displays 224 or 239 lines")
        vram = [UInt16](repeating: 0, count: PPUFrame.vramWords)
        cgram = [UInt16](repeating: 0, count: 256)
        oam = [UInt8](repeating: 0, count: PPUFrame.oamBytes)
        for i in 0..<128 { oam[i * 4 + 1] = 240 }
        lines = [PPURegisters](repeating: registers, count: height)
    }

    /// Apply one change to every line's registers.
    public mutating func setAllLines(_ change: (inout PPURegisters) -> Void) {
        for i in lines.indices { change(&lines[i]) }
    }

    /// Store 8x8 tiles (64 row-major palette indices each) in the SNES planar
    /// layout at a VRAM word address: planes 0/1 share one word per row (low
    /// byte plane 0), planes 2/3 follow eight words later.
    public mutating func storeTiles(_ indices: [UInt8], bpp: Int, atWord address: Int) {
        precondition(bpp == 2 || bpp == 4, "BG modes 0/1 and OBJ use 2bpp or 4bpp tiles")
        let wordsPerTile = bpp * 4
        for t in 0..<(indices.count / 64) {
            for row in 0..<8 {
                var p01: UInt16 = 0, p23: UInt16 = 0
                for col in 0..<8 {
                    let c = indices[t * 64 + row * 8 + col]
                    let bit = UInt16(7 - col)
                    p01 |= UInt16(c & 1) << bit | UInt16((c >> 1) & 1) << (bit + 8)
                    p23 |= UInt16((c >> 2) & 1) << bit | UInt16((c >> 3) & 1) << (bit + 8)
                }
                let base = address + t * wordsPerTile + row
                vram[base & 0x7FFF] = p01
                if bpp == 4 { vram[(base + 8) & 0x7FFF] = p23 }
            }
        }
    }

    /// A BG tilemap entry: tile (bits 9-0), palette (12-10), priority (13), flips (14, 15).
    public static func tilemapEntry(tile: Int, palette: Int = 0, priority: Bool = false,
                                    hflip: Bool = false, vflip: Bool = false) -> UInt16 {
        UInt16(tile & 0x3FF) | UInt16(palette & 7) << 10 | (priority ? 0x2000 : 0)
            | (hflip ? 0x4000 : 0) | (vflip ? 0x8000 : 0)
    }

    /// Write one OAM entry (both tables). x is -256...255, y 0...255.
    public mutating func setOBJ(_ index: Int, x: Int, y: Int, tile: Int, palette: Int = 0,
                                priority: Int = 0, hflip: Bool = false, vflip: Bool = false,
                                large: Bool = false) {
        let x9 = x & 0x1FF
        oam[index * 4] = UInt8(x9 & 0xFF)
        oam[index * 4 + 1] = UInt8(y & 0xFF)
        oam[index * 4 + 2] = UInt8(tile & 0xFF)
        oam[index * 4 + 3] = (vflip ? 0x80 : 0) | (hflip ? 0x40 : 0) | UInt8((priority & 3) << 4)
            | UInt8((palette & 7) << 1) | UInt8((tile >> 8) & 1)
        let hi = 512 + index / 4, shift = (index % 4) * 2
        var bits = oam[hi] & ~(3 << shift)
        bits |= UInt8((x9 >> 8) & 1) << shift | (large ? 2 : 0) << shift
        oam[hi] = bits
    }
}

// MARK: - OBJ evaluation

/// One 8-pixel-wide slice of one OBJ on one line, after the per-line limits.
public struct PPUSliver: Equatable, Sendable {
    /// Screen x of the sliver's leftmost pixel (-7...255).
    public var x: Int
    /// VRAM word address of this tile row (planes 0/1; planes 2/3 at +8).
    public var rowAddress: Int
    public var palette: Int
    public var priority: Int
    public var hflip: Bool
    /// Draw order: 0 is in front (OBJ priority rotation applied).
    public var order: Int
}

public struct PPUOBJLine: Equatable, Sendable {
    /// Front to back (ascending order, then x).
    public var slivers: [PPUSliver]
    /// More than 32 OBJs touched the line (STAT77 bit 6).
    public var rangeOver: Bool
    /// More than 34 slivers touched the line (STAT77 bit 7).
    public var timeOver: Bool
}

public enum PPUOBJEvaluator {
    public static let maxOBJsPerLine = 32
    public static let maxSliversPerLine = 34

    /// OBSEL size pairs (small, large) as (width, height); 6 and 7 are the
    /// undocumented rectangular settings fullsnes lists.
    public static let sizes: [(small: (Int, Int), large: (Int, Int))] = [
        ((8, 8), (16, 16)), ((8, 8), (32, 32)), ((8, 8), (64, 64)), ((16, 16), (32, 32)),
        ((16, 16), (64, 64)), ((32, 32), (64, 64)), ((16, 32), (32, 64)), ((16, 32), (32, 32)),
    ]

    /// VRAM word address of OBJ tile `tile` (9 bits): the base in 8K-word
    /// steps; tiles 100h-1FFh start one 4K-word page later plus the gap.
    public static func tileAddress(_ tile: Int, obsel: UInt8) -> Int {
        let base = Int(obsel & 7) << 13
        let gap = tile & 0x100 != 0 ? (Int((obsel >> 3) & 3) + 1) << 12 : 0
        return (base + gap + (tile & 0xFF) << 4) & 0x7FFF
    }

    /// The OBJ slivers drawn on visible line `line` (scanline line + 1).
    public static func evaluate(oam: [UInt8], registers r: PPURegisters, line: Int) -> PPUOBJLine {
        let pair = sizes[Int(r.obsel >> 5)]
        let first = Int(r.objFirst & 127)

        // Range: the first 32 OBJs (in priority order) on this line.
        struct Hit { var index: Int; var order: Int; var x9: Int; var w: Int; var h: Int; var row: Int }
        var hits: [Hit] = []
        var rangeOver = false
        for order in 0..<128 {
            let i = (first + order) & 127
            let hiBits = Int(oam[512 + i / 4] >> ((i % 4) * 2)) & 3
            let (w, h) = hiBits & 2 != 0 ? pair.large : pair.small
            let x9 = Int(oam[i * 4]) | (hiBits & 1) << 8
            let row = (line - Int(oam[i * 4 + 1])) & 0xFF
            guard row < h else { continue }
            let left = x9 >= 256 ? x9 - 512 : x9
            guard (left < 256 && left + w > 0) || x9 == 256 else { continue }
            if hits.count == maxOBJsPerLine { rangeOver = true; break }
            hits.append(Hit(index: i, order: order, x9: x9, w: w, h: h, row: row))
        }

        // Time: slivers counted from the last OBJ back to the first, left to right.
        var slivers: [PPUSliver] = []
        var counted = 0
        var timeOver = false
        evaluation: for hit in hits.reversed() {
            let i = hit.index
            let attr = oam[i * 4 + 3]
            let tile = Int(oam[i * 4 + 2]) | Int(attr & 1) << 8
            let hflip = attr & 0x40 != 0, vflip = attr & 0x80 != 0
            let left = hit.x9 >= 256 ? hit.x9 - 512 : hit.x9
            let y = vflip ? hit.h - 1 - hit.row : hit.row
            let columns = hit.w / 8
            for c in 0..<columns {
                let sx = left + c * 8
                let onScreen = sx > -8 && sx < 256
                guard onScreen || hit.x9 == 256 else { continue }
                if counted == maxSliversPerLine { timeOver = true; break evaluation }
                counted += 1
                guard onScreen else { continue }
                // Tile columns and rows add without carry between nibbles.
                let tc = hflip ? columns - 1 - c : c
                let n = (tile & 0x100) | ((((tile >> 4) + y / 8) & 15) << 4) | ((tile + tc) & 15)
                slivers.append(PPUSliver(x: sx, rowAddress: (tileAddress(n, obsel: r.obsel) + y % 8) & 0x7FFF,
                                         palette: Int((attr >> 1) & 7), priority: Int((attr >> 4) & 3),
                                         hflip: hflip, order: hit.order))
            }
        }
        slivers.sort { ($0.order, $0.x) < ($1.order, $1.x) }
        return PPUOBJLine(slivers: slivers, rangeOver: rangeOver, timeOver: timeOver)
    }
}

// MARK: - Windows

public enum PPUWindows {
    /// Whether the combined window of `area` (0-3 BG1-BG4, 4 OBJ, 5 the color
    /// window) covers x: each enabled window is left <= x <= right (empty when
    /// left > right), optionally inverted; two enabled windows combine with the
    /// area's logic; no enabled window covers nothing.
    public static func covers(_ r: PPURegisters, area: Int, x: Int) -> Bool {
        let sel: UInt8, logic: UInt8
        switch area {
        case 0, 1: sel = r.w12sel >> (area * 4); logic = r.wbglog >> (area * 2)
        case 2, 3: sel = r.w34sel >> ((area - 2) * 4); logic = r.wbglog >> (area * 2)
        default: sel = r.wobjsel >> ((area - 4) * 4); logic = r.wobjlog >> ((area - 4) * 2)
        }
        let enable1 = sel & 2 != 0, enable2 = sel & 8 != 0
        let w1 = (x >= Int(r.wh0) && x <= Int(r.wh1)) != (sel & 1 != 0)
        let w2 = (x >= Int(r.wh2) && x <= Int(r.wh3)) != (sel & 4 != 0)
        switch (enable1, enable2) {
        case (true, true):
            switch logic & 3 {
            case 0: return w1 || w2
            case 1: return w1 && w2
            case 2: return w1 != w2
            default: return w1 == w2
            }
        case (true, false): return w1
        case (false, true): return w2
        default: return false
        }
    }

    /// Bits 0-4 (BG1-BG4, OBJ) of the layers the windows cover at x.
    public static func layerMask(_ r: PPURegisters, x: Int) -> UInt8 {
        var mask: UInt8 = 0
        for area in 0..<5 where covers(r, area: area, x: x) { mask |= 1 << area }
        return mask
    }
}

// MARK: - Layering

/// Which layer a screen pixel came from; the raw values are the CGADSUB bits.
public enum PPULayer: Int, Sendable {
    case bg1 = 0, bg2, bg3, bg4, obj, backdrop
}

public enum PPULayering {
    /// Front-to-back rank (0 = front) of each (layer, priority) for modes 0
    /// and 1, keyed BG1L, BG1H, ... BG4L, BG4H, OBJ0...OBJ3. 255 = not shown.
    public static let mode0: [UInt8] = [4, 1, 5, 2, 10, 7, 11, 8, 9, 6, 3, 0]
    public static let mode1: [UInt8] = [4, 1, 5, 2, 9, 7, 255, 255, 8, 6, 3, 0]
    public static let mode1BG3High: [UInt8] = [5, 2, 6, 3, 9, 0, 255, 255, 8, 7, 4, 1]

    /// The rank table for a line, or nil for modes the renderer does not draw BGs in.
    public static func ranks(_ r: PPURegisters) -> [UInt8] {
        switch r.mode {
        case 0: return mode0
        case 1: return r.bg3High ? mode1BG3High : mode1
        default: return [255, 255, 255, 255, 255, 255, 255, 255, 8, 6, 3, 0]
        }
    }

    /// Bits per pixel of a BG in a mode, or 0 when the BG is not displayed.
    public static func bpp(mode: Int, bg: Int) -> Int {
        switch mode {
        case 0: return 2
        case 1: return bg < 2 ? 4 : (bg == 2 ? 2 : 0)
        default: return 0
        }
    }
}

// MARK: - Reference renderer

public enum PPUReferenceRenderer {
    struct Pixel {
        var color: UInt16
        var layer: PPULayer
        var objPalette: Int
    }

    /// A BG pixel: CGRAM index and tilemap priority bit, or nil when transparent.
    static func bgPixel(_ f: PPUFrame, _ r: PPURegisters, bg n: Int, x: Int, line: Int) -> (index: Int, priority: Int)? {
        let bpp = PPULayering.bpp(mode: r.mode, bg: n)
        guard bpp != 0 else { return nil }
        let regs = r.bg[n]
        let size = (r.bgmode >> (4 + n)) & 1 != 0 ? 16 : 8
        let sx = (x + Int(regs.hofs)) & 0x3FF
        let sy = (line + 1 + Int(regs.vofs)) & 0x3FF
        let tx = (sx / size) & 63, ty = (sy / size) & 63
        var address = Int(regs.sc & 0xFC) << 8 + (ty & 31) * 32 + (tx & 31)
        let screens = regs.sc & 3
        if tx & 32 != 0 && screens & 1 != 0 { address += 0x400 }
        if ty & 32 != 0 && screens >= 2 { address += screens == 3 ? 0x800 : 0x400 }
        let entry = Int(f.vram[address & 0x7FFF])
        var px = sx % size, py = sy % size
        if entry & 0x4000 != 0 { px = size - 1 - px }
        if entry & 0x8000 != 0 { py = size - 1 - py }
        // 16x16 tiles: N, N+1, N+16, N+17 with carry, within 10 bits.
        let tile = (entry + (px >= 8 ? 1 : 0) + (py >= 8 ? 16 : 0)) & 0x3FF
        let rowAddress = Int(regs.charBase) << 12 + tile * bpp * 4 + (py & 7)
        let index = planarPixel(f.vram, rowAddress: rowAddress, bpp: bpp, bit: 7 - (px & 7))
        guard index != 0 else { return nil }
        let palette = (entry >> 10) & 7
        let base = r.mode == 0 ? n * 32 : 0
        return (base + palette * (1 << bpp) + index, (entry >> 13) & 1)
    }

    static func planarPixel(_ vram: [UInt16], rowAddress: Int, bpp: Int, bit: Int) -> Int {
        let p01 = Int(vram[rowAddress & 0x7FFF])
        var c = (p01 >> bit) & 1 | ((p01 >> (bit + 8)) & 1) << 1
        if bpp == 4 {
            let p23 = Int(vram[(rowAddress + 8) & 0x7FFF])
            c |= ((p23 >> bit) & 1) << 2 | ((p23 >> (bit + 8)) & 1) << 3
        }
        return c
    }

    /// The front OBJ pixel at x: (CGRAM index, priority, palette), or nil.
    static func objPixel(_ f: PPUFrame, _ objs: PPUOBJLine, x: Int) -> (index: Int, priority: Int, palette: Int)? {
        for s in objs.slivers where x >= s.x && x < s.x + 8 {
            let px = x - s.x
            let c = planarPixel(f.vram, rowAddress: s.rowAddress, bpp: 4, bit: s.hflip ? px : 7 - px)
            if c != 0 { return (128 + s.palette * 16 + c, s.priority, s.palette) }
        }
        return nil
    }

    /// The front pixel of the layers enabled in `mask` (TM or TS), or nil for backdrop.
    static func front(_ f: PPUFrame, _ r: PPURegisters, ranks: [UInt8], mask: UInt8,
                      bgs: [(index: Int, priority: Int)?], obj: (index: Int, priority: Int, palette: Int)?) -> Pixel? {
        var best: Pixel?
        var bestRank = 255
        for n in 0..<4 where mask & (1 << n) != 0 {
            guard let p = bgs[n] else { continue }
            let rank = Int(ranks[n * 2 + p.priority])
            if rank < bestRank {
                bestRank = rank
                best = Pixel(color: f.cgram[p.index] & 0x7FFF, layer: PPULayer(rawValue: n)!, objPalette: 0)
            }
        }
        if mask & 0x10 != 0, let o = obj, Int(ranks[8 + o.priority]) < bestRank {
            best = Pixel(color: f.cgram[o.index] & 0x7FFF, layer: .obj, objPalette: o.palette)
        }
        return best
    }

    /// Whether a CGWSEL region (0 nowhere, 1 outside, 2 inside, 3 everywhere
    /// the color window) covers a pixel.
    static func inRegion(_ region: UInt8, insideColorWindow: Bool) -> Bool {
        switch region & 3 {
        case 0: return false
        case 1: return !insideColorWindow
        case 2: return insideColorWindow
        default: return true
        }
    }

    /// Main/sub composition and color math for one pixel; returns BGR555.
    static func compose(main: Pixel, sub: Pixel?, _ r: PPURegisters, colorWindow: Bool) -> UInt16 {
        let forceBlack = inRegion(r.cgwsel >> 6, insideColorWindow: colorWindow)
        let mainColor = forceBlack ? 0 : main.color
        let layerMath = r.cgadsub & (1 << main.layer.rawValue) != 0
            && (main.layer != .obj || main.objPalette >= 4)
        guard layerMath, !inRegion(r.cgwsel >> 4, insideColorWindow: colorWindow) else { return mainColor }
        let addend: UInt16
        var halve = r.cgadsub & 0x40 != 0 && !forceBlack
        if r.cgwsel & 0x02 != 0 {
            if let s = sub { addend = s.color } else { addend = r.fixedColor.word; halve = false }
        } else {
            addend = r.fixedColor.word
        }
        let subtract = r.cgadsub & 0x80 != 0
        var out: UInt16 = 0
        for shift in [0, 5, 10] as [UInt16] {
            let m = Int((mainColor >> shift) & 31), s = Int((addend >> shift) & 31)
            var v = subtract ? m - s : m + s
            if halve { v >>= 1 }
            out |= UInt16(min(31, max(0, v))) << shift
        }
        return out
    }

    /// 5-bit channel to 8 bits: (c << 3) | (c >> 2), then master brightness
    /// c8 * (b + 1) / 16 (b = 0 is black, 15 is full).
    public static func output8(_ c5: Int, brightness: Int) -> UInt8 {
        guard brightness > 0 else { return 0 }
        let c8 = (c5 << 3) | (c5 >> 2)
        return UInt8(c8 * (brightness + 1) / 16)
    }

    /// Render the frame: 256 x height RGBA8 pixels, row-major, alpha 255.
    public static func render(_ f: PPUFrame) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: PPUFrame.width * f.height * 4)
        for line in 0..<f.height {
            let r = f.lines[line]
            let row = line * PPUFrame.width * 4
            for x in 0..<PPUFrame.width { out[row + x * 4 + 3] = 255 }
            guard !r.forcedBlank else { continue }
            let ranks = PPULayering.ranks(r)
            let objs = PPUOBJEvaluator.evaluate(oam: f.oam, registers: r, line: line)
            for x in 0..<PPUFrame.width {
                let bgs = (0..<4).map { bgPixel(f, r, bg: $0, x: x, line: line) }
                let obj = objPixel(f, objs, x: x)
                let windows = PPUWindows.layerMask(r, x: x)
                let main = front(f, r, ranks: ranks, mask: r.tm & ~(r.tmw & windows), bgs: bgs, obj: obj)
                    ?? Pixel(color: f.cgram[0] & 0x7FFF, layer: .backdrop, objPalette: 0)
                let sub = front(f, r, ranks: ranks, mask: r.ts & ~(r.tsw & windows), bgs: bgs, obj: obj)
                let c = compose(main: main, sub: sub, r, colorWindow: PPUWindows.covers(r, area: 5, x: x))
                let o = row + x * 4
                out[o] = output8(Int(c & 31), brightness: r.brightness)
                out[o + 1] = output8(Int((c >> 5) & 31), brightness: r.brightness)
                out[o + 2] = output8(Int((c >> 10) & 31), brightness: r.brightness)
            }
        }
        return out
    }
}
