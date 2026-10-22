// CTSpritePatch.swift — `rom.sprites` written back into a copy of the base
// ROM (docs/sprites.md, "Writing back"). A playable character's set keeps its
// place and shape: the 40-byte frame records in place, the sheet's tiles
// re-encoded with the planar encoder (only changed tiles, one write each),
// the frame-id and duration rows in place, and colours 1-12 of its palette.
// What the format cannot carry is refused before anything is written, and
// the result is decoded again (CTSpriteROM.decode) and must give the sprite
// back. Unchanged parts are not written, so an unedited import rebuilds the
// base ROM byte for byte.
import Foundation

public enum CTSpritePatch {
    public static let family = "ct-pc"

    /// One listed sprite with its sheet's tiles (64 indices each; sheet tile k = set tile k).
    public struct Request: Sendable {
        public var sprite: SpriteDef
        public var sheet: [[UInt8]]
        public init(sprite: SpriteDef, sheet: [[UInt8]]) { self.sprite = sprite; self.sheet = sheet }
    }

    public struct ReportFrame: Codable, Equatable, Sendable {
        public let cells: [Int]
        public let pieces: [[Int]]                // OBJ n's (x, y)
    }
    public struct ReportAnimation: Codable, Equatable, Sendable {
        public let row: Int
        public let facing: Int
        public let frames: [Int]
        public let durations: [Int]
    }
    /// What the set holds after the build; the ROM checker decodes the built ROM and compares.
    public struct ReportSprite: Codable, Equatable, Sendable {
        public let id: String
        public let family: String
        public let set: Int
        public let changed: [String]              // the parts written: frames, tiles, animations, palette
        public let tiles: String
        public let tileCount: Int
        public let tilesSHA256: String            // the tile block after the build
        public let changedTiles: [Int]
        public let frames: String
        public let frameCount: Int
        public let frameList: [ReportFrame]
        public let frameIds: String
        public let durations: String
        public let rows: Int
        public let animations: [ReportAnimation]
        public let palette: String
        public let colours: [Int]                 // colours 1-12
        public let sharedWith: [String]?          // other sprite records naming a changed part
    }

    // MARK: Checks without the ROM

    /// Problems the write-back would refuse, from the sprite alone (the build
    /// adds the base ROM's: addresses, counts and the re-decode).
    public static func validate(_ s: SpriteDef) -> [String] {
        guard let src = s.rom else { return ["no rom source: import the ROM's sprites"] }
        guard src.family == family else { return ["rom family \(src.family) is not \(family)"] }
        guard (0..<CTSpriteROM.sets).contains(src.set) else { return ["rom set \(src.set) is not 0-6"] }
        var problems: [String] = []
        if s.bpp != 4 { problems.append("bpp \(s.bpp): the set's tiles are 4bpp") }
        if s.stream != .init(columns: CTSpriteROM.columns, rows: CTSpriteROM.rows, baseTile: CTSpriteROM.slotTile) {
            problems.append("stream must be 8 x 2 cells at slot tile 8")
        }
        if s.frames.count != src.frameCount {
            problems.append("\(s.frames.count) frames: the set's block holds \(src.frameCount) (frames are written in place)")
        }
        for (i, f) in s.frames.enumerated() {
            problems += frameProblems(f, tileCount: src.tileCount).map { "frame \(i): \($0)" }
        }
        problems += paletteProblems(s)
        var seen = Set<[Int]>()
        for a in s.animations {
            guard let row = a.row, let facing = a.facing else {
                problems.append("animation \(a.id): no row and facing (the game's lists are by row and facing)")
                continue
            }
            if !(0..<src.rows).contains(row) || !(0..<4).contains(facing) {
                problems.append("animation \(a.id): row \(row) facing \(facing) is not in the set's \(src.rows) rows x 4 facings")
            }
            if !seen.insert([row, facing]).inserted { problems.append("animation \(a.id): row \(row) facing \(facing) twice") }
            if !a.loop { problems.append("animation \(a.id): the game's lists always loop") }
            if a.frames.isEmpty || a.frames.count != a.durations.count {
                problems.append("animation \(a.id): \(a.frames.count) frames and \(a.durations.count) durations")
            }
            for d in a.durations where !(1...255).contains(d) {
                problems.append("animation \(a.id): duration \(d) is not 1-255"); break
            }
            for id in a.frames where !(0..<min(src.frameCount, CTSpriteROM.endMarker)).contains(id) {
                problems.append("animation \(a.id): frame id \(id) is not below \(min(src.frameCount, CTSpriteROM.endMarker))"); break
            }
        }
        return problems
    }

