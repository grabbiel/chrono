// CTTextCodecTests.swift — TextWin codec: synthetic dictionary rules (no ROM)
// plus ROM-gated checks against the locally generated message corpus.
import XCTest
@testable import ChronoForgeCore

final class CTTextCodecTests: XCTestCase {
    // Glyph bytes: A=$A0, a=$BA, digits from $D4. Entries that start with $FE never
    // occur in ordinary text, so they cannot interfere with packing.
    private static func glyphs(_ s: String) -> [UInt8] {
        s.map { ch -> UInt8 in
            if ch.isUppercase { return 0xA0 + UInt8(ch.asciiValue! - 65) }
            if ch.isLowercase { return 0xBA + UInt8(ch.asciiValue! - 97) }
            return 0xEF // space
        }
    }
    private static let synthetic: [[UInt8]] = (0..<128).map { i in
        switch i {
        case 0: return glyphs("the")
        case 1: return glyphs("th")
        case 2: return glyphs("he")
        case 40: return glyphs("ing")
        case 116: return glyphs("ou")          // decodable, never chosen by packing
        case 127: return glyphs("xyz")         // only reachable through {ext} $12 $68
        default: return [0xFE, 0xFE, UInt8(0xA0 + i % 64)]
        }
    }
    private let codec = CTTextCodec(validatedDictionary: synthetic)

    func testGreedyPackingPrefersLongestEntryAndSkipsExcludedIndices() throws {
        XCTAssertEqual(try codec.encode("the"), [0x21])
        XCTAssertEqual(try codec.encode("then"), [0x21, 0xC7])
        XCTAssertEqual(try codec.encode("thing"), [0x22, 0x21 + 40])
        // Entry 116 ("ou") is excluded from compression to match the ROM corpus.
        XCTAssertEqual(try codec.encode("you"), Self.glyphs("you"))
        XCTAssertEqual(try codec.encode("the", compress: false), Self.glyphs("the"))
    }

    func testNoncanonicalRunsAndExplicitReferencesRoundTripLosslessly() throws {
        let streams: [[UInt8]] = [
            Self.glyphs("the") + [0],          // literal spelling of entry 0
            [0x21 + 116, 0],                   // excluded entry used directly
            [0x22, 0xBE, 0],                   // "th"+"e" instead of "the"
            [0x12, 0x68, 0],                   // entry 127 through the extension control
            [0xEF, 0xFF, 0],                   // ordinary space vs second blank
            [0x01, 0x00, 0x03, 0x00, 0x12, 0x01, 0x05, 0],  // operands of $00 are not END
        ]
        for bytes in streams {
            let text = try codec.decode(bytes)
            XCTAssertEqual(try codec.encode(text), bytes, text)
        }
        XCTAssertEqual(try codec.decode(Self.glyphs("the") + [0]), "«the»{end}")
        XCTAssertEqual(try codec.decode([0xEF, 0xFF, 0]), " _{end}")
        XCTAssertEqual(try codec.encode("[the]"), [0x21])
        XCTAssertEqual(try codec.encode("{ext [xyz]}"), [0x12, 0x68])
        XCTAssertEqual(try codec.encode("{tech}{enemy}{wait 1E}{wide 01FF}"),
                       [0x12, 0, 0x12, 1, 3, 0x1E, 1, 0xFF])
    }

    func testNewlinesAreLineControlsAndUnknownGlyphsAreRejected() throws {
        XCTAssertEqual(try codec.encode("A\nB"), [0xA0, 5, 0xA1])
        XCTAssertEqual(try codec.encode("{gF5}"), [0xF5])      // unassigned glyph, explicit
        XCTAssertEqual(try codec.decode([0xF5]), "{gF5}")
        XCTAssertEqual(try codec.encode("{$10}"), [0x10])      // raw control notation
        for bad in ["雪", "{unknown}", "{g12}", "{dict 7F}", "«{line}»", "«abc", "abc»", "{wait",
                    "{ext [nope]}", "[the end]"] {
            XCTAssertThrowsError(try codec.encode(bad), bad)
        }
    }

