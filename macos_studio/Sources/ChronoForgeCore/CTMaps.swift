// CTMaps.swift — Chrono Trigger location maps: the LocRom header, MapProps
// (sizes, screens, colour math, own steps), the three tile planes, the
// tile-property planes, exits and treasure; the project import and verify.
// The Python reference with the evidence for every field is
// re_workspace/tools/ct_maps.py (docs/maps.md).
import Foundation

public enum CTMapROM {
    public static let locRom = CTTilesetROM.locRom, locCount = CTTilesetROM.locCount, locBytes = CTTilesetROM.locBytes
    public static let none = CTTilesetROM.none
    public static let propsPtrs = 0xF61E00, propsCount = 256          // Map_PropsPtrs
    public static let exitOfs = 0xE50000, exitBytes = 7                // ExitRom_LocOfs; records in bank $E5
    public static let treasureOfs = 0xF5F000, treasureBank = 0xF50000, treasureBytes = 4
    public static let limitsNone = 0x80                                // LocRom.LimitLeft bit 7
    public static let runFlag = 0x80                                   // a HiBits byte starting a run
    public static let exitNone = 0x80, treasureNone = 0x80             // Map_TileExitIdx / Map_TreasureIdx: none
    public static let destWorld = 0x1F0                                // destinations from here: no LocRom map
    /// Ppu_SetBgLayout: mode 1 with BG3 high, BG1/2 characters at $1000, BG3's
    /// at $5000, colour math adds the sub screen, COLDATA black.
    public static let bgmode: UInt8 = 0x09, bg12nba: UInt8 = 0x11, bg34nba: UInt8 = 0x05
    public static let cgwsel: UInt8 = 0x02, coldata: UInt8 = 0xE0
    /// LocLoad_DrawMap's tilemaps (Map_VramTilemap1/2/3), 64x32 (Map_ScSizeInit).
    public static let tilemaps = [0x6000, 0x6800, 0x7000]

    static func pc(_ long: Int) -> Int { CTSpriteROM.pc(long) }
    public static func snes(_ long: Int) -> String { CTSpriteROM.snes(long) }
    static func u8(_ rom: [UInt8], _ long: Int) -> Int { Int(rom[pc(long)]) }
    static func u16(_ rom: [UInt8], _ long: Int) -> Int { u8(rom, long) | u8(rom, long + 1) << 8 }
    static func u24(_ rom: [UInt8], _ long: Int) -> Int { u16(rom, long) | u8(rom, long + 2) << 16 }

    // MARK: Header

    public struct Header: Equatable, Sendable {
        public var at: Int, music: Int, tileset12: Int, tileset3: Int, palette: Int
        public var mapProps: Int, unk06: Int, events: Int
        public var limits: [Int]                       // left, top, right, bottom (raw)
    }

    public static func header(_ rom: [UInt8], _ i: Int) -> Header {
        let at = locRom + locBytes * i
        let b = (0..<locBytes).map { u8(rom, at + $0) }
        return Header(at: at, music: b[0], tileset12: b[1], tileset3: b[2], palette: b[3], mapProps: b[4] | b[5] << 8,
                      unk06: b[6] | b[7] << 8, events: b[8] | b[9] << 8, limits: Array(b[10..<14]))
    }

    public struct Size: Equatable, Sendable, Codable {
        public var width: Int, height: Int
        public init(width: Int, height: Int) { self.width = width; self.height = height }
        public var cells: Int { width * height }
    }

    /// Layers 1-3 in metatiles (LocLoad_UnkA33B): index 0 is layer 1.
    public static func layerSizes(size1: Int, size3: Int) -> [Size] {
        [Size(width: ((size1 & 3) + 1) * 16, height: ((size1 & 0x0C) + 4) * 4),
         Size(width: (size1 & 0x30) + 0x10, height: ((size1 & 0xC0) >> 2) + 0x10),
         Size(width: ((size3 & 3) + 1) * 16, height: ((size3 & 0x0C) + 4) * 4)]
    }

    /// Map_InitMasksAndLimits: 48 and 64 wrap at 64, 32 at 32, else 16.
    public static func wrapMask(_ n: Int) -> Int { n == 0x30 || n == 0x40 ? 0x3F : n == 0x20 ? 0x1F : 0x0F }

