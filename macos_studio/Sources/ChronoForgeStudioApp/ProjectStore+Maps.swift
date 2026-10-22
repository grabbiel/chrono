// ProjectStore+Maps.swift — the Maps pane's import and picture assets.
import Foundation
import ChronoForgeCore

extension ProjectStore {
    /// Every location map in the ROM into the project (CTMaps.importMaps), with
    /// the tilesets and palettes they use that the project lacks.
    public func importMaps(_ url: URL) {
        guard var candidate = project else { return }
        do {
            let before = candidate.tilesets.count
            let ids = try CTMaps.importMaps(rom: [UInt8](Data(contentsOf: url)), into: &candidate)
            try candidate.save()
            project = candidate
            let added = candidate.tilesets.count - before
            statusMessage = "imported \(ids.count) maps from the ROM" + (added > 0 ? " (and \(added) tilesets and palettes)" : "")
            statusIsError = false
        } catch {
            statusMessage = "map import failed: \(error)"
            statusIsError = true
        }
    }

    /// The tilesets, palette and sheets a map's picture needs, or nil (with the reason in the status line).
    public func mapAssets(_ m: GameMap) -> LocationScene.Assets? {
        guard let project else { return nil }
        do {
            return try LocationScene.assets(for: m, project: project)
        } catch {
            statusMessage = "map \(m.id): \(error)"
            statusIsError = true
            return nil
        }
    }
}
