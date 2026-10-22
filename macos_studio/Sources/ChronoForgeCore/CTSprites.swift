// CTSprites.swift — the playable characters' sprite sets (frames, tiles,
// animations, palettes) from the ROM, their import into a project, and the
// PPU scene that shows a sprite frame as the hardware would.
//
// The twin of re_workspace/tools/ct_sprites.py, which holds the evidence
// (ChronoRET's readers, the ROM's code bytes, the data invariants and a run of
// the ROM's own frame decoder) and writes the synthetic vectors this file is
// tested against. docs/sprites.md describes the format.
import Foundation

public enum CTSpriteROM {
    public static let sets = 7                         // the playable characters, by id
    public static let names = CTCharacterROM.names
    public static let tilesPtr = 0xE42000              // 3 B per set: long pointer to its 4bpp tiles
    public static let framesPtr = 0xE42300             // 3 B per set: long pointer to its frame records
    public static let animFrames = 0xE42600            // 2 B per set: bank-$E4 offset of its frame-id rows
    public static let animDurs = 0xE42800              // 2 B per set: bank-$E4 offset of its duration rows
    public static let pointers = 256                   // entries of each pointer table
    public static let sprRec = 0xE4F000                // 5 B per record: gfx, frames, palette, anim, size
    public static let sprRecBytes = 5
    public static let animBank = 0xE40000
    public static let paletteBytes = 0x18, paletteColours = 12
    public static let tileBytes = 32
    public static let frameBytes = 40                  // 16 tile words + 4 (x, y) signed byte pairs
    public static let columns = 8, rows = 2, pieces = 4
    public static let tileMask = 0x07FF, hflip = 0x4000
    public static let slotTile = 8                     // battle slot 0 and the field's leader
    public static let vramRow = 16                     // tiles per VRAM row: a 16x16 OBJ's lower half
    public static let priority = 2
    public static let endMarker = 0xFF                 // a frame id that ends the row (field)
    public static let facings = ["up", "down", "left", "right"]

    /// HiROM file offset of a 24-bit address.
    public static func pc(_ long: Int) -> Int { (long >> 16 & 0x3F) << 16 | long & 0xFFFF }

    public static func snes(_ long: Int) -> String { String(format: "$%02X:%04X", long >> 16, long & 0xFFFF) }

    public static func parseSNES(_ s: String) -> Int? {
        let parts = s.dropFirst(s.hasPrefix("$") ? 1 : 0).split(separator: ":")
        guard parts.count == 2, let bank = Int(parts[0], radix: 16), let low = Int(parts[1], radix: 16) else { return nil }
        return bank << 16 | low
    }

    public struct Frame: Equatable, Sendable {
        public var cells: [Int]                        // 16 tile words, row-major (8 x 2)
        public var pieces: [SpriteDef.Point]           // OBJ n's offset from the origin
    }

    public struct DecodedSet: Sendable {
        public var set: Int
        public var tilesAt: Int
        public var tiles: [[UInt8]]                    // raw 32-byte 4bpp tiles
        public var framesAt: Int
        public var frames: [Frame]
        public var paletteAt: Int
        public var palette: [UInt16]                   // colours 1-12
        public var frameIdsAt: Int
        public var durationsAt: Int
        public var rows: Int
        public var animations: [SpriteDef.Animation]
    }

    static func u8(_ rom: [UInt8], _ long: Int) -> Int { Int(rom[pc(long)]) }
    static func u16(_ rom: [UInt8], _ long: Int) -> Int { u8(rom, long) | u8(rom, long + 1) << 8 }
    static func u24(_ rom: [UInt8], _ long: Int) -> Int { u16(rom, long) | u8(rom, long + 2) << 16 }
    static func s8(_ v: Int) -> Int { v >= 0x80 ? v - 256 : v }

    /// Where the block at `start` ends: the next higher pointer of the table
    /// in the same bank, else the bank's end.
    static func blockEnd(_ table: Int, _ start: Int, _ rom: [UInt8]) -> Int {
        let bankEnd = (start | 0xFFFF) + 1
        var end = bankEnd
        for i in 0..<pointers {
            let p = u24(rom, table + 3 * i)
            if p > start && p < end { end = p }
        }
        return end
    }

