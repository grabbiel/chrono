// A new song to compose in the tracker: a ct-song/1 listing whose tracks are
// rests the song's length, each looping back to its start, so every note
// the piano roll inserts lands in a rest played once (docs/music_tracker.md).
import Foundation

public enum CTSongTemplate {
    public struct Track: Equatable, Sendable {
        public var slot: Int                // sample $20 + slot: entry `slot` of @samples
        public var volume: Int, pan: Int, octave: Int
        public init(slot: Int, volume: Int = 0x60, pan: Int = 0x40, octave: Int = 4) {
            self.slot = slot; self.volume = volume; self.pan = pan; self.octave = octave
        }
    }

    public struct Options: Equatable, Sendable {
        public var samples: [Int]           // the @samples row: sample numbers
        public var tracks: [Track]          // tracks A 0... in order (at most 8)
        public var steps: Int               // each track's length, in song steps
        public var tempo: Int = 0x40
        public var edl: Int = 0             // echo delay: 0 leaves every byte below $F100 to samples
        /// The @echo row's byte 1: the song command's Arg1, which the driver keeps in !Spc_Unk4D and
        /// multiplies every song voice's volume by (/ 256): 0 is silent. $FF is the ROM's most common.
        public var songVolume: Int = 0xFF
        public var echoVolume: Int = 0, feedback: Int = 0, firSet: Int = 0
        public init(samples: [Int], tracks: [Track], steps: Int = 768) {
            self.samples = samples; self.tracks = tracks; self.steps = steps
        }
    }

    /// Rests that add up to `steps`, longest first (Spc_DurationTable lengths).
    public static func rests(_ steps: Int) throws -> [Int] {
        var left = steps, out: [Int] = []
        for d in CTSongISA.durations.sorted(by: >) {
            while left >= d { out.append(d); left -= d }
        }
        guard left == 0, !out.isEmpty else { throw CTSongError("\(steps) steps is not a sum of note lengths (3 or more, in steps)") }
        return out
    }

    public static func listing(_ o: Options, title: String = "new song") throws -> String {
        guard (1...8).contains(o.tracks.count) else { throw CTSongError("a song has 1-8 tracks (set A)") }
        guard o.samples.count <= 16, o.samples.allSatisfy({ (1...CTSongISA.sampleNumberMax).contains($0) }) else {
            throw CTSongError("@samples takes at most 16 sample numbers")
        }
        guard (0...15).contains(o.edl), (0...0xFF).contains(o.tempo), (0...0xFF).contains(o.songVolume) else {
            throw CTSongError("EDL is 0-15, tempo and song volume bytes")
        }
        for t in o.tracks {
            guard o.samples.indices.contains(t.slot) else { throw CTSongError("track sample slot \(t.slot) is not in @samples") }
            guard (0...0xFF).contains(t.volume), (0...0xFF).contains(t.pan), (0...9).contains(t.octave) else {
                throw CTSongError("volume and pan are bytes, octave 0-9")
            }
        }
        let rests = try rests(o.steps)
        func hex(_ v: Int) -> String { String(format: "$%02X", v) }
        var lines = ["; \(title)", "; ct-song/1 — a new song from the template; see macos_studio/docs/music_tracker.md",
                     "@origin $2000", "@notrack $FFFF",
                     "@samples " + (o.samples.isEmpty ? "none" : o.samples.map(String.init).joined(separator: " ")),
                     "@echo \(hex(o.edl)) \(hex(o.songVolume))", "@drums none"]
        for i in 0..<16 { lines.append("@track \(i < 8 ? "A" : "B") \(i % 8) " + (i < o.tracks.count ? "TRACK\(i)" : "-")) }
        for (i, t) in o.tracks.enumerated() {
            lines.append("TRACK\(i):")
            if i == 0 {
                lines += ["    tempo \(hex(o.tempo))", "    echo_volume \(hex(o.echoVolume))",
                          "    efb_fade $00 \(hex(o.feedback))", "    fir $00 \(hex(o.firSet & 3))"]
            }
            lines += ["    sample \(hex(0x20 + t.slot))", "    volume \(hex(t.volume))", "    pan \(hex(t.pan))",
                      "    octave \(hex(t.octave))", "    transpose $0A", "LOOP\(i):"]
            lines += rests.map { "    rest \($0)" }
            lines.append("    jump ->LOOP\(i)")
        }
        let text = lines.joined(separator: "\n") + "\n"
        _ = try CTSongListing.assembleSong(text)
        return text
    }
}
