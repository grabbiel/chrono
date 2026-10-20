// PPURendererTests.swift — Metal library compiles, view inits, one offscreen
// frame renders without errors.
import XCTest
import Metal
import MetalKit
import AppKit
@testable import ChronoForgeMetal
import ChronoForgeCore

@MainActor
final class PPURendererTests: XCTestCase {
    /// MTKView must be created on the main thread; XCTest may not deliver
    /// there even for @MainActor classes, so hop explicitly when needed.
    static func onMain<T>(_ body: @MainActor @escaping () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        var result: Result<T, Error>?
        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            do { result = .success(try body()) } catch { result = .failure(error) }
            sem.signal()
        }
        sem.wait()
        return try result!.get()
    }

    func renderer() throws -> PPURenderer {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        return try PPURenderer(device: device)
    }

    func testShaderLibraryCompiles() throws {
        let r = try renderer()
        XCTAssertNotNil(r.library.makeFunction(name: "tile_vs"))
        XCTAssertNotNil(r.library.makeFunction(name: "tile_fs"))
    }

    func testSNESPPUViewInits() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("no Metal device available")
        }
        let view = try SNESPPUView(device: MTLCreateSystemDefaultDevice()!)
        XCTAssertEqual(view.preferredFramesPerSecond, 60)
        XCTAssertNotNil(view.renderer.library)
    }

    func testOffscreenFrameRenders() throws {
        let r = try renderer()
        let device = r.device
        // 16 tiles of a checkerboard, 4bpp indices.
        var indices = [UInt8](repeating: 0, count: 16 * 64)
        for t in 0..<16 {
            for i in 0..<64 { indices[t * 64 + i] = UInt8((i % 3) + 1) }
        }
        try r.setTileAtlas(indices: indices, tilesWide: 4, sprite: false)
        r.setPalette((0..<256).map { i in BGR555(r5: UInt8(i % 32), g5: 20, b5: UInt8(i % 32)) })

        guard let tex = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            return d
        }()) else { return XCTFail("no target texture") }

        let planes = [BGPlane(bg: 1, entries: (0..<16).map { t in
            BGPlaneEntry(x: (t % 4) * 8, y: (t / 4) * 8, tile: t, pal: 0,
                         priority: t >= 12)
        })]
        let sprites = [SpriteEntry(x: 4, y: 4, tile: 2, pal: 1, size16: false, z: 2)]
        r.render(into: tex, size: SIMD2(64, 64), bgPlanes: planes, sprites: sprites)

        // Read back: something must have been drawn (non-black pixels exist).
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        tex.getBytes(&bytes, bytesPerRow: 64 * 4,
                     from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        let nonBlack = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] != 0 || bytes[$0 + 1] != 0 || bytes[$0 + 2] != 0
        }.count
        XCTAssertGreaterThan(nonBlack, 100, "offscreen frame was blank")

        // Additive mode path executes without errors.
        r.render(into: tex, size: SIMD2(64, 64), bgPlanes: planes, sprites: sprites,
                 additive: true)
    }

    func testMTKViewFramePath() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device available")
        }
        let view = try SNESPPUView(device: device)
        var indices = [UInt8](repeating: 7, count: 64)   // one solid tile
        try view.loadTileset(indices: indices, tilesWide: 1,
                             palette: [BGR555](repeating: BGR555(hex: "0x7FFF")!, count: 256))
        indices[0] = 0
        try view.loadSprites(indices: indices, tilesWide: 1)
        view.bgPlanes = [BGPlane(bg: 2, entries: [BGPlaneEntry(x: 0, y: 0, tile: 0, pal: 0)])]
        view.sprites = [SpriteEntry(x: 0, y: 0, tile: 0, pal: 3, z: 3)]
        // Trigger a synchronous draw into the view's drawable if available.
        view.frame = NSRect(x: 0, y: 0, width: 64, height: 64)
        view.display()   // must not crash
    }
}
