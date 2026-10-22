// Models.swift — Codable structs for every .ctproj document (docs/ctproj_schema.md v1).
import Foundation

// MARK: - project.json

public struct Project: Codable, Equatable, Sendable {
    public var schema: String = "ctproj/1"
    public var name: String
    public var engine: Engine
    public var start: Start
    public var eras: [Era]
    public var flags: [Flag]
    public var encounters: [Encounter]
    /// What `chronoforge rom build` writes into the base ROM (absent: nothing).
    public var rom: ROMBuild? = nil

    /// Event packs to replace in the base ROM, by Evt_PackPtrs entry (each
    /// lowered from Studio scenes or assembled from a ct-events/1 listing),
    /// songs by Audio_SongTable index (each assembled from a ct-song/1 listing),
    /// and playable characters by their `characters/<id>.json` (its `pc`
    /// record and `growth` rows; docs/characters.md).
    public struct ROMBuild: Codable, Equatable, Sendable {
        public var eventPacks: [EventPack]
        public var songs: [Song]
        public var characters: [String]
        public var techs: Bool                 // write tech_system.json's tables (absent = false)
        public struct Song: Codable, Equatable, Sendable {
            public var song: Int
            public var listing: String         // project-relative path
            public init(song: Int, listing: String) { self.song = song; self.listing = listing }
        }
        public struct EventPack: Codable, Equatable, Sendable {
            public var entry: Int
            public var scenes: [String]?
            public var listing: String?        // project-relative path
            public init(entry: Int, scenes: [String]? = nil, listing: String? = nil) {
                self.entry = entry; self.scenes = scenes; self.listing = listing
            }
        }
        public init(eventPacks: [EventPack] = [], songs: [Song] = [], characters: [String] = [], techs: Bool = false) {
            self.eventPacks = eventPacks; self.songs = songs; self.characters = characters; self.techs = techs
        }
        private enum CodingKeys: String, CodingKey { case eventPacks, songs, characters, techs }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventPacks = try c.decodeIfPresent([EventPack].self, forKey: .eventPacks) ?? []
            songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
            characters = try c.decodeIfPresent([String].self, forKey: .characters) ?? []
            techs = try c.decodeIfPresent(Bool.self, forKey: .techs) ?? false
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(eventPacks, forKey: .eventPacks)
            if !songs.isEmpty { try c.encode(songs, forKey: .songs) }
            if !characters.isEmpty { try c.encode(characters, forKey: .characters) }
            if techs { try c.encode(techs, forKey: .techs) }
        }
    }

    public struct Engine: Codable, Equatable, Sendable {
        public var base: String
        public var rom_sha256: String
    }
    public struct Start: Codable, Equatable, Sendable {
        public var map: String
        public var x: Int
        public var y: Int
        public var era: String
    }
    public struct Era: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var maps: [String]
    }
    public struct Flag: Codable, Equatable, Sendable {
        public var symbol: String
        public var bank: String
        public var addr: String
        public var bit: Int
    }
    public struct Encounter: Codable, Equatable, Sendable {
        public var id: String
        public var rate: Int
        public var enemies: [String]
    }
}

// MARK: - characters/<id>.json

