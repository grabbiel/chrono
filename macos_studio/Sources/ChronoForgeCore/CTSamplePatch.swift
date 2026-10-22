// Project samples in the game: the four sample tables of bank $C7 as the
// 65816 sender reads them, the driver's note-to-pitch formula (so a sample's
// tuning word comes from its rate), and the writes that replace one of the
// ROM's samples or append new ones. docs/sfx_lab.md has the evidence;
// re_workspace/tools/ct_samples.py is the independent Python reader.
import Foundation

/// Audio_SampleTable, Audio_SampleLoop, Audio_SampleParamA and
/// Audio_SampleParamB as the code that reads them names them.
public struct CTSampleTables: Equatable, Sendable {
    public enum Table: String, CaseIterable, Sendable { case pointers, loops, tuning, adsr }

    /// The long operands of the twelve bank-$C7 instructions that read the
    /// tables (file offset of the operand, its table, the byte it adds):
    /// Audio_UploadSample and Audio_CmdSwapSample read the pointer's three
    /// bytes, Audio_SendSampleDir and Audio_CmdSwapSample the loop word and
    /// both parameter words (bankC7.asm:818-928, 1260-1264, 1469-1625). A
    /// byte search of the US 1.0 ROM finds no other long reference to them;
    /// Audio_TableDirectory ($C7:0028) lists them as bank-local words and
    /// nothing reads it.
    public static let sites: [(operand: Int, table: Table, offset: Int)] = [
        (0x070667, .pointers, 0), (0x07066D, .pointers, 1), (0x070673, .pointers, 2),
        (0x070774, .pointers, 0), (0x07077A, .pointers, 1), (0x070780, .pointers, 2),
        (0x0703AD, .loops, 0), (0x07085D, .loops, 0),
        (0x07043D, .tuning, 0), (0x070887, .tuning, 0),
        (0x07048B, .adsr, 0), (0x0708B1, .adsr, 0),
    ]
    /// LDA long,X and ADC long,X: the opcodes before those operands.
    static let opcodes: Set<UInt8> = [0xBF, 0x7F]
    /// The US 1.0 layout: 62 entries from $C7:0AEA, the four tables back to back.
    public static let rom = CTSampleTables(pointers: 0xC70AEA, count: 62)
    /// Sample numbers are words, but Audio_CmdSwapSample masks its argument to a byte.
    public static let numberMax = 255

    /// Long addresses (bank $C0-$FF) of the tables and how many entries they hold.
    public let pointers, count: Int
    public var loops: Int { pointers + 3 * count }
    public var tuning: Int { loops + 2 * count }
    public var adsr: Int { tuning + 2 * count }
    public var bytes: Int { 9 * count }
    public init(pointers: Int, count: Int) { self.pointers = pointers; self.count = count }

    public func address(_ table: Table) -> Int {
        switch table {
        case .pointers: return pointers
        case .loops: return loops
        case .tuning: return tuning
        case .adsr: return adsr
        }
    }

    /// The tables a ROM's code reads: every site must name the same four
    /// back-to-back tables (as the ROM and this builder lay them out).
    public static func locate(_ rom: [UInt8]) throws -> CTSampleTables {
        guard rom.count == CTROMBuilder.romSize else { throw CTSongError("expected a 4 MiB ROM") }
        var found: [Table: Int] = [:]
        for site in sites {
            guard opcodes.contains(rom[site.operand - 1]) else {
                throw CTSongError(String(format: "$%06X is not the LDA/ADC long,X that reads the sample tables", site.operand - 1))
            }
            let operand = Int(rom[site.operand]) | Int(rom[site.operand + 1]) << 8 | Int(rom[site.operand + 2]) << 16
            let base = operand - site.offset
            if let known = found[site.table], known != base {
                throw CTSongError("the code reads \(site.table.rawValue) from two places")
            }
            found[site.table] = base
        }
        let pointers = found[.pointers]!, count = (found[.loops]! - pointers) / 3
        let tables = CTSampleTables(pointers: pointers, count: count)
        guard (1...numberMax).contains(count), found[.loops]! == tables.loops, found[.tuning]! == tables.tuning,
              found[.adsr]! == tables.adsr, (0xC0...0xFF).contains(pointers >> 16),
              (tables.adsr + 2 * count - 1) >> 16 <= 0xFF else {
            throw CTSongError("the sample tables are not laid out back to back")
        }
        return tables
    }

