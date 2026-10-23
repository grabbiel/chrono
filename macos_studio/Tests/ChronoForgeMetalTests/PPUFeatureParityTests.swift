// PPUFeatureParityTests.swift — slice 2 features drawn by the Metal PPU and
// the CPU reference renderer, compared byte for byte: mid-frame writes,
// mosaic, modes 2-7, offset-per-tile, direct color, Mode 7/EXTBG, hi-res,
// interlace, the overscan border, then seeded random frames over all of it.
import XCTest
import Metal
@testable import ChronoForgeMetal
import ChronoForgeCore

@MainActor
final class PPUFeatureParityTests: XCTestCase {
    func renderer() throws -> PPURenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        return try PPURenderer(device: device)
    }

    func assertParity(_ r: PPURenderer, _ f: PPUFrame, _ label: String,
                      options: PPURenderOptions = PPURenderOptions(),
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let cpu = PPUReferenceRenderer.renderImage(f, options: options)
        let gpu = try r.renderImage(f, options: options)
        XCTAssertEqual([cpu.width, cpu.height], [gpu.width, gpu.height], label, file: file, line: line)
        guard cpu.rgba != gpu.rgba else { return }
        var diffs = 0
        var first = ""
        for p in 0..<(min(cpu.rgba.count, gpu.rgba.count) / 4) {
            let a = Array(cpu.rgba[p * 4..<p * 4 + 4]), b = Array(gpu.rgba[p * 4..<p * 4 + 4])
            guard a != b else { continue }
            if diffs == 0 { first = "(\(p % cpu.width), \(p / cpu.width)) cpu \(a) gpu \(b)" }
            diffs += 1
        }
        XCTFail("\(label): \(diffs) pixels differ, first at \(first)", file: file, line: line)
    }

    /// Random 8bpp-friendly memory: sparse VRAM bits, CGRAM with bit 15 set at
    /// random (it must be ignored), random OAM.
    func randomMemory(_ f: inout PPUFrame, _ rng: inout SeededRandom) {
        for i in 0..<PPUFrame.vramWords { f.vram[i] = rng.word() & rng.word() }
        for i in 0..<256 { f.cgram[i] = rng.word() }
        for i in 0..<PPUFrame.oamBytes { f.oam[i] = rng.byte() }
    }

    func testParityMidFrameWrites() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        for line in 0..<224 {
            f.writeCGRAM(line: line, index: 0, color: UInt16(line % 32) << 10)
            f.writeCGRAM(line: line, index: 1 + line % 200, color: UInt16(truncatingIfNeeded: line &* 0x1F3))
        }
        for line in stride(from: 10, to: 224, by: 37) {
            for k in 0..<64 { f.writeVRAM(line: line, address: 0x0000 + (line + k) % 1024, word: UInt16(line + k) & 0x3FF | 0x2000) }
            f.writeVRAM(line: line, address: 0x1000 + line % 64, word: UInt16(truncatingIfNeeded: line &* 0x9E37))
            f.writeOAM(line: line, address: (line % 16) * 4 + 1, byte: UInt8(line + 3))
        }
        f.writeVRAM(line: -3, address: 0x0400, word: 0x0001)
        try assertParity(r, f, "CGRAM, VRAM and OAM writes")
        XCTAssertGreaterThan(r.vramSegmentUploads, 0)
        XCTAssertGreaterThan(r.lineCGRAMUploads, 0)
        let vramUploads = r.vramUploads
        var g = ParityScenes.layered()
        g.vram = f.vram; g.cgram = f.cgram
        for line in 0..<224 { g.writeCGRAM(line: line, index: 0, color: UInt16(line % 32)) }
        try assertParity(r, g, "CGRAM gradient only")
        XCTAssertEqual(r.vramUploads, vramUploads, "CGRAM writes upload no VRAM")
    }

    func testParityMosaic() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        for line in 0..<224 { f.lines[line].mosaic = UInt8(((line / 9) % 16) << 4) | UInt8(line % 16) }
        try assertParity(r, f, "per-line mosaic, mode 1")
        f.setAllLines { $0.bgmode = 0x00; $0.tm = 0x1F; $0.ts = 0x0F }
        try assertParity(r, f, "per-line mosaic, mode 0")
    }

    func testParityModes2To6OffsetPerTileAndDirectColor() throws {
        let r = try renderer()
        var rng = SeededRandom(state: 0x5EED)
        var f = PPUFrame()
        randomMemory(&f, &rng)
        // BG3 offset rows with every combination of bits 13-15.
        for i in 0..<0x400 { f.vram[0x0800 + i] = rng.word() & 0xE3FF }
        for mode: UInt8 in [0x02, 0x03, 0x04, 0x05, 0x06] {
            for tiles: UInt8 in [0x00, 0x70] {
                for cgwsel: UInt8 in [0x00, 0x01, 0x03] {
                    f.setAllLines {
                        $0.bgmode = mode | tiles; $0.tm = 0x17; $0.ts = 0x13; $0.cgwsel = cgwsel; $0.cgadsub = 0x43
                        $0.bg[0] = PPUBGRegisters(sc: 0x10, charBase: 2, hofs: 13, vofs: 900)
                        $0.bg[1] = PPUBGRegisters(sc: 0x15, charBase: 4, hofs: 1000, vofs: 7)
                        $0.bg[2] = PPUBGRegisters(sc: 0x0B, charBase: 6, hofs: 37, vofs: 210)
                        $0.obsel = 0x63
                    }
                    for line in 0..<224 { f.lines[line].bg[2].vofs = UInt16((line * 3) & 0x3FF) }
                    try assertParity(r, f, "mode \(mode) tiles \(tiles) cgwsel \(cgwsel)")
                }
            }
        }
    }

    func testParityMode7AndEXTBG() throws {
        let r = try renderer()
        var rng = SeededRandom(state: 7)
        var f = PPUFrame()
        randomMemory(&f, &rng)
        for line in 0..<224 {
            // A perspective-style per-line matrix, as HDMA tables build.
            let scale = Int16(0x80 + line * 3)
            let angle = Double(line) / 50
            var l = f.lines[line]
            l.bgmode = 0x07; l.tm = 0x13; l.ts = 0x02; l.cgadsub = 0x41; l.cgwsel = 0x02
            l.m7a = Int16(Double(scale) * cos(angle)); l.m7b = Int16(Double(scale) * sin(angle))
            l.m7c = Int16(-Double(scale) * sin(angle)); l.m7d = Int16(Double(scale) * cos(angle))
            l.m7x = 0x200; l.m7y = -0x180; l.m7hofs = Int16(line * 5 - 600); l.m7vofs = 0x0FFF
            l.m7sel = UInt8((line / 56) << 6) | UInt8(line & 3)
            l.setini = line % 3 == 0 ? 0 : 0x40
            l.mosaic = line > 150 ? 0x33 : 0
            l.obsel = 0x02
            f.lines[line] = l
        }
        try assertParity(r, f, "mode 7 per-line matrix, screen over, flips, EXTBG")
        f.setAllLines { $0.cgwsel |= 0x01 }
        try assertParity(r, f, "mode 7 direct color")
        f.setAllLines { $0.m7a = Int16.min; $0.m7b = Int16.max; $0.m7c = -1; $0.m7d = 0x7FFF; $0.m7x = Int16.min; $0.m7hofs = -1 }
        try assertParity(r, f, "mode 7 extreme values (13-bit fields use their low bits)")
    }

    func testParityHiresAndInterlace() throws {
        let r = try renderer()
        var f = ParityScenes.layered()
        f.storeTiles(ParityScenes.pattern(16) + ParityScenes.pattern(4), bpp: 4, atWord: 0x1040)
        let wide = PPURenderOptions(), narrow = PPURenderOptions(highResolution: false)
        for mode: UInt8 in [0x05, 0x06, 0x35, 0x16] {
            f.setAllLines { $0.bgmode = mode; $0.tm = 0x13; $0.ts = 0x13; $0.setini = 0 }
            try assertParity(r, f, "mode \(mode), 512", options: wide)
            try assertParity(r, f, "mode \(mode), 256", options: narrow)
            f.setAllLines { $0.ts = 0x02; $0.mosaic = 0x13 }
            try assertParity(r, f, "mode \(mode), sub BG2, mosaic", options: wide)
            f.setAllLines { $0.setini = 0x03; $0.mosaic = 0 }
            for field in 0...1 {
                f.field = field
                try assertParity(r, f, "mode \(mode), interlace field \(field)", options: wide)
            }
            f.field = 0
        }
        // Pseudo 512 on some lines of a mode 1 picture.
        f.setAllLines { $0.bgmode = 0x01; $0.tm = 0x17; $0.ts = 0x13; $0.setini = 0 }
        for line in stride(from: 0, to: 224, by: 3) { f.lines[line].setini = 0x08 }
        try assertParity(r, f, "pseudo 512 lines", options: wide)
        try assertParity(r, f, "pseudo 512, 256 wide", options: narrow)
    }

    func testParityOverscanBorder() throws {
        let r = try renderer()
        let base = ParityScenes.layered()
        try assertParity(r, base, "224 lines in the border", options: PPURenderOptions(overscanBorder: true))
        var tall = PPUFrame(height: 239, registers: base.lines[0])
        tall.vram = base.vram; tall.cgram = base.cgram; tall.oam = base.oam
        tall.setAllLines { $0.setini = 0x0C }
        try assertParity(r, tall, "239 lines, pseudo 512, border", options: PPURenderOptions(overscanBorder: true))
    }

    func testParityRandomFeatureFrames() throws {
        let r = try renderer()
        for seed in 101...112 as ClosedRange<UInt64> {
            var rng = SeededRandom(state: seed)
            var base = PPURegisters()
            var f = PPUFrame(height: rng.chance(25) ? 239 : 224)
            randomMemory(&f, &rng)
            f.field = rng.int(2)
            func randomize(_ r: inout PPURegisters, all: Bool) {
                if all || rng.chance(8) { r.bgmode = rng.byte() }
                for n in 0..<4 {
                    if all || rng.chance(30) { r.bg[n].hofs = UInt16(rng.int(1024)); r.bg[n].vofs = UInt16(rng.int(1024)) }
                    if all || rng.chance(3) { r.bg[n].sc = rng.byte(); r.bg[n].charBase = UInt8(rng.int(16)) }
                }
                if all || rng.chance(10) { r.tm = rng.byte() & 0x1F; r.ts = rng.byte() & 0x1F }
                if all || rng.chance(20) { r.cgwsel = rng.byte(); r.cgadsub = rng.byte() }
                if all || rng.chance(20) { r.writeCOLDATA(rng.byte()) }
                if all || rng.chance(5) { r.obsel = rng.byte(); r.objFirst = rng.chance(50) ? 0 : UInt8(rng.int(128)) }
                if all || rng.chance(5) { r.inidisp = rng.chance(10) ? 0x80 : UInt8(rng.int(16)) | (rng.chance(80) ? 0x0F : 0) }
                if all || rng.chance(10) {
                    r.w12sel = rng.byte(); r.w34sel = rng.byte(); r.wobjsel = rng.byte()
                    r.wbglog = rng.byte(); r.wobjlog = rng.byte(); r.tmw = rng.byte(); r.tsw = rng.byte()
                }
                if all || rng.chance(40) { r.wh0 = rng.byte(); r.wh1 = rng.byte(); r.wh2 = rng.byte(); r.wh3 = rng.byte() }
                if all || rng.chance(10) { r.mosaic = rng.byte() }
                if all || rng.chance(5) { r.setini = rng.byte() & 0x4F }
                if all || rng.chance(30) {
                    r.m7sel = rng.byte()
                    r.m7a = Int16(bitPattern: rng.word()); r.m7b = Int16(bitPattern: rng.word())
                    r.m7c = Int16(bitPattern: rng.word()); r.m7d = Int16(bitPattern: rng.word())
                    r.m7x = Int16(bitPattern: rng.word()); r.m7y = Int16(bitPattern: rng.word())
                    r.m7hofs = Int16(bitPattern: rng.word()); r.m7vofs = Int16(bitPattern: rng.word())
                }
            }
            randomize(&base, all: true)
            for line in 0..<f.height {
                randomize(&base, all: false)
                f.lines[line] = base
                if rng.chance(30) { f.writeCGRAM(line: line, index: rng.int(256), color: rng.word()) }
                if rng.chance(3) { f.writeVRAM(line: line, address: rng.int(0x8000), word: rng.word()) }
                if rng.chance(3) { f.writeOAM(line: line, address: rng.int(PPUFrame.oamBytes), byte: rng.byte()) }
            }
            let options = PPURenderOptions(highResolution: rng.chance(70), overscanBorder: rng.chance(30))
            try assertParity(r, f, "seed \(seed)", options: options)
        }
    }
}