public struct CharacterDef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String            // playable | npc | enemy
    public var sprite: String?
    public var level: Int?
    public var stats: Stats?
    public var palette: [String]?      // 16 BGR555 hex words
    /// A playable character's game record ($CC:0000 + id x $50), imported
    /// from the ROM and written back by `rom build` (absent: not a PC record).
    public var pc: Record? = nil
    /// Its HP, MP and stat growth rows ($CC:258A, $CC:25C2, $CC:25FA).
    public var growth: Growth? = nil

    public init(id: String, name: String, kind: String, sprite: String? = nil, level: Int? = nil,
                stats: Stats? = nil, palette: [String]? = nil, pc: Record? = nil, growth: Growth? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.sprite = sprite; self.level = level
        self.stats = stats; self.palette = palette; self.pc = pc; self.growth = growth
    }

    /// The seven stats in the record's order (+$0B-$11). Also the growth base
    /// (+$2F-$35, stored there in the growth order) and the growth per level.
    public struct StatBlock: Codable, Equatable, Sendable {
        public var power: Int
        public var stamina: Int
        public var speed: Int
        public var magic: Int
        public var hit: Int
        public var evade: Int
        public var magicDefense: Int
        public static let names = ["power", "stamina", "speed", "magic", "hit", "evade", "magicDefense"]
        public static let labels = ["Power", "Stamina", "Speed", "Magic", "Hit", "Evade", "Magic Def"]
        public init(_ values: [Int]) {
            precondition(values.count == 7)
            power = values[0]; stamina = values[1]; speed = values[2]; magic = values[3]
            hit = values[4]; evade = values[5]; magicDefense = values[6]
        }
        public var values: [Int] {
            get { [power, stamina, speed, magic, hit, evade, magicDefense] }
            set { self = StatBlock(newValue) }
        }
        public subscript(i: Int) -> Int {
            get { values[i] }
            set { var v = values; v[i] = newValue; values = v }
        }
    }

    /// The decoded, writable fields of a character record (docs/characters.md).
    public struct Record: Codable, Equatable, Sendable {
        public var charId: Int                 // +$00, fixed by the record's slot
        public var level: Int                  // +$12
        public var exp: Int                    // +$13 u24
        public var expToNext: Int              // +$2B u16
        public var hp: Int                     // +$03
        public var maxHp: Int                  // +$05
        public var mp: Int                     // +$07
        public var maxMp: Int                  // +$09
        public var stats: StatBlock            // +$0B-$11
        public var growthBase: StatBlock       // +$2F-$35
        public var equipment: Equipment        // +$27-$2A
        public var techPoints: Int             // +$16 u24 (verified: docs/techs.md)
        public var techPointsToNext: Int       // +$2D u16 (verified: docs/techs.md)
        public struct Equipment: Codable, Equatable, Sendable {
            public var helmet: Int
            public var armor: Int
            public var weapon: Int
            public var accessory: Int
            public init(helmet: Int, armor: Int, weapon: Int, accessory: Int) {
                self.helmet = helmet; self.armor = armor; self.weapon = weapon; self.accessory = accessory
            }
        }
        public init(charId: Int, level: Int, exp: Int, expToNext: Int, hp: Int, maxHp: Int, mp: Int, maxMp: Int,
                    stats: StatBlock, growthBase: StatBlock, equipment: Equipment, techPoints: Int,
                    techPointsToNext: Int) {
            self.charId = charId; self.level = level; self.exp = exp; self.expToNext = expToNext
            self.hp = hp; self.maxHp = maxHp; self.mp = mp; self.maxMp = maxMp; self.stats = stats
            self.growthBase = growthBase; self.equipment = equipment; self.techPoints = techPoints
            self.techPointsToNext = techPointsToNext
        }
    }

    /// Growth per level: HP and MP rows of 4 (top level, gain) steps, the
    /// first step whose top level reaches the new level giving the gain; and
    /// per-stat growth x (level - 1) / 100 over the growth base (speed unused).
    public struct Growth: Codable, Equatable, Sendable {
        public var hp: [Step]
        public var mp: [Step]
        public var stats: StatBlock
        public struct Step: Codable, Equatable, Sendable {
            public var toLevel: Int
            public var gain: Int
            public init(toLevel: Int, gain: Int) { self.toLevel = toLevel; self.gain = gain }
        }
        public init(hp: [Step], mp: [Step], stats: StatBlock) { self.hp = hp; self.mp = mp; self.stats = stats }
    }

    public struct Stats: Codable, Equatable, Sendable {
        public var hp: Int
        public var mp: Int
        public var atk: Int
        public var def: Int
        public var mag: Int
        public var spd: Int
        public init(hp: Int, mp: Int, atk: Int, def: Int, mag: Int, spd: Int) {
            self.hp = hp; self.mp = mp; self.atk = atk
            self.def = def; self.mag = mag; self.spd = spd
        }
    }
}

// MARK: - party.json

/// Party-wide game data imported with the characters: the experience table
/// the level curve uses, and the equipment the editor offers (read-only: the
/// builder checks equipment against the base ROM).
public struct PartyDef: Codable, Equatable, Sendable {
    public var schema: String = "ct-party/1"
    public var expToLevel: [Int]               // 100 entries: [L] = exp from level L to L + 1
    public var equipment: [EquipItem]
    public struct EquipItem: Codable, Equatable, Sendable, Identifiable {
        public var id: Int                     // item id
        public var name: String
        public var slot: String                // weapon | armor | helmet | accessory
        public var equipMask: Int              // bit $80 >> character id
        public init(id: Int, name: String, slot: String, equipMask: Int) {
            self.id = id; self.name = name; self.slot = slot; self.equipMask = equipMask
        }
    }
    public init(expToLevel: [Int], equipment: [EquipItem]) { self.expToLevel = expToLevel; self.equipment = equipment }
}

