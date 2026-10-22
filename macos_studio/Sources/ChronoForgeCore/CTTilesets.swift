// CTTilesets.swift — Chrono Trigger's location tilesets: the graphics packs a
// location's LocRom Tileset12 / Tileset3 values put in VRAM, their metatile
// tables, the location palette sets and both field animation lists (tiles and
// palette cycles). The Swift twin of re_workspace/tools/ct_tilesets.py, which
// holds the evidence (ChronoRET routines, ROM-wide claims, the ROM's own
// routines run in an interpreter); docs/tilesets.md describes the result.
import Foundation

public enum CTTilesetROM {
    public static let locRom = 0xF60000, locCount = 512, locBytes = 14   // LocRom: +1 Tileset12, +2 Tileset3, +3 Palette
    public static let none = 0xFF                                         // !LocRom_SetNone
    public static let lists = 0xF61C00, listBytes = 8                     // LocGfx_Lists: 8 pack numbers per Tileset12
    public static let meta12Ptrs = 0xF62100, meta3Ptrs = 0xF621C0         // long pointers to lz11 metatile tables
    public static let packPtrs = 0xF62220                                 // LocGfx_PackPtrs
    public static let locPal = 0xF624C0, palSetBytes = 0xD2               // LocPal_Rom: 88 sets
    public static let palRows = 7, rowColours = 15                        // colours 1-15 of CGRAM rows 1-7
    public static let vram0 = 0x2000, vramStep = 0x0800                   // slot k uploads to $2000 + $800 k
    public static let packBytes = 0x1000, pack5Bytes = 0x0F80
    public static let vramL3 = 0x5000
    public static let bg12Char = 0x1000, bg3Char = 0x5000                 // BG12NBA $11, BG34NBA $05 (Ppu_SetBgLayout)
    public static let window = 1024                                       // characters a tilemap word names
    public static let slots = 6                                           // packs 6 and 7 go to $7F:6000 / $7F:7000
    public static let animWram = 0x7F6000, animWramBytes = 0x2000
    public static let animAPtrs = 0xFDF290, animA = 0xFDF310              // FieldRom_AnimListAPtrs / AnimListA
    public static let animBPtrs = 0xFDF9C7, animB = 0xFDFA77              // FieldRom_AnimListBPtrs / AnimListB
    public static let animSetMask = 0x3F, records = 12, bFilled = 6
    public static let endRecord = 0x80
    public static let frameMask = 0x0E00                                  // FieldAnimA: frame = accumulator bits 9-11
    public static let palAnimRom = 0xF60000
    public static let cycleKinds = [1: "rom-frames", 2: "rotate-down", 3: "rotate-up", 4: "fade-white", 5: "fade",
                                    6: "pulse-white", 7: "pulse", 8: "list-frames"]

    static func pc(_ long: Int) -> Int { CTSpriteROM.pc(long) }
    static func snes(_ long: Int) -> String { CTSpriteROM.snes(long) }
    static func u8(_ rom: [UInt8], _ long: Int) -> Int { Int(rom[pc(long)]) }
    static func u16(_ rom: [UInt8], _ long: Int) -> Int { u8(rom, long) | u8(rom, long + 1) << 8 }
    static func u24(_ rom: [UInt8], _ long: Int) -> Int { u16(rom, long) | u8(rom, long + 2) << 16 }

    // MARK: Locations

    public struct Location: Equatable, Sendable {
        public var id: Int, tileset12: Int, tileset3: Int, palette: Int
    }

    public static func locations(_ rom: [UInt8]) -> [Location] {
        (0..<locCount).map { i in
            let at = locRom + locBytes * i
            return Location(id: i, tileset12: u8(rom, at + 1), tileset3: u8(rom, at + 2), palette: u8(rom, at + 3))
        }
    }

