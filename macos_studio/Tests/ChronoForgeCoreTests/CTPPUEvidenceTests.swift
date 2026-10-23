// CTPPUEvidenceTests.swift — Chrono Trigger's own use of a slice 2 PPU
// feature, from ChronoRET's disassembly: C2Scene_SwirlInit ($C2:6F92)
// points HDMA channels 2-5 at M7A, M7D, M7B and M7C, one word per line, and
// fills the tables from the ROM's sine table ($C0:F900) with M7A = M7D =
// cos(a), M7B = M7C = sin(a + 80h), a + 4 per line. These tests read the
// local ROM (they skip without it), build a frame from those per-line
// registers over synthetic VRAM, and check structural invariants. No ROM
// pixel is used.
import XCTest
@testable import ChronoForgeCore

final class CTPPUEvidenceTests: XCTestCase {
    static let swirlInit = 0x02_6F92, swirlInitBytes = 245
    static let sineTable = 0x00_F900

    /// The routine's HDMA setup: LDY #(BBAD << 8 | indirect | one register
    /// twice), STY DMAPn, for M7A/ch2, M7D/ch5, M7B/ch3, M7C/ch4; then JSL
    /// Trig_Cos1024 and Trig_Sin1024 ($C2:225A / $C2:225E).
    func testSwirlProgramsHDMAForAPerLineMode7Matrix() throws {
        let rom = [UInt8](try Repo.romData())
        let routine = Array(rom[Self.swirlInit..<Self.swirlInit + Self.swirlInitBytes])
        func contains(_ pattern: [UInt8]) -> Bool {
            guard routine.count >= pattern.count else { return false }
            for i in 0...(routine.count - pattern.count) where Array(routine[i..<i + pattern.count]) == pattern { return true }
            return false
        }
        let channels: [(bbad: UInt8, dmap: UInt8)] = [(0x1B, 0x20), (0x1E, 0x50), (0x1C, 0x30), (0x1D, 0x40)]
        for c in channels {
            XCTAssertTrue(contains([0xA0, 0x42, c.bbad, 0x8C, c.dmap, 0x43]), "HDMA to $21\(String(c.bbad, radix: 16))")
        }
        XCTAssertTrue(contains([0x22, 0x5A, 0x22, 0xC2]), "JSL Trig_Cos1024")
        XCTAssertTrue(contains([0x22, 0x5E, 0x22, 0xC2]), "JSL Trig_Sin1024")
    }

    /// Trig_Sin1024: the table's byte, negated for the second half turn.
    static func sine(_ table: [UInt8], _ angle: Int) -> Int {
        let index = angle & 0x3FF
        let v = Int(table[index])
        return index >= 0x200 ? -v : v
    }

    func testSwirlFrameFromTheROMSineTable() throws {
        let rom = [UInt8](try Repo.romData())
        let table = Array(rom[Self.sineTable..<Self.sineTable + 1024])
        XCTAssertEqual([table[0], table[0x100], table[0x200]], [0, 0xFF, 0], "sin 0, 90 and 180 degrees")

        // The frame: mode 7 over a synthetic map whose every pixel is 1 + its
        // column in the tile, with the swirl's matrix on each line (angle 0 at line 0).
        var r = PPURegisters()
        r.bgmode = 0x07
        r.tm = 0x01
        var f = PPUFrame(registers: r)
        for i in 0..<256 { f.cgram[i] = UInt16(i) }
        var tile = [UInt8](repeating: 0, count: 64)
        for i in 0..<64 { tile[i] = UInt8(1 + i % 8) }
        f.storeMode7Tiles(tile)
        for line in 0..<224 {
            let a = line * 4
            let cos = Int16(Self.sine(table, a + 0x100)), sin = Int16(Self.sine(table, a + 0x80))
            f.lines[line].m7a = cos; f.lines[line].m7d = cos
            f.lines[line].m7b = sin; f.lines[line].m7c = sin
        }
        // Invariants of the game's registers: |value| <= 255 (about 1.0 in
        // 8.8), A = D and B = C, and 224 lines x 4 steps cross a half turn, so
        // A < 0 (the map is mirrored) exactly on lines 65-191.
        for (line, l) in f.lines.enumerated() {
            XCTAssertLessThanOrEqual(abs(Int(l.m7a)), 255)
            XCTAssertEqual(l.m7a, l.m7d)
            XCTAssertEqual(l.m7b, l.m7c)
            XCTAssertEqual(l.m7a < 0, (65...191).contains(line), "line \(line)")
        }
        // The picture: every pixel is drawn (screen over 0 wraps), and along
        // a line with |A| near 1 the tile column steps by +1 where A > 0 and
        // by -1 where A < 0.
        let out = PPUReferenceRenderer.render(f)
        var checked = 0
        for line in 0..<224 where abs(Int(f.lines[line].m7a)) >= 240 {
            var up = 0, down = 0
            for x in 0..<255 {
                let a = Int(out.word(x, line)), b = Int(out.word(x + 1, line))
                XCTAssertNotEqual(a, 0, "pixel (\(x), \(line)) drawn")
                let step = (b - a + 8) % 8
                if step == 1 { up += 1 } else if step == 7 { down += 1 }
            }
            if f.lines[line].m7a > 0 { XCTAssertGreaterThan(up, 200, "line \(line)") } else { XCTAssertGreaterThan(down, 200, "line \(line)") }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 40)
    }
}
