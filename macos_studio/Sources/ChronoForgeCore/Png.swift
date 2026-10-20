// Png.swift — minimal PNG reader (indexed, 2/4/8-bit) and RGBA8 writer.
// Inflate/deflate via the system Compression framework (raw deflate: strip
// the 2-byte zlib header and 4-byte adler32 that PNG's IDAT wraps around).
import Foundation
import Compression

public struct IndexedPNG: Sendable {
    public var width: Int
    public var height: Int
    public var bitDepth: Int          // 2 or 4 (or 8)
    public var palette: [BGR555]      // from PLTE (sRGB -> BGR555 truncation)
    public var indices: [UInt8]       // row-major, width*height

    public var colorsUsed: Int {
        var seen = Set<UInt8>()
        for i in indices { seen.insert(i) }
        return seen.count
    }
}

public enum PNGError: Error, CustomStringConvertible {
    case badSignature, missingChunk(String), unsupported(String), inflateFailed
    public var description: String {
        switch self {
        case .badSignature: return "bad PNG signature"
        case .missingChunk(let c): return "missing \(c) chunk"
        case .unsupported(let s): return "unsupported PNG: \(s)"
        case .inflateFailed: return "IDAT inflate failed"
        }
    }
}

public enum PNG {
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    // MARK: Reading (indexed)
    public static func readIndexed(url: URL) throws -> IndexedPNG {
        try readIndexed(data: try Data(contentsOf: url))
    }

