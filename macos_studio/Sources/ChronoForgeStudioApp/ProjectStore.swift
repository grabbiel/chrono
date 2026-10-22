// ProjectStore.swift — observable .ctproj backing store for all panes.
import SwiftUI
import Observation
import ChronoForgeCore
import ChronoForgeAudio

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
    /// Live S-SMP/S-DSP playback shared by the Music and SFX panes.
    public let audio = AKAOAudioEngine()

    public init() {}

    public func load(url: URL) {
        audio.stop()
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

    /// Saves tech_system.json (the Tech & Synergy Matrix's Apply).
    public func updateTechSystem(_ s: TechSystemDef) { project?.techSystem = s; save() }

    /// The ROM's tech tables into tech_system.json (CTTechROM.importTechs); sets `rom.techs`.
    public func importTechs(_ url: URL) {
        guard var candidate = project else { return }
        do {
            try CTTechROM.importTechs(rom: [UInt8](Data(contentsOf: url)), into: &candidate)
            try candidate.save()
            project = candidate
            statusMessage = "imported the tech tables from the ROM"
            statusIsError = false
        } catch {
            statusMessage = "tech import failed: \(error)"
            statusIsError = true
        }
    }

    /// The ROM's seven character records, growth rows, experience table and
    /// equipment into the project (CTCharacterROM.importCharacters).
    public func importCharacters(_ url: URL) {
        guard var candidate = project else { return }
        do {
            let ids = try CTCharacterROM.importCharacters(rom: [UInt8](Data(contentsOf: url)), into: &candidate)
            try candidate.save()
            project = candidate
            statusMessage = "imported \(ids.count) characters from the ROM"
            statusIsError = false
        } catch {
            statusMessage = "character import failed: \(error)"
            statusIsError = true
        }
    }

    /// Saves which characters `rom build` writes (`rom.characters`).
    public func updateROMCharacters(_ ids: [String]) -> Bool {
        guard var candidate = project else { return false }
        var spec = candidate.project.rom ?? Project.ROMBuild()
        spec.characters = ids
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

    /// Saves whether `rom build` writes tech_system.json's tables (`rom.techs`).
    public func updateROMTechs(_ on: Bool) -> Bool {
        guard var candidate = project else { return false }
        var spec = candidate.project.rom ?? Project.ROMBuild()
        spec.techs = on
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

    static func isEmpty(_ spec: Project.ROMBuild) -> Bool {
        spec.eventPacks.isEmpty && spec.songs.isEmpty && spec.characters.isEmpty && !spec.techs && !spec.items
            && spec.maps.isEmpty && spec.tilesets.isEmpty && spec.enemies.isEmpty && spec.sprites.isEmpty
            && spec.samples.isEmpty
    }

    /// Saves the project's `rom` section (nil: no packs or songs). Its
    /// `characters`, `techs`, `items`, `maps`, `tilesets`, `enemies`, `sprites` and
    /// `samples` are kept: their panes or project.json set them (updateROMCharacters,
    /// updateROMTechs, updateROMItems, updateROMEnemies, updateROMSample).
    public func updateROMBuild(_ spec: Project.ROMBuild?) -> Bool {
        guard var candidate = project else { return false }
        var merged = spec ?? Project.ROMBuild()
        merged.characters = candidate.project.rom?.characters ?? []
        merged.techs = candidate.project.rom?.techs ?? false
        merged.items = candidate.project.rom?.items ?? false
        merged.maps = candidate.project.rom?.maps ?? []
        merged.tilesets = candidate.project.rom?.tilesets ?? []
        merged.enemies = candidate.project.rom?.enemies ?? []
        merged.sprites = candidate.project.rom?.sprites ?? []
        merged.samples = candidate.project.rom?.samples ?? []
        candidate.project.rom = Self.isEmpty(merged) ? nil : merged
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
            lines += (report.characters ?? []).map { c in
                let fields = report.writes.filter { $0.what.hasPrefix("character \(c.id) ") }.count
                return "character \(c.id): record \(c.charId) at \(c.address), \(fields) field(s) changed"
            }
            if report.techs != nil {
                let changed = report.writes.filter { CTTechROM.isTechWrite($0.what) }
                lines.append("techs: \(changed.count) table write(s) changed")
            }
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
            if playbackROMPath == nil, CTEventPack.sha256(rom) == CTSPCDriver.cleanROMSHA256 { playbackROMPath = url.path }
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

    // MARK: Playback

    /// The verified US 1.0 ROM the sound driver boots from for song playback
    /// (headered or not); remembered across launches.
    public var playbackROMPath: String? = UserDefaults.standard.string(forKey: "playbackROMPath") {
        didSet { UserDefaults.standard.set(playbackROMPath, forKey: "playbackROMPath") }
    }

    /// Remembers `url` as the playback ROM if it is the verified ROM.
    @discardableResult
    public func setPlaybackROM(_ url: URL) -> Bool {
        do {
            let rom = try Self.playbackROM(url.path)
            guard CTEventPack.sha256(rom) == CTSPCDriver.cleanROMSHA256 else {
                throw CTSongError("\(url.lastPathComponent) is not the verified unheadered CT USA 1.0 ROM")
            }
            playbackROMPath = url.path
            statusMessage = "playback ROM: \(url.lastPathComponent)"
            statusIsError = false
            return true
        } catch {
            statusMessage = "playback ROM: \(error)"
            statusIsError = true
            return false
        }
    }

    /// Plays ROM song `song` as the driver loads it.
    public func playROMSong(_ song: Int) {
        guard let path = playbackROMPath else { return needPlaybackROM() }
        Task { await audio.play(String(format: "ROM song $%02X", song)) {
            try SPCStream.ctSong(rom: try Self.playbackROM(path), song: song)
        } }
    }

    /// Plays a ct-song/1 listing in place of ROM song `song`.
    public func playListing(_ text: String, replacing song: Int, title: String) {
        guard let path = playbackROMPath else { return needPlaybackROM() }
        Task { await audio.play(String(format: "%@ as song $%02X", title, song)) {
            let (data, tables) = try CTSongListing.assembleSong(text)
            return try SPCStream.ctSong(rom: try Self.playbackROM(path), replacing: song, data: data, tables: tables)
        } }
    }

    /// Plays a sample with its (possibly unsaved) sidecar settings.
    public func playSample(_ meta: SampleMeta, title: String) {
        guard let url = fileURL(meta.brr) else { return }
        Task { await audio.play(title) {
            try SPCStream.sample(file: [UInt8](try Data(contentsOf: url)), meta: meta)
        } }
    }

    private func needPlaybackROM() {
        statusMessage = "choose the CT ROM to play songs from (Sound ROM… in the playback bar)"
        statusIsError = true
    }

    nonisolated static func playbackROM(_ path: String) throws -> [UInt8] {
        var rom = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        return rom
    }
}