    func testCompileMessageTerminatesOnceAndRejectsUnsafeOperands() throws {
        XCTAssertEqual(try codec.compileMessage("Hi"), [0xA7, 0xC2, 0])
        XCTAssertEqual(try codec.compileMessage("Hi{end}"), [0xA7, 0xC2, 0])
        XCTAssertThrowsError(try codec.compileMessage("Hi{end}more"))
        XCTAssertThrowsError(try codec.compileMessage("{ext 02}"))      // unverified extension index
        XCTAssertThrowsError(try codec.compileMessage("{$03}"))         // raw control without operand
        XCTAssertNoThrow(try codec.compileMessage("{ext 08}{ext 68}{tech}"))
        let analysis = try codec.analyzeMessage("the thing")
        XCTAssertEqual(analysis.bytes, [0x21, 0xEF, 0x22, 0x21 + 40, 0])
        XCTAssertEqual(analysis.uncompressedBytes, 10)
        XCTAssertEqual(analysis.savedBytes, 5)
        XCTAssertEqual(analysis.canonical, "the thing{end}")
    }

    func testDecodeRejectsTruncatedOperands() {
        for bytes: [UInt8] in [[0x01], [0x03], [0x12], [0xA0, 0x12]] {
            XCTAssertThrowsError(try codec.decode(bytes))
        }
    }

    func testProfileValidationRejectsWrongSchemaHashOrShape() {
        let wrong = CTTextProfile(schema: "ct-text-us/1", romSHA256: CTTextProfile.romHash,
                                  dictionary: Self.synthetic)
        XCTAssertThrowsError(try wrong.validate())   // synthetic dictionary hash differs
        XCTAssertThrowsError(try CTTextCodec(profile: wrong))
        for profile in [CTTextProfile(schema: "ct-text-jp/1", romSHA256: CTTextProfile.romHash, dictionary: Self.synthetic),
                        CTTextProfile(schema: "ct-text-us/1", romSHA256: String(repeating: "0", count: 64), dictionary: Self.synthetic),
                        CTTextProfile(schema: "ct-text-us/1", romSHA256: CTTextProfile.romHash, dictionary: [])] {
            XCTAssertThrowsError(try profile.validate())
        }
        XCTAssertThrowsError(try CTTextProfile.fromROM(Data(count: 4_194_304)))
        XCTAssertThrowsError(try CTTextProfile.fromROM(Data([1, 2, 3])))
    }

    // MARK: ROM-backed (skipped when the user's ROM or generated corpus is absent)

    private func romProfile() throws -> CTTextProfile {
        guard let rom = try? Repo.romData() else { throw XCTSkip("local ROM not present") }
        return try CTTextProfile.fromROM(rom)
    }

    func testROMProfileAcceptsCopierHeaderAndMatchesGeneratedProfile() throws {
        let profile = try romProfile()
        let rom = try Repo.romData()
        XCTAssertEqual(try CTTextProfile.fromROM(Data(count: 512) + rom), profile)
        let generated = Repo.root.appendingPathComponent("re_workspace/assets/text/text_profile.json")
        guard let data = try? Data(contentsOf: generated) else { throw XCTSkip("text_profile.json not generated") }
        XCTAssertEqual(try JSONDecoder().decode(CTTextProfile.self, from: data), profile)
    }

    func testEveryROMMessageRoundTripsByteExactly() throws {
        let codec = try CTTextCodec(profile: romProfile())
        let url = Repo.root.appendingPathComponent("re_workspace/assets/text/message_corpus.json")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("message_corpus.json not generated") }
        struct Corpus: Decodable {
            struct Case: Decodable { let label: String; let bytes: [UInt8]; let text: String }
            let cases: [Case]
        }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        XCTAssertEqual(corpus.cases.count, 4581)
        var failures: [String] = []
        for sample in corpus.cases {
            let reference = try? codec.encode(sample.text)
            let roundTrip = try? codec.encode(codec.decode(sample.bytes))
            if reference != sample.bytes || roundTrip != sample.bytes { failures.append(sample.label) }
        }
        XCTAssertEqual(failures, [], "first failures: \(failures.prefix(5))")
    }

    func testDialogueArchiveIsDeterministicAndRequiresProfile() throws {
        var project = try CTProject.load(from: fixtureURL())
        project.textProfile = nil
        XCTAssertThrowsError(try CTDialogueArchive.compile(project))
        project.textProfile = try romProfile()
        project.dialogue.strings = ["b": "the end", "a": "Hi"]
        let build = try CTDialogueArchive.compile(project)
        XCTAssertEqual(build.records.map(\.id), ["a", "b"])
        XCTAssertEqual(build.records[0].offset, 0)
        XCTAssertEqual(build.records[1].offset, build.records[0].length)
        XCTAssertEqual(build.bytes.count, build.records.reduce(0) { $0 + $1.length })
        XCTAssertEqual(build.bytes.last, 0)
        XCTAssertEqual(try CTDialogueArchive.compile(project), build)
    }
}