    public struct Entry: Equatable, Sendable {
        public let number: Int                   // 1-count
        public let pointer: Int                  // long address of the length word
        public let pc: Int
        public let length: Int                   // BRR bytes
        public let loopOffset: Int, tuning: Int, adsr: Int
        public var blocks: Int { length / 9 }
    }

    static func pc(_ long: Int) -> Int { long & 0x3FFFFF }

    func word(_ rom: [UInt8], _ long: Int) -> Int { Int(rom[Self.pc(long)]) | Int(rom[Self.pc(long) + 1]) << 8 }

    /// Entry `number` (1-count) as the sender reads it.
    public func entry(_ rom: [UInt8], _ number: Int) throws -> Entry {
        guard (1...count).contains(number) else { throw CTSongError("sample \(number) is not 1-\(count)") }
        let at = Self.pc(pointers + 3 * (number - 1))
        let pointer = Int(rom[at]) | Int(rom[at + 1]) << 8 | Int(rom[at + 2]) << 16
        guard (0xC0...0xFF).contains(pointer >> 16), Self.pc(pointer) + 2 <= rom.count else {
            throw CTSongError(String(format: "sample %d points at $%06X, outside banks $C0-$FF", number, pointer))
        }
        let length = word(rom, pointer)
        guard Self.pc(pointer) + 2 + length <= rom.count else { throw CTSongError("sample \(number) runs past the ROM") }
        return Entry(number: number, pointer: pointer, pc: Self.pc(pointer), length: length,
                     loopOffset: word(rom, loops + 2 * (number - 1)), tuning: word(rom, tuning + 2 * (number - 1)),
                     adsr: word(rom, adsr + 2 * (number - 1)))
    }

    /// The BRR bytes of an entry (after its length word).
    public func brr(_ rom: [UInt8], _ entry: Entry) -> [UInt8] { Array(rom[(entry.pc + 2)..<(entry.pc + 2 + entry.length)]) }
}

/// Spc_NotePitch (driver.asm $06BD): the pitch register value the driver
/// writes for a note, from the sample's ParamA word.
public enum CTSampleTuning {
    /// Spc_PitchTable ($1D6D): octave 4's twelve semitones, 4096 x 2^((k - 11) / 12) rounded
    /// down (the ROM test compares it with the driver's table).
    public static let pitchTable: [Int] = (0..<12).map { k in
        let ratio = pow(2.0, Double(k - 11) / 12)
        return Int((4096.0 * ratio).rounded(.down))
    }
    /// Pitch $1000 plays one BRR sample per 32 kHz output sample.
    public static let unityPitch = 0x1000, outputRate = 32_000
    /// A note number with transpose 10 (as `octave o` and note index i sound 12 o + i).
    public static let defaultRoot = 60

    /// The driver's arithmetic, step for step: octave = n / 12, P = the
    /// semitone's word, t = (tuning low byte + fine tune) & $FF,
    /// Q = P.hi x t + (P.lo x t) >> 8; a nonzero tuning high byte h adds
    /// (Q.hi x h) >> 8; t below $80 adds P; then the octave's shift from 4.
    public static func pitch(note n: Int, tuning: Int, fine: Int = 0) -> Int {
        let note = n & 0xFF, octave = note / 12, p = pitchTable[note % 12]
        let t = (tuning + fine) & 0xFF, h = tuning >> 8 & 0xFF
        var q = (p >> 8) * t
        q = (q + (((p & 0xFF) * t) >> 8)) & 0xFFFF
        if h != 0 { q = (q + (((q >> 8) * h) >> 8)) & 0xFFFF }
        if t & 0x80 == 0 { q = (q + p) & 0xFFFF }
        if octave > 4 { for _ in 4..<octave { q = (q << 1) & 0xFFFF } }
        else { for _ in octave..<4 { q >>= 1 } }
        return q
    }

