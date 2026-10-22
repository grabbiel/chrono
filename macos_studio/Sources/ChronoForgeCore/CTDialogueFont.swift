// CTDialogueFont.swift — the in-game dialogue box's font, glyph widths and
// window (frame graphics, colours, tilemaps, the HDMA band), read from the
// user's ROM. The Swift twin of re_workspace/tools/ct_dialogue.py, which holds
// the evidence (ChronoRET's TextWin_* and Field_* routines, ROM-wide claims,
// the routines themselves run in an interpreter); docs/dialogue.md describes
// the result. No ROM data is kept here.
import Foundation
import CryptoKit

public enum CTDialogueROM {
    public static let font = 0xFF2060, fontRight = 0xFF3860   // !TextWinRom_Font / !TextWinRom_FontRight
    public static let widths = 0xC260E6                       // TextWin_GlyphWidths (96 entries)
    public static let charNamePtrs = 0xC25FD8                 // TextWin_CharNamePtrs (7 entries)
    public static let strNadia = 0xC26146                     // TextWin_StrNadia (5 glyphs)
    public static let dictPtrs = 0xDEFA00                     // !TextWin_DictPtrs
    public static let techNames = 0xCC15C4, enemyNames = 0xCC6500, itemNames = 0xCC0B5E
    public static let hexGlyphs = 0xC25D03                    // TextWin_HexGlyphs
    public static let charNames = 0x7E2C23, party = 0x7E2980, itemID = 0x7F0200
    public static let args = 0x7E0200, numHex = 0x7E02A1
    public static let firstGlyph = 0xA0, firstDict = 0x21, digit0 = 0xD4
    public static let penLeft = 8, penIndent = 0x14          // !TextWin_PenXLeft / !TextWin_PenXIndent
    public static let glyphTopSkip = 8
    public static let charNameMax = 5, charNameSize = 6, romNameSize = 11, namePad = 0xEF, techIcon = 0x2F
    public static let stepDone = 0x10
    public static let waitUnit = 15, lastLine = 3, openSize = 0x29, swallow = 0xFFFF
    public static let bufferBytes = 0x400                     // !Field_Unk7EF000, one text line
    public static let textVRAM = 0x5800, lineWords = 0x200    // Field_UploadUnk5800: line L at $5800 + $200 L
    public static let frameSrcs = 0xC06EA0, frameSetBytes = 0x280
    public static let frameVRAM = 0x1F00, frameAltVRAM = 0x4FC0
    public static let palSets = 0xFFB210
    public static let palGreys: [UInt16] = [0x0C63, 0x18C6, 0x739C]  // colours 9-11: the text
    public static let styles = 8                              // Menu_Config01 bits 0-2
    public static let tilemapText = 0x1C00, tilemapFrame = 0x1D00
    public static let frameTile = 0xF0, frameHigh = 0x20, frameHighAlt = 0x23, textHigh = 0x29
    public static let bandSC: UInt8 = 0x1C
    public static let bandCentre = [1: 48, 2: 171]
    /// (BG1 V, BG3 V) by place.
    public static let bandScroll: [Int: (UInt16, UInt16)] = [1: (0x0037, 0xFFF1), 2: (0xFFBC, 0xFF76)]
    public static let tmBand: UInt8 = 5, tmEdge: UInt8 = 1, tmCap = 10, tmMin = 2
    public static let gradLines = 40, gradSteps = 8, gradAdd: UInt8 = 0x01, gradSub: UInt8 = 0x81
    public static let bgmode: UInt8 = 0x09, bg12nba: UInt8 = 0x11, bg34nba: UInt8 = 0x05, cgwsel: UInt8 = 0x02
    /// The box: 4 lines of 16 pixels, glyph rows 4-15 of a line, the frame's inner right edge.
    public static let lines = 4, lineHeight = 16, innerRight = 248, bandLines = 80