    /// The per-frame (X, Y) step of a Move2/Move3 byte.
    public static func ownStep(_ byte: Int) -> (x: Int, y: Int) {
        func one(_ n: Int, _ negative: Bool) -> Int { n == 0 ? 0 : (negative ? -(1 << (n - 1)) : 1 << (n - 1)) }
        return (one(byte & 7, byte & 8 != 0), one(byte >> 4 & 7, byte & 0x80 != 0))
    }

    /// TM, TS and CGADSUB as LocLoad_UnkA33B makes them: with no Tileset3
    /// loaded (Field_UnkBB) only BG1, BG2 and OBJ stay.
    public static func screens(_ screens: Int, colorMath: Int, tileset3: Int) -> (tm: UInt8, ts: UInt8, cgadsub: UInt8) {
        var tm = (screens & 7) | (screens & 8) << 1, ts = (screens >> 4 & 7) | (screens & 0x80) >> 3
        if tileset3 == none { tm &= 0x13; ts &= 0x13 }
        return (UInt8(tm), UInt8(ts), UInt8(colorMath & 0xFF))
    }

    // MARK: MapProps

    public struct Props: Equatable, Sendable {
        public var size1: Int, size3: Int, move2: Int, move3: Int, screens: Int, colorMath: Int
        public var sizes: [Size]
        public var layer3Plane: Bool, halfRate2: Bool, ownStep2: Bool, ownStep3: Bool
        /// Metatile numbers per layer (1-3), row-major; bit 8 of layers 1/2 from HiBits.
        public var planes: [Int: [Int]]
        public var hiBits: [UInt8], attrA: [UInt8], attrB: [UInt8]
        public var entries = 0, runs = 0, used = 0, length = 0, staleTiles = 0
    }

    public struct MapError: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Map_UnpackTilePlanes over an unpacked MapProps image. A map that ends
    /// before its triples cover layer 1 makes the game read WRAM past it: those
    /// last `staleTiles` are decoded from zeros, as ct_maps.py does.
    public static func parseProps(_ image: [UInt8]) throws -> Props {
        guard image.count >= 6 else { throw MapError("MapProps shorter than its header") }
        let s1 = Int(image[0]), s3 = Int(image[1])
        let sizes = layerSizes(size1: s1, size3: s3)
        var p = Props(size1: s1, size3: s3, move2: Int(image[2]), move3: Int(image[3]), screens: Int(image[4]),
                      colorMath: Int(image[5]), sizes: sizes, layer3Plane: s3 & 0x80 != 0, halfRate2: s3 & 0x40 != 0,
                      ownStep2: s3 & 0x10 != 0, ownStep3: s3 & 0x20 != 0, planes: [:], hiBits: [], attrA: [], attrB: [])
        var at = 6
        for layer in 1...3 where layer != 3 || p.layer3Plane {
            let n = sizes[layer - 1].cells
            guard at + n <= image.count else { throw MapError("layer \(layer) plane runs past the data") }
            p.planes[layer] = image[at..<(at + n)].map(Int.init)
            at += n
        }
        let n = sizes[0].cells, end = image.count
        let data = image + [UInt8](repeating: 0, count: 4 * n)
        var stale: Int?
        p.hiBits.reserveCapacity(n); p.attrA.reserveCapacity(n); p.attrB.reserveCapacity(n)
        while p.hiBits.count < n {
            if at >= end && stale == nil { stale = p.hiBits.count }
            let first = Int(data[at])
            if first & runFlag != 0 {
                if at + 4 > end && stale == nil { stale = p.hiBits.count }
                let count = data[at + 3] == 0 ? 256 : Int(data[at + 3])
                let take = min(count, n - p.hiBits.count)        // the routine returns mid-run at the plane's end
                p.hiBits += [UInt8](repeating: UInt8(first & 0x7F), count: take)
                p.attrA += [UInt8](repeating: data[at + 1], count: take)
                p.attrB += [UInt8](repeating: data[at + 2], count: take)
                at += 4
                p.runs += 1
            } else {
                if at + 3 > end && stale == nil { stale = p.hiBits.count }
                p.hiBits.append(UInt8(first)); p.attrA.append(data[at + 1]); p.attrB.append(data[at + 2])
                at += 3
            }
            p.entries += 1
        }
        let w1 = sizes[0].width, w2 = sizes[1].width
        for r in 0..<sizes[0].height {
            for c in 0..<w1 { p.planes[1]![r * w1 + c] |= Int(p.hiBits[r * w1 + c] & 1) << 8 }
        }
        for r in 0..<min(sizes[0].height, sizes[1].height) {
            for c in 0..<min(w1, w2) { p.planes[2]![r * w2 + c] |= Int(p.hiBits[r * w1 + c] >> 1 & 1) << 8 }
        }
        p.used = min(at, end)
        p.length = end
        p.staleTiles = stale.map { n - $0 } ?? 0
        return p
    }

