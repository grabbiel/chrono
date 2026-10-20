// PPU.swift — Metal SNES PPU renderer core.
//
// Renders BG1/BG2/BG3 tile planes + an OAM sprite layer from decoded tile
// index data. Shader source is embedded as a Swift string and compiled via
// device.makeLibrary(source:) at init (SPM does not compile .metal files).
// Palette swaps are one-texture updates into a 256-entry BGR555 LUT.
import Metal
import simd
import ChronoForgeCore

#if canImport(MetalKit)
import MetalKit
#endif

// MARK: - Public frame description

public struct BGPlaneEntry: Sendable {
    public var x: Int          // pixels (top-left)
    public var y: Int
    public var tile: Int       // index into the tile atlas grid
    public var pal: Int        // 0-7
    public var hflip: Bool
    public var vflip: Bool
    public var priority: Bool  // BG priority bit (wins over sprites)
    public init(x: Int, y: Int, tile: Int, pal: Int, hflip: Bool = false,
                vflip: Bool = false, priority: Bool = false) {
        self.x = x; self.y = y; self.tile = tile; self.pal = pal
        self.hflip = hflip; self.vflip = vflip; self.priority = priority
    }
}

public struct BGPlane: Sendable {
    public var bg: Int                 // 1..3
    public var entries: [BGPlaneEntry]
    public init(bg: Int, entries: [BGPlaneEntry]) { self.bg = bg; self.entries = entries }
}

public struct SpriteEntry: Sendable {
    public var x: Int
    public var y: Int
    public var tile: Int       // index into the sprite atlas grid
    public var pal: Int        // 0-7
    public var hflip: Bool
    public var vflip: Bool
    public var size16: Bool    // 16x16 (else 8x8)
    public var z: Int          // OAM Z 0..3 (3 = front)
    public init(x: Int, y: Int, tile: Int, pal: Int, hflip: Bool = false,
                vflip: Bool = false, size16: Bool = false, z: Int = 0) {
        self.x = x; self.y = y; self.tile = tile; self.pal = pal
        self.hflip = hflip; self.vflip = vflip; self.size16 = size16; self.z = z
    }
}

// MARK: - Shader source (compiled at init; SPM does not build .metal)

public enum PPUShaders {
    public static let source = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 ndc;
    float2 uv;
    uint2  atlasPos;   // top-left texel of the tile in the atlas
    uint   palBase;    // pal * 32 into the LUT
    uint   priority;   // BG priority bit (sprites: 0)
    uint   flags;      // 1=hflip 2=vflip
};

struct VSOut {
    float4 pos [[position]];
    float2 uv;
    uint2  atlasPos;
    uint   palBase;
    uint   priority;
    uint   flags;
};

vertex VSOut tile_vs(uint vid [[vertex_id]],
                     const device Vertex* verts [[buffer(0)]]) {
    const device Vertex& V = verts[vid];
    VSOut o;
    o.pos = float4(V.ndc, 0.0, 1.0);
    o.uv = V.uv;
    o.atlasPos = V.atlasPos;
    o.palBase = V.palBase;
    o.priority = V.priority;
    o.flags = V.flags;
    return o;
}

