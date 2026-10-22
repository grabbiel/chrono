// PPU.swift — Metal SNES PPU renderer.
//
// One compute thread per output pixel runs the PPU pipeline of
// ChronoForgeCore's PPUReferenceRenderer: BG fetches from a VRAM texture, OBJ
// slivers from the shared OAM evaluator, main/sub layering, color math, master
// brightness. Palettes are a BGR555 LUT texture (CGRAM), so palette cycling
// rewrites 512 bytes and never touches the tile data. Its output must equal
// the reference pixel for pixel (ChronoForgeMetalTests). Shader source is a
// Swift string compiled at init (SwiftPM does not build .metal files).
import Metal
import simd
import ChronoForgeCore

// MARK: - Shader source

public enum PPUShaders {
    /// 32-bit words per line in the register buffer.
    static let registerStride = 24
    static let maxSlivers = PPUOBJEvaluator.maxSliversPerLine

    public static let source = """
#include <metal_stdlib>
using namespace metal;

// Register buffer, \(PPUShaders.registerStride) words per line:
// 0 INIDISP, 1 BGMODE, 2 TM, 3 TS, 4 CGWSEL, 5 CGADSUB, 6 fixed color,
// 7 sliver count, 8-11 BGnSC, 12-15 char base, 16-19 HOFS, 20-23 VOFS.
constant uint REG_STRIDE = \(PPUShaders.registerStride);
constant uint MAX_SLIVERS = \(PPUShaders.maxSlivers);

// Front-to-back ranks keyed BG1L, BG1H ... BG4L, BG4H, OBJ0 ... OBJ3.
constant uchar RANKS[4][12] = {
    { \(PPULayering.mode0.map { String($0) }.joined(separator: ", ")) },
    { \(PPULayering.mode1.map { String($0) }.joined(separator: ", ")) },
    { \(PPULayering.mode1BG3High.map { String($0) }.joined(separator: ", ")) },
    { 255, 255, 255, 255, 255, 255, 255, 255, 8, 6, 3, 0 },
};

static uint vram_word(texture2d<uint, access::read> vram, uint address) {
    address &= 0x7FFFu;
    return vram.read(uint2(address & 255u, address >> 8)).r;
}

static uint planar(texture2d<uint, access::read> vram, uint row, uint bpp, uint bit) {
    uint p01 = vram_word(vram, row);
    uint c = ((p01 >> bit) & 1u) | (((p01 >> (bit + 8u)) & 1u) << 1);
    if (bpp == 4u) {
        uint p23 = vram_word(vram, row + 8u);
        c |= (((p23 >> bit) & 1u) << 2) | (((p23 >> (bit + 8u)) & 1u) << 3);
    }
    return c;
}

static uint bg_bpp(uint mode, uint n) {
    if (mode == 0u) { return 2u; }
    if (mode == 1u) { return n < 2u ? 4u : (n == 2u ? 2u : 0u); }
    return 0u;
}

// CGRAM index | priority << 8 | 1 << 16, or 0 when transparent.
static uint bg_pixel(texture2d<uint, access::read> vram, const device uint* R,
                     uint n, uint x, uint line) {
    uint mode = R[1] & 7u;
    uint bpp = bg_bpp(mode, n);
    if (bpp == 0u) { return 0u; }
    uint sc = R[8 + n];
    uint size = ((R[1] >> (4u + n)) & 1u) != 0u ? 16u : 8u;
    uint sx = (x + R[16 + n]) & 0x3FFu;
    uint sy = (line + 1u + R[20 + n]) & 0x3FFu;
    uint tx = (sx / size) & 63u, ty = (sy / size) & 63u;
    uint address = ((sc & 0xFCu) << 8) + (ty & 31u) * 32u + (tx & 31u);
    uint screens = sc & 3u;
    if ((tx & 32u) != 0u && (screens & 1u) != 0u) { address += 0x400u; }
    if ((ty & 32u) != 0u && screens >= 2u) { address += screens == 3u ? 0x800u : 0x400u; }
    uint entry = vram_word(vram, address);
    uint px = sx % size, py = sy % size;
    if ((entry & 0x4000u) != 0u) { px = size - 1u - px; }
    if ((entry & 0x8000u) != 0u) { py = size - 1u - py; }
    uint tile = (entry + (px >= 8u ? 1u : 0u) + (py >= 8u ? 16u : 0u)) & 0x3FFu;
    uint row = (R[12 + n] << 12) + tile * bpp * 4u + (py & 7u);
    uint index = planar(vram, row, bpp, 7u - (px & 7u));
    if (index == 0u) { return 0u; }
    uint palette = (entry >> 10) & 7u;
    uint base = mode == 0u ? n * 32u : 0u;
    return (base + palette * (1u << bpp) + index) | (((entry >> 13) & 1u) << 8) | 0x10000u;
}

struct Front { uint color; uint layer; uint objPalette; bool found; };

static Front front(texture2d<uint, access::read> cgram, constant uchar* ranks, uint mask,
                   thread const uint* bgs, uint obj) {
    Front f = { 0u, 5u, 0u, false };
    uint best = 255u;
    for (uint n = 0u; n < 4u; n++) {
        if ((mask & (1u << n)) == 0u || bgs[n] == 0u) { continue; }
        uint rank = ranks[n * 2u + ((bgs[n] >> 8) & 1u)];
        if (rank < best) {
            best = rank;
            f = { cgram.read(uint2(bgs[n] & 255u, 0u)).r & 0x7FFFu, n, 0u, true };
        }
    }
    if ((mask & 0x10u) != 0u && obj != 0u && uint(ranks[8u + ((obj >> 8) & 3u)]) < best) {
        f = { cgram.read(uint2(obj & 255u, 0u)).r & 0x7FFFu, 4u, (obj >> 12) & 7u, true };
    }
    return f;
}

static bool in_region(uint region) {
    // Windows are not modelled: every pixel is outside the color window.
    region &= 3u;
    return region == 1u || region == 3u;
}

static uint output8(uint c5, uint brightness) {
    if (brightness == 0u) { return 0u; }
    uint c8 = (c5 << 3) | (c5 >> 2);
    return c8 * (brightness + 1u) / 16u;
}

kernel void ppu_frame(texture2d<uint, access::read> vram [[texture(0)]],
                      texture2d<uint, access::read> cgram [[texture(1)]],
                      texture2d<float, access::write> out [[texture(2)]],
                      const device uint* registers [[buffer(0)]],
                      const device uint4* slivers [[buffer(1)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    uint x = gid.x, line = gid.y;
    const device uint* R = registers + line * REG_STRIDE;
    if ((R[0] & 0x80u) != 0u) { out.write(float4(0.0, 0.0, 0.0, 1.0), gid); return; }

    uint bgs[4];
    for (uint n = 0u; n < 4u; n++) { bgs[n] = bg_pixel(vram, R, n, x, line); }

    // OBJ: slivers are front to back; the first opaque one wins.
    uint obj = 0u;
    uint count = R[7];
    for (uint k = 0u; k < count; k++) {
        uint4 s = slivers[line * MAX_SLIVERS + k];
        int sx = as_type<int>(s.x);
        if (int(x) < sx || int(x) >= sx + 8) { continue; }
        uint px = uint(int(x) - sx);
        uint hflip = (s.z >> 5) & 1u;
        uint c = planar(vram, s.y, 4u, hflip != 0u ? px : 7u - px);
        if (c != 0u) {
            uint palette = s.z & 7u;
            obj = (128u + palette * 16u + c) | (((s.z >> 3) & 3u) << 8) | (palette << 12) | 0x10000u;
            break;
        }
    }

    uint mode = R[1] & 7u;
    uint table = mode == 0u ? 0u : (mode == 1u ? (((R[1] & 8u) != 0u) ? 2u : 1u) : 3u);
    constant uchar* ranks = RANKS[table];
    Front main = front(cgram, ranks, R[2], bgs, obj);
    if (!main.found) { main.color = cgram.read(uint2(0u, 0u)).r & 0x7FFFu; main.layer = 5u; }
    Front sub = front(cgram, ranks, R[3], bgs, obj);

    uint cgwsel = R[4], cgadsub = R[5];
    bool forceBlack = in_region(cgwsel >> 6);
    uint color = forceBlack ? 0u : main.color;
    bool layerMath = (cgadsub & (1u << main.layer)) != 0u && (main.layer != 4u || main.objPalette >= 4u);
    if (layerMath && !in_region(cgwsel >> 4)) {
        uint addend = R[6];
        bool halve = (cgadsub & 0x40u) != 0u && !forceBlack;
        if ((cgwsel & 2u) != 0u) {
            if (sub.found) { addend = sub.color; } else { halve = false; }
        }
        bool subtract = (cgadsub & 0x80u) != 0u;
        uint mixed = 0u;
        for (uint shift = 0u; shift <= 10u; shift += 5u) {
            int m = int((color >> shift) & 31u), s = int((addend >> shift) & 31u);
            int v = subtract ? m - s : m + s;
            if (halve) { v >>= 1; }
            mixed |= uint(clamp(v, 0, 31)) << shift;
        }
        color = mixed;
    }
    uint b = R[0] & 15u;
    float4 rgba = float4(float(output8(color & 31u, b)), float(output8((color >> 5) & 31u, b)),
                         float(output8((color >> 10) & 31u, b)), 255.0) / 255.0;
    out.write(rgba, gid);
}

// Present: scale the frame into a rectangle of the drawable (nearest).
struct PresentOut { float4 position [[position]]; float2 uv; };

vertex PresentOut present_vs(uint vid [[vertex_id]], constant float4& rect [[buffer(0)]]) {
    float2 corner = float2(float(vid & 1u), float(vid >> 1));
    PresentOut o;
    o.position = float4(mix(rect.x, rect.z, corner.x), mix(rect.w, rect.y, corner.y), 0.0, 1.0);
    o.uv = corner;
    return o;
}

fragment float4 present_fs(PresentOut in [[stage_in]], texture2d<float> frame [[texture(0)]]) {
    constexpr sampler nearest(filter::nearest, address::clamp_to_edge);
    return frame.sample(nearest, in.uv);
}
"""
}