    /// An unpacked MapProps image of `p`: header, planes, then the triples with
    /// a run for each stretch of 2+ equal tiles (up to 256). One valid encoding;
    /// the ROM's own may split its runs differently.
    public static func packProps(_ p: Props) -> [UInt8] {
        var out: [UInt8] = [p.size1, p.size3, p.move2, p.move3, p.screens, p.colorMath].map { UInt8($0 & 0xFF) }
        for layer in 1...3 { if let plane = p.planes[layer] { out += plane.map { UInt8($0 & 0xFF) } } }
        // HiBits bit 7 starts a run, so a tile cannot keep it: shapes stop at $1F.
        let hi = p.hiBits.map { $0 & 0x7F }
        var i = 0
        while i < hi.count {
            var j = i + 1
            while j < hi.count, j - i < 256, (hi[j], p.attrA[j], p.attrB[j]) == (hi[i], p.attrA[i], p.attrB[i]) { j += 1 }
            if j - i >= 2 {
                out += [hi[i] | UInt8(runFlag), p.attrA[i], p.attrB[i], UInt8((j - i) & 0xFF)]
            } else {
                out += [hi[i], p.attrA[i], p.attrB[i]]
            }
            i = j
        }
        return out
    }

    public static func propsPointer(_ rom: [UInt8], _ entry: Int) -> Int { u24(rom, propsPtrs + 3 * entry) }

    // MARK: Exits and treasure

    public struct ExitRecord: Equatable, Sendable {
        public var offset: Int
        public var x: Int, y: Int, span: Int, vertical: Bool
        public var dest: Int, facing: Int, destFlag: Bool, destX: Int, destY: Int, unusedBits: Int
        public init(offset: Int = 0, raw b: [Int]) {
            self.offset = offset
            x = b[0]; y = b[1]; span = b[2] & 0x7F; vertical = b[2] & 0x80 != 0
            dest = b[3] | (b[4] & 1) << 8; facing = b[4] >> 1 & 0x0F; destFlag = b[4] & 0x80 != 0
            destX = b[5]; destY = b[6]; unusedBits = b[4] & 0x60
        }
        public var raw: [UInt8] {
            [x, y, span | (vertical ? 0x80 : 0), dest & 0xFF, dest >> 8 & 1 | facing << 1 | unusedBits | (destFlag ? 0x80 : 0),
             destX, destY].map { UInt8($0 & 0xFF) }
        }
    }

    /// Location i's records, ExitRom_LocOfs[i] up to [i + 1].
    public static func exitRecords(_ rom: [UInt8], _ i: Int) -> [ExitRecord] {
        let first = u16(rom, exitOfs + 2 * i), end = u16(rom, exitOfs + 2 * i + 2)
        return stride(from: first, to: end, by: exitBytes).map { o in
            ExitRecord(offset: o, raw: (0..<exitBytes).map { u8(rom, exitOfs + o + $0) })
        }
    }

    /// {row << 8 | column: record} as Map_LoadExitTiles writes Map_TileExitIdx:
    /// along a row only the column wraps; down a column the row wraps. A later
    /// record overwrites an earlier one.
    public static func exitTiles(_ exits: [(x: Int, y: Int, span: Int, vertical: Bool)], colMask: Int, rowMask: Int) -> [Int: Int] {
        var out: [Int: Int] = [:]
        for (n, e) in exits.enumerated() {
            for k in 0...e.span {
                let idx = e.vertical ? ((((e.y + k) & 0xFF) << 8 | e.x) & (rowMask << 8 | colMask))
                                     : ((e.y & rowMask) << 8 | (e.x + k) & colMask)
                out[idx] = n
            }
        }
        return out
    }

