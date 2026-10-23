// SNESPPUView.swift — MTKView that renders a PPUFrame at 60 fps and presents
// it scaled (integer factors when it fits, nearest sampling).
import MetalKit
import simd
import AppKit
import ChronoForgeCore

@MainActor
public final class SNESPPUView: MTKView, MTKViewDelegate {
    public private(set) var renderer: PPURenderer
    /// The picture: video memory plus per-line registers. Only memory that
    /// changed is uploaded, so a CGRAM edit is a palette-LUT write.
    public var picture = PPUFrame()
    /// How the picture is drawn. The default is the 256-wide picture
    /// (hi-res lines show their main-screen columns); `highResolution`
    /// draws 512 columns, `overscanBorder` the 239-line display area.
    public var renderOptions = PPURenderOptions(highResolution: false)
    /// Called once per displayed frame with the frame counter, before
    /// rendering: animate here (palette cycling, scroll, HDMA-style tables).
    public var tick: ((inout PPUFrame, Int) -> Void)?
    /// Scroll-wheel / trackpad deltas in points, for panning previews.
    public var onScroll: ((CGFloat, CGFloat) -> Void)?
    public private(set) var frameCount = 0

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

    public override func scrollWheel(with event: NSEvent) {
        guard let onScroll else { return super.scrollWheel(with: event) }
        onScroll(event.scrollingDeltaX, event.scrollingDeltaY)
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    // MARK: MTKViewDelegate — one frame
    public func draw(in view: MTKView) {
        tick?(&picture, frameCount)
        frameCount += 1
        guard let drawable = currentDrawable,
              let cmd = renderer.queue.makeCommandBuffer(),
              let texture = try? renderer.encode(picture, options: renderOptions, into: cmd) else { return }
        renderer.present(texture, to: drawable.texture, commandBuffer: cmd)
        cmd.present(drawable)
        cmd.commit()
    }
}
