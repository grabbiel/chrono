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
    /// record and `growth` rows; docs/characters.md), the tech tables, the
    /// item tables (docs/items.md), maps and tilesets by id over the
    /// locations and sets they were imported from (docs/rom_builder.md), and
    /// enemies by their `characters/<id>.json` `enemy` record (docs/enemies.md).
    public struct ROMBuild: Codable, Equatable, Sendable {
        public var eventPacks: [EventPack]
        public var songs: [Song]
        public var characters: [String]
        public var techs: Bool                 // write tech_system.json's tables (absent = false)
        public var items: Bool                 // write the ROM items and item_tables.json (absent = false)
        public var maps: [String] = []         // maps/<id>.map.json with a rom.location (absent = none)
        public var tilesets: [String] = []     // tilesets/<id>.tileset.json with a rom source (absent = none)
        public var enemies: [String] = []      // characters/<id>.json with an enemy record (absent = none)
        public var sprites: [String] = []      // sprites/<id>.sprite.json with a rom source (absent = none)
        public var samples: [Sample] = []      // audio/samples/<id>.json put in the game (absent = none)
        /// A project sample in the game (docs/sfx_lab.md, "A project sample in the game").
        public struct Sample: Codable, Equatable, Sendable {
            public var id: String
            public var replace: Int?           // 1-62: take over that ROM sample (absent: append after them)
            public var songs: [Int]            // songs whose sample list gets it (absent: none)
            public var rootNote: Int?          // the driver note that plays it at its rate (absent: a default)
            public var tuning: Int?            // Audio_SampleParamA word, instead of one from the rate
            public var adsr: Int?              // Audio_SampleParamB word (ADSR1 | ADSR2 << 8), instead of the sidecar's
            public var asIs: Bool              // write the .brr blocks unchanged (ROM imports; absent: false)
            public var loopOffset: Int?        // with asIs: Audio_SampleLoop, in bytes
            public init(id: String, replace: Int? = nil, songs: [Int] = [], rootNote: Int? = nil, tuning: Int? = nil,
                        adsr: Int? = nil, asIs: Bool = false, loopOffset: Int? = nil) {
                self.id = id; self.replace = replace; self.songs = songs; self.rootNote = rootNote; self.tuning = tuning
                self.adsr = adsr; self.asIs = asIs; self.loopOffset = loopOffset
            }
            private enum CodingKeys: String, CodingKey { case id, replace, songs, rootNote, tuning, adsr, asIs, loopOffset }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                replace = try c.decodeIfPresent(Int.self, forKey: .replace)
                songs = try c.decodeIfPresent([Int].self, forKey: .songs) ?? []
                rootNote = try c.decodeIfPresent(Int.self, forKey: .rootNote)
                tuning = try c.decodeIfPresent(Int.self, forKey: .tuning)
                adsr = try c.decodeIfPresent(Int.self, forKey: .adsr)
                asIs = try c.decodeIfPresent(Bool.self, forKey: .asIs) ?? false
                loopOffset = try c.decodeIfPresent(Int.self, forKey: .loopOffset)
            }
            public func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encodeIfPresent(replace, forKey: .replace)
                if !songs.isEmpty { try c.encode(songs, forKey: .songs) }
                try c.encodeIfPresent(rootNote, forKey: .rootNote)
                try c.encodeIfPresent(tuning, forKey: .tuning)
                try c.encodeIfPresent(adsr, forKey: .adsr)
                if asIs { try c.encode(asIs, forKey: .asIs) }
                try c.encodeIfPresent(loopOffset, forKey: .loopOffset)
            }
        }
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
        public init(eventPacks: [EventPack] = [], songs: [Song] = [], characters: [String] = [], techs: Bool = false,
                    items: Bool = false, maps: [String] = [], tilesets: [String] = [], enemies: [String] = [],
                    sprites: [String] = [], samples: [Sample] = []) {
            self.eventPacks = eventPacks; self.songs = songs; self.characters = characters; self.techs = techs
            self.items = items; self.maps = maps; self.tilesets = tilesets; self.enemies = enemies; self.sprites = sprites
            self.samples = samples
        }
        private enum CodingKeys: String, CodingKey { case eventPacks, songs, characters, techs, items, maps, tilesets, enemies, sprites, samples }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventPacks = try c.decodeIfPresent([EventPack].self, forKey: .eventPacks) ?? []
            songs = try c.decodeIfPresent([Song].self, forKey: .songs) ?? []
            characters = try c.decodeIfPresent([String].self, forKey: .characters) ?? []
            techs = try c.decodeIfPresent(Bool.self, forKey: .techs) ?? false
            items = try c.decodeIfPresent(Bool.self, forKey: .items) ?? false
            maps = try c.decodeIfPresent([String].self, forKey: .maps) ?? []
            tilesets = try c.decodeIfPresent([String].self, forKey: .tilesets) ?? []
            enemies = try c.decodeIfPresent([String].self, forKey: .enemies) ?? []
            sprites = try c.decodeIfPresent([String].self, forKey: .sprites) ?? []
            samples = try c.decodeIfPresent([Sample].self, forKey: .samples) ?? []
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(eventPacks, forKey: .eventPacks)
            if !songs.isEmpty { try c.encode(songs, forKey: .songs) }
            if !characters.isEmpty { try c.encode(characters, forKey: .characters) }
            if techs { try c.encode(techs, forKey: .techs) }
            if items { try c.encode(items, forKey: .items) }
            if !maps.isEmpty { try c.encode(maps, forKey: .maps) }
            if !tilesets.isEmpty { try c.encode(tilesets, forKey: .tilesets) }
            if !enemies.isEmpty { try c.encode(enemies, forKey: .enemies) }
            if !sprites.isEmpty { try c.encode(sprites, forKey: .sprites) }
            if !samples.isEmpty { try c.encode(samples, forKey: .samples) }
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
        /// "story" for flags the story registry writes (story/flags.json); absent for the maintainer's own.
        public var origin: String? = nil
        public var notes: String? = nil
        public init(symbol: String, bank: String, addr: String, bit: Int, origin: String? = nil, notes: String? = nil) {
            self.symbol = symbol; self.bank = bank; self.addr = addr; self.bit = bit
            self.origin = origin; self.notes = notes
        }
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
    /// An enemy's game data ($CC:4700 stats, $CC:5E00 rewards, name, AI;
    /// CTEnemies.swift, docs/enemies.md), absent for other characters.
    public var enemy: Enemy? = nil

    public init(id: String, name: String, kind: String, sprite: String? = nil, level: Int? = nil,
                stats: Stats? = nil, palette: [String]? = nil, pc: Record? = nil, growth: Growth? = nil,
                enemy: Enemy? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.sprite = sprite; self.level = level
        self.stats = stats; self.palette = palette; self.pc = pc; self.growth = growth; self.enemy = enemy
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
    /// ct-enemy: the record's battle fields ($E4:F600 +4 to +9; absent: not written).
    public var battle: Battle? = nil

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
        public var family: String      // "ct-pc": a playable character's set; "ct-enemy": an enemy record
        public var set: Int            // the set (ct-pc) or the enemy record (ct-enemy)
        public var tiles: String       // "$D2:72C0"
        public var tileCount: Int
        public var frames: String
        public var frameCount: Int
        public var palette: String
        public var frameIds: String
        public var durations: String
        public var rows: Int
        public var layout: Int? = nil  // ct-enemy: the frame layout (size class 0-2; absent = 0)
        public var packed: Bool? = nil // ct-enemy: the graphics are unpacked from `tiles` (absent = raw)
        public var packedBytes: Int? = nil // ct-enemy, packed: the pack's size in the base ROM (its in-place budget)
    }
    /// An enemy record's battle fields, as Battle_InitScene reads them
    /// (docs/sprites.md, "Enemy write-back").
    public struct Battle: Codable, Equatable, Sendable {
        public var flags: Int          // +4 bits 2-7 (the game tests 2, 3, 5 and 7; 4 and 6 stay as imported)
        public var screenOffsetX: Int  // +5, 0-255
        public var screenOffsetY: Int  // +6, 0-255
        public var halfWidth: Int      // +7, 0-255
        public var height: Int         // +8, 0-255
        public var moveSpeed: Int      // +9 bits 0-2
        public var moveDelay: Int      // +9 bits 4-7
        public init(flags: Int, screenOffsetX: Int, screenOffsetY: Int, halfWidth: Int, height: Int,
                    moveSpeed: Int, moveDelay: Int) {
            self.flags = flags; self.screenOffsetX = screenOffsetX; self.screenOffsetY = screenOffsetY
            self.halfWidth = halfWidth; self.height = height; self.moveSpeed = moveSpeed; self.moveDelay = moveDelay
        }
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
    /// A ROM item's record B fields by `CTItemROM.statFields[kind]` (docs/items.md).
    public var stats: [String: Int]?
    /// The ROM item this file edits (absent: a project-only item).
    public var rom: Record? = nil
    /// The menu description, in the dialogue codec's text.
    public var description: String? = nil

    /// The record A bytes and the read-only icon of a ROM item. Equip, boost,
    /// element bonus and target mode are present only where the category has them.
    public struct Record: Codable, Equatable, Sendable {
        public var itemId: Int                 // 0-$F1, fixes the category
        public var icon: Int                   // name byte 0, read-only
        public var flags: Int                  // record A byte 0
        public var equip: Int?                 // byte 3: bit 7 - character (weapons to accessories)
        public var boost: Int?                 // byte 4: ItemBoosts index (weapons, armour, helmets)
        public var elementBonus: Int?          // byte 5: bits 7-4 by CTItemROM.elements
        public var targetMode: Int?            // ItemTargetMode byte (consumables)
        public init(itemId: Int, icon: Int, flags: Int, equip: Int? = nil, boost: Int? = nil,
                    elementBonus: Int? = nil, targetMode: Int? = nil) {
            self.itemId = itemId; self.icon = icon; self.flags = flags; self.equip = equip; self.boost = boost
            self.elementBonus = elementBonus; self.targetMode = targetMode
        }
    }
    public init(id: String, name: String, kind: String, price: Int? = nil, effect: String? = nil,
                stats: [String: Int]? = nil, rom: Record? = nil, description: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.price = price; self.effect = effect
        self.stats = stats; self.rom = rom; self.description = description
    }
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
    // SFX Lab (docs/sfx_lab.md); absent in older sidecars.
    public var synth: SynthSpec?        // regenerates the PCM this sample was encoded from
    public var source: SampleSource?    // WAV import settings and measured SNR
    public var fx: SampleFX?            // pitch bend, vibrato, noise and preview key-off

    public init(brr: String, rate: Int? = nil, loop: Bool = false, loopStartSample: Int? = nil, loopEndSample: Int? = nil,
                adsr: [Int]? = nil, gain: Int? = nil, synth: SynthSpec? = nil, source: SampleSource? = nil, fx: SampleFX? = nil) {
        self.brr = brr; self.rate = rate; self.loop = loop; self.loopStartSample = loopStartSample
        self.loopEndSample = loopEndSample; self.adsr = adsr; self.gain = gain
        self.synth = synth; self.source = source; self.fx = fx
    }
}

