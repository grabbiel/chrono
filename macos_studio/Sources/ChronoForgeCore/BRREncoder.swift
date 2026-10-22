// BRREncoder.swift — BRR as the S-DSP decodes it, and an encoder that
// searches every block's filter and shift against that decode.
//
// `BRR.decode` keeps the 16-bit recursion ct_audio.py uses (its parity test
// pins it). The S-DSP works one bit lower (fullsnes "BRR Samples"): a nibble
// scales to (n << shift) >> 1, shifts 13-15 act as 12 with the nibble SAR 3,
// and each filtered sample is clamped to 16 bits and kept as 15 bits with
// wraparound. `decodeDSP` is that recursion, the same arithmetic as
// `SDSP.decode`; `BRRParity` shows the S-DSP plays exactly these samples.
import Foundation

extension BRR {
    /// A nibble as the S-DSP scales it.
    @inline(__always)
    static func dspScale(_ n: Int, _ shift: Int) -> Int {
        shift <= 12 ? (n << shift) >> 1 : (n >> 3) << 11
    }

    /// One sample as the S-DSP keeps it: filtered, clamped to 16 bits, 15 bits kept.
    @inline(__always)
    static func dspSample(_ filter: Int, _ x: Int, _ y1: Int, _ y2: Int) -> Int {
        Int(Int16(truncatingIfNeeded: Int(clamp16(BRR.filter(filter, x, y1, y2))) << 1)) >> 1
    }

    /// Decode bare 9-byte blocks to the S-DSP's 15-bit samples, starting from
    /// filter history `y1`, `y2` (newest first). Returns the samples and the
    /// history after the last block.
    public static func decodeDSP(_ blocks: ArraySlice<UInt8>, y1: Int = 0, y2: Int = 0) -> (samples: [Int16], y1: Int, y2: Int) {
        var out: [Int16] = []
        out.reserveCapacity(blocks.count / 9 * 16)
        var y1 = y1, y2 = y2
        var base = blocks.startIndex
        while base + 9 <= blocks.endIndex {
            let header = Int(blocks[base])
            let shift = header >> 4, filter = (header >> 2) & 3
            for i in 0..<16 {
                let byte = Int(blocks[base + 1 + (i >> 1)])
                let raw = i & 1 == 0 ? byte >> 4 : byte & 15
                let y = dspSample(filter, dspScale(raw >= 8 ? raw - 16 : raw, shift), y1, y2)
                out.append(Int16(y))
                y2 = y1; y1 = y
            }
            base += 9
        }
        return (out, y1, y2)
    }

    public static func decodeDSP(_ blocks: [UInt8]) -> [Int16] { decodeDSP(blocks[...]).samples }

    /// The samples a looping voice plays: every block once, then the blocks
    /// from `loopBlock` repeated `passes` times, each pass continuing the
    /// filter history the hardware carries across the jump.
    public static func decodeDSPLooping(_ blocks: [UInt8], loopBlock: Int, passes: Int) -> [Int16] {
        var (out, y1, y2) = decodeDSP(blocks[...])
        let loop = blocks[(9 * loopBlock)...]
        for _ in 0..<passes {
            let pass = decodeDSP(loop, y1: y1, y2: y2)
            out += pass.samples; y1 = pass.y1; y2 = pass.y2
        }
        return out
    }
}

/// Encodes 16-bit PCM to BRR blocks scored against `BRR.decodeDSP`. Each
/// block tries every filter with shifts 0...`maxShift`, rounding each nibble
/// to the nearest decoded value (checking its neighbours, so clamping and the
/// 15-bit wrap are never chosen by accident). `beam` > 1 keeps that many
/// candidate histories across blocks (filters 1-3 make a block's best choice
/// depend on the previous block's last two samples), so a block may take a
/// slightly worse fit that leaves a better history. `beam` 1 is greedy.
public enum BRREncoder {
    public struct Options: Equatable, Sendable {
        public var maxShift = 12
        public var beam = 4
        /// Blocks forced to filter 0, so their decode does not depend on the
        /// history (a loop block is entered from two different histories).
        public var filterZeroBlocks: Set<Int> = [0]
        /// Set the end flag on the last block, and the loop flag with it.
        public var loop = false
        public init() {}
    }

    public struct Result: Sendable {
        /// Bare 9-byte blocks.
        public var blocks: [UInt8]
        /// The S-DSP's decode of `blocks` (15-bit).
        public var decoded: [Int16]
        /// Sum of squared error against the source, in 16-bit units.
        public var squaredError: Double
    }

