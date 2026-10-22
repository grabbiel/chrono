// CTDialogueBox.swift — the dialogue box as a PPU picture: the frame style's
// tiles and colours, the window and text tilemaps and the uploaded text lines
// in VRAM, and the band's per-line registers (BG1SC/BG3SC, scroll, TM, colour
// math) as the field's HDMA sets them, for any frame of a CTDialogueLayout.
// Rendered by PPUReferenceRenderer (CLI, tests) or ChronoForgeMetal (Studio).
// Outside the band the field would show the map; here it is the backdrop.
import Foundation

public struct CTDialogueBox: Sendable {
    public let mem: CTDialogueMemory
    /// Menu_Config01 bits 0-2: the frame graphics and colour set (0-7).
    public var style: Int
    /// What shows outside the band and behind it (CGRAM 0).
    public var backdrop: UInt16

    public init(mem: CTDialogueMemory, style: Int = 0, backdrop: UInt16 = 0) {
        self.mem = mem
        self.style = style & 7
        self.backdrop = backdrop
    }

    public init(rom: [UInt8], style: Int = 0, backdrop: UInt16 = 0) {
        self.init(mem: CTDialogueMemory(rom: rom), style: style, backdrop: backdrop)
    }

    /// Video memory with the window loaded and no text (Field_UploadUnk1F00,
    /// Pal_LoadUnkRow0, Field_Unk29F7 and Field_Unk2B78 into $1C00/$1D00).
    public func blankFrame() -> PPUFrame {
        var f = PPUFrame()
        let (tiles, alt) = CTDialogueWindow.frameSet(mem, style: style)
        Self.storeBytes(&f, tiles, atWord: CTDialogueROM.frameVRAM)
        Self.storeBytes(&f, alt, atWord: CTDialogueROM.frameAltVRAM)
        let colours = CTDialogueWindow.palette(mem, style: style)
        f.cgram[0] = backdrop
        for i in 1..<16 { f.cgram[i] = colours[i] ?? 0 }
        for (r, row) in CTDialogueWindow.textTilemap().enumerated() {
            for (c, w) in row.enumerated() { f.vram[CTDialogueROM.tilemapText + 32 * r + c] = w }
        }
        for (r, row) in CTDialogueWindow.frameTilemap().enumerated() {
            for (c, w) in row.enumerated() { f.vram[CTDialogueROM.tilemapFrame + 32 * r + c] = w }
        }
        f.setAllLines { r in
            r.bgmode = CTDialogueROM.bgmode
            r.bg[0].charBase = CTDialogueROM.bg12nba & 0x0F
            r.bg[1].charBase = CTDialogueROM.bg12nba >> 4
            r.bg[2].charBase = CTDialogueROM.bg34nba & 0x0F
            r.bg[3].charBase = CTDialogueROM.bg34nba >> 4
            r.cgwsel = CTDialogueROM.cgwsel
            r.tm = 0
        }
        return f
    }

    /// Little-endian byte pairs as VRAM words.
    static func storeBytes(_ f: inout PPUFrame, _ bytes: [UInt8], atWord address: Int) {
        for i in 0..<(bytes.count / 2) {
            f.vram[(address + i) & 0x7FFF] = UInt16(bytes[2 * i]) | UInt16(bytes[2 * i + 1]) << 8
        }
    }

    /// Text lines as the NMI uploaded them up to `frame` (Field_UploadUnk5800).
    public static func storeText(_ f: inout PPUFrame, _ layout: CTDialogueLayout, through frame: Int) {
        var latest: [Int: [UInt8]] = [:]
        for u in layout.uploads where u.frame <= frame { latest[u.line & 3] = u.bytes }
        for (line, bytes) in latest {
            storeBytes(&f, bytes, atWord: CTDialogueROM.textVRAM + line * CTDialogueROM.lineWords)
        }
    }

    /// The band's registers at Field_Unk27 = `open` (0 closed) and `place`.
    public static func applyBand(_ f: inout PPUFrame, open: Int, place: Int) {
        guard open > 0 else { return }
        let (first, lines) = CTDialogueWindow.band(n: open, place: place)
        let scroll = CTDialogueROM.bandScroll[place] ?? (0, 0)
        for (k, b) in lines.enumerated() {
            let y = first + k
            guard y >= 0 && y < f.height else { continue }
            f.lines[y].bg[0].sc = CTDialogueROM.bandSC
            f.lines[y].bg[2].sc = CTDialogueROM.bandSC
            f.lines[y].bg[0].vofs = scroll.0
            f.lines[y].bg[2].vofs = scroll.1
            f.lines[y].tm = b.tm
            f.lines[y].cgadsub = b.cgadsub ?? 0
            f.lines[y].fixedColor = coldata(b.coldata)
        }
    }

    /// COLDATA $E0 | v: all three channels at intensity v.
    static func coldata(_ v: UInt8) -> BGR555 {
        let i = UInt16(v & 31)
        let r: UInt16 = v & 0x20 != 0 ? i : 0
        let g: UInt16 = v & 0x40 != 0 ? i << 5 : 0
        let b: UInt16 = v & 0x80 != 0 ? i << 10 : 0
        return BGR555(word: r | g | b)
    }

    /// The picture after `frame` of `layout` (clamped to its frames); `cursor`:
    /// a choice message's cursor line (CTChoiceCursor), shown from the end wait.
    public func frame(_ layout: CTDialogueLayout, at frame: Int, cursor: Int? = nil) -> PPUFrame {
        var f = blankFrame()
        guard !layout.frames.isEmpty else { return f }
        let t = min(max(0, frame), layout.frames.count - 1)
        Self.storeText(&f, layout, through: t)
        let s = layout.frames[t]
        Self.applyBand(&f, open: s.open, place: s.place)
        if let cursor, let first = CTChoiceCursor.firstFrame(layout), t >= first {
            CTChoiceCursor.apply(&f, row: cursor, mem: mem)
        }
        return f
    }

    /// 256 x 224 RGBA8 of `frame`.
    public func render(_ layout: CTDialogueLayout, at frame: Int, cursor: Int? = nil) -> [UInt8] {
        PPUReferenceRenderer.render(self.frame(layout, at: frame, cursor: cursor))
    }

    /// The frame at which page `page` is fully drawn (nil past the last page).
    public static func pageFrame(_ layout: CTDialogueLayout, page: Int) -> Int? {
        layout.pageFrame(page)
    }

    /// The box's rows on screen at full size: (first line, 80 lines).
    public static func boxLines(place: Int) -> Range<Int> {
        let (first, _) = CTDialogueWindow.band(n: CTDialogueROM.openSize - 1, place: place)
        return first..<(first + CTDialogueROM.bandLines)
    }
}
