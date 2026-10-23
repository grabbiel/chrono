// CTHelpLine.swift — an item's or a tech's description as the menu's help
// line draws it: Menu_DrawDescText / Menu_TechDescText set up the dialogue
// box's own decoder (CTTextWin, mode 0, one step a frame) into the glyph
// buffer $7E:5E00, and Menu_TextStepLoop / Menu_TextUpload send that buffer
// to VRAM $7800 (BG3 characters $100+) and two rows of BG3's map (at $6800)
// each frame. The Swift twin of re_workspace/tools/ct_helpline.py, which ran
// the ROM's own routines on every description in an interpreter
// (docs/dialogue.md). The window's frame (BG1/BG2) is not drawn.
import Foundation
import CryptoKit

public enum CTHelpLineROM {
    public static let itemTable = 0xCC2EB1, techTable = 0xCC3A09     // !MenuRom_DescStrTable / TechTextTable
    public static let itemCount = 242, techCount = 0x76               // item ids 0-$F1; tech ids 0-$75
    public static let gfx = 0x7E5E00, gfxBytes = 0x400                // !Menu_TextGfxA
    public static let tileDest = 0x7800, tileWord = 0x3101, penFirst = 8
    public static let mapBytes = 0x80, rowBytes = 0x40, lowerTile = 0x10
    public static let lineBreak = 5                                   // !Menu_TextLineBreak
    public static let bg3Map = 0x6800, bg3Chars = 0x7000
    public static let bg3sc: UInt8 = 0x6A, bg34nba: UInt8 = 0x07, bgmode: UInt8 = 0x09
    public static let palB = 0xFF9C78, palA = 0xFF9C68                // colours 16-19; colours 0-3
    /// A pen past this puts tile words past column 31 of the row.
    public static let rightLimit = 240
}

public struct CTHelpLine: Sendable {
    public enum Place: String, CaseIterable, Sendable {
        case item, tech
        /// Menu_TextDest: the bank-$7E address of the first tile word, less 2.
        public var dest: Int { self == .item ? 0x4E84 : 0x5344 }
        /// Menu_Unk0DCC: the VRAM word address the two rows go to.
        public var vramMap: Int { self == .item ? 0x6840 : 0x6AA0 }
        public var table: Int { self == .item ? CTHelpLineROM.itemTable : CTHelpLineROM.techTable }
        public var count: Int { self == .item ? CTHelpLineROM.itemCount : CTHelpLineROM.techCount }
        /// The first of the two BG3 rows on screen.
        public var row: Int { (vramMap - CTHelpLineROM.bg3Map) / 32 }
    }

    public struct Upload: Equatable, Sendable {
        public var frame: Int
        /// The glyph buffer (true) or the two map rows.
        public var glyphs: Bool
        public var dest: Int
        public var source: Int
        public var bytes: [UInt8]
    }

    public struct Glyph: Equatable, Sendable {
        public var frame: Int, glyph: Int, pen: Int, width: Int, line: Int
    }

    public let place: Place
    public private(set) var uploads: [Upload] = []
    public private(set) var glyphs: [Glyph] = []
    /// Frames from the first step to the decoder's end.
    public private(set) var frames = 0
    /// Lines started (only the first is ever shown).
    public private(set) var lineCount = 1
    /// The first line's last pen.
    public private(set) var right = CTHelpLineROM.penFirst
    /// The pen passed 255.
    public private(set) var wraps = false
    /// A tile word of the first line went past column 31 of its row.
    public private(set) var pastRow = false
    /// Why the game's tile loop would run away (a pen reset or wrap: 65536 words), when
    /// `stopAtRunaway` stopped the line there instead of throwing.
    public private(set) var runaway: String?
    public private(set) var buffer: [UInt8]
    public private(set) var wram: [Int: UInt8]

    /// One line, in the row, no wrap and the pen at most 240.
    public var fits: Bool {
        lineCount == 1 && !wraps && !pastRow && runaway == nil && right <= CTHelpLineROM.rightLimit
    }
    /// The screen x the first line ends at (buffer tile k is map column 2 + k).
    public var rightX: Int { right + 16 }

