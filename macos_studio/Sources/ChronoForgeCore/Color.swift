// Color.swift — BGR555 <-> sRGB conversion (SNES authoritative color).
import Foundation

/// One SNES color word: 0BBBBBGGGGGRRRRR.
public struct BGR555: Hashable, Sendable, Codable {
    public var word: UInt16
    public init(word: UInt16) { self.word = word & 0x7FFF }

    public init(r5: UInt8, g5: UInt8, b5: UInt8) {
        word = (UInt16(b5 & 31) << 10) | (UInt16(g5 & 31) << 5) | UInt16(r5 & 31)
    }

    /// Parse the schema hex form, e.g. "0x7FFF".
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
        guard let v = UInt16(s, radix: 16), v <= 0x7FFF else { return nil }
        word = v
    }
    public var hex: String { String(format: "0x%04X", word) }

    public var r5: UInt8 { UInt8(word & 31) }
    public var g5: UInt8 { UInt8((word >> 5) & 31) }
    public var b5: UInt8 { UInt8((word >> 10) & 31) }

    /// Per-channel expansion (c<<3)|(c>>2) — the SNES DAC ramp.
    public var srgb: (r: UInt8, g: UInt8, b: UInt8) {
        func c8(_ c: UInt8) -> UInt8 { (c << 3) | (c >> 2) }
        return (c8(r5), c8(g5), c8(b5))
    }

    /// Nearest BGR555 word for an 8-bit sRGB triple.
    public static func from(srgbR r: UInt8, _ g: UInt8, _ b: UInt8) -> BGR555 {
        BGR555(r5: r >> 3, g5: g >> 3, b5: b >> 3)
    }
}