fragment float4 tile_fs(VSOut in [[stage_in]],
                        constant uint& expectedPrio [[buffer(0)]],
                        texture2d<uint, access::read> atlas [[texture(0)]],
                        texture2d<uint, access::read> lut [[texture(1)]]) {
    if (in.priority != expectedPrio) { return float4(0.0); }
    float2 uvc = in.uv;
    if (in.flags & 1u) { uvc.x = 1.0 - uvc.x; }
    if (in.flags & 2u) { uvc.y = 1.0 - uvc.y; }
    uint2 t = in.atlasPos + uint2(clamp(uvc * 8.0, float2(0.0), float2(7.999)));
    uint idx = atlas.read(t, 0).r;
    if (idx == 0u) { return float4(0.0); }          // color 0 is transparent
    uint4 c8 = lut.read(uint2(in.palBase + (idx & 31u), 0u), 0);
    return float4(float(c8.x) / 255.0, float(c8.y) / 255.0, float(c8.z) / 255.0, 1.0);
}
"""
}

// MARK: - Renderer

/// Matches the Metal `Vertex` struct (40 bytes).
struct PPUVertex {
    var ndc: SIMD2<Float>
    var uv: SIMD2<Float>
    var atlasPos: SIMD2<UInt32>
    var palBase: UInt32
    var priority: UInt32
    var flags: UInt32
    var pad: UInt32 = 0
}

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
    let normalPipeline: MTLRenderPipelineState
    let additivePipeline: MTLRenderPipelineState
    let cmdQueue: MTLCommandQueue

    // Palette LUT: 256 RGBA8Uint texels (8 palettes x 32 colors).
    let lutTexture: MTLTexture
    // Tile + sprite atlases (R8Uint of palette indices).
    var bgAtlas: MTLTexture?
    var spriteAtlas: MTLTexture?
    var bgAtlasTilesWide = 1
    var spriteAtlasTilesWide = 1

    public private(set) var lastCompileLog: String = ""

    public init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw PPUError.noDevice }
        self.cmdQueue = queue
        do {
            self.library = try device.makeLibrary(source: PPUShaders.source, options: nil)
        } catch {
            throw PPUError.shaderCompile(String(describing: error))
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = try PPU.mustFind(library, "tile_vs")
        desc.fragmentFunction = try PPU.mustFind(library, "tile_fs")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].rgbBlendOperation = .add
        desc.colorAttachments[0].alphaBlendOperation = .add
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        normalPipeline = try device.makeRenderPipelineState(descriptor: desc)
        // Additive color-math mode: dest += src.
        desc.colorAttachments[0].destinationRGBBlendFactor = .one
        desc.colorAttachments[0].destinationAlphaBlendFactor = .one
        additivePipeline = try device.makeRenderPipelineState(descriptor: desc)

        guard let lut = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Uint,
                width: 256, height: 1, mipmapped: false)
            d.usage = [.shaderRead]
            return d
        }()) else { throw PPUError.texture("lut") }
        lutTexture = lut
        setPalette([BGR555](repeating: BGR555(word: 0), count: 256))
    }

    /// Palette swap = one texture write.
    public func setPalette(_ colors: [BGR555]) {
        var bytes = [UInt8](repeating: 0, count: 256 * 4)
        for i in 0..<min(256, colors.count) {
            let c = colors[i].srgb
            bytes[i * 4] = c.r; bytes[i * 4 + 1] = c.g; bytes[i * 4 + 2] = c.b
            bytes[i * 4 + 3] = (i == 0) ? 0 : 255    // color 0 of each pal handled in shader
        }
        lutTexture.replace(region: MTLRegionMake2D(0, 0, 256, 1),
                           mipmapLevel: 0, withBytes: bytes, bytesPerRow: 256 * 4)
    }

    /// Upload an 8x8-tile atlas from row-major palette indices.
    public func setTileAtlas(indices: [UInt8], tilesWide: Int, sprite: Bool) throws {
        let tilesHigh = max(1, (indices.count + tilesWide * 64 - 1) / (tilesWide * 64))
        guard let tex = device.makeTexture(descriptor: {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                width: tilesWide * 8, height: tilesHigh * 8, mipmapped: false)
            d.usage = [.shaderRead]
            return d
        }()) else { throw PPUError.texture("atlas") }
        var bytes = indices
        if bytes.count < tilesWide * tilesHigh * 64 {
            bytes += [UInt8](repeating: 0, count: tilesWide * tilesHigh * 64 - bytes.count)
        }
        bytes.withUnsafeBytes { buf in
            tex.replace(region: MTLRegionMake2D(0, 0, tilesWide * 8, tilesHigh * 8),
                        mipmapLevel: 0, withBytes: buf.baseAddress!, bytesPerRow: tilesWide * 8)
        }
        if sprite { spriteAtlas = tex; spriteAtlasTilesWide = tilesWide }
        else { bgAtlas = tex; bgAtlasTilesWide = tilesWide }
    }

    /// Render BG planes + sprites into a texture (drawable texture when nil is
    /// not used here; pass the destination explicitly).
    public func render(into target: MTLTexture,
                       size: SIMD2<Float>,
                       bgPlanes: [BGPlane],
                       sprites: [SpriteEntry] = [],
                       additive: Bool = false,
                       clearColor: MTLClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)) {
        guard let cmd = cmdQueue.makeCommandBuffer(),
              let rpd = makePassDescriptor(target, clearColor: clearColor) else { return }
        let enc = cmd.makeRenderCommandEncoder(descriptor: rpd)!

        // Pass order: non-priority BG (BG3->BG2->BG1), then sprites by Z,
        // then priority BG tiles (they win over sprites on SNES).
        func draw(_ vertices: [PPUVertex], atlas: MTLTexture?) {
            guard !vertices.isEmpty, let atlas else { return }
            enc.setRenderPipelineState(additive ? additivePipeline : normalPipeline)
            var verts = vertices
            guard let buf = device.makeBuffer(bytes: &verts,
                                              length: verts.count * MemoryLayout<PPUVertex>.stride,
                                              options: []) else { return }
            enc.setVertexBuffer(buf, offset: 0, index: 0)
            enc.setFragmentTexture(atlas, index: 0)
            enc.setFragmentTexture(lutTexture, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0,
                               vertexCount: vertices.count)
        }
        var expected: UInt32 = 0
        withUnsafeBytes(of: &expected) { enc.setFragmentBytes($0.baseAddress!, length: 4, index: 0) }
        for plane in bgPlanes.sorted(by: { $0.bg > $1.bg }) {
            draw(vertices(for: plane, size: size), atlas: bgAtlas)
        }
        var spriteVerts: [PPUVertex] = []
        for s in sprites.sorted(by: { $0.z < $1.z }) {
            spriteVerts.append(contentsOf: vertices(for: s, size: size))
        }
        draw(spriteVerts, atlas: spriteAtlas)
        expected = 1
        withUnsafeBytes(of: &expected) { enc.setFragmentBytes($0.baseAddress!, length: 4, index: 0) }
        for plane in bgPlanes.sorted(by: { $0.bg > $1.bg }) {
            draw(vertices(for: plane, size: size), atlas: bgAtlas)
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
    }

    private func makePassDescriptor(_ target: MTLTexture, clearColor: MTLClearColor) -> MTLRenderPassDescriptor? {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = target
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = clearColor
        return rpd
    }

    /// Bake one 8x8 (or 16x16) tile quad into two CCW triangles in NDC.
    private func quad(x: Int, y: Int, w: Int, h: Int, atlasTile: Int,
                      atlasTilesWide: Int, pal: Int, priority: Bool,
                      hflip: Bool, vflip: Bool, size: SIMD2<Float>) -> [PPUVertex] {
        let ax = UInt32(atlasTile % atlasTilesWide) * 8
        let ay = UInt32(atlasTile / atlasTilesWide) * 8
        let l = Float(x) / size.x * 2.0 - 1.0
        let r = Float(x + w) / size.x * 2.0 - 1.0
        let t = 1.0 - Float(y) / size.y * 2.0
        let b = 1.0 - Float(y + h) / size.y * 2.0
        let base = PPUVertex(ndc: .zero, uv: .zero,
                             atlasPos: SIMD2(ax, ay),
                             palBase: UInt32(pal & 7) * 32,
                             priority: priority ? 1 : 0,
                             flags: (hflip ? 1 : 0) | (vflip ? 2 : 0))
        func v(_ ndc: SIMD2<Float>, _ uv: SIMD2<Float>) -> PPUVertex {
            var o = base; o.ndc = ndc; o.uv = uv; return o
        }
        let tl = v(SIMD2(l, t), SIMD2(0, 0))
        let bl = v(SIMD2(l, b), SIMD2(0, 1))
        let tr = v(SIMD2(r, t), SIMD2(1, 0))
        let br = v(SIMD2(r, b), SIMD2(1, 1))
        return [tl, bl, tr, tr, bl, br]
    }

    private func vertices(for plane: BGPlane, size: SIMD2<Float>) -> [PPUVertex] {
        var out: [PPUVertex] = []
        for e in plane.entries where e.tile >= 0 {
            out += quad(x: e.x, y: e.y, w: 8, h: 8, atlasTile: e.tile,
                        atlasTilesWide: bgAtlasTilesWide, pal: e.pal,
                        priority: e.priority, hflip: e.hflip, vflip: e.vflip,
                        size: size)
        }
        return out
    }

    private func vertices(for s: SpriteEntry, size: SIMD2<Float>) -> [PPUVertex] {
        let wh = s.size16 ? 16 : 8
        return quad(x: s.x, y: s.y, w: wh, h: wh, atlasTile: s.tile,
                    atlasTilesWide: spriteAtlasTilesWide, pal: s.pal,
                    priority: false, hflip: s.hflip, vflip: s.vflip,
                    size: size)
    }
}

enum PPU {
    static func mustFind(_ lib: MTLLibrary, _ name: String) throws -> MTLFunction {
        guard let f = lib.makeFunction(name: name) else {
            throw PPUError.shaderCompile("function \(name) missing")
        }
        return f
    }
}
