// The dictionary compression of dialogue text: raw against packed bytes, the
// entries the packer chose and what each saved. It reads the codec's own
// output (compileMessage), so the bytes it reports are the ones a build
// writes (docs/text_codec.md).
import Foundation

public enum CTTextAnalyzer {
    /// A run of one kind in a compiled message.
    public struct Segment: Codable, Equatable, Sendable {
        public let kind: String                // glyphs | dictionary | control
        public let bytes: [UInt8]
        public let text: String                // glyph text, the entry's text, or the control byte
        public let entry: Int?                 // the dictionary entry ($21 + entry)
    }
    public struct EntryUse: Codable, Equatable, Sendable {
        public let entry: Int
        public let text: String
        public let uses: Int
        public let savedBytes: Int             // uses × (entry length − 1)
    }
    public struct Report: Encodable, Equatable, Sendable {
        public var schema = "ct-text-analysis/1"
        public let messages: Int
        public let rawBytes: Int               // compiled without the dictionary
        public let compressedBytes: Int        // as built
        public var savedBytes: Int { rawBytes - compressedBytes }
        public let entries: [EntryUse]         // used entries, most saving first
        public let unusedEntries: [Int]        // entries no message uses (skipped ones included)
        public let segments: [Segment]?        // one message only
        private enum CodingKeys: String, CodingKey {
            case schema, messages, rawBytes, compressedBytes, savedBytes, entries, unusedEntries, segments
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(schema, forKey: .schema); try c.encode(messages, forKey: .messages)
            try c.encode(rawBytes, forKey: .rawBytes); try c.encode(compressedBytes, forKey: .compressedBytes)
            try c.encode(savedBytes, forKey: .savedBytes); try c.encode(entries, forKey: .entries)
            try c.encode(unusedEntries, forKey: .unusedEntries); try c.encodeIfPresent(segments, forKey: .segments)
        }
    }

    static let operands: Set<UInt8> = [1, 2, 3, 0x12]

    static func glyphText(_ bytes: [UInt8]) -> String {
        bytes.map { CTTextCodec.glyphText($0) ?? String(format: "{g%02X}", $0) }.joined()
    }

    /// The runs of compiled message bytes.
    public static func segments(_ bytes: [UInt8], codec: CTTextCodec) -> [Segment] {
        let entries = codec.dictionaryEntries
        var out: [Segment] = [], glyphs: [UInt8] = [], i = 0
        func flush() {
            if !glyphs.isEmpty { out.append(.init(kind: "glyphs", bytes: glyphs, text: glyphText(glyphs), entry: nil)) }
            glyphs.removeAll()
        }
        while i < bytes.count {
            let b = bytes[i]
            if b >= 0xA0 { glyphs.append(b); i += 1; continue }
            flush()
            if b >= 0x21, Int(b) - 0x21 < entries.count {
                let e = Int(b) - 0x21
                out.append(.init(kind: "dictionary", bytes: [b], text: glyphText(entries[e]), entry: e))
                i += 1
            } else {
                let n = operands.contains(b) && i + 1 < bytes.count ? 2 : 1
                out.append(.init(kind: "control", bytes: Array(bytes[i..<(i + n)]), text: String(format: "$%02X", b), entry: nil))
                i += n
            }
        }
        flush()
        return out
    }

    /// Each message compiled as a build compiles it, against itself without the dictionary.
    public static func analyze(_ texts: [String], codec: CTTextCodec) throws -> Report {
        let entries = codec.dictionaryEntries
        var raw = 0, packed = 0, uses = [Int](repeating: 0, count: entries.count)
        var last: [Segment] = []
        for text in texts {
            let bytes = try codec.compileMessage(text)
            raw += try codec.compileMessage(text, compress: false).count
            packed += bytes.count
            last = segments(bytes, codec: codec)
            for s in last { if let e = s.entry { uses[e] += 1 } }
        }
        let used = uses.indices.filter { uses[$0] > 0 }.map { e in
            EntryUse(entry: e, text: glyphText(entries[e]), uses: uses[e], savedBytes: uses[e] * (entries[e].count - 1))
        }
        return Report(messages: texts.count, rawBytes: raw, compressedBytes: packed,
                      entries: used.sorted { ($0.savedBytes, -$0.entry) > ($1.savedBytes, -$1.entry) },
                      unusedEntries: uses.indices.filter { uses[$0] == 0 },
                      segments: texts.count == 1 ? last : nil)
    }
}
