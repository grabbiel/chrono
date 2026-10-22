// Chrono Trigger US 1.0 TextWin format. Mapping and compression rules adapted
// from ChronoRET/tools/text.py (MIT, Copyright (c) 2026 Akill).
// See docs/third_party/ChronoRET-LICENSE and text_codec.md for evidence/limits.
import Foundation
import CryptoKit

public struct CTTextError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Extracted from the user's ROM. Neither the ROM nor its dictionary is bundled.
public struct CTTextProfile: Codable, Equatable, Sendable {
    public let schema: String
    public let romSHA256: String
    public let dictionary: [[UInt8]]
    public static let romHash = "06d1c2b06b716052c5596aaa0c2e5632a027fee1a9a28439e509f813c30829a9"
    public static let dictionaryHash = "9e84c9b0aed0e9dd3140d6040638aae0ba88bf5d574558601c5260d2c360ef7e"

    public static func fromROM(_ input: Data) throws -> CTTextProfile {
        let data = input.count == 4_194_304 + 512 ? Data(input.dropFirst(512)) : input
        guard data.count == 4_194_304, digest(data) == romHash else {
            throw CTTextError("Expected Chrono Trigger US 1.0 ROM (SHA-256 \(romHash)); other revisions are not supported")
        }
        let bytes = Array(data)
        var entries: [[UInt8]] = []
        for i in 0..<128 {
            let pointer = 0x1EFA00 + i * 2
            let address = 0x1E0000 + Int(bytes[pointer]) + Int(bytes[pointer + 1]) * 256
            let length = Int(bytes[address])
            guard address + 1 + length <= 0x1F0000 else { throw CTTextError("dictionary entry crosses bank boundary") }
            entries.append(Array(bytes[(address + 1)..<(address + 1 + length)]))
        }
        let profile = CTTextProfile(schema: "ct-text-us/1", romSHA256: romHash, dictionary: entries)
        try profile.validate()
        return profile
    }

