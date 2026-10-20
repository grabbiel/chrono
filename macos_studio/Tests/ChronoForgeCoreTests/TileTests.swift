// TileTests.swift — planar tile decode parity vs the Python reference
// (tools/gen_fixture_assets.py) and vs re_workspace/assets/graphics when present.
import XCTest
@testable import ChronoForgeCore

final class TileTests: XCTestCase {
    func test4bppGoldenParity() throws {
        let blob = try resourceData("TileGolden/4bpp_blob.bin")
        let expected = try resourceData("TileGolden/4bpp_indices.bin")
        let got = TileDecoder.decodeIndices([UInt8](blob), depth: .bpp4)
        XCTAssertEqual(got.count, expected.count)
        XCTAssertEqual(got, [UInt8](expected), "4bpp decode differs from python reference")
    }

    func test2bppGoldenParity() throws {
        let blob = try resourceData("TileGolden/2bpp_blob.bin")
        let expected = try resourceData("TileGolden/2bpp_indices.bin")
        let got = TileDecoder.decodeIndices([UInt8](blob), depth: .bpp2)
        XCTAssertEqual(got, [UInt8](expected), "2bpp decode differs from python reference")
    }

    func testPlanarRoundTrip() throws {
        let blob = try resourceData("TileGolden/4bpp_blob.bin")
        let idx = TileDecoder.decodeIndices([UInt8](blob), depth: .bpp4)
        let back = TileDecoder.encodePlanar(idx, depth: .bpp4)
        XCTAssertEqual(back, [UInt8](blob), "decode->encode lost bits")
    }

    /// If the graphics pipeline has produced assets, decode them without
    /// error and with the expected geometry.
    func testRealGraphicsAssetsIfPresent() throws {
        let dir = Repo.graphicsAssets
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir,
            includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "bin" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw XCTSkip("re_workspace/assets/graphics/*.bin not produced yet")
        }
        for f in files.prefix(8) {
            let data = try Data(contentsOf: f)
            let idx = TileDecoder.decodeIndices([UInt8](data), depth: .bpp4)
            XCTAssertEqual(idx.count, (data.count / 32) * 64, "geometry wrong for \(f.lastPathComponent)")
        }
    }

    func testBGR555Expansion() {
        // (c<<3)|(c>>2) per channel
        XCTAssertEqual(BGR555(word: 0x7FFF).srgb.r, 255)
        XCTAssertEqual(BGR555(word: 0x7C1F).srgb.b, 255)
        XCTAssertEqual(BGR555(hex: "0x03E0")!.g5, 31)
        let c = BGR555(r5: 1, g5: 2, b5: 3)
        XCTAssertEqual(c.word, (3 << 10) | (2 << 5) | 1)
        XCTAssertEqual(c.srgb.r, (1 << 3) | (1 >> 2))   // 8
        XCTAssertEqual(c.srgb.g, (2 << 3) | (2 >> 2))   // 16
        XCTAssertEqual(c.srgb.b, (3 << 3) | (3 >> 2))   // 25
    }
}
