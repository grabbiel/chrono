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
            for e in enc.enemies where p.characters[e] == nil {
                err(1, "project.json", "encounter \(enc.id) references missing enemy \"\(e)\"")
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
