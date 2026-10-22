// CTDialogueLayout.swift — how a message lays out and paces in the dialogue
// box: TextWin_Step (bank $C2, one step per frame) inside the field's
// Field_Unk1F87 / Field_MsgStep state machine and the NMI's line upload. The
// Swift twin of ct_dialogue.py's TextWin and Dialogue classes, which the ROM's
// own routines were run against in an interpreter (docs/dialogue.md). Control
// codes are named only by what their handlers do; unknown ones stay raw.
import Foundation
import CryptoKit

/// What a message reads besides its own bytes.
public struct CTDialogueSettings: Equatable, Sendable {
    /// 8 names of up to 6 glyph bytes ($7E:2C23, 0-terminated, 5 drawn at most).
    public var names: [[UInt8]]
    /// The 3 party member ids ($7E:2980).
    public var party: [Int]
    /// The treasure item id ($7F:0200).
    public var item: Int
    /// The 12 argument bytes at $0200 (numbers, $11, $12 00 / 01).
    public var args: [UInt8]
    /// TextWin_NumHex: $0D/$0E print hex.
    public var numHex: Bool
    /// 1 the top of the screen, 2 the bottom (Field_Unk26).
    public var place: Int
    /// Frames after a key wait begins that the key is pressed (>= 1).
    public var press: Int

    public init(names: [[UInt8]] = Array(repeating: [], count: 8), party: [Int] = [0, 1, 2], item: Int = 0,
                args: [UInt8] = Array(repeating: 0, count: 12), numHex: Bool = false, place: Int = 1, press: Int = 1) {
        self.names = names
        self.party = party
        self.item = item
        self.args = args
        self.numHex = numHex
        self.place = place
        self.press = max(1, press)
    }

    /// Placeholder names "A"-"H", party 0-2, item 1, arguments $12, $34, ... (ct_dialogue default_settings).
    public static func placeholder(press: Int = 1, place: Int = 1) -> CTDialogueSettings {
        var args: [UInt8] = []
        for i in 0..<12 { args.append(UInt8((0x12 + 0x22 * i) & 0xFF)) }
        let names: [[UInt8]] = (0..<8).map { [UInt8(0xA0 + $0)] }
        return CTDialogueSettings(names: names, item: 1, args: args, place: place, press: press)
    }

    public func ram() -> [Int: UInt8] {
        var out: [Int: UInt8] = [:]
        for i in 0..<8 {
            let name = i < names.count ? names[i] : []
            for k in 0..<CTDialogueROM.charNameSize {
                out[CTDialogueROM.charNames + CTDialogueROM.charNameSize * i + k] = k < name.count ? name[k] : 0
            }
        }
        for (i, p) in party.enumerated() { out[CTDialogueROM.party + i] = UInt8(p & 0xFF) }
        out[CTDialogueROM.itemID] = UInt8(item & 0xFF)
        out[CTDialogueROM.itemID + 1] = UInt8(item >> 8 & 0xFF)
        for (i, b) in args.enumerated() { out[CTDialogueROM.args + i] = b }
        out[CTDialogueROM.numHex] = numHex ? 1 : 0
        return out
    }
}

public struct CTDialogueError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct CTDialogueEvent: Equatable, Sendable {
    public enum Kind: String, Sendable { case glyph, code, key }
    public var frame: Int
    public var kind: Kind
    /// The glyph (16-bit), the code byte, or 0 for a key.
    public var value: Int
    /// The pen X before the glyph or code (nil for a key).
    public var pen: Int?
    /// Field_Unk31: the box line (0-3).
    public var line: Int
    /// The page (0 first): pages turn when the box is cleared (Field_Unk29 = 8).
    public var page: Int
    /// The glyph's advance (0 for codes and keys).
    public var width: Int
}

/// TextWin_Init / TextWin_Step in mode 0 (2bpp), one step per call.
struct CTTextWin {
    var mem: CTDialogueMemory
    var ptr: Int
    var state = 0, status = 4, pen = CTDialogueROM.penLeft, code3 = 0
    var sub: Int? = 0
    var left = 0
    var argp = CTDialogueROM.args
    var digits: [Int] = []
    var drawn: [(code: Bool, value: Int, pen: Int, width: Int)] = []