    /// {value: location ids} of one LocRom field, $FF left out.
    public static func users(_ rom: [UInt8], _ field: KeyPath<Location, Int>) -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        for loc in locations(rom) where loc[keyPath: field] != none { out[loc[keyPath: field], default: []].append(loc.id) }
        return out
    }

    /// The `field` value most locations with `key` == value use (ties: the lowest).
    static func mostCommon(_ rom: [UInt8], _ key: KeyPath<Location, Int>, _ value: Int,
                           _ field: KeyPath<Location, Int>) -> Int? {
        var counts: [Int: Int] = [:]
        for loc in locations(rom) where loc[keyPath: key] == value && loc[keyPath: field] != none {
            counts[loc[keyPath: field], default: 0] += 1
        }
        return counts.min { ($0.value, -$0.key) > ($1.value, -$1.key) }?.key
    }

    // MARK: Graphics

    public struct Pack: Sendable {
        public var number: Int, at: Int, data: [UInt8], mode: LZSSMode, packed: Int
    }

    public static func unpack(_ rom: [UInt8], _ long: Int) throws -> (out: [UInt8], mode: LZSSMode, length: Int) {
        let start = pc(long)
        return try LZSS.decompressStream(Array(rom[start..<min(rom.count, start + 0x10000)]), maxOutput: 0x10000)
    }

    public static func packList(_ rom: [UInt8], _ t: Int) -> [Int?] {
        (0..<listBytes).map { k in
            let n = u8(rom, lists + listBytes * t + k)
            return n == none ? nil : n
        }
    }

    public static func pack(_ rom: [UInt8], _ n: Int) throws -> Pack {
        let at = u24(rom, packPtrs + 3 * n)
        let s = try unpack(rom, at)
        return Pack(number: n, at: at, data: s.out, mode: s.mode, packed: s.length)
    }

    /// A run of characters (bytes) with the ones a tileset sets marked.
    public struct Window: Sendable {
        public var bytes: [UInt8]
        public var set: [Bool]
        public let tileBytes: Int
        public init(tiles: Int, tileBytes: Int) {
            bytes = [UInt8](repeating: 0, count: tiles * tileBytes)
            set = [Bool](repeating: false, count: tiles * tileBytes)
            self.tileBytes = tileBytes
        }
        mutating func write<C: Collection>(_ data: C, at: Int) where C.Element == UInt8 {
            for (i, b) in data.enumerated() where at + i < bytes.count { bytes[at + i] = b; set[at + i] = true }
        }
        public var tiles: Int { bytes.count / tileBytes }
        /// Characters whose every byte the tileset sets.
        public var knownTiles: [Bool] {
            (0..<tiles).map { t in set[(t * tileBytes)..<((t + 1) * tileBytes)].allSatisfy { $0 } }
        }
        /// Row-major palette indices of every character (unset bytes read 0).
        public func indices(bpp: Int) -> [[UInt8]] {
            TileDecoder.decodeIndices(bytes, depth: bpp == 2 ? .bpp2 : .bpp4).chunked(64)
        }
    }

    public struct Upload: Equatable, Sendable {
        public var slot: Int, pack: Int?, vram: Int, firstTile: Int, tiles: Int
        public var at: Int?, packed: Int?, unpacked: Int?, ownTiles: Int?
        public var tilesetSlot: Tileset.Slot {
            Tileset.Slot(slot: slot, vram: vram, firstTile: firstTile, tiles: tiles, pack: pack, source: at.map(snes),
                         ownTiles: ownTiles)
        }
    }

    /// The BG1/2 character window after LocLoad_Unk0960: packs 0-5 unpack to
    /// one $1000-byte stage and slot k uploads $1000 bytes of it ($F80 for
    /// slot 5) to VRAM $2000 + $800 k, so a short pack sends the stage tail an
    /// earlier pack of the list left.
    public static func bg12Window(_ rom: [UInt8], _ t: Int) throws -> (window: Window, uploads: [Upload]) {
        var window = Window(tiles: Self.window, tileBytes: 32)
        var stage = Window(tiles: packBytes / 32, tileBytes: 32)
        var uploads: [Upload] = []
        for (k, n) in packList(rom, t).prefix(slots).enumerated() {
            let size = k == slots - 1 ? pack5Bytes : packBytes
            let vram = vram0 + vramStep * k, first = (vram - bg12Char) / 16
            var up = Upload(slot: k, pack: n, vram: vram, firstTile: first, tiles: size / 32)
            if let n {
                let p = try pack(rom, n)
                stage.write(p.data.prefix(packBytes), at: 0)
                for i in 0..<size where stage.set[i] { window.write([stage.bytes[i]], at: first * 32 + i) }
                up.at = p.at; up.packed = p.packed; up.unpacked = p.data.count
                up.ownTiles = min(p.data.count, size) / 32
            }
            uploads.append(up)
        }
        return (window, uploads)
    }

    public struct AnimPack: Equatable, Sendable {
        public var slot: Int, pack: Int, at: Int, packed: Int, unpacked: Int, wram: Int
    }

    /// $7F:6000-$7FFF after LocLoad_UnpackPacks67 (the tile animations' frames).
    public static func animWindow(_ rom: [UInt8], _ t: Int) throws -> (window: Window, packs: [AnimPack]) {
        var w = Window(tiles: animWramBytes / 32, tileBytes: 32)
        var used: [AnimPack] = []
        let list = packList(rom, t)
        for k in 6...7 {
            guard let n = list[k] else { continue }
            let p = try pack(rom, n)
            let base = 0x1000 * (k - 6)
            w.write(p.data.prefix(animWramBytes - base), at: base)
            used.append(AnimPack(slot: k, pack: n, at: p.at, packed: p.packed, unpacked: p.data.count,
                                 wram: animWram + base))
        }
        return (w, used)
    }

    /// The BG3 character window after LocLoad_Unk6DCF: the pack unpacked to
    /// $7F:5080 and $1000 bytes from there sent to VRAM $5000 (past a short
    /// pack: whatever follows the stage, which this tileset does not set).
    public static func bg3Window(_ rom: [UInt8], _ n: Int) throws -> (window: Window, upload: Upload) {
        var w = Window(tiles: Self.window, tileBytes: 16)
        let p = try pack(rom, n)
        let own = min(p.data.count, packBytes), first = (vramL3 - bg3Char) / 8
        w.write(p.data.prefix(own), at: first * 16)
        return (w, Upload(slot: 0, pack: n, vram: vramL3, firstTile: first, tiles: packBytes / 16, at: p.at,
                          packed: p.packed, unpacked: p.data.count, ownTiles: own / 16))
    }

    /// [first, end) runs of true.
    public static func ranges(_ flags: [Bool]) -> [Range<Int>] {
        var out: [Range<Int>] = [], start: Int?
        for (i, f) in (flags + [false]).enumerated() {
            if f, start == nil { start = i }
            if !f, let s = start { out.append(s..<i); start = nil }
        }
        return out
    }

    // MARK: Metatiles and palettes

    public struct MetaTable: Sendable {
        public var at: Int, mode: LZSSMode, packed: Int, length: Int
        public var metatiles: [[UInt16]]                  // 4 tilemap words each: TL, TR, BL, BR
    }

    public static func metaTable(_ rom: [UInt8], ptrs: Int, _ i: Int) throws -> MetaTable {
        let at = u24(rom, ptrs + 3 * i)
        let s = try unpack(rom, at)
        let words = stride(from: 0, to: s.out.count - 1, by: 2).map { UInt16(s.out[$0]) | UInt16(s.out[$0 + 1]) << 8 }
        return MetaTable(at: at, mode: s.mode, packed: s.length, length: s.out.count,
                         metatiles: stride(from: 0, to: words.count - 3, by: 4).map { Array(words[$0..<($0 + 4)]) })
    }

    /// Colours 1-15 of CGRAM rows 1-7.
    public static func paletteSet(_ rom: [UInt8], _ p: Int) -> [[UInt16]] {
        let at = locPal + palSetBytes * p
        return (0..<palRows).map { r in (0..<rowColours).map { c in UInt16(u16(rom, at + 2 * (rowColours * r + c))) } }
    }

    /// 256 CGRAM words with the set's rows and the rest 0.
    public static func cgram(_ rom: [UInt8], _ p: Int) -> [UInt16] {
        var out = [UInt16](repeating: 0, count: 256)
        for (r, row) in paletteSet(rom, p).enumerated() { out.replaceSubrange((16 * (r + 1) + 1)..<(16 * (r + 2)), with: row) }
        return out
    }

    // MARK: Animation lists

    public struct TileAnimRecord: Equatable, Sendable {
        public var kind: Int, vram: Int, steps: [Int], sources: [Int]
        /// Both repeated to the 8 entries FieldFD_LoadAnimSetA writes at $7F:0400.
        public var steps8: [Int] { Array(repeatElement(steps, count: 8 / steps.count).joined()) }
        public var sources8: [Int] { Array(repeatElement(sources, count: 8 / sources.count).joined()) }
    }

    /// The 12 records FieldFD_LoadAnimSetA reads for Tileset12 t (nil: $80),
    /// the list's address and its end.
    public static func animListA(_ rom: [UInt8], _ t: Int) -> (records: [TileAnimRecord?], at: Int, end: Int) {
        let start = animA + u16(rom, animAPtrs + 2 * (t & animSetMask))
        var at = start, out: [TileAnimRecord?] = []
        for _ in 0..<records {
            let kind = u8(rom, at)
            if kind == endRecord { out.append(nil); at += 1; continue }
            let n = kind == 2 ? 2 : kind == 4 ? 4 : 8
            out.append(TileAnimRecord(kind: kind, vram: u16(rom, at + 1), steps: (0..<n).map { u8(rom, at + 3 + $0) },
                                          sources: (0..<n).map { u16(rom, at + 3 + n + 2 * $0) }))
            at += 3 + 3 * n
        }
        return (out, start, at)
    }

    public struct CycleRecord: Equatable, Sendable {
        public var byte0: Int, kind: Int, first: Int, count: Int, delay: Int
        public var offset: Int?, bank: Int?, order: [Int]?
        public var colours: [[UInt16]]?                   // the frames the record can show
        public var name: String { CTTilesetROM.cycleKinds[kind] ?? "kind-\(kind)" }
        public var frames: Int? { offset == nil ? nil : (byte0 & 0x0F) + 1 }
    }

    /// The 6 records FieldFD_LoadAnimSetB reads for Palette p (nil: empty).
    public static func animListB(_ rom: [UInt8], _ p: Int) -> (records: [CycleRecord?], at: Int, end: Int) {
        let start = animB + u16(rom, animBPtrs + 2 * p)
        var at = start, records: [CycleRecord?] = []
        for _ in 0..<bFilled {
            let b = u8(rom, at), kind = b >> 4
            if kind == 0 { records.append(nil); at += 1; continue }
            var r = CycleRecord(byte0: b, kind: kind, first: u8(rom, at + 1), count: u8(rom, at + 2), delay: u8(rom, at + 3))
            if kind == 1 || kind == 8 {
                r.offset = u16(rom, at + 4); r.bank = u8(rom, at + 6)
                at += 7
                if kind == 8 {
                    r.order = (0...(b & 0x0F)).map { u8(rom, at + $0) }
                    at += (b & 0x0F) + 1
                }
                let shown = kind == 8 ? (r.order!.max()! + 1) : (b & 0x0F) + 1
                r.colours = (0..<shown).map { f in
                    (0..<r.count).map { c in UInt16(u16(rom, palAnimRom + r.offset! + 2 * (f * r.count + c))) }
                }
            } else {
                at += 4
            }
            records.append(r)
        }
        return (records, start, at)
    }

    // MARK: Decoded tilesets

    public struct Decoded12: Sendable {
        public var index: Int
        public var packs: [Int?]
        public var window: Window
        public var uploads: [Upload]
        public var meta: MetaTable
        public var anim: Window
        public var animPacks: [AnimPack]
        public var tileAnims: [TileAnimRecord?]
        public var animListAt: Int, animListEnd: Int
        public var locations: [Int]
        public var previewPalette: Int?, previewTileset3: Int?
    }

    public static func decode12(_ rom: [UInt8], _ t: Int) throws -> Decoded12 {
        let (window, uploads) = try bg12Window(rom, t)
        let (anim, animPacks) = try animWindow(rom, t)
        let a = animListA(rom, t)
        return Decoded12(index: t, packs: packList(rom, t), window: window, uploads: uploads,
                         meta: try metaTable(rom, ptrs: meta12Ptrs, t), anim: anim, animPacks: animPacks,
                         tileAnims: a.records, animListAt: a.at, animListEnd: a.end,
                         locations: users(rom, \.tileset12)[t] ?? [],
                         previewPalette: mostCommon(rom, \.tileset12, t, \.palette),
                         previewTileset3: mostCommon(rom, \.tileset12, t, \.tileset3))
    }

    public struct Decoded3: Sendable {
        public var index: Int, window: Window, upload: Upload, meta: MetaTable, locations: [Int]
    }

    public static func decode3(_ rom: [UInt8], _ n: Int) throws -> Decoded3 {
        let (window, upload) = try bg3Window(rom, n)
        return Decoded3(index: n, window: window, upload: upload, meta: try metaTable(rom, ptrs: meta3Ptrs, n),
                        locations: users(rom, \.tileset3)[n] ?? [])
    }

    public struct DecodedPalette: Sendable {
        public var index: Int, rows: [[UInt16]], cycles: [CycleRecord?], cyclesAt: Int, cyclesEnd: Int, locations: [Int]
    }

    public static func decodePalette(_ rom: [UInt8], _ p: Int) -> DecodedPalette {
        let b = animListB(rom, p)
        return DecodedPalette(index: p, rows: paletteSet(rom, p), cycles: b.records, cyclesAt: b.at, cyclesEnd: b.end,
                              locations: users(rom, \.palette)[p] ?? [])
    }
}

