// CTNPCSprites.swift — the field's NPC sprites: RomE4_SprRec ($E4:F000)
// records 7-255 as event opcode $82 (Evt_Op82_InitWramSprite) loads them,
// their import into a project, the event packs and locations that load each
// one, and the field's animation clock (Obj_AnimTickAndQueue).
//
// The twin of re_workspace/tools/ct_npc_sprites.py, which holds the evidence
// (ChronoRET's readers, the ROM's code bytes, the data invariants, and runs
// of the field's loader, frame builders, frame lookup and tick in the 65816
// interpreter) and writes the synthetic vectors this file is tested against.
// docs/sprites.md ("NPC sprites") describes the format.
import Foundation

public enum CTNPCSpriteROM {
    public static let family = "ct-npc"
    public static let firstNPC = 7                      // SprRec_FirstNpc: record of opcode $82's operand 0
    public static let opcode: UInt8 = 0x82
    /// The field's size classes: Obj_BuildFrame4 and Obj_BuildFrame8 (columns, rows, record bytes, OBJs).
    public static let layouts: [Int: (columns: Int, rows: Int, recordBytes: Int, objs: Int)] =
        [0: (8, 2, 40, 4), 1: (16, 2, 80, 8)]
    /// Obj_TileSlotAllocKind's first slot in an empty field: class 0 slot $19, class 1 the pair at $0C.
    public static func slotTile(size: Int) -> Int { size == 0 ? tile(slot: 0x19) : tile(slot: 0x0C) }
    /// OBJ tile of tile slot n: (n & $FE) x 16 + (n & 1) x 8.
    public static func tile(slot n: Int) -> Int { (n & 0xFE) * 16 + (n & 1) * 8 }
    /// Evt_PackPtrs entries that are not event data (event_pack_verification.json).
    static let nonEventEntries: Set<Int> = [0, 102, 103, 104, 105, 106, 107, 108, 109, 110, 231, 232, 233, 234, 235, 320, 321, 322]

    public static func id(_ r: Int) -> String { String(format: "npc_%03d", r) }

    public struct Record: Equatable, Sendable {
        public var gfx, frames, palette, anim, size, sizeByte: Int
    }

    public static func record(_ rom: [UInt8], _ r: Int) -> Record {
        let at = CTSpriteROM.pc(CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * r)
        let b = (0..<CTSpriteROM.sprRecBytes).map { Int(rom[at + $0]) }
        return Record(gfx: b[0], frames: b[1], palette: b[2], anim: b[3], size: b[4] & 3, sizeByte: b[4])
    }

    /// Whether record r is all zeros (the empty records name set 0 only by being empty).
    public static func isEmpty(_ rom: [UInt8], _ r: Int) -> Bool {
        let at = CTSpriteROM.pc(CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * r)
        return rom[at..<(at + CTSpriteROM.sprRecBytes)].allSatisfy { $0 == 0 }
    }

    public struct DecodedNPC: Sendable {
        public var record: Int
        public var fields: Record
        public var layout: Int
        public var tilesAt: Int                         // the $E4:2000 pointer
        public var packedBytes: Int                     // the stream's size through its end marker
        public var mode: LZSSMode
        public var tiles: [[UInt8]]                     // unpacked 32-byte 4bpp tiles
        public var framesAt: Int
        public var frames: [CTSpriteROM.Frame]
        public var paletteAt: Int
        public var palette: [UInt16]
        public var frameIdsAt: Int
        public var durationsAt: Int
        public var stride: Int                          // frame ids per facing
        public var rows: Int                            // rows a list may start in: ceil(stride / 4)
        public var animations: [SpriteDef.Animation]    // lists naming frames past the set left out
    }