    init(mem: CTDialogueMemory, text: Int) {
        self.mem = mem
        self.ptr = text
    }

    mutating func arg(_ n: Int) throws -> Int {
        guard argp + n <= CTDialogueROM.args + 12 else {
            throw CTDialogueError("an argument code reads past $020B (the TextWin block itself)")
        }
        var v = 0
        for i in 0..<n { v |= mem[argp + i] << (8 * i) }
        argp += n
        return v
    }

    mutating func draw(_ g: Int, into buf: inout [UInt8]) {
        let w = CTDialogueFont.width(mem, g)
        drawn.append((false, g, pen, w))
        CTDialogueFont.blit(&buf, mem, g, pen: pen)
        pen = (pen + w) & 0xFF
    }

    mutating func step(_ buf: inout [UInt8]) throws {
        if status == 0 { return }
        if [5, 7, 9, 11].contains(status) {
            pen = CTDialogueROM.penLeft
        } else if [6, 8, 10, 12].contains(status) {
            pen = CTDialogueROM.penIndent
        }
        switch state {
        case 0: try state0(&buf)
        case 2: try stateDec(&buf)
        default: try stateSub(&buf)
        }
    }

    mutating func nextByte() -> Int {
        let b = mem[ptr]
        ptr = (ptr & 0xFF0000) | (ptr + 1) & 0xFFFF
        return b
    }

    mutating func startSub(_ addr: Int?, _ count: Int, state: Int = 1) {
        sub = addr
        left = count
        self.state = state
    }

    mutating func state0(_ buf: inout [UInt8]) throws {
        let b = nextByte()
        if b >= CTDialogueROM.firstGlyph { return glyph0(b, &buf) }
        if b >= CTDialogueROM.firstDict {
            let at = 0xDE0000 | mem.word(CTDialogueROM.dictPtrs + ((b - CTDialogueROM.firstDict) * 2 & 0xFF))
            startSub(at + 1, mem[at])
            return try stateSub(&buf)
        }
        drawn.append((true, b, pen, 0))
        switch b {
        case 0, 4...12:
            status = b
        case 3:
            code3 = nextByte()
            status = 3
        case 1, 2:
            glyph0(b << 8 | nextByte(), &buf)
        case 0x0D, 0x0E, 0x0F:
            try number(b, &buf)
        case 0x10:
            return
        case 0x11:
            try charName(try arg(1) * 2, doubled: true, &buf)      // a 16-bit ASL here
        case 0x12:
            let e = nextByte()
            if e >= 8 {
                let at = 0xDE0000 | mem.word(CTDialogueROM.dictPtrs + (e - 8 + 0x1F) * 2)
                startSub(at + 1, mem[at])
                return try stateSub(&buf)
            }
            guard e <= 1 else { throw CTDialogueError(String(format: "code $12 $%02X jumps past TextWin_ExtTable", e)) }
            var at = (e == 0 ? CTDialogueROM.techNames : CTDialogueROM.enemyNames) + (try arg(1)) * CTDialogueROM.romNameSize
            var count = CTDialogueROM.romNameSize
            if e == 0 {
                count = nameLength(at, most: CTDialogueROM.romNameSize)
                if mem[at] == CTDialogueROM.techIcon {
                    at += 1
                    count = nameLength(at, most: CTDialogueROM.romNameSize - 1)
                }
            }
            startSub(at, count)
            try stateSub(&buf)
        case 0x13...0x19:
            try charName(b - 0x13, doubled: false, &buf)
        case 0x1A:
            try ramName(CTDialogueROM.charNames, &buf)
        case 0x1B...0x1D:
            let id = mem[CTDialogueROM.party + b - 0x1B]
            try charName(id * 2 & 0xFF, doubled: true, &buf)
        case 0x1E:
            startSub(CTDialogueROM.strNadia, 5)
            try stateSub(&buf)
        case 0x1F:
            let at = CTDialogueROM.itemNames + mem[CTDialogueROM.itemID] * CTDialogueROM.romNameSize + 1
            startSub(at, nameLength(at, most: CTDialogueROM.romNameSize - 1))
            try stateSub(&buf)
        case 0x20:
            try ramName(CTDialogueROM.charNames + 7 * CTDialogueROM.charNameSize, &buf)
        default:
            break
        }
    }

