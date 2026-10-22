// Validator.swift — the six .ctproj validation gates (docs/ctproj_schema.md).
import Foundation

public struct ValidationIssue: Equatable, Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var gate: Int
    public var severity: Severity
    public var path: String
    public var message: String

    public init(gate: Int, severity: Severity, path: String, message: String) {
        self.gate = gate; self.severity = severity; self.path = path; self.message = message
    }
    public var description: String { "gate\(gate) [\(severity.rawValue)] \(path): \(message)" }
}

public enum Validator {
    /// SNES engine budgets.
    public static let oamBudget = 512           // entries per frame (engine rule)
    public static let oamBudgetLarge = 1024     // large-sprite modes
    public static let vramBytesTotal = 65_536   // SNES VRAM
    public static let bgLayerBudget = 16_384    // per-BG tile-cache budget (bytes)

    /// BRR error envelope for gate 6: per-sample max abs error the SNES
    /// DAC path tolerates for a re-encode of a decoded sample.
    public static var brrEnvelope: Int { 2048 }

    public static func validate(_ p: CTProject) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func err(_ gate: Int, _ path: String, _ msg: String) {
            issues.append(.init(gate: gate, severity: .error, path: path, message: msg))
        }
        func warn(_ gate: Int, _ path: String, _ msg: String) {
            issues.append(.init(gate: gate, severity: .warning, path: path, message: msg))
        }

        // ---------------- Gate 1: references + PNG format ----------------
        let pr = p.project
        if pr.schema != "ctproj/1" { err(1, "project.json", "unknown schema \(pr.schema)") }
        if p.maps[pr.start.map] == nil { err(1, "project.json", "start.map \"\(pr.start.map)\" not found in maps/") }
        if !pr.eras.contains(where: { $0.id == pr.start.era }) { err(1, "project.json", "start.era \"\(pr.start.era)\" not found in eras") }
        for era in pr.eras {
            for m in era.maps where p.maps[m] == nil {
                err(1, "project.json", "era \(era.id) references missing map \"\(m)\"")
            }
        }
        for enc in pr.encounters {
            for e in enc.enemies {
                guard let c = p.characters[e] else {
                    err(1, "project.json", "encounter \(enc.id) references missing enemy \"\(e)\""); continue
                }
                if c.kind != "enemy" { warn(1, "project.json", "encounter \(enc.id): \"\(e)\" is kind \"\(c.kind)\", not an enemy") }
            }
        }
        for (id, c) in p.characters {
            if let s = c.sprite, p.sprites[s] == nil { err(1, "characters/\(id).json", "sprite \"\(s)\" not found") }
        }
        for (id, t) in p.techs {
            for u in t.users where p.characters[u] == nil { err(1, "techs/\(id).json", "user \"\(u)\" not found") }
        }
        for (id, m) in p.maps {
            guard let ts = p.tilesets[m.tileset] else {
                err(1, "maps/\(id).map.json", "tileset \"\(m.tileset)\" not found"); continue
            }
            for tr in m.triggers where p.scenes[tr.scene] == nil {
                err(1, "maps/\(id).map.json", "trigger scene \"\(tr.scene)\" not found")
            }
            for ex in m.exits where p.maps[ex.map] == nil {
                err(1, "maps/\(id).map.json", "exit to missing map \"\(ex.map)\"")
            }
            for layer in m.layers {
                for mt in layer.metatiles where mt >= ts.metatiles.count {
                    err(1, "maps/\(id).map.json", "layer BG\(layer.bg) metatile index \(mt) >= \(ts.metatiles.count)")
                }
            }
            for (mi, mt) in ts.metatiles.enumerated() {
                for chip in mt.chips where chip.tile >= ts.tileCount {
                    err(1, "tilesets/\(ts.id).tileset.json", "metatile \(mi) tile index \(chip.tile) >= tileCount \(ts.tileCount)")
                }
            }
        }
        // PNG format checks (mode P, color budget by depth)
        func checkPNG(_ rel: String, owner: String, bpp: Int) {
            let u = p.fileURL(relative: rel)
            guard FileManager.default.fileExists(atPath: u.path) else {
                err(1, owner, "sheet \(rel) missing"); return
            }
            do {
                let png = try PNG.readIndexed(url: u)
                if png.width % 8 != 0 || png.height % 8 != 0 {
                    err(1, owner, "sheet \(rel) not a multiple of 8px")
                }
                if png.bitDepth != bpp {
                    err(1, owner, "sheet \(rel) bitDepth \(png.bitDepth) != bpp \(bpp)")
                }
                let limit = bpp == 2 ? 4 : 16
                if png.palette.count > limit {
                    err(1, owner, "sheet \(rel) PLTE has \(png.palette.count) colors (limit \(limit))")
                }
                if png.colorsUsed > limit {
                    err(1, owner, "sheet \(rel) uses \(png.colorsUsed) colors (limit \(limit))")
                }
            } catch {
                err(1, owner, "sheet \(rel): \(error)")
            }
        }
        for (id, s) in p.sprites { checkPNG(s.sheet, owner: "sprites/\(id).sprite.json", bpp: s.bpp) }
        for (id, ts) in p.tilesets {
            if let sheet = ts.sheet { checkPNG(sheet, owner: "tilesets/\(id).tileset.json", bpp: ts.bpp) }
            if let blob = ts.blob, !FileManager.default.fileExists(atPath: p.fileURL(relative: blob).path) {
                err(1, "tilesets/\(id).tileset.json", "blob \(blob) missing")
            }
        }
        // Event-script references resolve
        let flagSyms = Set(pr.flags.map(\.symbol))
        for (id, sc) in p.scenes {
            for message in EventReferences.issues(in: sc.scene, flags: flagSyms,
                strings: Set(p.dialogue.strings.keys), maps: Set(p.maps.keys), scenes: p.scenes.mapValues(\.scene)) {
                err(1, "scenes/\(id).event.json", message)
            }
        }

