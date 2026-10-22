// CTEnemySprites.swift — the enemies' battle sprites (RomE4_EnemySprRec
// $E4:F600, 10 bytes per record): graphics, frames in frame layouts 0-2,
// palettes and animations, and their import into a project.
//
// The twin of the enemy section of re_workspace/tools/ct_sprites.py, which
// holds the evidence (the field's Evt_Op83_InitEnemySprite and FieldBtl_SaveObj,
// the battle's Battle_InitScene, Battle_InitSceneGfx and frame decoder, the
// ROM's code bytes, the data invariants and runs of the ROM's Decomp_ToWram and
// frame decoder) and writes the synthetic vectors this file is tested against.
// docs/sprites.md ("Enemy sprites") describes the format.
import Foundation

public enum CTEnemySpriteROM {
    public static let family = "ct-enemy"
    public static let records = 0xE4F600, recordBytes = 10
    public static let ids = 255                         // 0-254 ($FF is no enemy)
    public static let romGfxMin = 0xF8                  // records from here use ROM graphics as they are
    public static let slotTile = 0x40                   // battle slot 3's first OBJ tile
    /// Frame layouts 0-2 (the size class): cells wide x high, record bytes, OBJs.
    /// Layout 3 (96 x 1, 24 OBJs) has no OBJ assembly the battle's tables give.
    public static let layouts: [(columns: Int, rows: Int, recordBytes: Int, objs: Int)] =
        [(8, 2, 40, 4), (16, 2, 80, 8), (8, 6, 120, 12), (96, 1, 240, 24)]
    public static let assembled = 0..<3

    public static func id(_ i: Int) -> String { String(format: "enemy_%03d", i) }

    public struct Record: Equatable, Sendable {
        public var gfx, frames, palette, anim, size, flags: Int
        public var screenOffsetX, screenOffsetY, halfWidth, height, moveSpeed, moveDelay: Int
    }

    public static func record(_ rom: [UInt8], _ i: Int) -> Record {
        let at = CTSpriteROM.pc(records + recordBytes * i)
        let b = (0..<recordBytes).map { Int(rom[at + $0]) }
        return Record(gfx: b[0], frames: b[1], palette: b[2], anim: b[3], size: b[4] & 3, flags: b[4] & 0xFC,
                      screenOffsetX: b[5], screenOffsetY: b[6], halfWidth: b[7], height: b[8],
                      moveSpeed: b[9] & 7, moveDelay: b[9] >> 4)
    }

    /// Cells of OBJ n (16x16) in a frame `columns` wide: OBJs run along row
    /// pairs, columns / 2 per pair (top-left, top-right, bottom-left, bottom-right).
    public static func pieceCells(_ n: Int, columns: Int) -> [Int] {
        let p = n / (columns / 2), q = n % (columns / 2)
        let top = 2 * p * columns + 2 * q, bottom = (2 * p + 1) * columns + 2 * q
        return [top, top + 1, bottom, bottom + 1]
    }

    public struct DecodedEnemy: Sendable {
        public var id: Int
        public var record: Record
        public var layout: Int
        public var tilesAt: Int                         // the $E4:2000 pointer
        public var packed: Bool                         // unpacked (Decomp_ToWram) rather than raw ROM tiles
        public var tiles: [[UInt8]]
        public var framesAt: Int
        public var frames: [CTSpriteROM.Frame]
        public var paletteAt: Int
        public var palette: [UInt16]
        public var frameIdsAt: Int
        public var durationsAt: Int
        public var rows: Int
        public var animations: [SpriteDef.Animation]
    }

