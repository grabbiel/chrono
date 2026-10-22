// ProjectStore+SFX.swift — the SFX Lab's encodes, saves and previews.
import Foundation
import ChronoForgeCore

extension ProjectStore {
    nonisolated static let sampleDirectory = "audio/samples"

    /// `base` made into a sample id (letters, digits, _ and -) that no
    /// sample uses yet.
    public func newSampleID(_ base: String) -> String {
        var stem = String(base.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        if stem.isEmpty { stem = "sample" }
        var id = stem, n = 2
        while project?.samples[id] != nil { id = "\(stem)_\(n)"; n += 1 }
        return id
    }

    /// The sample's bare BRR blocks, from its `.brr` file.
    public func sampleBlocks(_ meta: SampleMeta) -> [UInt8]? {
        guard let url = fileURL(meta.brr), let data = try? Data(contentsOf: url) else { return nil }
        let file = [UInt8](data)
        if file.count >= 11, Int(file[0]) | Int(file[1]) << 8 == file.count - 2, (file.count - 2) % 9 == 0 { return Array(file[2...]) }
        if !file.isEmpty, file.count % 9 == 0 { return file }
        if file.count > 2, (file.count - 2) % 9 == 0 { return Array(file[2...]) }
        return nil
    }

    /// Writes `audio/samples/<id>.brr` ([u16 length][blocks]), its decoded
    /// preview `<id>.wav` and the sidecar `<id>.json`.
    @discardableResult
    public func saveSample(id: String, blocks: [UInt8], meta: SampleMeta) -> Bool {
        guard var candidate = project else { return false }
        var meta = meta
        meta.brr = "\(Self.sampleDirectory)/\(id).brr"
        do {
            let brr = candidate.fileURL(relative: meta.brr)
            try FileManager.default.createDirectory(at: brr.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(SFXImport.fileBytes(blocks)).write(to: brr)
            let preview = BRR.decodeDSP(blocks).map { Int16(clamping: Int($0) * 2) }
            try WAV.writeWav(samples: preview, rate: meta.rate ?? SPCRender.sampleRate)
                .write(to: brr.deletingPathExtension().appendingPathExtension("wav"))
            candidate.samples[id] = meta
            try candidate.save()
            project = candidate
            statusMessage = "saved sample \(id) (\(blocks.count / 9) blocks)"
            statusIsError = false
            return true
        } catch {
            statusMessage = "sample save failed: \(error)"
            statusIsError = true
            return false
        }
    }

    // MARK: Use in game (rom.samples)

    /// Sample `id`'s rom.samples entry, when `rom build` writes it.
    public func romSample(_ id: String) -> Project.ROMBuild.Sample? {
        project?.project.rom?.samples.first { $0.id == id }
    }

    /// The bytes and words `entry` would write (from the saved sidecar and .brr), or why not.
    public func resolveROMSample(_ entry: Project.ROMBuild.Sample) -> Result<CTSamplePatch.Request, Error> {
        guard let project else { return .failure(CTSongError("no project")) }
        return Result {
            let request = try CTROMBuilder.sampleRequest(entry, project: project)
            try CTSamplePatch.check(request)
            return request
        }
    }

    /// Lists sample `id` in rom.samples as `entry`, or with nil takes it out.
    /// An entry the game cannot load is refused with the reason in the status line.
    @discardableResult
    public func updateROMSample(_ id: String, entry: Project.ROMBuild.Sample?) -> Bool {
        guard var candidate = project else { return false }
        var spec = candidate.project.rom ?? Project.ROMBuild()
        var note = "took \(id) out of rom.samples"
        if let entry {
            switch resolveROMSample(entry) {
            case .failure(let error):
                statusMessage = "\(error)"
                statusIsError = true
                return false
            case .success(let r):
                note = String(format: "rom.samples: %@ %@, tuning $%04X, ADSR $%04X", id,
                              entry.replace.map { "replaces sample \($0)" } ?? "is appended", r.tuning, r.adsr)
            }
            if let i = spec.samples.firstIndex(where: { $0.id == id }) { spec.samples[i] = entry } else { spec.samples.append(entry) }
        } else {
            spec.samples.removeAll { $0.id == id }
        }
        candidate.project.rom = Self.isEmpty(spec) ? nil : spec
        do {
            try candidate.save()
            project = candidate
            statusMessage = note
            statusIsError = false
            return true
        } catch {
            statusMessage = "save failed: \(error)"
            statusIsError = true
            return false
        }
    }

    /// Song `song`'s ARAM and sequence budget as `rom build` would load it
    /// with `project`'s rom.samples and rom.songs (or `listing` for its text).
    public func songBudget(_ song: Int, in project: CTProject? = nil, listing: String? = nil) -> Result<CTSongBudget, Error> {
        guard let p = project ?? self.project else { return .failure(CTSongError("no project")) }
        guard let path = playbackROMPath, let rom = try? Self.playbackROM(path) else {
            return .failure(CTSongError("choose the CT ROM (Sound ROM… in the playback bar) for the budget"))
        }
        return Result {
            var text = listing
            if text == nil, let rel = p.project.rom?.songs.first(where: { $0.song == song })?.listing {
                text = try String(contentsOf: p.fileURL(relative: rel), encoding: .utf8)
            }
            guard let text else { return try CTProjectSamples.budget(rom: rom, project: p, song: song) }
            let (data, tables) = try CTSongListing.assembleSong(text)
            return try CTProjectSamples.budget(rom: rom, project: p, song: song, data: data, tables: tables)
        }
    }

    /// Plays BRR blocks with a sidecar's settings (unsaved edits included).
    public func playSample(blocks: [UInt8], meta: SampleMeta, title: String) {
        Task { await audio.play(title) { try SPCStream.sample(file: SFXImport.fileBytes(blocks), meta: meta) } }
    }

    /// Encodes off the main actor: a WAV import or a synth spec.
    nonisolated public static func encodeWAV(_ url: URL, options: SFXImport.Options) async throws -> SFXImport.Report {
        try await Task.detached(priority: .userInitiated) {
            try SFXImport.encode(wav: try WAV.read(url: url), options: options)
        }.value
    }

    nonisolated public static func encodeSynth(_ spec: SynthSpec, beam: Int) async throws -> SFXImport.Report {
        try await Task.detached(priority: .userInitiated) { try SFXSynth.encode(spec, beam: beam) }.value
    }

    /// The envelope curve for the shaper, rendered by the S-DSP off the main actor.
    nonisolated public static func envelopeCurve(_ setting: DSPEnvelope.Setting, keyOffTick: Int?, tickDivider: UInt8,
                                                 seconds: Double) async throws -> DSPEnvelope.Curve {
        try await Task.detached(priority: .userInitiated) {
            let frames = max(64, Int(seconds * Double(SPCRender.sampleRate)))
            return try DSPEnvelope.render(setting, keyOffTick: keyOffTick, tickDivider: tickDivider,
                                          frames: frames, stride: max(1, frames / 1024))
        }.value
    }
}
