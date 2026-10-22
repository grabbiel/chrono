// Writes event packs, their message tables, songs, playable-character
// records, techs, items, maps, tilesets, enemies and sprites into a copy of the base ROM.
// Layout facts and their evidence: CTROMLayout.swift / docs/rom_builder.md.
import Foundation

public struct CTROMBuildError: Error, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public enum CTROMBuilder {
    public static let romSize = 4_194_304
    public static let packMode = LZSSMode.lz11       // 462 of the 463 event streams use it

    /// One pack to write: its unpacked bytes (as loaded to $7F:2000) and, for
    /// lowered scenes, the messages whose table address goes into each `$B8`.
    public struct Request: Sendable {
        public let entry: Int
        public let source: String
        public let bytes: [UInt8]
        public let messages: [(id: String, text: String)]
        public let relocations: [Int]                // offsets into `bytes` of 24-bit table pointers
        public init(entry: Int, source: String, bytes: [UInt8],
                    messages: [(id: String, text: String)] = [], relocations: [Int] = []) {
            self.entry = entry; self.source = source; self.bytes = bytes
            self.messages = messages; self.relocations = relocations
        }
    }

    /// One song to write: its data (after the u16 length), as loaded to ARAM
    /// $2000, and the rows of the per-song tables its listing sets.
    public struct SongRequest: Sendable {
        public let song: Int
        public let source: String
        public let data: [UInt8]
        public let tables: CTSongTables
        public init(song: Int, source: String, data: [UInt8], tables: CTSongTables = .init()) {
            self.song = song; self.source = source; self.data = data; self.tables = tables
        }
    }

    /// One playable character to write: its record's decoded fields over the
    /// base ROM's record `record.charId`, and its growth rows when given.
    public struct CharacterRequest: Sendable {
        public let id: String
        public let record: CharacterDef.Record
        public let growth: CharacterDef.Growth?
        public init(id: String, record: CharacterDef.Record, growth: CharacterDef.Growth? = nil) {
            self.id = id; self.record = record; self.growth = growth
        }
    }

    /// One enemy to write: its stat and reward records over the base ROM's
    /// `enemy.enemyId`, and its name when given and changed.
    public struct EnemyRequest: Sendable {
        public let id: String
        public let enemy: CharacterDef.Enemy
        public let name: String?
        public init(id: String, enemy: CharacterDef.Enemy, name: String? = nil) {
            self.id = id; self.enemy = enemy; self.name = name
        }
    }

    public struct Report: Codable, Equatable, Sendable {
        public struct Enemy: Codable, Equatable, Sendable {
            public let id: String
            public let enemyId: Int
            public let address: String                 // the stat record
            public let pc: Int
            public let name: String?                   // written (absent: left as it was)
            public let enemy: CharacterDef.Enemy
        }
        public struct Character: Codable, Equatable, Sendable {
            public let id: String
            public let charId: Int
            public let address: String
            public let pc: Int
            public let record: CharacterDef.Record
            public let growth: CharacterDef.Growth?    // absent: rows left as they were
        }
        public struct Pack: Codable, Equatable, Sendable {
            public let entry: Int
            public let source: String
            public let address: String
            public let pc: Int
            public let packedBytes: Int
            public let unpackedBytes: Int
            public let unpackedSHA256: String
            public let placement: String               // original | reclaimed | free | shared
            public let messageTable: String?
        }
        public struct Message: Codable, Equatable, Sendable {
            public let id: String
            public let text: String
            public let address: String
            public let bytes: Int
        }
        public struct MessageTable: Codable, Equatable, Sendable {
            public let entries: [Int]
            public let address: String
            public let pc: Int
            public let bytes: Int
            public let messages: [Message]
        }
        public struct Song: Codable, Equatable, Sendable {
            public let song: Int
            public let source: String
            public let address: String
            public let pc: Int
            public let bytes: Int                      // the data after the u16 length
            public let dataSHA256: String
            public let placement: String               // original | reclaimed | free | shared
            public let samples: [Int]?                 // table rows written (absent: left as they were)
            public let echo: [Int]?
            public let drums: [Int]?
        }
        public struct Write: Codable, Equatable, Sendable {
            public let pc: Int
            public let length: Int
            public let what: String
        }
        /// A block written somewhere other than where the base ROM had it.
        public struct Relocation: Codable, Equatable, Sendable {
            public let what: String
            public let from: String?                   // its old place (absent: a new block, such as a fork)
            public let to: String
            public let pc: Int
            public let bytes: Int
        }
        public let schema: String
        public let baseSHA256: String
        public let outputSHA256: String
        public let checksum: Int
        public let packs: [Pack]
        public let messageTables: [MessageTable]
        public let songs: [Song]
        public let characters: [Character]?           // absent: none requested
        public let techs: TechSystemDef?               // absent: not requested
        public let items: [ItemDef]?                   // the ROM items built (absent: not requested)
        public let itemTables: ItemTablesDef?          // absent: not requested or no item_tables.json
        public let writes: [Write]
        public let freeBytesLeft: Int
        public var maps: [CTMapPatch.ReportMap]? = nil             // absent: not requested
        public var tilesets: [CTTilesetPatch.ReportTileset]? = nil // absent: not requested
        public var relocations: [Relocation]? = nil               // absent: nothing moved
        public var enemies: [Enemy]? = nil                        // absent: none requested
        public var sprites: [CTSpritePatch.ReportSprite]? = nil   // absent: none requested
    }