// MARK: - Project import

public enum CTTilesets {
    public static func id12(_ t: Int) -> String { String(format: "t12_%02d", t) }
    public static func id3(_ n: Int) -> String { String(format: "t3_%02d", n) }
    public static func idPalette(_ p: Int) -> String { String(format: "pal_%02d", p) }
    static func hex(_ w: UInt16) -> String { String(format: "0x%04X", w) }
    static func word(_ s: String) -> UInt16 {
        UInt16(s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s, radix: 16) ?? 0
    }

    public static func metatiles(_ m: CTTilesetROM.MetaTable) -> [Tileset.Metatile] {
        m.metatiles.map { Tileset.Metatile(chips: $0.map { Tileset.Chip(word: $0) }) }
    }

    /// Frames of the tile animations: tile = the target character, frames =
    /// animSheet tiles ($7F:6000 + 32 x frame).
    public static func tileAnimations(_ records: [CTTilesetROM.TileAnimRecord?]) -> [Tileset.TileAnimation] {
        records.compactMap { $0 }.map { r in
            Tileset.TileAnimation(tile: (r.vram - CTTilesetROM.bg12Char) / 16, steps: r.steps8,
                                  frames: r.sources8.map { ($0 - (CTTilesetROM.animWram & 0xFFFF)) / 32 })
        }
    }

