// ProjectStore+Scenes.swift — the Scene Director's ROM locations: the event
// pack a location loads, raised into a ct-scene/1 document, and its edits
// kept as a ct-events/1 listing the ROM build writes over that pack
// (project.json rom.eventPacks; docs/scene_director.md).
import Foundation
import ChronoForgeCore

extension ProjectStore {
    public static let sceneListingDirectory = "scenes/rom"

    /// The ROM the Scene Director reads packs from: `--rom` at launch, else
    /// the remembered playback ROM (Music pane).
    public var sceneROMPath: String? { LaunchArguments.value("--rom") ?? playbackROMPath }

    nonisolated public static func sceneROM(_ path: String) throws -> [UInt8] {
        var rom = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize else { throw CTEventError("expected a 4 MiB Chrono Trigger ROM") }
        return rom
    }

    public static func sceneListingPath(entry: Int) -> String {
        String(format: "%@/pack%03d.ctevt", sceneListingDirectory, entry)
    }

    /// The listing saved for pack `entry`, if the ROM build replaces that pack with one.
    public func savedSceneListing(entry: Int) -> String? {
        guard let rel = project?.project.rom?.eventPacks.first(where: { $0.entry == entry })?.listing else { return nil }
        return readText(rel)
    }

    /// Location `location`'s scene: the saved listing when there is one, else raised from the ROM.
    public func raiseLocation(_ location: Int, rom: [UInt8]) throws -> (document: CTSceneDocument, saved: Bool) {
        let entry = CTMapROM.header(rom, location).events
        if let text = savedSceneListing(entry: entry) {
            return (CTSceneDocument(program: try CTEventListing.parse(text), location: location, packEntry: entry), true)
        }
        let bytes = try CTEventROM.unpack(rom: rom, entry: try CTEventROM.entries(rom: rom)[entry])
        guard !bytes.isEmpty else { throw CTEventError("location \(location) loads event pack \(entry), which is empty") }
        return (try CTSceneDocument.raise(bytes: bytes, location: location, packEntry: entry), false)
    }

    /// Writes the scene as scenes/rom/packNNN.ctevt and points the ROM build's entry at it.
    @discardableResult
    public func saveLocationScene(_ doc: CTSceneDocument) -> Bool {
        guard let project, let entry = doc.packEntry else { return false }
        do {
            _ = try doc.lower()
            let rel = Self.sceneListingPath(entry: entry)
            let title = "location \(doc.location.map(String.init) ?? "?"), Evt_PackPtrs[\(entry)] — edited in the Scene Director; extracted game data, keep local"
            let url = project.fileURL(relative: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(try doc.annotatedListing(title: title).text.utf8).write(to: url, options: .atomic)
            var spec = project.project.rom ?? Project.ROMBuild()
            spec.eventPacks.removeAll { $0.entry == entry }
            spec.eventPacks.append(.init(entry: entry, listing: rel))
            spec.eventPacks.sort { $0.entry < $1.entry }
            guard updateROMBuild(spec) else { return false }
            statusMessage = "saved \(rel); the ROM build writes it over event pack \(entry)"
            statusIsError = false
            return true
        } catch {
            statusMessage = "scene save failed: \(error)"
            statusIsError = true
            return false
        }
    }

    /// Drops the saved listing from the ROM build (the file stays).
    @discardableResult
    public func revertLocationScene(entry: Int) -> Bool {
        guard var spec = project?.project.rom else { return true }
        spec.eventPacks.removeAll { $0.entry == entry }
        return updateROMBuild(spec)
    }
}
