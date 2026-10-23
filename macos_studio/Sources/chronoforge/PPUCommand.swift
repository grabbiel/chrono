import Foundation
import ChronoForgeCore
import ChronoForgeMetal
import Metal

private let ppuUsage = """
usage: chronoforge ppu demos [--out DIR] [--frame N] [--scale K] [--only SLUG] [--gpu]
         demos: the synthetic PPU feature scenes (docs/ppu.md) as PNGs, one per demo,
                through the CPU reference renderer (--gpu: the Metal renderer, and
                a byte-for-byte comparison with the reference)
"""

/// Nearest-neighbour upscale; 512-column pictures keep the 256-pixel aspect.
func ppuScaled(_ image: PPUImage, scale: Int) -> (width: Int, height: Int, rgba: [UInt8]) {
    let sx = image.width > PPUFrame.width ? max(1, scale / 2) : scale
    let w = image.width * sx, h = image.height * scale
    var out = [UInt8](repeating: 0, count: w * h * 4)
    for y in 0..<h {
        for x in 0..<w {
            let src = ((y / scale) * image.width + x / sx) * 4, dst = (y * w + x) * 4
            out.replaceSubrange(dst..<(dst + 4), with: image.rgba[src..<(src + 4)])
        }
    }
    return (w, h, out)
}

@MainActor
func cmdPPU(_ args: [String]) -> Int32 {
    guard args.first == "demos" else { print(ppuUsage); return 2 }
    var options: [String: String] = [:]
    var gpu = false
    var i = 1
    while i < args.count {
        if args[i] == "--gpu" { gpu = true; i += 1; continue }
        guard ["--out", "--frame", "--scale", "--only"].contains(args[i]), i + 1 < args.count else { print(ppuUsage); return 2 }
        options[args[i]] = args[i + 1]
        i += 2
    }
    let out = URL(fileURLWithPath: options["--out"] ?? ".")
    let frame = max(0, Int(options["--frame"] ?? "0") ?? 0)
    let scale = max(1, min(4, Int(options["--scale"] ?? "2") ?? 2))
    let demos = PPUPreviewScenes.Demo.allCases.filter { options["--only"] == nil || $0.slug == options["--only"] }
    guard !demos.isEmpty else { print("no demo \(options["--only"] ?? "")"); return 2 }
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let renderer: PPURenderer? = gpu ? try MTLCreateSystemDefaultDevice().map { try PPURenderer(device: $0) } : nil
        if gpu && renderer == nil { print("no Metal device"); return 1 }
        var mismatches = 0
        for d in demos {
            let f = PPUPreviewScenes.demo(d, frame: frame)
            let opts = PPUPreviewScenes.options(d)
            let cpu = PPUReferenceRenderer.renderImage(f, options: opts)
            var image = cpu
            var note = "reference"
            if let renderer {
                image = try renderer.renderImage(f, options: opts)
                let same = image == cpu
                if !same { mismatches += 1 }
                note = same ? "Metal, equal to the reference" : "Metal, DIFFERS from the reference"
            }
            let big = ppuScaled(image, scale: scale)
            let url = out.appendingPathComponent("ppu_\(d.slug)_f\(frame).png")
            try PNG.writeRGBA(width: big.width, height: big.height, rgba: big.rgba).write(to: url)
            print("wrote \(url.path): \(d.rawValue), \(image.width)x\(image.height) (\(note))")
        }
        return mismatches == 0 ? 0 : 1
    } catch {
        print("ppu demos failed: \(error)")
        return 1
    }
}
