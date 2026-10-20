// CodecBridge.swift — runtime dlopen/dlsym binding to libctcodec.
//
// The C codec (re_workspace/tools/libctcodec/libctcodec.dylib) is loaded at
// runtime so this package builds and runs whether or not the dylib exists.
// Search order:
//   1. $CHRONOFORGE_LIBCTCODEC (explicit path)
//   2. @executable_path/../Frameworks/libctcodec.dylib (bundled .app)
//   3. the repo's re_workspace/tools/libctcodec (compile-time package path)
//   4. plain "libctcodec.dylib" (system rpath/LD_LIBRARY_PATH)
import Foundation
import CCodec
#if canImport(Darwin)
import Darwin
#endif

public final class LibCTCodec: @unchecked Sendable {
    public typealias DecompressFn = @convention(c) (UnsafePointer<UInt8>, Int32,
        UnsafeMutablePointer<UInt8>, Int32, UnsafeMutablePointer<Int32>) -> Int32
    public typealias CompressFn = @convention(c) (UnsafePointer<UInt8>, Int32,
        UnsafeMutablePointer<UInt8>, Int32, UnsafeMutablePointer<Int32>, Int32) -> Int32

    public static let shared = LibCTCodec()

    public let path: String?
    public let decompress: DecompressFn?
    public let compress: CompressFn?

    /// True when the CCodec module was compiled against the codec worker's
    /// real ctcodec.h (vs our frozen contract fallback).
    public static var usingRealHeader: Bool { ccodec_using_real_header() != 0 }

    public var available: Bool { decompress != nil && compress != nil }

    private init() {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["CHRONOFORGE_LIBCTCODEC"] {
            candidates.append(env)
        }
        let exe = Bundle.main.executableURL?.deletingLastPathComponent().path
        if let exe { candidates.append(exe + "/../Frameworks/libctcodec.dylib") }
        // Package-relative: this file lives at macos_studio/Sources/ChronoForgeCore/
        let pkgRel = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // ChronoForgeCore
            .deletingLastPathComponent() // Sources
            .deletingLastPathComponent() // macos_studio
            .appendingPathComponent("../re_workspace/tools/libctcodec/libctcodec.dylib")
            .standardizedFileURL.path
        candidates.append(pkgRel)
        candidates.append("libctcodec.dylib")

        var handle: UnsafeMutableRawPointer? = nil
        var chosen: String? = nil
        for c in candidates {
            handle = dlopen(c, RTLD_NOW | RTLD_GLOBAL)
            if handle != nil { chosen = c; break }
        }
        path = chosen
        if let h = handle {
            decompress = dlsym(h, "ct_lzss_decompress").map { unsafeBitCast($0, to: DecompressFn.self) }
            compress = dlsym(h, "ct_lzss_compress").map { unsafeBitCast($0, to: CompressFn.self) }
        } else {
            decompress = nil
            compress = nil
        }
    }

    /// Decompress via the C codec. nil when unavailable or the codec fails.
    public func lzssDecompress(_ src: [UInt8], cap: Int = 1 << 22) -> [UInt8]? {
        guard let fn = decompress else { return nil }
        var dst = [UInt8](repeating: 0, count: cap)
        var written: Int32 = 0
        let rc = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                fn(s.baseAddress!, Int32(s.count), d.baseAddress!, Int32(cap), &written)
            }
        }
        guard rc == 0, written >= 0, Int(written) <= cap else { return nil }
        return Array(dst[0..<Int(written)])
    }

    /// Compress via the C codec (mode 11 or 12). nil when unavailable/fails.
    public func lzssCompress(_ src: [UInt8], mode: Int) -> [UInt8]? {
        guard let fn = compress, mode == 11 || mode == 12 else { return nil }
        let cap = src.count + src.count / 4 + 4096
        var dst = [UInt8](repeating: 0, count: cap)
        var written: Int32 = 0
        let rc = src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                fn(s.baseAddress!, Int32(s.count), d.baseAddress!, Int32(cap), &written, Int32(mode))
            }
        }
        guard rc == 0, written >= 0, Int(written) <= cap else { return nil }
        return Array(dst[0..<Int(written)])
    }
}
