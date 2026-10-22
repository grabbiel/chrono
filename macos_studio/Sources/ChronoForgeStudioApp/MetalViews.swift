// MetalViews.swift — NSViewRepresentable wrappers around SNESPPUView. Each
// preview is a real PPU picture: tiles and tilemaps in VRAM, scrolled with
// BG scroll registers (scroll wheel / trackpad pans).
import SwiftUI
import MetalKit
import simd
import ChronoForgeCore
import ChronoForgeMetal

/// Shared Metal device (created once) and preview palettes.
@MainActor
enum StudioMetal {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
}

/// Renders a tileset's tile bank on BG1 (scroll to page through it).
struct TilesetMetalView: NSViewRepresentable {
    let project: CTProject
    let tileset: Tileset

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else {
            return NSView()
        }
        view.addConstraint(NSLayoutConstraint(item: view, attribute: .height,
            relatedBy: .equal, toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: 224 * 2))
        Task { @MainActor [weak view] in
            guard let view, let indices = try? project.tileIndices(of: tileset) else { return }
            let bpp = tileset.bpp == 2 ? 2 : 4
            var scrollY = 0
            let maxScroll = max(0, PPUPreviewScenes.tileBankRows(indices) * 8 - 224)
            view.picture = PPUPreviewScenes.tileBank(indices: indices, bpp: bpp, scrollY: 0)
            view.onScroll = { [weak view] _, dy in
                scrollY = min(maxScroll, max(0, scrollY - Int(dy)))
                view?.picture.setAllLines { $0.bg[0].vofs = UInt16((scrollY - 1) & 0x3FF) }
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Renders a map's BG layers through the PPU, 256x224 at the camera.
struct MapMetalView: NSViewRepresentable {
    let project: CTProject
    let map: GameMap
    let ts: Tileset

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else {
            return NSView()
        }
        view.addConstraint(NSLayoutConstraint(item: view, attribute: .height,
            relatedBy: .equal, toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: 224 * 2))
        Task { @MainActor [weak view] in
            guard let view, let indices = try? project.tileIndices(of: ts) else { return }
            var camera = (x: 0, y: 0)
            let limit = (x: max(0, map.width * 16 - 256), y: max(0, map.height * 16 - 224))
            view.picture = PPUPreviewScenes.map(map, tileset: ts, indices: indices, cameraX: 0, cameraY: 0)
            view.onScroll = { [weak view] dx, dy in
                camera.x = min(limit.x, max(0, camera.x - Int(dx)))
                camera.y = min(limit.y, max(0, camera.y - Int(dy)))
                view?.picture = PPUPreviewScenes.map(map, tileset: ts, indices: indices,
                                                    cameraX: camera.x, cameraY: camera.y)
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