    /// The string at `text` (24-bit, in `mem`) to the decoder's status 0.
    /// `gfx`: the glyph buffer before (the routine never clears it); `wram`:
    /// bank-$7E bytes of the map before (by 16-bit address).
    /// `stopAtRunaway`: a runaway tile loop ends the line (see `runaway`) instead of throwing.
    public init(mem: CTDialogueMemory, text: Int, place: Place, settings: CTDialogueSettings = .placeholder(),
                gfx: [UInt8]? = nil, wram: [Int: UInt8] = [:], maxFrames: Int = 4000, stopAtRunaway: Bool = false) throws {
        var m = mem
        for (k, v) in settings.ram() { m.ram[CTDialogueMemory.canon(k)] = v }
        self.place = place
        self.buffer = gfx ?? [UInt8](repeating: 0, count: CTHelpLineROM.gfxBytes)
        self.wram = wram
        try run(m, text: text, maxFrames: maxFrames, stopAtRunaway: stopAtRunaway)
    }

    /// Description bytes overlaid at $C8:0000 on `rom`.
    public static func bytes(_ text: [UInt8], rom: [UInt8], place: Place,
                             settings: CTDialogueSettings = .placeholder(), stopAtRunaway: Bool = true) throws -> CTHelpLine {
        let at = 0xC80000
        guard text.count <= 0x10000 else { throw CTDialogueError("description too long") }
        var mem = CTDialogueMemory(rom: rom)
        for (i, b) in text.enumerated() { mem.ram[at + i] = b }
        return try CTHelpLine(mem: mem, text: at, place: place, settings: settings, stopAtRunaway: stopAtRunaway)
    }

    /// The ROM's string `index` of the place's table (16-bit pointers into its bank).
    public static func stringAddress(_ mem: CTDialogueMemory, place: Place, index: Int) -> Int {
        (place.table & 0xFF0000) | mem.word(place.table + 2 * (index & 0xFF))
    }

    /// The ROM's description bytes up to (not with) the $00.
    public static func description(_ mem: CTDialogueMemory, place: Place, index: Int) -> [UInt8] {
        let at = stringAddress(mem, place: place, index: index)
        var out: [UInt8] = []
        while out.count < 0x200 {
            let b = mem[(at & 0xFF0000) | (at + out.count) & 0xFFFF]
            if b == 0 { break }
            out.append(UInt8(b))
        }
        return out
    }

    private mutating func put(_ addr: Int, _ word: Int) {
        wram[addr & 0xFFFF] = UInt8(word & 0xFF)
        wram[(addr + 1) & 0xFFFF] = UInt8(word >> 8 & 0xFF)
    }

    private func mapBytes(_ start: Int, _ n: Int) -> [UInt8] {
        var out: [UInt8] = []
        for i in 0..<n { out.append(wram[(start + i) & 0xFFFF] ?? 0) }
        return out
    }