    /// The pitch register value that plays a `rate` Hz sample at its own pitch.
    public static func target(rate: Int) -> Int { (unityPitch * rate + outputRate / 2) / outputRate }

    public struct Solution: Codable, Equatable, Sendable {
        public let tuning: Int, rootNote: Int, rate: Int
        public let pitch: Int, target: Int
        /// The played rate's error, in cents.
        public var cents: Double { 1200 * log2(Double(pitch) / Double(target)) }
    }

    /// The ParamA word whose root note plays a `rate` Hz sample closest to its
    /// own pitch; nil when no word reaches it within a semitone (the root
    /// is then outside the octave the tuning byte covers: x0.5 to x1.5).
    public static func solve(rate: Int, rootNote: Int) -> Solution? {
        guard (1...128_000).contains(rate), (0...0xFF).contains(rootNote) else { return nil }
        let want = target(rate: rate)
        var best: (word: Int, pitch: Int)?
        func consider(_ word: Int) {
            let p = pitch(note: rootNote, tuning: word)
            if best == nil || abs(p - want) < abs(best!.pitch - want) { best = (word, p) }
        }
        // For a fixed low byte the pitch only grows with the high byte, so the
        // closest high byte is next to the first one that reaches the target.
        for t in 0...0xFF {
            var low = 0, high = 0xFF
            while low < high {
                let mid = (low + high) / 2
                if pitch(note: rootNote, tuning: mid << 8 | t) < want { low = mid + 1 } else { high = mid }
            }
            consider(low << 8 | t)
            if low > 0 { consider((low - 1) << 8 | t) }
        }
        guard let best, best.pitch > 0 else { return nil }
        let solution = Solution(tuning: best.word, rootNote: rootNote, rate: rate, pitch: best.pitch, target: want)
        return abs(solution.cents) < 100 ? solution : nil
    }

    /// The root notes `solve` can tune a `rate` Hz sample for.
    public static func roots(rate: Int) -> ClosedRange<Int>? {
        let notes = (0...0x7F).filter { solve(rate: rate, rootNote: $0).map { abs($0.cents) < 5 } ?? false }
        guard let low = notes.first, let high = notes.last else { return nil }
        return low...high
    }

    /// `defaultRoot` when it can be tuned, else the nearest C that can.
    public static func defaultRoot(rate: Int) -> Int {
        guard let range = roots(rate: rate) else { return defaultRoot }
        if range.contains(defaultRoot) { return defaultRoot }
        let cs = stride(from: 0, through: 0x7F, by: 12).filter(range.contains)
        return cs.min { abs($0 - defaultRoot) < abs($1 - defaultRoot) } ?? range.lowerBound
    }
}

/// The writes that put project samples into the ROM (`rom.samples`).
public enum CTSamplePatch {
    /// One sample to write: `replace` (1-62) takes over that entry, nil
    /// appends it after the ROM's samples. `brr` is whole blocks with the end
    /// (and loop) flags the game should play; `songs` get it in their list.
    public struct Request: Sendable {
        public let id: String
        public let replace: Int?
        public let brr: [UInt8]
        public let loopOffset: Int
        public let tuning: Int
        public let adsr: Int
        public let songs: [Int]
        public let tune: CTSampleTuning.Solution?
        /// False for bytes kept as they are (a ROM import): block flags before
        /// the last and the loop flag are then not checked.
        public let strict: Bool
        public init(id: String, replace: Int?, brr: [UInt8], loopOffset: Int, tuning: Int, adsr: Int,
                    songs: [Int], tune: CTSampleTuning.Solution? = nil, strict: Bool = true) {
            self.id = id; self.replace = replace; self.brr = brr; self.loopOffset = loopOffset
            self.tuning = tuning; self.adsr = adsr; self.songs = songs; self.tune = tune; self.strict = strict
        }
    }