// MARK: - tilesets/<id>.tileset.json

/// Sheet tile k is BG character k (a tilemap word's bits 0-9). Every field
/// after `collision` is optional: older files load and save unchanged. A
/// `kind` "palette" entry holds only palettes and their cycles (Chrono
/// Trigger picks a location's palette apart from its graphics); see
/// docs/tilesets.md.
public struct Tileset: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var sheet: String?          // indexed PNG sheet (mode P)
    public var blob: String?           // or raw planar .bin next to the json
    public var bpp: Int                // 4 or 2
    public var tileCount: Int
    public var metatiles: [Metatile]
    public var collision: [Collision]
    /// "bg12" (layers 1/2), "bg3" (layer 3) or "palette"; absent: a plain bank.
    public var kind: String?
    /// Where the sheet sits in VRAM and which of its tiles the tileset sets.
    public var vram: VRAM?
    /// CGRAM rows: entry r is 16 hex BGR555 words for palette row r.
    public var palettes: [[String]]?
    public var paletteCycles: [PaletteCycle]?
    /// Frames shown in place of 4 characters each (`animSheet` holds them).
    public var tileAnimations: [TileAnimation]?
    public var animSheet: String?      // indexed PNG, 16 tiles per row
    /// Ids of the tilesets the Studio previews this one with.
    public var preview: Preview?
    /// Where an import read the tileset (for write-back).
    public var rom: ROMSource?

    public init(id: String, sheet: String? = nil, blob: String? = nil, bpp: Int = 4, tileCount: Int = 0,
                metatiles: [Metatile] = [], collision: [Collision] = [], kind: String? = nil, vram: VRAM? = nil,
                palettes: [[String]]? = nil, paletteCycles: [PaletteCycle]? = nil,
                tileAnimations: [TileAnimation]? = nil, animSheet: String? = nil, preview: Preview? = nil,
                rom: ROMSource? = nil) {
        self.id = id; self.sheet = sheet; self.blob = blob; self.bpp = bpp; self.tileCount = tileCount
        self.metatiles = metatiles; self.collision = collision; self.kind = kind; self.vram = vram
        self.palettes = palettes; self.paletteCycles = paletteCycles; self.tileAnimations = tileAnimations
        self.animSheet = animSheet; self.preview = preview; self.rom = rom
    }

    /// 16x16 chip = 4 subtiles (order: TL, TR, BL, BR).
    public struct Metatile: Codable, Equatable, Sendable {
        public var chips: [Chip]
        public init(chips: [Chip]) { self.chips = chips }
    }
    public struct Chip: Codable, Equatable, Sendable {
        public var tile: Int
        public var pal: Int
        public var hflip: Bool
        public var vflip: Bool
        public var priority: Bool
        public init(tile: Int, pal: Int = 0, hflip: Bool = false, vflip: Bool = false, priority: Bool = false) {
            self.tile = tile; self.pal = pal; self.hflip = hflip; self.vflip = vflip; self.priority = priority
        }
        /// The SNES tilemap word: tile 0-9, palette 10-12, priority 13, hflip 14, vflip 15.
        public var word: UInt16 { PPUFrame.tilemapEntry(tile: tile, palette: pal, priority: priority, hflip: hflip, vflip: vflip) }
        public init(word w: UInt16) {
            self.init(tile: Int(w & 0x3FF), pal: Int(w >> 10 & 7), hflip: w & 0x4000 != 0, vflip: w & 0x8000 != 0,
                      priority: w & 0x2000 != 0)
        }
    }
    public struct VRAM: Codable, Equatable, Sendable {
        public var charBase: Int       // VRAM word of character 0
        public var slots: [Slot]       // the uploads that fill the sheet
        public var known: [Span]       // characters the tileset sets; the rest hold other data in the game
        public init(charBase: Int, slots: [Slot] = [], known: [Span] = []) {
            self.charBase = charBase; self.slots = slots; self.known = known
        }
    }
    public struct Slot: Codable, Equatable, Sendable {
        public var slot: Int
        public var vram: Int           // VRAM word address
        public var firstTile: Int
        public var tiles: Int          // characters the upload sends
        public var pack: Int?          // graphics pack number (absent: slot unused)
        public var source: String?     // "$E2:0C1E"
        public var ownTiles: Int?      // characters from this pack; the rest are an earlier pack's
        public init(slot: Int, vram: Int, firstTile: Int, tiles: Int, pack: Int? = nil, source: String? = nil,
                    ownTiles: Int? = nil) {
            self.slot = slot; self.vram = vram; self.firstTile = firstTile; self.tiles = tiles; self.pack = pack
            self.source = source; self.ownTiles = ownTiles
        }
    }
    public struct Span: Codable, Equatable, Sendable {
        public var firstTile: Int
        public var tiles: Int
        public init(firstTile: Int, tiles: Int) { self.firstTile = firstTile; self.tiles = tiles }
    }
    /// One palette animation. kind: "rotate-down" / "rotate-up" turn colours
    /// first...first+count (count + 1 of them) by one; "rom-frames" copies
    /// frame k of `frames` to colours first..<first+count, k stepping 0, 1, ...;
    /// "list-frames" the same with k from `order`. Every `delay` frames (0 =
    /// 256). Colours are CGRAM indices (16 x row + colour).
    public struct PaletteCycle: Codable, Equatable, Sendable {
        public var kind: String
        public var first: Int
        public var count: Int
        public var delay: Int
        public var frames: [[String]]?
        public var order: [Int]?
        public var source: String?     // "$F6:7568": where the frames are read
        public init(kind: String, first: Int, count: Int, delay: Int, frames: [[String]]? = nil, order: [Int]? = nil,
                    source: String? = nil) {
            self.kind = kind; self.first = first; self.count = count; self.delay = delay; self.frames = frames
            self.order = order; self.source = source
        }
    }
    /// 4 characters from `tile` show animSheet tiles frames[f]...frames[f]+3,
    /// f advancing as the game's accumulator: += 4 x steps[f] per upload, f =
    /// bits 9-11 (8 entries each; one upload every other field IRQ).
    public struct TileAnimation: Codable, Equatable, Sendable {
        public var tile: Int
        public var tiles: Int
        public var steps: [Int]
        public var frames: [Int]
        public init(tile: Int, tiles: Int = 4, steps: [Int], frames: [Int]) {
            self.tile = tile; self.tiles = tiles; self.steps = steps; self.frames = frames
        }
    }
    public struct Preview: Codable, Equatable, Sendable {
        public var palette: String?
        public var layer3: String?
        public init(palette: String? = nil, layer3: String? = nil) { self.palette = palette; self.layer3 = layer3 }
    }
    public struct ROMSource: Codable, Equatable, Sendable {
        public var family: String      // "ct-loc12" | "ct-loc3" | "ct-locpal"
        public var index: Int          // the LocRom.Tileset12 / Tileset3 / Palette value
        public var table: String       // the metatile pack, or the palette set
        public var packedBytes: Int?
        public var list: String?       // LocGfx_Lists entry
        public var animations: String? // FieldAnimListA / B list
        public var locations: [Int]
        public init(family: String, index: Int, table: String, packedBytes: Int? = nil, list: String? = nil,
                    animations: String? = nil, locations: [Int] = []) {
            self.family = family; self.index = index; self.table = table; self.packedBytes = packedBytes
            self.list = list; self.animations = animations; self.locations = locations
        }
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
    public var width: Int              // in 16px chips (layer 1's size)
    public var height: Int
    public var layers: [Layer]
    public var exits: [Exit]
    public var triggers: [Trigger]
    /// The LocRom record an import read (CTMapROM.Header): absent in hand-made maps.
    public var location: Location?
    /// MapProps' screen and scroll settings.
    public var settings: Settings?
    /// Map_TileHiBits / AttrA / AttrB over layer 1 (CTTileProps decodes them).
    public var tileProps: TileProps?
    /// TreasureRom records, in the ROM's order (their numbers are the flag bits).
    public var treasure: [Treasure]?
    /// Where an import read the map (for write-back).
    public var rom: ROMSource?

    public init(id: String, name: String, tileset: String, width: Int, height: Int, layers: [Layer],
                exits: [Exit], triggers: [Trigger], location: Location? = nil, settings: Settings? = nil,
                tileProps: TileProps? = nil, treasure: [Treasure]? = nil, rom: ROMSource? = nil) {
        self.id = id; self.name = name; self.tileset = tileset; self.width = width; self.height = height
        self.layers = layers; self.exits = exits; self.triggers = triggers; self.location = location
        self.settings = settings; self.tileProps = tileProps; self.treasure = treasure; self.rom = rom
    }

    public struct Layer: Codable, Equatable, Sendable {
        public var bg: Int             // 1..3
        public var metatiles: [Int]    // width*height metatile indices
        public var scrollX: Int?
        public var scrollY: Int?
        /// The layer's own size when it differs from the map's (layers 2 and 3 can).
        public var width: Int?
        public var height: Int?
        public init(bg: Int, metatiles: [Int], scrollX: Int? = nil, scrollY: Int? = nil,
                    width: Int? = nil, height: Int? = nil) {
            self.bg = bg; self.metatiles = metatiles; self.scrollX = scrollX; self.scrollY = scrollY
            self.width = width; self.height = height
        }
    }
    public struct Exit: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var map: String
        public var toX: Int
        public var toY: Int
        /// Tiles after the first the exit also covers, along the row or (`vertical`) down the column.
        public var span: Int?
        public var vertical: Bool?
        /// The facing on arrival (ExitRom byte 4 bits 1-4) and that byte's bit 7.
        public var facing: Int?
        public var facingBit7: Bool?
        public init(x: Int, y: Int, map: String, toX: Int, toY: Int, span: Int? = nil, vertical: Bool? = nil,
                    facing: Int? = nil, facingBit7: Bool? = nil) {
            self.x = x; self.y = y; self.map = map; self.toX = toX; self.toY = toY
            self.span = span; self.vertical = vertical; self.facing = facing; self.facingBit7 = facingBit7
        }
    }
    public struct Trigger: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        public var scene: String
        public init(x: Int, y: Int, scene: String) { self.x = x; self.y = y; self.scene = scene }
    }
    /// LocRom fields besides the map: raw values (CTMapROM.Header names them).
    public struct Location: Codable, Equatable, Sendable {
        public var music: Int
        public var tileset12: Int
        public var tileset3: Int
        public var palette: Int
        public var events: Int
        public var unk06: Int
        /// LimitLeft, LimitTop, LimitRight, LimitBottom; LimitLeft bit 7: the layer-1 edges.
        public var limits: [Int]
        public init(music: Int, tileset12: Int, tileset3: Int, palette: Int, events: Int, unk06: Int, limits: [Int]) {
            self.music = music; self.tileset12 = tileset12; self.tileset3 = tileset3; self.palette = palette
            self.events = events; self.unk06 = unk06; self.limits = limits
        }
    }
    /// MapProps bytes 1-5 apart from the layer sizes (those are the layers').
    public struct Settings: Codable, Equatable, Sendable {
        public var screens: Int        // bits 0-3 main screen BG1-3/OBJ, 4-7 sub screen
        public var colorMath: Int      // CGADSUB
        public var move2: Int          // layer 2's own step (CTMapROM.ownStep)
        public var move3: Int
        public var halfRate2: Bool     // layer 2 scrolls at half the camera's rate
        public var ownStep2: Bool      // layer 2 moves by its own step only
        public var ownStep3: Bool
        public init(screens: Int, colorMath: Int, move2: Int = 0, move3: Int = 0, halfRate2: Bool = false,
                    ownStep2: Bool = false, ownStep3: Bool = false) {
            self.screens = screens; self.colorMath = colorMath; self.move2 = move2; self.move3 = move3
            self.halfRate2 = halfRate2; self.ownStep2 = ownStep2; self.ownStep3 = ownStep3
        }
    }
    /// One byte per layer-1 tile of each plane, row-major, as hex.
    public struct TileProps: Codable, Equatable, Sendable {
        public var width: Int
        public var height: Int
        public var hiBits: String
        public var attrA: String
        public var attrB: String
        public init(width: Int, height: Int, hiBits: String, attrA: String, attrB: String) {
            self.width = width; self.height = height; self.hiBits = hiBits; self.attrA = attrA; self.attrB = attrB
        }
    }
    public struct Treasure: Codable, Equatable, Sendable {
        public var x: Int
        public var y: Int
        /// Bit 15: gold, amount = bits 0-14 x 2; else bit 14: nothing; else the item in bits 0-8.
        public var contents: Int
        public init(x: Int, y: Int, contents: Int) { self.x = x; self.y = y; self.contents = contents }
    }
    public struct ROMSource: Codable, Equatable, Sendable {
        public var location: Int
        public var record: String          // LocRom record, "$F6:000E"
        public var mapProps: Int           // Map_PropsPtrs entry
        public var packedAt: String
        public var packedBytes: Int
        public var unpackedBytes: Int
        /// Tiles at the end whose properties the game reads from WRAM past the map (decoded as 0).
        public var staleTiles: Int
        public var exitsAt: String?
        /// The location whose TreasureRom list this one uses (itself unless redirected).
        public var treasureList: Int
        public var treasureAt: String?
        public init(location: Int, record: String, mapProps: Int, packedAt: String, packedBytes: Int,
                    unpackedBytes: Int, staleTiles: Int, exitsAt: String?, treasureList: Int, treasureAt: String?) {
            self.location = location; self.record = record; self.mapProps = mapProps; self.packedAt = packedAt
            self.packedBytes = packedBytes; self.unpackedBytes = unpackedBytes; self.staleTiles = staleTiles
            self.exitsAt = exitsAt; self.treasureList = treasureList; self.treasureAt = treasureAt
        }
    }
}

// MARK: - scenes/<id>.event.json

public struct SceneDoc: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var scene: EventScene
    public init(id: String, scene: EventScene) { self.id = id; self.scene = scene }
}
