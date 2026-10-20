// LZSSTests.swift — corpus decompression via Swift fallback AND C interop.
import XCTest
@testable import ChronoForgeCore

final class LZSSTests: XCTestCase {
    static let corpusCount = 12

    func romBytes() throws -> [UInt8] { try [UInt8](Repo.romData()) }

    /// Swift fallback: >= 10 packed corpus blocks decompress to the exact
    /// sizes declared in data_assets.csv.
    func testSwiftDecompressCorpus() throws {
        let rom = try romBytes()
        let blocks = try loadCorpus()
        XCTAssertGreaterThanOrEqual(blocks.count, 100, "corpus unexpectedly small")
        var checked = 0, lz11 = 0, lz12 = 0
        for b in blocks.prefix(LZSSTests.corpusCount) {
            let src = Array(rom[b.pcStart...b.pcEnd])
            let (out, mode) = try LZSS.decompress(src)
            XCTAssertEqual(out.count, b.expectedSize, "block \(b.label) size mismatch")
            XCTAssertEqual(mode.rawValue, b.mode, "block \(b.label) mode mismatch")
            if b.mode == 11 { lz11 += 1 } else { lz12 += 1 }
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 10)
        XCTAssertGreaterThan(lz11 + lz12, 0)
    }

    /// C interop (libctcodec): same corpus, exact sizes, byte-identical to
    /// the Swift fallback. Skips when the dylib is absent.
    func testCInteropCorpus() throws {
        let codec = LibCTCodec.shared
        guard codec.available else {
            throw XCTSkip("libctcodec.dylib not present — C-interop skipped")
        }
        let rom = try romBytes()
        for b in try loadCorpus().prefix(LZSSTests.corpusCount) {
            let src = Array(rom[b.pcStart...b.pcEnd])
            guard let cOut = codec.lzssDecompress(src) else {
                return XCTFail("C decompress failed for \(b.label)")
            }
            XCTAssertEqual(cOut.count, b.expectedSize, "C: block \(b.label) size mismatch")
            let swiftOut = try LZSS.decompress(src).out
            XCTAssertEqual(cOut, swiftOut, "C vs Swift bytes differ for \(b.label)")
        }
    }

    /// Swift compress -> Swift decompress round-trip for both modes.
    func testCompressRoundTrip() throws {
        var rng = SeededRNG(seed: 0xC7C0C3C3)
        // Compressible-ish data: random with repeats.
        var data = [UInt8]()
        var vocab = [[UInt8]]()
        for _ in 0..<64 {
            vocab.append((0..<8).map { _ in UInt8.random(in: 0...255, using: &rng) })
        }
        while data.count < 40_000 { data.append(contentsOf: vocab.randomElement(using: &rng)!) }
        for mode in [LZSSMode.lz11, .lz12] {
            let packed = try XCTUnwrap(LZSS.compress(data, mode: mode))
            let (out, detected) = try LZSS.decompress(packed)
            XCTAssertEqual(detected, mode)
            XCTAssertEqual(out, data, "round-trip mismatch for \(mode)")
            XCTAssertLessThan(packed.count, data.count, "compression did not shrink \(mode) data")
        }
    }

    /// Cross-check the two codecs against each other (only when dylib present).
    func testCInteropCompressCrossCheck() throws {
        let codec = LibCTCodec.shared
        guard codec.available else { throw XCTSkip("libctcodec.dylib not present") }
        let data = ([UInt8](repeating: 0xAB, count: 5000) + [UInt8](repeating: 0x00, count: 3000))
        for mode in [11, 12] {
            guard let packed = codec.lzssCompress(data, mode: mode) else {
                return XCTFail("C compress mode \(mode) failed")
            }
            let (out, m) = try LZSS.decompress(packed)
            XCTAssertEqual(m.rawValue, mode)
            XCTAssertEqual(out, data, "C-compressed data failed Swift round-trip (mode \(mode))")
        }
    }

    /// The Swift packer and the C packer are the same algorithm: identical
    /// bytes on inputs with many equal-length match candidates, partial last
    /// groups, window edges and the 64 KiB limit.
    func testSwiftPackerMatchesC() throws {
        let codec = LibCTCodec.shared
        guard codec.available else { throw XCTSkip("libctcodec.dylib not present") }
        var rng = SeededRNG(seed: 0x0C0FFEE)
        var cases: [[UInt8]] = [[], [0], [1, 2], [UInt8](repeating: 0, count: 5000), Array(0...255) + Array(0...255)]
        for n in [7, 8, 9, 17, 18, 19, 34, 35, 2047, 2049, 4095, 4097, 20_000, 0xFFFF] {
            cases.append((0..<n).map { _ in UInt8.random(in: 0...2, using: &rng) })
        }
        for data in cases {
            for mode in [LZSSMode.lz11, .lz12] {
                let swift = try XCTUnwrap(LZSS.compress(data, mode: mode))
                XCTAssertEqual(swift, codec.lzssCompress(data, mode: mode.rawValue), "\(mode) \(data.count)")
                XCTAssertEqual(try LZSS.decompress(swift).out, data)
            }
        }
        XCTAssertNil(LZSS.compress([UInt8](repeating: 0, count: 0x10000), mode: .lz11))
    }

    /// Every packed block in the ROM is rebuilt byte for byte by the Swift packer.
    func testRomPacksRebuiltExactly() throws {
        let rom = try romBytes()
        let blocks = try loadCorpus()
        XCTAssertEqual(blocks.count, 1053)
        for block in blocks {
            let src = Array(rom[block.pcStart...block.pcEnd])
            let (out, mode) = try LZSS.decompress(src)
            XCTAssertEqual(LZSS.compress(out, mode: mode), src, "block at \(block.pcStart)")
        }
    }

    /// ROM-mode smoke: the first corpus block via the same path the CLI uses.
    func testRomSmokeFirstBlock() throws {
        let rom = try romBytes()
        let blocks = try loadCorpus()
        guard let first = blocks.first else { return XCTFail("empty corpus") }
        let src = Array(rom[first.pcStart...first.pcEnd])
        let (out, _) = try LZSS.decompress(src)
        XCTAssertEqual(out.count, first.expectedSize)
    }
}

struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
