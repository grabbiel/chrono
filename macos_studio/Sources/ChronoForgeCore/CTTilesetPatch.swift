// CTTilesetPatch.swift — `rom.tilesets` written back into a copy of the base
// ROM (docs/tilesets.md, "Writing back"): palette sets in place, palette-cycle
// lists (FieldAnimListB) and their frames, metatile tables repacked with the
// original lz11 packer (in place or moved and repointed), graphics packs
// re-encoded with the planar encoder and repacked in their own mode (a pack
// its users would edit differently is forked to a free pack number and the
// list repointed, or refused), and the tile-animation records
// (FieldAnimListA) in place. Unchanged parts are not written, so an unedited
// import rebuilds the base ROM byte for byte. Before anything is placed, the
// windows the game would load are rebuilt from the new packs and compared
// with the sheets: a character no slot can carry (a stale tail, a character
// the tileset does not set) is refused.
import Foundation

public enum CTTilesetPatch {
    /// BattleFx_BgSetPacks ($D1:ECDB): 6 battle backgrounds x 4 LocGfx_PackPtrs ids ($FF none).
    public static let battleSets = 0xD1ECDB, battleSetCount = 6, battleSlots = 4
    public static let packCount = 224                                 // LocGfx_PackPtrs
    public static let paletteCount = 88                               // LocPal_Rom sets
    /// FieldRom_AnimListB's lists must stay in bank $FD after $FD:FA77
    /// (16-bit offsets) and before $FD:FF29, the data after them.
    public static let animBEnd = 0xFDFF29

    /// One listed tileset with its sheets' tiles (64 indices each; sheet tile k = character k).
    public struct Request: Sendable {
        public var tileset: Tileset
        public var sheet: [[UInt8]]?
        public var animSheet: [[UInt8]]?
        public init(tileset: Tileset, sheet: [[UInt8]]? = nil, animSheet: [[UInt8]]? = nil) {
            self.tileset = tileset; self.sheet = sheet; self.animSheet = animSheet
        }
    }

    public struct ReportBlock: Codable, Equatable, Sendable {
        public let what: String                  // "metatiles", "pack 37", "pack 204 (fork of 37)"
        public let address: String
        public let pc: Int
        public let packedBytes: Int
        public let unpackedBytes: Int
        public let unpackedSHA256: String
        public let placement: String             // original | reclaimed | free
    }
    public struct ReportTileset: Codable, Equatable, Sendable {
        public let id: String
        public let kind: String                  // bg12 | bg3 | palette
        public let index: Int
        public let changed: [String]             // the parts written: palette, cycles, frames, metatiles, characters, animations
        public let blocks: [ReportBlock]         // packed blocks placed for it
        public let packs: [Int]?                 // bg12: the list's 8 pack numbers after the build (nil = none)
    }

    /// Every graphics-pack user in the base ROM: the lists of the Tileset12
    /// values locations use, the Tileset3 packs and the battle backgrounds.
    enum User: Hashable, Comparable {
        case list(Int, Int), layer3(Int), battle(Int, Int)
        var name: String {
            switch self {
            case let .list(t, k): return "\(CTTilesets.id12(t)) slot \(k)"
            case let .layer3(n): return CTTilesets.id3(n)
            case let .battle(s, k): return "battle background \(s) slot \(k)"
            }
        }
    }

    static func packUsers(_ rom: [UInt8]) -> [Int: [User]] {
        var out: [Int: [User]] = [:]
        for t in CTTilesetROM.users(rom, \.tileset12).keys.sorted() {
            for (k, n) in CTTilesetROM.packList(rom, t).enumerated() { if let n { out[n, default: []].append(.list(t, k)) } }
        }
        for n in CTTilesetROM.users(rom, \.tileset3).keys.sorted() { out[n, default: []].append(.layer3(n)) }
        for s in 0..<battleSetCount {
            for k in 0..<battleSlots {
                let n = Int(rom[CTTilesetROM.pc(battleSets) + battleSlots * s + k])
                if n != CTTilesetROM.none { out[n, default: []].append(.battle(s, k)) }
            }
        }
        return out
    }