    public struct ReportSample: Codable, Equatable, Sendable {
        public let id: String
        public let number: Int
        public let replaced: Bool
        public let address: String
        public let pc: Int
        public let length: Int
        public let brrSHA256: String
        public let loopOffset: Int
        public let tuning: Int
        public let adsr: Int
        public let placement: String               // original | reclaimed | free
        public let songs: [Int]
        public let rootNote: Int?                  // when the tuning came from the rate
        public let rate: Int?
        public let asIs: Bool                      // bytes kept as they are (block flags not checked)
    }

    public struct ReportTables: Codable, Equatable, Sendable {
        public let address: String
        public let pc: Int
        public let count: Int
        public let operands: [Int]                 // file offsets of the patched long operands
    }

    /// The game's sample bytes for a project sample, as the SFX Lab preview
    /// plays it (`SPCStream.sample(file:meta:)`): its played blocks with the
    /// flags cleared, the last with end (and loop) set, and the loop offset in bytes.
    public static func gameBytes(file: [UInt8], meta: SampleMeta) throws -> (brr: [UInt8], loopOffset: Int) {
        let played = try SPCStream.playedBlocks(file: file, meta: meta)
        return (played.brr, 9 * played.loopBlock)
    }

    /// The ParamB word (ADSR1 low, ADSR2 high) from the sidecar's ADSR; the
    /// driver writes only ADSR (Spc_WriteAdsr), so a GAIN envelope has none.
    public static func adsrWord(_ meta: SampleMeta) -> Int? {
        guard let (a1, a2) = DSPEnvelope.Setting(sample: meta).adsrRegisters else { return nil }
        return Int(a1) | Int(a2) << 8
    }

    /// Checks that need no ROM: whole blocks, an end flag only on the last,
    /// the loop flag with the end flag when looping, a loop on a block.
    public static func check(_ r: Request) throws {
        func fail(_ m: String) -> CTROMBuildError { CTROMBuildError("sample \(r.id): \(m)") }
        guard !r.brr.isEmpty, r.brr.count % 9 == 0 else { throw fail("\(r.brr.count) bytes is not whole 9-byte BRR blocks") }
        // Audio_UploadSample's BNE loop needs a nonzero multiple of 3; whole blocks are.
        guard r.brr.count <= 0xFFFF - 2 else { throw fail("\(r.brr.count) bytes is more than a length word holds") }
        let blocks = r.brr.count / 9
        for b in 0..<(blocks - 1) where r.strict && r.brr[9 * b] & 1 != 0 {
            throw fail("block \(b) has the end flag before the last block")
        }
        guard r.brr[9 * (blocks - 1)] & 1 != 0 else { throw fail("the last block has no end flag") }
        let loops = r.brr[9 * (blocks - 1)] & 2 != 0 || !r.strict
        // Kept bytes may carry any loop word (two ROM samples point past their data).
        let loopRange = r.strict ? 0..<r.brr.count : 0..<0x10000
        guard r.loopOffset % 9 == 0, loopRange.contains(r.loopOffset), loops || r.loopOffset == 0 else {
            throw fail("loop offset \(r.loopOffset) is not the start of a block (0 without a loop)")
        }
        guard (0...0xFFFF).contains(r.tuning), (0...0xFFFF).contains(r.adsr), r.adsr & 0x80 != 0 else {
            throw fail("the tuning and ADSR words are 16-bit, with ADSR1 bit 7 (ADSR on) set")
        }
        if let replace = r.replace, !(1...CTSampleTables.rom.count).contains(replace) {
            throw fail("replace takes one of the ROM's samples, 1-\(CTSampleTables.rom.count)")
        }
        guard Set(r.songs).count == r.songs.count else { throw fail("a song is named twice") }
    }