    /// (stride, rows) of animation set a as the field reads it: the facing
    /// stride is (AnimFrames[a + 1] - AnimFrames[a]) / 4 (Evt_LoadSpriteRec).
    public static func animShape(_ rom: [UInt8], set a: Int) -> (stride: Int, rows: Int) {
        let gap = (CTSpriteROM.u16(rom, CTSpriteROM.animFrames + 2 * a + 2) - CTSpriteROM.u16(rom, CTSpriteROM.animFrames + 2 * a)) & 0xFFFF
        let stride = gap >> 2
        return (stride, (stride + 3) / 4)
    }

    /// Every non-empty (row, facing) list with the field's stride: entries
    /// until a zero duration or a $FF frame id, never past the facing's last.
    /// A list the $FF marker ends keeps that entry's duration (markerDuration).
    public static func decodeAnimations(_ rom: [UInt8], set a: Int) -> [SpriteDef.Animation] {
        let (stride, rows) = animShape(rom, set: a)
        let idsAt = CTSpriteROM.animBank + CTSpriteROM.u16(rom, CTSpriteROM.animFrames + 2 * a)
        let dursAt = CTSpriteROM.animBank + CTSpriteROM.u16(rom, CTSpriteROM.animDurs + 2 * a)
        var out: [SpriteDef.Animation] = []
        for r in 0..<rows {
            for f in 0..<4 {
                var ids: [Int] = [], durs: [Int] = []
                var e = 4 * r
                while e < stride {
                    let d = CTSpriteROM.u8(rom, dursAt + e), i = CTSpriteROM.u8(rom, idsAt + f * stride + e)
                    if d == 0 || i == CTSpriteROM.endMarker { break }
                    ids.append(i)
                    durs.append(d)
                    e += 1
                }
                guard !ids.isEmpty else { continue }
                var anim = SpriteDef.Animation(id: String(format: "r%02d.%@", r, CTSpriteROM.facings[f]), frames: ids,
                                               durations: durs, loop: true, row: r, facing: f)
                if e < stride, CTSpriteROM.u8(rom, dursAt + e) != 0 { anim.markerDuration = CTSpriteROM.u8(rom, dursAt + e) }
                out.append(anim)
            }
        }
        return out
    }

    /// Whether the frame record at `at` is a frame of graphics with `tileCount` tiles.
    static func isFrame(_ rom: [UInt8], at: Int, cells: Int, tileCount: Int) -> Bool {
        for k in 0..<cells {
            let w = CTSpriteROM.u16(rom, at + 2 * k)
            if w & 0x3800 != 0 || w & CTSpriteROM.tileMask >= tileCount { return false }
        }
        return true
    }

    /// Records up to the next frame block in the bank (at most 256), less
    /// trailing all-zero records; a bank's last block (no next pointer) ends at
    /// its first record that is not a frame of the graphics.
    static func frameCount(_ rom: [UInt8], frameSet: Int, recordBytes: Int, cells: Int, tileCount: Int) -> Int {
        let start = CTSpriteROM.u24(rom, CTSpriteROM.framesPtr + 3 * frameSet)
        let end = CTSpriteROM.blockEnd(CTSpriteROM.framesPtr, start, rom)
        var n = max(0, min(CTSpriteROM.pointers, (end - start) / recordBytes))
        if end == (start | 0xFFFF) + 1 {
            var k = 0
            while k < n, isFrame(rom, at: start + recordBytes * k, cells: cells, tileCount: tileCount) { k += 1 }
            n = k
        }
        while n > 0, rom[CTSpriteROM.pc(start + recordBytes * (n - 1))..<CTSpriteROM.pc(start + recordBytes * n)].allSatisfy({ $0 == 0 }) {
            n -= 1
        }
        return n
    }