        // ---------------- Gate 2: OAM budget per frame ----------------
        for (id, s) in p.sprites {
            for (fi, f) in s.frames.enumerated() {
                let budget = (f.large == true) ? oamBudgetLarge : oamBudget
                if f.tiles.count > budget {
                    err(2, "sprites/\(id).sprite.json", "frame \(fi) has \(f.tiles.count) OAM entries (budget \(budget))")
                }
            }
        }

        // ---------------- Gate 3: tile bank VRAM budget ----------------
        for (id, ts) in p.tilesets {
            // VRAM tile size: 4bpp = 16 B, 2bpp = 8 B.
            let vramPerTile = ts.bpp == 2 ? 8 : 16
            let bytes = ts.tileCount * vramPerTile
            if bytes > bgLayerBudget {
                err(3, "tilesets/\(id).tileset.json", "tile bank \(bytes) B exceeds per-BG budget \(bgLayerBudget) B")
            }
        }
        for (id, m) in p.maps {
            var total = 0
            for layer in m.layers {
                if let ts = p.tilesets[m.tileset] {
                    total += ts.tileCount * (ts.bpp == 2 ? 8 : 16)
                }
            }
            if total > vramBytesTotal {
                err(3, "maps/\(id).map.json", "layers need \(total) B VRAM (total \(vramBytesTotal) B)")
            }
        }