    mutating func glyph0(_ g: Int, _ buf: inout [UInt8]) {
        draw(g, into: &buf)
        status = CTDialogueROM.stepDone
    }

    func nameLength(_ at: Int, most: Int) -> Int {
        var n = 0
        while mem[at + n] != CTDialogueROM.namePad {
            n += 1
            if n >= most { break }
        }
        return n
    }

    mutating func charName(_ index: Int, doubled: Bool, _ buf: inout [UInt8]) throws {
        let x = doubled ? index : index * 2 & 0xFF               // the 8-bit ASL of codes $13-$19
        try ramName(0x7E0000 | mem.word(CTDialogueROM.charNamePtrs + x), &buf)
    }

    mutating func ramName(_ at: Int, _ buf: inout [UInt8]) throws {
        var n = 0
        while mem[at + n] != 0 {
            n += 1
            if n >= CTDialogueROM.charNameMax { break }
        }
        startSub(at, n)
        try stateSub(&buf)
    }

    mutating func number(_ code: Int, _ buf: inout [UInt8]) throws {
        let value = try arg(code - 0x0C)
        if code != 0x0F && mem[CTDialogueROM.numHex] != 0 {
            var glyphs: [Int] = []
            let bytes = code == 0x0D ? [value] : [value >> 8, value & 0xFF]
            for byte in bytes {
                for nib in [byte >> 4, byte & 15] {
                    let g = mem.word(CTDialogueROM.hexGlyphs + 2 * nib)
                    glyphs += g >= 0x100 ? [g >> 8, g & 0xFF] : [g]
                }
            }
            digits = glyphs
            startSub(nil, glyphs.count, state: 3)
            return try stateSub(&buf)
        }
        digits = String(value).compactMap { $0.wholeNumberValue }
        startSub(nil, digits.count, state: 2)
        try stateDec(&buf)
    }

    mutating func subByte() throws -> Int {
        guard let at = sub else {
            guard !digits.isEmpty else { throw CTDialogueError("a number ran out of digits") }
            return digits.removeFirst()
        }
        let b = mem[at]
        sub = (at & 0xFF0000) | (at + 1) & 0xFFFF
        return b
    }

    mutating func stateSub(_ buf: inout [UInt8]) throws {
        var b = try subByte()
        if b == 1 || b == 2 { b = b << 8 | (try subByte()) }
        draw(b, into: &buf)
        subEnd()
    }

    mutating func stateDec(_ buf: inout [UInt8]) throws {
        draw((CTDialogueROM.digit0 + (try subByte())) & 0xFF, into: &buf)
        subEnd()
    }

    mutating func subEnd() {
        left = (left - 1) & 0xFF
        if left == 0 { state = 0 }
        status = CTDialogueROM.stepDone
    }
}

/// Field_Unk1F87 every frame with Field_MsgStep and the NMI's line upload,
/// from the message start (Field_Unk29 = 1) to the window closed (0).
public struct CTDialogueLayout: Sendable {
    public struct Upload: Equatable, Sendable {
        public var frame: Int
        public var line: Int
        public var bytes: [UInt8]
    }

    /// One frame's end state: what the box shows after Field_Unk1F87 ran.
    public struct FrameState: Equatable, Sendable {
        /// Field_Unk29: 1-13, 0 closed.
        public var state: Int
        /// Field_Unk27: the band's half height, 0-40.
        public var open: Int
        public var place: Int
        public var page: Int
        /// Waiting for a key.
        public var keyWait: Bool
    }

    public let settings: CTDialogueSettings
    public private(set) var events: [CTDialogueEvent] = []
    public private(set) var uploads: [Upload] = []
    public private(set) var frames: [FrameState] = []
    public var frameCount: Int { frame }

