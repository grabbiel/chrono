// CTMapPatch.swift — `rom.maps` written back into a copy of the base ROM
// (docs/maps.md, "Writing maps back"): each changed map's MapProps repacked in
// its entry's mode, kept in place when it fits and otherwise moved and
// repointed; a map edited away from a shared entry takes a free
// Map_PropsPtrs slot; the LocRom records in place; ExitRom rewritten with its
// 513 offset words; TreasureRom records in place. Unchanged parts are not
// written, so an unedited import rebuilds the base ROM byte for byte.
// re_workspace/tools/ct_rom_check.py checks the result independently.
import Foundation

public enum CTMapPatch {
    /// The ExitRom block: 513 offset words, then the records, ending where the
    /// confirmed padding at $E5:1A44 begins (the block may grow into it).
    public static let exitBlock = 0xE50000, exitWords = CTMapROM.locCount + 1
    /// Map_PropsPtrs slots no LocRom record names and whose pointer is 0 (202-255 in the ROM).
    public static func freeSlots(_ rom: [UInt8]) -> [Int] {
        let used = Set((0..<CTMapROM.locCount).map { CTMapROM.header(rom, $0).mapProps })
        return (0..<CTMapROM.propsCount).filter { !used.contains($0) && CTMapROM.propsPointer(rom, $0) == 0 }
    }

    public struct ReportMap: Codable, Equatable, Sendable {
        public let id: String
        public let location: Int
        public let entry: Int                  // the Map_PropsPtrs entry the record names
        public let newEntry: Bool              // a free slot taken for this map
        public let address: String             // the entry's pack
        public let pc: Int
        public let packedBytes: Int
        public let unpackedBytes: Int
        public let unpackedSHA256: String
        public let placement: String           // unchanged | original | reclaimed | free | shared
        public let record: [Int]               // the 14 LocRom bytes
        public let exits: [[Int]]              // 7 raw bytes each
        public let treasureList: Int           // the location whose TreasureRom list it uses
        public let treasure: [[Int]]           // x, y, contents of that list
    }

    /// A map's MapProps from the project: the sizes come from the layers, the
    /// flags from `settings`; what the project does not hold (layer 3's size
    /// without a layer-3 plane, settings when absent) is the base entry's.
    public static func props(_ m: GameMap, base: CTMapROM.Props) throws -> CTMapROM.Props {
        func fail(_ s: String) -> CTROMBuildError { CTROMBuildError("map \(m.id): \(s)") }
        func layer(_ k: Int) -> GameMap.Layer? { m.layers.first { $0.bg == k } }
        guard m.layers.allSatisfy({ (1...3).contains($0.bg) }), Set(m.layers.map(\.bg)).count == m.layers.count else {
            throw fail("layers must be BG1, BG2 and BG3 at most once each")
        }
        guard let l1 = layer(1), let l2 = layer(2) else { throw fail("a location map has layers 1 and 2") }
        let sides = [16, 32, 48, 64]
        func size(_ l: GameMap.Layer) throws -> CTMapROM.Size {
            let s = CTMapROM.Size(width: l.width ?? m.width, height: l.height ?? m.height)
            guard sides.contains(s.width), sides.contains(s.height) else {
                throw fail("layer \(l.bg) is \(s.width) x \(s.height); each side is 16, 32, 48 or 64")
            }
            guard l.metatiles.count == s.cells else { throw fail("layer \(l.bg) has \(l.metatiles.count) cells, not \(s.cells)") }
            return s
        }
        let s1 = try size(l1), s2 = try size(l2), s3 = try layer(3).map(size)
        guard (s1.width, s1.height) == (m.width, m.height) else { throw fail("layer 1 is not the map's size") }
        let settings = m.settings ?? .init(screens: base.screens, colorMath: base.colorMath, move2: base.move2, move3: base.move3,
                                           halfRate2: base.halfRate2, ownStep2: base.ownStep2, ownStep3: base.ownStep3)
        for (name, v) in [("screens", settings.screens), ("colorMath", settings.colorMath), ("move2", settings.move2),
                          ("move3", settings.move3)] where !(0...0xFF).contains(v) {
            throw fail("settings.\(name) \(v) is not a byte")
        }
        let code1 = (s1.width / 16 - 1) | (s1.height / 4 - 4)
        let code3 = s3.map { ($0.width / 16 - 1) | ($0.height / 4 - 4) } ?? base.size3 & 0x0F
        let size1 = code1 | (s2.width - 16) | (s2.height - 16) * 4
        let size3 = code3 | (settings.ownStep2 ? 0x10 : 0) | (settings.ownStep3 ? 0x20 : 0)
            | (settings.halfRate2 ? 0x40 : 0) | (s3 == nil ? 0 : 0x80)
        guard let tp = m.tileProps, let plane = CTTilePropsPlane(tp), (tp.width, tp.height) == (s1.width, s1.height) else {
            throw fail("tileProps must be three hex planes over layer 1 (\(s1.width) x \(s1.height))")
        }
        if let i = plane.hiBits.firstIndex(where: { $0 & 0x80 != 0 }) {
            throw fail("tile \(i): HiBits bit 7 starts a run in MapProps; the shape is at most $1F")
        }
        let p1 = l1.metatiles, p2 = l2.metatiles
        for (i, v) in p1.enumerated() {
            guard (0..<512).contains(v) else { throw fail("layer 1 cell \(i): metatile \(v) is not 0-511") }
            guard (v >> 8 == 1) == (plane.hiBits[i] & 1 != 0) else {
                throw fail("layer 1 cell \(i): metatile bit 8 and HiBits bit 0 disagree")
            }
        }
        for (i, v) in p2.enumerated() {
            guard (0..<512).contains(v) else { throw fail("layer 2 cell \(i): metatile \(v) is not 0-511") }
            let r = i / s2.width, c = i % s2.width
            let bit = r < s1.height && c < s1.width ? plane.hiBits[r * s1.width + c] >> 1 & 1 : 0
            guard v >> 8 == Int(bit) else {
                throw fail("layer 2 cell \(i): metatile bit 8 must be HiBits bit 1 of the layer-1 tile (0 outside layer 1)")
            }
        }
        if let l3 = layer(3), let v = l3.metatiles.first(where: { !(0..<256).contains($0) }) {
            throw fail("layer 3 metatile \(v) is not 0-255")
        }
        var planes = [1: p1, 2: p2]
        if let l3 = layer(3) { planes[3] = l3.metatiles }
        return CTMapROM.Props(size1: size1, size3: size3, move2: settings.move2, move3: settings.move3,
                              screens: settings.screens, colorMath: settings.colorMath,
                              sizes: CTMapROM.layerSizes(size1: size1, size3: size3), layer3Plane: s3 != nil,
                              halfRate2: settings.halfRate2, ownStep2: settings.ownStep2, ownStep3: settings.ownStep3,
                              planes: planes, hiBits: plane.hiBits, attrA: plane.attrA, attrB: plane.attrB)
    }