    public static func tileCount(_ rom: [UInt8], set c: Int) -> Int {
        let start = u24(rom, tilesPtr + 3 * c)
        return (blockEnd(tilesPtr, start, rom) - start) / tileBytes
    }

    /// Records up to the next frame block (at most 256: a frame id is a
    /// byte), less trailing all-zero records.
    public static func frameCount(_ rom: [UInt8], set c: Int) -> Int {
        let start = u24(rom, framesPtr + 3 * c)
        var n = min(pointers, (blockEnd(framesPtr, start, rom) - start) / frameBytes)
        while n > 0, rom[pc(start + frameBytes * (n - 1))..<pc(start + frameBytes * n)].allSatisfy({ $0 == 0 }) {
            n -= 1
        }
        return n
    }

    public static func decodeFrame(_ rec: ArraySlice<UInt8>) -> Frame {
        let b = Array(rec)
        precondition(b.count == frameBytes)
        let cells = (0..<(columns * rows)).map { Int(b[2 * $0]) | Int(b[2 * $0 + 1]) << 8 }
        let pieces = (0..<pieces).map { SpriteDef.Point(x: s8(Int(b[32 + 2 * $0])), y: s8(Int(b[33 + 2 * $0]))) }
        return Frame(cells: cells, pieces: pieces)
    }

    /// Every non-empty (row, facing) list: entries until a zero duration or
    /// a $FF frame id, running on into the next row, never past the last.
    public static func decodeAnimations(_ rom: [UInt8], set c: Int) -> [SpriteDef.Animation] {
        let rows = (u16(rom, animFrames + 2 * c + 2) - u16(rom, animFrames + 2 * c)) / 16
        let framesAt = animBank + u16(rom, animFrames + 2 * c)
        let dursAt = animBank + u16(rom, animDurs + 2 * c)
        let stride = rows * 4
        var out: [SpriteDef.Animation] = []
        for r in 0..<max(rows, 0) {
            for f in 0..<4 {
                var ids: [Int] = [], durs: [Int] = []
                for e in (r * 4)..<stride {
                    let d = u8(rom, dursAt + e), i = u8(rom, framesAt + f * stride + e)
                    if d == 0 || i == endMarker { break }
                    ids.append(i)
                    durs.append(d)
                }
                if !ids.isEmpty {
                    out.append(SpriteDef.Animation(id: String(format: "r%02d.%@", r, facings[f]), frames: ids,
                                                   durations: durs, loop: true, row: r, facing: f))
                }
            }
        }
        return out
    }

    /// Set `c` of a headerless 4 MiB ROM image.
    public static func decode(rom: [UInt8], set c: Int) -> DecodedSet {
        precondition((0..<sets).contains(c) && rom.count == CTROMBuilder.romSize)
        let tilesAt = u24(rom, tilesPtr + 3 * c), framesAt = u24(rom, framesPtr + 3 * c)
        let tiles = (0..<tileCount(rom, set: c)).map {
            Array(rom[(pc(tilesAt) + tileBytes * $0)..<(pc(tilesAt) + tileBytes * ($0 + 1))])
        }
        let frames = (0..<frameCount(rom, set: c)).map {
            decodeFrame(rom[pc(framesAt + frameBytes * $0)..<pc(framesAt + frameBytes * ($0 + 1))])
        }
        let paletteAt = animBank + u8(rom, sprRec + sprRecBytes * c + 2) * paletteBytes
        let rows = (u16(rom, animFrames + 2 * c + 2) - u16(rom, animFrames + 2 * c)) / 16
        return DecodedSet(set: c, tilesAt: tilesAt, tiles: tiles, framesAt: framesAt, frames: frames,
                          paletteAt: paletteAt,
                          palette: (0..<paletteColours).map { UInt16(u16(rom, paletteAt + 2 * $0)) },
                          frameIdsAt: animBank + u16(rom, animFrames + 2 * c),
                          durationsAt: animBank + u16(rom, animDurs + 2 * c),
                          rows: rows, animations: decodeAnimations(rom, set: c))
    }

    /// The 16-entry OBJ palette of an import: 0, the 12 ROM colours, then 3
    /// zeros (the battle loads the weapon's colours there; not imported).
    public static func objPalette(_ d: DecodedSet) -> [UInt16] { [0] + d.palette + [0, 0, 0] }

