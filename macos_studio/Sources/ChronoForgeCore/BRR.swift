// BRR.swift — SNES BRR sample codec (hardware-exact integer recursions).
//
// Block: [hdr: shift<<4 | filter<<2 | loop<<1 | end][8 bytes of 4-bit ADPCM]
// Filters (identical recursions to re_workspace/tools/ct_audio.py):
//   0: y = x
//   1: y = x + y1 + (-y1 >> 4)
//   2: y = x + (61*y1 >> 5) + (-15*y2 >> 4)
//   3: y = x + (115*y1 >> 6) + (-13*y2 >> 4)
// shift==13 -> x = n >> 1 (i.e. (n<<13)>>1 scaled), shift==14 -> x = 0.
// All >> are arithmetic (floor), matching Python on negative values.
import Foundation

public enum BRR {
    public struct Decoded: Sendable {
        public var samples: [Int16]
        public var loopBlocks: [Int]
        public var blocks: Int
        public var invalidHeaders: Int
        public var endBitSet: Bool
    }

    @inline(__always)
    static func filter(_ f: Int, _ x: Int, _ y1: Int, _ y2: Int) -> Int {
        switch f {
        case 0:  return x
        case 1:  return x + y1 + ((-y1) >> 4)
        case 2:  return x + ((61 * y1) >> 5) + ((-15 * y2) >> 4)
        default: return x + ((115 * y1) >> 6) + ((-13 * y2) >> 4)
        }
    }

    @inline(__always)
    static func clamp16(_ v: Int) -> Int16 { Int16(max(-32768, min(32767, v))) }

    /// Decode `nBlocks` BRR blocks starting at `off`.
    public static func decode(_ blob: [UInt8], off: Int, nBlocks: Int) -> Decoded {
        var out = [Int16](repeating: 0, count: nBlocks * 16)
        var loops: [Int] = []
        var y1 = 0, y2 = 0, invalid = 0
        for b in 0..<nBlocks {
            let base = off + 9 * b
            guard base + 9 <= blob.count else { break }
            let hdr = Int(blob[base])
            let shift = (hdr >> 4) & 0xF, fltr = (hdr >> 2) & 3
            if shift > 14 { invalid += 1 }
            if hdr & 2 != 0 { loops.append(b) }
            for i in 0..<16 {
                let byte = blob[base + 1 + (i >> 1)]
                let raw = Int(i % 2 == 0 ? (byte >> 4) & 0xF : byte & 0xF)
                let n = raw >= 8 ? raw - 16 : raw
                let x = shift == 13 ? (n << 13) >> 1 : (shift == 14 ? 0 : n << shift)
                let y = clamp16(filter(fltr, x, y1, y2))
                out[b * 16 + i] = y
                y2 = y1; y1 = Int(y)
            }
        }
        let endBit = nBlocks > 0 ? (blob[off + 9 * (nBlocks - 1)] & 1) != 0 : false
        return Decoded(samples: out, loopBlocks: loops, blocks: nBlocks,
                       invalidHeaders: invalid, endBitSet: endBit)
    }

    /// Decode a sample blob laid out as the ROM stores them:
    /// [u16 LE payload_len][BRR blocks...].
    public static func decodeBlob(_ blob: [UInt8]) -> Decoded {
        guard blob.count >= 2 else { return Decoded(samples: [], loopBlocks: [], blocks: 0, invalidHeaders: 0, endBitSet: false) }
        let len = Int(blob[0]) | (Int(blob[1]) << 8)
        let n = (len > 0 && len % 9 == 0 && 2 + len <= blob.count) ? len / 9 : (blob.count - 2) / 9
        return decode(blob, off: 2, nBlocks: n)
    }

    /// Encode int16 samples to BRR blocks (greedy per-block filter/shift search,
    /// simulating the decoder's clamped feedback exactly).
    public static func encode(_ samples: [Int16], maxShift: Int = 12) -> [UInt8] {
        var out: [UInt8] = []
        var y1 = 0, y2 = 0
        let nBlocks = (samples.count + 15) / 16
        for b in 0..<nBlocks {
            var bestNibs = [Int](repeating: 0, count: 16)
            var bestHdr = 0
            var bestErr = Int.max
            var bestNy1 = y1, bestNy2 = y2
            let startY1 = y1, startY2 = y2
            for f in 0...3 {
                for s in 0...maxShift {
                    var ny1 = startY1, ny2 = startY2, err = 0
                    var nibs = [Int](repeating: 0, count: 16)
                    var bad = false
                    for i in 0..<16 {
                        let idx = b * 16 + i
                        let orig = idx < samples.count ? Int(samples[idx]) : 0
                        let pred = filter(f, 0, ny1, ny2)
                        // Quantize: choose nibble minimizing |orig - decoded|
                        var bestN = 0, bestD = Int.max
                        for cand in -8...7 {
                            let x = (s == 13) ? (cand << 13) >> 1 : (s == 14 ? 0 : cand << s)
                            let y = clamp16(x + pred)
                            let d = abs(Int(y) - orig)
                            if d < bestD { bestD = d; bestN = cand }
                            if bestD == 0 { break }
                        }
                        if bestD > 32767 { bad = true; break }
                        nibs[i] = bestN & 0xF
                        let x = (s == 13) ? (bestN << 13) >> 1 : (s == 14 ? 0 : bestN << s)
                        let y = clamp16(x + pred)
                        ny2 = ny1; ny1 = Int(y)
                        err = max(err, bestD)
                    }
                    if !bad && err < bestErr {
                        bestErr = err
                        bestNibs = nibs
                        bestHdr = (s << 4) | (f << 2)
                        bestNy1 = ny1; bestNy2 = ny2
                    }
                }
            }
            y1 = bestNy1; y2 = bestNy2
            var hdr = bestHdr
            if b == nBlocks - 1 { hdr |= 1 }        // end bit
            out.append(UInt8(hdr))
            for i in stride(from: 0, to: 16, by: 2) {
                out.append(UInt8((bestNibs[i] << 4) | (bestNibs[i + 1] & 0xF)))
            }
        }
        return out
    }

    /// Encode with a [u16 len] header, ROM blob style.
    public static func encodeBlob(_ samples: [Int16]) -> [UInt8] {
        let blocks = encode(samples)
        var out: [UInt8] = [UInt8(blocks.count & 0xFF), UInt8(blocks.count >> 8)]
        out.append(contentsOf: blocks)
        return out
    }
}