    static func frameProblems(_ f: SpriteDef.Frame, tileCount: Int) -> [String] {
        var out: [String] = []
        let cells = f.cells ?? []
        if cells.count != CTSpriteROM.columns * CTSpriteROM.rows { out.append("\(cells.count) cells; a frame has 16") }
        for (k, w) in cells.enumerated() {
            let t = w & CTSpriteROM.tileMask
            if !(0...0xFFFF).contains(w) { out.append("cell \(k): \(w) is not a 16-bit word"); continue }
            if w & 0x3800 != 0 { out.append(String(format: "cell %d: bits 11-13 ($%04X) are not read by the game", k, w & 0x3800)) }
            if t >= tileCount { out.append("cell \(k): tile \(t) is not below the set's \(tileCount)") }
        }
        if f.tiles.count != CTSpriteROM.pieces { out.append("\(f.tiles.count) OBJs; a frame has 4 16x16 OBJs at slot tiles 0, 2, 4, 6") }
        for (n, t) in f.tiles.enumerated() {
            if !t.size16 || t.tile != 2 * n {
                out.append("OBJ \(n): must be 16x16 at slot tile \(2 * n) (the game places OBJ n at tile T + 2n)")
            }
            if t.hflip || t.vflip { out.append("OBJ \(n): the game's frames have no OAM flips (mirror cells instead)") }
            if t.pal != 0 { out.append("OBJ \(n): palette \(t.pal); the set has one palette (0)") }
            if let p = t.priority, p != CTSpriteROM.priority { out.append("OBJ \(n): priority \(p); the game sets it, not the frame") }
            if !(-128...127).contains(t.x) || !(-128...127).contains(t.y) {
                out.append("OBJ \(n): offset (\(t.x), \(t.y)) is not a signed byte pair")
            }
        }
        return out
    }

    static func paletteProblems(_ s: SpriteDef) -> [String] {
        guard let pals = s.palettes, pals.count == 1, pals[0].count == 16 else {
            return ["palettes: one OBJ palette of 16 colours (0, the set's 12, then the weapon's 3)"]
        }
        var out: [String] = []
        for (i, h) in pals[0].enumerated() {
            guard let c = BGR555(hex: h), c.word < 0x8000 else { out.append("palette colour \(i): \(h) is not BGR555"); continue }
            if (i == 0 || i > CTSpriteROM.paletteColours) && c.word != 0 {
                out.append("palette colour \(i): only colours 1-12 are the set's (0 is transparent, 13-15 the weapon's)")
            }
        }
        return out
    }

    // MARK: Writes

    public typealias Write = (pc: Int, bytes: [UInt8], what: String)

    static func encodeFrame(_ f: SpriteDef.Frame) -> [UInt8] {
        var out: [UInt8] = []
        for w in f.cells ?? [] { out += [UInt8(w & 0xFF), UInt8(w >> 8 & 0xFF)] }
        for t in f.tiles { out += [UInt8(t.x & 0xFF), UInt8(t.y & 0xFF)] }
        return out
    }

