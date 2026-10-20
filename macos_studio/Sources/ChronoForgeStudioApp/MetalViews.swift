// MetalViews.swift — NSViewRepresentable wrappers around SNESPPUView.
import SwiftUI
import MetalKit
import simd
import ChronoForgeCore
import ChronoForgeMetal

/// Shared Metal device (created once).
@MainActor
enum StudioMetal {
    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let gray16: [BGR555] = (0..<256).map { i in
        let v = UInt8((i % 16) * 17)
        return BGR555(r5: v >> 3, g5: v >> 3, b5: v >> 3)
    }
}

/// Renders a tileset's tile bank as a BG1 grid.
struct TilesetMetalView: NSViewRepresentable {
    let project: CTProject
    let tileset: Tileset

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else {
            return NSView()
        }
        view.addConstraint(NSLayoutConstraint(item: view, attribute: .height,
            relatedBy: .equal, toItem: nil, attribute: .notAnAttribute,
            multiplier: 1, constant: 256))
        Task { @MainActor in
            if let indices = try? project.tileIndices(of: tileset) {
                try? view.loadTileset(indices: indices, tilesWide: 16,
                                      palette: StudioMetal.gray16)
                let tiles = indices.count / 64
                view.bgPlanes = [BGPlane(bg: 1, entries: (0..<tiles).map { t in
                    BGPlaneEntry(x: (t % 16) * 8, y: (t / 16) * 8, tile: t, pal: 0)
                })]
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Renders a map's BG layers (metatiles -> 4 chips of 8x8 each).
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
            multiplier: 1, constant: 320))
        Task { @MainActor in
            guard let indices = try? project.tileIndices(of: ts) else { return }
            try? view.loadTileset(indices: indices, tilesWide: 16,
                                  palette: StudioMetal.gray16)
            view.bgPlanes = MapMetalView.planes(project: project, map: map, ts: ts, indices: indices)
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    static func planes(project: CTProject, map: GameMap, ts: Tileset, indices: [UInt8]) -> [BGPlane] {
        var planes: [BGPlane] = []
        for layer in map.layers {
            var entries: [BGPlaneEntry] = []
            for (i, mt) in layer.metatiles.enumerated() {
                guard mt < ts.metatiles.count else { continue }
                let mx = i % max(1, map.width), my = i / max(1, map.width)
                for (ci, chip) in ts.metatiles[mt].chips.enumerated() {
                    guard chip.tile * 64 + 63 < indices.count else { continue }
                    entries.append(BGPlaneEntry(
                        x: mx * 16 + (ci % 2) * 8,
                        y: my * 16 + (ci / 2) * 8,
                        tile: chip.tile, pal: chip.pal,
                        hflip: chip.hflip, vflip: chip.vflip,
                        priority: chip.priority))
                }
            }
            planes.append(BGPlane(bg: layer.bg, entries: entries))
        }
        return planes
    }
}
