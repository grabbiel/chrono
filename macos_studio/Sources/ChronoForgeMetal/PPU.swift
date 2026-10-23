// PPU.swift — Metal SNES PPU renderer.
//
// One compute thread per output pixel runs the PPU pipeline of
// ChronoForgeCore's PPUReferenceRenderer: BG fetches from a VRAM texture, OBJ
// slivers from the shared OAM evaluator, windows, main/sub layering, color math, master
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
    static let registerStride = 64
    static let maxSlivers = PPUOBJEvaluator.maxSliversPerLine
    /// Register word 44 when the line reads the frame's own CGRAM (no mid-frame writes).
    static let baseCGRAMRow: UInt32 = 0xFFFF_FFFF

    static func ranks(_ table: [UInt8]) -> String { table.map { String($0) }.joined(separator: ", ") }

    public static let source = """
#include <metal_stdlib>
using namespace metal;

// Register buffer, \(PPUShaders.registerStride) words per line:
// 0 INIDISP, 1 BGMODE, 2 TM, 3 TS, 4 CGWSEL, 5 CGADSUB, 6 fixed color,
// 7 sliver count, 8-11 BGnSC, 12-15 char base, 16-19 HOFS, 20-23 VOFS,
// 24 W12SEL, 25 W34SEL, 26 WOBJSEL, 27 WBGLOG, 28 WOBJLOG, 29 TMW, 30 TSW,
// 31 WH0 | WH1 << 8 | WH2 << 16 | WH3 << 24,
// 32 MOSAIC, 33 the line's row in its vertical mosaic block, 34 M7SEL,
// 35 SETINI, 36-39 M7A-M7D (sign-extended), 40 M7X, 41 M7Y, 42 M7HOFS,
// 43 M7VOFS (13-bit fields), 44 the line's row in the per-line CGRAM
// texture (all ones: the CGRAM LUT), 45 the line's VRAM slice.
constant uint REG_STRIDE = \(PPUShaders.registerStride);
constant uint MAX_SLIVERS = \(PPUShaders.maxSlivers);
constant uint BASE_CGRAM = 0xFFFFFFFFu;

struct FrameParams { uint width; uint height; uint top; uint field; };

// Front-to-back ranks keyed BG1L, BG1H ... BG4L, BG4H, OBJ0 ... OBJ3.
constant uchar RANKS[6][12] = {
    { \(ranks(PPULayering.mode0)) },
    { \(ranks(PPULayering.mode1)) },
    { \(ranks(PPULayering.mode1BG3High)) },
    { \(ranks(PPULayering.mode2to5)) },
    { \(ranks(PPULayering.mode6)) },
    { \(ranks(PPULayering.mode7)) },
};

#define VRAM_ARGS texture2d_array<uint, access::read> vram, uint slice
#define VRAM_PASS vram, slice
#define CG_ARGS texture2d<uint, access::read> lut, texture2d<uint, access::read> lineCG, uint cgRow
#define CG_PASS lut, lineCG, cgRow

static uint vram_word(VRAM_ARGS, uint address) {
    address &= 0x7FFFu;
    return vram.read(uint2(address & 255u, address >> 8), slice).r;
}

static uint cg(CG_ARGS, uint index) {
    index &= 255u;
    return cgRow == BASE_CGRAM ? lut.read(uint2(index, 0u)).r : lineCG.read(uint2(index, cgRow)).r;
}

static uint planar(VRAM_ARGS, uint row, uint bpp, uint bit) {
    uint c = 0u;
    for (uint pair = 0u; pair < bpp / 2u; pair++) {
        uint word = vram_word(VRAM_PASS, row + pair * 8u);
        c |= ((word >> bit) & 1u) << (pair * 2u);
        c |= ((word >> (bit + 8u)) & 1u) << (pair * 2u + 1u);
    }
    return c;
}

static uint bg_bpp(uint mode, uint n) {
    constexpr uint table[8][4] = { {2u, 2u, 2u, 2u}, {4u, 4u, 2u, 0u}, {4u, 4u, 0u, 0u}, {8u, 4u, 0u, 0u},
                                   {8u, 2u, 0u, 0u}, {4u, 2u, 0u, 0u}, {4u, 0u, 0u, 0u}, {8u, 0u, 0u, 0u} };
    return table[mode & 7u][n & 3u];
}

static uint direct_color(uint c, uint p) {
    uint r = ((c & 7u) << 2) | ((p & 1u) << 1);
    uint g = (((c >> 3) & 7u) << 2) | (((p >> 1) & 1u) << 1);
    uint b = (((c >> 6) & 3u) << 3) | (((p >> 2) & 1u) << 2);
    return r | (g << 5) | (b << 10);
}

static uint tilemap_address(uint sc, uint tx, uint ty) {
    uint address = ((sc & 0xFCu) << 8) + (ty & 31u) * 32u + (tx & 31u);
    uint screens = sc & 3u;
    if ((tx & 32u) != 0u && (screens & 1u) != 0u) { address += 0x400u; }
    if ((ty & 32u) != 0u && screens >= 2u) { address += screens == 3u ? 0x800u : 0x400u; }
    return address & 0x7FFFu;
}

// Offset-per-tile: (HOFS, VOFS) for BG n at screen x.
static uint2 offset_per_tile(VRAM_ARGS, const device uint* R, uint n, uint x, uint hofs, uint vofs) {
    uint mode = R[1] & 7u;
    uint column = (x + (hofs & 7u)) >> 3;
    uint2 out = uint2(hofs, vofs);
    if (column == 0u) { return out; }
    bool big3 = (R[1] & 0x40u) != 0u;
    uint width3 = (big3 && mode != 6u) ? 16u : 8u;
    uint height3 = big3 ? 16u : 8u;
    uint x3 = (column - 1u) * 8u + (R[18] & ~7u);
    uint tx = (x3 / width3) & 63u;
    uint y3 = R[22] & ~7u;
    uint applies = n == 0u ? 0x2000u : 0x4000u;
    uint first = vram_word(VRAM_PASS, tilemap_address(R[10], tx, ((y3 & 0x3FFu) / height3) & 63u));
    if (mode == 4u) {
        if ((first & applies) == 0u) { return out; }
        if ((first & 0x8000u) != 0u) { out.y = first & 0x3FFu; } else { out.x = (first & 0x3F8u) | (hofs & 7u); }
        return out;
    }
    if ((first & applies) != 0u) { out.x = (first & 0x3F8u) | (hofs & 7u); }
    uint second = vram_word(VRAM_PASS, tilemap_address(R[10], tx, (((y3 + 8u) & 0x3FFu) / height3) & 63u));
    if ((second & applies) != 0u) { out.y = second & 0x3FFu; }
    return out;
}

static int sext13(uint v) { return int((v & 0x1FFFu) ^ 0x1000u) - 0x1000; }

static int m7_origin(int d) {
    int o = d & ~0x1C00;
    if (d < 0) { o |= 0x1C00; }
    return o;
}

// A BG pixel: BGR555 | priority << 15 | 1 << 16, or 0 when transparent.
static uint mode7_pixel(VRAM_ARGS, CG_ARGS, const device uint* R, uint n, uint x, uint line) {
    bool extbg = (R[35] & 0x40u) != 0u;
    if (!(n == 0u || (n == 1u && extbg))) { return 0u; }
    bool mosaicOn = ((R[32] >> n) & 1u) != 0u;
    uint msize = (R[32] >> 4) + 1u;
    int sx = int(mosaicOn ? x - x % msize : x);
    int sy = int(line + 1u - (mosaicOn ? R[33] : 0u));
    uint m7sel = R[34];
    if ((m7sel & 1u) != 0u) { sx ^= 0xFF; }
    if ((m7sel & 2u) != 0u) { sy ^= 0xFF; }
    int a = as_type<int>(R[36]), b = as_type<int>(R[37]);
    int c = as_type<int>(R[38]), d = as_type<int>(R[39]);
    int cx = sext13(R[40]), cy = sext13(R[41]);
    int ox = m7_origin(sext13(R[42]) - cx);
    int oy = m7_origin(sext13(R[43]) - cy);
    int vx = ((a * ox) & ~63) + ((b * oy) & ~63) + cx * 256;
    int vy = ((c * ox) & ~63) + ((d * oy) & ~63) + cy * 256;
    vx += ((b * sy) & ~63) + a * sx;
    vy += ((d * sy) & ~63) + c * sx;
    int ix = vx >> 8, iy = vy >> 8;
    bool outside = (ix & ~0x3FF) != 0 || (iy & ~0x3FF) != 0;
    uint over = (m7sel >> 6) & 3u;
    if (outside && over == 2u) { return 0u; }
    uint tile = 0u;
    if (!(outside && over == 3u)) {
        tile = vram_word(VRAM_PASS, uint(((iy & 0x3FF) >> 3) * 128 + ((ix & 0x3FF) >> 3))) & 0xFFu;
    }
    uint pixel = vram_word(VRAM_PASS, tile * 64u + uint(iy & 7) * 8u + uint(ix & 7)) >> 8;
    if (n == 1u) {
        if ((pixel & 0x7Fu) == 0u) { return 0u; }
        return (cg(CG_PASS, pixel & 0x7Fu) & 0x7FFFu) | ((pixel >> 7) << 15) | 0x10000u;
    }
    if (pixel == 0u) { return 0u; }
    uint color = (R[4] & 1u) != 0u ? direct_color(pixel, 0u) : cg(CG_PASS, pixel);
    return (color & 0x7FFFu) | 0x10000u;
}

static uint bg_pixel(VRAM_ARGS, CG_ARGS, const device uint* R, uint n, uint x, uint side, uint line, uint field) {
    uint mode = R[1] & 7u;
    if (mode == 7u) { return mode7_pixel(VRAM_PASS, CG_PASS, R, n, x, line); }
    uint bpp = bg_bpp(mode, n);
    if (bpp == 0u) { return 0u; }
    bool hires = mode == 5u || mode == 6u;
    bool mosaicOn = ((R[32] >> n) & 1u) != 0u;
    uint msize = (R[32] >> 4) + 1u;
    uint mx = mosaicOn ? x - x % msize : x;
    uint mside = mosaicOn ? 0u : side;
    uint mosaicY = mosaicOn ? R[33] : 0u;
    uint hofs = R[16 + n], vofs = R[20 + n];
    if ((mode == 2u || mode == 4u || mode == 6u) && n < 2u) {
        uint2 o = offset_per_tile(VRAM_PASS, R, n, mx, hofs, vofs);
        hofs = o.x; vofs = o.y;
    }
    uint tileHeight = ((R[1] >> (4u + n)) & 1u) != 0u ? 16u : 8u;
    uint tileWidth = hires ? 16u : tileHeight;
    uint sx = hires ? (mx * 2u + mside + hofs * 2u) & 0x7FFu : (mx + hofs) & 0x3FFu;
    uint sy;
    if (hires && (R[35] & 1u) != 0u) {
        uint f = mosaicOn ? 0u : (field & 1u);
        sy = ((line + 1u - mosaicY) * 2u + f + vofs) & 0x3FFu;
    } else {
        sy = (line + 1u - mosaicY + vofs) & 0x3FFu;
    }
    uint tx = (sx / tileWidth) & 63u, ty = (sy / tileHeight) & 63u;
    uint entry = vram_word(VRAM_PASS, tilemap_address(R[8 + n], tx, ty));
    uint px = sx % tileWidth, py = sy % tileHeight;
    if ((entry & 0x4000u) != 0u) { px = tileWidth - 1u - px; }
    if ((entry & 0x8000u) != 0u) { py = tileHeight - 1u - py; }
    uint tile = (entry + (px >= 8u ? 1u : 0u) + (py >= 8u ? 16u : 0u)) & 0x3FFu;
    uint row = (R[12 + n] << 12) + tile * bpp * 4u + (py & 7u);
    uint index = planar(VRAM_PASS, row, bpp, 7u - (px & 7u));
    if (index == 0u) { return 0u; }
    uint palette = (entry >> 10) & 7u;
    uint priority = (entry >> 13) & 1u;
    uint color;
    if (bpp == 8u) {
        color = (R[4] & 1u) != 0u ? direct_color(index, palette) : cg(CG_PASS, index);
    } else {
        uint base = mode == 0u ? n * 32u : 0u;
        color = cg(CG_PASS, base + palette * (1u << bpp) + index);
    }
    return (color & 0x7FFFu) | (priority << 15) | 0x10000u;
}

struct Front { uint color; uint layer; uint objPalette; bool found; };

static Front front(CG_ARGS, constant uchar* ranks, uint mask, thread const uint* bgs, uint obj) {
    Front f = { 0u, 5u, 0u, false };
    uint best = 255u;
    for (uint n = 0u; n < 4u; n++) {
        if ((mask & (1u << n)) == 0u || bgs[n] == 0u) { continue; }
        uint rank = ranks[n * 2u + ((bgs[n] >> 15) & 1u)];
        if (rank < best) {
            best = rank;
            f = { bgs[n] & 0x7FFFu, n, 0u, true };
        }
    }
    if ((mask & 0x10u) != 0u && obj != 0u && uint(ranks[8u + ((obj >> 8) & 3u)]) < best) {
        f = { cg(CG_PASS, obj & 255u) & 0x7FFFu, 4u, (obj >> 12) & 7u, true };
    }
    return f;
}

// Whether the combined window of an area (0-3 BG1-BG4, 4 OBJ, 5 color) covers x.
static bool window_covers(const device uint* R, uint area, uint x) {
    uint sel, logic;
    if (area < 2u) { sel = R[24] >> (area * 4u); logic = R[27] >> (area * 2u); }
    else if (area < 4u) { sel = R[25] >> ((area - 2u) * 4u); logic = R[27] >> (area * 2u); }
    else { sel = R[26] >> ((area - 4u) * 4u); logic = R[28] >> ((area - 4u) * 2u); }
    uint wh = R[31];
    bool enable1 = (sel & 2u) != 0u, enable2 = (sel & 8u) != 0u;
    bool w1 = (x >= (wh & 255u) && x <= ((wh >> 8) & 255u)) != ((sel & 1u) != 0u);
    bool w2 = (x >= ((wh >> 16) & 255u) && x <= (wh >> 24)) != ((sel & 4u) != 0u);
    if (enable1 && enable2) {
        switch (logic & 3u) {
        case 0u: return w1 || w2;
        case 1u: return w1 && w2;
        case 2u: return w1 != w2;
        default: return w1 == w2;
        }
    }
    if (enable1) { return w1; }
    if (enable2) { return w2; }
    return false;
}

static bool in_region(uint region, bool insideColorWindow) {
    region &= 3u;
    return region == 3u || (region == 1u && !insideColorWindow) || (region == 2u && insideColorWindow);
}

static uint output8(uint c5, uint brightness) {
    if (brightness == 0u) { return 0u; }
    uint c8 = (c5 << 3) | (c5 >> 2);
    return c8 * (brightness + 1u) / 16u;
}

kernel void ppu_frame(texture2d_array<uint, access::read> vram [[texture(0)]],
                      texture2d<uint, access::read> lut [[texture(1)]],
                      texture2d<float, access::write> out [[texture(2)]],
                      texture2d<uint, access::read> lineCG [[texture(3)]],
                      const device uint* registers [[buffer(0)]],
                      const device uint4* slivers [[buffer(1)]],
                      constant FrameParams& P [[buffer(2)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) { return; }
    int lineIndex = int(gid.y) - int(P.top);
    if (lineIndex < 0 || lineIndex >= int(P.height)) { out.write(float4(0.0, 0.0, 0.0, 1.0), gid); return; }
    uint line = uint(lineIndex);
    const device uint* R = registers + line * REG_STRIDE;
    if ((R[0] & 0x80u) != 0u) { out.write(float4(0.0, 0.0, 0.0, 1.0), gid); return; }
    bool wide = P.width == 512u;
    uint x = wide ? gid.x >> 1 : gid.x;
    uint column = wide ? (gid.x & 1u) : 1u;
    uint slice = R[45], cgRow = R[44];
    uint mode = R[1] & 7u;

    // Half 0 feeds the sub screen, half 1 the main screen.
    uint subBGs[4], mainBGs[4];
    for (uint n = 0u; n < 4u; n++) {
        subBGs[n] = bg_pixel(VRAM_PASS, CG_PASS, R, n, x, 0u, line, P.field);
        mainBGs[n] = (mode == 5u || mode == 6u) ? bg_pixel(VRAM_PASS, CG_PASS, R, n, x, 1u, line, P.field) : subBGs[n];
    }

    // OBJ: slivers are front to back; the first opaque one wins.
    uint obj = 0u;
    uint count = R[7];
    for (uint k = 0u; k < count; k++) {
        uint4 s = slivers[line * MAX_SLIVERS + k];
        int sx = as_type<int>(s.x);
        if (int(x) < sx || int(x) >= sx + 8) { continue; }
        uint px = uint(int(x) - sx);
        uint hflip = (s.z >> 5) & 1u;
        uint c = planar(VRAM_PASS, s.y, 4u, hflip != 0u ? px : 7u - px);
        if (c != 0u) {
            uint palette = s.z & 7u;
            obj = (128u + palette * 16u + c) | (((s.z >> 3) & 3u) << 8) | (palette << 12) | 0x10000u;
            break;
        }
    }

    uint table;
    if (mode == 0u) { table = 0u; }
    else if (mode == 1u) { table = ((R[1] & 8u) != 0u) ? 2u : 1u; }
    else if (mode == 6u) { table = 4u; }
    else if (mode == 7u) { table = 5u; }
    else { table = 3u; }
    constant uchar* ranks = RANKS[table];
    uint windows = 0u;
    for (uint area = 0u; area < 5u; area++) {
        if (window_covers(R, area, x)) { windows |= 1u << area; }
    }
    bool colorWindow = window_covers(R, 5u, x);
    uint backdrop = cg(CG_PASS, 0u) & 0x7FFFu;
    Front main = front(CG_PASS, ranks, R[2] & ~(R[29] & windows), mainBGs, obj);
    if (!main.found) { main.color = backdrop; main.layer = 5u; }
    Front sub = front(CG_PASS, ranks, R[3] & ~(R[30] & windows), subBGs, obj);

    bool hires = mode == 5u || mode == 6u || (R[35] & 8u) != 0u;
    uint color;
    if (wide && column == 0u && hires) {
        color = sub.found ? sub.color : backdrop;
    } else {
        uint cgwsel = R[4], cgadsub = R[5];
        bool forceBlack = in_region(cgwsel >> 6, colorWindow);
        color = forceBlack ? 0u : main.color;
        bool layerMath = (cgadsub & (1u << main.layer)) != 0u && (main.layer != 4u || main.objPalette >= 4u);
        if (layerMath && !in_region(cgwsel >> 4, colorWindow)) {
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

    /// VRAM: 32K R16Uint texels (256 x 128), a one-slice array.
    let vramTexture: MTLTexture
    /// CGRAM: the BGR555 palette LUT, 256 R16Uint texels.
    public let paletteLUT: MTLTexture
    /// Mid-frame writes: one VRAM slice per stretch of lines with the same
    /// VRAM, and one CGRAM row per line (256 x 239).
    private var segmentTexture: MTLTexture?
    let lineCGRAMTexture: MTLTexture
    /// One output texture per size (256 or 512 x 224, 239), RGBA8.
    private var frameTextures: [Int: MTLTexture] = [:]

    /// What was last uploaded, to skip unchanged memory.
    private var uploadedVRAM: [UInt16] = []
    private var uploadedCGRAM: [UInt16] = []
    /// Upload counters: palette changes must not re-upload VRAM.
    public private(set) var vramUploads = 0
    public private(set) var paletteUploads = 0
    /// Frames drawn with mid-frame VRAM (slices) or CGRAM (rows) writes.
    public private(set) var vramSegmentUploads = 0
    public private(set) var lineCGRAMUploads = 0

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
        vramTexture = try PPU.vramArray(device, slices: 1)
        paletteLUT = try PPU.texture(device, .r16Uint, 256, 1, usage: .shaderRead)
        lineCGRAMTexture = try PPU.texture(device, .r16Uint, 256, PPURenderOptions.displayLines, usage: .shaderRead)
        setVRAM([UInt16](repeating: 0, count: PPUFrame.vramWords))
        setCGRAM([UInt16](repeating: 0, count: 256))
    }

    /// Upload all of VRAM (32K words).
    public func setVRAM(_ words: [UInt16]) {
        precondition(words.count == PPUFrame.vramWords, "VRAM is 32K words")
        PPU.upload(words, to: vramTexture, slice: 0)
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

    /// A frame's per-line buffers: registers, OBJ slivers, and the memory
    /// that mid-frame writes produce (nil when there are none).
    struct LineBuffers {
        var registers: [UInt32]
        var slivers: [UInt32]
        /// 256 words per line, when CGRAM changes mid-frame.
        var lineCGRAM: [UInt16]?
        /// One VRAM image per slice, when VRAM changes mid-frame.
        var vramSlices: [[UInt16]]?
    }

    /// The register and OBJ-sliver buffers for a frame's lines.
    static func lineBuffers(_ frame: PPUFrame) -> LineBuffers {
        let stride = PPUShaders.registerStride, maxSlivers = PPUShaders.maxSlivers
        var registers = [UInt32](repeating: 0, count: frame.height * stride)
        var slivers = [UInt32](repeating: 0, count: frame.height * maxSlivers * 4)
        let memory = frame.writes.isEmpty ? [PPUMemory](repeating: frame.memory, count: frame.height) : frame.memoryByLine()
        let mosaic = PPUMosaic.verticalIndices(frame.lines)
        let cgramLines = frame.linesChanging(.cgram)
        let vramLines = frame.linesChanging(.vram)
        var lineCGRAM: [UInt16]? = cgramLines.isEmpty ? nil : []
        var vramSlices: [[UInt16]]? = vramLines.isEmpty ? nil : []
        var slice = -1
        for (line, r) in frame.lines.enumerated() {
            let m = memory[line]
            let objs = r.forcedBlank ? [] : PPUOBJEvaluator.evaluate(oam: m.oam, registers: r, line: line,
                                                                     field: frame.field).slivers
            if lineCGRAM != nil { lineCGRAM!.append(contentsOf: m.cgram) }
            if vramSlices != nil && (line == 0 || vramLines.contains(line)) {
                vramSlices!.append(m.vram)
                slice += 1
            }
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
            registers[o + 24] = UInt32(r.w12sel)
            registers[o + 25] = UInt32(r.w34sel)
            registers[o + 26] = UInt32(r.wobjsel)
            registers[o + 27] = UInt32(r.wbglog)
            registers[o + 28] = UInt32(r.wobjlog)
            registers[o + 29] = UInt32(r.tmw)
            registers[o + 30] = UInt32(r.tsw)
            var wh = UInt32(r.wh0) | UInt32(r.wh1) << 8
            wh |= UInt32(r.wh2) << 16 | UInt32(r.wh3) << 24
            registers[o + 31] = wh
            registers[o + 32] = UInt32(r.mosaic)
            registers[o + 33] = UInt32(mosaic[line])
            registers[o + 34] = UInt32(r.m7sel)
            registers[o + 35] = UInt32(r.setini)
            let matrix: [Int16] = [r.m7a, r.m7b, r.m7c, r.m7d]
            for (k, v) in matrix.enumerated() { registers[o + 36 + k] = UInt32(bitPattern: Int32(v)) }
            let center: [Int16] = [r.m7x, r.m7y, r.m7hofs, r.m7vofs]
            for (k, v) in center.enumerated() { registers[o + 40 + k] = UInt32(UInt16(bitPattern: v)) }
            registers[o + 44] = lineCGRAM == nil ? PPUShaders.baseCGRAMRow : UInt32(line)
            registers[o + 45] = UInt32(max(0, slice))
            for (k, s) in objs.enumerated() {
                let so = (line * maxSlivers + k) * 4
                slivers[so] = UInt32(bitPattern: Int32(s.x))
                slivers[so + 1] = UInt32(s.rowAddress)
                var attributes = UInt32(s.palette) | UInt32(s.priority) << 3
                if s.hflip { attributes |= 0x20 }
                slivers[so + 2] = attributes
                slivers[so + 3] = UInt32(s.order)
            }
        }
        return LineBuffers(registers: registers, slivers: slivers, lineCGRAM: lineCGRAM, vramSlices: vramSlices)
    }

    func frameTexture(width: Int, height: Int) throws -> MTLTexture {
        let key = width * 1000 + height
        if let t = frameTextures[key] { return t }
        let t = try PPU.texture(device, .rgba8Unorm, width, height, usage: [.shaderRead, .shaderWrite])
        frameTextures[key] = t
        return t
    }

    /// The VRAM texture for a frame: the synced one, or a slice per stretch
    /// of lines when VRAM changes mid-frame.
    func vramFor(_ buffers: LineBuffers) throws -> MTLTexture {
        guard let slices = buffers.vramSlices else { return vramTexture }
        if segmentTexture == nil || segmentTexture!.arrayLength < slices.count {
            segmentTexture = try PPU.vramArray(device, slices: max(slices.count, 8))
        }
        for (k, words) in slices.enumerated() { PPU.upload(words, to: segmentTexture!, slice: k) }
        vramSegmentUploads += 1
        return segmentTexture!
    }

    /// Encode one frame into `commandBuffer`; returns the 256 x height texture
    /// (hi-res lines show their main-screen columns).
    public func encode(_ frame: PPUFrame, into commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        try encode(frame, options: PPURenderOptions(highResolution: false), into: commandBuffer)
    }

    /// Encode one frame with output options; the texture is 256 or 512
    /// wide, and 239 lines high with the overscan border.
    public func encode(_ frame: PPUFrame, options: PPURenderOptions,
                       into commandBuffer: MTLCommandBuffer) throws -> MTLTexture {
        sync(frame)
        let (width, height, top) = options.layout(frame)
        let target = try frameTexture(width: width, height: height)
        let buffers = PPURenderer.lineBuffers(frame)
        let vram = try vramFor(buffers)
        if let rows = buffers.lineCGRAM {
            rows.withUnsafeBytes { buf in
                lineCGRAMTexture.replace(region: MTLRegionMake2D(0, 0, 256, frame.height), mipmapLevel: 0,
                                         withBytes: buf.baseAddress!, bytesPerRow: 512)
            }
            lineCGRAMUploads += 1
        }
        var params: [UInt32] = [UInt32(width), UInt32(frame.height), UInt32(top), UInt32(frame.field & 1)]
        guard let regBuf = device.makeBuffer(bytes: buffers.registers, length: buffers.registers.count * 4),
              let sliverBuf = device.makeBuffer(bytes: buffers.slivers, length: buffers.slivers.count * 4),
              let enc = commandBuffer.makeComputeCommandEncoder() else {
            throw PPUError.texture("frame buffers")
        }
        enc.setComputePipelineState(framePipeline)
        enc.setTexture(vram, index: 0)
        enc.setTexture(paletteLUT, index: 1)
        enc.setTexture(target, index: 2)
        enc.setTexture(lineCGRAMTexture, index: 3)
        enc.setBuffer(regBuf, offset: 0, index: 0)
        enc.setBuffer(sliverBuf, offset: 0, index: 1)
        enc.setBytes(&params, length: params.count * 4, index: 2)
        // Uniform threadgroups (the kernel bounds-checks), for devices without
        // non-uniform dispatch.
        let w = framePipeline.threadExecutionWidth
        let h = max(1, min(8, framePipeline.maxTotalThreadsPerThreadgroup / w))
        enc.dispatchThreadgroups(MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1),
                                 threadsPerThreadgroup: MTLSize(width: w, height: h, depth: 1))
        enc.endEncoding()
        return target
    }

    /// Render synchronously and read back RGBA8 (256 x height), the layout of
    /// PPUReferenceRenderer.render.
    public func render(_ frame: PPUFrame) throws -> [UInt8] {
        try renderImage(frame, options: PPURenderOptions(highResolution: false)).rgba
    }

    /// Render synchronously at the options' size, the layout of
    /// PPUReferenceRenderer.renderImage.
    public func renderImage(_ frame: PPUFrame, options: PPURenderOptions = PPURenderOptions()) throws -> PPUImage {
        guard let cmd = queue.makeCommandBuffer() else { throw PPUError.noDevice }
        let tex = try encode(frame, options: options, into: cmd)
        cmd.commit()
        cmd.waitUntilCompleted()
        if let error = cmd.error { throw PPUError.shaderCompile(String(describing: error)) }
        var bytes = [UInt8](repeating: 0, count: tex.width * tex.height * 4)
        tex.getBytes(&bytes, bytesPerRow: tex.width * 4,
                     from: MTLRegionMake2D(0, 0, tex.width, tex.height), mipmapLevel: 0)
        return PPUImage(width: tex.width, height: tex.height, rgba: bytes)
    }

    /// Draw a rendered frame into `target` (bgra8Unorm), scaled by the
    /// largest integer factor that fits (or fit-to-size when smaller), centred.
    /// A 512-column frame keeps the 256-pixel aspect.
    public func present(_ frameTexture: MTLTexture, to target: MTLTexture, commandBuffer: MTLCommandBuffer) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }
        let tw = Float(target.width), th = Float(target.height)
        let fw = Float(min(frameTexture.width, PPUFrame.width)), fh = Float(frameTexture.height)
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

    static func vramArray(_ device: MTLDevice, slices: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor()
        d.textureType = .type2DArray
        d.pixelFormat = .r16Uint
        d.width = 256
        d.height = 128
        d.arrayLength = slices
        d.usage = .shaderRead
        guard let t = device.makeTexture(descriptor: d) else {
            throw PPUError.texture("VRAM array of \(slices)")
        }
        return t
    }

    static func upload(_ words: [UInt16], to texture: MTLTexture, slice: Int) {
        words.withUnsafeBytes { buf in
            texture.replace(region: MTLRegionMake2D(0, 0, 256, 128), mipmapLevel: 0, slice: slice,
                            withBytes: buf.baseAddress!, bytesPerRow: 512, bytesPerImage: 0x10000)
        }
    }
}
