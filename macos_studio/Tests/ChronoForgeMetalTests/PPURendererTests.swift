// PPURendererTests.swift — Metal library compiles, view inits and draws, one
// offscreen frame renders.
import XCTest
import Metal
import MetalKit
import AppKit
@testable import ChronoForgeMetal
import ChronoForgeCore

@MainActor
final class PPURendererTests: XCTestCase {
    func renderer() throws -> PPURenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        return try PPURenderer(device: device)
    }

    func testShaderLibraryCompiles() throws {
        let r = try renderer()
        for name in ["ppu_frame", "present_vs", "present_fs"] {
            XCTAssertNotNil(r.library.makeFunction(name: name), name)
        }
    }

    func testSNESPPUViewInits() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let view = try SNESPPUView(device: device)
        XCTAssertEqual(view.preferredFramesPerSecond, 60)
        XCTAssertEqual(view.picture.height, 224)
    }

    func testOffscreenFrameRenders() throws {
        let r = try renderer()
        var f = PPUFrame()
        f.cgram[0] = BGR555(r5: 31, g5: 0, b5: 0).word
        let out = try r.render(f)
        XCTAssertEqual(out.count, 256 * 224 * 4)
        XCTAssertEqual(Array(out[0..<4]), [255, 0, 0, 255], "backdrop")
        XCTAssertEqual(Array(out[out.count - 4..<out.count]), [255, 0, 0, 255])
    }

    func testMTKViewFramePath() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let view = try SNESPPUView(device: device)
        var ticks: [Int] = []
        view.tick = { frame, n in
            ticks.append(n)
            frame.cgram[0] = UInt16(n & 31)
        }
        view.frame = NSRect(x: 0, y: 0, width: 512, height: 448)
        view.draw(in: view)   // must not crash without a window/drawable
        view.draw(in: view)
        XCTAssertEqual(ticks, [0, 1])
        XCTAssertEqual(view.picture.cgram[0], 1)
    }
}