    public static func pc(_ long: Int) -> Int { (long >> 16 & 0x3F) << 16 | long & 0xFFFF }
    public static func snes(_ long: Int) -> String { String(format: "$%02X:%04X", long >> 16, long & 0xFFFF) }
}

/// The 24-bit space a message's routines read: the ROM (a 4 MiB HiROM image,
/// banks $C0-$FF) and RAM as {address: byte} (names, party, item id, arguments;
/// an entry at a ROM address overlays the ROM, as a message under edit does).
public struct CTDialogueMemory: Sendable {
    public let rom: [UInt8]
    public var ram: [Int: UInt8]

    /// `rom`: 4 MiB, a 512-byte copier header dropped.
    public init(rom: [UInt8], ram: [Int: UInt8] = [:]) {
        let size = 4 * 1024 * 1024
        self.rom = rom.count == size + 512 ? Array(rom.dropFirst(512)) : rom
        self.ram = [:]
        for (k, v) in ram { self.ram[Self.canon(k)] = v }
    }

    /// Low WRAM and its mirrors as $7E:0000-$1FFF.
    public static func canon(_ addr: Int) -> Int {
        let a = addr & 0xFFFFFF
        let bank = a >> 16, low = a & 0xFFFF
        if (bank < 0x40 || (0x80..<0xC0).contains(bank)) && low < 0x2000 { return 0x7E0000 | low }
        return a
    }

    public subscript(_ addr: Int) -> Int {
        let a = Self.canon(addr)
        if let v = ram[a] { return Int(v) }
        let bank = a >> 16
        if bank >= 0xC0 || (bank < 0x7E && a & 0xFFFF >= 0x8000) {
            let i = CTDialogueROM.pc(a)
            return i < rom.count ? Int(rom[i]) : 0
        }
        return 0
    }

    public func word(_ addr: Int) -> Int { self[addr] | self[addr + 1] << 8 }
}

// MARK: - Font

public enum CTDialogueFont {
    /// Every glyph a message can draw: $A0-$FF and $0100-$02FF (608).
    public static let glyphCodes: [Int] = Array(0xA0..<0x100) + Array(0x100..<0x300)

    /// (left 24 bytes, right 24 bytes) of glyph g: 16-bit sums in bank $FF (TextWin_DrawGlyph).
    public static func addresses(_ g: Int) -> (Int, Int) {
        let left = (g * 24 + (CTDialogueROM.font & 0xFFFF)) & 0xFFFF
        let right = ((g >> 1) * 24 + (CTDialogueROM.fontRight & 0xFFFF)) & 0xFFFF
        return (0xFF0000 | left, 0xFF0000 | right)
    }

    /// The 24 plane-row words of glyph g: bits 15-4 are pixels 0-11.
    public static func rowWords(_ mem: CTDialogueMemory, _ g: Int) -> [Int] {
        let (left, right) = addresses(g)
        var out: [Int] = []
        for r in 0..<24 {
            let hi = mem[left + r], nib = mem[right + r]
            let lo = g & 1 == 1 ? (nib << 4) & 0xFF : nib & 0xF0
            out.append(hi << 8 | lo)
        }
        return out
    }

    /// 12 rows of 12 colour indices 0-3.
    public static func pixels(_ mem: CTDialogueMemory, _ g: Int) -> [[UInt8]] {
        let words = rowWords(mem, g)
        var rows: [[UInt8]] = []
        for y in 0..<12 {
            var row: [UInt8] = []
            for x in 0..<12 {
                let p0 = words[2 * y] >> (15 - x) & 1
                let p1 = words[2 * y + 1] >> (15 - x) & 1
                row.append(UInt8(p0 | p1 << 1))
            }
            rows.append(row)
        }
        return rows
    }

    /// The pen advance: entry (g low byte - $A0) & $FF (wide glyphs read past the 96 entries).
    public static func width(_ mem: CTDialogueMemory, _ g: Int) -> Int {
        mem[CTDialogueROM.widths + (((g & 0xFF) - CTDialogueROM.firstGlyph) & 0xFF)]
    }

