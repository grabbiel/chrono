// CTTextAnalyzerTests.swift — the compression analyzer on a synthetic
// dictionary (runs, savings, unused entries, the codec's bytes unchanged),
// and with the local ROM: the item descriptions analyze to their ROM sizes.
import XCTest
@testable import ChronoForgeCore

final class CTTextAnalyzerTests: XCTestCase {
    /// 128 glyph-only entries: entry 0 "the ", entry 1 "ing", entry 2 "Th"; the rest unused "#" runs.
    private func syntheticCodec() throws -> CTTextCodec {
        func glyphs(_ s: String) throws -> [UInt8] { try s.map { try XCTUnwrap(CTTextCodec.glyphByte(String($0))) } }
        var entries = [try glyphs("the "), try glyphs("ing"), try glyphs("Th")]
        for k in 3..<128 { entries.append(try glyphs(String(repeating: "#", count: 2 + k % 3)) + [0xA0 + UInt8(k % 26)]) }
        return CTTextCodec(validatedDictionary: entries)
    }

    func testSegmentsAndSavings() throws {
        let codec = try syntheticCodec()
        let text = "The thing{line}the ring{wait 10}"
        let r = try CTTextAnalyzer.analyze([text], codec: codec)
        XCTAssertEqual(r.compressedBytes, try codec.compileMessage(text).count)          // the codec's own bytes
        XCTAssertEqual(r.rawBytes, try codec.compileMessage(text, compress: false).count)
        XCTAssertEqual(r.savedBytes, r.entries.map(\.savedBytes).reduce(0, +))
        let used = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.entry, $0.uses) })
        XCTAssertEqual(used[1], 2)                                                       // "ing" twice
        XCTAssertEqual(used[0], 1)                                                       // "the " once
        XCTAssertEqual(r.entries.first?.entry, 1)                                        // most saving first: 2 × 2 before 3
        let segments = try XCTUnwrap(r.segments)
        XCTAssertEqual(segments.flatMap(\.bytes), try codec.compileMessage(text))
        XCTAssertEqual(segments.filter { $0.kind == "control" }.map(\.bytes), [[5], [3, 0x10], [0]])
        XCTAssertEqual(segments.filter { $0.kind == "dictionary" }.map(\.text).first, "Th")
        XCTAssertEqual(r.unusedEntries.count, 127 - r.entries.count)
        XCTAssertTrue(r.unusedEntries.contains(116))
    }

    func testCorpusAddsUpAndReportsNoSegments() throws {
        let codec = try syntheticCodec()
        let texts = ["the king", "singing", "{nop}"]
        let r = try CTTextAnalyzer.analyze(texts, codec: codec)
        XCTAssertNil(r.segments)
        XCTAssertEqual(r.messages, 3)
        XCTAssertEqual(r.compressedBytes, try texts.map { try codec.compileMessage($0).count }.reduce(0, +))
        XCTAssertEqual(r.savedBytes, r.entries.map(\.savedBytes).reduce(0, +))
        XCTAssertEqual(r.entries.map(\.savedBytes), r.entries.map(\.savedBytes).sorted(by: >))
        XCTAssertThrowsError(try CTTextAnalyzer.analyze(["é"], codec: codec))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let json = String(decoding: try encoder.encode(r), as: UTF8.self)
        XCTAssertTrue(json.contains("\"savedBytes\":\(r.savedBytes)") && json.contains("ct-text-analysis/1"))
    }

    /// The ROM's item descriptions, recompiled, are the bytes the ROM holds (each plus its $00).
    func testItemDescriptionsAnalyzeToTheirROMSize() throws {
        let rom = [UInt8](try Repo.romData())
        let codec = try CTTextCodec(profile: CTTextProfile.fromROM(Data(rom)))
        let raw = CTItemROM.descriptionBytes(rom: rom)
        let texts = try raw.map { try codec.decode($0) }
        let r = try CTTextAnalyzer.analyze(texts, codec: codec)
        XCTAssertEqual(r.compressedBytes, raw.map { $0.count + 1 }.reduce(0, +))
        XCTAssertGreaterThan(r.savedBytes, 0)
        XCTAssertEqual(r.savedBytes, r.entries.map(\.savedBytes).reduce(0, +))
    }
}