    /// What two MapProps images mean to Map_UnpackTilePlanes (their run splits aside).
    static func sameContent(_ a: CTMapROM.Props, _ b: CTMapROM.Props) -> Bool {
        (a.size1, a.size3, a.move2, a.move3, a.screens, a.colorMath) == (b.size1, b.size3, b.move2, b.move3, b.screens, b.colorMath)
            && a.planes == b.planes && a.hiBits == b.hiBits && a.attrA == b.attrA && a.attrB == b.attrB
    }

    /// The 14 LocRom bytes of a map's `location` (the base record's when absent), naming `entry`.
    public static func record(_ m: GameMap, base: CTMapROM.Header, entry: Int) throws -> [UInt8] {
        let l = m.location ?? .init(music: base.music, tileset12: base.tileset12, tileset3: base.tileset3, palette: base.palette,
                                    events: base.events, unk06: base.unk06, limits: base.limits)
        func fail(_ s: String) -> CTROMBuildError { CTROMBuildError("map \(m.id): location.\(s)") }
        guard (0...0xFF).contains(l.music) else { throw fail("music \(l.music) is not a byte") }
        guard l.tileset12 == CTMapROM.none || (0..<64).contains(l.tileset12) else { throw fail("tileset12 \(l.tileset12) is not 0-63 or 255") }
        guard l.tileset3 == CTMapROM.none || (0..<32).contains(l.tileset3) else { throw fail("tileset3 \(l.tileset3) is not 0-31 or 255") }
        guard (0..<88).contains(l.palette) else { throw fail("palette \(l.palette) is not 0-87") }
        guard (0..<CTEventROM.pointerCount).contains(l.events) else { throw fail("events \(l.events) is not 0-512") }
        guard (0...0xFFFF).contains(l.unk06) else { throw fail("unk06 \(l.unk06) is not 16-bit") }
        guard l.limits.count == 4, l.limits.allSatisfy({ (0...0xFF).contains($0) }) else { throw fail("limits must be 4 bytes") }
        let header = CTMapROM.Header(at: base.at, music: l.music, tileset12: l.tileset12, tileset3: l.tileset3,
                                     palette: l.palette, mapProps: entry, unk06: l.unk06, events: l.events, limits: l.limits)
        guard m.tileset == CTMaps.tilesetID(header) else {
            throw CTROMBuildError("map \(m.id): its tileset \(m.tileset) is not the one its location record loads (\(CTMaps.tilesetID(header)))")
        }
        return [l.music, l.tileset12, l.tileset3, l.palette, entry & 0xFF, entry >> 8, l.unk06 & 0xFF, l.unk06 >> 8,
                l.events & 0xFF, l.events >> 8].map { UInt8($0) } + l.limits.map { UInt8($0) }
    }