    /// Record `r` (7-255) of a headerless 4 MiB ROM image, as opcode $82 loads it.
    public static func decode(rom: [UInt8], record r: Int) throws -> DecodedNPC {
        precondition((firstNPC..<CTSpriteROM.pointers).contains(r) && rom.count == CTROMBuilder.romSize)
        let rec = record(rom, r)
        guard let shape = layouts[rec.size] else {
            throw CTROMBuildError("NPC record \(r): size class \(rec.size) has no field builder this import reads (0 and 1)")
        }
        let tilesAt = CTSpriteROM.u24(rom, CTSpriteROM.tilesPtr + 3 * rec.gfx)
        let start = CTSpriteROM.pc(tilesAt)
        guard start < rom.count else {
            throw CTROMBuildError(String(format: "NPC record %d: graphics pointer %@ is outside the ROM", r, CTSpriteROM.snes(tilesAt)))
        }
        let data: [UInt8], mode: LZSSMode, packedBytes: Int
        do { (data, mode, packedBytes) = try LZSS.decompressStream(Array(rom[start..<min(rom.count, start + 0x10000)])) }
        catch { throw CTROMBuildError(String(format: "NPC record %d: graphics at %@ do not unpack: %@", r, CTSpriteROM.snes(tilesAt), "\(error)")) }
        guard data.count % CTSpriteROM.tileBytes == 0 else {
            throw CTROMBuildError("NPC record \(r): graphics \(rec.gfx) unpack to \(data.count) bytes, not whole tiles")
        }
        let tiles = data.chunked(CTSpriteROM.tileBytes)
        let framesAt = CTSpriteROM.u24(rom, CTSpriteROM.framesPtr + 3 * rec.frames)
        let n = frameCount(rom, frameSet: rec.frames, recordBytes: shape.recordBytes, cells: shape.columns * shape.rows,
                           tileCount: tiles.count)
        var frames: [CTSpriteROM.Frame] = []
        for f in 0..<n {
            let at = CTSpriteROM.pc(framesAt + shape.recordBytes * f)
            frames.append(CTEnemySpriteROM.decodeFrame(Array(rom[at..<(at + shape.recordBytes)]), columns: shape.columns,
                                                       rows: shape.rows, objs: shape.objs))
        }
        let paletteAt = CTSpriteROM.animBank + rec.palette * CTSpriteROM.paletteBytes
        var palette: [UInt16] = []
        for k in 0..<CTSpriteROM.paletteColours { palette.append(UInt16(CTSpriteROM.u16(rom, paletteAt + 2 * k))) }
        let (stride, rows) = animShape(rom, set: rec.anim)
        let animations = decodeAnimations(rom, set: rec.anim).filter { $0.frames.allSatisfy { $0 < n } }
        return DecodedNPC(record: r, fields: rec, layout: rec.size, tilesAt: tilesAt, packedBytes: packedBytes, mode: mode,
                          tiles: tiles, framesAt: framesAt, frames: frames, paletteAt: paletteAt, palette: palette,
                          frameIdsAt: CTSpriteROM.animBank + CTSpriteROM.u16(rom, CTSpriteROM.animFrames + 2 * rec.anim),
                          durationsAt: CTSpriteROM.animBank + CTSpriteROM.u16(rom, CTSpriteROM.animDurs + 2 * rec.anim),
                          stride: stride, rows: rows, animations: animations)
    }

    // MARK: Who loads each record

    /// {record: Evt_PackPtrs entries} of every opcode $82 in the ROM's event packs.
    public static func loaders(rom: [UInt8]) throws -> [Int: [Int]] {
        var out: [Int: Set<Int>] = [:]
        var byAddress: [Int: [Int]] = [:]
        let entries = try CTEventROM.entries(rom: rom)
        for e in entries where !nonEventEntries.contains(e.index) { byAddress[e.snesAddress, default: []].append(e.index) }
        for (_, indices) in byAddress {
            guard let bytes = try? CTEventROM.unpack(rom: rom, entry: entries[indices[0]]), !bytes.isEmpty,
                  let pack = try? CTEventPack(bytes: bytes) else { continue }
            for (y, op) in pack.instructions where op.opcode == opcode && y + 2 < bytes.count {
                out[Int(bytes[y + 2]) + firstNPC, default: []].formUnion(indices)
            }
        }
        return out.mapValues { $0.sorted() }
    }