        // ---------------- Gate 4: event compile -> bytecode -> AST ----------------
        for (id, sc) in p.scenes {
            // A scene that cannot be lowered only warns unless a ROM build uses it.
            // It is lowered with the scenes its call_obj statements reach.
            var group = [id], todo = [sc.scene]
            while let scene = todo.popLast() {
                func reach(_ stmts: [EventStmt]) {
                    for stmt in stmts {
                        switch stmt {
                        case .callObject(let target, _, _, _) where !group.contains(target) && p.scenes[target] != nil:
                            group.append(target); todo.append(p.scenes[target]!.scene)
                        case .ifFlag(_, let t, let e): reach(t); reach(e)
                        default: break
                        }
                    }
                }
                for f in scene.funcs { reach(f.stmts) }
            }
            do { _ = try CTEventLowering.lower(project: p, scenes: group) }
            catch { warn(4, "scenes/\(id).event.json", "no CT event bytecode: \(error)") }
            do {
                try EventBytecode.validate(sc.scene)
                let code = try EventBytecode.compile(sc.scene.funcs)
                let back = try EventBytecode.decompile(code)
                if back != sc.scene.funcs {
                    err(4, "scenes/\(id).event.json", "bytecode round-trip changed the AST")
                }
            } catch {
                err(4, "scenes/\(id).event.json", "bytecode round-trip failed: \(error)")
            }
            let dsl = p.url.appendingPathComponent("scenes/\(id).event.dsl")
            if !FileManager.default.fileExists(atPath: dsl.path) {
                warn(4, "scenes/\(id).event.json", "canonical .event.dsl missing; save to generate it")
            } else {
                do {
                    let parsed = try EventDSL.parse(String(contentsOf: dsl, encoding: .utf8))
                    if parsed.object != sc.scene.object || parsed.funcs != sc.scene.funcs {
                        warn(4, "scenes/\(id).event.dsl", "on-disk source differs from the current scene; save to synchronize")
                    }
                } catch { err(4, "scenes/\(id).event.dsl", "\(error)") }
            }
        }

