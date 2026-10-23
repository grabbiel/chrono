// CTNPCSpritePatch.swift — `rom.sprites` entries of family ct-npc (docs/sprites.md,
// "NPC write-back"). An NPC sprite keeps its record's parts and their shapes, as
// an enemy sprite does: frame records, animation rows and colours 1-12 in place,
// and its pack re-encoded with LZSS.compress in its own mode, in place when it
// fits its old span, else in confirmed free space with its $E4:2000 pointer
// rewritten. The record itself (+0 to +4) is not written.
//
// The writes go through CTEnemySpritePatch.apply with the enemy requests, so
// one sharer pass covers both families: a changed part needs every record that
// names it (NPC records 7-255 of $E4:F000, enemy records 0-254 of $E4:F600)
// listed with the same edit, and a part of a playable character's set needs
// that set's sprite. This file holds the checks without the ROM and the report.
import Foundation

public enum CTNPCSpritePatch {
    public static let family = CTNPCSpriteROM.family

    /// What the record shows after the build; the ROM checker decodes the built ROM and compares.
    public struct ReportSprite: Codable, Equatable, Sendable {
        public let id: String
        public let family: String
        public let set: Int                       // the $E4:F000 record (7-255)
        public let layout: Int                    // the size class (0 or 1)
        public let changed: [String]              // tiles, frames, animations, palette
        public let graphics: Int
        public let tiles: String                  // the $E4:2000 pointer after the build
        public let tileCount: Int
        public let tilesSHA256: String            // the unpacked tiles after the build
        public let changedTiles: [Int]
        public let pack: CTEnemySpritePatch.ReportPack?   // the record's pack when this build wrote it
        public let frameSet: Int
        public let frames: String
        public let frameCount: Int
        public let recordBytes: Int
        public let frameList: [CTSpritePatch.ReportFrame]
        public let animationSet: Int
        public let frameIds: String
        public let durations: String
        public let rows: Int
        public let stride: Int                    // frame ids per facing
        public let animations: [CTSpritePatch.ReportAnimation]
        public let paletteIndex: Int
        public let palette: String
        public let colours: [Int]                 // colours 1-12
        public let sharedWith: [String]?          // other records naming a changed part
    }

    /// Problems the write-back would refuse, from the sprite alone (the build
    /// adds the base ROM's: addresses, counts, cells past the graphics,
    /// sharers and the re-decode).
    public static func validate(_ s: SpriteDef) -> [String] {
        guard let src = s.rom else { return ["no rom source: import the ROM's sprites"] }
        guard src.family == family else { return ["rom family \(src.family) is not \(family)"] }
        guard (CTNPCSpriteROM.firstNPC..<CTSpriteROM.pointers).contains(src.set) else {
            return ["rom set \(src.set) is not an NPC record 7-255"]
        }
        let size = src.layout ?? 0
        guard let shape = CTNPCSpriteROM.layouts[size] else {
            return ["size class \(size): only classes 0 and 1 have the field builders this write-back models"]
        }
        var problems: [String] = []
        if s.bpp != 4 { problems.append("bpp \(s.bpp): the record's tiles are 4bpp") }
        if src.packed != true { problems.append("rom.packed: opcode $82 always unpacks the record's graphics") }
        let stream = SpriteDef.Stream(columns: shape.columns, rows: shape.rows, baseTile: CTNPCSpriteROM.slotTile(size: size))
        if s.stream != stream {
            problems.append("stream must be \(shape.columns) x \(shape.rows) cells at slot tile \(stream.baseTile)")
        }
        if s.frames.count != src.frameCount {
            problems.append("\(s.frames.count) frames: the frame set holds \(src.frameCount) (frames are written in place)")
        }
        for (i, f) in s.frames.enumerated() {
            let found = CTEnemySpritePatch.frameProblems(f, columns: shape.columns, rows: shape.rows, objs: shape.objs)
            problems += found.map { "frame \(i): \($0)" }
        }
        problems += CTEnemySpritePatch.paletteProblems(s)
        problems += CTSpritePatch.animationProblems(s.animations, rows: src.rows, frameCount: src.frameCount)
        let stride = src.stride ?? 4 * src.rows
        for a in s.animations {
            guard let row = a.row else { continue }
            if 4 * row + a.frames.count > stride {
                problems.append("animation \(a.id): \(a.frames.count) steps from row \(row) run past the facing's \(stride) entries")
            }
        }
        return problems
    }

    /// The PC write-back's changed parts that NPC records with a project sprite
    /// (`views`, not listed in rom.sprites) show: their files keep the old content.
    public static func staleViews(_ pcReport: [CTSpritePatch.ReportSprite], base: [UInt8], views: Set<Int>) -> [String] {
        var out: [String] = []
        for r in pcReport where !r.changed.isEmpty {
            let c = r.set
            var records: [Int: [String]] = [:]
            for name in r.changed {
                let offset: Int, value: Int
                switch name {
                case "tiles": (offset, value) = (0, c)
                case "frames": (offset, value) = (1, c)
                case "animations": (offset, value) = (3, c)
                case "palette": (offset, value) = (2, CTSpriteROM.u8(base, CTSpriteROM.sprRec + CTSpriteROM.sprRecBytes * c + 2))
                default: continue
                }
                for j in CTEnemySpritePatch.users(base, offset: offset, value: value).others where views.contains(j) {
                    records[j, default: []].append(name)
                }
            }
            for (j, names) in records.sorted(by: { $0.key < $1.key }) {
                out.append("sprite \(r.id) changes the \(names.joined(separator: ", ")) NPC record \(j) shows; " +
                           "its sprites/\(CTNPCSpriteROM.id(j)) files keep the old ones (list it in rom.sprites or re-import it)")
            }
        }
        return out
    }
}