    /// Record `i` of a headerless 4 MiB ROM image.
    public static func decode(rom: [UInt8], id i: Int) throws -> DecodedEnemy {
        precondition((0..<CTSpriteROM.pointers).contains(i) && rom.count == CTROMBuilder.romSize)
        let r = record(rom, i)
        let shape = layouts[r.size]
        let tilesAt = CTSpriteROM.u24(rom, CTSpriteROM.tilesPtr + 3 * r.gfx)
        var tiles: [[UInt8]]
        let packed = i < romGfxMin
        if packed {
            let start = CTSpriteROM.pc(tilesAt)
            guard start < rom.count else { throw CTROMBuildError(String(format: "enemy %d: graphics pointer %@ is outside the ROM", i, CTSpriteROM.snes(tilesAt))) }
            let src = Array(rom[start..<min(rom.count, start + 0x10000)])
            let data: [UInt8]
            do { data = try LZSS.decompressStream(src).out }
            catch { throw CTROMBuildError(String(format: "enemy %d: graphics at %@ do not unpack: %@", i, CTSpriteROM.snes(tilesAt), "\(error)")) }
            tiles = data.chunked(CTSpriteROM.tileBytes).filter { $0.count == CTSpriteROM.tileBytes }
        } else {
            let n = CTSpriteROM.tileCount(rom, set: r.gfx)
            guard CTSpriteROM.pc(tilesAt) + 32 * n <= rom.count else {
                throw CTROMBuildError(String(format: "enemy %d: tiles at %@ run past the ROM", i, CTSpriteROM.snes(tilesAt)))
            }
            let base: Int = CTSpriteROM.pc(tilesAt)
            var list: [[UInt8]] = []
            for t in 0..<n {
                let at: Int = base + 32 * t
                list.append(Array(rom[at..<(at + 32)]))
            }
            tiles = list
        }
        let framesAt = CTSpriteROM.u24(rom, CTSpriteROM.framesPtr + 3 * r.frames)
        let n = frameCount(rom, frameSet: r.frames, recordBytes: shape.recordBytes)
        var frames: [CTSpriteROM.Frame] = []
        for f in 0..<n {
            let at = CTSpriteROM.pc(framesAt + shape.recordBytes * f)
            guard at + shape.recordBytes <= rom.count else {
                throw CTROMBuildError(String(format: "enemy %d: frame %d runs past the ROM", i, f))
            }
            frames.append(decodeFrame(Array(rom[at..<(at + shape.recordBytes)]), columns: shape.columns, rows: shape.rows, objs: shape.objs))
        }
        let paletteAt = CTSpriteROM.animBank + r.palette * CTSpriteROM.paletteBytes
        var palette: [UInt16] = []
        for k in 0..<CTSpriteROM.paletteColours { palette.append(UInt16(CTSpriteROM.u16(rom, paletteAt + 2 * k))) }
        let rowsA = CTSpriteROM.u16(rom, CTSpriteROM.animFrames + 2 * r.anim)
        let rowsB = CTSpriteROM.u16(rom, CTSpriteROM.animFrames + 2 * r.anim + 2)
        return DecodedEnemy(id: i, record: r, layout: r.size, tilesAt: tilesAt, packed: packed, tiles: tiles,
                            framesAt: framesAt, frames: frames, paletteAt: paletteAt, palette: palette,
                            frameIdsAt: CTSpriteROM.animBank + rowsA,
                            durationsAt: CTSpriteROM.animBank + CTSpriteROM.u16(rom, CTSpriteROM.animDurs + 2 * r.anim),
                            rows: (rowsB - rowsA) / 16, animations: CTSpriteROM.decodeAnimations(rom, set: r.anim))
    }

    static func decodeFrame(_ b: [UInt8], columns: Int, rows: Int, objs: Int) -> CTSpriteROM.Frame {
        var cells: [Int] = []
        for k in 0..<(columns * rows) { cells.append(Int(b[2 * k]) | Int(b[2 * k + 1]) << 8) }
        let at = 2 * columns * rows
        var pieces: [SpriteDef.Point] = []
        for n in 0..<objs {
            pieces.append(SpriteDef.Point(x: CTSpriteROM.s8(Int(b[at + 2 * n])), y: CTSpriteROM.s8(Int(b[at + 2 * n + 1]))))
        }
        return CTSpriteROM.Frame(cells: cells, pieces: pieces)
    }

    /// Records up to the next frame block (the PC rule with the layout's record size).
    static func frameCount(_ rom: [UInt8], frameSet: Int, recordBytes: Int) -> Int {
        let start = CTSpriteROM.u24(rom, CTSpriteROM.framesPtr + 3 * frameSet)
        var n = max(0, min(CTSpriteROM.pointers, (CTSpriteROM.blockEnd(CTSpriteROM.framesPtr, start, rom) - start) / recordBytes))
        while n > 0, rom[CTSpriteROM.pc(start + recordBytes * (n - 1))..<CTSpriteROM.pc(start + recordBytes * n)].allSatisfy({ $0 == 0 }) {
            n -= 1
        }
        return n
    }