    private mutating func run(_ mem: CTDialogueMemory, text: Int, maxFrames: Int, stopAtRunaway: Bool) throws {
        let row = place.dest & 0xFFC0
        for i in 0..<CTHelpLineROM.mapBytes { wram[row + i] = 0 }
        var glyphCount = 0, col = 0, penStart = CTHelpLineROM.penFirst
        var tileWord = CTHelpLineROM.tileWord, tileDest = CTHelpLineROM.tileDest
        var unk17 = 0
        var line = 0
        var tw = CTTextWin(mem: mem, text: text)
        while true {
            guard frames < maxFrames else { throw CTDialogueError("no end within \(maxFrames) frames") }
            if (5...12).contains(tw.status) { unk17 = 0 }
            let before = tw.drawn.count
            try tw.step(&buffer)
            for d in tw.drawn[before...] where !d.code {
                glyphs.append(Glyph(frame: frames, glyph: d.value, pen: d.pen, width: d.width, line: line))
                if d.pen + d.width > 0xFF { wraps = true }
                unk17 = (unk17 + 1) & 0xFF
            }
            // Menu_TextUpload
            if unk17 != glyphCount {
                glyphCount = unk17
                uploads.append(Upload(frame: frames, glyphs: true, dest: tileDest, source: CTHelpLineROM.gfx & 0xFFFF,
                                      bytes: buffer))
                var p = tw.pen
                for _ in 0..<3 { p = (p >> 1) + (p & 1) }
                let first = (penStart & 0xF8) >> 2
                var x = (first + col + place.dest) & 0xFFFF
                let tmp02 = first >> 1
                let count = (p - tmp02) & 0xFFFF
                guard count != 0 && count <= 0x40 else {
                    let n = count == 0 ? 0x10000 : count
                    let why = "frame \(frames): the tile loop would write \(n) words (pen \(tw.pen), last tile pen \(penStart))"
                    guard stopAtRunaway else { throw CTDialogueError(why) }
                    runaway = why
                    frames += 1
                    return
                }
                var a = ((tmp02 - 1) & 0xFFFF) + tileWord
                let carry = a >> 16
                a = (a + CTHelpLineROM.lowerTile + carry) & 0xFFFF
                for _ in 0..<count {
                    a &= 0xFFEF
                    put(x, a)
                    a |= CTHelpLineROM.lowerTile
                    put(x + CTHelpLineROM.rowBytes, a)
                    a = (a + 1) & 0xFFFF
                    if line == 0 && (x - row) / 2 >= 32 { pastRow = true }
                    x += 2
                }
                penStart = tw.pen
                if line == 0 { right = tw.pen }
            }
            uploads.append(Upload(frame: frames, glyphs: false, dest: place.vramMap, source: row,
                                  bytes: mapBytes(row, CTHelpLineROM.mapBytes)))
            if tw.status == 0 { break }
            if tw.status == CTHelpLineROM.lineBreak {
                col = (col & 0xFF00) | ((col & 0xE0) + 0x80) & 0xFF
                tileWord = (tileWord & 0xFF00) | ((tileWord & 0xC0) + 0x41) & 0xFF
                glyphCount = 0
                tileDest = (tileDest + 0x200) & 0xFFFF
                penStart = CTHelpLineROM.penFirst
                line += 1
                lineCount = line + 1
            }
            frames += 1
        }
        frames += 1
    }

    // MARK: - What the screen shows

    /// VRAM words after the uploads up to `frame` (all of them when nil), in order.
    public func vram(through frame: Int? = nil) -> [Int: UInt16] {
        var out: [Int: UInt16] = [:]
        for u in uploads where frame.map({ u.frame <= $0 }) ?? true {
            for i in 0..<(u.bytes.count / 2) {
                out[(u.dest + i) & 0x7FFF] = UInt16(u.bytes[2 * i]) | UInt16(u.bytes[2 * i + 1]) << 8
            }
        }
        return out
    }

    /// The two BG3 map rows the help line shows (2 x 32 tile words).
    public func rows(through frame: Int? = nil) -> [[UInt16]] {
        let v = vram(through: frame)
        var out: [[UInt16]] = []
        for r in 0..<2 {
            var row: [UInt16] = []
            for c in 0..<32 { row.append(v[place.vramMap + 32 * r + c] ?? 0) }
            out.append(row)
        }
        return out
    }

    /// 16 lines x 256 colour indices 0-3 (palette 4) of BG3's two rows; tiles
    /// below $100 (the menu font, and the cleared map's blank tile 0) read 0.
    public func pixels(through frame: Int? = nil) -> [[UInt8]] {
        let v = vram(through: frame)
        var out = [[UInt8]](repeating: [UInt8](repeating: 0, count: 256), count: 16)
        for (r, row) in rows(through: frame).enumerated() {
            for (c, w) in row.enumerated() {
                let tile = Int(w & 0x3FF)
                guard tile >= 0x100 else { continue }
                let base = CTHelpLineROM.bg3Chars + tile * 8
                let hf = w & 0x4000 != 0, vf = w & 0x8000 != 0
                for y in 0..<8 {
                    let word = Int(v[base + (vf ? 7 - y : y)] ?? 0)
                    for xx in 0..<8 {
                        let bit = hf ? xx : 7 - xx
                        out[8 * r + y][8 * c + xx] = UInt8((word >> bit & 1) | (word >> (8 + bit) & 1) << 1)
                    }
                }
            }
        }
        return out
    }

