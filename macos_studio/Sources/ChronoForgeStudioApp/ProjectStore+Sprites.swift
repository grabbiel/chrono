// ProjectStore+Sprites.swift — the Sprites pane's import and sheet I/O.
import Foundation
import ChronoForgeCore

extension ProjectStore {
    /// The ROM's seven playable-character sprite sets and the enemies'
    /// battle sprites into the project (CTSpriteROM / CTEnemySpriteROM
    /// importSprites): sheets now, sprite JSON on save.
    public func importSprites(_ url: URL) {
        guard var candidate = project else { return }
        do {
            let rom = [UInt8](try Data(contentsOf: url))
            let ids = try CTSpriteROM.importSprites(rom: rom, into: &candidate)
            let foes = try CTEnemySpriteROM.importSprites(rom: rom, into: &candidate)
            try candidate.save()
            project = candidate
            statusMessage = "imported \(ids.count) character and \(foes.ids.count) enemy sprites from the ROM"
            statusIsError = false
        } catch {
            statusMessage = "sprite import failed: \(error)"
            statusIsError = true
        }
    }

    /// A sprite's sheet, or nil (with the reason in the status line).
    public func spriteSheet(_ s: SpriteDef) -> IndexedPNG? {
        guard let project else { return nil }
        do {
            return try PNG.readIndexed(url: project.fileURL(relative: s.sheet))
        } catch {
            statusMessage = "sheet \(s.sheet): \(error)"
            statusIsError = true
            return nil
        }
    }

    /// Writes a sprite's sheet PNG (indexed, as `PNG.readIndexed` reads it back).
    @discardableResult
    public func saveSpriteSheet(_ s: SpriteDef, _ png: IndexedPNG) -> Bool {
        guard let project else { return false }
        do {
            let url = project.fileURL(relative: s.sheet)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PNG.writeIndexed(png).write(to: url, options: .atomic)
            statusMessage = "saved \(s.sheet)"
            statusIsError = false
            return true
        } catch {
            statusMessage = "sheet save failed: \(error)"
            statusIsError = true
            return false
        }
    }
}