    // MARK: Project entry point

    /// The ROM items and shared tables `rom.items` writes (docs/items.md).
    public struct ItemsRequest: Sendable {
        public var items: [ItemDef]
        public var tables: ItemTablesDef?
        public init(items: [ItemDef], tables: ItemTablesDef?) { self.items = items; self.tables = tables }
    }

    /// Builds the project's `rom.eventPacks`, `rom.songs`, `rom.characters`, `rom.techs`, `rom.items`,
    /// `rom.maps` and `rom.tilesets` into a copy of `base` (the pinned US 1.0 ROM; a 512-byte copier
    /// header is dropped).
    public static func build(base: [UInt8], project: CTProject) throws -> (rom: [UInt8], report: Report) {
        guard let spec = project.project.rom,
              !(spec.eventPacks.isEmpty && spec.songs.isEmpty && spec.characters.isEmpty && !spec.techs && !spec.items
                && spec.maps.isEmpty && spec.tilesets.isEmpty && spec.enemies.isEmpty && spec.sprites.isEmpty) else {
            throw CTROMBuildError("project.json has no rom.eventPacks, rom.songs, rom.characters, rom.techs, rom.items, " +
                                  "rom.maps, rom.tilesets, rom.enemies or rom.sprites to build")
        }
        func inside(_ path: String) -> Bool { !path.hasPrefix("/") && !path.split(separator: "/").contains("..") }
        var requests: [Request] = []
        for pack in spec.eventPacks {
            switch (pack.scenes, pack.listing) {
            case (let scenes?, nil):
                let lowered: CTEventLowering.Output
                do { lowered = try CTEventLowering.lower(project: project, scenes: scenes) }
                catch { throw CTROMBuildError("entry \(pack.entry): \(error)") }
                let messages = try lowered.messages.map { id -> (id: String, text: String) in
                    guard let text = project.dialogue.strings[id] else {
                        throw CTROMBuildError("entry \(pack.entry): no dialogue string \(id)")
                    }
                    return (id, text)
                }
                requests.append(Request(entry: pack.entry, source: "scenes " + scenes.joined(separator: ","),
                                        bytes: lowered.bytes, messages: messages,
                                        relocations: lowered.relocations.map(\.offset)))
            case (nil, let listing?):
                let url = project.fileURL(relative: listing)
                guard inside(listing) else {
                    throw CTROMBuildError("entry \(pack.entry): listing path must stay inside the project")
                }
                let bytes: [UInt8]
                do { bytes = try CTEventListing.parse(String(contentsOf: url, encoding: .utf8)).assemble() }
                catch { throw CTROMBuildError("entry \(pack.entry): \(listing): \(error)") }
                requests.append(Request(entry: pack.entry, source: "listing " + listing, bytes: bytes))
            default:
                throw CTROMBuildError("entry \(pack.entry): give exactly one of scenes or listing")
            }
        }
        let songs = try spec.songs.map { s -> SongRequest in
            guard inside(s.listing) else { throw CTROMBuildError("song \(s.song): listing path must stay inside the project") }
            do {
                let text = try String(contentsOf: project.fileURL(relative: s.listing), encoding: .utf8)
                let (data, tables) = try CTSongListing.assembleSong(text)
                return SongRequest(song: s.song, source: "listing " + s.listing, data: data, tables: tables)
            } catch { throw CTROMBuildError("song \(s.song): \(s.listing): \(error)") }
        }
        let characters = try spec.characters.map { id -> CharacterRequest in
            guard let c = project.characters[id] else { throw CTROMBuildError("character \(id): no characters/\(id).json") }
            guard let record = c.pc else { throw CTROMBuildError("character \(id) has no pc record; import the ROM's characters") }
            return CharacterRequest(id: id, record: record, growth: c.growth)
        }
        var techs: TechSystemDef?
        if spec.techs {
            guard let system = project.techSystem else { throw CTROMBuildError("rom.techs needs tech_system.json; import the ROM's techs") }
            techs = system
        }
        var items: ItemsRequest?
        if spec.items {
            let rom = project.items.values.filter { $0.rom != nil }.sorted { $0.id < $1.id }
            guard !rom.isEmpty || project.itemTables != nil else {
                throw CTROMBuildError("rom.items needs ROM items or item_tables.json; import the ROM's items")
            }
            items = ItemsRequest(items: rom, tables: project.itemTables)
        }
        let maps = try spec.maps.map { id -> GameMap in
            guard let m = project.maps[id] else { throw CTROMBuildError("map \(id): no maps/\(id).map.json") }
            return m
        }
        let tilesets = try spec.tilesets.map { id -> CTTilesetPatch.Request in
            guard let ts = project.tilesets[id] else { throw CTROMBuildError("tileset \(id): no tilesets/\(id).tileset.json") }
            func tiles(_ rel: String?) throws -> [[UInt8]]? {
                guard let rel else { return nil }
                guard inside(rel) else { throw CTROMBuildError("tileset \(id): \(rel) must stay inside the project") }
                do { return SpriteSheet.tiles(try PNG.readIndexed(url: project.fileURL(relative: rel))) }
                catch { throw CTROMBuildError("tileset \(id): \(rel): \(error)") }
            }
            return CTTilesetPatch.Request(tileset: ts, sheet: try tiles(ts.sheet), animSheet: try tiles(ts.animSheet))
        }
        let enemies = try spec.enemies.map { id -> EnemyRequest in
            guard let c = project.characters[id] else { throw CTROMBuildError("enemy \(id): no characters/\(id).json") }
            guard let e = c.enemy else { throw CTROMBuildError("enemy \(id) has no enemy record; import the ROM's enemies") }
            return EnemyRequest(id: id, enemy: e, name: CTEnemyROM.writableName(c))
        }
        let sprites = try spec.sprites.map { id -> CTSpritePatch.Request in
            guard let s = project.sprites[id] else { throw CTROMBuildError("sprite \(id): no sprites/\(id).sprite.json") }
            guard inside(s.sheet) else { throw CTROMBuildError("sprite \(id): \(s.sheet) must stay inside the project") }
            let png: IndexedPNG
            do { png = try PNG.readIndexed(url: project.fileURL(relative: s.sheet)) }
            catch { throw CTROMBuildError("sprite \(id): \(s.sheet): \(error)") }
            guard png.bitDepth <= 4, png.indices.allSatisfy({ $0 < 16 }) else {
                throw CTROMBuildError("sprite \(id): \(s.sheet) must be a 4bpp indexed sheet (indices 0-15)")
            }
            return CTSpritePatch.Request(sprite: s, sheet: SpriteSheet.tiles(png))
        }
        return try build(base: base, requests: requests, songs: songs, characters: characters, techs: techs,
                         items: items, maps: maps, tilesets: tilesets, enemies: enemies, sprites: sprites,
                         textProfile: project.textProfile)
    }

