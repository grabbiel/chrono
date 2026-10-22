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

    /// fullsnes: byte 2r is plane 0 of row r, 2r+1 plane 1, 16+2r plane 2,
    /// 17+2r plane 3; bit 7 is the leftmost pixel.
    func testPlanarLayoutFollowsFullsnes() {
        var raw = [UInt8](repeating: 0, count: 32)
        raw[2 * 3] = 0x80; raw[2 * 3 + 1] = 0x80        // row 3, x 0: planes 0 and 1
        raw[16 + 2 * 5] = 0x01                          // row 5, x 7: plane 2
        raw[17 + 2 * 6] = 0x40                          // row 6, x 1: plane 3
        let px = TileDecoder.decodeIndices(raw, depth: .bpp4)
        XCTAssertEqual(px[3 * 8 + 0], 3)
        XCTAssertEqual(px[5 * 8 + 7], 4)
        XCTAssertEqual(px[6 * 8 + 1], 8)
        XCTAssertEqual(px.filter { $0 != 0 }.count, 3)
        let two = TileDecoder.decodeIndices([0x00, 0x00, 0x80, 0x01] + [UInt8](repeating: 0, count: 12), depth: .bpp2)
        XCTAssertEqual(two[8 + 0], 1)                   // row 1: byte 2 is plane 0, byte 3 plane 1
        XCTAssertEqual(two[8 + 7], 2)
        XCTAssertEqual(two.filter { $0 != 0 }.count, 2)
    }

    /// The decoder's layout is the PPU's: encoded bytes read as little-endian
    /// words equal what `PPUFrame.storeTiles` puts in VRAM, for both depths.
    func testEncodedBytesEqualThePPUsVRAMWords() throws {
        for (depth, bpp) in [(TileDepth.bpp4, 4), (.bpp2, 2)] {
            let blob = try resourceData("TileGolden/\(bpp)bpp_blob.bin")
            let idx = TileDecoder.decodeIndices([UInt8](blob), depth: depth)
            let bytes = TileDecoder.encodePlanar(idx, depth: depth)
            var frame = PPUFrame()
            frame.storeTiles(idx, bpp: bpp, atWord: 0x1000)
            let words = (0..<(bytes.count / 2)).map { UInt16(bytes[2 * $0]) | UInt16(bytes[2 * $0 + 1]) << 8 }
            XCTAssertEqual(Array(frame.vram[0x1000..<(0x1000 + words.count)]), words, "\(bpp)bpp")
        }
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