    /// A kept block: its header, nibbles packed high-first, and the block before it.
    private struct Node { var parent: Int32; var header: UInt8; var nibbles: UInt64 }
    private struct State { var cost: Double; var y1: Int; var y2: Int; var node: Int32 }
    private struct Candidate { var state: State; var parent: Int32; var header: UInt8; var nibbles: UInt64 }

    /// `samples` is padded with zeros to whole blocks.
    public static func encode(_ samples: [Int16], options: Options = .init()) -> Result {
        let blockCount = max(1, (samples.count + 15) / 16)
        let target = (0..<blockCount * 16).map { $0 < samples.count ? Int(samples[$0]) : 0 }
        let beam = max(1, options.beam)
        let maxShift = max(0, min(12, options.maxShift))
        var nodes: [Node] = []
        nodes.reserveCapacity(blockCount * beam)
        var states = [State(cost: 0, y1: 0, y2: 0, node: -1)]
        var candidates: [Candidate] = []
        for b in 0..<blockCount {
            let filters = options.filterZeroBlocks.contains(b) ? 0...0 : 0...3
            candidates.removeAll(keepingCapacity: true)
            for state in states {
                for f in filters {
                    for shift in 0...maxShift {
                        // A nibble n decodes to n × step before filtering (shift 0: n SAR 1).
                        let step = shift == 0 ? 0.5 : Double(1 << (shift - 1))
                        var y1 = state.y1, y2 = state.y2, cost = state.cost, packed: UInt64 = 0
                        for i in 0..<16 {
                            let t = target[b * 16 + i]
                            let p = BRR.filter(f, 0, y1, y2)
                            // Nearest nibble ignoring clamps, then it and its neighbours exactly.
                            let guess = max(-8, min(7, Int(((Double(t) / 2 - Double(p)) / step).rounded())))
                            var bestN = guess, bestY = 0, bestE = Int.max
                            for n in max(-8, guess - 1)...min(7, guess + 1) {
                                let y = BRR.dspSample(f, BRR.dspScale(n, shift), y1, y2)
                                let e = (t - 2 * y) * (t - 2 * y)
                                if e < bestE { bestE = e; bestN = n; bestY = y }
                            }
                            packed = packed << 4 | UInt64(bestN & 15)
                            cost += Double(bestE)
                            y2 = y1; y1 = bestY
                        }
                        candidates.append(Candidate(state: State(cost: cost, y1: y1, y2: y2, node: -1), parent: state.node,
                                                    header: UInt8(shift << 4 | f << 2), nibbles: packed))
                    }
                }
            }
            // Keep the cheapest candidate per distinct history, then the best `beam`.
            candidates.sort { $0.state.cost < $1.state.cost }
            var seen = Set<Int>()
            states.removeAll(keepingCapacity: true)
            for c in candidates where states.count < beam {
                guard seen.insert(c.state.y1 &* 65536 &+ c.state.y2).inserted else { continue }
                var s = c.state
                s.node = Int32(nodes.count)
                nodes.append(Node(parent: c.parent, header: c.header, nibbles: c.nibbles))
                states.append(s)
            }
        }
        let best = states[0]
        var blocks = [UInt8](repeating: 0, count: blockCount * 9)
        var at = best.node, b = blockCount - 1
        while at >= 0 {
            let node = nodes[Int(at)]
            blocks[9 * b] = node.header
            for i in 0..<8 { blocks[9 * b + 1 + i] = UInt8(truncatingIfNeeded: node.nibbles >> UInt64(56 - 8 * i)) }
            at = node.parent; b -= 1
        }
        blocks[blocks.count - 9] |= options.loop ? 3 : 1
        return Result(blocks: blocks, decoded: BRR.decodeDSP(blocks), squaredError: best.cost)
    }

    /// Signal-to-noise ratio in dB of a 15-bit decode against 16-bit source
    /// PCM (decode × 2 is the 16-bit value); infinity when identical.
    public static func snr(source: [Int16], decoded: [Int16]) -> Double {
        var signal = 0.0, noise = 0.0
        for i in 0..<source.count {
            let s = Double(source[i]), d = i < decoded.count ? 2 * Double(decoded[i]) : 0
            signal += s * s; noise += (s - d) * (s - d)
        }
        if noise == 0 { return .infinity }
        if signal == 0 { return -.infinity }
        return 10 * log10(signal / noise)
    }

    /// Largest |source - 2 × decode| in 16-bit units.
    public static func maxError(source: [Int16], decoded: [Int16]) -> Int {
        var worst = 0
        for i in 0..<source.count {
            worst = max(worst, abs(Int(source[i]) - 2 * Int(i < decoded.count ? decoded[i] : 0)))
        }
        return worst
    }
}