    /// A project sprite of the set: the sheet holds its tiles 16 per row,
    /// each frame streams its 8 x 2 cells into a slot at OBJ tile 8, and
    /// OBJ n (16x16) shows slot tile 2n.
    public static func spriteDef(_ d: DecodedSet, id: String) -> SpriteDef {
        let frames = d.frames.map { f in
            SpriteDef.Frame(tiles: f.pieces.enumerated().map { n, p in
                SpriteDef.OAMTile(x: p.x, y: p.y, tile: 2 * n, pal: 0, size16: true, priority: priority)
            }, cells: f.cells)
        }
        let source = SpriteDef.ROMSource(family: "ct-pc", set: d.set, tiles: snes(d.tilesAt), tileCount: d.tiles.count,
                                         frames: snes(d.framesAt), frameCount: d.frames.count,
                                         palette: snes(d.paletteAt), frameIds: snes(d.frameIdsAt),
                                         durations: snes(d.durationsAt), rows: d.rows)
        return SpriteDef(id: id, sheet: "sprites/\(id).png", bpp: 4, frames: frames, animations: d.animations,
                         palettes: [objPalette(d).map { BGR555(word: $0).hex }],
                         stream: .init(columns: columns, rows: rows, baseTile: slotTile), rom: source)
    }

    /// The set's tiles as an indexed PNG, 16 per row.
    public static func sheet(_ d: DecodedSet) -> IndexedPNG {
        SpriteSheet.png(tiles: TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4).chunked(64),
                        palette: objPalette(d).map { BGR555(word: $0) })
    }

    /// The seven sets (or `sets`) into `project`: sprites/<id>.png is
    /// written now, the sprite JSON on the project's next save. A sprite
    /// whose `rom.set` matches is replaced (its frames' hitbox and weapon
    /// fields are kept); a character of that id without a sprite gets it.
    @discardableResult
    public static func importSprites(rom input: [UInt8], into project: inout CTProject,
                                     sets wanted: [Int] = Array(0..<7)) throws -> [String] {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("sprites import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        var ids: [String] = []
        for c in wanted {
            guard (0..<sets).contains(c) else { throw CTROMBuildError("sprite set \(c) is not 0-6") }
            let d = decode(rom: rom, set: c)
            let id = project.sprites.first { $0.value.rom?.family == "ct-pc" && $0.value.rom?.set == c }?.key ?? names[c]
            var s = spriteDef(d, id: id)
            if let old = project.sprites[id] {
                for i in s.frames.indices where i < old.frames.count {
                    s.frames[i].hitbox = old.frames[i].hitbox
                    s.frames[i].weapon = old.frames[i].weapon
                }
            }
            let url = project.fileURL(relative: s.sheet)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PNG.writeIndexed(sheet(d)).write(to: url, options: .atomic)
            project.sprites[id] = s
            let owner = project.characters.first { $0.value.pc?.charId == c }?.key ?? (project.characters[names[c]] != nil ? names[c] : nil)
            if let owner, project.characters[owner]?.sprite == nil { project.characters[owner]?.sprite = id }
            ids.append(id)
        }
        return ids
    }
}

// MARK: - Sheets

public enum SpriteSheet {
    public static let tilesPerRow = 16

    /// The sheet's 8x8 tiles, row-major, 64 indices each.
    public static func tiles(_ png: IndexedPNG) -> [[UInt8]] {
        let cols = png.width / 8, rows = png.height / 8
        return (0..<(cols * rows)).map { t in
            let tx = (t % cols) * 8, ty = (t / cols) * 8
            return (0..<64).map { png.indices[(ty + $0 / 8) * png.width + tx + $0 % 8] }
        }
    }

    /// Tiles (64 indices each) as a sheet `tilesPerRow` wide.
    public static func png(tiles: [[UInt8]], palette: [BGR555], bitDepth: Int = 4) -> IndexedPNG {
        let rows = max(1, (tiles.count + tilesPerRow - 1) / tilesPerRow)
        let width = tilesPerRow * 8, height = rows * 8
        var indices = [UInt8](repeating: 0, count: width * height)
        for (t, px) in tiles.enumerated() {
            let tx = (t % tilesPerRow) * 8, ty = (t / tilesPerRow) * 8
            for i in 0..<64 { indices[(ty + i / 8) * width + tx + i % 8] = px[i] }
        }
        return IndexedPNG(width: width, height: height, bitDepth: bitDepth, palette: palette, indices: indices)
    }