    public static func paletteCycles(_ records: [CTTilesetROM.CycleRecord?]) -> [Tileset.PaletteCycle] {
        records.compactMap { $0 }.map { r in
            Tileset.PaletteCycle(kind: r.name, first: r.first, count: r.count, delay: r.delay,
                                 frames: r.colours?.map { $0.map(hex) }, order: r.order,
                                 source: r.offset.map { CTTilesetROM.snes((r.bank ?? 0) << 16 | $0) })
        }
    }

    /// 8 rows of 16 hex words; row 0 and colour 0 of each row are not the
    /// location's (0x0000).
    public static func paletteRows(_ rows: [[UInt16]]) -> [[String]] {
        [[String](repeating: hex(0), count: 16)] + rows.map { [hex(0)] + $0.map(hex) }
    }

    public static func spans(_ w: CTTilesetROM.Window) -> [Tileset.Span] {
        CTTilesetROM.ranges(w.knownTiles).map { Tileset.Span(firstTile: $0.lowerBound, tiles: $0.count) }
    }

    /// The sheet's PLTE: a 4bpp sheet the preview palette's most used row, a
    /// 2bpp one a gray ramp (the PPU picks the colours per metatile).
    static func sheetPalette(bpp: Int, rows: [[UInt16]]?, metatiles: [[UInt16]]) -> [BGR555] {
        guard bpp == 4, let rows else {
            return (0..<(1 << bpp)).map { BGR555(word: PPUPreviewScenes.grayCGRAM(bpp: bpp)[$0]) }
        }
        var uses = [Int](repeating: 0, count: 8)
        for mt in metatiles { for w in mt { uses[Int(w >> 10 & 7)] += 1 } }
        let row = (1...7).max { (uses[$0], -$0) < (uses[$1], -$1) }!
        return ([0] + rows[row - 1]).map { BGR555(word: $0) }
    }