// MARK: - sprites/<id>.sprite.json  (OAM assemblies)

/// Sheet tile k is OBJ tile k (OBSEL 0: 8x8 and 16x16, name base 0), so a
/// 16x16 OBJ shows tiles N, N+1, N+16 and N+17. With `stream`, each frame's
/// `cells` are copied into a VRAM slot first and `tile` counts from the
/// slot (the game's PC sprites; see docs/sprites.md). Every field after
/// `animations` is optional: older files load and save unchanged.
public struct SpriteDef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sheet: String           // sprites/<id>.png (mode P)
    public var bpp: Int                // 4 (16-col) or 2 (4-col)
    public var frames: [Frame]
    public var animations: [Animation]
    /// OBJ palettes: entry k (16 hex BGR555 words) is palette k of `pal`
    /// (CGRAM 128 + 16k). Absent: palette 0 is the sheet's PLTE.
    public var palettes: [[String]]?
    public var stream: Stream?
    /// Where an import read the sprite (for write-back).
    public var rom: ROMSource?

    public init(id: String, sheet: String, bpp: Int = 4, frames: [Frame] = [], animations: [Animation] = [],
                palettes: [[String]]? = nil, stream: Stream? = nil, rom: ROMSource? = nil) {
        self.id = id; self.sheet = sheet; self.bpp = bpp; self.frames = frames; self.animations = animations
        self.palettes = palettes; self.stream = stream; self.rom = rom
    }

    public struct Frame: Codable, Equatable, Sendable {
        public var tiles: [OAMTile]
        public var large: Bool?        // large-sprite mode: 1024-entry budget
        /// With `stream`: columns x rows tile words, row-major. Bits 0-10 a
        /// sheet tile (0 = blank), bit 14 mirrors it; other bits are kept.
        public var cells: [Int]?
        public var hitbox: Box?        // Studio metadata, frame pixels about the origin
        public var weapon: Point?      // Studio metadata, weapon anchor about the origin

        public init(tiles: [OAMTile] = [], large: Bool? = nil, cells: [Int]? = nil,
                    hitbox: Box? = nil, weapon: Point? = nil) {
            self.tiles = tiles; self.large = large; self.cells = cells; self.hitbox = hitbox; self.weapon = weapon
        }
    }
    /// One OAM entry.
    public struct OAMTile: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var tile: Int
        public var hflip: Bool
        public var vflip: Bool
        public var pal: Int            // 0-7
        public var size16: Bool        // size8|16
        public var anchor: Bool
        public var priority: Int?      // OAM priority 0-3 (absent: 2)

        public init(x: Int, y: Int, tile: Int, hflip: Bool = false, vflip: Bool = false, pal: Int = 0,
                    size16: Bool = false, anchor: Bool = false, priority: Int? = nil) {
            self.x = x; self.y = y; self.tile = tile; self.hflip = hflip; self.vflip = vflip
            self.pal = pal; self.size16 = size16; self.anchor = anchor; self.priority = priority
        }
    }
    public struct Animation: Codable, Equatable, Sendable {
        public var id: String
        public var frames: [Int]
        public var durations: [Int]    // frames per step, 60 Hz ticks
        public var loop: Bool
        public var row: Int?           // the game's animation row
        public var facing: Int?        // 0 up, 1 down, 2 left, 3 right

        public init(id: String, frames: [Int] = [], durations: [Int] = [], loop: Bool = true,
                    row: Int? = nil, facing: Int? = nil) {
            self.id = id; self.frames = frames; self.durations = durations; self.loop = loop
            self.row = row; self.facing = facing
        }
    }
    /// A VRAM slot the frame's cells are copied into: cell (r, c) becomes
    /// OBJ tile baseTile + 16r + c.
    public struct Stream: Codable, Equatable, Sendable {
        public var columns: Int
        public var rows: Int
        public var baseTile: Int
        public init(columns: Int, rows: Int, baseTile: Int) {
            self.columns = columns; self.rows = rows; self.baseTile = baseTile
        }
    }
    public struct ROMSource: Codable, Equatable, Sendable {
        public var family: String      // "ct-pc": a playable character's set
        public var set: Int
        public var tiles: String       // "$D2:72C0"
        public var tileCount: Int
        public var frames: String
        public var frameCount: Int
        public var palette: String
        public var frameIds: String
        public var durations: String
        public var rows: Int
    }
    public struct Box: Codable, Equatable, Sendable {
        public var x: Int, y: Int, w: Int, h: Int
        public init(x: Int, y: Int, w: Int, h: Int) { self.x = x; self.y = y; self.w = w; self.h = h }
    }
    public struct Point: Codable, Equatable, Sendable {
        public var x: Int, y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }
}

