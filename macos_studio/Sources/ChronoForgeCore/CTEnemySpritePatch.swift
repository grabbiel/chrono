// CTEnemySpritePatch.swift — `rom.sprites` entries of family ct-enemy
// written back into a copy of the base ROM (docs/sprites.md, "Enemy
// write-back"). An enemy sprite keeps its record's parts and their shapes:
// frame records, animation rows and colours 1-12 in place; an edited pack
// re-encoded with LZSS.compress (the packer that rebuilds all 96 enemy packs
// byte for byte) in place when it fits its old span, else in confirmed free
// space with its $E4:2000 pointer rewritten; and the record's battle fields
// (+4 to +9) where the battle reads them.
//
// Sharing: a changed part is written only when every record that names it is
// accounted for. A part of a playable character's set (tiles, frames and
// animations 0-6, and the PC palettes) belongs to that set: an enemy edit to
// it needs the set listed in rom.sprites with the same result (the PC
// write-back writes it). Any other part needs every enemy record and every
// NPC record ($E4:F000 7-255, as ct-npc sprites: CTNPCSpritePatch) naming it
// listed with the same edit; layout-3 enemies cannot be listed, so a part
// they share is refused with the sharers named.
//
// Everything is checked and the listed sprites are decoded again from the
// result before anything is written. Unchanged parts are not written, so an
// unedited import rebuilds the base ROM byte for byte.
import Foundation

public enum CTEnemySpritePatch {
    public static let family = CTEnemySpriteROM.family
    /// Record byte +4: bits 0-1 are the layout; Battle_InitScene tests $04, $08, $20 and $80;
    /// bits 4 and 6 have no reader and stay as the base ROM has them.
    public static let testedFlags = 0xAC, keptFlags = 0x50
    /// Record byte +9: bit 3 has no reader (speed is bits 0-2, delay bits 4-7) and stays.
    public static let keptMove = 0x08

    public struct ReportPack: Codable, Equatable, Sendable {
        public let graphics: Int                  // the $E4:2000 entry
        public let address: String                // the stream after the build
        public let pc: Int
        public let packedBytes: Int
        public let budget: Int                    // the base ROM's stream: written in place up to this
        public let unpackedBytes: Int
        public let unpackedSHA256: String
        public let placement: String              // original | free
        public let from: String                   // the base ROM's stream
    }

    /// What the record shows after the build; the ROM checker decodes the built ROM and compares.
    public struct ReportSprite: Codable, Equatable, Sendable {
        public let id: String
        public let family: String
        public let set: Int                       // the enemy record
        public let layout: Int
        public let packed: Bool
        public let changed: [String]              // tiles, frames, animations, palette, record
        public let graphics: Int
        public let tiles: String                  // the $E4:2000 pointer after the build
        public let tileCount: Int
        public let tilesSHA256: String            // the (unpacked) tiles after the build
        public let changedTiles: [Int]
        public let pack: ReportPack?              // the record's pack when this build wrote it
        public let frameSet: Int
        public let frames: String
        public let frameCount: Int
        public let recordBytes: Int
        public let frameList: [CTSpritePatch.ReportFrame]
        public let animationSet: Int
        public let frameIds: String
        public let durations: String
        public let rows: Int
        public let animations: [CTSpritePatch.ReportAnimation]
        public let paletteIndex: Int
        public let palette: String
        public let colours: [Int]                 // colours 1-12
        public let record: SpriteDef.Battle       // +4 to +9 after the build
        public let sharedWith: [String]?          // other records naming a changed part
    }

    /// OBJ n's slot tile in a frame `columns` wide (pair p, column q: 32p + 2q).
    public static func objTile(_ n: Int, columns: Int) -> Int {
        let half = columns / 2
        return 32 * (n / half) + 2 * (n % half)
    }

    // MARK: Checks without the ROM

    /// Problems the write-back would refuse, from the sprite alone (the build
    /// adds the base ROM's: addresses, counts, cells past the graphics, kept
    /// bits, sharers and the re-decode).
    public static func validate(_ s: SpriteDef) -> [String] {
        guard let src = s.rom else { return ["no rom source: import the ROM's sprites"] }
        guard src.family == family else { return ["rom family \(src.family) is not \(family)"] }
        guard (0..<CTEnemySpriteROM.ids).contains(src.set) else { return ["rom set \(src.set) is not an enemy record 0-254"] }
        let layout = src.layout ?? 0
        guard CTEnemySpriteROM.assembled.contains(layout) else {
            return ["layout \(layout): only frame layouts 0-2 have an OBJ assembly the battle's tables give " +
                    "(a layout-3 import is the field's view, read-only)"]
        }
        let shape = CTEnemySpriteROM.layouts[layout]
        var problems: [String] = []
        if s.bpp != 4 { problems.append("bpp \(s.bpp): the record's tiles are 4bpp") }
        if s.stream != .init(columns: shape.columns, rows: shape.rows, baseTile: CTEnemySpriteROM.slotTile) {
            problems.append("stream must be \(shape.columns) x \(shape.rows) cells at slot tile \(CTEnemySpriteROM.slotTile)")
        }
        if s.frames.count != src.frameCount {
            problems.append("\(s.frames.count) frames: the frame set holds \(src.frameCount) (frames are written in place)")
        }
        for (i, f) in s.frames.enumerated() {
            problems += frameProblems(f, columns: shape.columns, rows: shape.rows, objs: shape.objs).map { "frame \(i): \($0)" }
        }
        problems += paletteProblems(s)
        problems += CTSpritePatch.animationProblems(s.animations, rows: src.rows, frameCount: src.frameCount)
        if let b = s.battle { problems += battleProblems(b) }
        return problems
    }