    static func write(_ png: IndexedPNG, _ rel: String, in project: CTProject) throws {
        let url = project.fileURL(relative: rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PNG.writeIndexed(png).write(to: url, options: .atomic)
    }

    public static func sheetPNG(_ w: CTTilesetROM.Window, bpp: Int, palette: [BGR555]) -> IndexedPNG {
        SpriteSheet.png(tiles: w.indices(bpp: bpp), palette: palette, bitDepth: bpp)
    }

    /// Every Tileset12, Tileset3 and Palette value a location uses (or the
    /// ones given) into `project` as t12_NN / t3_NN / pal_NN: the sheets are
    /// written now, the JSON on the project's next save. A tileset already
    /// there keeps its collision.
    @discardableResult
    public static func importTilesets(rom input: [UInt8], into project: inout CTProject, tileset12: [Int]? = nil,
                                      tileset3: [Int]? = nil, palettes: [Int]? = nil) throws -> [String] {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("tilesets import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        return try importDecoded(rom: rom, into: &project, tileset12: tileset12, tileset3: tileset3, palettes: palettes)
    }

    /// The import without the ROM check (the tests feed it synthetic images).
    public static func importDecoded(rom: [UInt8], into project: inout CTProject, tileset12: [Int]? = nil,
                                     tileset3: [Int]? = nil, palettes: [Int]? = nil) throws -> [String] {
        let t12s = tileset12 ?? CTTilesetROM.users(rom, \.tileset12).keys.sorted()
        let t3s = tileset3 ?? CTTilesetROM.users(rom, \.tileset3).keys.sorted()
        let pals = palettes ?? CTTilesetROM.users(rom, \.palette).keys.sorted()
        var ids: [String] = []
        func keep(_ ts: inout Tileset) {
            if let old = project.tilesets[ts.id] { ts.collision = old.collision }
            project.tilesets[ts.id] = ts
            ids.append(ts.id)
        }
        for t in t12s {
            let d = try CTTilesetROM.decode12(rom, t)
            let id = id12(t)
            let rows = d.previewPalette.map { CTTilesetROM.paletteSet(rom, $0) }
            let plte = sheetPalette(bpp: 4, rows: rows, metatiles: d.meta.metatiles)
            let sheet = "tilesets/\(id).png", animSheet = d.animPacks.isEmpty ? nil : "tilesets/\(id)_anim.png"
            try write(sheetPNG(d.window, bpp: 4, palette: plte), sheet, in: project)
            if let animSheet { try write(sheetPNG(d.anim, bpp: 4, palette: plte), animSheet, in: project) }
            let anims = tileAnimations(d.tileAnims)
            var ts = Tileset(id: id, sheet: sheet, bpp: 4, tileCount: CTTilesetROM.window, metatiles: metatiles(d.meta),
                             kind: "bg12",
                             vram: .init(charBase: CTTilesetROM.bg12Char, slots: d.uploads.map(\.tilesetSlot),
                                         known: spans(d.window)),
                             tileAnimations: anims.isEmpty ? nil : anims, animSheet: animSheet,
                             preview: .init(palette: d.previewPalette.map(idPalette), layer3: d.previewTileset3.map(id3)),
                             rom: .init(family: "ct-loc12", index: t, table: CTTilesetROM.snes(d.meta.at),
                                        packedBytes: d.meta.packed,
                                        list: CTTilesetROM.snes(CTTilesetROM.lists + CTTilesetROM.listBytes * t),
                                        animations: CTTilesetROM.snes(d.animListAt), locations: d.locations))
            keep(&ts)
        }
        for n in t3s {
            let d = try CTTilesetROM.decode3(rom, n)
            let id = id3(n), sheet = "tilesets/\(id).png"
            try write(sheetPNG(d.window, bpp: 2, palette: sheetPalette(bpp: 2, rows: nil, metatiles: [])), sheet, in: project)
            var ts = Tileset(id: id, sheet: sheet, bpp: 2, tileCount: CTTilesetROM.window, metatiles: metatiles(d.meta),
                             kind: "bg3",
                             vram: .init(charBase: CTTilesetROM.bg3Char, slots: [d.upload.tilesetSlot], known: spans(d.window)),
                             rom: .init(family: "ct-loc3", index: n, table: CTTilesetROM.snes(d.meta.at),
                                        packedBytes: d.meta.packed, locations: d.locations))
            keep(&ts)
        }
        for p in pals {
            let d = CTTilesetROM.decodePalette(rom, p)
            let cycles = paletteCycles(d.cycles)
            var ts = Tileset(id: idPalette(p), kind: "palette", palettes: paletteRows(d.rows),
                             paletteCycles: cycles.isEmpty ? nil : cycles,
                             rom: .init(family: "ct-locpal", index: p,
                                        table: CTTilesetROM.snes(CTTilesetROM.locPal + CTTilesetROM.palSetBytes * p),
                                        animations: CTTilesetROM.snes(d.cyclesAt), locations: d.locations))
            keep(&ts)
        }
        return ids
    }

    /// A tileset as `tilesets import` decodes it, checked against the project's
    /// copy: the problems found (none = the import holds).
    public static func verify(rom: [UInt8], project: CTProject) throws -> (checked: Int, problems: [String]) {
        var problems: [String] = [], checked = 0
        func sheetTiles(_ ts: Tileset) throws -> [[UInt8]] {
            guard let sheet = ts.sheet else { return [] }
            return SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: sheet)))
        }
        func windowTiles(_ w: CTTilesetROM.Window, bpp: Int) -> [[UInt8]] {
            let known = w.knownTiles, idx = w.indices(bpp: bpp)
            return idx.indices.map { known[$0] ? idx[$0] : [UInt8](repeating: 0, count: 64) }
        }
        for t in CTTilesetROM.users(rom, \.tileset12).keys.sorted() {
            checked += 1
            guard let ts = project.tilesets[id12(t)] else { problems.append("\(id12(t)): not imported"); continue }
            let d = try CTTilesetROM.decode12(rom, t)
            if ts.metatiles != metatiles(d.meta) { problems.append("\(ts.id): metatiles differ") }
            if ts.vram?.known != spans(d.window) { problems.append("\(ts.id): known characters differ") }
            if (ts.tileAnimations ?? []) != tileAnimations(d.tileAnims) { problems.append("\(ts.id): tile animations differ") }
            if try sheetTiles(ts) != windowTiles(d.window, bpp: 4) { problems.append("\(ts.id): sheet differs") }
            if let anim = ts.animSheet {
                let tiles = SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: anim)))
                if tiles != d.anim.indices(bpp: 4) { problems.append("\(ts.id): animation sheet differs") }
            } else if !d.animPacks.isEmpty { problems.append("\(ts.id): animation sheet missing") }
        }
        for n in CTTilesetROM.users(rom, \.tileset3).keys.sorted() {
            checked += 1
            guard let ts = project.tilesets[id3(n)] else { problems.append("\(id3(n)): not imported"); continue }
            let d = try CTTilesetROM.decode3(rom, n)
            if ts.metatiles != metatiles(d.meta) { problems.append("\(ts.id): metatiles differ") }
            if try sheetTiles(ts) != windowTiles(d.window, bpp: 2) { problems.append("\(ts.id): sheet differs") }
        }
        for p in CTTilesetROM.users(rom, \.palette).keys.sorted() {
            checked += 1
            guard let ts = project.tilesets[idPalette(p)] else { problems.append("\(idPalette(p)): not imported"); continue }
            let d = CTTilesetROM.decodePalette(rom, p)
            let rows = (ts.palettes ?? []).map { $0.map(word) }
            if rows.count != 8 || (0..<7).contains(where: { Array(rows[$0 + 1].dropFirst()) != d.rows[$0] }) {
                problems.append("\(ts.id): palette rows differ")
            }
            if (ts.paletteCycles ?? []) != paletteCycles(d.cycles) { problems.append("\(ts.id): palette cycles differ") }
        }
        return (checked, problems)
    }
}