    /// The menu's colours 0 and 16-19 (MenuRom_PalA's first, MenuRom_PalB).
    public static func palette(_ mem: CTDialogueMemory) -> (backdrop: UInt16, bg3: [UInt16]) {
        var bg3: [UInt16] = []
        for i in 0..<4 { bg3.append(UInt16(mem.word(CTHelpLineROM.palB + 2 * i))) }
        return (UInt16(mem.word(CTHelpLineROM.palA)), bg3)
    }

    /// A PPU picture of the help line after `frame`: BG3 alone in the menu's
    /// mode 1 (map $6800, characters $7000, palette 4), over `backdrop`.
    public func frame(through frame: Int? = nil, backdrop: UInt16, colours: [UInt16]) -> PPUFrame {
        var f = PPUFrame()
        for (a, w) in vram(through: frame) { f.vram[a & 0x7FFF] = w }
        f.cgram[0] = backdrop
        for (i, c) in colours.prefix(4).enumerated() { f.cgram[16 + i] = c }
        f.setAllLines { r in
            r.bgmode = CTHelpLineROM.bgmode
            r.bg[2].sc = CTHelpLineROM.bg3sc
            r.bg[2].charBase = CTHelpLineROM.bg34nba & 0x0F
            r.tm = 0x04
        }
        return f
    }

    /// The picture line BG3 row 8 x `place.row` is on (line i shows scanline i + 1; BG3VOFS 0).
    public var topLine: Int { place.row * 8 - 1 }

    /// The help line's 256 x 16 RGBA8 strip of `frame(...)`, rendered by PPUReferenceRenderer.
    public func renderStrip(through frame: Int? = nil, backdrop: UInt16, colours: [UInt16]) -> [UInt8] {
        let full = PPUReferenceRenderer.render(self.frame(through: frame, backdrop: backdrop, colours: colours))
        let top = topLine
        return Array(full[(top * 256 * 4)..<((top + 16) * 256 * 4)])
    }

    // MARK: - Summary (ct_helpline.py's numbers)

    public struct Summary: Codable, Equatable, Sendable {
        public var frames: Int, glyphs: Int, pens: [Int], lines: Int, right: Int, rightX: Int
        public var wraps: Bool, pastRow: Bool, fits: Bool, uploads: Int
        public var uploadDigest: String, rows: String, pixels: String
    }

    static func sha(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    public var summary: Summary {
        var up: [UInt8] = []
        for u in uploads {
            let fr = UInt32(u.frame)
            up += [UInt8(fr & 0xFF), UInt8(fr >> 8 & 0xFF), UInt8(fr >> 16 & 0xFF), UInt8(fr >> 24)]
            up += [UInt8(u.dest & 0xFF), UInt8(u.dest >> 8 & 0xFF), UInt8(u.source & 0xFF), UInt8(u.source >> 8 & 0xFF)]
            up += u.bytes
        }
        var rowBytes: [UInt8] = []
        for row in rows() {
            for w in row {
                rowBytes.append(UInt8(w & 0xFF))
                rowBytes.append(UInt8(w >> 8))
            }
        }
        var pix: [UInt8] = []
        for row in pixels() { pix += row }
        let pens = glyphs.map { $0.pen }
        return Summary(frames: frames, glyphs: glyphs.count, pens: pens, lines: lineCount, right: right,
                       rightX: rightX, wraps: wraps, pastRow: pastRow, fits: fits, uploads: uploads.count,
                       uploadDigest: Self.sha(up), rows: Self.sha(rowBytes), pixels: Self.sha(pix))
    }
}
