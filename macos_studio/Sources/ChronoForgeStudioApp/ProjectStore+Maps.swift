// ProjectStore+Maps.swift — the Maps pane's import, picture assets, new
// locations, rom.maps and the build budget (docs/maps.md).
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

    /// Creates location `number` from map `source` (CTNewLocation.create); the new map's id, or nil.
    @discardableResult
    public func createLocation(from source: String, number: Int, entrance: CTNewLocation.Entrance?, list: Bool) -> String? {
        guard var candidate = project else { return nil }
        do {
            let ids = try CTNewLocation.create(in: &candidate, from: source, number: number, entrance: entrance, list: list)
            try candidate.save()
            project = candidate
            let entranceText: String = entrance.map { (e: CTNewLocation.Entrance) -> String in ", entrance on \(e.map)" } ?? ""
            let listText: String = list ? " (listed in rom.maps)" : ""
            statusMessage = "created \(ids[0]) from \(source)\(entranceText)\(listText)"
            statusIsError = false
            return ids[0]
        } catch {
            statusMessage = "new location: \(error)"
            statusIsError = true
            return nil
        }
    }

    /// Puts maps in rom.maps, or takes them out.
    public func setMapsListed(_ ids: [String], listed: Bool) {
        guard var candidate = project else { return }
        do {
            let changed = try CTMapList.set(ids, listed: listed, in: &candidate)
            try candidate.save()
            project = candidate
            statusMessage = changed.isEmpty ? "rom.maps unchanged"
                : (listed ? "listed in rom.maps: " : "taken out of rom.maps: ") + changed.joined(separator: ", ")
            statusIsError = false
        } catch {
            statusMessage = "rom.maps: \(error)"
            statusIsError = true
        }
    }

    /// A dry-run build of the project on the scene ROM (`--rom` or the playback ROM): free space left,
    /// TreasureRom and the chests' flags, or the refusal. Nil without a ROM.
    public func mapBudget() async -> CTMapList.Budget? {
        guard let project, let path = sceneROMPath else { return nil }
        return await Task.detached {
            guard let base = try? ProjectStore.playbackROM(path) else {
                return CTMapList.Budget(maps: CTMapList.listed(project).count, freeBytesLeft: nil, treasure: nil, flags: [:],
                                        refusal: "cannot read the ROM at \(path)")
            }
            return CTMapList.budget(base: base, project: project)
        }.value
    }
}