// MARK: - VRAM budget

/// What a tileset puts in VRAM: the characters its uploads fill against the
/// ones its metatiles name.
public struct TilesetBudget: Equatable, Sendable {
    public var tileBytes: Int
    public var uploaded: Int          // characters the slots send (with a short pack's stale tail)
    public var known: Int             // characters the tileset sets
    public var named: Int             // distinct characters the metatiles name
    public var namedUnknown: [Int]    // named but not set by this tileset (the game shows what VRAM holds there)
    public var animated: Int          // characters tile animations rewrite
    public var bytes: Int { uploaded * tileBytes }

    public init(_ ts: Tileset) {
        tileBytes = ts.bytesPerTile
        uploaded = ts.vram?.slots.filter { $0.pack != nil }.reduce(0) { $0 + $1.tiles } ?? ts.tileCount
        let spans = ts.vram?.known ?? [Tileset.Span(firstTile: 0, tiles: ts.tileCount)]
        var isKnown = [Bool](repeating: false, count: max(1024, ts.tileCount))
        for s in spans { for t in s.firstTile..<min(isKnown.count, s.firstTile + s.tiles) { isKnown[t] = true } }
        known = isKnown.filter { $0 }.count
        let names = Set(ts.metatiles.flatMap { $0.chips.map(\.tile) })
        named = names.count
        namedUnknown = names.filter { $0 < isKnown.count && !isKnown[$0] }.sorted()
        animated = (ts.tileAnimations ?? []).reduce(into: Set<Int>()) { s, a in s.formUnion(a.tile..<(a.tile + a.tiles)) }.count
    }
}

