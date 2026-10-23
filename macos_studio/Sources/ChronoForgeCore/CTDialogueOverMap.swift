// CTDialogueOverMap.swift — the field picture a dialogue box opens over: a
// project's imported location (chronoforge maps import) through
// LocationScene.frame, read only, for CTDialogueBox.frame(_:at:over:). The
// field keeps its layers and registers outside the band; in it the box's own
// HDMA records replace them (CTDialogueBox.applyBand).
import Foundation

public enum CTDialogueOverMap {
    /// The imported locations of `project`, by number.
    public static func locations(_ project: CTProject) -> [Int] {
        var out: [Int] = []
        for (id, m) in project.maps where m.rom != nil && id.hasPrefix("loc_") {
            if let n = Int(id.dropFirst(4)) { out.append(n) }
        }
        return out.sorted()
    }

    /// The field picture of `location` with the camera at (`cameraX`, `cameraY`)
    /// (clamped to the map) after `frame` frames of its tile and palette animation.
    public static func picture(project: CTProject, location: Int, cameraX: Int = 0, cameraY: Int = 0,
                               frame n: Int = 0) throws -> PPUFrame {
        guard let m = project.maps[CTMaps.id(location)] else {
            throw CTDialogueError("location \(location) is not in the project (chronoforge maps import)")
        }
        let assets = try LocationScene.assets(for: m, project: project)
        let start = TilesetScene.cgram(assets.palette)
        var player = assets.t12.map { TilesetPlayer(tileset: $0, palette: assets.palette, cgram: start) }
        player?.advance(to: n)
        let c = LocationScene.clampCamera(m, x: cameraX, y: cameraY)
        return LocationScene.frame(m, assets: assets, cgram: player?.cgram ?? start, cameraX: c.x, cameraY: c.y,
                                   frame: n, animFrames: player?.animator.frames)
    }
}
