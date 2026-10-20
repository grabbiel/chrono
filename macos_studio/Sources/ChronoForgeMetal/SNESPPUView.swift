// SNESPPUView.swift — MTKView subclass rendering BG1/BG2/BG3 + OAM sprites
// at 60 fps from .ctproj-decoded tile/sprite data.
import MetalKit
import simd
import AppKit
import ChronoForgeCore

@MainActor
public final class SNESPPUView: MTKView, MTKViewDelegate {
    public private(set) var renderer: PPURenderer
    public var additiveColorMath = false { didSet { needsDisplay = true } }
    public var bgPlanes: [BGPlane] = [] { didSet { needsDisplay = true } }
    public var sprites: [SpriteEntry] = [] { didSet { needsDisplay = true } }

    public init(device: MTLDevice) throws {
        self.renderer = try PPURenderer(device: device)
        super.init(frame: .zero, device: device)
        self.delegate = self
        self.preferredFramesPerSecond = 60
        self.enableSetNeedsDisplay = false
        self.isPaused = false
        self.colorPixelFormat = .bgra8Unorm
        self.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Load a tileset's tiles into the BG atlas and set its palette.
    public func loadTileset(indices: [UInt8], tilesWide: Int = 16, palette: [BGR555]) throws {
        renderer.setPalette(palette)
        try renderer.setTileAtlas(indices: indices, tilesWide: tilesWide, sprite: false)
        needsDisplay = true
    }

    /// Load a sprite sheet's tiles into the sprite atlas.
    public func loadSprites(indices: [UInt8], tilesWide: Int = 16) throws {
        try renderer.setTileAtlas(indices: indices, tilesWide: tilesWide, sprite: true)
        needsDisplay = true
    }

    // MARK: MTKViewDelegate — one frame
    public func draw(in view: MTKView) {
        guard let drawable = currentDrawable else { return }
        renderer.render(into: drawable.texture,
                        size: SIMD2(Float(max(1, bounds.width)), Float(max(1, bounds.height))),
                        bgPlanes: bgPlanes, sprites: sprites,
                        additive: additiveColorMath, clearColor: clearColor)
    }
}