    private let mem: CTDialogueMemory
    private let text: Int
    private var buf = [UInt8](repeating: 0, count: CTDialogueROM.bufferBytes)
    private var f29 = 1, f26 = 0, f27 = 0, f31 = 0, f34 = 0, f36 = 0
    private var tw: CTTextWin?
    private var frame = 0
    private var hold: Int?
    private var page = 0

    /// Lay out the message at `text` (a 24-bit address in `mem`) to the window closed.
    public init(mem: CTDialogueMemory, text: Int, settings: CTDialogueSettings, maxFrames: Int = 20000) throws {
        var m = mem
        for (k, v) in settings.ram() { m.ram[CTDialogueMemory.canon(k)] = v }
        self.mem = m
        self.text = text
        self.settings = settings
        while f29 != 0 {
            guard frame < maxFrames else { throw CTDialogueError("no end within \(maxFrames) frames") }
            try stepFrame()
        }
    }

    /// Lay out message bytes (glyphs, codes, dictionary bytes) overlaid at $C8:0000 on `rom`.
    public static func bytes(_ message: [UInt8], rom: [UInt8], settings: CTDialogueSettings) throws -> CTDialogueLayout {
        let at = 0xC80000
        guard message.count <= 0x10000 else { throw CTDialogueError("message too long") }
        var mem = CTDialogueMemory(rom: rom)
        for (i, b) in message.enumerated() { mem.ram[at + i] = b }
        return try CTDialogueLayout(mem: mem, text: at, settings: settings)
    }

    /// The message a `TABLE:INDEX` pointer names (16-bit pointers into the table's bank).
    public static func messageAddress(rom: [UInt8], table: Int, index: Int) -> Int {
        let mem = CTDialogueMemory(rom: rom)
        return (table & 0xFF0000) | mem.word(table + 2 * index)
    }

    private mutating func log(_ kind: CTDialogueEvent.Kind, _ value: Int, pen: Int?, width: Int = 0) {
        events.append(CTDialogueEvent(frame: frame, kind: kind, value: value, pen: pen, line: f31, page: page, width: width))
    }

    private mutating func clear() {
        for i in buf.indices { buf[i] = 0 }
    }

    private mutating func press() {
        if f29 == 7 && f34 == CTDialogueROM.swallow {
            if hold == nil { hold = frame }
            if let h = hold, frame - h >= settings.press {
                f34 = 0
                hold = nil
                log(.key, 0, pen: nil)
            }
        }
    }

    private mutating func stepFrame() throws {
        press()
        switch f29 {
        case 1, 8:
            if f29 == 8 { page += 1 }
            clear()
            f29 += 1
            f31 = 0
            f36 = 1
        case 2, 3, 4, 9, 10, 11:
            f29 += 1
            f31 += 1
        case 5:
            if f26 == 0 {
                f26 = settings.place
                f27 = 0
                f31 = 0
                f36 = 0
                tw = CTTextWin(mem: mem, text: text)
            } else {
                var opened = f27 == CTDialogueROM.openSize - 1
                for _ in 0..<4 where !opened {
                    f27 += 1
                    opened = f27 == CTDialogueROM.openSize - 1
                }
                if opened {
                    f29 = 6
                    try msgStep()
                }
            }
        case 6:
            try msgStep()
        case 7:
            wait()
        case 12:
            f29 = 6
            try msgStep()
        case 13:
            // LDA; BEQ, then DEC / BEQ three times and a fourth DEC with no test
            var closed = f27 == 0
            for i in 0..<4 where !closed {
                f27 -= 1
                closed = i < 3 && f27 == 0
            }
            if closed {
                f29 = 0
                f26 = 0
            }
        default:
            break
        }
        if f36 != 0 {
            uploads.append(Upload(frame: frame, line: f31, bytes: buf))
            if f36 & 0x80 != 0 { f36 = 0 }
        }
        frames.append(FrameState(state: f29, open: f27, place: f26 == 0 ? settings.place : f26, page: page,
                                 keyWait: f29 == 7 && f34 == CTDialogueROM.swallow))
        frame += 1
    }