    public struct TreasureRecord: Equatable, Sendable {
        public var offset: Int, tile: Int, contents: Int
        public var x: Int { tile & 0xFF }
        public var y: Int { tile >> 8 }
    }

    /// (location whose list is used, records) as Map_LoadTreasureTiles reads
    /// them: a first record with tile 0 sends it on to the list of the location
    /// in its contents word.
    public static func treasureList(_ rom: [UInt8], _ i: Int) throws -> (list: Int, records: [TreasureRecord]) {
        var loc = i, seen: Set<Int> = []
        while true {
            let first = u16(rom, treasureOfs + 2 * loc), end = u16(rom, treasureOfs + 2 * loc + 2)
            if first == end { return (loc, []) }
            if u16(rom, treasureBank + first) != 0 {
                return (loc, stride(from: first, to: end, by: treasureBytes).map {
                    TreasureRecord(offset: $0, tile: u16(rom, treasureBank + $0), contents: u16(rom, treasureBank + $0 + 2))
                })
            }
            let next = u16(rom, treasureBank + first + 2)
            guard !seen.contains(next), next < locCount else { throw MapError("treasure redirect loop at \(i)") }
            seen.insert(loc)
            loc = next
        }
    }

    public enum TreasureKind: Equatable, Sendable {
        case gold(Int), empty, item(Int)
        public init(contents c: Int) {
            self = c & 0x8000 != 0 ? .gold((c & 0x7FFF) * 2) : c & 0x4000 != 0 ? .empty : .item(c & 0x1FF)
        }
    }

    // MARK: A location

    public struct Decoded: Sendable {
        public var id: Int
        public var header: Header
        public var props: Props
        public var entry: Int, at: Int, packedBytes: Int, mode: LZSSMode
        /// The camera limits Map_InitMasksAndLimits sets (the record's, or layer 1's edges).
        public var limits: (left: Int, top: Int, right: Int, bottom: Int)
        public var masks: [(col: Int, row: Int)]
        public var steps: [(x: Int, y: Int)]           // layers 2 and 3
        public var tm: UInt8, ts: UInt8, cgadsub: UInt8
        public var exits: [ExitRecord]
        public var treasureList: Int
        public var treasure: [TreasureRecord]
        public var fromRecord: Bool { header.limits[0] & limitsNone == 0 }
    }

    public static func decode(_ rom: [UInt8], _ i: Int) throws -> Decoded {
        let h = header(rom, i)
        let at = propsPointer(rom, h.mapProps)
        let u = try CTTilesetROM.unpack(rom, at)
        let p = try parseProps(u.out)
        let s = screens(p.screens, colorMath: p.colorMath, tileset3: h.tileset3)
        let l1 = p.sizes[0]
        let lim = h.limits[0] & limitsNone != 0 ? (0, 0, l1.width - 1, l1.height - 1)
                                                : (h.limits[0], h.limits[1], h.limits[2], h.limits[3])
        let t = try treasureList(rom, i)
        return Decoded(id: i, header: h, props: p, entry: h.mapProps, at: at, packedBytes: u.length, mode: u.mode,
                       limits: lim, masks: p.sizes.map { (wrapMask($0.width), wrapMask($0.height)) },
                       steps: [ownStep(p.move2), ownStep(p.move3)], tm: s.tm, ts: s.ts, cgadsub: s.cgadsub,
                       exits: exitRecords(rom, i), treasureList: t.list, treasure: t.records)
    }
}

// MARK: - Tile properties

/// One tile's three property bytes, named as the field code reads them
/// (Map_ProbeTileLevel, Map_ProbeLevelBlocked, Map_StepTileEffects,
/// Obj_SetVelocityChecked). Bits no traced code reads stay in `raw`.
public struct CTTileProps: Equatable, Sendable {
    public var hiBits: UInt8, attrA: UInt8, attrB: UInt8
    public init(hiBits: UInt8, attrA: UInt8, attrB: UInt8) { self.hiBits = hiBits; self.attrA = attrA; self.attrB = attrB }