    static func frameProblems(_ f: SpriteDef.Frame, columns: Int, rows: Int, objs: Int) -> [String] {
        var out: [String] = []
        let cells = f.cells ?? []
        if cells.count != columns * rows { out.append("\(cells.count) cells; a frame of this layout has \(columns * rows)") }
        for (k, w) in cells.enumerated() where !(0...0xFFFF).contains(w) { out.append("cell \(k): \(w) is not a 16-bit word") }
        if f.tiles.count != objs { out.append("\(f.tiles.count) OBJs; a frame of this layout has \(objs) 16x16 OBJs") }
        for (n, t) in f.tiles.enumerated() {
            let want = objTile(n, columns: columns)
            if !t.size16 || t.tile != want {
                out.append("OBJ \(n): must be 16x16 at slot tile \(want) (the battle's OBJ records place it there)")
            }
            if t.hflip || t.vflip { out.append("OBJ \(n): the game's frames have no OAM flips (mirror cells instead)") }
            if t.pal != 0 { out.append("OBJ \(n): palette \(t.pal); the record has one palette (0)") }
            if let p = t.priority, p != CTSpriteROM.priority { out.append("OBJ \(n): priority \(p); the game sets it, not the frame") }
            if !(-128...127).contains(t.x) || !(-128...127).contains(t.y) {
                out.append("OBJ \(n): offset (\(t.x), \(t.y)) is not a signed byte pair")
            }
        }
        return out
    }

    static func paletteProblems(_ s: SpriteDef) -> [String] {
        guard let pals = s.palettes, pals.count == 1, pals[0].count == 16 else {
            return ["palettes: one OBJ palette of 16 colours (0, the record's 12, then 3 zeros)"]
        }
        var out: [String] = []
        for (i, h) in pals[0].enumerated() {
            guard let c = BGR555(hex: h), c.word < 0x8000 else { out.append("palette colour \(i): \(h) is not BGR555"); continue }
            if (i == 0 || i > CTSpriteROM.paletteColours) && c.word != 0 {
                out.append("palette colour \(i): only colours 1-12 are the record's (0 is transparent)")
            }
        }
        return out
    }

    /// The ranges Battle_InitScene carries: whole bytes for +5 to +8, speed
    /// bits 0-2 and delay bits 4-7 of +9 (the move-interval table has 32
    /// rows: delay / 2 x 4 + speed / 2), flags in bits 2-7 of +4.
    public static func battleProblems(_ b: SpriteDef.Battle) -> [String] {
        var out: [String] = []
        if !(0...0xFC).contains(b.flags) || b.flags & 3 != 0 {
            out.append(String(format: "battle flags $%02X: bits 2-7 only (bits 0-1 are the frame layout)", b.flags & 0xFFFF))
        }
        let bytes: [(String, Int)] = [("screenOffsetX", b.screenOffsetX), ("screenOffsetY", b.screenOffsetY),
                                      ("halfWidth", b.halfWidth), ("height", b.height)]
        for (name, v) in bytes where !(0...255).contains(v) { out.append("battle \(name) \(v) is not 0-255") }
        if !(0...7).contains(b.moveSpeed) { out.append("battle moveSpeed \(b.moveSpeed) is not 0-7") }
        if !(0...15).contains(b.moveDelay) { out.append("battle moveDelay \(b.moveDelay) is not 0-15") }
        return out
    }

    // MARK: Without the ROM (Validator, Studio)

    /// The pack the sheet's first `tileCount` tiles make and the base ROM's
    /// pack size (the in-place budget), for a packed import (nil otherwise).
    public static func packBudget(_ s: SpriteDef, sheet: [[UInt8]]) -> (packed: Int, budget: Int)? {
        guard let src = s.rom, src.family == family || src.family == CTNPCSpritePatch.family, src.packed == true,
              let budget = src.packedBytes,
              sheet.count >= src.tileCount else { return nil }
        var data: [UInt8] = []
        for t in 0..<src.tileCount { data += TileDecoder.encodePlanar(sheet[t], depth: .bpp4) }
        guard let packed = LZSS.compress(data, mode: .lz12) else { return nil }
        return (packed.count, budget)
    }

    /// The project's other ROM sprites that show one of this sprite's parts
    /// (the same graphics, frame, palette or animation addresses), by id.
    public static func sharers(of s: SpriteDef, in sprites: [String: SpriteDef]) -> [(id: String, parts: [String])] {
        guard let src = s.rom else { return [] }
        var out: [(id: String, parts: [String])] = []
        for (id, other) in sprites.sorted(by: { $0.key < $1.key }) where id != s.id {
            guard let o = other.rom else { continue }
            var parts: [String] = []
            if o.tiles == src.tiles { parts.append("tiles") }
            if o.frames == src.frames { parts.append("frames") }
            if o.palette == src.palette { parts.append("palette") }
            if o.frameIds == src.frameIds { parts.append("animations") }
            if !parts.isEmpty { out.append((id, parts)) }
        }
        return out
    }