    /// Pack numbers no loader names and whose pointer does not unpack (204-223
    /// in the ROM): a fork can take them.
    public static func freePackNumbers(_ rom: [UInt8]) -> [Int] {
        let used = packUsers(rom)
        return (0..<packCount).filter { n in
            used[n] == nil && (try? CTTilesetROM.pack(rom, n)) == nil
        }
    }

    static func hexWord(_ s: String, _ what: String) throws -> UInt16 {
        let body = s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s
        guard let v = UInt16(body, radix: 16), v <= 0x7FFF else { throw CTROMBuildError("\(what): \(s) is not a BGR555 word") }
        return v
    }
    static func le(_ w: Int) -> [UInt8] { [UInt8(w & 0xFF), UInt8(w >> 8 & 0xFF)] }

    // MARK: Palettes

    /// The 210 bytes of a palette set: colours 1-15 of rows 1-7.
    public static func paletteBytes(_ ts: Tileset) throws -> [UInt8] {
        guard let rows = ts.palettes, rows.count == 8, rows.allSatisfy({ $0.count == 16 }) else {
            throw CTROMBuildError("\(ts.id): palettes must be 8 rows of 16 words")
        }
        var out: [UInt8] = []
        for r in 1...CTTilesetROM.palRows {
            for c in 1...CTTilesetROM.rowColours { out += le(Int(try hexWord(rows[r][c], "\(ts.id) row \(r) colour \(c)"))) }
        }
        return out
    }

    /// A cycle list's bytes (6 records, empty ones a $00 byte) with each frames
    /// record's colours; `frameAt` gives the bank-$F6 offset of each frames record.
    static func cycleList(_ cycles: [Tileset.PaletteCycle], id: String, frameAt: (Int) throws -> Int) throws -> [UInt8] {
        guard cycles.count <= CTTilesetROM.bFilled else { throw CTROMBuildError("\(id): at most \(CTTilesetROM.bFilled) palette cycles") }
        var out: [UInt8] = []
        for (i, c) in cycles.enumerated() {
            let what = "\(id) palette cycle \(i)"
            guard let kind = CTTilesetROM.cycleKinds.first(where: { $0.value == c.kind })?.key, [1, 2, 3, 8].contains(kind) else {
                throw CTROMBuildError("\(what): kind \(c.kind) is not rom-frames, list-frames, rotate-down or rotate-up")
            }
            for (name, v) in [("first", c.first), ("count", c.count), ("delay", c.delay)] where !(0...0xFF).contains(v) {
                throw CTROMBuildError("\(what): \(name) \(v) is not a byte")
            }
            // Location cycles stay inside CGRAM rows 1-7 (colours 16-127).
            let last = kind == 2 || kind == 3 ? c.first + c.count : c.first + c.count - 1
            guard c.first >= 16, last < 128, c.count > 0 else { throw CTROMBuildError("\(what): colours \(c.first)-\(last) leave rows 1-7") }
            switch kind {
            case 2, 3:
                out += [UInt8(kind << 4), UInt8(c.first), UInt8(c.count), UInt8(c.delay)]
            default:
                let frames = c.frames ?? []
                let nibble: Int
                if kind == 8 {
                    guard let order = c.order, (1...16).contains(order.count), order.allSatisfy({ (0..<frames.count).contains($0) }),
                          order.max().map({ $0 + 1 }) == frames.count else {
                        throw CTROMBuildError("\(what): list-frames needs 1-16 order entries naming every frame")
                    }
                    nibble = order.count - 1
                } else {
                    guard (1...16).contains(frames.count) else { throw CTROMBuildError("\(what): rom-frames needs 1-16 frames") }
                    nibble = frames.count - 1
                }
                guard frames.allSatisfy({ $0.count == c.count }) else { throw CTROMBuildError("\(what): each frame has count colours") }
                let at = try frameAt(i)
                out += [UInt8(kind << 4 | nibble), UInt8(c.first), UInt8(c.count), UInt8(c.delay)] + le(at) + [0xF6]
                if kind == 8 { out += c.order!.map { UInt8($0) } }
            }
        }
        return out + [UInt8](repeating: 0, count: CTTilesetROM.bFilled - cycles.count)
    }

    static func frameBytes(_ c: Tileset.PaletteCycle, id: String) throws -> [UInt8] {
        try (c.frames ?? []).flatMap { f in try f.flatMap { le(Int(try hexWord($0, "\(id) cycle frames"))) } }
    }