    /// HiBits bits 2-7: 0 half A, 1 half B, 2-$17 a sloped split, $18-$1D B in a
    /// half or quarter, $1E half A with the step cut ("stair"), $1F-$3F half A.
    public var shape: Int { Int(hiBits >> 2) }
    public var layer1Bit8: Bool { hiBits & 1 != 0 }
    public var layer2Bit8: Bool { hiBits & 2 != 0 }
    /// AttrA bits 0-1: 0 up, 1 down, 2 left, 3 right; bits 2-3 speed (0 none).
    public var pushDirection: Int { Int(attrA & 3) }
    public var pushSpeed: Int { Int(attrA >> 2 & 3) }
    /// Map_PushSlow / Mid / Fast in 1/16 pixel per frame.
    public var pushAmount: Int { [0, 0x08, 0x10, 0x20][pushSpeed] }
    public var animTrigger: Bool { attrA & 0x10 != 0 }
    /// OAM priority 3 (over the BG's high tiles) for the low / high half of a sprite.
    public var overheadLow: Bool { attrA & 0x40 != 0 }
    public var overheadHigh: Bool { attrB & 0x40 != 0 }
    /// AttrB bit 7: event-moved objects stop here.
    public var blocksObjects: Bool { attrB & 0x80 != 0 }
    /// A half's level (0 blocks, 1/2 a plane, 3 any), nil for a no-level half.
    public var levelA: Int? { attrB & 0x04 != 0 ? nil : Int(attrB & 3) }
    public var levelB: Int? { attrB & 0x20 != 0 ? nil : Int(attrB >> 3 & 3) }
    /// Whether half B exists: the shapes that name it (0 is half A alone).
    public var hasHalfB: Bool { (1...0x1D).contains(shape) }

    public static let shapeNames: [Int: String] = [0: "half A", 1: "half B", 0x18: "left B", 0x19: "top B",
                                                   0x1A: "bottom-left B", 0x1B: "bottom-right B",
                                                   0x1C: "top-right B", 0x1D: "top-left B", 0x1E: "stair"]
    public var shapeName: String { Self.shapeNames[shape] ?? ((2...0x17).contains(shape) ? "slope \(shape - 2)" : "half A") }

    /// What the painter shows for a level (Map_ProbeLevelBlocked).
    public enum Walk: String, CaseIterable, Sendable {
        case solid, plane1, plane2, transition, neutral
        public init(level: Int?) {
            switch level { case nil: self = .neutral; case 0: self = .solid; case 1: self = .plane1
                           case 2: self = .plane2; default: self = .transition }
        }
        /// AttrB bits for half A (shift 3 for half B).
        public var bits: UInt8 { [.solid: 0, .plane1: 1, .plane2: 2, .transition: 3, .neutral: 4][self]! }
    }
    public var walkA: Walk { Walk(level: levelA) }
    public var walkB: Walk { Walk(level: levelB) }
    public mutating func setWalk(_ w: Walk, halfB: Bool = false) {
        if halfB { attrB = attrB & ~0x38 | w.bits << 3 } else { attrB = attrB & ~0x07 | w.bits }
    }
    public mutating func setPush(direction: Int, speed: Int) {
        attrA = attrA & ~0x0F | UInt8(direction & 3) | UInt8(speed & 3) << 2
    }
}

/// The tile-property planes of a map as byte arrays, for editing.
public struct CTTilePropsPlane: Equatable, Sendable {
    public var width: Int, height: Int
    public var hiBits: [UInt8], attrA: [UInt8], attrB: [UInt8]