    /// The writes for `requests` over `base` (a 4 MiB image holding the
    /// bank-$E4 tables), only where a byte changes, and the report of each.
    /// Throws on anything the set cannot carry.
    public static func writes(_ requests: [Request], base: [UInt8]) throws -> (writes: [Write], report: [ReportSprite]) {
        var writes: [Write] = [], report: [ReportSprite] = []
        var seenSets = Set<Int>(), seenIDs = Set<String>()
        for r in requests {
            let s = r.sprite
            guard seenIDs.insert(s.id).inserted else { throw CTROMBuildError("sprite \(s.id) is built twice") }
            if let problem = validate(s).first { throw CTROMBuildError("sprite \(s.id): \(problem)") }
            let src = s.rom!, c = src.set
            guard seenSets.insert(c).inserted else { throw CTROMBuildError("sprite \(s.id): set \(c) is built twice") }
            let d = CTSpriteROM.decode(rom: base, set: c)
            let have = CTSpriteROM.spriteDef(d, id: s.id).rom!
            guard src == have else {
                throw CTROMBuildError("sprite \(s.id): its rom source is not where the base ROM has set \(c) " +
                                      "(tiles \(have.tiles) x \(have.tileCount), frames \(have.frames) x \(have.frameCount), " +
                                      "palette \(have.palette), \(have.rows) rows); re-import the sprites")
            }
            guard r.sheet.count >= d.tiles.count else {
                throw CTROMBuildError("sprite \(s.id): the sheet has \(r.sheet.count) tiles; the set has \(d.tiles.count)")
            }
            let name = "sprite \(s.id)"
            var mine: [Write] = []
            func put(_ long: Int, _ bytes: [UInt8], _ what: String) {
                let pc = CTSpriteROM.pc(long)
                if Array(base[pc..<(pc + bytes.count)]) != bytes { mine.append((pc, bytes, "\(name) \(what)")) }
            }
            var changed: [String] = [], changedTiles: [Int] = []
            // Tiles: tile 0 is the blank cell (the battle draws zeros for it whatever it holds).
            for t in 0..<d.tiles.count {
                let raw = TileDecoder.encodePlanar(r.sheet[t], depth: .bpp4)
                guard raw != d.tiles[t] else { continue }
                guard t != 0 else { throw CTROMBuildError("\(name): sheet tile 0 is the blank cell and must stay empty") }
                put(d.tilesAt + CTSpriteROM.tileBytes * t, raw, "tile \(t)")
                changedTiles.append(t)
            }
            if !changedTiles.isEmpty { changed.append("tiles") }
            let before = mine.count
            for (i, f) in s.frames.enumerated() { put(d.framesAt + CTSpriteROM.frameBytes * i, encodeFrame(f), "frame \(i)") }
            if mine.count > before { changed.append("frames") }
            // Animations: over the base rows, entry e of facing f at frameIds + f * stride + e, durations shared.
            let stride = 4 * d.rows, ids0 = CTSpriteROM.pc(d.frameIdsAt), durs0 = CTSpriteROM.pc(d.durationsAt)
            var ids = Array(base[ids0..<(ids0 + 4 * stride)]), durs = Array(base[durs0..<(durs0 + stride)])
            for a in s.animations {
                for (k, id) in a.frames.enumerated() where 4 * a.row! + k < stride {
                    ids[a.facing! * stride + 4 * a.row! + k] = UInt8(id)
                    durs[4 * a.row! + k] = UInt8(a.durations[k])
                }
            }
            let beforeAnims = mine.count
            for f in 0..<4 {
                for row in 0..<d.rows {
                    let at = f * stride + 4 * row
                    put(d.frameIdsAt + at, Array(ids[at..<(at + 4)]), String(format: "frame ids r%02d.%@", row, CTSpriteROM.facings[f]))
                }
            }
            for row in 0..<d.rows { put(d.durationsAt + 4 * row, Array(durs[(4 * row)..<(4 * row + 4)]), String(format: "durations r%02d", row)) }
            if mine.count > beforeAnims { changed.append("animations") }
            let colours = s.palettes![0][1...CTSpriteROM.paletteColours].map { Int(BGR555(hex: $0)!.word) }
            let beforePal = mine.count
            put(d.paletteAt, colours.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }, "palette")
            if mine.count > beforePal { changed.append("palette") }

            // The set decoded from the result must give the sprite back.
            var out = base
            for w in mine { out.replaceSubrange(w.pc..<(w.pc + w.bytes.count), with: w.bytes) }
            let e = CTSpriteROM.decode(rom: out, set: c)
            guard e.tiles.count == d.tiles.count, e.frames.count == s.frames.count else {
                throw CTROMBuildError("\(name): the edit changes the set's block ends (an all-zero last frame is trimmed)")
            }
            for (i, f) in s.frames.enumerated() {
                let pieces: [SpriteDef.Point] = f.tiles.map { SpriteDef.Point(x: $0.x, y: $0.y) }
                let cells: [Int] = f.cells ?? []
                if e.frames[i].cells != cells || e.frames[i].pieces != pieces {
                    throw CTROMBuildError("\(name): frame \(i) does not decode back")
                }
            }
            let want = s.animations.map { ReportAnimation(row: $0.row!, facing: $0.facing!, frames: $0.frames, durations: $0.durations) }
                .sorted { ($0.row, $0.facing) < ($1.row, $1.facing) }
            let got = e.animations.map { ReportAnimation(row: $0.row!, facing: $0.facing!, frames: $0.frames, durations: $0.durations) }
            if got != want {
                let bad = zip(got, want).first { $0 != $1 }
                let which = bad.map { String(format: "r%02d.%@", $0.1.row, CTSpriteROM.facings[$0.1.facing]) }
                    ?? "\(want.count) animations where the rows hold \(got.count)"
                throw CTROMBuildError("\(name): animation \(which) would not read back as given; a list keeps its row's " +
                                      "length and terminator, and the 4 facings of a row share its durations")
            }
            writes += mine
            report.append(ReportSprite(
                id: s.id, family: family, set: c, changed: changed, tiles: src.tiles, tileCount: d.tiles.count,
                tilesSHA256: CTEventPack.sha256(e.tiles.flatMap { $0 }), changedTiles: changedTiles,
                frames: src.frames, frameCount: e.frames.count,
                frameList: e.frames.map { ReportFrame(cells: $0.cells, pieces: $0.pieces.map { [$0.x, $0.y] }) },
                frameIds: src.frameIds, durations: src.durations, rows: d.rows, animations: got,
                palette: src.palette, colours: e.palette.map(Int.init), sharedWith: sharers(base, set: c, parts: changed)))
        }
        return (writes, report)
    }

    /// The other sprite records (RomE4_SprRec $E4:F000, 5 B; $E4:F600, 10 B,
    /// whose first five bytes are laid out the same way) that name set `c`'s
    /// changed parts: they show the edit too. All-zero records are left out
    /// (they name set 0 only by being empty).
    static func sharers(_ rom: [UInt8], set c: Int, parts: [String]) -> [String]? {
        let fields: [(part: String, offset: Int)] = [("tiles", 0), ("frames", 1), ("palette", 2), ("animations", 3)]
        var out: [String] = []
        for (table, size, first) in [(CTSpriteROM.sprRec, CTSpriteROM.sprRecBytes, CTSpriteROM.sets), (0xE4F600, 10, 0)] {
            for i in first..<CTSpriteROM.pointers {
                let at = CTSpriteROM.pc(table + size * i)
                if rom[at..<(at + CTSpriteROM.sprRecBytes)].allSatisfy({ $0 == 0 }) { continue }
                let hits = fields.filter { parts.contains($0.part) && CTSpriteROM.u8(rom, table + size * i + $0.offset) == c }
                if !hits.isEmpty { out.append("\(CTSpriteROM.snes(table)) record \(i): \(hits.map(\.part).joined(separator: ", "))") }
            }
        }
        return out.isEmpty ? nil : out
    }
}
