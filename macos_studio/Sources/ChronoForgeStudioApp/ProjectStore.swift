// ProjectStore.swift — observable .ctproj backing store for all panes.
import SwiftUI
import Observation
import ChronoForgeCore

@MainActor
@Observable
public final class ProjectStore {
    public var project: CTProject?
    var sceneDrafts: [String: SceneDraft] = [:]
    public var requestOpen = false
    public var showIssues = false
    public var issuesText = ""
    public var statusMessage = ""
    public var statusIsError = false

    public init() {}

    public func load(url: URL) {
        do {
            project = try CTProject.load(from: url)
            sceneDrafts = [:]
            statusMessage = "loaded \(url.lastPathComponent)"
            statusIsError = false
        } catch {
            statusMessage = "load failed: \(error)"
            statusIsError = true
        }
    }

    public func save() {
        guard let project else { return }
        do {
            try project.save()
            statusMessage = "saved \(Date.now.formatted(date: .omitted, time: .standard))"
            statusIsError = false
        } catch {
            statusMessage = "save failed: \(error)"
            statusIsError = true
        }
    }

    public func validateNow() {
        guard let project else { return }
        let issues = Validator.validate(project)
        issuesText = issues.isEmpty ? "All 6 gates pass."
            : issues.map(\.description).joined(separator: "\n")
        showIssues = true
        statusMessage = Validator.isValid(issues) ? "VALID" : "INVALID"
        statusIsError = !Validator.isValid(issues)
    }

    // MARK: Mutations (panes call these; each marks dirty + saves)
    public func updateCharacter(_ c: CharacterDef) { project?.characters[c.id] = c; save() }
    public func updateSprite(_ s: SpriteDef) { project?.sprites[s.id] = s; save() }
    public func updateItem(_ i: ItemDef) { project?.items[i.id] = i; save() }
    public func updateTileset(_ t: Tileset) { project?.tilesets[t.id] = t; save() }
    public func updateMap(_ m: GameMap) { project?.maps[m.id] = m; save() }
    public func updateTrack(_ t: Track) { project?.tracks[t.id] = t; save() }
    public func updateSample(_ id: String, _ s: SampleMeta) { project?.samples[id] = s; save() }
    @discardableResult
    public func updateScene(_ s: SceneDoc) -> Bool {
        guard var candidate = project else { return false }
        do {
            try EventBytecode.validate(s.scene)
            let problems = EventReferences.issues(in: s.scene, flags: Set(candidate.project.flags.map(\.symbol)),
                strings: Set(candidate.dialogue.strings.keys), maps: Set(candidate.maps.keys),
                scenes: candidate.scenes.mapValues(\.scene).merging([s.id: s.scene]) { $1 })
            guard problems.isEmpty else { throw CTProjectError.badFormat(problems.joined(separator: "\n")) }
            candidate.scenes[s.id] = s
            try candidate.save()
            project = candidate
            statusMessage = "saved scene \(s.id)"
            statusIsError = false
            return true
        } catch {
            statusMessage = "scene save failed: \(error)"
            statusIsError = true
            return false
        }
    }
    @discardableResult
    public func updateDialogue(_ strings: [String: String]) -> Bool {
        guard var candidate = project else { return false }
        candidate.dialogue.strings = strings
        do {
            try candidate.save()
            project = candidate
            statusMessage = "saved dialogue"
            statusIsError = false
            return true
        } catch {
            statusMessage = "dialogue save failed: \(error)"
            statusIsError = true
            return false
        }
    }

    public func importTextROM(_ url: URL) {
        guard var candidate = project else { return }
        do {
            candidate.textProfile = try CTTextProfile.fromROM(Data(contentsOf: url))
            try candidate.save()
            project = candidate
            statusMessage = "imported verified US 1.0 text dictionary"
            statusIsError = false
        } catch {
            statusMessage = "text profile import failed: \(error)"
            statusIsError = true
        }
    }
    public func updateTech(_ t: TechDef) { project?.techs[t.id] = t; save() }