    // MARK: Parts and their users

    enum Part: Hashable, Comparable {
        case tiles(Int), frames(Int), palette(Int), animations(Int), record(Int)

        var name: String {
            switch self {
            case .tiles: return "tiles"
            case .frames: return "frames"
            case .palette: return "palette"
            case .animations: return "animations"
            case .record: return "record"
            }
        }
        var label: String {
            switch self {
            case .tiles(let g): return "graphics \(g)"
            case .frames(let f): return "frame set \(f)"
            case .palette(let p): return "palette \(p)"
            case .animations(let a): return "animation set \(a)"
            case .record(let i): return "record \(i)"
            }
        }
        /// The record byte that names the part (nil: the record itself).
        var field: (offset: Int, value: Int)? {
            switch self {
            case .tiles(let g): return (0, g)
            case .frames(let f): return (1, f)
            case .palette(let p): return (2, p)
            case .animations(let a): return (3, a)
            case .record: return nil
            }
        }
    }

    /// Records naming a field value: every enemy record 0-254 (each is an
    /// enemy id the battle shows) and the $E4:F000 records 7-255 (the NPCs'),
    /// all-zero NPC records left out (they name set 0 only by being empty).
    static func users(_ rom: [UInt8], offset: Int, value: Int) -> (enemies: [Int], others: [Int]) {
        var enemies: [Int] = [], others: [Int] = []
        for i in 0..<CTEnemySpriteROM.ids {
            let at = CTSpriteROM.pc(CTEnemySpriteROM.records + CTEnemySpriteROM.recordBytes * i)
            if Int(rom[at + offset]) == value { enemies.append(i) }
        }
        for i in CTSpriteROM.sets..<CTSpriteROM.pointers {
            let at = CTSpriteROM.pc(CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * i)
            if rom[at..<(at + CTSpriteROM.sprRecBytes)].allSatisfy({ $0 == 0 }) { continue }
            if Int(rom[at + offset]) == value { others.append(i) }
        }
        return (enemies, others)
    }

    /// The playable character's set a part belongs to: its tiles, frames and
    /// animations are entries 0-6, its palette the one its $E4:F000 record names.
    static func pcOwner(_ rom: [UInt8], _ part: Part) -> Int? {
        switch part {
        case .tiles(let n), .frames(let n), .animations(let n): return n < CTSpriteROM.sets ? n : nil
        case .palette(let p):
            return (0..<CTSpriteROM.sets).first { CTSpriteROM.u8(rom, CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * $0 + 2) == p }
        case .record: return nil
        }
    }

    /// Records whose $E4:2000 block is read as raw tiles, so its measured end
    /// (the next pointer in the bank) is its size: the PC sets and the graphics
    /// of enemy records $F8 and up. An NPC record's graphics are not: opcode $82
    /// always unpacks them, and the event packs use $81 (raw tiles) only for
    /// records 0-6 (ct_npc_sprites.py check).
    static func measuredEntries(_ rom: [UInt8]) -> [Int] {
        var out = Set(0..<CTSpriteROM.sets)
        for i in CTEnemySpriteROM.romGfxMin..<CTEnemySpriteROM.ids {
            out.insert(CTEnemySpriteROM.record(rom, i).gfx)
        }
        return out.sorted()
    }

    /// Tiles from entry g's pointer to the next higher pointer in its bank (CTSpriteROM.tileCount).
    static func measured(_ pointers: [Int], _ g: Int) -> Int {
        let start = pointers[g]
        var end = (start | 0xFFFF) + 1
        for p in pointers where p > start && p < end { end = p }
        return (end - start) / CTSpriteROM.tileBytes
    }

    // MARK: The build

    struct Want {
        var id: String
        var owner: Owner
        var content: [UInt8]
    }

    struct PartData {
        var slices: [(pc: Int, count: Int)] = []      // in the image; empty for a pack
        var unit = 1                                   // bytes per write
        var unitName: (Int) -> String = { "+\($0)" }
        var pack: (gfx: Int, pc: Int, budget: Int, mode: LZSSMode, current: [UInt8])?
        var wants: [Want] = []
    }

    /// The bytes of `slices` in `image`, in order.
    static func read(_ image: [UInt8], _ slices: [(pc: Int, count: Int)]) -> [UInt8] {
        var out: [UInt8] = []
        for s in slices { out += image[s.pc..<(s.pc + s.count)] }
        return out
    }

    static func encodeFrame(_ f: SpriteDef.Frame) -> [UInt8] { CTSpritePatch.encodeFrame(f) }

    static func sameLocation(_ a: SpriteDef.ROMSource, _ b: SpriteDef.ROMSource) -> Bool {
        a.family == b.family && a.set == b.set && a.tiles == b.tiles && a.tileCount == b.tileCount && a.frames == b.frames
            && a.frameCount == b.frameCount && a.palette == b.palette && a.frameIds == b.frameIds && a.durations == b.durations
            && a.rows == b.rows && (a.layout ?? 0) == (b.layout ?? 0) && (a.packed ?? false) == (b.packed ?? false)
            && a.stride == b.stride
    }