    /// Tile `t`'s 64 indices (zeros outside the sheet).
    public static func tile(_ png: IndexedPNG, _ t: Int) -> [UInt8] {
        let cols = png.width / 8
        guard cols > 0, t >= 0, t < cols * (png.height / 8) else { return [UInt8](repeating: 0, count: 64) }
        let tx = (t % cols) * 8, ty = (t / cols) * 8
        return (0..<64).map { png.indices[(ty + $0 / 8) * png.width + tx + $0 % 8] }
    }

    /// Replace tile `t`'s pixels in a sheet.
    public static func setTile(_ png: inout IndexedPNG, _ t: Int, _ px: [UInt8]) {
        let cols = png.width / 8
        let tx = (t % cols) * 8, ty = (t / cols) * 8
        for i in 0..<64 { png.indices[(ty + i / 8) * png.width + tx + i % 8] = px[i] }
    }

    public static func mirrored(_ px: [UInt8]) -> [UInt8] { (0..<64).map { px[$0 / 8 * 8 + 7 - $0 % 8] } }
}

// MARK: - The PPU scene

/// A sprite frame on a PPUFrame: OBSEL 0 (8x8 and 16x16 OBJs at VRAM word
/// 0), OBJ layer only, OBJ palettes from the sprite. A streamed frame's cells
/// go to its slot first, as the game's frame builders do.
public enum SpriteScene {
    public struct Options: Sendable {
        public var originX = 128, originY = 144
        public var backdrop: UInt16 = 0x2108
        public var onionFrame: Int?                    // drawn behind, dimmed, in OBJ palette 7
        public var height = 224
        public init() {}
    }

    /// The 8 OBJ palettes (16 words each): `palettes`, else the sheet's PLTE as palette 0.
    public static func palettes(_ s: SpriteDef, sheetPalette: [BGR555]) -> [[UInt16]] {
        var out = [[UInt16]](repeating: [UInt16](repeating: 0, count: 16), count: 8)
        if let pals = s.palettes {
            for (k, p) in pals.prefix(8).enumerated() {
                for (i, h) in p.prefix(16).enumerated() { out[k][i] = BGR555(hex: h)?.word ?? 0 }
            }
        } else {
            for (i, c) in sheetPalette.prefix(16).enumerated() { out[0][i] = c.word }
        }
        return out
    }

    /// The OBJ tiles frame `f` needs, OBJ tile number -> 64 indices.
    public static func objTiles(_ s: SpriteDef, frame f: Int, sheet: [[UInt8]], slotBase: Int? = nil) -> [Int: [UInt8]] {
        var out: [Int: [UInt8]] = [:]
        if let st = s.stream {
            let base = slotBase ?? st.baseTile
            let cells = s.frames[f].cells ?? []
            for r in 0..<st.rows {
                for c in 0..<st.columns {
                    let w = r * st.columns + c < cells.count ? cells[r * st.columns + c] : 0
                    let t = w & CTSpriteROM.tileMask
                    var px = t == 0 || t >= sheet.count ? [UInt8](repeating: 0, count: 64) : sheet[t]
                    if w & CTSpriteROM.hflip != 0 { px = SpriteSheet.mirrored(px) }
                    out[base + CTSpriteROM.vramRow * r + c] = px
                }
            }
        } else {
            for (k, px) in sheet.prefix(512).enumerated() { out[k] = px }
        }
        return out
    }

    /// OBJ tile number of an OAM entry: from the slot with `stream`.
    public static func objTile(_ s: SpriteDef, _ t: SpriteDef.OAMTile, slotBase: Int? = nil) -> Int {
        guard let st = s.stream else { return t.tile & 0x1FF }
        return ((slotBase ?? st.baseTile) + t.tile) & 0x1FF
    }

    /// Where the onion frame's slot goes: below the current one.
    public static func onionSlot(_ s: SpriteDef) -> Int? {
        guard let st = s.stream else { return nil }
        return (st.baseTile + CTSpriteROM.vramRow * st.rows) & 0x1FF
    }