    /// Write `requests` into `rom` (the clean base): sample bytes in place when
    /// they fit, else in free space; table entries; for appended samples the
    /// four tables moved to free space with one more entry each and the twelve
    /// operands pointed at them. Returns the numbers, the sample-list rows the
    /// songs get, and the report. `rows` is each song's list before this.
    static func apply(_ requests: [CTSamplePatch.Request], rom: [UInt8], space: inout FreeSpace,
                      rows: (Int) -> [Int], write: ([UInt8], Int, String) -> Void)
        throws -> (lists: [Int: [Int]], samples: [ReportSample], tables: ReportTables?) {
        let base = try CTSampleTables.locate(rom)
        guard base == CTSampleTables.rom else { throw CTROMBuildError("the base ROM's sample tables are not at $C7:0AEA") }
        var replaced = Set<Int>()
        for r in requests {
            try check(r)
            if let n = r.replace, !replaced.insert(n).inserted { throw CTROMBuildError("sample \(n) is replaced twice") }
        }
        let appended = requests.filter { $0.replace == nil }
        let count = base.count + appended.count
        guard count <= CTSampleTables.numberMax else {
            throw CTROMBuildError("at most \(CTSampleTables.numberMax - base.count) samples can be appended")
        }
        var entries = try (1...base.count).map { try base.entry(rom, $0) }
        // Old spans no other entry still uses become reclaimable.
        let kept = Set(entries.filter { !replaced.contains($0.number) }.map(\.pc))
        var homes: [Int: Range<Int>] = [:]
        for e in entries where replaced.contains(e.number) && !kept.contains(e.pc) {
            homes[e.number] = e.pc..<(e.pc + 2 + e.length)
        }

        var report: [ReportSample] = [], numbers: [String: Int] = [:]
        var next = base.count + 1
        for r in requests {
            let number = r.replace ?? next
            if r.replace == nil { next += 1 }
            numbers[r.id] = number
            let block = [UInt8(r.brr.count & 0xFF), UInt8(r.brr.count >> 8)] + r.brr
            let pc: Int, placement: String
            if let home = homes[number], block.count <= home.count {
                pc = home.lowerBound; placement = "original"
                if block.count < home.count { addSplit(home.lowerBound + block.count..<home.upperBound, to: &space) }
                homes[number] = nil
            } else {
                if let home = homes[number] { addSplit(home, to: &space); homes[number] = nil }
                (pc, placement) = try CTROMBuilder.placeBlock(block, home: nil, space: &space, what: "sample \(r.id)")
            }
            write(block, pc, "sample \(r.id) BRR")
            let entry = CTSampleTables.Entry(number: number, pointer: 0xC00000 | pc, pc: pc, length: r.brr.count,
                                             loopOffset: r.loopOffset, tuning: r.tuning, adsr: r.adsr)
            if number <= entries.count { entries[number - 1] = entry } else { entries.append(entry) }
            report.append(.init(id: r.id, number: number, replaced: r.replace != nil, address: CTROMBuilder.snes(pc), pc: pc,
                                length: r.brr.count, brrSHA256: CTEventPack.sha256(r.brr), loopOffset: r.loopOffset,
                                tuning: r.tuning, adsr: r.adsr, placement: placement, songs: r.songs.sorted(),
                                rootNote: r.tune?.rootNote, rate: r.tune?.rate, asIs: !r.strict))
        }

        // The tables: rewritten in place for replacements only; moved when appending.
        var tables: CTSampleTables = base, tablesReport: ReportTables?
        if !appended.isEmpty {
            let size = 9 * count
            guard let pc = space.allocate(size, reclaimed: false) else {
                throw CTROMBuildError("no free space for the \(size)-byte sample tables (\(space.total) bytes left, " +
                                      "in pieces of at most \(space.largest))")
            }
            tables = CTSampleTables(pointers: 0xC00000 | pc, count: count)
            for site in CTSampleTables.sites {
                let operand = tables.address(site.table) + site.offset
                write([UInt8(operand & 0xFF), UInt8(operand >> 8 & 0xFF), UInt8(operand >> 16)], site.operand,
                      "sample table operand at \(CTROMBuilder.snes(site.operand - 1))")
            }
            tablesReport = .init(address: CTROMBuilder.snes(pc), pc: pc, count: count,
                                 operands: CTSampleTables.sites.map(\.operand))
        }
        let touched = Set(report.map(\.number))
        for e in entries where !appended.isEmpty || touched.contains(e.number) {
            let i = e.number - 1, what = "sample \(e.number)"
            write([UInt8(e.pointer & 0xFF), UInt8(e.pointer >> 8 & 0xFF), UInt8(e.pointer >> 16)],
                  CTSampleTables.pc(tables.pointers + 3 * i), "Audio_SampleTable[\(what)]")
            write(le(e.loopOffset), CTSampleTables.pc(tables.loops + 2 * i), "Audio_SampleLoop[\(what)]")
            write(le(e.tuning), CTSampleTables.pc(tables.tuning + 2 * i), "Audio_SampleParamA[\(what)]")
            write(le(e.adsr), CTSampleTables.pc(tables.adsr + 2 * i), "Audio_SampleParamB[\(what)]")
        }

        // Songs: the sample joins the end of each named song's list.
        var lists: [Int: [Int]] = [:]
        for r in requests {
            for song in r.songs {
                var list = lists[song] ?? rows(song)
                let number = numbers[r.id]!
                if !list.contains(number) {
                    guard list.count < 16 else {
                        throw CTROMBuildError(String(format: "sample %@: song $%02X already loads 16 samples", r.id, song))
                    }
                    list.append(number)
                }
                lists[song] = list
            }
        }
        return (lists, report, tablesReport)
    }