    static func sortedAnimations(_ list: [SpriteDef.Animation]) -> [CTSpritePatch.ReportAnimation] {
        list.map { CTSpritePatch.ReportAnimation(row: $0.row ?? 0, facing: $0.facing ?? 0, frames: $0.frames, durations: $0.durations) }
            .sorted { ($0.row, $0.facing) < ($1.row, $1.facing) }
    }

    /// The record a request writes: an enemy record of $E4:F600 or an NPC record of $E4:F000.
    enum Owner: Hashable, Comparable {
        case enemy(Int), npc(Int)

        var label: String {
            switch self {
            case .enemy(let i): return "enemy record \(i)"
            case .npc(let r): return "NPC record \(r)"
            }
        }
    }

    /// A request's record as the base ROM has it, in the terms both families share.
    struct Source {
        var owner: Owner
        var gfx: Int, frameSet: Int, palette: Int, anim: Int
        var packed: Bool
        var tilesAt: Int, packedBytes: Int
        var mode: LZSSMode
        var tiles: [[UInt8]]
        var framesAt: Int
        var frames: [CTSpriteROM.Frame]
        var recordBytes: Int
        var paletteAt: Int, frameIdsAt: Int, durationsAt: Int
        var stride: Int                                // frame ids per facing
        var rows: Int
    }

    static func source(_ d: CTEnemySpriteROM.DecodedEnemy) -> Source {
        Source(owner: .enemy(d.id), gfx: d.record.gfx, frameSet: d.record.frames, palette: d.record.palette, anim: d.record.anim,
               packed: d.packed, tilesAt: d.tilesAt, packedBytes: d.packedBytes, mode: d.mode, tiles: d.tiles,
               framesAt: d.framesAt, frames: d.frames, recordBytes: CTEnemySpriteROM.layouts[d.layout].recordBytes,
               paletteAt: d.paletteAt, frameIdsAt: d.frameIdsAt, durationsAt: d.durationsAt, stride: 4 * d.rows, rows: d.rows)
    }

    static func source(_ d: CTNPCSpriteROM.DecodedNPC) -> Source {
        Source(owner: .npc(d.record), gfx: d.fields.gfx, frameSet: d.fields.frames, palette: d.fields.palette, anim: d.fields.anim,
               packed: true, tilesAt: d.tilesAt, packedBytes: d.packedBytes, mode: d.mode, tiles: d.tiles,
               framesAt: d.framesAt, frames: d.frames, recordBytes: CTNPCSpriteROM.layouts[d.layout]!.recordBytes,
               paletteAt: d.paletteAt, frameIdsAt: d.frameIdsAt, durationsAt: d.durationsAt, stride: d.stride, rows: d.rows)
    }

    /// Writes `requests` (all ct-enemy) over `built` (the base ROM with the
    /// PC write-back applied; `base` is the unmodified ROM), placing relocated
    /// packs in `space`. `pcListed` maps the PC sets rom.sprites lists to their
    /// ids. Nothing is written unless every request decodes back.
    static func apply(_ requests: [CTSpritePatch.Request], base: [UInt8], built: [UInt8], pcListed: [Int: String],
                      space: inout FreeSpace, write: ([UInt8], Int, String) -> Void,
                      relocated: (String, Int?, Int, Int) -> Void) throws -> [ReportSprite] {
        try applyAll(requests, base: base, built: built, pcListed: pcListed, space: &space, write: write,
                     relocated: relocated).enemies
    }

