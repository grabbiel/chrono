// PNG+Indexed.swift — indexed (mode P) PNG writer, the counterpart of
// PNG.readIndexed: 1/2/4/8-bit indices, PLTE from BGR555 (SNES DAC ramp).
import Foundation

extension PNG {
    public static func writeIndexed(_ png: IndexedPNG) throws -> Data {
        let depth = png.bitDepth
        guard [1, 2, 4, 8].contains(depth), png.indices.count == png.width * png.height,
              !png.palette.isEmpty, png.palette.count <= 1 << depth else {
            throw PNGError.unsupported("indexed write: depth \(depth), \(png.palette.count) colours")
        }
        let stride = (png.width * depth + 7) / 8
        var raw = [UInt8]()
        raw.reserveCapacity(png.height * (1 + stride))
        for y in 0..<png.height {
            raw.append(0) // filter: none
            var line = [UInt8](repeating: 0, count: stride)
            for x in 0..<png.width {
                let v = png.indices[y * png.width + x] & UInt8((1 << depth) - 1)
                line[x * depth / 8] |= v << UInt8(8 - depth - (x * depth) % 8)
            }
            raw.append(contentsOf: line)
        }
        var out = Data(signature)
        func chunk(_ type: String, _ body: [UInt8]) {
            out.append(contentsOf: UInt32(body.count).bigEndianBytes)
            out.append(contentsOf: Array(type.utf8))
            out.append(contentsOf: body)
            out.append(contentsOf: crc32(Array(type.utf8) + body).bigEndianBytes)
        }
        var ihdr = [UInt8]()
        ihdr.append(contentsOf: UInt32(png.width).bigEndianBytes)
        ihdr.append(contentsOf: UInt32(png.height).bigEndianBytes)
        ihdr.append(UInt8(depth)); ihdr.append(3); ihdr.append(0); ihdr.append(0); ihdr.append(0)
        chunk("IHDR", ihdr)
        chunk("PLTE", png.palette.flatMap { [$0.srgb.r, $0.srgb.g, $0.srgb.b] })
        var idat: [UInt8] = [0x78, 0x01]
        idat.append(contentsOf: try deflate(raw))
        idat.append(contentsOf: adler32(raw).bigEndianBytes)
        chunk("IDAT", idat)
        chunk("IEND", [])
        return out
    }
}
