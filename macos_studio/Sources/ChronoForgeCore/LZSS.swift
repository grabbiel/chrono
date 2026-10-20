// LZSS.swift — Chrono Trigger LZSS (LZ77 variant) in pure Swift.
//
// Format (transcribed from Decomp_ToWram, $C3:0557-$C3:08B2, ChronoRET
// bankC3.asm — byte-exact decompilation of this ROM):
//   +0  u16 W: segment 1's items run from +2 to +2+W-1; its end marker is at +2+W.
//   Items come in groups. Each group starts with a control byte c:
//     - c == 0: 8 literal bytes follow.
//     - else: one item per bit of c from bit 0 up (8 items, except after a
//       segment change): 0 bit = one literal byte; 1 bit = 16-bit LE
//       back-reference v, copied byte-by-byte forward from (out - dist)
//       (overlap repeats bytes):
//         lz12: dist = v & $0FFF, len = (v >> 12) + 3
//         lz11: dist = v & $07FF, len = (v >> 11) + 3
//   At a segment end: marker byte m + u16 offset. m & $3F == 0 -> end of
//   stream. Else next segment's end marker sits at (srcStart + offset),
//   items resume right after the 3-byte record, and the next non-zero
//   control group has (m & $3F) items.
//   Bits 6-7 of the FIRST end marker select the mode: 0 = lz12, nonzero = lz11.
import Foundation

public enum LZSSMode: Int, Sendable {
    case lz11 = 11
    case lz12 = 12
    var window: Int { self == .lz12 ? 4096 : 2048 }
    var lenBits: Int { self == .lz12 ? 4 : 5 }
    /// Max match length: length field (5-bit lz11 / 4-bit lz12) + 3.
    public var maxLen: Int { (1 << (self == .lz12 ? 4 : 5)) - 1 + 3 }
}

public enum LZSSError: Error, Equatable, CustomStringConvertible {
    case truncated(String)
    case badBackReference(distance: Int, output: Int)
    case overlong(Int)
    public var description: String {
        switch self {
        case .truncated(let w): return "LZSS truncated: \(w)"
        case .badBackReference(let d, let o): return "LZSS back-reference past start (dist \(d) at out \(o))"
        case .overlong(let n): return "LZSS output exceeded \(n) bytes"
        }
    }
}

public enum LZSS {
    /// Detect lz11/lz12 from the end-marker byte at offset 2+W (nil if the
    /// stream is too short to inspect).
    public static func detectMode(in src: [UInt8]) -> LZSSMode? {
        guard src.count >= 3 else { return nil }
        let w = int(src, 0)
        guard 2 + w < src.count else { return nil }
        return (src[2 + w] & 0xC0) != 0 ? .lz11 : .lz12
    }

    /// Decompress a packed block. Returns (bytes, detected mode).
    public static func decompress(_ src: [UInt8], maxOutput: Int = 1 << 22) throws -> (out: [UInt8], mode: LZSSMode) {
        let stream = try decompressStream(src, maxOutput: maxOutput)
        return (stream.out, stream.mode)
    }

    /// Decompress a packed stream at the start of `src`, which may continue past
    /// it; `length` is the stream's packed size (through its final end marker).
    public static func decompressStream(_ src: [UInt8], maxOutput: Int = 1 << 22) throws
        -> (out: [UInt8], mode: LZSSMode, length: Int) {
        guard src.count >= 3 else { throw LZSSError.truncated("header") }
        let w = int(src, 0)
        var segEnd = 2 + w
        guard segEnd < src.count else { throw LZSSError.truncated("first end marker past source") }
        let mode: LZSSMode = (src[segEnd] & 0xC0) != 0 ? .lz11 : .lz12

        var out: [UInt8] = []
        out.reserveCapacity(min(w * 2, maxOutput))
        var x = 2
        var groupLeft = 8

        func emit(_ b: UInt8) throws {
            if out.count >= maxOutput { throw LZSSError.overlong(maxOutput) }
            out.append(b)
        }

        decode: while true {
            groupLeft = 8                       // .m12_7E_group: fresh group
            while true {                        // .m12_7E_next
                if x == segEnd {
                    guard x < src.count else { throw LZSSError.truncated("marker") }
                    let m = src[x]
                    let cnt = Int(m & 0x3F)
                    if cnt == 0 { x += 1; break decode }  // end marker
                    guard x + 3 <= src.count else { throw LZSSError.truncated("segment record") }
                    groupLeft = cnt
                    segEnd = int(src, x + 1)              // offset from src start
                    x += 3
                    continue
                }
                guard x < src.count else { throw LZSSError.truncated("control byte") }
                let c = src[x]
                if c == 0 {                               // run of 8 literals
                    guard x + 9 <= src.count else { throw LZSSError.truncated("literal run") }
                    for i in 1...8 { try emit(src[x + i]) }
                    x += 9
                    continue decode                       // next group (groupLeft = 8)
                }
                x += 1
                var ctrl = c
                while true {
                    if ctrl & 1 != 0 {                    // back-reference
                        guard x + 2 <= src.count else { throw LZSSError.truncated("back-ref") }
                        let v = int(src, x)
                        x += 2
                        let dist: Int, len: Int
                        if mode == .lz12 { dist = v & 0x0FFF; len = (v >> 12) + 3 }
                        else { dist = v & 0x07FF; len = (v >> 11) + 3 }
                        guard dist > 0, dist <= out.count else {
                            throw LZSSError.badBackReference(distance: dist, output: out.count)
                        }
                        var pos = out.count - dist
                        for _ in 0..<len {
                            try emit(out[pos])            // forward copy: overlap repeats
                            pos += 1
                        }
                    } else {                              // literal
                        guard x < src.count else { throw LZSSError.truncated("literal") }
                        try emit(src[x]); x += 1
                    }
                    groupLeft -= 1
                    if groupLeft == 0 { continue decode }
                    ctrl >>= 1
                }
            }
        }
        return (out, mode, x)
    }