    public static func frame(_ s: SpriteDef, frame f: Int, sheet: [[UInt8]], sheetPalette: [BGR555],
                             options o: Options = Options()) -> PPUFrame {
        var r = PPURegisters()
        r.obsel = 0
        r.tm = 0x10
        var p = PPUFrame(height: o.height, registers: r)
        p.cgram[0] = o.backdrop
        let pals = palettes(s, sheetPalette: sheetPalette)
        for k in 0..<8 { for i in 0..<16 { p.cgram[128 + 16 * k + i] = pals[k][i] } }
        var next = 0
        func place(_ index: Int, slot: Int?, palette: Int?) {
            guard s.frames.indices.contains(index) else { return }
            for (t, px) in objTiles(s, frame: index, sheet: sheet, slotBase: slot) {
                p.storeTiles(px, bpp: 4, atWord: PPUOBJEvaluator.tileAddress(t, obsel: r.obsel))
            }
            for t in s.frames[index].tiles where next < 128 {
                p.setOBJ(next, x: o.originX + t.x, y: (o.originY + t.y) & 0xFF, tile: objTile(s, t, slotBase: slot),
                         palette: palette ?? t.pal, priority: t.priority ?? CTSpriteROM.priority,
                         hflip: t.hflip, vflip: t.vflip, large: t.size16)
                next += 1
            }
        }
        place(f, slot: nil, palette: nil)
        if let onion = o.onionFrame, onion != f {
            let source = s.frames.indices.contains(f) ? s.frames[f].tiles.first?.pal ?? 0 : 0
            for i in 1..<16 { p.cgram[128 + 16 * 7 + i] = dim(pals[source][i], toward: o.backdrop) }
            place(onion, slot: onionSlot(s), palette: 7)
        }
        return p
    }

    /// Halfway from `c` to `backdrop`, per channel.
    static func dim(_ c: UInt16, toward backdrop: UInt16) -> UInt16 {
        var out: UInt16 = 0
        for shift: UInt16 in [0, 5, 10] {
            let a = c >> shift & 31, b = backdrop >> shift & 31
            out |= ((a + b) / 2) << shift
        }
        return out
    }

    /// The OBJ budget of a frame on the PPU: entries, distinct OBJ tiles
    /// (a 16x16 OBJ is 4), the slot's tiles when streamed, and the worst
    /// line against the 32-OBJ and 34-sliver limits.
    public struct Budget: Equatable, Sendable {
        public var objs: Int
        public var tiles: Int
        public var streamedTiles: Int
        public var maxOBJsOnALine: Int
        public var maxSliversOnALine: Int
        public var rangeOver: Bool
        public var timeOver: Bool
    }

    public static func budget(_ s: SpriteDef, frame f: Int, options o: Options = Options()) -> Budget {
        guard s.frames.indices.contains(f) else {
            return Budget(objs: 0, tiles: 0, streamedTiles: 0, maxOBJsOnALine: 0, maxSliversOnALine: 0,
                          rangeOver: false, timeOver: false)
        }
        var tiles = Set<Int>()
        for t in s.frames[f].tiles {
            let n = objTile(s, t)
            if t.size16 { [0, 1, 16, 17].forEach { tiles.insert((n + $0) & 0x1FF) } } else { tiles.insert(n) }
        }
        var single = Options()
        single.originX = o.originX; single.originY = o.originY; single.height = o.height
        let p = frame(s, frame: f, sheet: [], sheetPalette: [], options: single)
        var objs = 0, slivers = 0, range = false, time = false
        for line in 0..<p.height {
            let l = PPUOBJEvaluator.evaluate(oam: p.oam, registers: p.lines[line], line: line)
            slivers = max(slivers, l.slivers.count)
            range = range || l.rangeOver
            time = time || l.timeOver
            let onLine = Set(l.slivers.map { $0.order }).count
            objs = max(objs, onLine)
        }
        return Budget(objs: s.frames[f].tiles.count, tiles: tiles.count,
                      streamedTiles: s.stream.map { $0.columns * $0.rows } ?? 0,
                      maxOBJsOnALine: objs, maxSliversOnALine: slivers, rangeOver: range, timeOver: time)
    }