    /// TextWin_TileOfs2bpp entry `col` (0-63).
    public static func tileOffset(_ col: Int) -> Int {
        (col & 15) * 16 + (col >> 4 & 1) * 0x200 + (col >> 5 & 1) * 0x100
    }

    /// TextWin_Blit2bpp: glyph g at pen X into the 1 KB line buffer.
    public static func blit(_ buf: inout [UInt8], _ mem: CTDialogueMemory, _ g: Int, pen: Int) {
        let shift = pen & 7, tile = (pen & 0xF8) >> 3
        let ofs = [tileOffset(tile), tileOffset(tile + 1), tileOffset(tile + 2)]
        var out = CTDialogueROM.glyphTopSkip
        for (r, w) in rowWords(mem, g).enumerated() {
            if r == 8 { out += 0xF0 }
            if shift == 0 {
                buf[(out + ofs[1]) & 0x3FF] = UInt8(w & 0xFF)
                buf[(out + ofs[0]) & 0x3FF] = UInt8(w >> 8)
            } else if shift <= 4 {
                let v = w >> shift
                buf[(out + ofs[1]) & 0x3FF] = UInt8(v & 0xFF)
                buf[(out + ofs[0]) & 0x3FF] |= UInt8(v >> 8)
            } else {
                let k = 8 - shift
                let v = (w << k) & 0xFFFF
                buf[(out + ofs[2]) & 0x3FF] = UInt8(v & 0xFF)
                buf[(out + ofs[1]) & 0x3FF] = UInt8(v >> 8)
                buf[(out + ofs[0]) & 0x3FF] |= UInt8(w >> (16 - k))
            }
            out += 1
        }
    }

    /// SHA-256 over each glyph's 144 pixels and its width (ct_dialogue font_digest).
    public static func digest(_ mem: CTDialogueMemory, codes: [Int] = glyphCodes) -> String {
        var h = SHA256()
        for g in codes {
            for row in pixels(mem, g) { h.update(data: Data(row)) }
            h.update(data: Data([UInt8(width(mem, g))]))
        }
        return hex(h.finalize())
    }