    /// `block` in its old span `home` (now unused) when it fits, else in a
    /// reclaimed span, else in free space; never across a bank.
    static func placeBlock(_ block: [UInt8], home: Range<Int>?, space: inout FreeSpace, what: String) throws -> (pc: Int, placement: String) {
        if let home {
            space.add(home, reclaimed: true)
            if space.allocate(block.count, at: home.lowerBound) { return (home.lowerBound, "original") }
        }
        if let pc = space.allocate(block.count, reclaimed: true) { return (pc, "reclaimed") }
        if let pc = space.allocate(block.count, reclaimed: false) { return (pc, "free") }
        throw CTROMBuildError("no free space for the \(block.count)-byte \(what) " +
                              "(\(space.total) bytes left, in pieces of at most \(space.largest))")
    }

    // MARK: Builder

    public static func build(base input: [UInt8], requests: [Request], songs songRequests: [SongRequest] = [],
                             characters characterRequests: [CharacterRequest] = [], techs: TechSystemDef? = nil,
                             items: ItemsRequest? = nil, maps: [GameMap] = [], tilesets: [CTTilesetPatch.Request] = [],
                             enemies enemyRequests: [EnemyRequest] = [], sprites spriteRequests: [CTSpritePatch.Request] = [],
                             textProfile: CTTextProfile?) throws -> (rom: [UInt8], report: Report) {
        var rom = input
        if rom.count == romSize + 512 { rom.removeFirst(512) }
        guard rom.count == romSize, CTEventPack.sha256(rom) == CTTextProfile.romHash else {
            throw CTROMBuildError("the base must be the unmodified Chrono Trigger US 1.0 ROM (SHA-256 06d1c2b0…829a9)")
        }
        let base = rom
        let entries = try CTEventROM.entries(rom: rom)
        var seen = Set<Int>()
        for r in requests {
            guard (0..<CTEventROM.pointerCount).contains(r.entry) else { throw CTROMBuildError("entry \(r.entry) is not 0-512") }
            guard !CTROMLayout.notEventPackEntries.contains(r.entry) else {
                throw CTROMBuildError("entry \(r.entry) does not point at an event pack in this ROM")
            }
            guard seen.insert(r.entry).inserted else { throw CTROMBuildError("entry \(r.entry) is built twice") }
            try checkPack(r)
        }
        let romSongs = try CTSong.romSongs(rom)
        var seenSongs = Set<Int>()
        for s in songRequests {
            guard romSongs.indices.contains(s.song) else { throw CTROMBuildError("song \(s.song) is not 0-\(romSongs.count - 1)") }
            guard seenSongs.insert(s.song).inserted else { throw CTROMBuildError("song \(s.song) is built twice") }
            try checkSong(s)
        }
        var seenCharacters = Set<Int>(), seenIDs = Set<String>()
        for c in characterRequests {
            guard seenIDs.insert(c.id).inserted else { throw CTROMBuildError("character \(c.id) is built twice") }
            try CTCharacterROM.check(c.record, growth: c.growth, rom: rom)
            guard seenCharacters.insert(c.record.charId).inserted else {
                throw CTROMBuildError("character \(c.id): record \(c.record.charId) is built twice")
            }
        }
        if let techs {
            try CTTechROM.check(techs)
            try CTTechROM.check(techs, against: CTTechROM.decode(rom: rom, codec: nil))
        }
        var seenEnemies = Set<Int>(), seenEnemyIDs = Set<String>()
        var enemyWrites: [(pc: Int, bytes: [UInt8], what: String)] = []
        for e in enemyRequests {
            guard seenEnemyIDs.insert(e.id).inserted else { throw CTROMBuildError("enemy \(e.id) is built twice") }
            try CTEnemyROM.check(e.enemy, name: e.name)
            guard seenEnemies.insert(e.enemy.enemyId).inserted else {
                throw CTROMBuildError("enemy \(e.id): record \(e.enemy.enemyId) is built twice")
            }
            enemyWrites += try CTEnemyROM.writes(e.enemy, id: e.id, name: e.name, base: rom)
        }
        // Sprites: checked and decoded back before anything is written (docs/sprites.md).
        let (spriteWrites, spriteReport) = try CTSpritePatch.writes(spriteRequests, base: rom)
        var itemWrites: [(pc: Int, bytes: [UInt8], what: String)] = []
        if let items {
            try CTItemROM.check(items.items, tables: items.tables)
            try CTItemROM.check(items.items, tables: items.tables, against: CTItemROM.decode(rom: rom, codec: nil))
            let codec = try CTTextCodec(profile: textProfile ?? CTTextProfile.fromROM(Data(rom)))
            itemWrites = try CTItemROM.writes(items.items, tables: items.tables, rom: rom, codec: codec)
        }

        // Spans of the streams still in use, and those the new packs free.
        func span(_ entry: Int) throws -> Range<Int> {
            let pc = entries[entry].pc
            let stream = try LZSS.decompressStream(Array(rom[pc..<min(rom.count, (pc | 0xFFFF) + 1)]))
            return pc..<(pc + stream.length)
        }
        let rebuilt = Set(requests.map(\.entry))
        var live = Set<Int>()
        for entry in 0..<CTEventROM.pointerCount where !rebuilt.contains(entry) { live.insert(entries[entry].pc) }
        var homes: [Int: Range<Int>] = [:]                 // old stream start -> span, now unused
        for entry in rebuilt where !live.contains(entries[entry].pc) { homes[entries[entry].pc] = try span(entry) }

        var space = FreeSpace()
        for region in CTROMLayout.freeRegions {
            guard rom[region.pc..<region.end].allSatisfy({ $0 == region.fill }) else {
                throw CTROMBuildError(String(format: "free region at $%06X is not filled as surveyed", region.pc))
            }
            space.add(region.pc..<region.end, reclaimed: false)
        }
        for home in homes.values { space.add(home, reclaimed: true) }
        // Songs: a u16 length and the data; a span may cross a bank (Audio_SendSongData steps the bank).
        let rebuiltSongs = Set(songRequests.map(\.song))
        let liveSongs = Set(romSongs.filter { !rebuiltSongs.contains($0.index) }.map(\.pc))
        var songHomes: [Int: Range<Int>] = [:]
        for s in romSongs where rebuiltSongs.contains(s.index) && !liveSongs.contains(s.pc) {
            songHomes[s.pc] = s.pc..<(s.pc + 2 + s.data.count)
        }
        for home in songHomes.values {
            var start = home.lowerBound
            while start < home.upperBound {
                let end = min(home.upperBound, (start | 0xFFFF) + 1)
                space.add(start..<end, reclaimed: true)
                start = end
            }
        }

        var writes: [Report.Write] = [], relocations: [Report.Relocation] = []
        func write(_ bytes: [UInt8], at pc: Int, _ what: String) {
            rom.replaceSubrange(pc..<(pc + bytes.count), with: bytes)
            writes.append(.init(pc: pc, length: bytes.count, what: what))
        }
        func relocated(_ what: String, from: Int?, to pc: Int, bytes: Int) {
            relocations.append(.init(what: what, from: from.map(snes), to: snes(pc), pc: pc, bytes: bytes))
        }

        // Maps and tilesets first: the exits may grow only into the padding right after them.
        let mapReport = maps.isEmpty ? nil : try CTMapPatch.apply(
            maps: maps, base: base, space: &space, write: { write($0, at: $1, $2) },
            relocated: { relocated($0, from: $1, to: $2, bytes: $3) })
        let tilesetReport = tilesets.isEmpty ? nil : try CTTilesetPatch.apply(
            requests: tilesets, base: base, space: &space, write: { write($0, at: $1, $2) },
            relocated: { relocated($0, from: $1, to: $2, bytes: $3) })

        // Message tables first: their addresses go inside the packs.
        let codec = try textProfile.map { try CTTextCodec(profile: $0) }
        var tables: [Report.MessageTable] = [], tableAt: [[UInt8]: Int] = [:], tableOf: [Int: Int] = [:]
        var unpacked: [Int: [UInt8]] = [:]
        for r in requests {
            var bytes = r.bytes
            if !r.messages.isEmpty {
                guard let codec else {
                    throw CTROMBuildError("entry \(r.entry) has dialogue; import the ROM text profile first")
                }
                let (table, strings) = try messageTable(r, codec: codec)
                let pc: Int
                if let shared = tableAt[table] {
                    pc = shared
                    let i = tables.firstIndex { $0.pc == pc }!
                    let t = tables[i]
                    tables[i] = .init(entries: t.entries + [r.entry], address: t.address, pc: pc, bytes: t.bytes, messages: t.messages)
                } else {
                    guard let at = space.allocate(table.count, reclaimed: false) else {
                        throw CTROMBuildError("no free space for the \(table.count)-byte message table of entry \(r.entry)")
                    }
                    pc = at
                    tableAt[table] = pc
                    // The entries are addresses in the table's bank: local offsets + its own.
                    var placed = table
                    for (i, string) in strings.enumerated() {
                        let address = (pc & 0xFFFF) + string.offset
                        placed[2 * i] = UInt8(address & 0xFF); placed[2 * i + 1] = UInt8(address >> 8)
                    }
                    write(placed, at: pc, "message table for entry \(r.entry)")
                    tables.append(.init(entries: [r.entry], address: snes(pc), pc: pc, bytes: table.count,
                                        messages: zip(r.messages, strings).map { message, string in
                                            .init(id: message.id, text: message.text, address: snes(pc + string.offset),
                                                  bytes: string.count)
                                        }))
                }
                tableOf[r.entry] = pc
                let pointer = [UInt8(pc & 0xFF), UInt8(pc >> 8 & 0xFF), UInt8(0xC0 | pc >> 16)]
                for offset in r.relocations { bytes.replaceSubrange(offset..<(offset + 3), with: pointer) }
            } else if !r.relocations.isEmpty {
                throw CTROMBuildError("entry \(r.entry) has message relocations but no messages")
            }
            unpacked[r.entry] = bytes
        }

        // Packs and songs: each first at its own old start, then shared, reclaimed, free.
        var packed: [Int: [UInt8]] = [:], packPC: [Int: (pc: Int, placement: String)] = [:]
        var songPC: [Int: (pc: Int, placement: String)] = [:]
        for r in requests {
            guard let p = LZSS.compress(unpacked[r.entry]!, mode: packMode) else { throw CTROMBuildError("entry \(r.entry): pack too large") }
            packed[r.entry] = p
            let home = entries[r.entry].pc
            if homes[home] != nil, space.allocate(p.count, at: home) { packPC[r.entry] = (home, "original") }
        }
        for s in songRequests {
            let home = romSongs[s.song].pc
            if let span = songHomes[home], 2 + s.data.count <= span.count, space.allocateSpanning(2 + s.data.count, at: home) {
                songPC[s.song] = (home, "original")
            }
        }
        func place(_ block: [UInt8], at: inout [[UInt8]: Int], _ what: String) throws -> (pc: Int, placement: String) {
            if let shared = at[block] { return (shared, "shared") }
            let pc: Int, placement: String
            if let p = space.allocate(block.count, reclaimed: true) { pc = p; placement = "reclaimed" }
            else if let p = space.allocate(block.count, reclaimed: false) { pc = p; placement = "free" }
            else {
                throw CTROMBuildError("no free space for the \(block.count)-byte \(what) " +
                                      "(\(space.total) bytes left, in pieces of at most \(space.largest))")
            }
            at[block] = pc
            return (pc, placement)
        }
        var packs: [Report.Pack] = [], packAt: [[UInt8]: Int] = [:]
        for r in requests { if let home = packPC[r.entry] { packAt[packed[r.entry]!] = home.pc } }
        for r in requests {
            let bytes = unpacked[r.entry]!, block = packed[r.entry]!
            let (pc, placement) = try packPC[r.entry] ?? place(block, at: &packAt, "pack of entry \(r.entry)")
            if placement != "shared" { write(block, at: pc, "event pack for entry \(r.entry)") }
            let pointer = CTEventROM.pointerTablePC + 3 * r.entry
            write([UInt8(pc & 0xFF), UInt8(pc >> 8 & 0xFF), UInt8(0xC0 | pc >> 16)], at: pointer, "Evt_PackPtrs[\(r.entry)]")
            packs.append(.init(entry: r.entry, source: r.source, address: snes(pc), pc: pc, packedBytes: block.count,
                               unpackedBytes: bytes.count, unpackedSHA256: CTEventPack.sha256(bytes),
                               placement: placement, messageTable: tableOf[r.entry].map(snes)))
        }
        var songs: [Report.Song] = [], songAt: [[UInt8]: Int] = [:]
        for s in songRequests {
            let block = [UInt8(s.data.count & 0xFF), UInt8(s.data.count >> 8)] + s.data
            if let home = songPC[s.song] { songAt[block] = home.pc }
        }
        for s in songRequests {
            let block = [UInt8(s.data.count & 0xFF), UInt8(s.data.count >> 8)] + s.data
            let (pc, placement) = try songPC[s.song] ?? place(block, at: &songAt, String(format: "song $%02X", s.song))
            if placement != "shared" { write(block, at: pc, String(format: "song $%02X", s.song)) }
            write([UInt8(pc & 0xFF), UInt8(pc >> 8 & 0xFF), UInt8(0xC0 | pc >> 16)],
                  at: CTSongISA.songTablePC + 3 * s.song, String(format: "Audio_SongTable[$%02X]", s.song))
            for row in s.tables.rows(song: s.song) {
                let name = row.pc < CTSongISA.drumsPC ? "AudioRom_SongSamples" : row.pc < CTSongISA.echoPC ? "AudioRom_SongExtra" : "AudioRom_SongEcho"
                write(row.bytes, at: row.pc, String(format: "%@[$%02X]", name, s.song))
            }
            songs.append(.init(song: s.song, source: s.source, address: snes(pc), pc: pc, bytes: s.data.count,
                               dataSHA256: CTEventPack.sha256(s.data), placement: placement, samples: s.tables.samples,
                               echo: s.tables.echo.map { $0.map(Int.init) }, drums: s.tables.drums.map { $0.map(Int.init) }))
        }

        // Characters: each decoded field in place; the record's other bytes stay the base ROM's.
        var characters: [Report.Character] = []
        for c in characterRequests {
            let pc = CTCharacterROM.recordPC(c.record.charId)
            for (field, bytes) in zip(CTCharacterROM.writableFields, CTCharacterROM.fieldBytes(c.record)) {
                write(bytes, at: pc + field.offset, "character \(c.id) \(field.name)")
            }
            if let growth = c.growth {
                let rows = CTCharacterROM.encodeGrowth(growth), id = c.record.charId
                write(rows.hp, at: CTCharacterROM.hpGrowthPC + CTCharacterROM.growthRow * id, "character \(c.id) HP growth")
                write(rows.mp, at: CTCharacterROM.mpGrowthPC + CTCharacterROM.growthRow * id, "character \(c.id) MP growth")
                write(rows.stats, at: CTCharacterROM.statGrowthPC + CTCharacterROM.statGrowthRow * id,
                      "character \(c.id) stat growth")
            }
            characters.append(.init(id: c.id, charId: c.record.charId, address: snes(pc), pc: pc, record: c.record,
                                    growth: c.growth))
        }

        // Techs: each writable field in place over the base ROM's tables (docs/techs.md).
        if let techs {
            for w in CTTechROM.writes(techs, rom: base) { write(w.bytes, at: w.pc, w.what) }
        }
        // Items: records, names and ItemBoosts in place; the descriptions repacked in their own span.
        for w in itemWrites { write(w.bytes, at: w.pc, w.what) }
        // Enemies: the stat and reward records field by field, the name in place (docs/enemies.md).
        for w in enemyWrites { write(w.bytes, at: w.pc, w.what) }
        // Sprites: frame records, changed tiles, animation rows and colours 1-12 in place.
        for w in spriteWrites { write(w.bytes, at: w.pc, w.what) }
        let enemyReport = enemyRequests.map { e -> Report.Enemy in
            let pc = CTEnemyROM.statsPC(e.enemy.enemyId)
            let wroteName = enemyWrites.contains { $0.what == "enemy \(e.id) name" }
            let named = wroteName ? e.name : nil
            return .init(id: e.id, enemyId: e.enemy.enemyId, address: snes(pc), pc: pc, name: named, enemy: e.enemy)
        }

        let sum = checksum(rom)
        write([UInt8(~sum & 0xFF), UInt8(~sum >> 8 & 0xFF), UInt8(sum & 0xFF), UInt8(sum >> 8)],
              at: CTROMLayout.complementPC, "checksum")
        // Drop writes that changed nothing (an identical rebuild), keeping the report about real edits.
        let changed = writes.filter { w in (w.pc..<(w.pc + w.length)).contains { rom[$0] != base[$0] } }
        var report = Report(schema: "ct-rom-build/1", baseSHA256: CTEventPack.sha256(base),
                            outputSHA256: CTEventPack.sha256(rom), checksum: sum, packs: packs,
                            messageTables: tables, songs: songs, characters: characters.isEmpty ? nil : characters,
                            techs: techs, items: items?.items, itemTables: items?.tables,
                            writes: changed, freeBytesLeft: space.total, maps: mapReport, tilesets: tilesetReport,
                            relocations: relocations.isEmpty ? nil : relocations)
        report.enemies = enemyReport.isEmpty ? nil : enemyReport
        report.sprites = spriteRequests.isEmpty ? nil : spriteReport
        return (rom, report)
    }