    static func le(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }

    /// A span given back to free space, in pieces that stay inside a bank.
    static func addSplit(_ range: Range<Int>, to space: inout FreeSpace) {
        var start = range.lowerBound
        while start < range.upperBound {
            let end = min(range.upperBound, (start | 0xFFFF) + 1)
            space.add(start..<end, reclaimed: true)
            start = end
        }
    }
}

/// A built ROM's song on the real driver, watched for one sample: the load
/// (`CTSPCTransfer`, the ROM's sender transcribed), then the first key-on
/// of a voice that plays it. Its directory entry, ARAM bytes, parameter
/// words, pitch register and the samples the S-DSP decodes for the voice
/// are compared with what the ROM's tables say.
public enum CTSampleProbe {
    public struct Result: Encodable, Sendable {
        public let format = "ct-sample-probe/1"
        public let song: Int, sample: Int
        /// The song's list entry (`sample $20 + slot` plays it) and its ARAM place.
        public let slot: Int, aram: Int, length: Int, loopOffset: Int
        public let tuning: Int, adsr: Int
        public let voice: Int?
        /// The driver's note number, fine tune and tuning word for the voice's track at the key-on.
        public let note: Int?, fine: Int?
        /// The voice's pitch register and Spc_NotePitch's value for that note.
        public let pitch: Int?, formulaPitch: Int?
        /// Samples the voice decoded, compared with the BRR's S-DSP decode,
        /// the filter history at its first decode, and the samples' SHA-256
        /// (little-endian 16-bit), for an independent decode to compare.
        public let decodedSamples: Int
        public let history: [Int]
        public let decodedSHA256: String
        public let transfer: CTSPCTransfer.Report
        public let checks: [CTSPCDriver.Check]
        public let passed: Bool
        /// The rate the voice plays the sample at (32 kHz x pitch / $1000).
        public var playedRate: Double? { pitch.map { Double(CTSampleTuning.outputRate) * Double($0) / Double(CTSampleTuning.unityPitch) } }
        enum CodingKeys: String, CodingKey {
            case format, song, sample, slot, aram, length, loopOffset, tuning, adsr, voice, note, fine, pitch, formulaPitch
            case decodedSamples, history, decodedSHA256, transfer, checks, passed, playedRate
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(format, forKey: .format); try c.encode(song, forKey: .song); try c.encode(sample, forKey: .sample)
            try c.encode(slot, forKey: .slot); try c.encode(aram, forKey: .aram); try c.encode(length, forKey: .length)
            try c.encode(loopOffset, forKey: .loopOffset); try c.encode(tuning, forKey: .tuning); try c.encode(adsr, forKey: .adsr)
            try c.encodeIfPresent(voice, forKey: .voice); try c.encodeIfPresent(note, forKey: .note)
            try c.encodeIfPresent(fine, forKey: .fine); try c.encodeIfPresent(pitch, forKey: .pitch)
            try c.encodeIfPresent(formulaPitch, forKey: .formulaPitch); try c.encode(decodedSamples, forKey: .decodedSamples)
            try c.encode(history, forKey: .history); try c.encode(decodedSHA256, forKey: .decodedSHA256)
            try c.encode(transfer, forKey: .transfer); try c.encode(checks, forKey: .checks); try c.encode(passed, forKey: .passed)
            try c.encodeIfPresent(playedRate, forKey: .playedRate)
        }
    }

