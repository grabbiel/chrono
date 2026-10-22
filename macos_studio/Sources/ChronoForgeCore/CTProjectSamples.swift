// The project's rom.samples as `rom build` will number and write them, for the
// Studio's instrument rack and song budgets before a build (docs/sfx_lab.md).
import Foundation

public enum CTProjectSamples {
    public struct Placed: Sendable {
        public let id: String
        /// The Audio_SampleTable number: the one it replaces, or 63 on in list order.
        public let number: Int
        public let request: CTSamplePatch.Request
    }

    /// Each entry of rom.samples that resolves, and why the others do not.
    public static func placed(_ project: CTProject) -> (placed: [Placed], problems: [String: String]) {
        var out: [Placed] = [], problems: [String: String] = [:], appended = 0
        for s in project.project.rom?.samples ?? [] {
            let number = s.replace ?? CTSampleTables.rom.count + 1 + appended
            if s.replace == nil { appended += 1 }
            do {
                let request = try CTROMBuilder.sampleRequest(s, project: project)
                try CTSamplePatch.check(request)
                out.append(.init(id: s.id, number: number, request: request))
            } catch { problems[s.id] = "\(error)" }
        }
        return (out, problems)
    }

    /// The instruments of `samples` with the project's samples in place of the ROM's.
    public static func rack(rom: [UInt8], samples: [Int], project: CTProject) throws -> [CTSongInstrument] {
        let byNumber = Dictionary(placed(project).placed.map { ($0.number, $0.request) }, uniquingKeysWith: { a, _ in a })
        let tables = try CTSampleTables.locate(rom)
        return try samples.enumerated().map { slot, n in
            if let r = byNumber[n] {
                return CTSongInstrument(slot: slot, sample: n, tuning: UInt16(r.tuning), adsr: UInt16(r.adsr), length: r.brr.count,
                                        loopOffset: r.loopOffset)
            }
            let e = try tables.entry(rom, n)
            return CTSongInstrument(slot: slot, sample: n, tuning: UInt16(e.tuning), adsr: UInt16(e.adsr), length: e.length,
                                    loopOffset: e.loopOffset)
        }
    }

    /// Song `song`'s budget as the build would load it: `data` and `tables`
    /// (a listing's) in place of the ROM's when given, its list followed by
    /// the project samples that name the song, their lengths for theirs.
    public static func budget(rom: [UInt8], project: CTProject, song: Int, data: [UInt8]? = nil,
                              tables: CTSongTables = .init()) throws -> CTSongBudget {
        let songs = try CTSong.romSongs(rom)
        guard songs.indices.contains(song) else { throw CTSongError("song \(song) is not 0-\(songs.count - 1)") }
        let rows = CTSongTables.rom(rom, song: song)
        let placed = placed(project).placed
        var list = tables.samples ?? rows.samples ?? []
        for p in placed where p.request.songs.contains(song) && !list.contains(p.number) { list.append(p.number) }
        let instruments = try rack(rom: rom, samples: list, project: project)
        let echo = tables.echo ?? rows.echo ?? [0, 0]
        return CTSongBudget.budget(song: song, sequenceBytes: (data ?? songs[song].data).count, samples: list,
                                   lengths: instruments.map(\.length), start: CTSongInstrument.sampleAreaStart(rom: rom),
                                   edl: Int(echo[0] & 0x0F))
    }
}