// MARK: - Animation

/// PalAnim_TickAll over a CGRAM image for the location kinds: each cycle's
/// counter steps every tick and the cycle acts when it reaches `delay`.
public struct PaletteCycler: Sendable {
    public var cycles: [Tileset.PaletteCycle]
    var counters: [Int], frames: [Int]

    public init(_ cycles: [Tileset.PaletteCycle]) {
        self.cycles = cycles
        counters = [Int](repeating: 0, count: cycles.count)
        frames = counters
    }

    public mutating func tick(_ cg: inout [UInt16]) {
        for (i, c) in cycles.enumerated() {
            counters[i] = (counters[i] + 1) & 0xFF
            guard counters[i] == c.delay & 0xFF else { continue }
            counters[i] = 0
            let first = c.first, count = c.count
            switch c.kind {
            case "rom-frames", "list-frames":
                let frameList = c.frames ?? []
                let length = c.kind == "list-frames" ? (c.order ?? []).count : frameList.count
                guard length > 0 else { continue }
                frames[i] = (frames[i] + 1) % length
                let shown = c.kind == "list-frames" ? c.order![frames[i]] : frames[i]
                guard shown < frameList.count else { continue }
                for k in 0..<min(count, frameList[shown].count) { cg[(first + k) & 0xFF] = CTTilesets.word(frameList[shown][k]) }
            case "rotate-down":                           // each takes the one above
                guard first + count < 256 else { continue }
                let keep = cg[first]
                for k in first..<(first + count) { cg[k] = cg[k + 1] }
                cg[first + count] = keep
            case "rotate-up":                             // each takes the one below
                guard first + count < 256 else { continue }
                let keep = cg[first + count]
                for k in stride(from: first + count, to: first, by: -1) { cg[k] = cg[k - 1] }
                cg[first] = keep
            default:
                continue                                  // fades: not used by locations
            }
        }
    }
}

/// FieldFD_UploadTileAnims: per animation an accumulator += 4 x steps[f] on
/// each upload, f = its bits 9-11.
public struct TileAnimator: Sendable {
    public var animations: [Tileset.TileAnimation]
    public private(set) var accumulators: [Int]

    public init(_ animations: [Tileset.TileAnimation]) {
        self.animations = animations
        accumulators = [Int](repeating: 0, count: animations.count)
    }

    /// The frame (0-7) each animation shows now.
    public var frames: [Int] { accumulators.map { ($0 & CTTilesetROM.frameMask) >> 9 } }

    public mutating func upload() {
        for (i, a) in animations.enumerated() where !a.steps.isEmpty {
            accumulators[i] = (accumulators[i] + 4 * a.steps[frames[i] % a.steps.count]) & 0xFFFF
        }
    }
}

// MARK: - PPU scenes

/// Metatiles on the PPU the way the field shows them: mode 1, characters at
/// the tileset's VRAM base (BG1 $1000 / BG3 $5000), 16 metatiles per row in a
/// 32x64 tilemap at word 0, CGRAM from a palette tileset.
public enum TilesetScene {
    public static let perRow = 16

    /// CGRAM from a palette tileset's rows (rows it lacks: a gray ramp), with
    /// the preview backdrop as colour 0.
    public static func cgram(_ palette: Tileset?) -> [UInt16] {
        var cg = PPUPreviewScenes.grayCGRAM(bpp: 4)
        for (r, row) in (palette?.palettes ?? []).enumerated() where r < 16 && r > 0 {
            for (c, h) in row.enumerated() where c < 16 && c > 0 { cg[16 * r + c] = CTTilesets.word(h) }
        }
        return cg
    }