    /// The original packer: Okumura's LZSS (binary-tree match finder) with the
    /// ROM's framing, identical to libctcodec's `ct_lzss_compress`. It rebuilds
    /// every pack in the ROM byte for byte (see ctcodec.c for the rules).
    /// Inputs longer than 65,535 bytes cannot be unpacked by the game (16-bit
    /// output length) and are refused with nil.
    public static func compress(_ src: [UInt8], mode: LZSSMode) -> [UInt8]? {
        guard src.count <= 0xFFFF else { return nil }
        let n = mode == .lz12 ? 4096 : 2048, f = mode == .lz12 ? 18 : 34
        let shift = mode == .lz12 ? 12 : 11, modeBits: UInt8 = mode == .lz12 ? 0x00 : 0x40
        let nilNode = n
        var text = [Int](repeating: 0, count: n + f - 1)
        var lson = [Int](repeating: nilNode, count: n + 1)
        var rson = [Int](repeating: nilNode, count: n + 257)
        var dad = [Int](repeating: nilNode, count: n + 1)
        var matchPos = 0, matchLen = 0

        func insert(_ r: Int) {
            var cmp = 1, p = n + 1 + text[r]
            rson[r] = nilNode; lson[r] = nilNode
            matchLen = 0
            while true {
                if cmp >= 0 {
                    if rson[p] != nilNode { p = rson[p] } else { rson[p] = r; dad[r] = p; return }
                } else {
                    if lson[p] != nilNode { p = lson[p] } else { lson[p] = r; dad[r] = p; return }
                }
                var i = 1
                while i < f {
                    cmp = text[r + i] - text[p + i]
                    if cmp != 0 { break }
                    i += 1
                }
                if i > matchLen {
                    matchPos = p; matchLen = i
                    if i >= f { break }
                }
            }
            // A full-length match replaces the old node.
            dad[r] = dad[p]; lson[r] = lson[p]; rson[r] = rson[p]
            dad[lson[p]] = r; dad[rson[p]] = r
            if rson[dad[p]] == p { rson[dad[p]] = r } else { lson[dad[p]] = r }
            dad[p] = nilNode
        }

        func delete(_ p: Int) {
            guard dad[p] != nilNode else { return }
            var q: Int
            if rson[p] == nilNode { q = lson[p] }
            else if lson[p] == nilNode { q = rson[p] }
            else {
                q = lson[p]
                if rson[q] != nilNode {
                    while rson[q] != nilNode { q = rson[q] }
                    rson[dad[q]] = lson[q]
                    dad[lson[q]] = dad[q]
                    lson[q] = lson[p]
                    dad[lson[p]] = q
                }
                rson[q] = rson[p]
                dad[rson[p]] = q
            }
            dad[q] = dad[p]
            if rson[dad[p]] == p { rson[dad[p]] = q } else { lson[dad[p]] = q }
            dad[p] = nilNode
        }

        // Items: (reference?, byte or distance | (length - 3) << shift).
        var items: [(ref: Bool, value: Int)] = []
        var r = 0, s = f
        var length = min(f, src.count)
        for i in 0..<length { text[i] = Int(src[i]) }
        var next = length
        if length > 0 { insert(r) }
        while length > 0 {
            var mlen = min(matchLen, length)
            if mlen <= 2 {
                mlen = 1
                items.append((false, text[r]))
            } else {
                items.append((true, ((r - matchPos) & (n - 1)) | (mlen - 3) << shift))
            }
            var i = 0
            while i < mlen && next < src.count {
                let c = Int(src[next]); next += 1
                delete(s)
                text[s] = c
                if s < f - 1 { text[s + n] = c }
                s = (s + 1) & (n - 1); r = (r + 1) & (n - 1)
                insert(r)
                i += 1
            }
            while i < mlen {
                i += 1
                delete(s)
                s = (s + 1) & (n - 1); r = (r + 1) & (n - 1)
                length -= 1
                if length > 0 { insert(r) }
            }
        }

        func group(_ slice: ArraySlice<(ref: Bool, value: Int)>) -> [UInt8] {
            var ctrl = (0xFF << slice.count) & 0xFF        // unused bits of a partial group set
            var body: [UInt8] = []
            for (k, item) in slice.enumerated() {
                if item.ref {
                    ctrl |= 1 << k
                    body += [UInt8(item.value & 0xFF), UInt8(item.value >> 8)]
                } else {
                    body.append(UInt8(item.value))
                }
            }
            return [UInt8(ctrl)] + body
        }
        let whole = items.count / 8 * 8, rest = items.count - whole
        var out: [UInt8] = [0, 0]
        for g in stride(from: 0, to: whole, by: 8) { out += group(items[g..<g + 8]) }
        out[0] = UInt8((out.count - 2) & 0xFF); out[1] = UInt8((out.count - 2) >> 8)
        if rest > 0 {
            let last = group(items[whole...])
            let final = out.count + 3 + last.count
            out += [UInt8(rest) | modeBits, UInt8(final & 0xFF), UInt8(final >> 8)] + last
        }
        out.append(modeBits)
        return out.count <= 0x10000 ? out : nil
    }

    @inline(__always) static func int(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) | (Int(b[i + 1]) << 8)
    }
}