    /// `apply` for ct-enemy and ct-npc requests together: one sharer pass over
    /// both families, so an NPC record listed with the same edit counts as a
    /// sharer of an enemy's part and the other way round.
    static func applyAll(_ requests: [CTSpritePatch.Request], base: [UInt8], built: [UInt8], pcListed: [Int: String],
                         space: inout FreeSpace, write: ([UInt8], Int, String) -> Void,
                         relocated: (String, Int?, Int, Int) -> Void) throws
        -> (enemies: [ReportSprite], npcs: [CTNPCSpritePatch.ReportSprite]) {
        guard !requests.isEmpty else { return ([], []) }
        var parts: [Part: PartData] = [:]
        var decoded: [Owner: Source] = [:]
        var tilesWanted: [Owner: [[UInt8]]] = [:]
        var byOwner: [Owner: String] = [:]
        var seenIDs = Set<String>()
        for r in requests {
            let s = r.sprite
            guard seenIDs.insert(s.id).inserted else { throw CTROMBuildError("sprite \(s.id) is built twice") }
            let npc = s.rom?.family == CTNPCSpriteROM.family
            if let problem = (npc ? CTNPCSpritePatch.validate(s) : validate(s)).first {
                throw CTROMBuildError("sprite \(s.id): \(problem)")
            }
            let src = s.rom!, i = src.set, name = "sprite \(s.id)"
            let owner: Owner = npc ? .npc(i) : .enemy(i)
            if let other = byOwner.updateValue(s.id, forKey: owner) {
                throw CTROMBuildError("\(name): \(owner.label) is also sprite \(other)")
            }
            let d: Source, have: SpriteDef.ROMSource
            var enemy: CTEnemySpriteROM.DecodedEnemy?
            if npc {
                let n = try CTNPCSpriteROM.decode(rom: base, record: i)
                d = source(n)
                have = CTNPCSpriteROM.spriteDef(n, id: s.id, field: nil).rom!
            } else {
                let e = try CTEnemySpriteROM.decode(rom: base, id: i)
                d = source(e)
                enemy = e
                have = CTEnemySpriteROM.spriteDef(e, id: s.id).rom!
            }
            guard sameLocation(src, have) else {
                throw CTROMBuildError("\(name): its rom source is not where the base ROM has \(owner.label) " +
                                      "(tiles \(have.tiles) x \(have.tileCount), frames \(have.frames) x \(have.frameCount), " +
                                      "palette \(have.palette), \(have.rows) rows, layout \(have.layout ?? 0)); re-import the sprites")
            }
            guard r.sheet.count >= d.tiles.count else {
                throw CTROMBuildError("\(name): the sheet has \(r.sheet.count) tiles; the record has \(d.tiles.count)")
            }
            decoded[owner] = d
            // Cells past the graphics or with bits 11-13 (not read by the game) only where the base ROM
            // has the same word (records 117 and 253 pair graphics with frame sets drawn for others).
            for (f, frame) in s.frames.enumerated() {
                for (k, w) in (frame.cells ?? []).enumerated() where w & CTSpriteROM.tileMask >= d.tiles.count || w & 0x3800 != 0 {
                    guard f < d.frames.count, k < d.frames[f].cells.count, d.frames[f].cells[k] == w else {
                        let why = w & 0x3800 != 0 ? String(format: "bits 11-13 ($%04X) are not read by the game", w & 0x3800)
                                                  : "tile \(w & CTSpriteROM.tileMask) is not below the record's \(d.tiles.count)"
                        throw CTROMBuildError("\(name): frame \(f) cell \(k): \(why)")
                    }
                }
            }
            var tiles: [[UInt8]] = []
            for t in 0..<d.tiles.count { tiles.append(TileDecoder.encodePlanar(r.sheet[t], depth: .bpp4)) }
            guard tiles.isEmpty || tiles[0] == d.tiles[0] else {
                let why = npc ? "the Studio draws cell word 0 blank" : "the battle draws zeros for it"
                throw CTROMBuildError("\(name): sheet tile 0 is the blank cell (\(why)) and must stay as imported")
            }
            tilesWanted[owner] = tiles
            if let e = enemy, let b = s.battle, b.flags & keptFlags != e.record.flags & keptFlags {
                throw CTROMBuildError(String(format: "%@: battle flags bits 4 and 6 have no reader and stay $%02X", name,
                                             e.record.flags & keptFlags))
            }

            // Tiles: the pack's unpacked bytes, or the raw block in place.
            let joined: [UInt8] = tiles.flatMap { $0 }
            let tilesPart = Part.tiles(d.gfx)
            if parts[tilesPart] == nil {
                var p = PartData()
                if d.packed {
                    p.pack = (d.gfx, CTSpriteROM.pc(d.tilesAt), d.packedBytes, d.mode, d.tiles.flatMap { $0 })
                } else {
                    p.slices = [(CTSpriteROM.pc(d.tilesAt), CTSpriteROM.tileBytes * d.tiles.count)]
                    p.unit = CTSpriteROM.tileBytes
                    p.unitName = { "tile \($0)" }
                }
                parts[tilesPart] = p
            }
            parts[tilesPart]!.wants.append(Want(id: s.id, owner: owner, content: joined))

            // Frames: the records in place.
            let framesPart = Part.frames(d.frameSet)
            var frameBytes: [UInt8] = []
            for f in s.frames { frameBytes += encodeFrame(f) }
            if parts[framesPart] == nil {
                var p = PartData()
                p.slices = [(CTSpriteROM.pc(d.framesAt), d.recordBytes * d.frames.count)]
                p.unit = d.recordBytes
                p.unitName = { "frame \($0)" }
                parts[framesPart] = p
            }
            parts[framesPart]!.wants.append(Want(id: s.id, owner: owner, content: frameBytes))

            // Animations: each list over the rows as built, as the PC write-back does
            // (entry e of facing f at frameIds + f * stride + e, the durations shared).
            let stride = d.stride, ids0 = CTSpriteROM.pc(d.frameIdsAt), durs0 = CTSpriteROM.pc(d.durationsAt)
            var ids = Array(built[ids0..<(ids0 + 4 * stride)]), durs = Array(built[durs0..<(durs0 + stride)])
            for a in s.animations {
                let row = a.row!, facing = a.facing!
                for (k, id) in a.frames.enumerated() where 4 * row + k < stride {
                    ids[facing * stride + 4 * row + k] = UInt8(id)
                    durs[4 * row + k] = UInt8(a.durations[k])
                }
            }
            let animPart = Part.animations(d.anim)
            if parts[animPart] == nil {
                var p = PartData()
                p.slices = [(ids0, 4 * stride), (durs0, stride)]
                p.unit = 4
                p.unitName = { u in
                    guard u < stride else { return String(format: "durations r%02d", u - stride) }
                    return String(format: "frame ids r%02d.%@", 4 * u % stride / 4, CTSpriteROM.facings[4 * u / stride])
                }
                parts[animPart] = p
            }
            parts[animPart]!.wants.append(Want(id: s.id, owner: owner, content: ids + durs))

            // Palette: colours 1-12.
            var colours: [UInt8] = []
            for h in s.palettes![0][1...CTSpriteROM.paletteColours] {
                let w = Int(BGR555(hex: h)!.word)
                colours += [UInt8(w & 0xFF), UInt8(w >> 8)]
            }
            let palPart = Part.palette(d.palette)
            if parts[palPart] == nil {
                var p = PartData()
                p.slices = [(CTSpriteROM.pc(d.paletteAt), CTSpriteROM.paletteBytes)]
                p.unit = CTSpriteROM.paletteBytes
                p.unitName = { _ in "palette" }
                parts[palPart] = p
            }
            parts[palPart]!.wants.append(Want(id: s.id, owner: owner, content: colours))

            // Record +4 to +9 (enemies): the battle fields over the kept bits.
            guard let e = enemy else { continue }
            let recordPC = CTSpriteROM.pc(CTEnemySpriteROM.records + CTEnemySpriteROM.recordBytes * i)
            var fields = Array(built[(recordPC + 4)..<(recordPC + 10)])
            if let b = s.battle {
                fields[0] = UInt8(b.flags | e.record.size)
                fields[1] = UInt8(b.screenOffsetX); fields[2] = UInt8(b.screenOffsetY)
                fields[3] = UInt8(b.halfWidth); fields[4] = UInt8(b.height)
                fields[5] = UInt8(b.moveSpeed | b.moveDelay << 4) | fields[5] & UInt8(keptMove)
            }
            var p = PartData()
            p.slices = [(recordPC + 4, 6)]
            p.unit = 6
            p.unitName = { _ in "record" }
            p.wants = [Want(id: s.id, owner: owner, content: fields)]
            parts[.record(i)] = p
        }

        // The sharer rule, then the writes (kept until everything decodes back).
        var writes: [CTSpritePatch.Write] = []
        var moves: [(what: String, from: Int, to: Int, bytes: Int)] = []
        var changedParts: [Owner: [Part]] = [:]
        var packReports: [Int: ReportPack] = [:]
        var listedEnemies = Set<Int>(), listedNPCs = Set<Int>()
        for owner in byOwner.keys {
            switch owner {
            case .enemy(let i): listedEnemies.insert(i)
            case .npc(let r): listedNPCs.insert(r)
            }
        }
        let measuredSet = measuredEntries(base)
        var pointers: [Int] = (0..<CTSpriteROM.pointers).map { CTSpriteROM.u24(built, CTSpriteROM.tilesPtr + 3 * $0) }
        var baseMeasure: [Int: Int] = [:]
        for g in measuredSet { baseMeasure[g] = measured(pointers, g) }
        for part in parts.keys.sorted() {
            let p = parts[part]!
            let current: [UInt8] = p.pack?.current ?? read(built, p.slices)
            guard p.wants.contains(where: { $0.content != current }) else { continue }
            let names = p.wants.map(\.id).sorted()
            let first = p.wants[0].content
            if let odd = p.wants.first(where: { $0.content != first }) {
                throw CTROMBuildError("sprites \(p.wants[0].id) and \(odd.id) want different \(part.name) for \(part.label); " +
                                      "a shared part has one content")
            }
            if let c = pcOwner(base, part) {
                let who = CTSpriteROM.names[c]
                guard let pcID = pcListed[c] else {
                    throw CTROMBuildError("sprite \(names[0]): its \(part.name) (\(part.label)) belong to playable set \(c) (\(who)); " +
                                          "list that set's sprite in rom.sprites with the same edit")
                }
                throw CTROMBuildError("sprite \(names[0]): its \(part.name) (\(part.label)) differ from sprite \(pcID)'s as built " +
                                      "(set \(c), \(who)); the two must agree")
            }
            if let field = part.field {
                let u = users(base, offset: field.offset, value: field.value)
                let missingEnemies = u.enemies.filter { !listedEnemies.contains($0) }
                let missingNPCs = u.others.filter { !listedNPCs.contains($0) }
                if !missingEnemies.isEmpty || !missingNPCs.isEmpty {
                    var who: [String] = []
                    if !missingEnemies.isEmpty { who.append("enemy records " + missingEnemies.map(String.init).joined(separator: ", ")) }
                    if !missingNPCs.isEmpty {
                        who.append("\(CTSpriteROM.snes(CTSpriteROM.sprRec)) records " +
                                   missingNPCs.map(String.init).joined(separator: ", ") + " (NPCs)")
                    }
                    throw CTROMBuildError("sprite \(names[0]): \(part.label)'s \(part.name) are also shown by " +
                                          who.joined(separator: " and ") + "; list every sharer's sprite with the same edit " +
                                          "(NPC records as ct-npc sprites; layout-3 enemies cannot be listed)")
                }
            }
            for w in p.wants { changedParts[w.owner, default: []].append(part) }
            let owner = "sprite \(names[0])"
            if let pack = p.pack {
                guard let packed = LZSS.compress(first, mode: pack.mode) else {
                    throw CTROMBuildError("\(owner): \(part.label) does not pack")
                }
                var at = pack.pc, placement = "original"
                if packed.count > pack.budget {
                    var found: Int?
                    for start in space.starts(packed.count, reclaimed: false) {
                        var trial = pointers
                        trial[pack.gfx] = 0xC00000 | start
                        if measuredSet.allSatisfy({ $0 == pack.gfx || measured(trial, $0) == baseMeasure[$0] }) {
                            found = start
                            break
                        }
                    }
                    guard let start = found, space.allocate(packed.count, at: start) else {
                        throw CTROMBuildError("\(owner): \(part.label) packs to \(packed.count) bytes, over its \(pack.budget)-byte span, " +
                                              "and no free region (\(space.total) bytes left, in pieces of at most \(space.largest)) " +
                                              "keeps the raw tile blocks' measured ends")
                    }
                    at = start
                    placement = "free"
                    pointers[pack.gfx] = 0xC00000 | start
                    let ptr = [UInt8(start & 0xFF), UInt8(start >> 8 & 0xFF), UInt8(0xC0 | start >> 16)]
                    writes.append((CTSpriteROM.pc(CTSpriteROM.tilesPtr + 3 * pack.gfx), ptr, "\(owner) $E4:2000[\(pack.gfx)]"))
                    moves.append(("\(owner) \(part.label) pack", pack.pc, start, packed.count))
                }
                writes.append((at, packed, "\(owner) \(part.label) pack"))
                packReports[pack.gfx] = ReportPack(graphics: pack.gfx, address: CTSpriteROM.snes(0xC00000 | at), pc: at,
                                                   packedBytes: packed.count, budget: pack.budget, unpackedBytes: first.count,
                                                   unpackedSHA256: CTEventPack.sha256(first), placement: placement,
                                                   from: CTSpriteROM.snes(0xC00000 | pack.pc))
            } else {
                var offset = 0
                for s in p.slices {
                    var k = 0
                    while k < s.count {
                        let n = min(p.unit, s.count - k)
                        let new = Array(first[(offset + k)..<(offset + k + n)])
                        if Array(built[(s.pc + k)..<(s.pc + k + n)]) != new {
                            writes.append((s.pc + k, new, "\(owner) \(p.unitName((offset + k) / p.unit))"))
                        }
                        k += n
                    }
                    offset += s.count
                }
            }
        }

        // Every listed record decoded from the result must give its sprite back.
        var out = built
        for w in writes { out.replaceSubrange(w.pc..<(w.pc + w.bytes.count), with: w.bytes) }
        for g in measuredSet {
            guard CTSpriteROM.tileCount(out, set: g) == baseMeasure[g] else {
                throw CTROMBuildError("graphics \(g): its raw tile block's measured end moved")
            }
        }
        /// The other records naming one of `owner`'s changed parts, with the sprite listing them.
        func sharedWith(_ owner: Owner) -> [String] {
            var shared: [String] = []
            for part in changedParts[owner] ?? [] {
                guard let field = part.field else { continue }
                let u = users(base, offset: field.offset, value: field.value)
                for j in u.enemies where Owner.enemy(j) != owner {
                    shared.append("enemy record \(j) (\(byOwner[.enemy(j)] ?? "?")): \(part.name)")
                }
                for j in u.others where Owner.npc(j) != owner {
                    shared.append("NPC record \(j) (\(byOwner[.npc(j)] ?? "?")): \(part.name)")
                }
            }
            return shared
        }
        var report: [ReportSprite] = [], npcReport: [CTNPCSpritePatch.ReportSprite] = []
        for r in requests {
            let s = r.sprite, i = s.rom!.set, name = "sprite \(s.id)"
            let owner: Owner = s.rom!.family == CTNPCSpriteROM.family ? .npc(i) : .enemy(i)
            let d = decoded[owner]!
            let e: Source, animations: [SpriteDef.Animation], palette: [UInt16]
            var enemy: CTEnemySpriteROM.DecodedEnemy?
            var layout = 0
            if case .npc = owner {
                let n = try CTNPCSpriteROM.decode(rom: out, record: i)
                (e, animations, palette, layout) = (source(n), n.animations, n.palette, n.layout)
            } else {
                let x = try CTEnemySpriteROM.decode(rom: out, id: i)
                let kept = x.animations.filter { $0.frames.allSatisfy { $0 < x.frames.count } }
                (e, animations, palette, layout) = (source(x), kept, x.palette, x.layout)
                enemy = x
            }
            guard e.tiles == tilesWanted[owner]! else { throw CTROMBuildError("\(name): the tiles do not decode back") }
            guard e.frames.count == s.frames.count else {
                throw CTROMBuildError("\(name): the edit changes the frame set's end (an all-zero last frame is trimmed)")
            }
            for (f, frame) in s.frames.enumerated() {
                let pieces: [SpriteDef.Point] = frame.tiles.map { SpriteDef.Point(x: $0.x, y: $0.y) }
                if e.frames[f].cells != (frame.cells ?? []) || e.frames[f].pieces != pieces {
                    throw CTROMBuildError("\(name): frame \(f) does not decode back")
                }
            }
            let got = sortedAnimations(animations), want = sortedAnimations(s.animations)
            var markers: [String: Int] = [:]
            for a in animations { markers[a.id] = a.markerDuration ?? 0 }
            let markersKept = s.animations.allSatisfy { (markers[$0.id] ?? 0) == ($0.markerDuration ?? 0) }
            if got != want || !markersKept {
                throw CTROMBuildError("\(name): an animation would not read back as given; a list keeps its row's length and " +
                                      "terminator, and the 4 facings of a row share its durations")
            }
            let colours: [Int] = s.palettes![0][1...CTSpriteROM.paletteColours].map { Int(BGR555(hex: $0)!.word) }
            guard palette.map(Int.init) == colours else { throw CTROMBuildError("\(name): the palette does not decode back") }

            let mine = changedParts[owner] ?? []
            var changed: [String] = []
            for part in mine { if !changed.contains(part.name) { changed.append(part.name) } }
            var changedTiles: [Int] = []
            for t in 0..<d.tiles.count where e.tiles[t] != d.tiles[t] { changedTiles.append(t) }
            let shared = sharedWith(owner)
            let pack: ReportPack? = mine.contains(.tiles(e.gfx)) ? packReports[e.gfx] : nil
            let frameList: [CTSpritePatch.ReportFrame] = e.frames.map { f in
                CTSpritePatch.ReportFrame(cells: f.cells, pieces: f.pieces.map { [$0.x, $0.y] })
            }
            guard let x = enemy else {
                npcReport.append(CTNPCSpritePatch.ReportSprite(
                    id: s.id, family: CTNPCSpritePatch.family, set: i, layout: layout, changed: changed,
                    graphics: e.gfx, tiles: CTSpriteROM.snes(e.tilesAt), tileCount: e.tiles.count,
                    tilesSHA256: CTEventPack.sha256(e.tiles.flatMap { $0 }), changedTiles: changedTiles, pack: pack,
                    frameSet: e.frameSet, frames: CTSpriteROM.snes(e.framesAt), frameCount: e.frames.count,
                    recordBytes: e.recordBytes, frameList: frameList, animationSet: e.anim,
                    frameIds: CTSpriteROM.snes(e.frameIdsAt), durations: CTSpriteROM.snes(e.durationsAt), rows: e.rows,
                    stride: e.stride, animations: got, paletteIndex: e.palette, palette: CTSpriteROM.snes(e.paletteAt),
                    colours: palette.map(Int.init), sharedWith: shared.isEmpty ? nil : shared))
                continue
            }
            let record = CTEnemySpriteROM.battle(x.record)
            if let b = s.battle, b != record { throw CTROMBuildError("\(name): the record fields do not decode back") }
            report.append(ReportSprite(
                id: s.id, family: family, set: i, layout: x.layout, packed: x.packed, changed: changed,
                graphics: e.gfx, tiles: CTSpriteROM.snes(e.tilesAt), tileCount: e.tiles.count,
                tilesSHA256: CTEventPack.sha256(e.tiles.flatMap { $0 }), changedTiles: changedTiles, pack: pack,
                frameSet: e.frameSet, frames: CTSpriteROM.snes(e.framesAt), frameCount: e.frames.count,
                recordBytes: e.recordBytes, frameList: frameList,
                animationSet: e.anim, frameIds: CTSpriteROM.snes(e.frameIdsAt), durations: CTSpriteROM.snes(e.durationsAt),
                rows: e.rows, animations: got, paletteIndex: e.palette, palette: CTSpriteROM.snes(e.paletteAt),
                colours: palette.map(Int.init), record: record, sharedWith: shared.isEmpty ? nil : shared))
        }
        for w in writes { write(w.bytes, w.pc, w.what) }
        for m in moves { relocated(m.what, m.from, m.to, m.bytes) }
        return (report, npcReport)
    }

