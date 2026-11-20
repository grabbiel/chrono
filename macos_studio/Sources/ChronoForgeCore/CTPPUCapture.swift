// CTPPUCapture.swift — Chrono Trigger frames built from the register writes the
// game makes. re_workspace/tools/ct_ppu_frames.py runs the ROM's own routines
// (the battle's NMI set-up, the bank $C3 module's title and Lavos programs) in
// ChronoRET's 65816 interpreter and writes a capture: the registers of every
// visible line, the HDMA channels with their tables, the HDMA and IRQ writes
// per line and the VRAM, CGRAM and OAM images. This file reads a capture and
// builds a `PPUFrame` from it. Captures are made at run time from the ROM
// (`CTPPUCapture.run`) and are never stored in the repository; docs/ppu.md,
// "CT frames", lists the routines, tables and invariants.
import Foundation

// MARK: - The write ports

/// PPURegisters as the CPU write ports $2100-$2133 leave them: the shared
/// BG scroll latch, the mode-7 latch and OAMADD. The rules are the ones
/// ct_ppu_frames.Registers uses (fullsnes "SNES PPU BG Control",
/// "Rotation/Scaling"; SNESdev Wiki PPU registers):
/// - BGnHOFS = value << 8 | (latch & ~7) | (old >> 8 & 7), BGnVOFS = value << 8 |
///   latch; both set the latch. BG1HOFS/BG1VOFS also write M7HOFS/M7VOFS.
/// - M7A-M7D, M7X, M7Y, M7HOFS, M7VOFS = value << 8 | the mode-7 latch.
/// - OAMADDH bit 7 turns on the OBJ priority rotation from OBJ (OAMADD >> 1) & 127.
public struct PPURegisterPorts: Equatable, Sendable {
    public var registers: PPURegisters
    public var bgLatch: UInt8 = 0
    public var m7Latch: UInt8 = 0
    public var oamadd: UInt16 = 0

    public init(registers: PPURegisters = PPURegisters(), bgLatch: UInt8 = 0, m7Latch: UInt8 = 0, oamadd: UInt16 = 0) {
        self.registers = registers
        self.bgLatch = bgLatch
        self.m7Latch = m7Latch
        self.oamadd = oamadd
    }

    static func signed13(_ v: Int) -> Int16 {
        let low = v & 0x1FFF
        return Int16(low >= 0x1000 ? low - 0x2000 : low)
    }

    func latched(_ value: UInt8) -> Int {
        Int(value) << 8 | Int(m7Latch)
    }

    /// One CPU or HDMA write to a register port. Memory ports are ignored.
    public mutating func write(port: Int, value: UInt8) {
        var r = registers
        switch port {
        case 0x2100: r.inidisp = value
        case 0x2101: r.obsel = value
        case 0x2102, 0x2103:
            if port == 0x2102 {
                oamadd = oamadd & 0xFF00 | UInt16(value)
            } else {
                oamadd = oamadd & 0x00FF | UInt16(value) << 8
            }
            r.objFirst = oamadd & 0x8000 != 0 ? UInt8((oamadd >> 1) & 0x7F) : 0
        case 0x2105: r.bgmode = value
        case 0x2106: r.mosaic = value
        case 0x2107...0x210A: r.bg[port - 0x2107].sc = value
        case 0x210B: r.writeBG12NBA(value)
        case 0x210C: r.writeBG34NBA(value)
        case 0x210D...0x2114:
            let n = (port - 0x210D) >> 1
            let high = Int(value) << 8
            if port & 1 == 1 {
                let fine = Int(r.bg[n].hofs) >> 8 & 7
                let coarse = Int(bgLatch) & 0xF8
                r.bg[n].hofs = UInt16((high | coarse | fine) & 0x3FF)
            } else {
                r.bg[n].vofs = UInt16((high | Int(bgLatch)) & 0x3FF)
            }
            bgLatch = value
            if port == 0x210D || port == 0x210E {
                let v = Self.signed13(latched(value))
                if port == 0x210D { r.m7hofs = v } else { r.m7vofs = v }
                m7Latch = value
            }
        case 0x211A: r.m7sel = value
        case 0x211B...0x211E:
            let v = Int16(truncatingIfNeeded: latched(value))
            switch port {
            case 0x211B: r.m7a = v
            case 0x211C: r.m7b = v
            case 0x211D: r.m7c = v
            default: r.m7d = v
            }
            m7Latch = value
        case 0x211F, 0x2120:
            let v = Self.signed13(latched(value))
            if port == 0x211F { r.m7x = v } else { r.m7y = v }
            m7Latch = value
        case 0x2123: r.w12sel = value
        case 0x2124: r.w34sel = value
        case 0x2125: r.wobjsel = value
        case 0x2126: r.wh0 = value
        case 0x2127: r.wh1 = value
        case 0x2128: r.wh2 = value
        case 0x2129: r.wh3 = value
        case 0x212A: r.wbglog = value
        case 0x212B: r.wobjlog = value
        case 0x212C: r.tm = value
        case 0x212D: r.ts = value
        case 0x212E: r.tmw = value
        case 0x212F: r.tsw = value
        case 0x2130: r.cgwsel = value
        case 0x2131: r.cgadsub = value
        case 0x2132: r.writeCOLDATA(value)
        case 0x2133: r.setini = value
        default: break
        }
        registers = r
    }
}

