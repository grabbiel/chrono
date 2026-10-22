// CTDialogueChoice.swift — where the field puts the dialogue box and the
// choice cursor of the choice messages, from the ROM's routines (checked by
// re_workspace/tools/ct_boxchoice.py, which runs them in ChronoRET's
// interpreter):
// - the place (Field_Unk1F87 state 5): Field_Unk30 1 or 2 as set by the
//   opcode (OpC1/OpC3 1, OpC2/OpC4 2), else (OpBB/OpC0: 0) by the low byte of
//   the speaker's Obj_ScreenY: below $80 the bottom (2), from $80 the top (1);
// - the choice (Evt_MsgChoiceStart, Sub_1ADF): the operand's bits 2-3 are the
//   first choice line and bits 0-1 the last; the cursor starts at the first
//   when the text has ended and Down / Up step it, wrapping;
// - the cursor (Irq_DrawChoiceCursor): tiles $0FC/$0FD over $0FE/$0FF (the 64
//   bytes at $FF:9260 sent to VRAM $57E0), palette 2, at columns 2-3 of the
//   choice line's two map rows of the text grid at $1C00, the grid's own words
//   back at the other lines.
import Foundation

public enum CTBoxPlace {
    public static let top = 1, bottom = 2
    /// Field_Unk30 as each message opcode sets it.
    public static let opcodeUnk30: [Int: Int] = [0xBB: 0, 0xC0: 0, 0xC1: 1, 0xC2: 2, 0xC3: 1, 0xC4: 2]
    /// The opcodes whose second operand is a choice (Evt_MsgChoiceStart).
    public static let choiceOpcodes: Set<Int> = [0xC0, 0xC3, 0xC4]

    /// Field_Unk26 for Field_Unk30 and the speaker's Obj_ScreenY (its low byte only).
    public static func place(unk30: Int, screenY: Int) -> Int {
        if unk30 == top || unk30 == bottom { return unk30 }
        return screenY & 0xFF < 0x80 ? bottom : top
    }

    /// The place of a message opcode's box for a speaker at `screenY` (nil: not a message opcode).
    public static func place(opcode: Int, screenY: Int) -> Int? {
        guard let unk30 = opcodeUnk30[opcode] else { return nil }
        return place(unk30: unk30, screenY: screenY)
    }

    /// Whether the opcode's place follows the speaker (Field_Unk30 = 0).
    public static func followsSpeaker(opcode: Int) -> Bool { opcodeUnk30[opcode] == 0 }
}

public struct CTChoice: Equatable, Sendable {
    public enum Key: Sendable { case down, up }

    /// Field_Unk64: the first choice line (operand bits 2-3).
    public var first: Int
    /// Field_Unk65: the last choice line (operand bits 0-1).
    public var last: Int

    public init(operand: Int) {
        first = operand >> 2 & 3
        last = operand & 3
    }

    /// The cursor after one key (nil: no key).
    public func step(_ cursor: Int, _ key: Key?) -> Int {
        let f7 = key == .down ? CTChoiceROM.padDown : key == .up ? CTChoiceROM.padUp : 0
        return Self.sub1ADF(f62: CTChoiceROM.active, f63: cursor, f64: first, f65: last, f66: 0, f6: 0, f7: f7,
                            f8: 0, f34: 0).f63
    }

    public struct Sub1ADF: Equatable, Sendable {
        public var f62: Int, f63: Int, f66: Int, f34: Int
    }

    /// Sub_1ADF ($C0:1ADF) for Field_Unk62-66, the pads $F6-$F8 and Field_Unk34: its writes.
    public static func sub1ADF(f62: Int, f63: Int, f64: Int, f65: Int, f66: Int, f6: Int, f7: Int, f8: Int,
                               f34: Int) -> Sub1ADF {
        var out = Sub1ADF(f62: f62, f63: f63, f66: f66, f34: f34)
        if f62 == CTChoiceROM.active {
            if f7 & CTChoiceROM.padDown != 0 {
                let n = (f63 + 1) & 0xFF
                out.f63 = n <= f65 ? n : f64
            } else if f7 & CTChoiceROM.padUp != 0 {
                if f63 == 0 {
                    out.f63 = f65
                } else {
                    out.f63 = f63 - 1 >= f64 ? f63 - 1 : f65
                }
            } else if f8 & CTChoiceROM.padConfirm != 0 {
                out.f62 = CTChoiceROM.made
            }
            return out
        }
        if f62 != CTChoiceROM.start && f63 < 0x80 && f63 != CTChoiceROM.cursorOff {
            out.f66 = f63
            out.f63 = CTChoiceROM.cursorOff
        }
        if f6 & 0x80 != 0 { out.f34 = 0 }
        return out
    }
}

