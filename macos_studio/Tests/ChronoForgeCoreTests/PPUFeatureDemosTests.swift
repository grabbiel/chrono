// PPUFeatureDemosTests.swift — the synthetic PPU feature demos (PPU Demos
// window, `chronoforge ppu demos`): each builds, uses the feature it is
// named for, and draws a varied picture at the expected size.
import XCTest
@testable import ChronoForgeCore

final class PPUFeatureDemosTests: XCTestCase {
    func testEveryDemoDrawsAtItsSize() {
        for d in PPUPreviewScenes.Demo.allCases {
            let image = PPUReferenceRenderer.renderImage(PPUPreviewScenes.demo(d, frame: 12), options: PPUPreviewScenes.options(d))
            let wide: Set<PPUPreviewScenes.Demo> = [.hires, .pseudoHires, .interlace]
            XCTAssertEqual(image.width, wide.contains(d) ? 512 : 256, d.rawValue)
            XCTAssertEqual(image.height, d == .overscan ? 239 : 224, d.rawValue)
            var colors = Set<UInt32>()
            for p in stride(from: 0, to: image.rgba.count, by: 4) {
                var c = UInt32(image.rgba[p])
                c |= UInt32(image.rgba[p + 1]) << 8
                c |= UInt32(image.rgba[p + 2]) << 16
                colors.insert(c)
            }
            XCTAssertGreaterThan(colors.count, 8, "\(d.rawValue) has a varied picture")
        }
        XCTAssertEqual(Set(PPUPreviewScenes.Demo.allCases.map(\.slug)).count, PPUPreviewScenes.Demo.allCases.count)
    }

    func testEachDemoUsesItsFeature() {
        func demo(_ d: PPUPreviewScenes.Demo, _ n: Int = 0) -> PPUFrame { PPUPreviewScenes.demo(d, frame: n) }
        XCTAssertEqual(demo(.hdmaGradient).linesChanging(.cgram).count, 224, "a CGRAM write before every line")
        XCTAssertTrue(demo(.mosaic, 20).lines.allSatisfy { $0.mosaicSize > 1 && $0.mosaic & 1 != 0 })
        let opt = demo(.offsetPerTile)
        XCTAssertEqual(opt.lines[0].mode, 2)
        XCTAssertTrue((0..<32).contains { opt.vram[0x7000 + 32 + $0] & 0x2000 != 0 }, "BG3 holds BG1 offsets")
        let direct = demo(.directColor)
        XCTAssertEqual(direct.lines[0].mode, 3)
        XCTAssertTrue(direct.lines[0].directColor)
        XCTAssertFalse(direct.lines[200].directColor, "the lower half shows CGRAM for contrast")
        let m7 = demo(.mode7, 30)
        XCTAssertTrue(m7.lines.allSatisfy { $0.mode == 7 })
        XCTAssertGreaterThan(Set(m7.lines.map(\.m7a)).count, 100, "a per-line perspective matrix")
        XCTAssertTrue(demo(.extbg).lines.allSatisfy { $0.extbg && $0.tm & 0x02 != 0 })
        XCTAssertTrue(demo(.hires).lines.allSatisfy { $0.mode == 5 })
        XCTAssertTrue(demo(.pseudoHires).lines.allSatisfy { $0.highResolution && $0.mode == 1 })
        XCTAssertEqual([demo(.interlace, 0).field, demo(.interlace, 1).field], [0, 1])
        XCTAssertTrue(demo(.interlace).lines.allSatisfy { $0.interlace && $0.objInterlace })
        XCTAssertTrue(PPUPreviewScenes.options(.overscan).overscanBorder)
    }

    func testAnimationChangesThePicture() {
        for d in PPUPreviewScenes.Demo.allCases where d != .directColor {
            // At the demo's own size: pseudo 512 animates its sub screen.
            let options = PPUPreviewScenes.options(d)
            let a = PPUReferenceRenderer.renderImage(PPUPreviewScenes.demo(d, frame: 0), options: options)
            let b = PPUReferenceRenderer.renderImage(PPUPreviewScenes.demo(d, frame: 33), options: options)
            XCTAssertNotEqual(a.rgba, b.rgba, d.rawValue)
        }
    }
}
