// WAV.swift — minimal RIFF/WAVE reader + writer (16-bit PCM).
import Foundation

public struct WAV: Sendable {
    public var sampleRate: Int
    public var samples: [Int16]

    /// Parse a mono or stereo 16-bit PCM WAV; stereo is downmixed by taking L.
    public static func read(url: URL) throws -> WAV {
        let data = try Data(contentsOf: url)
        return try read(data: data)
    }

    public static func read(data: Data) throws -> WAV {
        let b = [UInt8](data)
        guard b.count > 44, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else {
            throw WAVError.notWav
        }
        var off = 12
        var rate = 8000, channels = 1, bits = 16
        var pcm: ArraySlice<UInt8> = []
        while off + 8 <= b.count {
            let id = String(decoding: b[off..<off+4], as: UTF8.self)
            let size = Int(b[off+4]) | (Int(b[off+5]) << 8) | (Int(b[off+6]) << 16) | (Int(b[off+7]) << 24)
            switch id {
            case "fmt ":
                guard off + 8 + 16 <= b.count else { throw WAVError.truncated }
                channels = Int(b[off+10]) | (Int(b[off+11]) << 8)
                rate = Int(b[off+12]) | (Int(b[off+13]) << 8) | (Int(b[off+14]) << 16) | (Int(b[off+15]) << 24)
                bits = Int(b[off+22]) | (Int(b[off+23]) << 8)
                guard bits == 16 else { throw WAVError.unsupported("bits=\(bits)") }
            case "data":
                let start = off + 8
                let end = min(start + size, b.count)
                pcm = b[start..<end]
            default: break
            }
            off += 8 + size + (size & 1)
        }
        let frame = 2 * channels
        var out = [Int16]()
        out.reserveCapacity(pcm.count / frame)
        var i = pcm.startIndex
        while i + frame - 1 < pcm.endIndex {
            let lo = Int(pcm[i]); let hi = Int(Int8(bitPattern: pcm[i+1]))
            out.append(Int16(truncatingIfNeeded: lo | (hi << 8)))
            i += frame
        }
        return WAV(sampleRate: rate, samples: out)
    }

    public func write(to url: URL) throws {
        try WAV.writeWav(samples: samples, rate: sampleRate).write(to: url)
    }

    public static func writeWav(samples: [Int16], rate: Int) -> Data {
        let dataSize = samples.count * 2
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]) }
        func u16(_ v: Int) { d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
        str("RIFF"); u32(36 + dataSize); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        str("data"); u32(dataSize)
        samples.withUnsafeBytes { d.append(contentsOf: $0) } // little-endian on arm64/x86
        return d
    }
}

public enum WAVError: Error, CustomStringConvertible {
    case notWav, truncated, unsupported(String)
    public var description: String {
        switch self {
        case .notWav: return "not a RIFF/WAVE file"
        case .truncated: return "truncated WAV"
        case .unsupported(let s): return "unsupported WAV: \(s)"
        }
    }
}