public enum CTChoiceROM {
    public static let start = 1, active = 2, made = 3          // Field_Unk62
    public static let cursorOff = 4, cursorIdle = 0x80         // Field_Unk63
    public static let padDown = 0x04, padUp = 0x08, padConfirm = 0x80
    public static let vramRow0 = 0x1C02, vramRowStep = 0x40, vramLine = 0x20
    public static let tileTop: UInt16 = 0x28FC, tileBottom: UInt16 = 0x28FE
    public static let gridRow0: UInt16 = 0x2902, gridRowStep: UInt16 = 0x40, gridLine: UInt16 = 0x10
    /// FieldRom_Unk9260: the cursor's four 2bpp characters, sent to VRAM $57E0 (BG3 $0FC-$0FF).
    public static let gfx = 0xFF9260, gfxBytes = 0x40, gfxVRAM = 0x57E0
}

public enum CTChoiceCursor {
    public struct Write: Equatable, Sendable {
        public var address: Int
        public var word: UInt16
    }

    static func gridWord(_ row: Int, below: Bool) -> UInt16 {
        CTChoiceROM.gridRow0 + CTChoiceROM.gridRowStep * UInt16(row) + (below ? CTChoiceROM.gridLine : 0)
    }

    /// Irq_DrawChoiceCursor's VRAM word writes in order, and Field_Unk63 after (`row` 0-$7F).
    public static func writes(row: Int) -> (writes: [Write], after: Int) {
        var out: [Write] = []
        for j in 0..<4 where j != row {
            let at = CTChoiceROM.vramRow0 + CTChoiceROM.vramRowStep * j
            let up = gridWord(j, below: false)
            let down = gridWord(j, below: true)
            out += [Write(address: at, word: up), Write(address: at + 1, word: up + 1),
                    Write(address: at + CTChoiceROM.vramLine, word: down),
                    Write(address: at + CTChoiceROM.vramLine + 1, word: down + 1)]
        }
        guard row < 4 else { return (out, CTChoiceROM.cursorIdle) }
        let at = CTChoiceROM.vramRow0 + CTChoiceROM.vramRowStep * row
        out += [Write(address: at, word: CTChoiceROM.tileTop), Write(address: at + 1, word: CTChoiceROM.tileTop + 1),
                Write(address: at + CTChoiceROM.vramLine, word: CTChoiceROM.tileBottom),
                Write(address: at + CTChoiceROM.vramLine + 1, word: CTChoiceROM.tileBottom + 1)]
        return (out, row)
    }

    /// The cursor's characters (Field_UploadUnk57E0) and the cursor at text line `row` in `f`.
    public static func apply(_ f: inout PPUFrame, row: Int, mem: CTDialogueMemory) {
        var bytes: [UInt8] = []
        for i in 0..<CTChoiceROM.gfxBytes { bytes.append(UInt8(mem[CTChoiceROM.gfx + i] & 0xFF)) }
        CTDialogueBox.storeBytes(&f, bytes, atWord: CTChoiceROM.gfxVRAM)
        for w in writes(row: row).writes { f.vram[w.address & 0x7FFF] = w.word }
    }

    /// The first frame the cursor shows: the frame after the text's last wait
    /// begins (state 7 with TextWin_Status 0: Field_Unk1F87 then starts the
    /// cursor). nil for a layout with no end wait.
    public static func firstFrame(_ layout: CTDialogueLayout) -> Int? {
        let frames = layout.frames
        guard let close = frames.firstIndex(where: { $0.state == 13 }) else { return nil }
        var t = close
        while t > 0 && frames[t - 1].state == 7 { t -= 1 }
        guard t < close else { return nil }
        return min(t + 1, close - 1)
    }

    /// The cursor's 16 x 16 pixels (colour indices 0-3).
    public static func pixels(_ mem: CTDialogueMemory) -> [[UInt8]] {
        var pix = [[UInt8]](repeating: [UInt8](repeating: 0, count: 16), count: 16)
        for t in 0..<4 {
            let ox = 8 * (t & 1)
            let oy = 8 * (t >> 1)
            for y in 0..<8 {
                let p0 = UInt8(mem[CTChoiceROM.gfx + 16 * t + 2 * y] & 0xFF)
                let p1 = UInt8(mem[CTChoiceROM.gfx + 16 * t + 2 * y + 1] & 0xFF)
                for x in 0..<8 {
                    let lo = p0 >> UInt8(7 - x) & 1
                    let hi = p1 >> UInt8(7 - x) & 1
                    pix[oy + y][ox + x] = lo | hi << 1
                }
            }
        }
        return pix
    }
}