    /// Checks LocLoad_CheckEvtData makes after unpacking, and that the pack
    /// decodes with the derived opcode table.
    static func checkPack(_ r: Request) throws {
        guard !r.bytes.isEmpty, r.bytes.count <= CTROMLayout.eventDataMax else {
            throw CTROMBuildError("entry \(r.entry): \(r.bytes.count) unpacked bytes; the game accepts 1-\(CTROMLayout.eventDataMax)")
        }
        guard !(r.bytes.count > 1 && r.bytes[0] == 0x0D && r.bytes[1] == 0x0A) else {
            throw CTROMBuildError("entry \(r.entry): 13 objects with a first script byte $0A halt the game (LocLoad_CheckEvtData)")
        }
        do { _ = try CTEventPack(bytes: r.bytes) }
        catch { throw CTROMBuildError("entry \(r.entry): \(error)") }
        for offset in r.relocations where offset < 1 || offset + 3 > r.bytes.count {
            throw CTROMBuildError("entry \(r.entry): relocation at \(offset) is outside the pack")
        }
    }

    /// The driver's limits: the tracks walk cleanly and the transfer stops before $4700.
    static func checkSong(_ s: SongRequest) throws {
        guard CTSongISA.fits(s.data.count) else {
            throw CTROMBuildError(String(format: "song $%02X: %d bytes; the most that loads below $4700 is %d",
                                         s.song, s.data.count, CTSongISA.maxLength))
        }
        do { _ = try CTSong(data: s.data).walk(); try s.tables.validate() }
        catch { throw CTROMBuildError(String(format: "song $%02X: %@", s.song, "\(error)")) }
    }