    private mutating func wait() {
        guard f34 != CTDialogueROM.swallow, let s = tw?.status else { return }
        if f34 != 0 {
            f34 -= 1
            return
        }
        if (9...12).contains(s) {
            f29 = 8
        } else if (5...8).contains(s) {
            f29 = f31 == CTDialogueROM.lastLine ? 8 : 6
        } else if s == 3 && tw?.code3 != 0 {
            f29 = 6
        } else {
            f29 = 13
        }
    }

    private mutating func msgStep() throws {
        guard var t = tw else { return }
        var s = t.status
        if s == 0 {
            f36 = 0
            return
        }
        if (9...12).contains(s) {
            f31 = 0
            clear()
        } else if (5...8).contains(s) {
            f31 = f31 == CTDialogueROM.lastLine ? 0 : f31 + 1
            clear()
        } else if s == 3 && t.code3 == 0 {
            f36 = 0
            return
        }
        let before = t.drawn.count
        try t.step(&buf)
        for d in t.drawn[before...] {
            log(d.code ? .code : .glyph, d.value, pen: d.pen, width: d.width)
        }
        t.drawn.removeAll()
        tw = t
        s = t.status
        if s == 0 || s == 11 || s == 12 {
            f34 = CTDialogueROM.swallow
            pageWait()
        } else if s == 9 || s == 10 {
            pageWait()
        } else if s == 7 || s == 8 {
            f34 = CTDialogueROM.swallow
            f29 = 7
            lineEnd()
        } else if s == 5 || s == 6 {
            lineEnd()
        } else if s == 3 {
            if t.code3 == 0 {
                pageWait()
            } else {
                f34 = t.code3 * CTDialogueROM.waitUnit
                f29 = 7
                f36 = 1
            }
        } else {
            f36 = 1
        }
    }

    private mutating func lineEnd() {
        if f31 != CTDialogueROM.lastLine {
            f36 = 1
        } else {
            pageWait()
        }
    }

    private mutating func pageWait() {
        f29 = 7
        f36 = 0x81
    }

    // MARK: Results

    public var glyphs: [CTDialogueEvent] { events.filter { $0.kind == .glyph } }
    public var pageCount: Int { page + 1 }

    /// The last frame of page `n` before the box clears or closes (the page fully drawn).
    public func pageFrame(_ n: Int) -> Int? {
        frames.indices.last { frames[$0].page == n && frames[$0].state != 13 && frames[$0].state != 0 }
    }

    /// Numbers only, as ct_dialogue layout_summary (the CLI's --layout-json and the vectors).
    public struct Summary: Codable, Equatable, Sendable {
        public var frames: Int, glyphs: Int
        public var glyphFrames: [Int], pens: [Int], lines: [Int], keyFrames: [Int], pageCodes: [Int]
        public var uploads: Int
        public var uploadDigest: String
    }

    public var summary: Summary {
        let g = glyphs
        var h = SHA256()
        for u in uploads {
            var head = [UInt8]()
            for i in 0..<4 { head.append(UInt8(u.frame >> (8 * i) & 0xFF)) }
            head.append(UInt8(u.line & 0xFF))
            h.update(data: Data(head + u.bytes))
        }
        let pages = events.filter { $0.kind == .code && (9...12).contains($0.value) }.map(\.frame)
        return Summary(frames: frame, glyphs: g.count, glyphFrames: g.map(\.frame), pens: g.map { $0.pen ?? 0 },
                       lines: g.map(\.line), keyFrames: events.filter { $0.kind == .key }.map(\.frame),
                       pageCodes: pages, uploads: uploads.count, uploadDigest: CTDialogueFont.hex(h.finalize()))
    }

    /// A glyph that runs past the frame's inner edge (x 248) or wraps the 8-bit pen.
    public struct Overflow: Equatable, Sendable {
        public var page: Int, line: Int, frame: Int, glyph: Int, pen: Int, end: Int
        public var wraps: Bool { end > 0xFF }
    }

    public var overflows: [Overflow] {
        glyphs.compactMap { e in
            let pen = e.pen ?? 0
            let end = pen + e.width
            guard end > CTDialogueROM.innerRight else { return nil }
            return Overflow(page: e.page, line: e.line, frame: e.frame, glyph: e.value, pen: pen, end: end)
        }
    }
}