    /// {record: (packs, locations)}: the packs that load it and the locations whose LocRom .Events names one.
    public static func usage(rom: [UInt8]) throws -> [Int: SpriteDef.Field] {
        var byPack: [Int: [Int]] = [:]
        for i in 0..<CTMapROM.locCount { byPack[CTMapROM.header(rom, i).events, default: []].append(i) }
        var out: [Int: SpriteDef.Field] = [:]
        for (r, packs) in try loaders(rom: rom) {
            let locations = Set(packs.flatMap { byPack[$0] ?? [] }).sorted()
            out[r] = SpriteDef.Field(size: record(rom, r).sizeByte, packs: packs, locations: locations)
        }
        return out
    }

    // MARK: The project sprite

    /// A project sprite of the record: cell (r, c) streams to slot tile 16r + c
    /// at the first tile slot an empty field gives its class ($188 or $C0),
    /// and OBJ n (16x16) shows slot tile 2n.
    public static func spriteDef(_ d: DecodedNPC, id: String, field: SpriteDef.Field?) -> SpriteDef {
        let shape = layouts[d.layout]!
        var frames: [SpriteDef.Frame] = []
        for f in d.frames {
            var objs: [SpriteDef.OAMTile] = []
            for (n, p) in f.pieces.enumerated() {
                objs.append(SpriteDef.OAMTile(x: p.x, y: p.y, tile: 2 * n, pal: 0, size16: true, priority: CTSpriteROM.priority))
            }
            frames.append(SpriteDef.Frame(tiles: objs, cells: f.cells))
        }
        var source = SpriteDef.ROMSource(family: family, set: d.record, tiles: CTSpriteROM.snes(d.tilesAt), tileCount: d.tiles.count,
                                         frames: CTSpriteROM.snes(d.framesAt), frameCount: d.frames.count,
                                         palette: CTSpriteROM.snes(d.paletteAt), frameIds: CTSpriteROM.snes(d.frameIdsAt),
                                         durations: CTSpriteROM.snes(d.durationsAt), rows: d.rows)
        source.layout = d.layout
        source.packed = true
        source.packedBytes = d.packedBytes
        if d.stride != 4 * d.rows { source.stride = d.stride }
        let palette: [UInt16] = [0] + d.palette + [0, 0, 0]
        var s = SpriteDef(id: id, sheet: "sprites/\(id).png", bpp: 4, frames: frames, animations: d.animations,
                          palettes: [palette.map { BGR555(word: $0).hex }],
                          stream: .init(columns: shape.columns, rows: shape.rows, baseTile: slotTile(size: d.layout)), rom: source)
        s.field = field ?? SpriteDef.Field(size: d.fields.sizeByte, packs: [], locations: [])
        return s
    }