// MARK: - A capture

public struct CTPPUCapture: Sendable {
    /// The frames ct_ppu_frames.py captures.
    public enum Kind: String, CaseIterable, Sendable, Identifiable {
        case battle, title, lavos
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .battle: return "Battle (HDMA set 8)"
            case .title: return "Title (offset-per-tile)"
            case .lavos: return "Lavos (interlace, mode 7)"
            }
        }
    }

    /// One register write: `line` is nil for a write made before the frame
    /// (vertical blank), else the visible line it takes effect on.
    public struct Write: Equatable, Sendable {
        public var line: Int?
        public var port: Int
        public var value: UInt8
        public init(line: Int?, port: Int, value: UInt8) {
            self.line = line; self.port = port; self.value = value
        }
    }

    /// One entry of an HDMA table: its count byte, the lines it covers, and
    /// the bytes of each transfer (one unit, or one per line when it repeats).
    public struct Entry: Equatable, Sendable {
        public var count: Int
        public var lines: Int
        public var repeats: Bool
        public var address: Int
        public var data: [[UInt8]]
    }

    /// One HDMA channel as HDMAEN found it: DMAP, the B-bus register, the table.
    public struct Channel: Equatable, Sendable {
        public var channel: Int
        public var dmap: Int
        public var bbad: Int
        public var table: Int
        public var indirectBank: Int
        public var entries: [Entry]
        public var indirect: Bool { dmap & 0x40 != 0 }
        /// The B-bus offsets of one transfer unit (DMAP bits 0-2).
        public var pattern: [Int] { CTPPUCapture.patterns[dmap & 7] }
    }

    public static let format = "chronoforge.ppu-capture"
    public static let lineCount = 224
    static let patterns: [[Int]] = [[0], [0, 1], [0, 0], [0, 0, 1, 1], [0, 1, 2, 3], [0, 1, 0, 1], [0, 0], [0, 0, 1, 1]]

    public var kind: Kind
    /// The routines run, in order.
    public var runs: [String]
    /// Numbers that identify the run: location, hdmaSet, program, moduleFrames, mode2Frame.
    public var meta: [String: Int]
    /// The V-count IRQ's visible line, and the writes made before the frame and by the IRQ.
    public var irqLine: Int
    public var vblank: [Write]
    public var irq: [Write]
    public var channels: [Channel]
    /// The HDMA writes of each visible line, channel 0 first.
    public var hdma: [Write]
    /// The ports as the frame starts (after the vertical blank's writes).
    public var start: PPURegisterPorts
    /// Each visible line's registers, as the capture tool computed them.
    public var lines: [PPURegisters]
    public var vram: [UInt16]
    public var cgram: [UInt16]
    public var oam: [UInt8]

    public enum CaptureError: Error, CustomStringConvertible {
        case format(String)
        case tool(String)
        public var description: String {
            switch self {
            case .format(let s): return "not a PPU capture: \(s)"
            case .tool(let s): return "ct_ppu_frames.py: \(s)"
            }
        }
    }

    // MARK: Decoding

    struct BGJSON: Decodable { var sc: Int, charBase: Int, hofs: Int, vofs: Int }
    struct RegistersJSON: Decodable {
        var inidisp: Int, obsel: Int, objFirst: Int, bgmode: Int, mosaic: Int, m7sel: Int
        var m7a: Int, m7b: Int, m7c: Int, m7d: Int, m7x: Int, m7y: Int, m7hofs: Int, m7vofs: Int
        var w12sel: Int, w34sel: Int, wobjsel: Int, wh0: Int, wh1: Int, wh2: Int, wh3: Int
        var wbglog: Int, wobjlog: Int, tm: Int, ts: Int, tmw: Int, tsw: Int, cgwsel: Int, cgadsub: Int
        var fixedColor: Int, setini: Int
        var bg: [BGJSON]

        var registers: PPURegisters {
            var r = PPURegisters()
            r.inidisp = UInt8(inidisp & 0xFF); r.obsel = UInt8(obsel & 0xFF); r.objFirst = UInt8(objFirst & 0x7F)
            r.bgmode = UInt8(bgmode & 0xFF); r.mosaic = UInt8(mosaic & 0xFF); r.m7sel = UInt8(m7sel & 0xFF)
            r.m7a = Int16(truncatingIfNeeded: m7a); r.m7b = Int16(truncatingIfNeeded: m7b)
            r.m7c = Int16(truncatingIfNeeded: m7c); r.m7d = Int16(truncatingIfNeeded: m7d)
            r.m7x = Int16(truncatingIfNeeded: m7x); r.m7y = Int16(truncatingIfNeeded: m7y)
            r.m7hofs = Int16(truncatingIfNeeded: m7hofs); r.m7vofs = Int16(truncatingIfNeeded: m7vofs)
            r.w12sel = UInt8(w12sel & 0xFF); r.w34sel = UInt8(w34sel & 0xFF); r.wobjsel = UInt8(wobjsel & 0xFF)
            r.wh0 = UInt8(wh0 & 0xFF); r.wh1 = UInt8(wh1 & 0xFF); r.wh2 = UInt8(wh2 & 0xFF); r.wh3 = UInt8(wh3 & 0xFF)
            r.wbglog = UInt8(wbglog & 0xFF); r.wobjlog = UInt8(wobjlog & 0xFF)
            r.tm = UInt8(tm & 0xFF); r.ts = UInt8(ts & 0xFF); r.tmw = UInt8(tmw & 0xFF); r.tsw = UInt8(tsw & 0xFF)
            r.cgwsel = UInt8(cgwsel & 0xFF); r.cgadsub = UInt8(cgadsub & 0xFF)
            r.fixedColor = BGR555(word: UInt16(fixedColor & 0x7FFF)); r.setini = UInt8(setini & 0xFF)
            for (i, b) in bg.prefix(4).enumerated() {
                r.bg[i] = PPUBGRegisters(sc: UInt8(b.sc & 0xFF), charBase: UInt8(b.charBase & 15),
                                         hofs: UInt16(b.hofs & 0x3FF), vofs: UInt16(b.vofs & 0x3FF))
            }
            return r
        }
    }
    struct StartJSON: Decodable { var registers: RegistersJSON, bgLatch: Int, m7Latch: Int, oamadd: Int }
    struct EntryJSON: Decodable { var count: Int, lines: Int, `repeat`: Bool, address: Int, data: [[Int]] }
    struct ChannelJSON: Decodable {
        var channel: Int, dmap: Int, bbad: Int, table: Int, indirectBank: Int
        var entries: [EntryJSON]
    }
    struct FileJSON: Decodable {
        var format: String, version: Int, frame: String, runs: [String]
        var location: Int?, hdmaSet: Int?, program: Int?, moduleFrames: Int?, mode2Frame: Int?
        var irqLine: Int
        var start: StartJSON
        var vblank: [[Int]], irq: [[Int]], hdma: [[Int]]
        var channels: [ChannelJSON]
        var lines: [RegistersJSON]
        var vram: String, cgram: String, oam: String
    }

    static func write(_ a: [Int], hasLine: Bool) -> Write {
        if hasLine { return Write(line: a[0], port: a[1], value: UInt8(a[2] & 0xFF)) }
        return Write(line: nil, port: a[0], value: UInt8(a[1] & 0xFF))
    }

    /// Captures can also be supplied with --capture. Check their shape before
    /// indexing transfer units or replaying writes; malformed files must throw.
    static func validate(_ f: FileJSON) throws {
        guard (0...lineCount).contains(f.irqLine), f.start.registers.bg.count == 4,
              f.lines.allSatisfy({ $0.bg.count == 4 }) else {
            throw CaptureError.format("line or background register shape")
        }
        for (writes, hasLine) in [(f.vblank, false), (f.irq, true), (f.hdma, true)] {
            var previousLine = -1
            for w in writes {
                let offset = hasLine ? 1 : 0
                guard w.count == offset + 2 else { throw CaptureError.format("register write shape") }
                guard (0...0xFFFF).contains(w[offset]), (0...255).contains(w[offset + 1]) else {
                    throw CaptureError.format("register write value")
                }
                if hasLine {
                    guard (0..<lineCount).contains(w[0]), w[0] >= previousLine else {
                        throw CaptureError.format("register writes out of scanline order")
                    }
                    previousLine = w[0]
                }
            }
        }
        var seen: Set<Int> = []
        for c in f.channels {
            guard (0..<8).contains(c.channel), seen.insert(c.channel).inserted,
                  (0...255).contains(c.dmap), (0x2100...0x21FF).contains(c.bbad) else {
                throw CaptureError.format("HDMA channel")
            }
            let width = patterns[c.dmap & 7].count
            for e in c.entries {
                let count = e.count & 0x7F
                let lines = count == 0 ? 128 : count
                let repeats = e.count > 0x80
                let units = repeats ? lines : 1
                guard (1...255).contains(e.count), e.lines == lines, e.repeat == repeats,
                      e.data.count == units,
                      e.data.allSatisfy({ $0.count == width && $0.allSatisfy({ (0...255).contains($0) }) }) else {
                    throw CaptureError.format("HDMA entry shape")
                }
            }
        }
    }

    static func words(_ base64: String, count: Int) throws -> [UInt16] {
        guard let d = Data(base64Encoded: base64), d.count == count * 2 else { throw CaptureError.format("memory size") }
        let b = [UInt8](d)
        var out = [UInt16](repeating: 0, count: count)
        for i in 0..<count { out[i] = UInt16(b[i * 2]) | UInt16(b[i * 2 + 1]) << 8 }
        return out
    }

    /// Read a capture (the JSON ct_ppu_frames.py writes).
    public static func decode(_ data: Data) throws -> CTPPUCapture {
        let f = try JSONDecoder().decode(FileJSON.self, from: data)
        guard f.format == format, f.version == 1 else { throw CaptureError.format("\(f.format) v\(f.version)") }
        guard let kind = Kind(rawValue: f.frame) else { throw CaptureError.format("frame \(f.frame)") }
        guard f.lines.count == lineCount else { throw CaptureError.format("\(f.lines.count) lines") }
        try validate(f)
        guard let oamData = Data(base64Encoded: f.oam), oamData.count == PPUFrame.oamBytes else {
            throw CaptureError.format("OAM size")
        }
        var meta: [String: Int] = [:]
        meta["location"] = f.location; meta["hdmaSet"] = f.hdmaSet; meta["program"] = f.program
        meta["moduleFrames"] = f.moduleFrames; meta["mode2Frame"] = f.mode2Frame
        var channels: [Channel] = []
        for c in f.channels {
            var entries: [Entry] = []
            for e in c.entries {
                let data: [[UInt8]] = e.data.map { (unit: [Int]) -> [UInt8] in unit.map { UInt8($0 & 0xFF) } }
                entries.append(Entry(count: e.count, lines: e.lines, repeats: e.repeat, address: e.address, data: data))
            }
            channels.append(Channel(channel: c.channel, dmap: c.dmap, bbad: c.bbad, table: c.table,
                                    indirectBank: c.indirectBank, entries: entries))
        }
        let start = PPURegisterPorts(registers: f.start.registers.registers, bgLatch: UInt8(f.start.bgLatch & 0xFF),
                                     m7Latch: UInt8(f.start.m7Latch & 0xFF), oamadd: UInt16(f.start.oamadd & 0xFFFF))
        let capture = CTPPUCapture(
            kind: kind, runs: f.runs, meta: meta, irqLine: f.irqLine,
            vblank: f.vblank.map { write($0, hasLine: false) },
            irq: f.irq.map { write($0, hasLine: true) },
            channels: channels,
            hdma: f.hdma.map { write($0, hasLine: true) },
            start: start,
            lines: f.lines.map { $0.registers },
            vram: try words(f.vram, count: PPUFrame.vramWords),
            cgram: try words(f.cgram, count: 256),
            oam: [UInt8](oamData))
        guard expandHDMA(capture.channels, stops: capture.irqStops) == capture.hdma else {
            throw CaptureError.format("HDMA writes disagree with channel tables")
        }
        guard capture.replayLines() == capture.lines else {
            throw CaptureError.format("line registers disagree with replayed writes")
        }
        return capture
    }

    public static func load(from url: URL) throws -> CTPPUCapture {
        try decode(try Data(contentsOf: url))
    }

    // MARK: The frame

    /// The `PPUFrame`: the captured memory and every line's registers. `field`
    /// is the interlace field drawn (the capture does not fix one).
    public func frame(field: Int = 0) -> PPUFrame {
        var f = PPUFrame(height: CTPPUCapture.lineCount)
        f.vram = vram
        f.cgram = cgram
        f.oam = oam
        f.lines = lines
        f.field = field
        return f
    }

    /// The HDMA writes the channels' tables make, line by line, channel 0
    /// first within a line: an entry writes its unit on its first line, or on
    /// every line when it repeats. `stops` ends a channel from a line on (an
    /// IRQ that clears its HDMAEN bit). The Swift twin of ct_ppu_frames.hdma_writes.
    public static func expandHDMA(_ channels: [Channel], lines: Int = lineCount, stops: [Int: Int] = [:]) -> [Write] {
        var perLine = [[Write]](repeating: [], count: lines)
        for c in channels.sorted(by: { $0.channel < $1.channel }) {
            let end = min(lines, stops[c.channel] ?? lines)
            let pattern = c.pattern
            var line = 0
            for e in c.entries {
                for k in 0..<e.lines {
                    let ln = line + k
                    if ln >= end { break }
                    if !(e.repeats || k == 0) { continue }
                    let unit = e.data[e.repeats ? k : 0]
                    for (off, v) in zip(pattern, unit) {
                        let port = 0x2100 | (c.bbad + off) & 0xFF
                        perLine[ln].append(Write(line: ln, port: port, value: v))
                    }
                }
                line += e.lines
            }
        }
        return perLine.flatMap { $0 }
    }

    /// The channels an IRQ write to HDMAEN ($420C) stops, by the line it stops them on.
    public var irqStops: [Int: Int] {
        var out: [Int: Int] = [:]
        for w in irq where w.port == 0x420C {
            guard let line = w.line else { continue }
            for ch in 0..<8 where (Int(w.value) >> ch) & 1 == 0 && out[ch] == nil { out[ch] = line }
        }
        return out
    }

    /// Every line's registers from the frame-start ports, the HDMA writes and
    /// the IRQ's writes (HDMA first within a line), through `PPURegisterPorts`.
    public func replayLines() -> [PPURegisters] {
        var ports = start
        var out: [PPURegisters] = []
        var i = 0, j = 0
        let irqWrites = irq.filter { $0.port < 0x2134 }
        for ln in 0..<CTPPUCapture.lineCount {
            while i < hdma.count, hdma[i].line == ln {
                ports.write(port: hdma[i].port, value: hdma[i].value)
                i += 1
            }
            while j < irqWrites.count, irqWrites[j].line == ln {
                ports.write(port: irqWrites[j].port, value: irqWrites[j].value)
                j += 1
            }
            out.append(ports.registers)
        }
        return out
    }

    // MARK: The listing

    public static let registerNames: [Int: String] = [
        0x2100: "INIDISP", 0x2101: "OBSEL", 0x2102: "OAMADDL", 0x2103: "OAMADDH", 0x2104: "OAMDATA",
        0x2105: "BGMODE", 0x2106: "MOSAIC", 0x2107: "BG1SC", 0x2108: "BG2SC", 0x2109: "BG3SC", 0x210A: "BG4SC",
        0x210B: "BG12NBA", 0x210C: "BG34NBA", 0x210D: "BG1HOFS", 0x210E: "BG1VOFS", 0x210F: "BG2HOFS",
        0x2110: "BG2VOFS", 0x2111: "BG3HOFS", 0x2112: "BG3VOFS", 0x2113: "BG4HOFS", 0x2114: "BG4VOFS",
        0x2115: "VMAIN", 0x2116: "VMADDL", 0x2117: "VMADDH", 0x2118: "VMDATAL", 0x2119: "VMDATAH",
        0x211A: "M7SEL", 0x211B: "M7A", 0x211C: "M7B", 0x211D: "M7C", 0x211E: "M7D", 0x211F: "M7X",
        0x2120: "M7Y", 0x2121: "CGADD", 0x2122: "CGDATA", 0x2123: "W12SEL", 0x2124: "W34SEL",
        0x2125: "WOBJSEL", 0x2126: "WH0", 0x2127: "WH1", 0x2128: "WH2", 0x2129: "WH3", 0x212A: "WBGLOG",
        0x212B: "WOBJLOG", 0x212C: "TM", 0x212D: "TS", 0x212E: "TMW", 0x212F: "TSW", 0x2130: "CGWSEL",
        0x2131: "CGADSUB", 0x2132: "COLDATA", 0x2133: "SETINI", 0x420B: "MDMAEN", 0x420C: "HDMAEN",
    ]

    public static func portName(_ port: Int) -> String {
        registerNames[port] ?? String(format: "$%04X", port)
    }

    static func hex2(_ v: UInt8) -> String { String(format: "$%02X", Int(v)) }

    /// The register and HDMA listing, as text lines (the same shape as `ct_ppu_frames.py show`).
    public func listing() -> [String] {
        var out = ["frame \(kind.rawValue): " + runs.joined(separator: ", ")]
        let numbers = meta.keys.sorted().map { "\($0) \(meta[$0] ?? 0)" }
        if !numbers.isEmpty { out.append(numbers.joined(separator: ", ")) }
        out.append("vblank writes (\(vblank.count)):")
        for w in vblank { out.append("  \(Self.portName(w.port)) = \(Self.hex2(w.value))") }
        for c in channels {
            let mode = c.indirect ? "indirect" : "direct"
            let head = "HDMA channel \(c.channel): \(mode), pattern \(c.dmap & 7), B-bus \(Self.portName(c.bbad)), "
            out.append(head + String(format: "table $%06X", c.table))
            var line = 0
            for e in c.entries {
                let first = (e.data.first ?? []).map { String(format: "%02X", Int($0)) }.joined(separator: " ")
                let range = String(format: "lines %3d-%3d", line, line + e.lines - 1)
                let kindText = e.repeats ? "repeat" : "once"
                let more = e.data.count > 1 ? " ..." : ""
                out.append("  \(range) (\(kindText)) from " + String(format: "$%06X", e.address) + ": \(first)\(more)")
                line += e.lines
            }
        }
        let irqText = irq.map { "\(Self.portName($0.port)) = \(Self.hex2($0.value))" }.joined(separator: ", ")
        out.append("IRQ writes at line \(irqLine): \(irqText)")
        return out
    }

    // MARK: Running the capture tool

    /// re_workspace/tools/ct_ppu_frames.py found upward from `start` (a file or directory).
    public static func locateTool(from start: URL) -> URL? {
        var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
        for _ in 0..<8 {
            let tool = dir.appendingPathComponent("re_workspace/tools/ct_ppu_frames.py")
            if FileManager.default.fileExists(atPath: tool.path) { return tool }
            let inside = dir.appendingPathComponent("tools/ct_ppu_frames.py")
            if FileManager.default.fileExists(atPath: inside.path) { return inside }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The workspace's virtual environment's Python next to the tool, else python3 on the PATH.
    static func python(for tool: URL) -> (URL, [String]) {
        let venv = tool.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".venv/bin/python")
        if FileManager.default.isExecutableFile(atPath: venv.path) { return (venv, []) }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["python3"])
    }

    /// Run `ct_ppu_frames.py capture <kind>` on the ROM and read the result.
    /// It needs the ROM and the ChronoRET checkout the tool uses
    /// (re_workspace/refs/ChronoRET); the capture goes to a temporary file
    /// that is removed afterwards. The title and Lavos runs take 20-40 s.
    public static func run(_ kind: Kind, rom: URL, tool: URL? = nil) throws -> CTPPUCapture {
        guard let script = tool ?? locateTool(from: rom) ?? locateTool(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) else {
            throw CaptureError.tool("re_workspace/tools/ct_ppu_frames.py not found")
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ppu-capture-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: out) }
        let (exe, prefix) = python(for: script)
        let p = Process()
        p.executableURL = exe
        p.arguments = prefix + [script.path, "--rom", rom.path, "capture", kind.rawValue, "--out", out.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        try p.run()
        let message = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(decoding: message, as: UTF8.self).split(separator: "\n").suffix(3).joined(separator: " / ")
            throw CaptureError.tool("exit \(p.terminationStatus): \(text)")
        }
        return try load(from: out)
    }
}
