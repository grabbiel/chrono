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
    /// MOSAIC ($2106): block size minus 1 (bits 7-4), BG4-BG1 enables (bits 3-0).
    public var mosaic: UInt8 = 0
    /// M7SEL ($211A): screen over (bits 7-6), V flip (bit 1), H flip (bit 0).
    public var m7sel: UInt8 = 0
    /// M7A-M7D ($211B-$211E): the matrix, signed 8.8 fixed point. The default
    /// is the identity the Wiki's init code recommends.
    public var m7a: Int16 = 0x0100
    public var m7b: Int16 = 0
    public var m7c: Int16 = 0
    public var m7d: Int16 = 0x0100
    /// M7X / M7Y ($211F/$2120) and M7HOFS / M7VOFS ($210D/$210E, separate from
    /// BG1HOFS/VOFS): 13-bit signed; the renderers use the low 13 bits.
    public var m7x: Int16 = 0
    public var m7y: Int16 = 0
    public var m7hofs: Int16 = 0
    public var m7vofs: Int16 = 0
    /// SETINI ($2133): EXTBG (bit 6), pseudo 512 (bit 3), overscan (bit 2),
    /// OBJ interlace (bit 1), screen interlace (bit 0). The line count comes
    /// from `PPUFrame.height`, not from bit 2.
    public var setini: UInt8 = 0

    public init() {}

    public var mode: Int { Int(bgmode & 7) }
    public var bg3High: Bool { bgmode & 0x08 != 0 }
    public var forcedBlank: Bool { inidisp & 0x80 != 0 }
    public var brightness: Int { Int(inidisp & 15) }
    /// MOSAIC block size in pixels (1-16).
    public var mosaicSize: Int { Int(mosaic >> 4) + 1 }
    /// The line has 512 half-pixel columns: modes 5/6, or SETINI pseudo 512.
    public var highResolution: Bool { mode == 5 || mode == 6 || setini & 0x08 != 0 }
    public var extbg: Bool { setini & 0x40 != 0 }
    public var interlace: Bool { setini & 0x01 != 0 }
    public var objInterlace: Bool { setini & 0x02 != 0 }
    /// CGWSEL bit 0: 256-color BGs use direct color instead of CGRAM.
    public var directColor: Bool { cgwsel & 0x01 != 0 }

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
    /// Mid-frame memory writes: each takes effect before its line is drawn
    /// and stays for the rest of the frame (HDMA CGRAM gradients, palette
    /// effects, writes during forced-blank lines). Empty by default.
    public var writes: [PPUMemoryWrite] = []
    /// The interlace field drawn (0 even, 1 odd): with SETINI interlace it
    /// picks the half-lines of modes 5/6 BGs, and of OBJs with OBJ interlace.
    public var field: Int = 0

    public var height: Int { lines.count }
    /// The memory in effect before any mid-frame write.
    public var memory: PPUMemory { PPUMemory(vram: vram, cgram: cgram, oam: oam) }
    /// Whether any line has 512 half-pixel columns.
    public var hasHighResolution: Bool { lines.contains { $0.highResolution && !$0.forcedBlank } }

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
    /// 8bpp tiles (modes 3/4) add planes 4/5 and 6/7 at +16 and +24 words.
    public mutating func storeTiles(_ indices: [UInt8], bpp: Int, atWord address: Int) {
        precondition(bpp == 2 || bpp == 4 || bpp == 8, "BG tiles are 2bpp, 4bpp or 8bpp")
        let wordsPerTile = bpp * 4
        for t in 0..<(indices.count / 64) {
            for row in 0..<8 {
                for pair in 0..<(bpp / 2) {
                    var word: UInt16 = 0
                    for col in 0..<8 {
                        let c = indices[t * 64 + row * 8 + col] >> UInt8(pair * 2)
                        let bit = UInt16(7 - col)
                        word |= UInt16(c & 1) << bit
                        word |= UInt16((c >> 1) & 1) << (bit + 8)
                    }
                    vram[(address + t * wordsPerTile + pair * 8 + row) & 0x7FFF] = word
                }
            }
        }
    }

    /// Mode 7 characters: 8x8 tiles of 64 row-major 8-bit pixels in the high
    /// bytes of VRAM words tile * 64 ... tile * 64 + 63. Low bytes are kept.
    public mutating func storeMode7Tiles(_ indices: [UInt8], firstTile: Int = 0) {
        for i in 0..<min(indices.count, (256 - firstTile) * 64) {
            let a = firstTile * 64 + i
            vram[a] = (vram[a] & 0x00FF) | UInt16(indices[i]) << 8
        }
    }

    /// One mode 7 tilemap entry (128x128 tiles in the low bytes of words 0-3FFFh).
    public mutating func setMode7Tile(x: Int, y: Int, tile: Int) {
        let a = (y & 127) * 128 + (x & 127)
        vram[a] = (vram[a] & 0xFF00) | UInt16(tile & 0xFF)
    }

    /// Queue mid-frame writes, effective from visible line `line`.
    public mutating func writeCGRAM(line: Int, index: Int, color: UInt16) {
        writes.append(PPUMemoryWrite(line: line, target: .cgram, address: index, value: color))
    }
    public mutating func writeVRAM(line: Int, address: Int, word: UInt16) {
        writes.append(PPUMemoryWrite(line: line, target: .vram, address: address, value: word))
    }
    public mutating func writeOAM(line: Int, address: Int, byte: UInt8) {
        writes.append(PPUMemoryWrite(line: line, target: .oam, address: address, value: UInt16(byte)))
    }

    /// The memory each visible line is drawn from: the frame's memory with
    /// every write whose line is at or before it applied, in line order and
    /// then queue order. Lines share storage until a write changes it.
    public func memoryByLine() -> [PPUMemory] {
        let pending = writes.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }
        var current = memory
        var next = 0
        var out: [PPUMemory] = []
        out.reserveCapacity(height)
        for line in 0..<height {
            while next < pending.count && pending[next].element.line <= line {
                current.apply(pending[next].element)
                next += 1
            }
            out.append(current)
        }
        return out
    }

    /// The first line each target's memory differs from the line before
    /// (line 0 when a write applies before the first line).
    public func linesChanging(_ target: PPUMemoryWrite.Target) -> Set<Int> {
        var out = Set<Int>()
        for w in writes where w.target == target && w.line < height { out.insert(max(0, w.line)) }
        return out
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

// MARK: - Memory

/// VRAM, CGRAM and OAM as one line sees them.
public struct PPUMemory: Equatable, Sendable {
    public var vram: [UInt16]
    public var cgram: [UInt16]
    public var oam: [UInt8]

    public init(vram: [UInt16], cgram: [UInt16], oam: [UInt8]) {
        self.vram = vram; self.cgram = cgram; self.oam = oam
    }

    public mutating func apply(_ w: PPUMemoryWrite) {
        switch w.target {
        case .vram: vram[w.address & 0x7FFF] = w.value
        case .cgram: cgram[w.address & 0xFF] = w.value
        case .oam: oam[((w.address % PPUFrame.oamBytes) + PPUFrame.oamBytes) % PPUFrame.oamBytes] = UInt8(w.value & 0xFF)
        }
    }
}

/// One mid-frame write: a VRAM word (15-bit word address), a CGRAM word
/// (8-bit index) or an OAM byte (0-543).
public struct PPUMemoryWrite: Equatable, Sendable {
    public enum Target: Int, Sendable { case vram, cgram, oam }
    /// The visible line it takes effect before (0 or less: before line 0).
    public var line: Int
    public var target: Target
    public var address: Int
    public var value: UInt16

    public init(line: Int, target: Target, address: Int, value: UInt16) {
        self.line = line; self.target = target; self.address = address; self.value = value
    }
}

// MARK: - Mosaic

public enum PPUMosaic {
    /// Each line's row within its vertical mosaic block. The first block
    /// starts on the top line; a size change applies once the current block
    /// (of the old size) is finished (fullsnes MOSAIC). The counter runs
    /// whether or not any BG has mosaic enabled.
    public static func verticalIndices(_ lines: [PPURegisters]) -> [Int] {
        var out = [Int](repeating: 0, count: lines.count)
        guard let first = lines.first else { return out }
        var index = 0
        var size = first.mosaicSize
        for i in stride(from: 1, to: lines.count, by: 1) {
            index += 1
            if index >= size { index = 0; size = lines[i].mosaicSize }
            out[i] = index
        }
        return out
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
    /// With SETINI OBJ interlace, OBJ rows advance two per line, starting at
    /// `field`, so OBJs appear half as tall.
    public static func evaluate(oam: [UInt8], registers r: PPURegisters, line: Int, field: Int = 0) -> PPUOBJLine {
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
            var row = (line - Int(oam[i * 4 + 1])) & 0xFF
            if r.objInterlace { row = row * 2 + (field & 1) }
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
    /// Front-to-back rank (0 = front) of each (layer, priority), keyed BG1L,
    /// BG1H, ... BG4L, BG4H, OBJ0...OBJ3, from the fullsnes "Background
    /// Priority Chart". 255 = not shown.
    public static let mode0: [UInt8] = [4, 1, 5, 2, 10, 7, 11, 8, 9, 6, 3, 0]
    public static let mode1: [UInt8] = [4, 1, 5, 2, 9, 7, 255, 255, 8, 6, 3, 0]
    public static let mode1BG3High: [UInt8] = [5, 2, 6, 3, 9, 0, 255, 255, 8, 7, 4, 1]
    /// Modes 2-5: S3 1H S2 2H S1 1L S0 2L.
    public static let mode2to5: [UInt8] = [5, 1, 7, 3, 255, 255, 255, 255, 6, 4, 2, 0]
    /// Mode 6: S3 1H S2 S1 1L S0.
    public static let mode6: [UInt8] = [4, 1, 255, 255, 255, 255, 255, 255, 5, 3, 2, 0]
    /// Mode 7: S3 S2 2H S1 1 S0 2L (BG1 has no priority bit; BG2 is EXTBG).
    public static let mode7: [UInt8] = [4, 4, 6, 2, 255, 255, 255, 255, 5, 3, 1, 0]

    /// The rank table for a line.
    public static func ranks(_ r: PPURegisters) -> [UInt8] {
        switch r.mode {
        case 0: return mode0
        case 1: return r.bg3High ? mode1BG3High : mode1
        case 6: return mode6
        case 7: return mode7
        default: return mode2to5
        }
    }

    /// Bits per pixel of a BG in a mode, or 0 when the BG is not displayed
    /// (BG3 in modes 2, 4 and 6 holds offset-per-tile data). Mode 7 BG1 is
    /// 8bpp; its EXTBG BG2 is drawn from the same pixels.
    public static func bpp(mode: Int, bg: Int) -> Int {
        let table: [[Int]] = [[2, 2, 2, 2], [4, 4, 2, 0], [4, 4, 0, 0], [8, 4, 0, 0],
                              [8, 2, 0, 0], [4, 2, 0, 0], [4, 0, 0, 0], [8, 0, 0, 0]]
        return table[mode & 7][bg & 3]
    }
}

// MARK: - Output image

/// A rendered picture: width x height RGBA8 pixels, row-major, alpha 255.
public struct PPUImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var rgba: [UInt8]

    public init(width: Int, height: Int, rgba: [UInt8]) {
        self.width = width; self.height = height; self.rgba = rgba
    }

    /// Two interlace fields woven into one picture of twice the height: the
    /// even field's lines on even rows, the odd field's (half a line lower)
    /// on odd rows.
    public static func weave(even: PPUImage, odd: PPUImage) -> PPUImage {
        precondition(even.width == odd.width && even.height == odd.height, "fields must match")
        let rowBytes = even.width * 4
        var out = [UInt8](repeating: 0, count: rowBytes * even.height * 2)
        for y in 0..<even.height {
            let src = y * rowBytes
            out.replaceSubrange(2 * y * rowBytes..<(2 * y + 1) * rowBytes, with: even.rgba[src..<src + rowBytes])
            out.replaceSubrange((2 * y + 1) * rowBytes..<(2 * y + 2) * rowBytes, with: odd.rgba[src..<src + rowBytes])
        }
        return PPUImage(width: even.width, height: even.height * 2, rgba: out)
    }
}

public struct PPURenderOptions: Equatable, Sendable {
    /// Draw 512 half-pixel columns when any line is hi-res (sub screen on
    /// even columns, main screen on odd ones; other lines repeat each pixel).
    /// Off, or with no hi-res line, the picture is 256 wide and hi-res lines
    /// show their main-screen columns.
    public var highResolution: Bool
    /// Place the picture in the 239-line display area: the border outside
    /// the picture is black, and a 224-line picture starts 8 lines down.
    public var overscanBorder: Bool

    public init(highResolution: Bool = true, overscanBorder: Bool = false) {
        self.highResolution = highResolution; self.overscanBorder = overscanBorder
    }

    /// Display lines, and the first line of the picture within them.
    public static let displayLines = 239
    public static let borderTop224 = 8

    public func layout(_ f: PPUFrame) -> (width: Int, height: Int, top: Int) {
        let width = highResolution && f.hasHighResolution ? 512 : 256
        guard overscanBorder else { return (width, f.height, 0) }
        return (width, PPURenderOptions.displayLines, f.height == 224 ? PPURenderOptions.borderTop224 : 0)
    }
}

// MARK: - Reference renderer

public enum PPUReferenceRenderer {
    struct Pixel {
        var color: UInt16
        var layer: PPULayer
        var objPalette: Int
    }

    /// A BG half-pixel: its BGR555 color and tilemap (or EXTBG) priority bit.
    struct BGPixel {
        var color: UInt16
        var priority: Int
    }

    /// What a line takes from the frame besides its registers.
    struct LineContext {
        var memory: PPUMemory
        var line: Int
        var mosaicY: Int
        var field: Int
    }

    /// Direct color (fullsnes "Direct Color Mode"): an 8-bit BBGGGRRR pixel
    /// plus the tile's bgr palette bits give BBb00 GGGg0 RRRr0.
    public static func directColor(_ c: Int, palette p: Int) -> UInt16 {
        let r = (c & 7) << 2 | (p & 1) << 1
        let g = ((c >> 3) & 7) << 2 | ((p >> 1) & 1) << 1
        let b = ((c >> 6) & 3) << 3 | ((p >> 2) & 1) << 2
        return UInt16(r | g << 5 | b << 10)
    }

    /// Word address of tilemap entry (tx, ty), both 0-63, under a BGnSC value.
    static func tilemapAddress(sc: UInt8, tx: Int, ty: Int) -> Int {
        var address = Int(sc & 0xFC) << 8 + (ty & 31) * 32 + (tx & 31)
        let screens = sc & 3
        if tx & 32 != 0 && screens & 1 != 0 { address += 0x400 }
        if ty & 32 != 0 && screens >= 2 { address += screens == 3 ? 0x800 : 0x400 }
        return address & 0x7FFF
    }

    /// Offset-per-tile (modes 2, 4, 6; Wiki *Offset-per-tile*): the scroll
    /// BG n uses at screen x. Column 0 keeps the BG's own scroll; column c
    /// reads BG3's tilemap entry (c - 1) to the right of BG3HOFS's tile, in
    /// the row at BG3VOFS (HOFS entries) and 8 lines below (VOFS entries;
    /// mode 4 has one row whose bit 15 picks the direction). Bit 13 applies
    /// an entry to BG1, bit 14 to BG2. HOFS keeps its low 3 bits.
    static func offsetPerTile(_ vram: [UInt16], _ r: PPURegisters, bg n: Int, x: Int,
                              hofs: Int, vofs: Int) -> (hofs: Int, vofs: Int) {
        let column = (x + (hofs & 7)) >> 3
        guard column > 0 else { return (hofs, vofs) }
        let bg3 = r.bg[2]
        let big3 = r.bgmode & 0x40 != 0
        let width3 = big3 && r.mode != 6 ? 16 : 8, height3 = big3 ? 16 : 8
        let x3 = (column - 1) * 8 + (Int(bg3.hofs) & ~7)
        let tx = (x3 / width3) & 63
        func entry(_ y3: Int) -> Int {
            let ty = ((y3 & 0x3FF) / height3) & 63
            return Int(vram[tilemapAddress(sc: bg3.sc, tx: tx, ty: ty)])
        }
        let y3 = Int(bg3.vofs) & ~7
        let applies = n == 0 ? 0x2000 : 0x4000
        var out = (hofs: hofs, vofs: vofs)
        let first = entry(y3)
        if r.mode == 4 {
            guard first & applies != 0 else { return out }
            if first & 0x8000 != 0 { out.vofs = first & 0x3FF } else { out.hofs = (first & 0x3F8) | (hofs & 7) }
            return out
        }
        if first & applies != 0 { out.hofs = (first & 0x3F8) | (hofs & 7) }
        let second = entry(y3 + 8)
        if second & applies != 0 { out.vofs = second & 0x3FF }
        return out
    }

    /// A BG half-pixel at screen x (half 0 even, 1 odd; only modes 5/6 draw
    /// BGs at 512 columns), or nil when transparent.
    static func bgPixel(_ c: LineContext, _ r: PPURegisters, bg n: Int, x: Int, half: Int) -> BGPixel? {
        if r.mode == 7 { return mode7Pixel(c, r, bg: n, x: x) }
        let bpp = PPULayering.bpp(mode: r.mode, bg: n)
        guard bpp != 0 else { return nil }
        let regs = r.bg[n]
        let hires = r.mode == 5 || r.mode == 6
        // Mosaic: each block shows its top-left pixel (in full pixels, so the
        // even half in hi-res), counted from the screen's left edge.
        let mosaicOn = r.mosaic & (1 << n) != 0
        let mx = mosaicOn ? x - x % r.mosaicSize : x
        let mhalf = mosaicOn ? 0 : half
        let mosaicY = mosaicOn ? c.mosaicY : 0
        var hofs = Int(regs.hofs), vofs = Int(regs.vofs)
        if (r.mode == 2 || r.mode == 4 || r.mode == 6) && n < 2 {
            (hofs, vofs) = offsetPerTile(c.memory.vram, r, bg: n, x: mx, hofs: hofs, vofs: vofs)
        }
        let tileHeight = (r.bgmode >> (4 + n)) & 1 != 0 ? 16 : 8
        let tileWidth = hires ? 16 : tileHeight
        let sx = hires ? (mx * 2 + mhalf + hofs * 2) & 0x7FF : (mx + hofs) & 0x3FF
        let sy: Int
        if hires && r.interlace {
            // Interlaced modes 5/6: rows are half-lines, the field picks one.
            let field = mosaicOn ? 0 : c.field & 1
            sy = ((c.line + 1 - mosaicY) * 2 + field + vofs) & 0x3FF
        } else {
            sy = (c.line + 1 - mosaicY + vofs) & 0x3FF
        }
        let tx = (sx / tileWidth) & 63, ty = (sy / tileHeight) & 63
        let entry = Int(c.memory.vram[tilemapAddress(sc: regs.sc, tx: tx, ty: ty)])
        var px = sx % tileWidth, py = sy % tileHeight
        if entry & 0x4000 != 0 { px = tileWidth - 1 - px }
        if entry & 0x8000 != 0 { py = tileHeight - 1 - py }
        // 16-pixel tiles: N, N+1, N+16, N+17 with carry, within 10 bits.
        let tile = (entry + (px >= 8 ? 1 : 0) + (py >= 8 ? 16 : 0)) & 0x3FF
        let rowAddress = Int(regs.charBase) << 12 + tile * bpp * 4 + (py & 7)
        let index = planarPixel(c.memory.vram, rowAddress: rowAddress, bpp: bpp, bit: 7 - (px & 7))
        guard index != 0 else { return nil }
        let palette = (entry >> 10) & 7
        let priority = (entry >> 13) & 1
        if bpp == 8 {
            let color = r.directColor ? directColor(index, palette: palette) : c.memory.cgram[index]
            return BGPixel(color: color & 0x7FFF, priority: priority)
        }
        let base = r.mode == 0 ? n * 32 : 0
        return BGPixel(color: c.memory.cgram[base + palette * (1 << bpp) + index] & 0x7FFF, priority: priority)
    }

    /// fullsnes "Rotation/Scaling": ORG wraps to 10-bit signed.
    static func mode7Origin(_ d: Int) -> Int {
        var o = d & ~0x1C00
        if d < 0 { o |= 0x1C00 }
        return o
    }

    static func signExtend13(_ v: Int16) -> Int { ((Int(v) & 0x1FFF) ^ 0x1000) - 0x1000 }

    /// Mode 7 BG1, or EXTBG BG2 (the same pixel: color bits 6-0, priority
    /// bit 7, never direct color), at screen x.
    static func mode7Pixel(_ c: LineContext, _ r: PPURegisters, bg n: Int, x: Int) -> BGPixel? {
        guard n == 0 || (n == 1 && r.extbg) else { return nil }
        let mosaicOn = r.mosaic & (1 << n) != 0
        var sx = mosaicOn ? x - x % r.mosaicSize : x
        var sy = c.line + 1 - (mosaicOn ? c.mosaicY : 0)
        if r.m7sel & 1 != 0 { sx ^= 0xFF }
        if r.m7sel & 2 != 0 { sy ^= 0xFF }
        let a = Int(r.m7a), b = Int(r.m7b), cc = Int(r.m7c), d = Int(r.m7d)
        let cx = signExtend13(r.m7x), cy = signExtend13(r.m7y)
        let ox = mode7Origin(signExtend13(r.m7hofs) - cx)
        let oy = mode7Origin(signExtend13(r.m7vofs) - cy)
        var vx = ((a * ox) & ~63) + ((b * oy) & ~63) + cx * 256
        var vy = ((cc * ox) & ~63) + ((d * oy) & ~63) + cy * 256
        vx += ((b * sy) & ~63) + a * sx
        vy += ((d * sy) & ~63) + cc * sx
        let ix = vx >> 8, iy = vy >> 8
        let outside = ix & ~0x3FF != 0 || iy & ~0x3FF != 0
        let over = r.m7sel >> 6
        if outside && over == 2 { return nil }
        var tile = 0
        if !(outside && over == 3) {
            tile = Int(c.memory.vram[((iy & 0x3FF) >> 3) * 128 + ((ix & 0x3FF) >> 3)] & 0xFF)
        }
        let pixel = Int(c.memory.vram[tile * 64 + (iy & 7) * 8 + (ix & 7)] >> 8)
        if n == 1 {
            guard pixel & 0x7F != 0 else { return nil }
            return BGPixel(color: c.memory.cgram[pixel & 0x7F] & 0x7FFF, priority: pixel >> 7)
        }
        guard pixel != 0 else { return nil }
        let color = r.directColor ? directColor(pixel, palette: 0) : c.memory.cgram[pixel]
        return BGPixel(color: color & 0x7FFF, priority: 0)
    }

    static func planarPixel(_ vram: [UInt16], rowAddress: Int, bpp: Int, bit: Int) -> Int {
        var c = 0
        for pair in 0..<(bpp / 2) {
            let word = Int(vram[(rowAddress + pair * 8) & 0x7FFF])
            c |= ((word >> bit) & 1) << (pair * 2)
            c |= ((word >> (bit + 8)) & 1) << (pair * 2 + 1)
        }
        return c
    }

    /// The front OBJ pixel at x: (CGRAM index, priority, palette), or nil.
    static func objPixel(_ vram: [UInt16], _ objs: PPUOBJLine, x: Int) -> (index: Int, priority: Int, palette: Int)? {
        for s in objs.slivers where x >= s.x && x < s.x + 8 {
            let px = x - s.x
            let c = planarPixel(vram, rowAddress: s.rowAddress, bpp: 4, bit: s.hflip ? px : 7 - px)
            if c != 0 { return (128 + s.palette * 16 + c, s.priority, s.palette) }
        }
        return nil
    }

    /// The front pixel of the layers enabled in `mask` (TM or TS), or nil for backdrop.
    static func front(_ cgram: [UInt16], ranks: [UInt8], mask: UInt8,
                      bgs: [BGPixel?], obj: (index: Int, priority: Int, palette: Int)?) -> Pixel? {
        var best: Pixel?
        var bestRank = 255
        for n in 0..<4 where mask & (1 << n) != 0 {
            guard let p = bgs[n] else { continue }
            let rank = Int(ranks[n * 2 + p.priority])
            if rank < bestRank {
                bestRank = rank
                best = Pixel(color: p.color, layer: PPULayer(rawValue: n)!, objPalette: 0)
            }
        }
        if mask & 0x10 != 0, let o = obj, Int(ranks[8 + o.priority]) < bestRank {
            best = Pixel(color: cgram[o.index] & 0x7FFF, layer: .obj, objPalette: o.palette)
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

    /// One line's BGR555 columns: 256 main-screen pixels, or 512 half-pixels
    /// (sub screen on even columns on hi-res lines). nil when forced blank.
    static func renderLine(_ c: LineContext, _ r: PPURegisters, columns: Int) -> [UInt16]? {
        guard !r.forcedBlank else { return nil }
        let ranks = PPULayering.ranks(r)
        let objs = PPUOBJEvaluator.evaluate(oam: c.memory.oam, registers: r, line: c.line, field: c.field)
        let hires = r.highResolution
        let backdrop = c.memory.cgram[0] & 0x7FFF
        var out = [UInt16](repeating: 0, count: columns)
        for x in 0..<PPUFrame.width {
            // Half 0 feeds the sub screen, half 1 the main screen; they differ
            // only where modes 5/6 draw BGs at 512 columns.
            var subBGs: [BGPixel?] = []
            var mainBGs: [BGPixel?] = []
            for n in 0..<4 {
                let even = bgPixel(c, r, bg: n, x: x, half: 0)
                subBGs.append(even)
                mainBGs.append(r.mode == 5 || r.mode == 6 ? bgPixel(c, r, bg: n, x: x, half: 1) : even)
            }
            let obj = objPixel(c.memory.vram, objs, x: x)
            let windows = PPUWindows.layerMask(r, x: x)
            let main = front(c.memory.cgram, ranks: ranks, mask: r.tm & ~(r.tmw & windows), bgs: mainBGs, obj: obj)
                ?? Pixel(color: backdrop, layer: .backdrop, objPalette: 0)
            let sub = front(c.memory.cgram, ranks: ranks, mask: r.ts & ~(r.tsw & windows), bgs: subBGs, obj: obj)
            let composed = compose(main: main, sub: sub, r, colorWindow: PPUWindows.covers(r, area: 5, x: x))
            if columns == 512 {
                // The sub-screen column shows its pixel, or CGRAM 0 (fullsnes Hires Notes).
                out[x * 2] = hires ? (sub?.color ?? backdrop) : composed
                out[x * 2 + 1] = composed
            } else {
                out[x] = composed
            }
        }
        return out
    }

    /// Render the frame: 256 x height RGBA8 pixels, row-major, alpha 255.
    /// Hi-res lines show their main-screen columns.
    public static func render(_ f: PPUFrame) -> [UInt8] {
        renderImage(f, options: PPURenderOptions(highResolution: false)).rgba
    }

    /// Render the frame at its full width (512 with hi-res lines), optionally
    /// within the black overscan border.
    public static func renderImage(_ f: PPUFrame, options: PPURenderOptions = PPURenderOptions()) -> PPUImage {
        let (width, height, top) = options.layout(f)
        var out = [UInt8](repeating: 0, count: width * height * 4)
        for i in 0..<(width * height) { out[i * 4 + 3] = 255 }
        let memory = f.memoryByLine()
        let mosaic = PPUMosaic.verticalIndices(f.lines)
        for line in 0..<f.height {
            let r = f.lines[line]
            let c = LineContext(memory: memory[line], line: line, mosaicY: mosaic[line], field: f.field)
            guard let colors = renderLine(c, r, columns: width) else { continue }
            let row = (top + line) * width * 4
            for x in 0..<width {
                let color = Int(colors[x]), o = row + x * 4
                out[o] = output8(color & 31, brightness: r.brightness)
                out[o + 1] = output8((color >> 5) & 31, brightness: r.brightness)
                out[o + 2] = output8((color >> 10) & 31, brightness: r.brightness)
            }
        }
        return PPUImage(width: width, height: height, rgba: out)
    }
}