    public func validate() throws {
        guard schema == "ct-text-us/1", romSHA256 == Self.romHash else {
            throw CTTextError("unsupported text profile schema or ROM identity")
        }
        guard dictionary.count == 128,
              dictionary.allSatisfy({ !$0.isEmpty && $0.count <= 255 && $0.allSatisfy { $0 >= 0xA0 } }) else {
            throw CTTextError("text profile requires 128 nonempty glyph-only dictionary entries")
        }
        let payload = dictionary.flatMap { [UInt8($0.count)] + $0 }
        guard Self.digest(Data(payload)) == Self.dictionaryHash else {
            throw CTTextError("text profile dictionary does not match the verified US 1.0 dictionary")
        }
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct CTTextCodec: Sendable {
    private let dictionary: [[UInt8]]
    private let candidates: [UInt8: [Int]]
    public static let maximumBytes = 1_048_576
    private static let skippedEntries: Set<Int> = [116, 117, 118]
    private static let glyphCharacters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!?/“”:&()'.,=-+%♪ ♥…∞#")
    private static let glyphs: [UInt8: String] = {
        var result = Dictionary(uniqueKeysWithValues: glyphCharacters.enumerated().map { (UInt8(0xA0 + $0.offset), String($0.element)) })
        result[0xFF] = "_" // second blank, distinct from ordinary $EF space
        return result
    }()
    private static let characters = Dictionary(uniqueKeysWithValues: glyphs.map { ($0.value, $0.key) })
    /// The text of glyph `byte` ($A0-$FF; $EF " ", $FF "_"), nil when it has none.
    /// For fixed-width names outside messages (item names).
    public static func glyphText(_ byte: UInt8) -> String? { glyphs[byte] }
    /// The glyph byte of one character's text, nil when it has none.
    public static func glyphByte(_ text: String) -> UInt8? { characters[text] }
    private static let tags: [UInt8: String] = [
        0: "end", 4: "step", 5: "line", 6: "line indent", 7: "wait line", 8: "wait line indent",
        9: "page", 10: "page indent", 11: "wait page", 12: "wait page indent",
        13: "num8", 14: "num16", 15: "num24", 16: "nop", 17: "argname",
        19: "char0", 20: "char1", 21: "char2", 22: "char3", 23: "char4", 24: "char5", 25: "char6",
        26: "name0", 27: "member0", 28: "member1", 29: "member2", 30: "nadia", 31: "item", 32: "name7"
    ]
    private static let codes = Dictionary(uniqueKeysWithValues: tags.map { ($0.value, $0.key) })
    private static let operands: Set<UInt8> = [1, 2, 3, 0x12]

    public init(profile: CTTextProfile) throws {
        try profile.validate()
        self.init(validatedDictionary: profile.dictionary)
    }
    // Internal initializer supports synthetic compressor tests without a ROM.
    init(validatedDictionary: [[UInt8]]) {
        let dictionary = validatedDictionary
        self.dictionary = dictionary
        var candidates: [UInt8: [Int]] = [:]
        for i in 0..<min(127, dictionary.count) where !Self.skippedEntries.contains(i) {
            if let first = dictionary[i].first { candidates[first, default: []].append(i) }
        }
        for key in candidates.keys {
            candidates[key]!.sort { dictionary[$0].count == dictionary[$1].count ? $0 < $1 : dictionary[$0].count > dictionary[$1].count }
        }
        self.candidates = candidates
    }

    public struct Analysis: Equatable, Sendable {
        public let bytes: [UInt8]
        public let uncompressedBytes: Int
        public let canonical: String
        public var savedBytes: Int { uncompressedBytes - bytes.count }
    }
    public func analyzeMessage(_ text: String) throws -> Analysis {
        let bytes = try compileMessage(text)
        return Analysis(bytes: bytes, uncompressedBytes: try compileMessage(text, compress: false).count,
                        canonical: try decode(bytes))
    }

    /// Compile one complete dialogue, append $00 if absent, refuse unreachable
    /// suffixes and unsafe extension-table operands. No silent glyph replacement.
    public func compileMessage(_ text: String, compress: Bool = true) throws -> [UInt8] {
        var bytes = try encode(text, compress: compress)
        var i = 0, ended = false
        while i < bytes.count {
            let offset = i, code = bytes[i]; i += 1
            if code == 0 {
                guard i == bytes.count else { throw CTTextError("byte \(offset): content follows {end}") }
                ended = true
            } else if Self.operands.contains(code) {
                guard i < bytes.count else { throw CTTextError("byte \(offset): missing control operand") }
                let value = bytes[i]; i += 1
                if code == 0x12 && value != 0 && value != 1 && !(8...104).contains(value) {
                    throw CTTextError("byte \(offset): unsafe extension operand \(Self.hex(value)); use tech, enemy, or a verified dictionary entry")
                }
            }
        }
        if !ended { bytes.append(0) }
        return bytes
    }

    /// Encode a stream, including explicit {end} markers. This low-level API also
    /// preserves raw/unsafe controls for archival round trips; use compileMessage
    /// for authored dialogue. Actual newlines are $05, not formatting whitespace.
    public func encode(_ text: String, compress: Bool = true) throws -> [UInt8] {
        guard text.utf8.count <= Self.maximumBytes else { throw CTTextError("text exceeds 1 MiB") }
        let chars = Array(text)
        var i = 0, literal = false
        var out: [UInt8] = [], run: [UInt8] = []
        func flush() {
            out += compress && !literal ? pack(run) : run
            run.removeAll(keepingCapacity: true)
        }
        func fail(_ message: String) -> CTTextError {
            CTTextError("character \(i + 1): \(message)")
        }
        while i < chars.count {
            let ch = chars[i]
            if ch == "«" || ch == "»" {
                if ch == "«" {
                    guard !literal else { throw fail("nested literal run") }
                    flush(); literal = true
                } else {
                    guard literal else { throw fail("unexpected literal-run close") }
                    flush(); literal = false
                }
                i += 1; continue
            }
            if ch == "{" || ch == "[" {
                let close: Character = ch == "{" ? "}" : "]"
                guard let end = chars[(i + 1)...].firstIndex(of: close) else { throw fail("unterminated token") }
                let token = String(chars[(i + 1)..<end])
                if ch == "[" {
                    let entry = try glyphBytes(token)
                    guard let index = dictionary.prefix(127).firstIndex(of: entry) else { throw fail("unknown dictionary text") }
                    flush(); out.append(UInt8(0x21 + index))
                } else if token.count == 3, token.first == "g", let value = UInt8(token.dropFirst(), radix: 16), value >= 0xA0 {
                    run.append(value)
                } else {
                    let encoded = try encodeTag(token, position: i + 1)
                    guard !literal || (encoded.count == 1 && encoded[0] >= 0x21) else {
                        throw fail("controls are not allowed inside literal glyph runs")
                    }
                    flush(); out += encoded
                }
                i = end + 1; continue
            }
            if ch.isNewline {
                guard !literal else { throw fail("newline inside literal glyph run") }
                flush(); out.append(5); i += 1; continue
            }
            guard let byte = Self.characters[String(ch)] else {
                throw fail("unsupported glyph \(String(reflecting: String(ch))); use a verified {gXX} or control tag")
            }
            run.append(byte); i += 1
        }
        guard !literal else { throw fail("unterminated literal glyph run") }
        flush()
        return out
    }

    public func decode(_ bytes: [UInt8]) throws -> String {
        guard bytes.count <= Self.maximumBytes else { throw CTTextError("text stream exceeds 1 MiB") }
        var i = 0, result = ""
        var run: [UInt8] = []
        func glyphText(_ b: UInt8) -> String { Self.glyphs[b] ?? "{g\(Self.hex(b))}" }
        func flush() {
            guard !run.isEmpty else { return }
            let expanded = run.flatMap { $0 >= 0xA0 ? [$0] : dictionary[Int($0) - 0x21] }
            if pack(expanded) == run { result += expanded.map(glyphText).joined() }
            else {
                result += "«" + run.map { b in
                    b >= 0xA0 ? glyphText(b) : "{dict \(Self.hex(b - 0x21))}"
                }.joined() + "»"
            }
            run.removeAll(keepingCapacity: true)
        }
        while i < bytes.count {
            let offset = i, byte = bytes[i]; i += 1
            if byte >= 0x21 { run.append(byte); continue }
            flush()
            if Self.operands.contains(byte) {
                guard i < bytes.count else { throw CTTextError("byte \(offset): truncated control operand") }
                let arg = bytes[i]; i += 1
                switch byte {
                case 1, 2: result += "{wide \(Self.hex(byte))\(Self.hex(arg))}"
                case 3: result += "{wait \(Self.hex(arg))}"
                case 0x12:
                    if arg == 0 { result += "{tech}" }
                    else if arg == 1 { result += "{enemy}" }
                    else { result += "{ext \(Self.hex(arg))}" }
                default: break
                }
            } else { result += "{\(Self.tags[byte]!)}" }
        }
        flush()
        return result
    }

    private func glyphBytes(_ string: String) throws -> [UInt8] {
        try string.map { ch in
            guard let value = Self.characters[String(ch)] else { throw CTTextError("unsupported glyph in dictionary reference") }
            return value
        }
    }
    private func encodeTag(_ tag: String, position: Int) throws -> [UInt8] {
        if let code = Self.codes[tag] { return [code] }
        if tag == "tech" { return [0x12, 0] }
        if tag == "enemy" { return [0x12, 1] }
        if tag.hasPrefix("ext ["), tag.hasSuffix("]") {
            let bytes = try glyphBytes(String(tag.dropFirst(5).dropLast()))
            if let index = dictionary.firstIndex(of: bytes), index >= 31 {
                return [0x12, UInt8(index - 31 + 8)]
            }
        }
        if tag.count == 3, tag.first == "$", let value = UInt8(tag.dropFirst(), radix: 16) { return [value] }
        let parts = tag.split(separator: " ", omittingEmptySubsequences: false)
        if parts.count == 2 {
            if parts[0] == "wide", parts[1].count == 4, let value = UInt16(parts[1], radix: 16), (0x100...0x2FF).contains(value) {
                return [UInt8(value >> 8), UInt8(value & 255)]
            }
            if parts[1].count == 2, let value = UInt8(parts[1], radix: 16) {
                switch parts[0] {
                case "dict" where value < 127: return [0x21 + value]
                case "wait": return [3, value]
                case "ext": return [0x12, value]
                default: break
                }
            }
        }
        throw CTTextError("character \(position): unknown control {\(tag)}")
    }
    private func pack(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = [], i = 0
        while i < bytes.count {
            if let index = candidates[bytes[i]]?.first(where: { index in
                let value = dictionary[index]
                return i + value.count <= bytes.count && bytes[i..<(i + value.count)].elementsEqual(value)
            }) {
                output.append(UInt8(0x21 + index)); i += dictionary[index].count
            } else { output.append(bytes[i]); i += 1 }
        }
        return output
    }
    private static func hex(_ byte: UInt8) -> String { String(format: "%02X", byte) }
}