    public init(width: Int, height: Int, hiBits: [UInt8], attrA: [UInt8], attrB: [UInt8]) {
        self.width = width; self.height = height; self.hiBits = hiBits; self.attrA = attrA; self.attrB = attrB
    }
    public init?(_ t: GameMap.TileProps) {
        guard let h = Self.bytes(t.hiBits), let a = Self.bytes(t.attrA), let b = Self.bytes(t.attrB),
              h.count == t.width * t.height, a.count == h.count, b.count == h.count else { return nil }
        self.init(width: t.width, height: t.height, hiBits: h, attrA: a, attrB: b)
    }
    public var json: GameMap.TileProps {
        GameMap.TileProps(width: width, height: height, hiBits: Self.hex(hiBits), attrA: Self.hex(attrA), attrB: Self.hex(attrB))
    }
    public subscript(x: Int, y: Int) -> CTTileProps {
        get { let i = y * width + x; return CTTileProps(hiBits: hiBits[i], attrA: attrA[i], attrB: attrB[i]) }
        set { let i = y * width + x; hiBits[i] = newValue.hiBits; attrA[i] = newValue.attrA; attrB[i] = newValue.attrB }
    }

    static let digits = Array("0123456789abcdef".utf8)
    public static func hex(_ b: [UInt8]) -> String {
        var out = [UInt8](); out.reserveCapacity(b.count * 2)
        for v in b { out.append(digits[Int(v >> 4)]); out.append(digits[Int(v & 15)]) }
        return String(decoding: out, as: UTF8.self)
    }
    public static func bytes(_ s: String) -> [UInt8]? {
        let u = Array(s.utf8)
        guard u.count % 2 == 0 else { return nil }
        func nib(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: return c - 48; case 97...102: return c - 87; case 65...70: return c - 55; default: return nil }
        }
        var out = [UInt8](); out.reserveCapacity(u.count / 2)
        var i = 0
        while i < u.count {
            guard let hi = nib(u[i]), let lo = nib(u[i + 1]) else { return nil }
            out.append(hi << 4 | lo); i += 2
        }
        return out
    }
}

// MARK: - Project

public enum CTMaps {
    public static func id(_ i: Int) -> String { String(format: "loc_%03d", i) }

    /// The tileset entry a location's map names: its Tileset12, else its Tileset3.
    public static func tilesetID(_ h: CTMapROM.Header) -> String {
        h.tileset12 != CTMapROM.none ? CTTilesets.id12(h.tileset12)
            : h.tileset3 != CTMapROM.none ? CTTilesets.id3(h.tileset3) : noTileset
    }

    /// The tileset of a location with Tileset12 and Tileset3 both $FF: the game
    /// loads no BG characters (all 17 such locations are 16 x 16 of metatile 0
    /// with OBJ alone on the main screen). One chip-less metatile, no tiles.
    public static let noTileset = "t12_none"
    public static var emptyTileset: Tileset {
        Tileset(id: noTileset, bpp: 4, tileCount: 0, metatiles: [Tileset.Metatile(chips: [])], kind: "bg12")
    }

    /// A decoded location as a project map.
    public static func gameMap(_ d: CTMapROM.Decoded) -> GameMap {
        let p = d.props, h = d.header
        let layers = (1...3).compactMap { k -> GameMap.Layer? in
            guard let plane = p.planes[k] else { return nil }
            let s = p.sizes[k - 1]
            return GameMap.Layer(bg: k, metatiles: plane, width: k == 1 ? nil : s.width, height: k == 1 ? nil : s.height)
        }
        let exits = d.exits.map {
            GameMap.Exit(x: $0.x, y: $0.y, map: id($0.dest), toX: $0.destX, toY: $0.destY, span: $0.span,
                         vertical: $0.vertical, facing: $0.facing, facingBit7: $0.destFlag)
        }
        let props = CTTilePropsPlane(width: p.sizes[0].width, height: p.sizes[0].height,
                                     hiBits: p.hiBits, attrA: p.attrA, attrB: p.attrB)
        return GameMap(id: id(d.id), name: String(format: "Location %03d", d.id), tileset: tilesetID(h),
                       width: p.sizes[0].width, height: p.sizes[0].height, layers: layers, exits: exits, triggers: [],
                       location: .init(music: h.music, tileset12: h.tileset12, tileset3: h.tileset3, palette: h.palette,
                                       events: h.events, unk06: h.unk06, limits: h.limits),
                       settings: .init(screens: p.screens, colorMath: p.colorMath, move2: p.move2, move3: p.move3,
                                       halfRate2: p.halfRate2, ownStep2: p.ownStep2, ownStep3: p.ownStep3),
                       tileProps: props.json,
                       treasure: d.treasure.map { GameMap.Treasure(x: $0.x, y: $0.y, contents: $0.contents) },
                       rom: .init(location: d.id, record: CTMapROM.snes(h.at), mapProps: d.entry,
                                  packedAt: CTMapROM.snes(d.at), packedBytes: d.packedBytes, unpackedBytes: p.length,
                                  staleTiles: p.staleTiles,
                                  exitsAt: d.exits.first.map { CTMapROM.snes(CTMapROM.exitOfs + $0.offset) },
                                  treasureList: d.treasureList,
                                  treasureAt: d.treasure.first.map { CTMapROM.snes(CTMapROM.treasureBank + $0.offset) }))
    }