    /// A project sprite of the record: cell (r, c) streams to slot tile 16r + c
    /// at OBJ tile $40, and OBJ n (16x16) of pair p, column q shows slot tile
    /// 32p + 2q. Animations naming a frame past the block are left out.
    public static func spriteDef(_ d: DecodedEnemy, id: String) -> SpriteDef {
        let shape = layouts[d.layout]
        var frames: [SpriteDef.Frame] = []
        for f in d.frames {
            var objs: [SpriteDef.OAMTile] = []
            for (n, p) in f.pieces.enumerated() {
                let pair = n / (shape.columns / 2), q = n % (shape.columns / 2)
                objs.append(SpriteDef.OAMTile(x: p.x, y: p.y, tile: 32 * pair + 2 * q, pal: 0, size16: true,
                                              priority: CTSpriteROM.priority))
            }
            frames.append(SpriteDef.Frame(tiles: objs, cells: f.cells))
        }
        let animations = d.animations.filter { $0.frames.allSatisfy { $0 < d.frames.count } }
        var source = SpriteDef.ROMSource(family: family, set: d.id, tiles: CTSpriteROM.snes(d.tilesAt), tileCount: d.tiles.count,
                                         frames: CTSpriteROM.snes(d.framesAt), frameCount: d.frames.count,
                                         palette: CTSpriteROM.snes(d.paletteAt), frameIds: CTSpriteROM.snes(d.frameIdsAt),
                                         durations: CTSpriteROM.snes(d.durationsAt), rows: d.rows)
        source.layout = d.layout
        source.packed = d.packed
        let palette: [UInt16] = [0] + d.palette + [0, 0, 0]
        return SpriteDef(id: id, sheet: "sprites/\(id).png", bpp: 4, frames: frames, animations: animations,
                         palettes: [palette.map { BGR555(word: $0).hex }],
                         stream: .init(columns: shape.columns, rows: shape.rows, baseTile: slotTile), rom: source)
    }

    /// The record's tiles as an indexed PNG, 16 per row.
    public static func sheet(_ d: DecodedEnemy) -> IndexedPNG {
        let palette: [UInt16] = [0] + d.palette + [0, 0, 0]
        return SpriteSheet.png(tiles: TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4).chunked(64),
                               palette: palette.map { BGR555(word: $0) })
    }

    /// The enemies' sprites (records 0-254 in frame layouts 0-2, or `wanted`)
    /// into `project` as sprites/enemy_NNN.*: the PNG now, the JSON on the
    /// project's next save. A sprite already imported from the same record is
    /// replaced (frames keep their hitbox and weapon); an enemy character of
    /// that id without a sprite gets it. Returns the ids and the records left
    /// out (layout 3).
    @discardableResult
    public static func importSprites(rom input: [UInt8], into project: inout CTProject,
                                     ids wanted: [Int]? = nil) throws -> (ids: [String], skipped: [Int]) {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("sprites import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        var out: [String] = [], skipped: [Int] = []
        for i in wanted ?? Array(0..<ids) {
            guard (0..<ids).contains(i) else { throw CTROMBuildError("enemy sprite \(i) is not 0-254") }
            guard assembled.contains(record(rom, i).size) else { skipped.append(i); continue }
            let d = try decode(rom: rom, id: i)
            let key = project.sprites.first { $0.value.rom?.family == family && $0.value.rom?.set == i }?.key ?? id(i)
            var s = spriteDef(d, id: key)
            if let old = project.sprites[key] {
                for f in s.frames.indices where f < old.frames.count {
                    s.frames[f].hitbox = old.frames[f].hitbox
                    s.frames[f].weapon = old.frames[f].weapon
                }
            }
            let url = project.fileURL(relative: s.sheet)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PNG.writeIndexed(sheet(d)).write(to: url, options: .atomic)
            project.sprites[key] = s
            let owner = project.characters.first { $0.value.enemy?.enemyId == i }?.key
            if let owner, project.characters[owner]?.sprite == nil { project.characters[owner]?.sprite = key }
            out.append(key)
        }
        return (out, skipped)
    }

    /// The battle sprite of an enemy character: its `sprite`, else the
    /// imported sprite of its enemy id (the Enemies view's hook).
    public static func sprite(for c: CharacterDef, in project: CTProject) -> SpriteDef? {
        if let s = c.sprite, let def = project.sprites[s] { return def }
        guard let e = c.enemy?.enemyId else { return nil }
        return project.sprites.values.first { $0.rom?.family == family && $0.rom?.set == e }
    }

    /// The frame an enemy sprite shows at rest: the first step of its first
    /// animation, else frame 0.
    public static func restFrame(_ s: SpriteDef) -> Int {
        let f = s.animations.first?.frames.first ?? 0
        return s.frames.indices.contains(f) ? f : 0
    }
}
