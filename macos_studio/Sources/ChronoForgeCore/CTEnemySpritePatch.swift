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
// write-back writes it). Any other part needs every enemy record naming it
// listed with the same edit; records of $E4:F000 and layout-3 enemies cannot
// be listed, so a part they share is refused with the sharers named.
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
            return ["layout \(layout): only frame layouts 0-2 have an OBJ assembly the battle's tables give"]
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
    /// (the next pointer in the bank) is its size: the PC sets, the graphics of
    /// records $F8 and up, and (conservatively) every graphics an NPC record names.
    static func measuredEntries(_ rom: [UInt8]) -> [Int] {
        var out = Set(0..<CTSpriteROM.sets)
        for i in CTEnemySpriteROM.romGfxMin..<CTEnemySpriteROM.ids {
            out.insert(CTEnemySpriteROM.record(rom, i).gfx)
        }
        for i in CTSpriteROM.sets..<CTSpriteROM.pointers {
            let at = CTSpriteROM.pc(CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * i)
            if rom[at..<(at + CTSpriteROM.sprRecBytes)].allSatisfy({ $0 == 0 }) { continue }
            out.insert(Int(rom[at]))
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
        var record: Int
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
    }

    static func sortedAnimations(_ list: [SpriteDef.Animation]) -> [CTSpritePatch.ReportAnimation] {
        list.map { CTSpritePatch.ReportAnimation(row: $0.row ?? 0, facing: $0.facing ?? 0, frames: $0.frames, durations: $0.durations) }
            .sorted { ($0.row, $0.facing) < ($1.row, $1.facing) }
    }

    /// Writes `requests` (all ct-enemy) over `built` (the base ROM with the
    /// PC write-back applied; `base` is the unmodified ROM), placing relocated
    /// packs in `space`. `pcListed` maps the PC sets rom.sprites lists to their
    /// ids. Nothing is written unless every request decodes back.
    static func apply(_ requests: [CTSpritePatch.Request], base: [UInt8], built: [UInt8], pcListed: [Int: String],
                      space: inout FreeSpace, write: ([UInt8], Int, String) -> Void,
                      relocated: (String, Int?, Int, Int) -> Void) throws -> [ReportSprite] {
        guard !requests.isEmpty else { return [] }
        var parts: [Part: PartData] = [:]
        var decoded: [Int: CTEnemySpriteROM.DecodedEnemy] = [:]
        var tilesWanted: [Int: [[UInt8]]] = [:]
        var byRecord: [Int: String] = [:]
        var seenIDs = Set<String>()
        for r in requests {
            let s = r.sprite
            guard seenIDs.insert(s.id).inserted else { throw CTROMBuildError("sprite \(s.id) is built twice") }
            if let problem = validate(s).first { throw CTROMBuildError("sprite \(s.id): \(problem)") }
            let src = s.rom!, i = src.set, name = "sprite \(s.id)"
            if let other = byRecord.updateValue(s.id, forKey: i) {
                throw CTROMBuildError("\(name): enemy record \(i) is also sprite \(other)")
            }
            let d = try CTEnemySpriteROM.decode(rom: base, id: i)
            let have = CTEnemySpriteROM.spriteDef(d, id: s.id).rom!
            guard sameLocation(src, have) else {
                throw CTROMBuildError("\(name): its rom source is not where the base ROM has record \(i) " +
                                      "(tiles \(have.tiles) x \(have.tileCount), frames \(have.frames) x \(have.frameCount), " +
                                      "palette \(have.palette), \(have.rows) rows, layout \(have.layout ?? 0)); re-import the sprites")
            }
            guard r.sheet.count >= d.tiles.count else {
                throw CTROMBuildError("\(name): the sheet has \(r.sheet.count) tiles; the record has \(d.tiles.count)")
            }
            decoded[i] = d
            let shape = CTEnemySpriteROM.layouts[d.layout]
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
                throw CTROMBuildError("\(name): sheet tile 0 is the blank cell (the battle draws zeros for it) and must stay as imported")
            }
            tilesWanted[i] = tiles
            let recordPC = CTSpriteROM.pc(CTEnemySpriteROM.records + CTEnemySpriteROM.recordBytes * i)
            if let b = s.battle, b.flags & keptFlags != d.record.flags & keptFlags {
                throw CTROMBuildError(String(format: "%@: battle flags bits 4 and 6 have no reader and stay $%02X", name,
                                             d.record.flags & keptFlags))
            }

            // Tiles: the pack's unpacked bytes, or the raw block in place.
            let joined: [UInt8] = tiles.flatMap { $0 }
            let tilesPart = Part.tiles(d.record.gfx)
            if parts[tilesPart] == nil {
                var p = PartData()
                if d.packed {
                    p.pack = (d.record.gfx, CTSpriteROM.pc(d.tilesAt), d.packedBytes, d.mode, d.tiles.flatMap { $0 })
                } else {
                    p.slices = [(CTSpriteROM.pc(d.tilesAt), CTSpriteROM.tileBytes * d.tiles.count)]
                    p.unit = CTSpriteROM.tileBytes
                    p.unitName = { "tile \($0)" }
                }
                parts[tilesPart] = p
            }
            parts[tilesPart]!.wants.append(Want(id: s.id, record: i, content: joined))

            // Frames: the records in place.
            let framesPart = Part.frames(d.record.frames)
            var frameBytes: [UInt8] = []
            for f in s.frames { frameBytes += encodeFrame(f) }
            if parts[framesPart] == nil {
                var p = PartData()
                p.slices = [(CTSpriteROM.pc(d.framesAt), shape.recordBytes * d.frames.count)]
                p.unit = shape.recordBytes
                p.unitName = { "frame \($0)" }
                parts[framesPart] = p
            }
            parts[framesPart]!.wants.append(Want(id: s.id, record: i, content: frameBytes))

            // Animations: each list over the rows as built, as the PC write-back does.
            let stride = 4 * d.rows, ids0 = CTSpriteROM.pc(d.frameIdsAt), durs0 = CTSpriteROM.pc(d.durationsAt)
            var ids = Array(built[ids0..<(ids0 + 4 * stride)]), durs = Array(built[durs0..<(durs0 + stride)])
            for a in s.animations {
                let row = a.row!, facing = a.facing!
                for (k, id) in a.frames.enumerated() where 4 * row + k < stride {
                    ids[facing * stride + 4 * row + k] = UInt8(id)
                    durs[4 * row + k] = UInt8(a.durations[k])
                }
            }
            let animPart = Part.animations(d.record.anim)
            if parts[animPart] == nil {
                var p = PartData()
                p.slices = [(ids0, 4 * stride), (durs0, stride)]
                p.unit = 4
                let rows = d.rows
                p.unitName = { u in
                    u < 4 * rows ? String(format: "frame ids r%02d.%@", u % rows, CTSpriteROM.facings[u / rows])
                                 : String(format: "durations r%02d", u - 4 * rows)
                }
                parts[animPart] = p
            }
            parts[animPart]!.wants.append(Want(id: s.id, record: i, content: ids + durs))

            // Palette: colours 1-12.
            var colours: [UInt8] = []
            for h in s.palettes![0][1...CTSpriteROM.paletteColours] {
                let w = Int(BGR555(hex: h)!.word)
                colours += [UInt8(w & 0xFF), UInt8(w >> 8)]
            }
            let palPart = Part.palette(d.record.palette)
            if parts[palPart] == nil {
                var p = PartData()
                p.slices = [(CTSpriteROM.pc(d.paletteAt), CTSpriteROM.paletteBytes)]
                p.unit = CTSpriteROM.paletteBytes
                p.unitName = { _ in "palette" }
                parts[palPart] = p
            }
            parts[palPart]!.wants.append(Want(id: s.id, record: i, content: colours))

            // Record +4 to +9: the battle fields over the kept bits.
            var fields = Array(built[(recordPC + 4)..<(recordPC + 10)])
            if let b = s.battle {
                fields[0] = UInt8(b.flags | d.record.size)
                fields[1] = UInt8(b.screenOffsetX); fields[2] = UInt8(b.screenOffsetY)
                fields[3] = UInt8(b.halfWidth); fields[4] = UInt8(b.height)
                fields[5] = UInt8(b.moveSpeed | b.moveDelay << 4) | fields[5] & UInt8(keptMove)
            }
            var p = PartData()
            p.slices = [(recordPC + 4, 6)]
            p.unit = 6
            p.unitName = { _ in "record" }
            p.wants = [Want(id: s.id, record: i, content: fields)]
            parts[.record(i)] = p
        }

        // The sharer rule, then the writes (kept until everything decodes back).
        var writes: [CTSpritePatch.Write] = []
        var moves: [(what: String, from: Int, to: Int, bytes: Int)] = []
        var changedParts: [Int: [Part]] = [:]
        var packReports: [Int: ReportPack] = [:]
        let listed = Set(byRecord.keys)
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
                let missingEnemies = u.enemies.filter { !listed.contains($0) }
                if !missingEnemies.isEmpty || !u.others.isEmpty {
                    var who: [String] = []
                    if !missingEnemies.isEmpty { who.append("enemy records " + missingEnemies.map(String.init).joined(separator: ", ")) }
                    if !u.others.isEmpty {
                        who.append("\(CTSpriteROM.snes(CTSpriteROM.sprRec)) records " + u.others.map(String.init).joined(separator: ", "))
                    }
                    throw CTROMBuildError("sprite \(names[0]): \(part.label)'s \(part.name) are also shown by " +
                                          who.joined(separator: " and ") + "; list every sharer's sprite with the same edit " +
                                          "(\(CTSpriteROM.snes(CTSpriteROM.sprRec)) records and layout-3 enemies cannot be listed)")
                }
            }
            for w in p.wants { changedParts[w.record, default: []].append(part) }
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
        var report: [ReportSprite] = []
        for r in requests {
            let s = r.sprite, i = s.rom!.set, name = "sprite \(s.id)", d = decoded[i]!
            let e = try CTEnemySpriteROM.decode(rom: out, id: i)
            guard e.tiles == tilesWanted[i]! else { throw CTROMBuildError("\(name): the tiles do not decode back") }
            guard e.frames.count == s.frames.count else {
                throw CTROMBuildError("\(name): the edit changes the frame set's end (an all-zero last frame is trimmed)")
            }
            for (f, frame) in s.frames.enumerated() {
                let pieces: [SpriteDef.Point] = frame.tiles.map { SpriteDef.Point(x: $0.x, y: $0.y) }
                if e.frames[f].cells != (frame.cells ?? []) || e.frames[f].pieces != pieces {
                    throw CTROMBuildError("\(name): frame \(f) does not decode back")
                }
            }
            let kept = e.animations.filter { $0.frames.allSatisfy { $0 < e.frames.count } }
            let got = sortedAnimations(kept), want = sortedAnimations(s.animations)
            if got != want {
                throw CTROMBuildError("\(name): an animation would not read back as given; a list keeps its row's length and " +
                                      "terminator, and the 4 facings of a row share its durations")
            }
            let colours: [Int] = s.palettes![0][1...CTSpriteROM.paletteColours].map { Int(BGR555(hex: $0)!.word) }
            guard e.palette.map(Int.init) == colours else { throw CTROMBuildError("\(name): the palette does not decode back") }
            let record = CTEnemySpriteROM.battle(e.record)
            if let b = s.battle, b != record { throw CTROMBuildError("\(name): the record fields do not decode back") }

            let mine = changedParts[i] ?? []
            var changed: [String] = []
            for part in mine { if !changed.contains(part.name) { changed.append(part.name) } }
            var changedTiles: [Int] = []
            for t in 0..<d.tiles.count where e.tiles[t] != d.tiles[t] { changedTiles.append(t) }
            var shared: [String] = []
            for part in mine {
                guard let field = part.field else { continue }
                for j in users(base, offset: field.offset, value: field.value).enemies where j != i {
                    shared.append("enemy record \(j) (\(byRecord[j] ?? "?")): \(part.name)")
                }
            }
            let shape = CTEnemySpriteROM.layouts[e.layout]
            report.append(ReportSprite(
                id: s.id, family: family, set: i, layout: e.layout, packed: e.packed, changed: changed,
                graphics: e.record.gfx, tiles: CTSpriteROM.snes(e.tilesAt), tileCount: e.tiles.count,
                tilesSHA256: CTEventPack.sha256(e.tiles.flatMap { $0 }), changedTiles: changedTiles,
                pack: mine.contains(.tiles(e.record.gfx)) ? packReports[e.record.gfx] : nil,
                frameSet: e.record.frames, frames: CTSpriteROM.snes(e.framesAt), frameCount: e.frames.count,
                recordBytes: shape.recordBytes,
                frameList: e.frames.map { CTSpritePatch.ReportFrame(cells: $0.cells, pieces: $0.pieces.map { [$0.x, $0.y] }) },
                animationSet: e.record.anim, frameIds: CTSpriteROM.snes(e.frameIdsAt), durations: CTSpriteROM.snes(e.durationsAt),
                rows: e.rows, animations: got, paletteIndex: e.record.palette, palette: CTSpriteROM.snes(e.paletteAt),
                colours: e.palette.map(Int.init), record: record, sharedWith: shared.isEmpty ? nil : shared))
        }
        for w in writes { write(w.bytes, w.pc, w.what) }
        for m in moves { relocated(m.what, m.from, m.to, m.bytes) }
        return report
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