    /// Saves the project's `rom` section (nil removes it).
    public func updateROMBuild(_ spec: Project.ROMBuild?) -> Bool {
        guard var candidate = project else { return false }
        candidate.project.rom = spec
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

    /// Writes the built ROM to `output` and its report beside it
    /// (`<name>.build.json`); returns a summary, or nil after an error.
    public func buildROM(base: URL, output: URL) -> String? {
        guard let project else { return nil }
        do {
            let (rom, report) = try CTROMBuilder.build(base: [UInt8](Data(contentsOf: base)), project: project)
            try Data(rom).write(to: output, options: .atomic)
            let reportURL = output.deletingPathExtension().appendingPathExtension("build.json")
            try CTProject.jsonEncoder.encode(report).write(to: reportURL, options: .atomic)
            statusMessage = "built \(output.lastPathComponent)"
            statusIsError = false
            var lines = report.packs.map { p in
                "entry \(p.entry): \(p.packedBytes) B at \(p.address) (\(p.placement))"
                    + (p.messageTable.map { ", messages at \($0)" } ?? "")
            }
            lines += report.songs.map { s in String(format: "song $%02X: %d B at %@ (%@)", s.song, s.bytes, s.address, s.placement) }
            lines.append(String(format: "checksum $%04X; %d bytes of free space left", report.checksum, report.freeBytesLeft))
            lines.append("report: \(reportURL.lastPathComponent)")
            return lines.joined(separator: "\n")
        } catch {
            statusMessage = "ROM build failed: \(error)"
            statusIsError = true
            return nil
        }
    }

    // MARK: Song listings (audio/songs/*.ctsong, ct-song/1)

    public static let songDirectory = "audio/songs"

    /// Project-relative paths of the song listings, sorted.
    public func songListings() -> [String] {
        guard let dir = project?.fileURL(relative: Self.songDirectory),
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".ctsong") }.sorted().map { "\(Self.songDirectory)/\($0)" }
    }

    public func readText(_ rel: String) -> String? {
        project.flatMap { try? String(contentsOf: $0.fileURL(relative: rel), encoding: .utf8) }
    }

    @discardableResult
    public func writeSongListing(_ rel: String, _ text: String) -> Bool {
        guard let project, rel.hasPrefix(Self.songDirectory + "/"), !rel.split(separator: "/").contains("..") else { return false }
        do {
            let url = project.fileURL(relative: rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            statusMessage = "saved \(rel)"
            statusIsError = false
            return true
        } catch {
            statusMessage = "save failed: \(error)"
            statusIsError = true
            return false
        }
    }

    /// Disassembles Audio_SongTable song `song` of a ROM into
    /// audio/songs/songNN.ctsong; returns its path.
    public func importSong(rom url: URL, song: Int) -> String? {
        do {
            var rom = [UInt8](try Data(contentsOf: url))
            if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
            let songs = try CTSong.romSongs(rom)
            guard songs.indices.contains(song) else { throw CTSongError("song must be 0-\(songs.count - 1)") }
            let s = songs[song]
            let title = String(format: "song $%02X ($%02X:%04X, %d bytes)", song, s.pointer >> 16, s.pointer & 0xFFFF, s.data.count)
            let rel = String(format: "%@/song%02X.ctsong", Self.songDirectory, song)
            let listing = try CTSongListing.render(try CTSong(data: s.data), title: title, tables: CTSongTables.rom(rom, song: song))
            return writeSongListing(rel, listing) ? rel : nil
        } catch {
            statusMessage = "song import failed: \(error)"
            statusIsError = true
            return nil
        }
    }

    /// Sets (or with nil clears) the Audio_SongTable index a listing is built into.
    @discardableResult
    public func setSongTarget(_ rel: String, song: Int?) -> Bool {
        var spec = project?.project.rom ?? Project.ROMBuild()
        spec.songs.removeAll { $0.listing == rel || $0.song == song }
        if let song { spec.songs.append(.init(song: song, listing: rel)); spec.songs.sort { $0.song < $1.song } }
        return updateROMBuild(spec.eventPacks.isEmpty && spec.songs.isEmpty ? nil : spec)
    }

    public func fileURL(_ rel: String) -> URL? {
        project?.fileURL(relative: rel)
    }
}
