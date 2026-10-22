// ProjectStore+Tilesets.swift — the Tilesets pane's import and sheet I/O.
import Foundation
import ChronoForgeCore

extension ProjectStore {
    /// Every location tileset and palette in the ROM into the project
    /// (CTTilesets.importTilesets): sheets now, tileset JSON on save.
    public func importTilesets(_ url: URL) {
        guard var candidate = project else { return }
        do {
            let ids = try CTTilesets.importTilesets(rom: [UInt8](Data(contentsOf: url)), into: &candidate)
            try candidate.save()
            project = candidate
            statusMessage = "imported \(ids.count) tilesets and palettes from the ROM"
            statusIsError = false
        } catch {
            statusMessage = "tileset import failed: \(error)"
            statusIsError = true
        }
    }

    /// A tileset sheet (or its animation sheet), or nil (with the reason in the status line).
    public func tilesetSheet(_ relative: String?) -> IndexedPNG? {
        guard let project, let relative else { return nil }
        do {
            return try PNG.readIndexed(url: project.fileURL(relative: relative))
        } catch {
            statusMessage = "sheet \(relative): \(error)"
            statusIsError = true
            return nil
        }
    }

    @discardableResult
    public func saveTilesetSheet(_ relative: String, _ png: IndexedPNG) -> Bool {
        guard let project else { return false }
        do {
            let url = project.fileURL(relative: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PNG.writeIndexed(png).write(to: url, options: .atomic)
            statusMessage = "saved \(relative)"
            statusIsError = false
            return true
        } catch {
            statusMessage = "sheet save failed: \(error)"
            statusIsError = true
            return false
        }
    }
}