    public static func readIndexed(data: Data) throws -> IndexedPNG {
        let b = [UInt8](data)
        guard b.count > 8, Array(b[0..<8]) == signature else { throw PNGError.badSignature }
        var off = 8
        var w = 0, h = 0, depth = 0, colorType = 0
        var palette: [BGR555] = []
        var idat: [UInt8] = []
        while off + 8 <= b.count {
            let len = Int(b[off]) << 24 | Int(b[off+1]) << 16 | Int(b[off+2]) << 8 | Int(b[off+3])
            let type = String(decoding: b[off+4..<off+8], as: UTF8.self)
            let bodyStart = off + 8
            // Array (not slice) so indices are 0-based.
            let body = Array(b[bodyStart..<min(bodyStart + len, b.count)])
            switch type {
            case "IHDR":
                w = Int(body[0]) << 24 | Int(body[1]) << 16 | Int(body[2]) << 8 | Int(body[3])
                h = Int(body[4]) << 24 | Int(body[5]) << 16 | Int(body[6]) << 8 | Int(body[7])
                depth = Int(body[8]); colorType = Int(body[9])
            case "PLTE":
                var i = body.startIndex
                while i + 2 < body.endIndex {
                    palette.append(.from(srgbR: body[i], (body[i+1]), body[i+2]))
                    i += 3
                }
            case "IDAT":
                idat.append(contentsOf: body)
            case "IEND": break
            default: break
            }
            off = bodyStart + len + 4
        }
        guard colorType == 3 else { throw PNGError.unsupported("colorType \(colorType) (need indexed/mode P)") }
        guard depth == 1 || depth == 2 || depth == 4 || depth == 8 else {
            throw PNGError.unsupported("bitDepth \(depth)")
        }
        guard !idat.isEmpty else { throw PNGError.missingChunk("IDAT") }
        let raw = try inflate(idat)
        // Unfilter
        let bpp = max(1, depth / 8)
        let stride = (w * depth + 7) / 8
        var out = [UInt8](repeating: 0, count: h * stride)
        var prev = [UInt8](repeating: 0, count: stride)
        for y in 0..<h {
            guard y * (stride + 1) < raw.count else { throw PNGError.inflateFailed }
            let fType = raw[y * (stride + 1)]
            var line = Array(raw[(y * (stride + 1) + 1)..<min((y * (stride + 1) + 1) + stride, raw.count)])
            if line.count < stride { line += [UInt8](repeating: 0, count: stride - line.count) }
            unfilter(fType: fType, line: &line, prev: prev, bpp: bpp)
            out.replaceSubrange((y * stride)..<((y + 1) * stride), with: line)
            prev = line
        }
        // Extract indices
        var indices = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let byte = out[y * stride + (x * depth) / 8]
                let shift = UInt8(8 - depth - (x % (8 / depth)) * depth)
                let mask = UInt8((1 << depth) - 1)
                indices[y * w + x] = (byte >> shift) & mask
            }
        }
        return IndexedPNG(width: w, height: h, bitDepth: depth, palette: palette, indices: indices)
    }

    static func unfilter(fType: UInt8, line: inout [UInt8], prev: [UInt8], bpp: Int) {
        switch fType {
        case 1: for i in bpp..<line.count { line[i] = line[i] &+ line[i - bpp] }
        case 2: for i in 0..<line.count { line[i] = line[i] &+ prev[i] }
        case 3: for i in 0..<line.count {
            let a = i >= bpp ? Int(line[i - bpp]) : 0
            line[i] = line[i] &+ UInt8((a + Int(prev[i])) / 2)
        }
        case 4: for i in 0..<line.count {
            let a = i >= bpp ? Int(line[i - bpp]) : 0
            let b = Int(prev[i])
            let c = i >= bpp ? Int(prev[i - bpp]) : 0
            let p = a + b - c
            let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
            let pred = (pa <= pb && pa <= pc) ? a : (pb <= pc ? b : c)
            line[i] = line[i] &+ UInt8(pred)
        }
        default: break
        }
    }

    // MARK: Writing (RGBA8 -> indexed-free truecolor PNG)
    /// Write 8-bit RGBA pixels as a non-interlaced PNG.
    public static func writeRGBA(width: Int, height: Int, rgba: [UInt8]) throws -> Data {
        var raw = [UInt8]()
        raw.reserveCapacity(height * (1 + width * 4))
        for y in 0..<height {
            raw.append(0) // filter: none
            raw.append(contentsOf: rgba[(y * width * 4)..<((y + 1) * width * 4)])
        }
        let deflated = try deflate(raw)
        var out = Data(signature)
        func chunk(_ type: String, _ body: [UInt8]) {
            out.append(contentsOf: UInt32(body.count).bigEndianBytes)
            out.append(contentsOf: Array(type.utf8))
            out.append(contentsOf: body)
            out.append(contentsOf: crc32(Array(type.utf8) + body).bigEndianBytes)
        }
        var ihdr = [UInt8]()
        ihdr.append(contentsOf: UInt32(width).bigEndianBytes)
        ihdr.append(contentsOf: UInt32(height).bigEndianBytes)
        ihdr.append(8); ihdr.append(6); ihdr.append(0); ihdr.append(0); ihdr.append(0)
        chunk("IHDR", ihdr)
        // zlib wrapper around raw deflate
        var idat: [UInt8] = [0x78, 0x01]
        idat.append(contentsOf: deflated)
        idat.append(contentsOf: adler32(raw).bigEndianBytes)
        chunk("IDAT", idat)
        chunk("IEND", [])
        return out
    }

    // MARK: Compression helpers
    static func inflate(_ zlib: [UInt8]) throws -> [UInt8] {
        guard zlib.count > 6 else { throw PNGError.inflateFailed }
        let payload = Array(zlib[2..<(zlib.count - 4)])
        var out = [UInt8](repeating: 0, count: max(1 << 16, payload.count * 16))
        for _ in 0..<6 {
            let n = payload.withUnsafeBufferPointer { p in
                out.withUnsafeMutableBufferPointer { d in
                    compression_decode_buffer(d.baseAddress!, d.count,
                        p.baseAddress!, p.count, nil, COMPRESSION_ZLIB)
                }
            }
            if n > 0 { return Array(out[0..<n]) }
            out = [UInt8](repeating: 0, count: out.count * 4)
        }
        throw PNGError.inflateFailed
    }

    static func deflate(_ raw: [UInt8]) throws -> [UInt8] {
        var out = [UInt8](repeating: 0, count: raw.count + 512)
        let n = raw.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                compression_encode_buffer(d.baseAddress!, d.count,
                    s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0 else { throw PNGError.inflateFailed } // reuse error: encode failed
        return Array(out[0..<n])
    }

    static func adler32(_ data: [UInt8]) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        return (b << 16) | a
    }

    static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            return c
        }
    }()
    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

extension UInt32 { var bigEndianBytes: [UInt8] { [UInt8((self >> 24) & 0xFF), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)] } }
