// Support.swift — shared test helpers: repo paths, corpus loader.
import Foundation
import XCTest
@testable import ChronoForgeCore

enum Repo {
    /// macos_studio/Tests/ChronoForgeCoreTests/Support.swift -> repo root
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ChronoForgeCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macos_studio
        .deletingLastPathComponent()   // chrono
    static var rom: URL { root.appendingPathComponent("re_workspace/ct_clean.sfc") }
    static var dataAssetsCSV: URL {
        root.appendingPathComponent("re_workspace/refs/ChronoRET/symbols/data_assets.csv")
    }
    static var audioSamples: URL {
        root.appendingPathComponent("re_workspace/assets/audio/samples")
    }
    static var graphicsAssets: URL {
        root.appendingPathComponent("re_workspace/assets/graphics")
    }
    /// The ROM is local-only (never published); tests that need it skip.
    static func romData() throws -> Data {
        guard let d = try? Data(contentsOf: rom) else {
            throw XCTSkip("local ROM not present (re_workspace/ct_clean.sfc)")
        }
        return d
    }
}

struct XCTestExpectationError: Error, CustomStringConvertible {
    var description: String { "test resource not found" }
}

struct CorpusBlock {
    let label: String
    let pcStart: Int
    let pcEnd: Int
    let mode: Int          // 11 | 12
    let expectedSize: Int
}

func snesPC(_ addr: String) -> Int? {
    let parts = addr.replacingOccurrences(of: "$", with: "").split(separator: ":")
    guard parts.count == 2, let b = Int(parts[0], radix: 16), let a = Int(parts[1], radix: 16) else { return nil }
    return ((b & 0x3F) << 16) | a
}

/// Packed LZSS blocks listed in data_assets.csv ("piece=packed",
/// column 7 = "lz11 -> N B" / "lz12 -> N B").
func loadCorpus() throws -> [CorpusBlock] {
    guard FileManager.default.fileExists(atPath: Repo.dataAssetsCSV.path) else {
        throw XCTSkip("local ChronoRET checkout not present (data_assets.csv)")
    }
    let text = try String(contentsOf: Repo.dataAssetsCSV, encoding: .utf8)
    var out: [CorpusBlock] = []
    for line in text.split(separator: "\n") {
        if line.hasPrefix("#") { continue }
        let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard cols.count >= 7, cols[4] == "packed" else { continue }
        guard let s = snesPC(cols[1]), let e = snesPC(cols[2]) else { continue }
        let spec = cols[6]
        let mode = spec.contains("lz11") ? 11 : (spec.contains("lz12") ? 12 : 0)
        guard mode != 0, let arrow = spec.firstIndex(of: ">"),
              let n = Int(spec[spec.index(after: arrow)...].filter(\.isNumber)) else { continue }
        out.append(CorpusBlock(label: cols[0], pcStart: s, pcEnd: e, mode: mode, expectedSize: n))
    }
    return out
}

func fixtureURL() throws -> URL {
    guard let u = Bundle.module.url(forResource: "MyGame", withExtension: "ctproj",
                                    subdirectory: "Resources") else {
        throw XCTestExpectationError()
    }
    return u
}

func resourceData(_ subpath: String) throws -> Data {
    // Resources/... inside the test bundle
    let comp = subpath.split(separator: "/").map(String.init)
    var url = Bundle.module.resourceURL!.appendingPathComponent("Resources")
    for c in comp { url = url.appendingPathComponent(c) }
    return try Data(contentsOf: url)
}
