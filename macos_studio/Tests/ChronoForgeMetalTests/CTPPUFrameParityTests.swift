// CTPPUFrameParityTests.swift — the Chrono Trigger frames that
// re_workspace/tools/ct_ppu_frames.py captures at run time from the local ROM
// (the battle's HDMA, the title's offset-per-tile, the Lavos program's
// interlaced mode 7 with both fields) drawn by the Metal PPU and the CPU
// reference renderer, compared byte for byte. They skip without a Metal
// device, the ROM or the ChronoRET checkout.
import XCTest
import Metal
@testable import ChronoForgeMetal
import ChronoForgeCore

@MainActor
final class CTPPUFrameParityTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func renderer() throws -> PPURenderer {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("no Metal device available") }
        return try PPURenderer(device: device)
    }

    func capture(_ kind: CTPPUCapture.Kind) throws -> CTPPUCapture {
        let rom = Self.root.appendingPathComponent("re_workspace/ct_clean.sfc")
        guard FileManager.default.fileExists(atPath: rom.path) else {
            throw XCTSkip("local ROM not present (re_workspace/ct_clean.sfc)")
        }
        let absint = Self.root.appendingPathComponent("re_workspace/refs/ChronoRET/tools/absint.py")
        guard FileManager.default.fileExists(atPath: absint.path) else {
            throw XCTSkip("local ChronoRET checkout not present (re_workspace/refs/ChronoRET)")
        }
        let tool = Self.root.appendingPathComponent("re_workspace/tools/ct_ppu_frames.py")
        return try CTPPUCapture.run(kind, rom: rom, tool: tool)
    }

    func assertParity(_ r: PPURenderer, _ f: PPUFrame, _ label: String,
                      file: StaticString = #filePath, line: UInt = #line) throws {
        let cpu = PPUReferenceRenderer.renderImage(f)
        let gpu = try r.renderImage(f)
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

    func testParityBattleFrame() throws {
        let r = try renderer()
        try assertParity(r, try capture(.battle).frame(), "battle")
    }

    func testParityTitleFrame() throws {
        let r = try renderer()
        try assertParity(r, try capture(.title).frame(), "title")
    }

    func testParityLavosFrameBothFields() throws {
        let r = try renderer()
        let c = try capture(.lavos)
        try assertParity(r, c.frame(field: 0), "lavos field 0")
        try assertParity(r, c.frame(field: 1), "lavos field 1")
    }
}