    /// A word per message, then the messages; identical messages share their
    /// bytes. The words hold offsets from the table's start until it is placed.
    static func messageTable(_ r: Request, codec: CTTextCodec) throws -> ([UInt8], [(offset: Int, count: Int)]) {
        guard r.messages.count <= 256 else { throw CTROMBuildError("entry \(r.entry): more than 256 messages") }
        var body: [UInt8] = [], at: [[UInt8]: Int] = [:], strings: [(offset: Int, count: Int)] = []
        let head = 2 * r.messages.count
        for message in r.messages {
            let bytes: [UInt8]
            do { bytes = try codec.compileMessage(message.text) }
            catch { throw CTROMBuildError("dialogue \(message.id): \(error)") }
            let offset = at[bytes] ?? head + body.count
            if at[bytes] == nil { at[bytes] = offset; body += bytes }
            strings.append((offset, bytes.count))
        }
        guard head + body.count <= 0x10000 else { throw CTROMBuildError("entry \(r.entry): message table exceeds a bank") }
        return (strings.flatMap { [UInt8($0.offset & 0xFF), UInt8($0.offset >> 8)] } + body, strings)
    }

    /// SNES header checksum: the sum of all bytes with the complement $FFFF
    /// and the checksum $0000 (reproduces the US 1.0 header).
    public static func checksum(_ rom: [UInt8]) -> Int {
        var sum = 0
        for (i, b) in rom.enumerated() {
            switch i {
            case CTROMLayout.complementPC, CTROMLayout.complementPC + 1: sum += 0xFF
            case CTROMLayout.checksumPC, CTROMLayout.checksumPC + 1: break
            default: sum += Int(b)
            }
        }
        return sum & 0xFFFF
    }