// MARK: - items/<id>.json

public struct ItemDef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String            // weapon|helmet|armor|accessory|consumable
    public var price: Int?
    public var effect: String?
    public var stats: [String: Int]?
}

// MARK: - techs/<id>.json

public struct TechDef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var kind: String            // single|dual|triple
    public var users: [String]
    public var element: String?
    public var power: Int?
    public var description: String?
}

// MARK: - strings/dialogue.json

public struct Dialogue: Codable, Equatable, Sendable {
    public var strings: [String: String]
}

// MARK: - audio/tracks/<id>.akao.json

public struct Track: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var tempo: Int
    public var tracks: [Part]
    public var echo: Echo?

    public struct Part: Codable, Equatable, Sendable {
        public var voice: Int
        public var program: Int
        public var pan: Int?
        public var adsr_override: [Int]?
        public var events: [Note]
    }
    public struct Note: Codable, Equatable, Sendable {
        public var t: Int
        public var dur: Int
        public var note: Int
        public var vel: Int?
    }
    public struct Echo: Codable, Equatable, Sendable {
        public var edl: Int
        public var efb: Int
        public var evoll: Int
        public var evolr: Int
        public var fir: [Int]          // 8 echo FIR taps
    }
}

/// audio/samples/<id>.json sidecar (loop/ADSR/GAIN).
public struct SampleMeta: Codable, Equatable, Sendable {
    public var brr: String
    public var rate: Int?
    public var loop: Bool
    public var loopStartSample: Int?   // must be on a 16-sample block boundary
    public var loopEndSample: Int?
    public var adsr: [Int]?
    public var gain: Int?
}

// MARK: - tilesets/<id>.tileset.json

public struct Tileset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sheet: String?          // indexed PNG sheet (mode P)
    public var blob: String?           // or raw planar .bin next to the json
    public var bpp: Int                // 4 or 2
    public var tileCount: Int
    public var metatiles: [Metatile]
    public var collision: [Collision]

    /// 16x16 chip = 4 subtiles (order: TL, TR, BL, BR).
    public struct Metatile: Codable, Equatable, Sendable {
        public var chips: [Chip]
    }
    public struct Chip: Codable, Equatable, Sendable {
        public var tile: Int
        public var pal: Int
        public var hflip: Bool
        public var vflip: Bool
        public var priority: Bool
    }
    public struct Collision: Codable, Equatable, Sendable {
        public var plane1: String      // walk|solid|water|...
        public var plane2: String?
        public var plane_swap: Bool
        public var zmask: Bool
        public var conveyor: String    // none|dir0..dir7
    }

    public var bytesPerTile: Int { bpp == 2 ? 16 : 32 }
}

// MARK: - maps/<id>.map.json

public struct GameMap: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var tileset: String
    public var width: Int              // in 16px chips
    public var height: Int
    public var layers: [Layer]
    public var exits: [Exit]
    public var triggers: [Trigger]

    public struct Layer: Codable, Equatable, Sendable {
        public var bg: Int             // 1..3
        public var metatiles: [Int]    // width*height metatile indices
        public var scrollX: Int?
        public var scrollY: Int?
    }
    public struct Exit: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var map: String
        public var toX: Int
        public var toY: Int
    }
    public struct Trigger: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var scene: String
    }
}

// MARK: - scenes/<id>.event.json

public struct SceneDoc: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var scene: EventScene
    public init(id: String, scene: EventScene) { self.id = id; self.scene = scene }
}