    // MARK: Metatiles

    public static func metatileBytes(_ ts: Tileset, count: Int) throws -> [UInt8] {
        guard ts.metatiles.count == count else { throw CTROMBuildError("\(ts.id): \(ts.metatiles.count) metatiles; the table holds \(count)") }
        var out: [UInt8] = []
        for (i, mt) in ts.metatiles.enumerated() {
            guard mt.chips.count == 4 else { throw CTROMBuildError("\(ts.id): metatile \(i) needs 4 chips") }
            for c in mt.chips {
                guard (0..<1024).contains(c.tile), (0..<8).contains(c.pal) else {
                    throw CTROMBuildError("\(ts.id): metatile \(i): character \(c.tile) or palette \(c.pal) out of range")
                }
                out += le(Int(c.word))
            }
        }
        return out
    }

    /// The checks a build makes that need no ROM: the source, palettes,
    /// cycles, metatile counts and ranges, and the tile animations' shapes.
    public static func validate(_ ts: Tileset) -> [String] {
        guard let src = ts.rom else { return ["no rom source: import the ROM's tilesets"] }
        var problems: [String] = []
        func attempt(_ body: () throws -> Void) { do { try body() } catch { problems.append("\(error)") } }
        switch src.family {
        case "ct-loc12", "ct-loc3":
            let twelve = src.family == "ct-loc12"
            guard (0..<(twelve ? 64 : 32)).contains(src.index), ts.id == (twelve ? CTTilesets.id12 : CTTilesets.id3)(src.index) else {
                return ["rom \(src.family) \(src.index) does not name this tileset"]
            }
            attempt { _ = try metatileBytes(ts, count: twelve ? 512 : 256) }
            if ts.sheet == nil { problems.append("no sheet: the build writes its characters from it") }
            for (i, a) in (ts.tileAnimations ?? []).enumerated()
                where a.tiles != 4 || a.steps.count != 8 || a.frames.count != 8 || !(0..<CTTilesetROM.window).contains(a.tile)
                || !a.steps.allSatisfy({ (0...0xFF).contains($0) }) || !a.frames.allSatisfy({ (0...252).contains($0) }) {
                problems.append("tile animation \(i): 4 characters, 8 steps (bytes) and 8 frames of the animation sheet")
            }
        case "ct-locpal":
            guard (0..<paletteCount).contains(src.index), ts.id == CTTilesets.idPalette(src.index) else {
                return ["rom \(src.family) \(src.index) does not name this palette"]
            }
            attempt { _ = try paletteBytes(ts) }
            attempt {
                let cycles = ts.paletteCycles ?? []
                _ = try cycleList(cycles, id: ts.id) { i in _ = try frameBytes(cycles[i], id: ts.id); return 0 }
            }
        default:
            problems.append("rom family \(src.family) is not ct-loc12, ct-loc3 or ct-locpal")
        }
        return problems
    }

    // MARK: Windows from pack contents (as CTTilesetROM decodes them)

    static func bg12Window(_ list: [Int?], _ data: (Int) throws -> [UInt8]) throws -> CTTilesetROM.Window {
        var window = CTTilesetROM.Window(tiles: CTTilesetROM.window, tileBytes: 32)
        var stage = CTTilesetROM.Window(tiles: CTTilesetROM.packBytes / 32, tileBytes: 32)
        for (k, n) in list.prefix(CTTilesetROM.slots).enumerated() {
            guard let n else { continue }
            let size = k == CTTilesetROM.slots - 1 ? CTTilesetROM.pack5Bytes : CTTilesetROM.packBytes
            let first = (CTTilesetROM.vram0 + CTTilesetROM.vramStep * k - CTTilesetROM.bg12Char) / 16
            stage.write(try data(n).prefix(CTTilesetROM.packBytes), at: 0)
            for i in 0..<size where stage.set[i] { window.write([stage.bytes[i]], at: first * 32 + i) }
        }
        return window
    }

    static func animWindow(_ list: [Int?], _ data: (Int) throws -> [UInt8]) throws -> CTTilesetROM.Window {
        var w = CTTilesetROM.Window(tiles: CTTilesetROM.animWramBytes / 32, tileBytes: 32)
        for k in 6...7 {
            guard let n = list[k] else { continue }
            let base = 0x1000 * (k - 6)
            w.write(try data(n).prefix(CTTilesetROM.animWramBytes - base), at: base)
        }
        return w
    }