    /// The 7 ExitRom bytes of a project exit (destinations are `loc_NNN`).
    public static func exitBytes(_ e: GameMap.Exit, map: String) throws -> [UInt8] {
        func fail(_ s: String) -> CTROMBuildError { CTROMBuildError("map \(map): exit at \(e.x),\(e.y): \(s)") }
        guard e.map.hasPrefix("loc_"), let dest = Int(e.map.dropFirst(4)), (0..<CTMapROM.locCount).contains(dest) else {
            throw fail("destination \(e.map) is not loc_000-loc_511")
        }
        for (name, v, top) in [("x", e.x, 0xFF), ("y", e.y, 0xFF), ("toX", e.toX, 0xFF), ("toY", e.toY, 0xFF),
                               ("span", e.span ?? 0, 0x7F), ("facing", e.facing ?? 0, 0x0F)] where !(0...top).contains(v) {
            throw fail("\(name) \(v) is not 0-\(top)")
        }
        var r = CTMapROM.ExitRecord(raw: [0, 0, 0, 0, 0, 0, 0])
        r.x = e.x; r.y = e.y; r.span = e.span ?? 0; r.vertical = e.vertical ?? false
        r.dest = dest; r.facing = e.facing ?? 0; r.destFlag = e.facingBit7 ?? false; r.destX = e.toX; r.destY = e.toY
        return r.raw
    }