    static func snes(_ pc: Int) -> String { String(format: "$%02X:%04X", 0xC0 | pc >> 16, pc & 0xFFFF) }
}

/// Free byte ranges, never crossing a bank. Reclaimed ranges (old packs) are
/// kept apart so packs can prefer them and message tables avoid them.
struct FreeSpace {
    private var ranges: [(range: Range<Int>, reclaimed: Bool)] = []

    mutating func add(_ range: Range<Int>, reclaimed: Bool) {
        precondition(range.lowerBound >> 16 == (range.upperBound - 1) >> 16, "free range crosses a bank")
        ranges.append((range, reclaimed))
        ranges.sort { $0.range.lowerBound < $1.range.lowerBound }
    }

    var total: Int { ranges.reduce(0) { $0 + $1.range.count } }
    var largest: Int { ranges.map(\.range.count).max() ?? 0 }

    /// First range of the kind with room (in `bank`, a PC bank, when given), lowest address first.
    mutating func allocate(_ size: Int, reclaimed: Bool, bank: Int? = nil) -> Int? {
        guard let i = ranges.firstIndex(where: {
            $0.reclaimed == reclaimed && $0.range.count >= size && (bank == nil || $0.range.lowerBound >> 16 == bank)
        }) else { return nil }
        let start = ranges[i].range.lowerBound
        take(i, start..<(start + size))
        return start
    }