// MARK: - Renderer

public enum PPUError: Error, CustomStringConvertible {
    case noDevice, shaderCompile(String), texture(String)
    public var description: String {
        switch self {
        case .noDevice: return "no Metal device"
        case .shaderCompile(let s): return "shader compile failed: \(s)"
        case .texture(let s): return "texture error: \(s)"
        }
    }
}

@MainActor
public final class PPURenderer {
    public let device: MTLDevice
    public let library: MTLLibrary
    let framePipeline: MTLComputePipelineState
    let presentPipeline: MTLRenderPipelineState
    let queue: MTLCommandQueue

    /// VRAM: 32K R16Uint texels (256 x 128).
    let vramTexture: MTLTexture
    /// CGRAM: the BGR555 palette LUT, 256 R16Uint texels.
    public let paletteLUT: MTLTexture
    /// One output texture per line count (224 / 239), RGBA8.
    private var frameTextures: [Int: MTLTexture] = [:]

    /// What was last uploaded, to skip unchanged memory.
    private var uploadedVRAM: [UInt16] = []
    private var uploadedCGRAM: [UInt16] = []
    /// Upload counters: palette changes must not re-upload VRAM.
    public private(set) var vramUploads = 0
    public private(set) var paletteUploads = 0

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw PPUError.noDevice }
        self.queue = queue
        do {
            library = try device.makeLibrary(source: PPUShaders.source, options: nil)
        } catch {
            throw PPUError.shaderCompile(String(describing: error))
        }
        framePipeline = try device.makeComputePipelineState(function: try PPU.mustFind(library, "ppu_frame"))
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try PPU.mustFind(library, "present_vs")
        desc.fragmentFunction = try PPU.mustFind(library, "present_fs")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        presentPipeline = try device.makeRenderPipelineState(descriptor: desc)
        vramTexture = try PPU.texture(device, .r16Uint, 256, 128, usage: .shaderRead)
        paletteLUT = try PPU.texture(device, .r16Uint, 256, 1, usage: .shaderRead)
        setVRAM([UInt16](repeating: 0, count: PPUFrame.vramWords))
        setCGRAM([UInt16](repeating: 0, count: 256))
    }

    /// Upload all of VRAM (32K words).
    public func setVRAM(_ words: [UInt16]) {
        precondition(words.count == PPUFrame.vramWords, "VRAM is 32K words")
        words.withUnsafeBytes { buf in
            vramTexture.replace(region: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0,
                                withBytes: buf.baseAddress!, bytesPerRow: 512)
        }
        uploadedVRAM = words
        vramUploads += 1
    }

    /// Rewrite the palette LUT (256 BGR555 words). Tile data stays as is.
    public func setCGRAM(_ words: [UInt16]) {
        precondition(words.count == 256, "CGRAM is 256 words")
        words.withUnsafeBytes { buf in
            paletteLUT.replace(region: MTLRegionMake2D(0, 0, 256, 1), mipmapLevel: 0,
                               withBytes: buf.baseAddress!, bytesPerRow: 512)
        }
        uploadedCGRAM = words
        paletteUploads += 1
    }

    /// Upload whichever of VRAM and CGRAM changed since the last upload.
    public func sync(_ frame: PPUFrame) {
        if frame.vram != uploadedVRAM { setVRAM(frame.vram) }
        if frame.cgram != uploadedCGRAM { setCGRAM(frame.cgram) }
    }

    /// The register and OBJ-sliver buffers for a frame's lines.
    static func lineBuffers(_ frame: PPUFrame) -> (registers: [UInt32], slivers: [UInt32]) {
        let stride = PPUShaders.registerStride, maxSlivers = PPUShaders.maxSlivers
        var registers = [UInt32](repeating: 0, count: frame.height * stride)
        var slivers = [UInt32](repeating: 0, count: frame.height * maxSlivers * 4)
        for (line, r) in frame.lines.enumerated() {
            let objs = r.forcedBlank ? [] : PPUOBJEvaluator.evaluate(oam: frame.oam, registers: r, line: line).slivers
            let o = line * stride
            registers[o] = UInt32(r.inidisp)
            registers[o + 1] = UInt32(r.bgmode)
            registers[o + 2] = UInt32(r.tm)
            registers[o + 3] = UInt32(r.ts)
            registers[o + 4] = UInt32(r.cgwsel)
            registers[o + 5] = UInt32(r.cgadsub)
            registers[o + 6] = UInt32(r.fixedColor.word)
            registers[o + 7] = UInt32(objs.count)
            for n in 0..<4 {
                registers[o + 8 + n] = UInt32(r.bg[n].sc)
                registers[o + 12 + n] = UInt32(r.bg[n].charBase & 15)
                registers[o + 16 + n] = UInt32(r.bg[n].hofs & 0x3FF)
                registers[o + 20 + n] = UInt32(r.bg[n].vofs & 0x3FF)
            }
            for (k, s) in objs.enumerated() {
                let so = (line * maxSlivers + k) * 4
                slivers[so] = UInt32(bitPattern: Int32(s.x))
                slivers[so + 1] = UInt32(s.rowAddress)
                slivers[so + 2] = UInt32(s.palette) | UInt32(s.priority) << 3 | (s.hflip ? 0x20 : 0)
                slivers[so + 3] = UInt32(s.order)
            }
        }
        return (registers, slivers)
    }

    func frameTexture(height: Int) throws -> MTLTexture {
        if let t = frameTextures[height] { return t }
        let t = try PPU.texture(device, .rgba8Unorm, PPUFrame.width, height, usage: [.shaderRead, .shaderWrite])
        frameTextures[height] = t
        return t
    }

    /// Encode one frame into `commandBuffer`; returns the 256 x height texture.
    public func encode(_ frame: PPUFrame, into commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        sync(frame)
        let target = try frameTexture(height: frame.height)
        let (registers, slivers) = PPURenderer.lineBuffers(frame)
        guard let regBuf = device.makeBuffer(bytes: registers, length: registers.count * 4),
              let sliverBuf = device.makeBuffer(bytes: slivers, length: slivers.count * 4),
              let enc = commandBuffer.makeComputeCommandEncoder() else {
            throw PPUError.texture("frame buffers")
        }
        enc.setComputePipelineState(framePipeline)
        enc.setTexture(vramTexture, index: 0)
        enc.setTexture(paletteLUT, index: 1)
        enc.setTexture(target, index: 2)
        enc.setBuffer(regBuf, offset: 0, index: 0)
        enc.setBuffer(sliverBuf, offset: 0, index: 1)
        // Uniform threadgroups (the kernel bounds-checks), for devices without
        // non-uniform dispatch.
        let w = framePipeline.threadExecutionWidth
        let h = max(1, min(8, framePipeline.maxTotalThreadsPerThreadgroup / w))
        enc.dispatchThreadgroups(MTLSize(width: (PPUFrame.width + w - 1) / w,
                                         height: (frame.height + h - 1) / h, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
        return target
    }

    /// Render synchronously and read back RGBA8 (256 x height), the layout of
    /// PPUReferenceRenderer.render.
    public func render(_ frame: PPUFrame) throws -> [UInt8] {
        guard let cmd = queue.makeCommandBuffer() else { throw PPUError.noDevice }
        let tex = try encode(frame, into: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw PPUError.shaderCompile(String(describing: error)) }
        var bytes = [UInt8](repeating: 0, count: PPUFrame.width * frame.height * 4)
        tex.getBytes(&bytes, bytesPerRow: PPUFrame.width * 4,
                     from: MTLRegionMake2D(0, 0, PPUFrame.width, frame.height), mipmapLevel: 0)
        return bytes
    }

    /// Draw a rendered frame into `target` (bgra8Unorm), scaled by the
    /// largest integer factor that fits (or fit-to-size when smaller), centred.
    public func present(_ frameTexture: MTLTexture, to target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let tw = Float(target.width), th = Float(target.height)
        let fw = Float(frameTexture.width), fh = Float(frameTexture.height)
        let fit = min(tw / fw, th / fh)
        let scale = fit >= 1 ? fit.rounded(.down) : fit
        let w = fw * scale / tw, h = fh * scale / th
        var rect = SIMD4<Float>(-w, -h, w, h)
        enc.setRenderPipelineState(presentPipeline)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentTexture(frameTexture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
    }
}

enum PPU {
    static func mustFind(_ lib: MTLLibrary, _ name: String) throws -> MTLFunction {
        guard let f = lib.makeFunction(name: name) else {
            throw PPUError.shaderCompile("function \(name) missing")
        }
        return f
    }

    static func texture(_ device: MTLDevice, _ format: MTLPixelFormat, _ width: Int, _ height: Int,
                        usage: MTLTextureUsage) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width,
                                                         height: height, mipmapped: false)
        d.usage = usage
        guard let t = device.makeTexture(descriptor: d) else {
            throw PPUError.texture("\(format) \(width)x\(height)")
        }
        return t
    }
}