    public static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 {
        d.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Window

public enum CTDialogueWindow {
    /// Frame style 0-7: (16 tiles $F0-$FF, 4 tiles $3FC-$3FF), 4bpp tile bytes.
    public static func frameSet(_ mem: CTDialogueMemory, style: Int) -> ([UInt8], [UInt8]) {
        let start = 0xFF0000 | mem.word(CTDialogueROM.frameSrcs + 2 * style)
        let data = (0..<CTDialogueROM.frameSetBytes).map { UInt8(mem[start + $0]) }
        return (Array(data[0..<0x200]), Array(data[0x200...]))
    }

    /// Colours 0-15 of CGRAM row 0 for style 0-7 (Pal_LoadUnkRow0); colour 0 is
    /// the field's, nil here; 9-11 the text greys.
    public static func palette(_ mem: CTDialogueMemory, style: Int) -> [UInt16?] {
        let src = CTDialogueROM.palSets + 2 + 16 * style
        var out: [UInt16?] = [nil]
        for i in 0..<15 { out.append(UInt16(mem.word(src + 2 * i))) }
        for (i, c) in CTDialogueROM.palGreys.enumerated() { out[9 + i] = c }
        return out
    }

    /// Field_Unk29F7's 32 x 10 frame map (tilemap words).
    public static func frameTilemap() -> [[UInt16]] {
        let t = CTDialogueROM.frameTile, hi = CTDialogueROM.frameHigh << 8, alt = CTDialogueROM.frameHighAlt << 8
        var rows: [[UInt16]] = []
        var top = [t | hi]
        for i in 0..<30 { top.append((t + 1 + (i & 1)) | hi) }
        top.append((t + 3) | hi)
        rows.append(top.map { UInt16($0) })
        for _ in 0..<2 {
            for r in 0..<4 {
                let even = r == 0 || r == 2
                let left = even ? t + 4 : t + 6, right = even ? t + 5 : t + 7
                let pair = even ? (t + 12, t + 13) : (t + 14, t + 15)
                let first = r < 2 ? (hi, alt) : (alt, hi)
                var row = [left | hi]
                for block in 0..<15 {
                    let h = block & 1 == 0 ? first.0 : first.1
                    row.append(pair.0 | h)
                    row.append(pair.1 | h)
                }
                row.append(right | hi)
                rows.append(row.map { UInt16($0) })
            }
        }
        var bottom = [(t + 8) | hi]
        for i in 0..<30 { bottom.append((t + 9 + (i & 1)) | hi) }
        bottom.append((t + 11) | hi)
        rows.append(bottom.map { UInt16($0) })
        return rows
    }

    /// Field_Unk2B78's 32 x 8 text grid: characters $00-$FF in runs of 16, high byte $29.
    public static func textTilemap() -> [[UInt16]] {
        let runs = [0x00, 0x20, 0x10, 0x30, 0x40, 0x60, 0x50, 0x70, 0x80, 0xA0, 0x90, 0xB0, 0xC0, 0xE0, 0xD0, 0xF0]
        var flat: [UInt16] = []
        for t in runs {
            for i in 0..<16 { flat.append(UInt16((t + i) | CTDialogueROM.textHigh << 8)) }
        }
        return (0..<8).map { Array(flat[(32 * $0)..<(32 * $0 + 32)]) }
    }

    /// EngFD_UnkD52D's (CGADSUB, COLDATA) pairs (90).
    public static func gradient() -> [(UInt8, UInt8)] {
        let step = CTDialogueROM.gradLines / CTDialogueROM.gradSteps
        var out: [(UInt8, UInt8)] = []
        for v in stride(from: 0xE8, to: 0xE0, by: -1) {
            out += Array(repeating: (CTDialogueROM.gradAdd, UInt8(v)), count: step)
        }
        let middle = step + 2 * (CTDialogueROM.gradLines % CTDialogueROM.gradSteps)
        out += Array(repeating: (CTDialogueROM.gradSub, UInt8(0xE0)), count: middle)
        for v in 0xE1..<0xEA {
            out += Array(repeating: (CTDialogueROM.gradSub, UInt8(v)), count: step)
        }
        return out
    }

    public struct BandLine: Equatable, Sendable {
        public var tm: UInt8
        /// nil on the last line: the field's own value.
        public var cgadsub: UInt8?
        public var coldata: UInt8
    }

    /// The band at Field_Unk27 = n (1-40), place 1 (top) / 2 (bottom): the first
    /// visible line and each band line's registers.
    public static func band(n: Int, place: Int) -> (first: Int, lines: [BandLine]) {
        let first = (CTDialogueROM.bandCentre[place] ?? 48) - n
        let a: Int, b: Int
        if n <= CTDialogueROM.tmCap {
            a = n - 1
            b = CTDialogueROM.tmMin
        } else {
            a = CTDialogueROM.tmCap
            b = 2 * n - 2 * CTDialogueROM.tmCap
        }
        let grad = gradient()
        var lines: [BandLine] = []
        for k in 0..<(2 * n) {
            let tm = (a..<(a + b)).contains(k) ? CTDialogueROM.tmBand : CTDialogueROM.tmEdge
            if k < 2 * n - 1 {
                let pair = grad[((CTDialogueROM.gradLines - n) & 0x3F) + k]
                lines.append(BandLine(tm: tm, cgadsub: pair.0, coldata: pair.1))
            } else {
                lines.append(BandLine(tm: tm, cgadsub: nil, coldata: 0xE0))
            }
        }
        return (first, lines)
    }
}