        // ROM build settings (project.json rom): entries, songs and sources; packs are
        // otherwise checked by CTROMBuilder against the base ROM at build time.
        if let spec = pr.rom {
            var entries = Set<Int>()
            for pack in spec.eventPacks {
                let path = "project.json rom entry \(pack.entry)"
                if !(0..<CTEventROM.pointerCount).contains(pack.entry) || CTROMLayout.notEventPackEntries.contains(pack.entry) {
                    err(4, path, "not an Evt_PackPtrs entry that points at an event pack")
                }
                if !entries.insert(pack.entry).inserted { err(4, path, "entry built twice") }
                switch (pack.scenes, pack.listing) {
                case (let scenes?, nil):
                    for id in scenes where p.scenes[id] == nil { err(4, path, "scene \"\(id)\" not found") }
                    if scenes.isEmpty { err(4, path, "no scenes") }
                    else if (try? CTEventLowering.lower(project: p, scenes: scenes)) == nil {
                        err(4, path, "scenes do not lower to CT event bytecode")
                    }
                case (nil, let listing?):
                    if !FileManager.default.fileExists(atPath: p.fileURL(relative: listing).path) {
                        err(4, path, "listing \(listing) not found")
                    }
                default: err(4, path, "give exactly one of scenes or listing")
                }
            }
            var songs = Set<Int>()
            for song in spec.songs {
                let path = "project.json rom song \(song.song)"
                if !(0..<CTSongISA.romSongCount).contains(song.song) { err(4, path, "not an Audio_SongTable index (0-\(CTSongISA.romSongCount - 1))") }
                if !songs.insert(song.song).inserted { err(4, path, "song built twice") }
                if song.listing.hasPrefix("/") || song.listing.split(separator: "/").contains("..") {
                    err(4, path, "listing path must stay inside the project")
                } else if let text = try? String(contentsOf: p.fileURL(relative: song.listing), encoding: .utf8) {
                    do { _ = try CTSongListing.assemble(text) } catch { err(4, path, "\(song.listing): \(error)") }
                } else { err(4, path, "listing \(song.listing) not found") }
            }
            // Samples (docs/sfx_lab.md): the file, its BRR blocks and loop, the slot and the songs.
            var sampleIDs = Set<String>(), replacedSamples = Set<Int>()
            var sampleLengths: [Int: Int] = [:], sampleNumbers: [String: Int] = [:], appendedSamples = 0
            for s in spec.samples {
                let path = "project.json rom sample \(s.id)"
                if !sampleIDs.insert(s.id).inserted { err(4, path, "sample listed twice"); continue }
                if let n = s.replace, !replacedSamples.insert(n).inserted { err(4, path, "sample \(n) replaced twice") }
                for song in s.songs where !(0..<CTSongISA.romSongCount).contains(song) {
                    err(4, path, "song \(song) is not an Audio_SongTable index (0-\(CTSongISA.romSongCount - 1))")
                }
                let number = s.replace ?? CTSampleTables.rom.count + 1 + appendedSamples
                if s.replace == nil { appendedSamples += 1 }
                sampleNumbers[s.id] = number
                do {
                    let request = try CTROMBuilder.sampleRequest(s, project: p)
                    try CTSamplePatch.check(request)
                    sampleLengths[number] = request.brr.count
                } catch { err(4, path, "\(error)") }
            }
            if CTSampleTables.rom.count + appendedSamples > CTSampleTables.numberMax {
                err(4, "project.json rom samples", "at most \(CTSampleTables.numberMax - CTSampleTables.rom.count) samples can be appended")
            }
            // Sample budgets of songs built from listings (the listing check above
            // covers the sequence): at most 16 samples, and project samples that
            // cannot fit below the echo buffer even from $4700 (the build checks
            // the exact start with the ROM's own samples).
            for song in spec.songs {
                let path = "project.json rom song \(song.song)"
                guard !song.listing.hasPrefix("/"), !song.listing.split(separator: "/").contains(".."),
                      let text = try? String(contentsOf: p.fileURL(relative: song.listing), encoding: .utf8),
                      let tables = try? CTSongListing.assembleSong(text).tables else { continue }
                guard let own = tables.samples, let echo = tables.echo else { continue }
                var list = own
                for s in spec.samples where s.songs.contains(song.song) {
                    if let n = sampleNumbers[s.id], !list.contains(n) { list.append(n) }
                }
                if list.count > 16 { err(4, path, "loads \(list.count) samples; a song loads at most 16") }
                let known: [Int] = list.compactMap { sampleLengths[$0] }
                let bytes = known.reduce(0, +)
                let room = CTSongEcho.buffer(edl: Int(echo[0] & 0x0F)).lowerBound - 0x4700
                if bytes > room {
                    err(4, path, "its project samples alone take \(bytes) bytes; at most \(room) fit below the echo buffer")
                }
            }
            // Characters: a file with a pc record each, no record twice, values in the game's ranges.
            var characterIDs = Set<String>(), records = Set<Int>()
            for id in spec.characters {
                let path = "project.json rom character \(id)"
                if !characterIDs.insert(id).inserted { err(4, path, "character built twice"); continue }
                guard let c = p.characters[id] else { err(4, path, "no characters/\(id).json"); continue }
                guard let r = c.pc else { err(4, path, "no pc record; import the ROM's characters"); continue }
                if !records.insert(r.charId).inserted { err(4, path, "record \(r.charId) built twice") }
                if let party = p.party {
                    do { try CTCharacterROM.check(r, growth: c.growth, party: party) } catch { err(4, "characters/\(id).json", "\(error)") }
                } else { warn(4, path, "no party.json: equipment and ranges are checked only by the build") }
            }
            // Enemies: a file with an enemy record each, no enemy id twice, values in the game's ranges.
            var enemyFiles = Set<String>(), enemyIDs = Set<Int>()
            for id in spec.enemies {
                let path = "project.json rom enemy \(id)"
                if !enemyFiles.insert(id).inserted { err(4, path, "enemy built twice"); continue }
                guard let c = p.characters[id] else { err(4, path, "no characters/\(id).json"); continue }
                guard let e = c.enemy else { err(4, path, "no enemy record; import the ROM's enemies"); continue }
                if !enemyIDs.insert(e.enemyId).inserted { err(4, path, "enemy \(e.enemyId) built twice") }
                do { try CTEnemyROM.check(e, name: CTEnemyROM.writableName(c)) } catch { err(4, "characters/\(id).json", "\(error)") }
                // The AI script `rom build` writes back: it parses, its codes are known, the game can step it.
                if let text = e.ai?.text {
                    do { _ = try CTEnemyAIPatch.assemble(text: text, lengths: CTEnemyAIPatch.listedLengths) }
                    catch { err(4, "characters/\(id).json", "AI: \(error)") }
                }
            }
            if !spec.enemies.isEmpty {
                let budget = CTEnemyAIPatch.budget(p)
                if budget.used > CTEnemyAIPatch.freeBytes {
                    err(4, "project.json rom enemies", "edited AI scripts that are shared or grow need \(budget.used) bytes " +
                        "of bank $CC's padding; it has \(CTEnemyAIPatch.freeBytes)")
                }
                if !budget.unknown.isEmpty {
                    warn(4, "project.json rom enemies", "\(budget.unknown.count) AI scripts were imported without their size; " +
                         "re-import the enemies to check the bank $CC budget before a build")
                }
            }
            if spec.techs {
                if let system = p.techSystem {
                    do { try CTTechROM.check(system) } catch { err(4, "tech_system.json", "\(error)") }
                    // +$2D is the next single's cost when the new game starts (the ROM's own records agree).
                    for id in spec.characters {
                        guard let r = p.characters[id]?.pc, system.learned.counts.indices.contains(r.charId),
                              system.tpCost.indices.contains(r.charId) else { continue }
                        let n = system.learned.counts[r.charId]
                        if n < 8, system.tpCost[r.charId].indices.contains(n), r.techPointsToNext != system.tpCost[r.charId][n] {
                            warn(4, "characters/\(id).json", "tech points to next \(r.techPointsToNext) is not the cost of single \(n + 1) (\(system.tpCost[r.charId][n]))")
                        }
                    }
                } else { err(4, "project.json rom techs", "no tech_system.json; import the ROM's techs") }
            }
            // Items: each ROM item file in its category's ranges, no item id twice, the shared tables.
            if spec.items {
                let romItems = p.items.filter { $0.value.rom != nil }.sorted { $0.key < $1.key }
                if romItems.isEmpty && p.itemTables == nil {
                    err(4, "project.json rom items", "no ROM items or item_tables.json; import the ROM's items")
                }
                var itemIds: [Int: String] = [:]
                for (id, item) in romItems {
                    do { try CTItemROM.check([item], tables: nil) } catch { err(4, "items/\(id).json", "\(error)") }
                    if let other = itemIds.updateValue(id, forKey: item.rom!.itemId) {
                        err(4, "items/\(id).json", String(format: "item $%02X is also items/%@.json", item.rom!.itemId, other))
                    }
                }
                if let tables = p.itemTables {
                    do { try CTItemROM.check([], tables: tables) } catch { err(4, "item_tables.json", "\(error)") }
                }
                // Descriptions: with a text profile (the build checks them with the base ROM's own).
                if let codec = p.textProfile.flatMap({ try? CTTextCodec(profile: $0) }) {
                    for (id, item) in romItems {
                        guard let text = item.description else { continue }
                        do { _ = try codec.compileMessage(text) } catch { err(4, "items/\(id).json", "description: \(error)") }
                    }
                }
            }
            // Maps and tilesets: ids, their ROM sources, sizes and ranges (the build adds the base ROM's checks).
            var locations: [Int: String] = [:]
            for id in Set(spec.maps).sorted() {
                let path = "project.json rom map \(id)"
                if spec.maps.filter({ $0 == id }).count > 1 { err(4, path, "map built twice") }
                guard let m = p.maps[id] else { err(4, path, "no maps/\(id).map.json"); continue }
                if let loc = m.rom?.location, let other = locations.updateValue(id, forKey: loc) {
                    err(4, "maps/\(id).map.json", "location \(loc) is also maps/\(other).map.json")
                }
                for problem in CTMapPatch.validate(m) { err(4, "maps/\(id).map.json", problem) }
            }
            // Sprites: ids exist, one per set, the PC family's format (the build adds the base ROM's checks).
            var spriteSets: [Int: String] = [:]
            for id in Set(spec.sprites).sorted() {
                let path = "project.json rom sprite \(id)"
                if spec.sprites.filter({ $0 == id }).count > 1 { err(4, path, "sprite built twice") }
                guard let s = p.sprites[id] else { err(4, path, "no sprites/\(id).sprite.json"); continue }
                if let set = s.rom?.set, s.rom?.family == CTSpritePatch.family, let other = spriteSets.updateValue(id, forKey: set) {
                    err(4, "sprites/\(id).sprite.json", "set \(set) is also sprites/\(other).sprite.json")
                }
                for problem in CTSpritePatch.validate(s) { err(4, "sprites/\(id).sprite.json", problem) }
            }
            for id in Set(spec.tilesets).sorted() {
                let path = "project.json rom tileset \(id)"
                if spec.tilesets.filter({ $0 == id }).count > 1 { err(4, path, "tileset built twice") }
                guard let ts = p.tilesets[id] else { err(4, path, "no tilesets/\(id).tileset.json"); continue }
                for problem in CTTilesetPatch.validate(ts) { err(4, "tilesets/\(id).tileset.json", problem) }
            }
        }

