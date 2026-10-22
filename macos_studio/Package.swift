// swift-tools-version: 6.0
import PackageDescription
import Foundation

// Resolve the libctcodec location package-relative, from this manifest's own path.
let pkgRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().standardizedFileURL.path
let codecDir = URL(fileURLWithPath: pkgRoot)
    .appendingPathComponent("../re_workspace/tools/libctcodec").standardizedFileURL.path
let dylibPath = codecDir + "/libctcodec.dylib"
let dylibExists = FileManager.default.fileExists(atPath: dylibPath)

// Linker search path for libctcodec (package-relative). We intentionally do NOT
// pass -lctcodec: symbols are resolved at runtime with dlopen/dlsym so the
// package builds and tests cleanly whether or not the dylib exists yet
// (C-interop tests skip gracefully when it is absent).
var codecLinkerFlags: [LinkerSetting] = [
    .unsafeFlags(["-Xlinker", "-L\(codecDir)",
                  "-Xlinker", "-rpath", "-Xlinker", codecDir])
]
_ = dylibExists // reserved: enables -lctcodec once the codec exports a stable install_name

let package = Package(
    name: "ChronoForgeStudio",
    platforms: [.macOS(.v15)],
    targets: [
        // MARK: C-interop to libctcodec (C codec written by a sibling worker)
        .target(
            name: "CCodec",
            cSettings: [
                .headerSearchPath("include"),
                .unsafeFlags(["-I", codecDir]),
            ],
            linkerSettings: codecLinkerFlags
        ),
        // MARK: Core engine: .ctproj models, SNES primitives, validator
        .target(
            name: "ChronoForgeCore",
            dependencies: ["CCodec"]
        ),
        // MARK: Metal SNES PPU renderer
        .target(
            name: "ChronoForgeMetal",
            dependencies: ["ChronoForgeCore"]
        ),
        // MARK: Real-time S-SMP/S-DSP playback (AVAudioEngine)
        .target(
            name: "ChronoForgeAudio",
            dependencies: ["ChronoForgeCore"]
        ),
        // MARK: CLI
        .executableTarget(
            name: "chronoforge",
            dependencies: ["ChronoForgeCore", "ChronoForgeMetal", "ChronoForgeAudio"]
        ),
        // MARK: SwiftUI IDE shell
        .executableTarget(
            name: "ChronoForgeStudioApp",
            dependencies: ["ChronoForgeCore", "ChronoForgeMetal", "ChronoForgeAudio"]
        ),
        // MARK: Tests
        .testTarget(
            name: "ChronoForgeCoreTests",
            dependencies: ["ChronoForgeCore"],
            resources: [.copy("Resources")]
        ),
        .testTarget(
            name: "ChronoForgeAudioTests",
            dependencies: ["ChronoForgeAudio", "ChronoForgeCore"]
        ),
        .testTarget(
            name: "ChronoForgeMetalTests",
            dependencies: ["ChronoForgeMetal", "ChronoForgeCore"]
        ),
    ]
)
