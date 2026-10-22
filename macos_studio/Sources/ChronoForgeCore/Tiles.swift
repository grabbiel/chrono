// Tiles.swift — SNES planar tile decode (4bpp and 2bpp), 8x8 tiles.
import Foundation

public enum TileDepth: Int, Sendable, Codable {
    case bpp2 = 2
    case bpp4 = 4

    public var bytesPerTile: Int { self == .bpp4 ? 32 : 16 }
}

public enum TileDecoder {
    /// Offset in a tile of plane p's byte for row r. SNES layout (fullsnes,
    /// "Tile/Character Data"; the same as `PPUFrame.storeTiles` and VRAM):
    /// planes 0 and 1 of row r are bytes 2r and 2r+1 (one little-endian word
    /// per row), and a 4bpp tile's planes 2 and 3 follow 16 bytes later.
    @inline(__always)
    public static func planeByte(_ p: Int, row: Int) -> Int {
        (p >= 2 ? 16 : 0) + 2 * row + (p & 1)
    }

    /// Decode planar SNES tile data into row-major palette-index bytes
    /// (one UInt8 per pixel, 64 per tile); bit (7-col) is pixel col.
    public static func decodeIndices(_ data: [UInt8], depth: TileDepth, tileCount: Int? = nil) -> [UInt8] {
        let bpp = depth == .bpp4 ? 4 : 2
        let tiles = tileCount ?? (data.count / depth.bytesPerTile)
        var out = [UInt8](repeating: 0, count: tiles * 64)
        for t in 0..<tiles {
            let base = t * depth.bytesPerTile
            guard base + depth.bytesPerTile <= data.count else { break }
            for row in 0..<8 {
                for col in 0..<8 {
                    let bit: UInt8 = UInt8(7 - col)
                    var idx: UInt8 = 0
                    for p in 0..<bpp {
                        let byte = data[base + planeByte(p, row: row)]
                        if byte & (1 << bit) != 0 { idx |= (1 << p) }
                    }
                    out[t * 64 + row * 8 + col] = idx
                }
            }
        }
        return out
    }

    /// Encode row-major palette indices back to planar SNES tile bytes.
    public static func encodePlanar(_ indices: [UInt8], depth: TileDepth) -> [UInt8] {
        let bpp = depth == .bpp4 ? 4 : 2
        let tiles = indices.count / 64
        var out = [UInt8](repeating: 0, count: tiles * depth.bytesPerTile)
        for t in 0..<tiles {
            let base = t * depth.bytesPerTile
            for row in 0..<8 {
                for col in 0..<8 {
                    let idx = indices[t * 64 + row * 8 + col]
                    for p in 0..<bpp where idx & (1 << p) != 0 {
                        out[base + planeByte(p, row: row)] |= UInt8(1 << (7 - col))
                    }
                }
            }
        }
        return out
    }
}