    /// The PC write-back's changed parts that unlisted enemy records show
    /// (records $F8-$FE, and any other enemy naming a PC set's part): their
    /// project files keep the old content.
    public static func staleViews(_ pcReport: [CTSpritePatch.ReportSprite], base: [UInt8], listed: Set<Int>) -> [String] {
        var out: [String] = []
        for r in pcReport where !r.changed.isEmpty {
            let c = r.set
            var parts: [(name: String, offset: Int, value: Int)] = []
            for name in r.changed {
                switch name {
                case "tiles": parts.append((name, 0, c))
                case "frames": parts.append((name, 1, c))
                case "animations": parts.append((name, 3, c))
                case "palette": parts.append((name, 2, CTSpriteROM.u8(base, CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * c + 2)))
                default: break
                }
            }
            var records: [Int: [String]] = [:]
            for p in parts {
                for j in users(base, offset: p.offset, value: p.value).enemies where !listed.contains(j) {
                    records[j, default: []].append(p.name)
                }
            }
            for (j, names) in records.sorted(by: { $0.key < $1.key }) {
                out.append("sprite \(r.id) changes the \(names.joined(separator: ", ")) enemy record \(j) shows; " +
                           "its sprites/\(CTEnemySpriteROM.id(j)) files keep the old ones (list it in rom.sprites or re-import it)")
            }
        }
        return out
    }
}