        // ---------------- Gate 5: explicit ROM-backed text or legacy Studio format ----------------
        if let profile = p.textProfile {
            do {
                let codec = try CTTextCodec(profile: profile)
                for (sid, text) in p.dialogue.strings.sorted(by: { $0.key < $1.key }) {
                    do {
                        let bytes = try codec.compileMessage(text)
                        if try codec.encode(codec.decode(bytes)) != bytes {
                            err(5, "strings/dialogue.json", "string \(sid) failed CT byte round-trip")
                        }
                    } catch { err(5, "strings/dialogue.json", "string \(sid): \(error)") }
                }
            } catch { err(5, "strings/ct-text-profile.json", "\(error)") }
        } else {
            warn(5, "strings/dialogue.json", "no ROM text profile: only the legacy Studio codec is checked; CT export is unavailable")
            for (sid, text) in p.dialogue.strings {
                let back = TextCodec.decode(TextCodec.encode(text))
                if back != text { err(5, "strings/dialogue.json", "string \(sid) failed legacy text round-trip") }
            }
        }

        // ---------------- Gate 6: BRR encode/decode + loop boundaries ----------------
        for (id, meta) in p.samples {
            let brrURL = p.fileURL(relative: meta.brr)
            guard let data = try? Data(contentsOf: brrURL) else {
                err(6, "audio/samples/\(id).json", "brr \(meta.brr) missing"); continue
            }
            let blob = [UInt8](data)
            let dec = BRR.decodeBlob(blob)
            if dec.invalidHeaders > 0 {
                err(6, "audio/samples/\(id).json", "\(dec.invalidHeaders) invalid BRR headers")
            }
            if !dec.endBitSet {
                err(6, "audio/samples/\(id).json", "last BRR block missing end bit")
            }
            if meta.loop {
                if let s = meta.loopStartSample, s % 16 != 0 {
                    err(6, "audio/samples/\(id).json", "loopStart \(s) not on a 16-sample block boundary")
                }
                if let e = meta.loopEndSample, e % 16 != 0 {
                    err(6, "audio/samples/\(id).json", "loopEnd \(e) not on a 16-sample block boundary")
                }
            }
            // Envelope check against the decoded-preview WAV when present.
            let wavURL = brrURL.deletingPathExtension().appendingPathExtension("wav")
            if FileManager.default.fileExists(atPath: wavURL.path) {
                do {
                    let wav = try WAV.read(url: wavURL)
                    let reencoded = BRR.encode(wav.samples)
                    let back = BRR.decode(reencoded, off: 0, nBlocks: reencoded.count / 9)
                    var maxErr = 0
                    for i in 0..<min(wav.samples.count, back.samples.count) {
                        maxErr = max(maxErr, abs(Int(wav.samples[i]) - Int(back.samples[i])))
                    }
                    if maxErr > Validator.brrEnvelope {
                        err(6, "audio/samples/\(id).json", "re-encode error \(maxErr) exceeds envelope \(Validator.brrEnvelope)")
                    }
                } catch {
                    warn(6, "audio/samples/\(id).json", "wav preview unreadable: \(error)")
                }
            }
        }

        return issues
    }

    public static func isValid(_ issues: [ValidationIssue]) -> Bool {
        !issues.contains { $0.severity == .error }
    }
}
