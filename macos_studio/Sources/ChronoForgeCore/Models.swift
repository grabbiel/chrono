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
    /// lowered from Studio scenes or assembled from a ct-events/1 listing), and
    /// songs by Audio_SongTable index (each assembled from a ct-song/1 listing).
    public struct ROMBuild: Codable, Equatable, Sendable {
        public var eventPacks: [EventPack]
        public var songs: [Song]
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
        public init(eventPacks: [EventPack] = [], songs: [Song] = []) { self.eventPacks = eventPacks; self.songs = songs }
        private enum CodingKeys: String, CodingKey { case eventPacks, songs }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventPacks = try c.decodeIfPresent([EventPack].self, forKey: .eventPacks) ?? []
            songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(eventPacks, forKey: .eventPacks)
            if !songs.isEmpty { try c.encode(songs, forKey: .songs) }
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

// MARK: - sprites/<id>.sprite.json  (OAM assemblies)

public struct SpriteDef: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sheet: String           // sprites/<id>.png (mode P)
    public var bpp: Int                // 4 (16-col) or 2 (4-col)
    public var frames: [Frame]
    public var animations: [Animation]

    public struct Frame: Codable, Equatable, Sendable {
        public var tiles: [OAMTile]
        public var large: Bool?        // large-sprite mode: 1024-entry budget
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
    }
    public struct Animation: Codable, Equatable, Sendable {
        public var id: String
        public var frames: [Int]
        public var durations: [Int]    // frames per step, 60 Hz ticks
        public var loop: Bool
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