    /// The screen rectangle the frame's OBJs cover (x, y, w, h), clipped to the screen.
    public static func bounds(_ s: SpriteDef, frame f: Int, options o: Options = Options()) -> (x: Int, y: Int, w: Int, h: Int)? {
        guard s.frames.indices.contains(f), !s.frames[f].tiles.isEmpty else { return nil }
        var x0 = Int.max, y0 = Int.max, x1 = Int.min, y1 = Int.min
        for t in s.frames[f].tiles {
            let size = t.size16 ? 16 : 8
            x0 = min(x0, o.originX + t.x); y0 = min(y0, o.originY + t.y)
            x1 = max(x1, o.originX + t.x + size); y1 = max(y1, o.originY + t.y + size)
        }
        x0 = max(x0, 0); y0 = max(y0, 0); x1 = min(x1, 256); y1 = min(y1, o.height)
        return x1 > x0 && y1 > y0 ? (x0, y0, x1 - x0, y1 - y0) : nil
    }
}

// MARK: - Editing (the Studio's Sprites pane)

public enum SpriteEditing {
    /// The front OBJ (lowest OAM index) of frame `f` under screen point (x, y).
    public static func hit(_ s: SpriteDef, frame f: Int, x: Int, y: Int,
                           options o: SpriteScene.Options = SpriteScene.Options()) -> Int? {
        guard s.frames.indices.contains(f) else { return nil }
        return s.frames[f].tiles.firstIndex { t in
            let size = t.size16 ? 16 : 8
            let left = o.originX + t.x, top = o.originY + t.y
            return x >= left && x < left + size && y >= top && y < top + size
        }
    }

    /// The step shown `ticks` 60 Hz frames into an animation (a looping one
    /// wraps; otherwise it holds the last step).
    public static func step(_ a: SpriteDef.Animation, at ticks: Int) -> Int {
        let durations = a.durations.prefix(a.frames.count).map { max(1, $0) }
        guard !durations.isEmpty else { return 0 }
        let total = durations.reduce(0, +)
        var t = a.loop ? ticks % total : min(ticks, total - 1)
        for (i, d) in durations.enumerated() {
            if t < d { return i }
            t -= d
        }
        return durations.count - 1
    }

    /// Append a copy of frame `f`; returns the new frame's index.
    @discardableResult
    public static func duplicateFrame(_ s: inout SpriteDef, _ f: Int) -> Int {
        s.frames.append(s.frames[f])
        return s.frames.count - 1
    }

    /// Remove frame `f`: steps showing it go, higher frame ids move down by one.
    public static func deleteFrame(_ s: inout SpriteDef, _ f: Int) {
        guard s.frames.indices.contains(f) else { return }
        s.frames.remove(at: f)
        for i in s.animations.indices {
            var frames: [Int] = [], durations: [Int] = []
            for (k, id) in s.animations[i].frames.enumerated() where id != f {
                frames.append(id > f ? id - 1 : id)
                durations.append(k < s.animations[i].durations.count ? s.animations[i].durations[k] : 1)
            }
            s.animations[i].frames = frames
            s.animations[i].durations = durations
        }
    }

    /// Set one pixel of sheet tile `t` (x, y in 0-7).
    public static func paint(_ png: inout IndexedPNG, tile t: Int, x: Int, y: Int, index: UInt8) {
        let cols = png.width / 8
        guard (0..<8).contains(x), (0..<8).contains(y), t >= 0, t < cols * (png.height / 8) else { return }
        png.indices[((t / cols) * 8 + y) * png.width + (t % cols) * 8 + x] = index & UInt8((1 << png.bitDepth) - 1)
    }

    /// The sheet with `rows` more empty 16-tile rows (room for new tiles).
    public static func grow(_ png: IndexedPNG, rows: Int = 1) -> IndexedPNG {
        var out = png
        out.height += 8 * rows
        out.indices += [UInt8](repeating: 0, count: png.width * 8 * rows)
        return out
    }
}

extension Array {
    func chunked(_ n: Int) -> [[Element]] {
        stride(from: 0, to: count, by: n).map { Array(self[$0..<Swift.min($0 + n, count)]) }
    }
}
