// PPUParityTests.swift — the Metal PPU must equal the CPU reference renderer
// (ChronoForgeCore.PPUReferenceRenderer) byte for byte: targeted scenes per
// feature, then seeded random frames over the whole supported register space.
import XCTest
import Metal
@testable import ChronoForgeMetal
import ChronoForgeCore

/// SplitMix64: deterministic across platforms and runs.
struct SeededRandom {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    mutating func word() -> UInt16 { UInt16(truncatingIfNeeded: next()) }
    mutating func chance(_ percent: Int) -> Bool { int(100) < percent }
}

enum ParityScenes {
    static func solid(_ i: UInt8) -> [UInt8] { [UInt8](repeating: i, count: 64) }

    /// A diagonal-gradient tile: index (row + col) % (colors - 1) + 1, with a
    /// transparent first column so lower layers show through.
    static func pattern(_ colors: Int) -> [UInt8] {
        (0..<64).map { i in i % 8 == 0 ? 0 : UInt8((i / 8 + i % 8) % (colors - 1) + 1) }
    }

    /// Mode 1 scene: BG1-3 with distinct patterns, flips, priorities and
    /// palettes; 16 OBJs of mixed sizes and priorities.
    static func layered() -> PPUFrame {
        var r = PPURegisters()
        r.bgmode = 0x01
        r.bg[0] = PPUBGRegisters(sc: 0x00, charBase: 1, hofs: 3, vofs: 5)
        r.bg[1] = PPUBGRegisters(sc: 0x05, charBase: 1, hofs: 100, vofs: 1000)
        r.bg[2] = PPUBGRegisters(sc: 0x0A, charBase: 2, hofs: 7, vofs: 0)
        r.obsel = 0x02
        r.tm = 0x17; r.ts = 0x13
        var f = PPUFrame(registers: r)
        for i in 0..<256 { f.cgram[i] = UInt16(truncatingIfNeeded: i &* 0x2F1B) & 0x7FFF }
        f.storeTiles(solid(0) + pattern(16) + pattern(8) + solid(5), bpp: 4, atWord: 0x1000)
        f.storeTiles(solid(0) + pattern(4) + solid(2) + pattern(3), bpp: 2, atWord: 0x2000)
        f.storeTiles(solid(0) + pattern(16) + solid(9) + pattern(5), bpp: 4, atWord: 0x4000)
        for i in 0..<1024 {
            f.vram[0x0000 + i] = PPUFrame.tilemapEntry(tile: 1 + i % 3, palette: i % 8, priority: i % 5 == 0,
                                                       hflip: i % 3 == 0, vflip: i % 7 == 0)
            f.vram[0x0400 + i] = PPUFrame.tilemapEntry(tile: (i / 3) % 4, palette: (i / 2) % 8,
                                                       priority: i % 4 == 1, hflip: i % 2 == 0)
            f.vram[0x0800 + i] = PPUFrame.tilemapEntry(tile: (i * 7) % 4, palette: i % 8,
                                                       priority: i % 6 < 2, vflip: i % 2 == 1)
            f.vram[0x0C00 + i] = PPUFrame.tilemapEntry(tile: 3 - i % 4, palette: 7 - i % 8)
        }
        for i in 0..<16 {
            f.setOBJ(i, x: i * 17 - 10, y: i * 13, tile: 1 + i % 3, palette: i % 8, priority: i % 4,
                     hflip: i % 2 == 1, vflip: i % 3 == 1, large: i % 4 == 2)
        }
        return f
    }
}

