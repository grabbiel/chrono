// CTPPUFramesTests.swift — Chrono Trigger frames captured at run time from the
// local ROM by re_workspace/tools/ct_ppu_frames.py (ChronoRET's interpreter
// running the game's own routines), read with CTPPUCapture. Structural
// invariants only: each line's registers against the HDMA tables that set
// them, the layers, windows and modes on, the offset-per-tile table, the
// interlace bits. No pixel or table value from the ROM is stored here. The
// tests skip without the ROM or the ChronoRET checkout; the title and Lavos
// captures take 20-40 s each and are made once per run.
import XCTest
@testable import ChronoForgeCore

enum CTFrameCaptures {
    nonisolated(unsafe) static var cache: [CTPPUCapture.Kind: CTPPUCapture] = [:]
    static let lock = NSLock()

    static func capture(_ kind: CTPPUCapture.Kind) throws -> CTPPUCapture {
        _ = try Repo.romData()
        let absint = Repo.root.appendingPathComponent("re_workspace/refs/ChronoRET/tools/absint.py")
        guard FileManager.default.fileExists(atPath: absint.path) else {
            throw XCTSkip("local ChronoRET checkout not present (re_workspace/refs/ChronoRET)")
        }
        lock.lock()
        defer { lock.unlock() }
        if let c = cache[kind] { return c }
        let tool = Repo.root.appendingPathComponent("re_workspace/tools/ct_ppu_frames.py")
        let c = try CTPPUCapture.run(kind, rom: Repo.rom, tool: tool)
        cache[kind] = c
        return c
    }
}

final class CTPPUFramesTests: XCTestCase {
    /// The byte `index` of each line's unit from one channel: the value its
    /// last transfer left (nil before the first and while a channel never ran).
    func perLine(_ c: CTPPUCapture.Channel, _ index: Int) -> [UInt8?] {
        var out = [UInt8?](repeating: nil, count: CTPPUCapture.lineCount)
        var line = 0
        var held: UInt8?
        for e in c.entries {
            for k in 0..<e.lines where line + k < out.count {
                let unit: [UInt8] = e.data[e.repeats ? k : 0]
                if e.repeats || k == 0 { held = unit[index] }
                out[line + k] = held
            }
            line += e.lines
        }
        if line < out.count {
            for i in line..<out.count { out[i] = held }
        }
        return out
    }

    func channel(_ c: CTPPUCapture, _ n: Int) throws -> CTPPUCapture.Channel {
        try XCTUnwrap(c.channels.first { $0.channel == n }, "HDMA channel \(n)")
    }

    func assertCommon(_ c: CTPPUCapture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(c.lines.count, 224, file: file, line: line)
        XCTAssertEqual(CTPPUCapture.expandHDMA(c.channels, stops: c.irqStops), c.hdma,
                       "the HDMA writes follow the tables", file: file, line: line)
        XCTAssertEqual(c.replayLines(), c.lines, "the lines replay through the write ports", file: file, line: line)
        for i in c.irqLine..<224 {
            XCTAssertTrue(c.lines[i].forcedBlank, "line \(i) is blanked by the IRQ", file: file, line: line)
        }
        XCTAssertFalse(c.lines[0].forcedBlank, file: file, line: line)
    }

    // MARK: Battle

    /// BattleCD_NmiSetup: channel 5 indirect, four registers from CGWSEL
    /// (CGWSEL, CGADSUB, COLDATA, SETINI); channel 6 two from BGMODE (BGMODE,
    /// MOSAIC). Every shown line has its table's values.
    func testBattleChannels5And6SetTheirRegistersOnEveryLine() throws {
        let c = try CTFrameCaptures.capture(.battle)
        assertCommon(c)
        let math = try channel(c, 5), mode = try channel(c, 6)
        XCTAssertEqual([math.dmap, math.bbad], [0x44, 0x2130])
        XCTAssertEqual([mode.dmap, mode.bbad], [0x41, 0x2105])
        let cgwsel = perLine(math, 0), cgadsub = perLine(math, 1), setini = perLine(math, 3)
        let bgmode = perLine(mode, 0), mosaic = perLine(mode, 1)
        for i in 0..<c.irqLine {
            let r = c.lines[i]
            XCTAssertEqual(r.cgwsel, cgwsel[i], "CGWSEL line \(i)")
            XCTAssertEqual(r.cgadsub, cgadsub[i], "CGADSUB line \(i)")
            XCTAssertEqual(r.setini, setini[i], "SETINI line \(i)")
            XCTAssertEqual(r.bgmode, bgmode[i], "BGMODE line \(i)")
            XCTAssertEqual(r.mosaic, mosaic[i], "MOSAIC line \(i)")
        }
    }

    /// Channel 4 sets TM, TS, TMW and TSW and channel 7 the window edges
    /// WH0-WH3 on every line; the main screen has layers on.
    func testBattleLayersAndWindowsFollowChannels4And7() throws {
        let c = try CTFrameCaptures.capture(.battle)
        let screens = try channel(c, 4), windows = try channel(c, 7)
        XCTAssertEqual([screens.bbad, windows.bbad], [0x212C, 0x2126])
        let tm = perLine(screens, 0), ts = perLine(screens, 1), tmw = perLine(screens, 2), tsw = perLine(screens, 3)
        let wh = (0..<4).map { (k: Int) -> [UInt8?] in perLine(windows, k) }
        for i in 0..<c.irqLine {
            let r = c.lines[i]
            XCTAssertEqual([r.tm, r.ts, r.tmw, r.tsw], [tm[i], ts[i], tmw[i], tsw[i]].map { $0 ?? 0 }, "line \(i)")
            XCTAssertEqual([r.wh0, r.wh1, r.wh2, r.wh3], wh.map { $0[i] ?? 0 }, "line \(i)")
            XCTAssertNotEqual(r.tm & 0x1F, 0, "line \(i) shows layers")
        }
        XCTAssertEqual(c.irqStops.count, 8, "the IRQ turns every channel off")
    }