    // Driver RAM (spc700.inc): per track X = 2 x voice.
    static let trackTuning = 0xF380, trackF3A0 = 0xF3A0
    static let directoryRegister = 0x5D, konRegister = 0x4C

    /// `clean` boots the driver (the pinned ROM); `built` gives the song load.
    /// Runs up to `cycles` SMP clocks for the key-on, then until `frames`
    /// decoded samples (at most the sample's first pass) were compared.
    public static func run(clean: [UInt8], built: [UInt8], song: Int, sample number: Int,
                           frames: Int = 4096, cycles: Int = 40_000_000) throws -> Result {
        let plan = try CTSPCTransfer.Plan(rom: built, song: song)
        guard let placed = plan.samples.first(where: { $0.number == number }) else {
            throw CTSongError(String(format: "song $%02X does not load sample %d", song, number))
        }
        let tables = try CTSampleTables.locate(built)
        let entry = try tables.entry(built, number)
        let brr = tables.brr(built, entry)
        let (session, load) = try CTSPCTransfer.loadSession(rom: clean, plan: plan, iplROM: nil, limits: .init())
        let cpu = session.cpu, bus = session.bus, dsp = session.dsp
        var checks = load.checks
        func record(_ name: String, _ passed: Bool) { checks.append(.init(name: name, passed: passed)) }
        func word(_ a: Int) -> Int { Int(bus.ram[a]) | Int(bus.ram[a + 1]) << 8 }
        let slot = placed.slot, start = Int(placed.destination)
        record("ARAM holds the sample's BRR bytes", Array(bus.ram[start..<(start + brr.count)]) == brr)
        record("directory entry $20 + slot: start and loop start", word(0x1E80 + 4 * slot) == start
               && word(0x1E82 + 4 * slot) == (start + entry.loopOffset) & 0xFFFF)
        record("parameter words: tuning and ADSR", word(0x1F40 + 2 * slot) == entry.tuning && word(0x1FC0 + 2 * slot) == entry.adsr)

        // The key-on of a voice whose SRCN is $20 + slot.
        let source = UInt8(0x20 + slot), limit = bus.cycles + cycles
        var writes = dsp.registerWrites, voice: Int?
        while voice == nil && bus.cycles < limit {
            if cpu.stopped { bus.idle() } else { cpu.step() }
            if let fault = bus.fault { throw CTSongError("probe bus fault: \(fault)") }
            if dsp.registerWrites != writes {
                writes = dsp.registerWrites
                if bus.ram[0xF2] & 0x7F == UInt8(konRegister) {
                    let kon = dsp.registers[konRegister]
                    voice = (0..<8).first { kon & (1 << $0) != 0 && dsp.registers[$0 << 4 | 4] == source }
                }
            }
        }
        guard let v = voice else {
            record("a voice keys on the sample", false)
            return Result(song: song, sample: number, slot: slot, aram: start, length: entry.length, loopOffset: entry.loopOffset,
                          tuning: entry.tuning, adsr: entry.adsr, voice: nil, note: nil, fine: nil, pitch: nil, formulaPitch: nil,
                          decodedSamples: 0, history: [], decodedSHA256: "", transfer: load.transfer, checks: checks, passed: false)
        }
        // Wait for the S-DSP to take the key-on (KON delay 5), then for its first decode.
        let base = v * 12
        var armed = false, history: (Int, Int)?, got: [Int] = []
        var pitch = 0, note = 0, fine = 0, tuning = 0
        let want = min(frames, brr.count / 9 * 16)
        while got.count < want && bus.cycles < limit {
            let before = dsp.voices[v], ring = Array(dsp.decoded[base..<(base + 12)])
            if cpu.stopped { bus.idle() } else { cpu.step() }
            if let fault = bus.fault { throw CTSongError("probe bus fault: \(fault)") }
            let after = dsp.voices[v]
            if !armed {
                guard after.konDelay == 5 else { continue }
                armed = true
                pitch = Int(dsp.registers[v << 4 | 2]) | Int(dsp.registers[v << 4 | 3]) << 8
                let x = 2 * v
                note = Int(bus.ram[trackF3A0 + x + 1]); fine = Int(bus.ram[trackF3A0 + x])
                tuning = word(trackTuning + x)
                continue
            }
            // The KON fetch (delay 5 to 4) takes the directory entry's start
            // and restarts the buffer at 0; a decode then writes 4 samples
            // there and moves it on by 4.
            let fetch = before.konDelay == 5 && after.konDelay < 5
            if fetch { record("the voice starts at the directory entry", after.brrAddress == start) }
            let from = fetch ? 0 : before.bufferPosition
            guard (after.bufferPosition - from + 12) % 12 == 4 else { continue }
            if history == nil { history = (ring[(from + 11) % 12], ring[(from + 10) % 12]) }
            for i in 0..<4 { got.append(dsp.decoded[base + (from + i) % 12]) }
        }
        let expected = BRR.decodeDSP(brr[...], y1: history?.0 ?? 0, y2: history?.1 ?? 0).samples.prefix(want).map(Int.init)
        let compared = min(got.count, want)
        record("the voice decodes the sample's BRR (\(compared) samples)", compared == want && Array(got.prefix(want)) == expected)
        let formula = CTSampleTuning.pitch(note: note, tuning: tuning, fine: fine)
        record("the track's tuning word is the sample's ParamA", tuning == entry.tuning)
        record("the pitch register is Spc_NotePitch's value", pitch & 0x3FFF == formula & 0x3FFF)
        return Result(song: song, sample: number, slot: slot, aram: start, length: entry.length, loopOffset: entry.loopOffset,
                      tuning: entry.tuning, adsr: entry.adsr, voice: v, note: note, fine: fine, pitch: pitch & 0x3FFF,
                      formulaPitch: formula & 0x3FFF, decodedSamples: compared, history: [history?.0 ?? 0, history?.1 ?? 0],
                      decodedSHA256: CTEventPack.sha256(got.prefix(compared).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF)] }),
                      transfer: load.transfer, checks: checks,
                      passed: checks.allSatisfy(\.passed))
    }
}