    /// ExitRom with every location's records: 513 words of bank-$E5 offsets, then the records.
    public static func exitBlock(_ records: [[[UInt8]]]) -> [UInt8] {
        var words: [Int] = [], body: [UInt8] = []
        for list in records {
            words.append(2 * exitWords + body.count)
            for r in list { body += r }
        }
        words.append(2 * exitWords + body.count)
        return words.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] } + body
    }

    /// The base ROM's ExitRom block (offset words through the last record).
    public static func baseExitBlock(_ rom: [UInt8]) -> [UInt8] {
        let end = CTMapROM.u16(rom, CTMapROM.exitOfs + 2 * CTMapROM.locCount)
        let pc = CTMapROM.pc(exitBlock)
        return Array(rom[pc..<(pc + end)])
    }

    /// The checks a build makes that need no ROM: sizes, metatile ranges and
    /// bit 8, tile properties, the location record's ranges, exits (the
    /// validator's gate 4; the build adds the checks against the base ROM).
    public static func validate(_ m: GameMap) -> [String] {
        var problems: [String] = []
        guard let loc = m.rom?.location, (0..<CTMapROM.locCount).contains(loc) else {
            return ["no rom.location: maps are written over the location they were imported from"]
        }
        let base = CTMapROM.Props(size1: 0, size3: 0, move2: 0, move3: 0, screens: 0, colorMath: 0, sizes: [],
                                  layer3Plane: false, halfRate2: false, ownStep2: false, ownStep3: false,
                                  planes: [:], hiBits: [], attrA: [], attrB: [])
        do { _ = try props(m, base: base) } catch { problems.append("\(error)") }
        if let l = m.location {
            let header = CTMapROM.Header(at: 0, music: l.music, tileset12: l.tileset12, tileset3: l.tileset3, palette: l.palette,
                                         mapProps: 0, unk06: l.unk06, events: l.events, limits: l.limits)
            do { _ = try record(m, base: header, entry: 0) } catch { problems.append("\(error)") }
        }
        for e in m.exits { do { _ = try exitBytes(e, map: m.id) } catch { problems.append("\(error)") } }
        for (k, t) in (m.treasure ?? []).enumerated() where !(0...0xFF).contains(t.x) || !(0...0xFF).contains(t.y)
            || !(0...0xFFFF).contains(t.contents) || (k == 0 && t.x | t.y == 0) {
            problems.append("treasure \(k) is out of range (a first record on tile 0,0 is a redirect)")
        }
        return problems
    }

    // MARK: The build

    /// Writes the listed maps into `rom` (the builder's copy of the base),
    /// placing packs through `space` and recording every write with `write`
    /// and every moved block with `relocated`.
    static func apply(maps: [GameMap], base: [UInt8], space: inout FreeSpace,
                      write: ([UInt8], Int, String) -> Void,
                      relocated: (String, Int?, Int, Int) -> Void) throws -> [ReportMap] {
        // Each listed map: its location, the base decode, the new MapProps and whether it changed.
        struct Item { var map: GameMap; var loc: Int; var base: CTMapROM.Decoded; var image: [UInt8]?; var props: CTMapROM.Props }
        var items: [Item] = [], seen = Set<Int>()
        for m in maps {
            guard let loc = m.rom?.location, (0..<CTMapROM.locCount).contains(loc) else {
                throw CTROMBuildError("map \(m.id): no rom.location; maps are written over the location they were imported from")
            }
            guard seen.insert(loc).inserted else { throw CTROMBuildError("map \(m.id): location \(loc) is built twice") }
            let d: CTMapROM.Decoded
            do { d = try CTMapROM.decode(base, loc) } catch { throw CTROMBuildError("map \(m.id): \(error)") }
            let p = try props(m, base: d.props)
            let image = CTMapROM.packProps(p)
            let back = try CTMapROM.parseProps(image)
            guard sameContent(back, p) else { throw CTROMBuildError("map \(m.id): MapProps does not unpack to the map") }
            items.append(Item(map: m, loc: loc, base: d, image: sameContent(back, d.props) ? nil : image, props: back))
        }

        // Entries: the users of each entry that a changed map leaves.
        let heads = (0..<CTMapROM.locCount).map { CTMapROM.header(base, $0) }
        var usersOf: [Int: [Int]] = [:]
        for (i, h) in heads.enumerated() { usersOf[h.mapProps, default: []].append(i) }
        let wanted = Dictionary(uniqueKeysWithValues: items.map { ($0.loc, $0.image) })
        var entryOf: [Int: Int] = [:]                          // location -> final entry
        var images: [(entry: Int, image: [UInt8], mode: LZSSMode, home: Range<Int>?, newSlot: Bool, users: [Int])] = []
        var slots = freeSlots(base)
        for (entry, users) in usersOf.sorted(by: { $0.key < $1.key }) {
            let changed = users.filter { wanted[$0] ?? nil != nil }
            guard !changed.isEmpty else { continue }
            let first = items.first { $0.loc == changed[0] }!.base
            let home = CTMapROM.pc(first.at)..<(CTMapROM.pc(first.at) + first.packedBytes)
            var groups: [[UInt8]: [Int]] = [:], order: [[UInt8]] = []
            for u in users {
                guard let image = wanted[u] ?? nil else { continue }
                if groups[image] == nil { order.append(image) }
                groups[image, default: []].append(u)
            }
            let keepsBase = users.contains { wanted[$0] ?? nil == nil }
            for (k, image) in order.enumerated() {
                if k == 0 && !keepsBase {
                    images.append((entry, image, first.mode, home, false, groups[image]!))
                    continue
                }
                guard !slots.isEmpty else {
                    throw CTROMBuildError("map \(CTMaps.id(groups[image]![0])): its entry \(entry) is shared and no Map_PropsPtrs slot is free")
                }
                let slot = slots.removeFirst()
                images.append((slot, image, first.mode, nil, true, groups[image]!))
                for u in groups[image]! { entryOf[u] = slot }
            }
        }

        // Place each image: in its own old span first, then reclaimed, then free space.
        var placedAt: [Int: (pc: Int, packed: Int, placement: String)] = [:]
        for img in images {
            guard let packed = LZSS.compress(img.image, mode: img.mode) else {
                throw CTROMBuildError("map entry \(img.entry): MapProps does not pack")
            }
            let what = "MapProps entry \(img.entry)"
            let (pc, placement) = try CTROMBuilder.placeBlock(packed, home: img.home, space: &space, what: what)
            write(packed, pc, what)
            write([UInt8(pc & 0xFF), UInt8(pc >> 8 & 0xFF), UInt8(0xC0 | pc >> 16)],
                  CTMapROM.pc(CTMapROM.propsPtrs) + 3 * img.entry, "Map_PropsPtrs[\(img.entry)]")
            if placement != "original" { relocated(what, img.home?.lowerBound, pc, packed.count) }
            placedAt[img.entry] = (pc, packed.count, img.newSlot ? "free slot, " + placement : placement)
        }

        // LocRom records in place.
        var records: [Int: [UInt8]] = [:]
        for it in items {
            let entry = entryOf[it.loc] ?? it.base.header.mapProps
            let bytes = try record(it.map, base: it.base.header, entry: entry)
            records[it.loc] = bytes
            write(bytes, CTMapROM.pc(it.base.header.at), "LocRom[\(it.loc)]")
        }

        // Exits: every location's list; the block is rewritten when one changed.
        var exitLists = (0..<CTMapROM.locCount).map { i in CTMapROM.exitRecords(base, i).map(\.raw) }
        for it in items {
            let old = CTMaps.gameMap(it.base).exits
            guard it.map.exits != old else { continue }
            exitLists[it.loc] = try it.map.exits.map { try exitBytes($0, map: it.map.id) }
        }
        let block = exitBlock(exitLists), oldBlock = baseExitBlock(base)
        if block != oldBlock {
            let start = CTMapROM.pc(exitBlock)
            guard block.count <= 0x10000 else { throw CTROMBuildError("the exits no longer fit bank $E5") }
            if block.count > oldBlock.count {
                // The growth must be the confirmed padding right after the block.
                guard space.allocateSpanning(block.count - oldBlock.count, at: start + oldBlock.count) else {
                    throw CTROMBuildError("the exits grow by \(block.count - oldBlock.count) bytes past ExitRom; " +
                                          "the free space after it is smaller")
                }
            }
            write(block, start, "ExitRom")
        }

        // Treasure: each list's records in place (a count change renumbers every later chest's flag).
        var lists: [Int: (map: String, records: [GameMap.Treasure])] = [:]
        for it in items {
            let old = it.base.treasure.map { GameMap.Treasure(x: $0.x, y: $0.y, contents: $0.contents) }
            let new = it.map.treasure ?? old
            guard new != old else { continue }
            guard new.count == old.count else {
                throw CTROMBuildError("map \(it.map.id): \(new.count) treasure records instead of \(old.count); a chest's flag " +
                                      "is its number in TreasureRom, so adding or removing one renumbers every later chest")
            }
            if let other = lists[it.base.treasureList], other.records != new {
                throw CTROMBuildError("map \(it.map.id): it shares location \(it.base.treasureList)'s treasure list with " +
                                      "\(other.map), which lists other treasure")
            }
            for (k, t) in new.enumerated() {
                guard (0...0xFF).contains(t.x), (0...0xFF).contains(t.y), (0...0xFFFF).contains(t.contents) else {
                    throw CTROMBuildError("map \(it.map.id): treasure \(k) is out of range")
                }
                guard k > 0 || t.x | t.y != 0 else {
                    throw CTROMBuildError("map \(it.map.id): a first treasure record on tile 0,0 redirects to another location")
                }
            }
            lists[it.base.treasureList] = (it.map.id, new)
            for (record, t) in zip(it.base.treasure, new) {
                let tile = t.y << 8 | t.x
                write([UInt8(tile & 0xFF), UInt8(tile >> 8), UInt8(t.contents & 0xFF), UInt8(t.contents >> 8)],
                      CTMapROM.pc(CTMapROM.treasureBank + record.offset), "TreasureRom[\(it.base.treasureList)]")
            }
        }

        return items.map { it in
            let entry = entryOf[it.loc] ?? it.base.header.mapProps
            let placed = placedAt[entry]
            let exits = exitLists[it.loc].map { $0.map(Int.init) }
            let tlist = lists[it.base.treasureList]?.records
                ?? it.base.treasure.map { GameMap.Treasure(x: $0.x, y: $0.y, contents: $0.contents) }
            let unpacked = it.image ?? CTMapROM.packProps(it.base.props)
            let shaBytes = it.image ?? (try? CTTilesetROM.unpack(base, it.base.at).out) ?? unpacked
            let pc = placed?.pc ?? CTMapROM.pc(it.base.at)
            return ReportMap(id: it.map.id, location: it.loc, entry: entry, newEntry: entryOf[it.loc] != nil,
                             address: CTROMBuilder.snes(pc), pc: pc, packedBytes: placed?.packed ?? it.base.packedBytes,
                             unpackedBytes: shaBytes.count, unpackedSHA256: CTEventPack.sha256(shaBytes),
                             placement: placed?.placement ?? "unchanged", record: records[it.loc]!.map(Int.init),
                             exits: exits, treasureList: it.base.treasureList,
                             treasure: tlist.map { [$0.x, $0.y, $0.contents] })
        }
    }
}