    // MARK: Title

    /// Program 2 in mode 2: BG3's map is the offset-per-tile table at VRAM
    /// word $7000. Its first row (horizontal offsets) is unused; its second
    /// row (vertical offsets) has bit 13 (BG1) on every moving column and
    /// changes from column to column (the wave).
    func testTitleIsMode2WithItsOffsetTableAtBG3() throws {
        let c = try CTFrameCaptures.capture(.title)
        assertCommon(c)
        XCTAssertTrue(c.hdma.isEmpty, "the title uses no HDMA")
        for i in 0..<c.irqLine { XCTAssertEqual(c.lines[i].mode, 2, "line \(i)") }
        let bg3 = c.lines[0].bg[2]
        XCTAssertEqual(Int(bg3.sc >> 2) << 10, 0x7000)
        XCTAssertEqual([bg3.hofs, bg3.vofs], [0, 0])
        let rowH = Array(c.vram[0x7000..<0x7020]), rowV = Array(c.vram[0x7020..<0x7040])
        XCTAssertTrue(rowH.allSatisfy { $0 & 0x6000 == 0 }, "no horizontal offsets")
        XCTAssertTrue(rowV.dropFirst().allSatisfy { $0 & 0x2000 != 0 && $0 & 0xC000 == 0 }, "BG1's vertical offsets")
        XCTAssertGreaterThan(Set(rowV.dropFirst().map { $0 & 0x3FF }).count, 4, "the offsets vary by column")
    }

    /// The table moves the picture: the frame drawn with its vertical-offset
    /// row cleared differs from the frame as captured, and only on BG1's
    /// columns from the second one on (column 0 keeps its own scroll).
    func testTitleOffsetsMoveBG1ColumnsFromTheSecond() throws {
        let c = try CTFrameCaptures.capture(.title)
        let f = c.frame()
        var flat = f
        for w in 0x7020..<0x7040 { flat.vram[w] = 0 }
        let a = PPUReferenceRenderer.render(f), b = PPUReferenceRenderer.render(flat)
        XCTAssertNotEqual(a, b, "the offsets change the picture")
        for y in 0..<c.irqLine {
            for x in 0..<8 {
                let p = (y * 256 + x) * 4
                XCTAssertEqual(Array(a[p..<p + 4]), Array(b[p..<p + 4]), "column 0 at (\(x), \(y))")
            }
        }
    }

    // MARK: Lavos

    /// Program 6: SETINI $41 (screen interlace and EXTBG) on every line, the
    /// mode 7 / mode 1 split as channel 4's table writes BGMODE, and the
    /// matrix's A and B per line as channel 1's table gives them.
    func testLavosSetsInterlaceAndEXTBGWithAPerLineMatrix() throws {
        let c = try CTFrameCaptures.capture(.lavos)
        assertCommon(c)
        for r in c.lines { XCTAssertEqual(r.setini, 0x41) }
        let mode = try channel(c, 4), matrix = try channel(c, 1)
        XCTAssertEqual([mode.bbad, matrix.bbad, matrix.dmap & 7], [0x2105, 0x211B, 3])
        let modes = perLine(mode, 0)
        let aLow = perLine(matrix, 0), aHigh = perLine(matrix, 1), bLow = perLine(matrix, 2), bHigh = perLine(matrix, 3)
        var sevens = 0
        for i in 0..<c.irqLine {
            let r = c.lines[i]
            XCTAssertEqual(r.bgmode, modes[i], "BGMODE line \(i)")
            if r.mode == 7 { sevens += 1 }
            guard let al = aLow[i], let ah = aHigh[i], let bl = bLow[i], let bh = bHigh[i] else { continue }
            let a = Int16(bitPattern: UInt16(ah) << 8 | UInt16(al))
            let b = Int16(bitPattern: UInt16(bh) << 8 | UInt16(bl))
            XCTAssertEqual([r.m7a, r.m7b], [a, b], "M7A/M7B line \(i)")
        }
        XCTAssertGreaterThan(sevens, 100, "mode 7 on the plane")
        XCTAssertTrue(c.lines[..<c.irqLine].contains { $0.mode == 1 }, "the mode-1 strip")
        XCTAssertGreaterThan(Set(c.lines[..<c.irqLine].map { $0.m7a }).count, 16, "the matrix changes per line")
    }

    /// Interlace outside modes 5/6, without OBJ interlace, changes only the
    /// field number (docs/ppu.md): both fields draw the same picture.
    func testLavosFieldsDrawTheSamePictureInMode7() throws {
        let c = try CTFrameCaptures.capture(.lavos)
        XCTAssertEqual(c.lines[0].setini & 0x02, 0, "no OBJ interlace")
        let even = PPUReferenceRenderer.render(c.frame(field: 0))
        let odd = PPUReferenceRenderer.render(c.frame(field: 1))
        XCTAssertEqual(even, odd)
        XCTAssertGreaterThan(Set(stride(from: 0, to: even.count, by: 4).map { even[$0] }).count, 8, "a picture, not a blank")
    }
}