    static func bg3Window(_ n: Int, _ data: (Int) throws -> [UInt8]) throws -> CTTilesetROM.Window {
        var w = CTTilesetROM.Window(tiles: CTTilesetROM.window, tileBytes: 16)
        let d = try data(n)
        w.write(d.prefix(min(d.count, CTTilesetROM.packBytes)), at: 0)
        return w
    }

    /// The sheet's tiles where the window sets them, blank elsewhere (the import's sheet).
    static func sheetTiles(_ w: CTTilesetROM.Window, bpp: Int) -> [[UInt8]] {
        let known = w.knownTiles, idx = w.indices(bpp: bpp)
        return idx.indices.map { known[$0] ? idx[$0] : [UInt8](repeating: 0, count: 64) }
    }

    /// `data` with bytes [from, from + tiles x tileBytes) replaced by the tiles' planar bytes.
    static func encode(_ data: [UInt8], tiles: ArraySlice<[UInt8]>, at from: Int, bpp: Int) -> [UInt8] {
        var out = data
        let bytes = TileDecoder.encodePlanar(Array(tiles.joined()), depth: bpp == 2 ? .bpp2 : .bpp4)
        out.replaceSubrange(from..<(from + bytes.count), with: bytes)
        return out
    }

    // MARK: The build

    static func apply(requests: [Request], base: [UInt8], space: inout FreeSpace,
                      write: ([UInt8], Int, String) -> Void,
                      relocated: (String, Int?, Int, Int) -> Void) throws -> [ReportTileset] {
        var seen = Set<String>()
        var changed: [String: [String]] = [:], blocks: [String: [ReportBlock]] = [:]
        func mark(_ id: String, _ part: String) { if !(changed[id] ?? []).contains(part) { changed[id, default: []].append(part) } }
        func place(_ packed: [UInt8], unpacked: [UInt8], home: Range<Int>?, owner: String, what: String) throws -> Int {
            let (pc, placement) = try CTROMBuilder.placeBlock(packed, home: home, space: &space, what: "\(owner) \(what)")
            write(packed, pc, "\(owner) \(what)")
            if placement != "original" { relocated("\(owner) \(what)", home?.lowerBound, pc, packed.count) }
            blocks[owner, default: []].append(.init(what: what, address: CTROMBuilder.snes(pc), pc: pc, packedBytes: packed.count,
                                                    unpackedBytes: unpacked.count, unpackedSHA256: CTEventPack.sha256(unpacked),
                                                    placement: placement))
            return pc
        }
        func pointer(_ pc: Int) -> [UInt8] { [UInt8(pc & 0xFF), UInt8(pc >> 8 & 0xFF), UInt8(0xC0 | pc >> 16)] }

        struct Parsed { var request: Request; var family: String; var index: Int }
        var parsed: [Parsed] = []
        let used12 = Set(CTTilesetROM.users(base, \.tileset12).keys), used3 = Set(CTTilesetROM.users(base, \.tileset3).keys)
        let usedPal = Set(CTTilesetROM.users(base, \.palette).keys)
        for r in requests {
            let ts = r.tileset
            guard seen.insert(ts.id).inserted else { throw CTROMBuildError("tileset \(ts.id) is built twice") }
            guard let src = ts.rom else { throw CTROMBuildError("tileset \(ts.id): no rom source; import the ROM's tilesets") }
            let ok: Bool
            switch src.family {
            case "ct-loc12": ok = used12.contains(src.index) && ts.id == CTTilesets.id12(src.index)
            case "ct-loc3": ok = used3.contains(src.index) && ts.id == CTTilesets.id3(src.index)
            case "ct-locpal": ok = usedPal.contains(src.index) && ts.id == CTTilesets.idPalette(src.index)
            default: ok = false
            }
            guard ok else { throw CTROMBuildError("tileset \(ts.id): rom \(src.family) \(src.index) is not a set the locations use") }
            parsed.append(Parsed(request: r, family: src.family, index: src.index))
        }

        // Palettes: the sets in place; cycle lists in place; frames in place or moved within bank $F6.
        let listOffsets = (0..<paletteCount).map { CTTilesetROM.u16(base, CTTilesetROM.animBPtrs + 2 * $0) }
        var wantedLists: [Int: (id: String, bytes: [UInt8])] = [:]          // list offset -> new bytes
        var frameUses: [Int: [UInt8]] = [:]                                 // bank-$F6 offset -> colours as built
        for p in usedPal {                                                  // the base frames every record shows
            for r in CTTilesetROM.animListB(base, p).records.compactMap({ $0 }) where r.offset != nil {
                frameUses[r.offset!] = r.colours!.flatMap { $0.flatMap { le(Int($0)) } }
            }
        }
        let baseFrames = frameUses
        for item in parsed where item.family == "ct-locpal" {
            let ts = item.request.tileset, p = item.index
            let set = try paletteBytes(ts)
            let at = CTTilesetROM.pc(CTTilesetROM.locPal + CTTilesetROM.palSetBytes * p)
            if Array(base[at..<(at + set.count)]) != set { write(set, at, "\(ts.id) palette"); mark(ts.id, "palette") }
            let d = CTTilesetROM.decodePalette(base, p)
            let cycles = ts.paletteCycles ?? []
            guard cycles != CTTilesets.paletteCycles(d.cycles) else { continue }
            let old = d.cycles.compactMap { $0 }
            let list = try cycleList(cycles, id: ts.id) { i in
                let c = cycles[i]
                let bytes = try frameBytes(c, id: ts.id)
                var source = c.source.flatMap(Self.long)
                if source == nil, i < old.count, let o = old[i].offset { source = 0xF60000 | o }
                if let s = source, s >> 16 == 0xF6, let had = frameUses[s & 0xFFFF],
                   had == bytes || (baseFrames[s & 0xFFFF] == had && bytes.count <= had.count
                                    && !Self.framesShared(base, s & 0xFFFF, except: p, usedPal)) {
                    if had != bytes {
                        write(bytes, CTTilesetROM.pc(s), "\(ts.id) cycle \(i) frames"); mark(ts.id, "frames")
                        frameUses[s & 0xFFFF] = bytes
                    }
                    return s & 0xFFFF
                }
                // A new place in bank $F6 (PalAnim_CopyRomFrame reads bank $F6).
                guard let pc = space.allocate(bytes.count, reclaimed: false, bank: 0x36) else {
                    throw CTROMBuildError("\(ts.id) cycle \(i): no free space in bank $F6 for \(bytes.count) bytes of frames")
                }
                write(bytes, pc, "\(ts.id) cycle \(i) frames"); mark(ts.id, "frames")
                relocated("\(ts.id) cycle \(i) frames", source.map(CTTilesetROM.pc), pc, bytes.count)
                frameUses[pc & 0xFFFF] = bytes
                return pc & 0xFFFF
            }
            let off = listOffsets[p]
            if let other = wantedLists[off], other.bytes != list {
                throw CTROMBuildError("\(ts.id): its cycle list is shared with \(other.id), which lists other cycles")
            }
            wantedLists[off] = (ts.id, list)
            let sharers = usedPal.filter { listOffsets[$0] == off && $0 != p }
            for q in sharers where !parsed.contains(where: { $0.family == "ct-locpal" && $0.index == q }) {
                throw CTROMBuildError("\(ts.id): its cycle list is shared with \(CTTilesets.idPalette(q)), which is not built; " +
                                      "FieldAnimListB has no room in bank $FD to give it its own")
            }
            guard list.count <= d.cyclesEnd - d.cyclesAt else {
                throw CTROMBuildError("\(ts.id): the cycle list grows from \(d.cyclesEnd - d.cyclesAt) to \(list.count) bytes; " +
                                      "FieldAnimListB has no room in bank $FD to move it")
            }
            write(list, CTTilesetROM.pc(d.cyclesAt), "\(ts.id) cycle list"); mark(ts.id, "cycles")
        }

        // Metatile tables: repacked with the original lz11 packer.
        for item in parsed where item.family != "ct-locpal" {
            let ts = item.request.tileset
            let twelve = item.family == "ct-loc12"
            let ptrs = twelve ? CTTilesetROM.meta12Ptrs : CTTilesetROM.meta3Ptrs
            let table = try CTTilesetROM.metaTable(base, ptrs: ptrs, item.index)
            let old = try CTTilesetROM.unpack(base, table.at).out
            let count = table.metatiles.count
            var bytes = old
            bytes.replaceSubrange(0..<(8 * count), with: try metatileBytes(ts, count: count))
            guard bytes != old else { continue }
            guard let packed = LZSS.compress(bytes, mode: table.mode) else { throw CTROMBuildError("\(ts.id): metatiles do not pack") }
            let home = CTTilesetROM.pc(table.at)..<(CTTilesetROM.pc(table.at) + table.packed)
            let pc = try place(packed, unpacked: bytes, home: home, owner: ts.id, what: "metatiles")
            write(pointer(pc), CTTilesetROM.pc(ptrs + 3 * item.index), "\(ts.id) metatile pointer")
            mark(ts.id, "metatiles")
        }

        // Graphics packs: the contents each user wants (nil: the base pack's).
        let users = packUsers(base)
        var basePack: [Int: CTTilesetROM.Pack] = [:]
        func pack(_ n: Int) throws -> CTTilesetROM.Pack {
            if let p = basePack[n] { return p }
            let p = try CTTilesetROM.pack(base, n)
            basePack[n] = p
            return p
        }
        var want: [User: [UInt8]] = [:]
        for item in parsed where item.family != "ct-locpal" {
            let ts = item.request.tileset, t = item.index
            if item.family == "ct-loc3" {
                guard let sheet = item.request.sheet else { continue }
                guard sheet.count == CTTilesetROM.window else { throw CTROMBuildError("\(ts.id): the sheet has \(sheet.count) tiles, not 1024") }
                let p = try pack(t)
                let own = min(p.data.count, CTTilesetROM.packBytes) / 16
                let data = encode(p.data, tiles: sheet[0..<own], at: 0, bpp: 2)
                if data != p.data { want[.layer3(t)] = data }
                continue
            }
            let list = CTTilesetROM.packList(base, t)
            if let sheet = item.request.sheet {
                guard sheet.count == CTTilesetROM.window else { throw CTROMBuildError("\(ts.id): the sheet has \(sheet.count) tiles, not 1024") }
                for (k, n) in list.prefix(CTTilesetROM.slots).enumerated() {
                    guard let n else { continue }
                    let p = try pack(n)
                    let size = k == CTTilesetROM.slots - 1 ? CTTilesetROM.pack5Bytes : CTTilesetROM.packBytes
                    let own = min(p.data.count, size) / 32
                    let first = (CTTilesetROM.vram0 + CTTilesetROM.vramStep * k - CTTilesetROM.bg12Char) / 16
                    let data = encode(p.data, tiles: sheet[first..<(first + own)], at: 0, bpp: 4)
                    if data != p.data { want[.list(t, k)] = data }
                }
            }
            if let anim = item.request.animSheet {
                guard anim.count == CTTilesetROM.animWramBytes / 32 else {
                    throw CTROMBuildError("\(ts.id): the animation sheet has \(anim.count) tiles, not 256")
                }
                for k in 6...7 {
                    guard let n = list[k] else { continue }
                    let p = try pack(n)
                    let start = 0x1000 * (k - 6)
                    // Pack 7's bytes cover the second half of pack 6's.
                    let room = k == 6 && list[7] != nil ? 0x1000 : CTTilesetROM.animWramBytes - start
                    let own = min(p.data.count, room) / 32
                    let data = encode(p.data, tiles: anim[(start / 32)..<(start / 32 + own)], at: 0, bpp: 4)
                    if data != p.data { want[.list(t, k)] = data }
                }
            }
        }

        // Each pack: one content stays at its number, every other one is forked (lists only).
        var final: [Int: [UInt8]] = [:], lists: [Int: [Int?]] = [:]
        var forks = freePackNumbers(base)
        var rewrites: [(n: Int, data: [UInt8], fork: Int?, users: [User])] = []
        for n in users.keys.sorted() {
            let us = users[n]!
            guard us.contains(where: { want[$0] != nil }) else { continue }
            var order: [[UInt8]] = [], groups: [[UInt8]: [User]] = [:]
            for u in us { if let d = want[u] { if groups[d] == nil { order.append(d) }; groups[d, default: []].append(u) } }
            let keepsBase = us.contains { want[$0] == nil }
            for (k, data) in order.enumerated() {
                if k == 0 && !keepsBase { rewrites.append((n, data, nil, groups[data]!)); final[n] = data; continue }
                let group = groups[data]!
                if let fixed = group.first(where: { if case .list = $0 { return false }; return true }) {
                    throw CTROMBuildError("pack \(n): \(fixed.name) would change it, but its other users (" +
                                          us.filter { want[$0] != data }.map(\.name).joined(separator: ", ") +
                                          ") keep it and \(fixed.name) cannot be given a fork")
                }
                guard !forks.isEmpty else { throw CTROMBuildError("pack \(n) needs a fork for \(group[0].name); no pack number is free") }
                let f = forks.removeFirst()
                rewrites.append((n, data, f, group))
                final[f] = data
                for case let .list(t, k) in group {
                    var l = lists[t] ?? CTTilesetROM.packList(base, t)
                    l[k] = f
                    lists[t] = l
                }
            }
        }

        // The windows the game would load now must be the sheets.
        func content(_ n: Int) throws -> [UInt8] { try final[n] ?? pack(n).data }
        for item in parsed where item.family != "ct-locpal" {
            let ts = item.request.tileset, t = item.index
            func compare(_ sheet: [[UInt8]], _ window: CTTilesetROM.Window, raw: Bool, what: String) throws {
                let built = raw ? window.indices(bpp: 4) : sheetTiles(window, bpp: ts.bpp)
                if let k = sheet.indices.first(where: { sheet[$0] != built[$0] }) {
                    throw CTROMBuildError("\(ts.id): \(what) \(k) is not what the game would load from the new packs " +
                                          "(a stale tail past a short pack, a character no slot of this tileset sets, or " +
                                          "a pack shared within the list)")
                }
            }
            if item.family == "ct-loc3" {
                if let sheet = item.request.sheet { try compare(sheet, try bg3Window(t, content), raw: false, what: "character") }
                continue
            }
            let list = lists[t] ?? CTTilesetROM.packList(base, t)
            if let sheet = item.request.sheet { try compare(sheet, try bg12Window(list, content), raw: false, what: "character") }
            if let anim = item.request.animSheet { try compare(anim, try animWindow(list, content), raw: true, what: "animation tile") }
        }

        // Place the packs, repoint them and the lists.
        let pointers = (0..<packCount).map { CTTilesetROM.u24(base, CTTilesetROM.packPtrs + 3 * $0) }
        for r in rewrites {
            let p = try pack(r.n)
            guard let packed = LZSS.compress(r.data, mode: p.mode) else { throw CTROMBuildError("pack \(r.n) does not pack") }
            let number = r.fork ?? r.n
            // The old span is free only when the pack is rewritten and no other pointer shares it.
            let shared = pointers.enumerated().contains { $0.offset != r.n && $0.element == p.at }
            let home = r.fork == nil && !shared ? CTTilesetROM.pc(p.at)..<(CTTilesetROM.pc(p.at) + p.packed) : nil
            let owners = Set(r.users.compactMap { u -> String? in
                switch u { case let .list(t, _): return CTTilesets.id12(t); case let .layer3(n): return CTTilesets.id3(n); default: return nil }
            }).sorted()
            let what = r.fork.map { "pack \($0) (fork of \(r.n))" } ?? "pack \(r.n)"
            let pc = try place(packed, unpacked: r.data, home: home, owner: owners[0], what: what)
            for o in owners.dropFirst() { blocks[o, default: []].append(blocks[owners[0]]!.last!) }
            write(pointer(pc), CTTilesetROM.pc(CTTilesetROM.packPtrs + 3 * number), "LocGfx_PackPtrs[\(number)]")
            for o in owners { mark(o, "characters") }
        }
        for (t, l) in lists.sorted(by: { $0.key < $1.key }) {
            write(l.map { UInt8($0 ?? CTTilesetROM.none) }, CTTilesetROM.pc(CTTilesetROM.lists + CTTilesetROM.listBytes * t),
                  "\(CTTilesets.id12(t)) pack list")
        }

        // Tile animations: each record's target, steps and frames in place.
        let used12List = used12.sorted()
        var wantedA: [Int: (id: String, bytes: [(Int, [UInt8])])] = [:]
        for item in parsed where item.family == "ct-loc12" {
            let ts = item.request.tileset, t = item.index
            let a = CTTilesetROM.animListA(base, t)
            let anims = ts.tileAnimations ?? []
            guard anims != CTTilesets.tileAnimations(a.records) else { continue }
            let records = a.records.compactMap { $0 }
            guard anims.count == records.count else {
                throw CTROMBuildError("\(ts.id): \(anims.count) tile animations instead of \(records.count); FieldAnimListA has " +
                                      "no room in bank $FD for a longer list")
            }
            var at = CTTilesetROM.pc(a.at), out: [(Int, [UInt8])] = []
            var walk = a.records.makeIterator()
            var k = 0
            while let r = walk.next() {
                guard let r else { at += 1; continue }
                let n = r.steps.count, an = anims[k]; k += 1
                let what = "\(ts.id) tile animation \(k - 1)"
                guard an.tiles == 4, (0..<CTTilesetROM.window).contains(an.tile), an.steps.count == 8, an.frames.count == 8 else {
                    throw CTROMBuildError("\(what): 4 characters, 8 steps and 8 frames")
                }
                guard an.steps == Array(repeatElement(Array(an.steps.prefix(n)), count: 8 / n).joined()),
                      an.frames == Array(repeatElement(Array(an.frames.prefix(n)), count: 8 / n).joined()) else {
                    throw CTROMBuildError("\(what): its record (kind \(r.kind)) holds \(n) steps and frames, repeated to 8")
                }
                guard an.steps.allSatisfy({ (0...0xFF).contains($0) }), an.frames.allSatisfy({ (0...252).contains($0) }) else {
                    throw CTROMBuildError("\(what): a step is not a byte or a frame is past the animation sheet")
                }
                let vram = CTTilesetROM.bg12Char + 16 * an.tile
                out.append((at + 1, le(vram) + an.steps.prefix(n).map { UInt8($0) }
                            + an.frames.prefix(n).flatMap { le((CTTilesetROM.animWram & 0xFFFF) + 32 * $0) }))
                at += 3 + 3 * n
            }
            let off = CTTilesetROM.u16(base, CTTilesetROM.animAPtrs + 2 * (t & CTTilesetROM.animSetMask))
            if let other = wantedA[off], other.bytes.map(\.1) != out.map(\.1) {
                throw CTROMBuildError("\(ts.id): its tile-animation list is shared with \(other.id), which animates differently")
            }
            for u in used12List where u != t && CTTilesetROM.u16(base, CTTilesetROM.animAPtrs + 2 * (u & CTTilesetROM.animSetMask)) == off
                && !parsed.contains(where: { $0.family == "ct-loc12" && $0.index == u }) {
                throw CTROMBuildError("\(ts.id): its tile-animation list is shared with \(CTTilesets.id12(u)), which is not built")
            }
            wantedA[off] = (ts.id, out)
            for (pc, bytes) in out { write(bytes, pc, "\(ts.id) tile animations") }
            mark(ts.id, "animations")
        }

        return parsed.map { item in
            let id = item.request.tileset.id
            let kind = item.family == "ct-loc12" ? "bg12" : item.family == "ct-loc3" ? "bg3" : "palette"
            let packs = item.family == "ct-loc12" ? (lists[item.index] ?? CTTilesetROM.packList(base, item.index)) : nil
            return ReportTileset(id: id, kind: kind, index: item.index, changed: changed[id] ?? [], blocks: blocks[id] ?? [],
                                 packs: packs.map { $0.map { $0 ?? CTTilesetROM.none } })
        }
    }

    /// "$F6:7568" as a long address.
    static func long(_ s: String) -> Int? {
        let parts = s.dropFirst().split(separator: ":")
        guard s.hasPrefix("$"), parts.count == 2, let b = Int(parts[0], radix: 16), let a = Int(parts[1], radix: 16) else { return nil }
        return b << 16 | a
    }

    /// Whether a frames block is shown by a record of a palette other than `p`.
    static func framesShared(_ rom: [UInt8], _ offset: Int, except p: Int, _ used: Set<Int>) -> Bool {
        used.contains { q in q != p && CTTilesetROM.animListB(rom, q).records.contains { $0?.offset == offset } }
    }
}