    public static func charBase(_ ts: Tileset) -> Int {
        ts.vram?.charBase ?? (ts.bpp == 2 ? CTTilesetROM.bg3Char : CTTilesetROM.bg12Char)
    }

    /// Rows of metatiles in the scene.
    public static func rows(_ ts: Tileset) -> Int { (ts.metatiles.count + perRow - 1) / perRow }

    public static func frame(_ ts: Tileset, tiles: [[UInt8]], cgram: [UInt16], scrollY: Int = 0) -> PPUFrame {
        let layer = ts.bpp == 2 ? 2 : 0
        var r = PPURegisters()
        r.bgmode = 0x09                                    // mode 1, BG3 high priority (Ppu_SetBgLayout)
        r.tm = 1 << layer
        r.bg[layer] = PPUBGRegisters(sc: 0x02, charBase: UInt8(charBase(ts) >> 12), vofs: UInt16((scrollY - 1) & 0x3FF))
        var f = PPUFrame(registers: r)
        f.storeTiles(Array(tiles.prefix(1024).joined()), bpp: ts.bpp, atWord: charBase(ts))
        for (m, mt) in ts.metatiles.enumerated() where m < perRow * 32 {
            for (q, c) in mt.chips.prefix(4).enumerated() {
                let tx = (m % perRow) * 2 + q % 2, ty = (m / perRow) * 2 + q / 2
                f.vram[ty * 32 + tx] = c.word                // 32x64: the lower screen follows at +$400
            }
        }
        f.cgram = cgram
        return f
    }

    /// The metatiles, `perRow` per row, as CGRAM indices (0 = backdrop) read
    /// straight from the tilemap words: what the scene's frame shows.
    public static func cgramIndices(_ ts: Tileset, tiles: [[UInt8]], metatiles: Range<Int>? = nil) -> (width: Int, height: Int, indices: [Int]) {
        let range = metatiles ?? 0..<ts.metatiles.count
        let width = perRow * 16, height = (range.count + perRow - 1) / perRow * 16
        var out = [Int](repeating: 0, count: width * height)
        let rowStep = ts.bpp == 2 ? 4 : 16
        for (k, m) in range.enumerated() where m < ts.metatiles.count {
            for (q, c) in ts.metatiles[m].chips.prefix(4).enumerated() where c.tile < tiles.count {
                for i in 0..<64 {
                    let x = i % 8, y = i / 8
                    let v = Int(tiles[c.tile][(c.vflip ? 7 - y : y) * 8 + (c.hflip ? 7 - x : x)])
                    let ox = (k % perRow) * 16 + (q % 2) * 8 + x, oy = (k / perRow) * 16 + (q / 2) * 8 + y
                    out[oy * width + ox] = v == 0 ? 0 : rowStep * c.pal + v
                }
            }
        }
        return (width, height, out)
    }

    /// Write each animation's current frame (4 animSheet tiles) over its characters.
    public static func applyTileAnimations(_ f: inout PPUFrame, _ ts: Tileset, animTiles: [[UInt8]], frames: [Int]) {
        for (a, f0) in zip(ts.tileAnimations ?? [], frames) where f0 < a.frames.count {
            let src = a.frames[f0]
            guard src >= 0, src + a.tiles <= animTiles.count else { continue }
            f.storeTiles(Array(animTiles[src..<(src + a.tiles)].joined()), bpp: ts.bpp,
                         atWord: charBase(ts) + a.tile * ts.bpp * 4)
        }
    }
}

/// Both animations of a previewed tileset advanced to a frame count (the
/// field runs PalAnim_TickAll every frame and one tile upload every other).
public struct TilesetPlayer: Sendable {
    public private(set) var frame = 0
    public var cycler: PaletteCycler
    public var animator: TileAnimator
    let baseCGRAM: [UInt16]
    public private(set) var cgram: [UInt16]

    public init(tileset: Tileset, palette: Tileset?, cgram: [UInt16]) {
        cycler = PaletteCycler(palette?.paletteCycles ?? [])
        animator = TileAnimator(tileset.tileAnimations ?? [])
        baseCGRAM = cgram
        self.cgram = cgram
    }

    public mutating func advance(to n: Int) {
        if n < frame { self = TilesetPlayer(restart: self) }
        while frame < n {
            frame += 1
            cycler.tick(&cgram)
            if frame % 2 == 0 { animator.upload() }
        }
    }

    init(restart p: TilesetPlayer) {
        cycler = PaletteCycler(p.cycler.cycles)
        animator = TileAnimator(p.animator.animations)
        baseCGRAM = p.baseCGRAM
        cgram = p.baseCGRAM
    }
}
