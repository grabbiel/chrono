// A song's room in ARAM, as the game loads it: the sequence from $2000 up
// to $4700 (it reaches the $2F00 effects block from $0F00 bytes on), and its
// samples from $4700 + boot block 2 up to the echo buffer the song's delay
// sets. Every US 1.0 song fits; the builder refuses a song that does not.
import Foundation

public struct CTSongBudget: Codable, Equatable, Sendable {
    public let song: Int
    /// Sequence bytes (after the length word) and the most that loads below $4700.
    public let sequenceBytes: Int, sequenceMax: Int
    /// The sequence is !Audio_SongRoom ($0F00) bytes or longer: while it plays
    /// it overwrites the $2F00 effects block, which the next load sends again.
    public let reachesEffectsBlock: Bool
    public let samples: [Int]
    /// ARAM: the first sample's address, the end of the last, and the echo
    /// buffer's start ($F100 - EDL x $800).
    public let sampleStart: Int, sampleEnd: Int, echoStart: Int
    public let edl: Int
    public var sampleBytes: Int { sampleEnd - sampleStart }
    public var freeBytes: Int { echoStart - sampleEnd }
    public var fits: Bool { CTSongISA.fits(sequenceBytes) && sampleEnd <= echoStart }

    /// The budget of `song` in `rom` (any ROM laid out like US 1.0, built or
    /// not), with `data` and `tables` in place of the ROM's when given.
    public static func of(rom: [UInt8], song: Int, data: [UInt8]? = nil, tables: CTSongTables = .init()) throws -> CTSongBudget {
        let songs = try CTSong.romSongs(rom)
        guard songs.indices.contains(song) else { throw CTSongError("song \(song) is not 0-\(songs.count - 1)") }
        let rows = CTSongTables.rom(rom, song: song)
        let samples = tables.samples ?? rows.samples ?? []
        let echo = tables.echo ?? rows.echo ?? [0, 0]
        let sampleTables = try CTSampleTables.locate(rom)
        let lengths = try samples.map { try sampleTables.entry(rom, $0).length }
        return budget(song: song, sequenceBytes: (data ?? songs[song].data).count, samples: samples, lengths: lengths,
                      start: CTSongInstrument.sampleAreaStart(rom: rom), edl: Int(echo[0] & 0x0F))
    }

    /// The budget from its parts (the Studio's rack uses this while editing).
    public static func budget(song: Int, sequenceBytes: Int, samples: [Int], lengths: [Int], start: Int, edl: Int) -> CTSongBudget {
        CTSongBudget(song: song, sequenceBytes: sequenceBytes, sequenceMax: CTSongISA.maxLength,
                     reachesEffectsBlock: sequenceBytes >= CTSongISA.songRoom, samples: samples,
                     sampleStart: start, sampleEnd: start + lengths.reduce(0, +),
                     echoStart: CTSongEcho.buffer(edl: edl).lowerBound, edl: edl)
    }

    /// Why the game cannot load it, or nil.
    public var problem: String? {
        if !CTSongISA.fits(sequenceBytes) {
            return String(format: "song $%02X: %d sequence bytes; the most that loads below $4700 is %d", song, sequenceBytes, sequenceMax)
        }
        if sampleEnd > echoStart {
            return String(format: "song $%02X: its %d samples end at $%04X, %d bytes into the echo buffer at $%04X (EDL %d)",
                          song, samples.count, sampleEnd, sampleEnd - echoStart, echoStart, edl)
        }
        return nil
    }
}