    /// The record's tiles as an indexed PNG, 16 per row.
    public static func sheet(_ d: DecodedNPC) -> IndexedPNG {
        let palette: [UInt16] = [0] + d.palette + [0, 0, 0]
        return SpriteSheet.png(tiles: TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4).chunked(64),
                               palette: palette.map { BGR555(word: $0) })
    }

    /// The NPC records into `project` as sprites/npc_NNN.*: every record the
    /// event packs load with opcode $82 (or `wanted`, any nonzero record
    /// 7-255). The PNG is written now, the JSON on the project's next save. A
    /// sprite already imported from the same record is replaced (frames keep
    /// their hitbox and weapon). Returns the ids.
    @discardableResult
    public static func importSprites(rom input: [UInt8], into project: inout CTProject, records wanted: [Int]? = nil) throws -> [String] {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("sprites import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        let uses = try usage(rom: rom)
        var out: [String] = []
        for r in wanted ?? uses.keys.sorted() {
            guard (firstNPC..<CTSpriteROM.pointers).contains(r), !isEmpty(rom, r) else {
                throw CTROMBuildError("NPC sprite \(r) is not a nonzero record 7-255")
            }
            let d = try decode(rom: rom, record: r)
            let key = project.sprites.first { $0.value.rom?.family == family && $0.value.rom?.set == r }?.key ?? id(r)
            var s = spriteDef(d, id: key, field: uses[r])
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
            out.append(key)
        }
        return out
    }

    // MARK: The field's animation clock

    /// Obj_AnimTickAndQueue and Obj_AnimFrameLookup for one object, as the
    /// field runs them once a frame: the timer counts down; at 0 the column
    /// steps on and the new entry's duration is the timer; a zero duration
    /// restarts the row (mode 2, counted loops: from 3 up the count drops by
    /// 2 and the row restarts, at 2 it drops to 1 and at 1 the last frame
    /// holds). A $FF frame id shows the row's first frame and sets the column
    /// to $FF, so the next step is column 0. A load or a new row starts at
    /// column 0 with the timer at 0.
    public struct FieldClock: Equatable, Sendable {
        public var ids: [Int]                           // the facing's frame ids from the row's first entry
        public var durations: [Int]                     // the shared durations from the row's first entry
        public var mode: Int
        public var loops: Int                           // ObjX_AnimLoops (mode 2)
        public var column = 0
        public var timer = 0

        public init(ids: [Int], durations: [Int], mode: Int = 0, loops: Int = 0) {
            self.ids = ids; self.durations = durations; self.mode = mode; self.loops = loops
        }

        /// A project list: its ids then the $FF marker (with its duration) or the zero duration that ends it.
        public init(animation a: SpriteDef.Animation, mode: Int = 0, loops: Int = 0) {
            let marker = a.markerDuration ?? 0
            self.init(ids: a.frames + [marker > 0 ? CTSpriteROM.endMarker : 0], durations: a.durations + [marker],
                      mode: mode, loops: loops)
        }

        public mutating func tick() {
            if timer != 0 {
                timer -= 1
                if timer != 0 { return }
            }
            column = (column + 1) & 0xFF
            let d = column < durations.count ? durations[column] : 0
            if d != 0 { timer = d; return }
            timer = durations.first ?? 0
            if mode == 2 {
                if loops == 1 { column = (column - 1) & 0xFF; return }
                if loops == 2 { loops = 1; column = (column - 1) & 0xFF; return }
                loops -= 2
            }
            column = 0
        }

        /// The frame id the builder shows now (and the column after the lookup).
        public mutating func frame() -> Int {
            let i = column < ids.count ? ids[column] : CTSpriteROM.endMarker
            if i == CTSpriteROM.endMarker {
                column = 0xFF
                return ids.first ?? 0
            }
            return i
        }
    }

    /// The step of `a` (an index into its frames) the field shows after `ticks`
    /// frames from a load: the first tick already steps on (the timer starts at
    /// 0), the $FF marker shows the first step again for its duration, and the
    /// list then repeats.
    public static func fieldStep(_ a: SpriteDef.Animation, at ticks: Int) -> Int {
        // Project JSON can reach the preview before validation. Invalid timing
        // holds the first step instead of producing a zero/negative cycle.
        let marker = a.markerDuration ?? 0
        guard !a.frames.isEmpty, a.durations.count == a.frames.count,
              a.durations.allSatisfy({ (1...255).contains($0) }),
              (0...255).contains(marker) else { return 0 }
        var clock = FieldClock(animation: a)
        // From the first tick on, the state repeats every cycle (the durations and the marker's).
        let cycle = a.durations.reduce(0, +) + marker
        let n = ticks <= 1 ? max(0, ticks) : 1 + (ticks - 1) % cycle
        for _ in 0..<n { clock.tick() }
        return clock.column >= a.frames.count ? 0 : clock.column
    }

    /// The step the Studio shows `ticks` frames into `a` of `s`: an NPC sprite
    /// runs the field's clock (`fieldStep`), any other sprite `SpriteEditing.step`.
    public static func playStep(_ s: SpriteDef, _ a: SpriteDef.Animation, at ticks: Int) -> Int {
        s.rom?.family == family ? fieldStep(a, at: ticks) : SpriteEditing.step(a, at: ticks)
    }
}
