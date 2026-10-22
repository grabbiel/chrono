// ProjectStore+Items.swift — the Items pane's import and saves.
import Foundation
import ChronoForgeCore

extension ProjectStore {
    /// The ROM's items, names, descriptions and ItemBoosts into the project
    /// (CTItemROM.importItems); sets `rom.items`.
    public func importItems(_ url: URL) {
        guard var candidate = project else { return }
        do {
            let ids = try CTItemROM.importItems(rom: [UInt8](Data(contentsOf: url)), into: &candidate)
            try candidate.save()
            project = candidate
            statusMessage = "imported \(ids.count) items from the ROM"
            statusIsError = false
        } catch {
            statusMessage = "item import failed: \(error)"
            statusIsError = true
        }
    }

    /// Saves the ROM items and item_tables.json (the Items pane's Apply).
    public func updateItemDatabase(_ items: [ItemDef], tables: ItemTablesDef?) {
        guard var candidate = project else { return }
        for i in items { candidate.items[i.id] = i }
        candidate.itemTables = tables
        do {
            try candidate.save()
            project = candidate
            statusMessage = "saved \(items.count) items"
            statusIsError = false
        } catch {
            statusMessage = "save failed: \(error)"
            statusIsError = true
        }
    }

    /// Saves whether `rom build` writes the ROM items (`rom.items`).
    public func updateROMItems(_ on: Bool) -> Bool {
        guard var candidate = project else { return false }
        var spec = candidate.project.rom ?? Project.ROMBuild()
        spec.items = on
        candidate.project.rom = Self.isEmpty(spec) ? nil : spec
        do {
            try candidate.save()
            project = candidate
            statusMessage = "saved ROM build settings"
            statusIsError = false
            return true
        } catch {
            statusMessage = "save failed: \(error)"
            statusIsError = true
            return false
        }
    }
}