    /// Every location (or the ones given) into the project as maps/loc_NNN, with
    /// the tilesets and palettes they use that the project lacks. A reimport
    /// keeps a map's name and triggers.
    @discardableResult
    public static func importMaps(rom input: [UInt8], into project: inout CTProject, locations: [Int]? = nil) throws -> [String] {
        var rom = input
        if rom.count == CTROMBuilder.romSize + 512 { rom.removeFirst(512) }
        guard rom.count == CTROMBuilder.romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("maps import needs the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        return try importDecoded(rom: rom, into: &project, locations: locations)
    }

    /// The import without the ROM check (the tests feed it synthetic images).
    public static func importDecoded(rom: [UInt8], into project: inout CTProject, locations: [Int]? = nil,
                                     tilesets: Bool = true) throws -> [String] {
        let picks = locations ?? Array(0..<CTMapROM.locCount)
        var ids: [String] = []
        var need12: Set<Int> = [], need3: Set<Int> = [], needPal: Set<Int> = []
        for i in picks {
            var m = gameMap(try CTMapROM.decode(rom, i))
            if project.maps[m.id]?.rom?.createdFrom != nil { continue }        // a created location stays (CTNewLocation)
            if let old = project.maps[m.id] { m.name = old.name; m.triggers = old.triggers }
            project.maps[m.id] = m
            ids.append(m.id)
            let h = CTMapROM.header(rom, i)
            if h.tileset12 != CTMapROM.none, project.tilesets[CTTilesets.id12(h.tileset12)] == nil { need12.insert(h.tileset12) }
            if h.tileset3 != CTMapROM.none, project.tilesets[CTTilesets.id3(h.tileset3)] == nil { need3.insert(h.tileset3) }
            if project.tilesets[CTTilesets.idPalette(h.palette)] == nil { needPal.insert(h.palette) }
            if tilesets, m.tileset == noTileset, project.tilesets[noTileset] == nil { project.tilesets[noTileset] = emptyTileset }
        }
        if tilesets, !(need12.isEmpty && need3.isEmpty && needPal.isEmpty) {
            try CTTilesets.importDecoded(rom: rom, into: &project, tileset12: need12.sorted(), tileset3: need3.sorted(),
                                         palettes: needPal.sorted())
        }
        return ids
    }

    /// The project's maps that came from the ROM against a fresh decode, plus
    /// the structural invariants of every map: the problems found.
    public static func verify(rom: [UInt8], project: CTProject) throws -> (checked: Int, problems: [String]) {
        var problems: [String] = [], checked = 0
        for (id, m) in project.maps.sorted(by: { $0.key < $1.key }) {
            problems += LocationScene.invariants(m, project: project).map { "\(id): \($0)" }
            guard let i = m.rom?.location, m.rom?.createdFrom == nil else { continue }
            checked += 1
            var want = gameMap(try CTMapROM.decode(rom, i))
            want.name = m.name; want.triggers = m.triggers
            if want == m { continue }
            for (field, same) in [("layers", want.layers == m.layers), ("size", (want.width, want.height) == (m.width, m.height)),
                                  ("exits", want.exits == m.exits), ("tile properties", want.tileProps == m.tileProps),
                                  ("location", want.location == m.location), ("settings", want.settings == m.settings),
                                  ("treasure", want.treasure == m.treasure), ("tileset", want.tileset == m.tileset),
                                  ("rom", want.rom == m.rom)] where !same {
                problems.append("\(id): \(field) differ from the ROM")
            }
        }
        return (checked, problems)
    }
}