@MainActor
final class PPUParityTests: XCTestCase {
    func renderer() throws -> PPURenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        return try PPURenderer(device: device)
    }

    func assertParity(_ r: PPURenderer, _ f: PPUFrame, _ label: String,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let cpu = PPUReferenceRenderer.render(f)
        let gpu = try r.render(f)
        XCTAssertEqual(cpu.count, gpu.count, label, file: file, line: line)
        guard cpu != gpu else { return }
        var diffs = 0
        var first = ""
        for p in 0..<(cpu.count / 4) where cpu[p * 4..<p * 4 + 4] != gpu[p * 4..<p * 4 + 4] {
            if diffs == 0 {
                first = "(\(p % 256), \(p / 256)) cpu \(Array(cpu[p * 4..<p * 4 + 4])) gpu \(Array(gpu[p * 4..<p * 4 + 4]))"
            }
            diffs += 1
        }
        XCTFail("\(label): \(diffs) pixels differ, first at \(first)", file: file, line: line)
    }

    func testParityLayeredScene() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        try assertParity(r, f, "mode 1")
        f.setAllLines { $0.bgmode = 0x09 }
        try assertParity(r, f, "mode 1, BG3 priority")
        f.setAllLines { $0.bgmode = 0x00; $0.tm = 0x1F; $0.ts = 0x0F }
        try assertParity(r, f, "mode 0")
        f.setAllLines { $0.bgmode = 0xF1 }
        try assertParity(r, f, "16x16 tiles")
        f.setAllLines { $0.bgmode = 0x03 }
        try assertParity(r, f, "mode 3: OBJ and backdrop only")
    }

    func testParityColorMath() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        // Every CGWSEL region/addend and CGADSUB combination, one per line.
        for line in 0..<224 {
            let combo = line
            f.lines[line].cgwsel = UInt8((combo & 0x0F) << 4) | (combo & 0x10 != 0 ? 0x02 : 0)
            f.lines[line].cgadsub = UInt8(truncatingIfNeeded: combo &* 0x9D) | UInt8(((combo >> 5) & 3) << 6)
            f.lines[line].fixedColor = BGR555(word: UInt16(truncatingIfNeeded: combo &* 0x1357))
        }
        try assertParity(r, f, "color math per line")
        f.setAllLines { $0.ts = 0 }
        try assertParity(r, f, "color math, empty sub screen")
    }

    func testParityPerLineScrollModeAndBrightness() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        for line in 0..<224 {
            f.lines[line].bg[0].hofs = UInt16((line * 3) & 0x3FF)
            f.lines[line].bg[1].vofs = UInt16((1000 - line * 5) & 0x3FF)
            f.lines[line].bg[2].hofs = UInt16((line * line) & 0x3FF)
            f.lines[line].bgmode = [0x01, 0x09, 0x00, 0x11][line % 4]
            f.lines[line].inidisp = line % 37 == 0 ? 0x80 : UInt8(line % 16)
            f.lines[line].objFirst = UInt8(line % 128)
        }
        try assertParity(r, f, "per-line registers")
    }

    func testParityOBJLimits() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        f.setAllLines { $0.obsel = 0x42; $0.tm = 0x11 }   // 8x8 / 64x64
        for i in 0..<128 {
            f.setOBJ(i, x: (i * 29) % 300 - 40, y: (i * 11) % 240, tile: (i * 5) % 4, palette: i % 8,
                     priority: (i / 3) % 4, hflip: i % 5 == 0, vflip: i % 2 == 0, large: i % 6 == 0)
        }
        f.setOBJ(3, x: -256, y: 20, tile: 1, large: true)
        try assertParity(r, f, "range and time over")
        for obsel: UInt8 in [0xA2, 0xC2, 0xE2, 0x7A] {
            f.setAllLines { $0.obsel = obsel }
            try assertParity(r, f, "OBSEL \(String(obsel, radix: 16))")
        }
    }

    func testParity239Lines() throws {
        let r = try renderer()
        let base = ParityScenes.layered()
        var f = PPUFrame(height: 239, registers: base.lines[0])
        f.vram = base.vram; f.cgram = base.cgram; f.oam = base.oam
        try assertParity(r, f, "239 lines")
    }

    func testParityRandomFrames() throws {
        let r = try renderer()
        for seed in 1...8 as ClosedRange<UInt64> {
            var rng = SeededRandom(state: seed)
            var base = PPURegisters()
            var f = PPUFrame(height: rng.chance(25) ? 239 : 224)
            // Sparse bits so transparency and every layer show up.
            for i in 0..<PPUFrame.vramWords { f.vram[i] = rng.word() & rng.word() }
            for i in 0..<256 { f.cgram[i] = rng.word() }   // bit 15 must be ignored
            for i in 0..<PPUFrame.oamBytes { f.oam[i] = rng.byte() }
            func randomize(_ r: inout PPURegisters, all: Bool) {
                if all || rng.chance(10) { r.bgmode = [0x00, 0x01, 0x09, 0x03][rng.int(4)] | (rng.byte() & 0xF0) }
                for n in 0..<4 {
                    if all || rng.chance(30) { r.bg[n].hofs = UInt16(rng.int(1024)); r.bg[n].vofs = UInt16(rng.int(1024)) }
                    if all || rng.chance(3) { r.bg[n].sc = rng.byte(); r.bg[n].charBase = UInt8(rng.int(16)) }
                }
                if all || rng.chance(10) { r.tm = rng.byte() & 0x1F; r.ts = rng.byte() & 0x1F }
                if all || rng.chance(20) { r.cgwsel = rng.byte(); r.cgadsub = rng.byte() }
                if all || rng.chance(20) { r.writeCOLDATA(rng.byte()) }
                if all || rng.chance(5) { r.obsel = rng.byte(); r.objFirst = rng.chance(50) ? 0 : UInt8(rng.int(128)) }
                if all || rng.chance(5) { r.inidisp = rng.chance(10) ? 0x80 : UInt8(rng.int(16)) | (rng.chance(80) ? 0x0F : 0) }
            }
            randomize(&base, all: true)
            for line in 0..<f.height {
                randomize(&base, all: false)
                f.lines[line] = base
            }
            try assertParity(r, f, "seed \(seed)")
        }
    }

    func testPaletteCyclingRewritesOnlyTheLUT() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        let before = try r.render(f)
        let vramUploads = r.vramUploads, paletteUploads = r.paletteUploads
        // Rotate colours 1-15 of every BG palette, as a palette-cycling effect does.
        for p in 0..<8 {
            let row = Array(f.cgram[p * 16 + 1..<p * 16 + 16])
            for i in 0..<15 { f.cgram[p * 16 + 1 + i] = row[(i + 1) % 15] }
        }
        try assertParity(r, f, "after cycling")
        XCTAssertEqual(r.vramUploads, vramUploads, "palette change re-uploaded VRAM")
        XCTAssertEqual(r.paletteUploads, paletteUploads + 1)
        XCTAssertNotEqual(try r.render(f), before)
        XCTAssertEqual(r.paletteUploads, paletteUploads + 1, "unchanged frame uploads nothing")
    }
}
