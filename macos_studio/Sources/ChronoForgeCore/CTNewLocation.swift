// CTNewLocation.swift — a location created over one the game never loads
// (docs/maps.md, "New locations"). re_workspace/tools/ct_chests.py proves the
// numbers on the ROM: no exit, event warp, world-map list or world-map script
// names them, their LocRom record is the placeholder (MapProps 0, Tileset12
// 18, palette 75, no exits, no treasure) and their Events entry is not an
// event pack. A new location copies its source's map, header, exits and
// treasure; it runs the source's event pack (a new pack is a Scene Director
// slice), its MapProps takes a free Map_PropsPtrs slot as a split shared map
// does, and its chests are its own, with flags of their own.
import Foundation

public enum CTNewLocation {
    /// The location numbers the game never loads (ct_chests.py `unused-locations` re-derives them).
    public static let unused = [448, 452, 453, 454, 455, 461, 462, 463]

    /// Why `number` cannot be created from location `from`, if it cannot.
    public static func problems(number: Int, from: Int) -> [String] {
        var out: [String] = []
        if !unused.contains(number) {
            out.append("location \(number) is not one the game never loads (\(unused.map(String.init).joined(separator: ", ")))")
        }
        if !(0..<CTMapROM.destWorld).contains(from) || unused.contains(from) {
            out.append("the source \(from) must be a field location the game loads (0-\(CTMapROM.destWorld - 1))")
        }
        return out
    }

    /// The map of location `number` made from `source`, a map imported from the ROM.
    public static func make(from source: GameMap, number: Int, name: String? = nil) throws -> GameMap {
        guard let r = source.rom, r.createdFrom == nil else {
            throw CTROMBuildError("map \(source.id): create a location from a map imported from the ROM")
        }
        if let problem = problems(number: number, from: r.location).first { throw CTROMBuildError(problem) }
        var m = source
        m.id = CTMaps.id(number)
        m.name = name ?? "Location \(number) (from \(source.id))"
        m.rom = .init(location: number, record: CTMapROM.snes(CTMapROM.locRom + CTMapROM.locBytes * number),
                      mapProps: r.mapProps, packedAt: r.packedAt, packedBytes: r.packedBytes, unpackedBytes: r.unpackedBytes,
                      staleTiles: r.staleTiles, exitsAt: nil, treasureList: number, treasureAt: nil, createdFrom: r.location)
        return m
    }

    /// An exit at (x, y) of `map` leading to `target`'s tile (toX, toY).
    public static func addEntrance(_ map: inout GameMap, x: Int, y: Int, to target: String, toX: Int, toY: Int,
                                   facing: Int = 0) {
        map.exits.append(GameMap.Exit(x: x, y: y, map: target, toX: toX, toY: toY, span: 0, vertical: false,
                                      facing: facing, facingBit7: false))
    }

    public struct Entrance: Sendable {
        public var map: String, x: Int, y: Int, toX: Int, toY: Int, facing: Int
        public init(map: String, x: Int, y: Int, toX: Int, toY: Int, facing: Int = 0) {
            self.map = map; self.x = x; self.y = y; self.toX = toX; self.toY = toY; self.facing = facing
        }
    }

    /// Creates location `number` from map `sourceID` in the project, with an entrance on another map when
    /// given, and (with `list`) lists both in rom.maps. Returns the ids written.
    @discardableResult
    public static func create(in project: inout CTProject, from sourceID: String, number: Int,
                              entrance: Entrance? = nil, name: String? = nil, list: Bool = false) throws -> [String] {
        guard let source = project.maps[sourceID] else { throw CTROMBuildError("no map \(sourceID)") }
        let id = CTMaps.id(number)
        if let old = project.maps[id], old.rom?.createdFrom != nil {
            throw CTROMBuildError("\(id) was already created (from loc_\(String(format: "%03d", old.rom!.createdFrom!)))")
        }
        let m = try make(from: source, number: number, name: name)
        project.maps[id] = m
        var ids = [id]
        if let e = entrance {
            guard var at = project.maps[e.map], at.rom != nil else { throw CTROMBuildError("no ROM map \(e.map) for the entrance") }
            guard (0..<at.width).contains(e.x), (0..<at.height).contains(e.y), (0..<m.width).contains(e.toX),
                  (0..<m.height).contains(e.toY) else {
                throw CTROMBuildError("the entrance at \(e.x),\(e.y) of \(e.map) or its arrival \(e.toX),\(e.toY) is off the map")
            }
            addEntrance(&at, x: e.x, y: e.y, to: id, toX: e.toX, toY: e.toY, facing: e.facing)
            project.maps[e.map] = at
            ids.append(e.map)
        }
        if list {
            var spec = project.project.rom ?? Project.ROMBuild()
            for i in ids where !spec.maps.contains(i) { spec.maps.append(i) }
            project.project.rom = spec
        }
        return ids
    }
}