    /// Exactly at `start`, when free.
    mutating func allocate(_ size: Int, at start: Int) -> Bool {
        guard let i = ranges.firstIndex(where: { $0.range.lowerBound == start && $0.range.count >= size }) else { return false }
        take(i, start..<(start + size))
        return true
    }

    /// Exactly at `start`, across adjacent ranges (a song may cross a bank).
    mutating func allocateSpanning(_ size: Int, at start: Int) -> Bool {
        guard var i = ranges.firstIndex(where: { $0.range.lowerBound == start }) else { return false }
        var end = ranges[i].range.upperBound
        while end - start < size, i + 1 < ranges.count, ranges[i + 1].range.lowerBound == end {
            i += 1; end = ranges[i].range.upperBound
        }
        guard end - start >= size else { return false }
        var at = start
        while at < start + size {
            let j = ranges.firstIndex { $0.range.lowerBound == at }!
            let piece = ranges[j].range
            take(j, at..<min(piece.upperBound, start + size))
            at = piece.upperBound
        }
        return true
    }

    private mutating func take(_ i: Int, _ used: Range<Int>) {
        let (range, reclaimed) = ranges[i]
        ranges.remove(at: i)
        if used.upperBound < range.upperBound { ranges.insert((used.upperBound..<range.upperBound, reclaimed), at: i) }
    }
}
