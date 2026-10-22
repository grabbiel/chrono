import Foundation
import ChronoForgeCore

private let charactersUsage = """
usage: chronoforge characters import <rom.sfc> --project <project.ctproj>
       chronoforge characters show <project.ctproj | rom.sfc>
       chronoforge characters curve <project.ctproj | rom.sfc> <character> [--json]
       chronoforge characters techs import <rom.sfc> --project <project.ctproj>
       chronoforge characters techs show <project.ctproj | rom.sfc> [<character>] [--json]
       chronoforge characters techs tp <project.ctproj | rom.sfc> --party <c,c,c> --award <n[,n...]> [--unlock <mask>] [--json]
         <character>: a project character id, a name (crono ... magus) or 0-6
         --party: three characters, "-" for an empty slot; --unlock: the $7F:01E0 bits (1 << id) that open magic
"""

/// (id, record, growth) of each PC record, from a project or a ROM; the
/// experience table; equipment names when a project has party.json.
private func loadCharacters(_ path: String) throws
    -> (characters: [(id: String, record: CharacterDef.Record, growth: CharacterDef.Growth?)], expToLevel: [Int]?, items: [Int: String]) {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        let project = try CTProject.load(from: URL(fileURLWithPath: path))
        let characters = project.characters.compactMap { id, c in c.pc.map { (id: id, record: $0, growth: c.growth) } }
            .sorted { $0.record.charId < $1.record.charId }
        let items = Dictionary(uniqueKeysWithValues: (project.party?.equipment ?? []).map { ($0.id, $0.name) })
        return (characters, project.party?.expToLevel, items)
    }
    let rom = try readROM(path)
    let characters = (0..<CTCharacterROM.count).map { id in
        let pc = CTCharacterROM.recordPC(id)
        return (id: CTCharacterROM.names[id], record: CTCharacterROM.decode(record: Array(rom[pc..<(pc + CTCharacterROM.recordSize)])),
                growth: Optional(CTCharacterROM.decodeGrowth(rom: rom, id: id)))
    }
    return (characters, CTCharacterROM.expToLevel(rom: rom), [:])
}

/// The tech system and the characters' tech-point fields, from a project
/// (tech_system.json and its records) or a ROM.
private func loadTechs(_ path: String) throws -> (system: TechSystemDef, records: [Int: CharacterDef.Record]) {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        let project = try CTProject.load(from: URL(fileURLWithPath: path))
        guard let system = project.techSystem else {
            throw CTROMBuildError("\(path) has no tech_system.json (chronoforge characters techs import)")
        }
        var records: [Int: CharacterDef.Record] = [:]
        for c in project.characters.values { if let r = c.pc { records[r.charId] = r } }
        return (system, records)
    }
    let rom = try readROM(path)
    let codec = try CTTextCodec(profile: CTTextProfile.fromROM(Data(rom)))
    var records: [Int: CharacterDef.Record] = [:]
    for id in 0..<CTCharacterROM.count {
        let pc = CTCharacterROM.recordPC(id)
        records[id] = CTCharacterROM.decode(record: Array(rom[pc..<(pc + CTCharacterROM.recordSize)]))
    }
    return (try CTTechROM.decode(rom: rom, codec: codec), records)
}

private func characterIndex(_ key: String) -> Int? {
    if let n = Int(key), (0..<CTCharacterROM.count).contains(n) { return n }
    return CTCharacterROM.names.firstIndex(of: key.lowercased())
}

private func techLine(_ s: TechSystemDef, _ id: Int) -> String {
    let t = s.techs[id]
    let mp = t.parts.map { $0 & 0x80 != 0 ? "-" : String(s.parts[$0 & 0x7F].mp) }.joined(separator: "/")
    var line = String(format: "$%02X %-11@ MP %@  target %02X", id, t.name as NSString, mp, t.targetMode)
    if t.area != 0 { line += String(format: " area %d", t.area) }
    if let e = t.element { line += " \(e)" }
    if t.needsUnlock { line += " (needs the unlock)" }
    if s.isLearned(id) { line += " learned" }
    return line
}

private func cmdTechs(_ args: [String], json: Bool, options: [String: String]) throws -> Int32 {
    guard let operation = args.first else { print(charactersUsage); return 2 }
    let positional = Array(args.dropFirst())
    switch operation {
    case "import":
        guard positional.count == 1, let path = options["--project"] else { print(charactersUsage); return 2 }
        var project = try CTProject.load(from: URL(fileURLWithPath: path))
        try CTTechROM.importTechs(rom: try readROM(positional[0]), into: &project)
        try project.save()
        let s = project.techSystem!
        let kinds = Dictionary(grouping: s.techs.dropFirst(), by: \.kind).mapValues(\.count)
        print("tech_system.json: \(kinds["single"] ?? 0) singles, \(kinds["double"] ?? 0) doubles, \(kinds["triple"] ?? 0) triples, "
              + "\(s.parts.count) parts, \(s.combos.count) combination records")
        print("learned at the start: " + (0..<CTCharacterROM.count).map { "\(CTCharacterROM.names[$0]) \(s.learned.counts[$0])" }
            .joined(separator: ", "))
        print("rom.techs: true")
    case "show":
        guard (1...2).contains(positional.count) else { print(charactersUsage); return 2 }
        let s = try loadTechs(positional[0]).system
        var who: Int?
        if positional.count == 2 {
            guard let c = characterIndex(positional[1]) else { print("no character \(positional[1])"); return 1 }
            who = c
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let who {
                let ids = (1..<CTTechROM.count).filter { s.users(of: $0).contains(who) }
                print(String(decoding: try encoder.encode(ids.map { s.techs[$0] }), as: UTF8.self))
            } else {
                print(String(decoding: try encoder.encode(s), as: UTF8.self))
            }
            return 0
        }
        for c in 0..<CTCharacterROM.count where who == nil || who == c {
            print("\(CTCharacterROM.names[c]): \(s.learned.counts[c]) singles learned at the start")
            for k in 0..<CTTechROM.singlesPerCharacter {
                print("  " + techLine(s, 1 + 8 * c + k) + "  TP \(s.tpCost[c][k])")
            }
        }
        for (i, combo) in s.combos.enumerated() where who == nil || combo.members.contains(who!) {
            let members = combo.members.map { CTCharacterROM.names[$0] }.joined(separator: "+")
            print(String(format: "%@ (record %d, mask $%02X)", members, i, combo.mask))
            for (k, req) in combo.requirements.enumerated() {
                let need = zip(combo.members, req).map { "\(CTCharacterROM.names[$0]) \($1)" }.joined(separator: ", ")
                print("  " + techLine(s, combo.first + k) + "  needs " + need)
            }
        }
        if who == nil {
            let rest = (CTTechROM.firstDouble..<CTTechROM.count).filter { s.combo(of: $0) == nil }
            if !rest.isEmpty {
                print("in no combination record:")
                for id in rest { print("  " + techLine(s, id) + "  users " + s.users(of: id).map { CTCharacterROM.names[$0] }.joined(separator: "+")) }
            }
        }
    case "tp":
        guard positional.count == 1, let partyText = options["--party"], let awardText = options["--award"] else {
            print(charactersUsage); return 2
        }
        let (s, records) = try loadTechs(positional[0])
        let keys = partyText.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard keys.count == 3 else { print("--party needs three slots"); return 2 }
        var party: [Int?] = []
        for key in keys {
            if key == "-" || key.isEmpty { party.append(nil); continue }
            guard let c = characterIndex(key) else { print("no character \(key)"); return 1 }
            guard records[c] != nil else {
                print("\(key) has no pc record in \(positional[0]) (chronoforge characters import)"); return 1
            }
            party.append(c)
        }
        let awards = awardText.split(separator: ",").compactMap { Int($0) }
        guard awards.count == awardText.split(separator: ",").count, !awards.isEmpty else { print("--award needs numbers"); return 2 }
        let unlockText = options["--unlock"] ?? "0"
        guard let unlock = unlockText.hasPrefix("0x") ? Int(unlockText.dropFirst(2), radix: 16) : Int(unlockText) else {
            print("--unlock needs a number"); return 2
        }
        let tables = CTTechPoints.tables(s)
        var state = CTTechPoints.startingState(s, records: records, party: party, unlock: unlock)
        var states = [state]
        for award in awards {
            let next = try CTTechPoints.award(state, tables: tables, award: award)
            if !json {
                var learned: [String] = []
                for c in 0..<CTCharacterROM.count where next.counts[c] > state.counts[c] {
                    learned += (state.counts[c]..<next.counts[c]).map { s.techs[1 + 8 * c + $0].name }
                }
                for (i, (a, b)) in zip(state.comboBits, next.comboBits).enumerated() where a != b {
                    for k in 0..<8 where (b & ~a) & (0x80 >> k) != 0 {
                        let id = i < s.combos.count ? s.combos[i].first + k : CTTechROM.firstTriple + i - CTTechROM.doubleRecords
                        learned.append(s.techs[id].name)
                    }
                }
                let slots = next.slots.compactMap { $0 }.map { "\(CTCharacterROM.names[$0.char]) TP \($0.tp), next \($0.toNext)" }
                print("award \(award): " + (learned.isEmpty ? "nothing learned" : "learned " + learned.joined(separator: ", "))
                      + "; " + slots.joined(separator: "; "))
            }
            states.append(next)
            state = next
        }
        if json {
            struct Run: Encodable { let awards: [Int]; let states: [CTTechPoints.State] }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(Run(awards: awards, states: states)), as: UTF8.self))
        }
    default:
        print(charactersUsage); return 2
    }
    return 0
}

func cmdCharacters(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show", "curve", "techs"].contains(operation) else {
        print(charactersUsage); return 2
    }
    var positional: [String] = [], options: [String: String] = [:], json = false
    var i = 1
    while i < args.count {
        if ["--project", "--party", "--award", "--unlock"].contains(args[i]) {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            options[args[i]] = args[i + 1]; i += 2
        } else if args[i] == "--json" {
            json = true; i += 1
        } else {
            positional.append(args[i]); i += 1
        }
    }
    do {
        switch operation {
        case "techs":
            return try cmdTechs(positional, json: json, options: options)
        case "import":
            guard positional.count == 1, let path = options["--project"] else { print(charactersUsage); return 2 }
            var project = try CTProject.load(from: URL(fileURLWithPath: path))
            let ids = try CTCharacterROM.importCharacters(rom: try readROM(positional[0]), into: &project)
            try project.save()
            for id in ids {
                let r = project.characters[id]!.pc!
                print("\(id): record \(r.charId), level \(r.level), HP \(r.maxHp), MP \(r.maxMp)")
            }
            print("party.json: \(project.party!.expToLevel.count) experience entries, \(project.party!.equipment.count) equipment items")
            print("rom.characters: \(project.project.rom!.characters.joined(separator: " "))")
        case "show":
            guard positional.count == 1 else { print(charactersUsage); return 2 }
            let loaded = try loadCharacters(positional[0])
            func item(_ id: Int) -> String { loaded.items[id].map { String(format: "$%02X %@", id, $0) } ?? String(format: "$%02X", id) }
            for c in loaded.characters {
                let r = c.record
                print("\(c.id) (record \(r.charId)) level \(r.level), exp \(r.exp), to next \(r.expToNext)")
                print("  HP \(r.hp)/\(r.maxHp)  MP \(r.mp)/\(r.maxMp)  tech points \(r.techPoints), to next \(r.techPointsToNext)")
                print("  stats       " + zip(CharacterDef.StatBlock.labels, r.stats.values).map { "\($0) \($1)" }.joined(separator: ", "))
                print("  growth base " + r.growthBase.values.map(String.init).joined(separator: " "))
                if let g = c.growth {
                    print("  growth      " + g.stats.values.map(String.init).joined(separator: " ") +
                          "; HP " + g.hp.map { "\($0.gain) to \($0.toLevel)" }.joined(separator: ", ") +
                          "; MP " + g.mp.map { "\($0.gain) to \($0.toLevel)" }.joined(separator: ", "))
                }
                let e = r.equipment
                print("  weapon \(item(e.weapon)), armor \(item(e.armor)), helmet \(item(e.helmet)), accessory \(item(e.accessory))")
            }
        default:
            guard positional.count == 2 else { print(charactersUsage); return 2 }
            let loaded = try loadCharacters(positional[0])
            let key = positional[1]
            guard let c = loaded.characters.first(where: { $0.id == key || CTCharacterROM.names[$0.record.charId] == key ||
                                                            String($0.record.charId) == key }) else {
                print("no character \(key)"); return 1
            }
            guard let growth = c.growth, let table = loaded.expToLevel else {
                print("\(c.id): the curve needs growth rows and party.json (import the ROM's characters)"); return 1
            }
            let rows = try CTLevelCurve.curve(c.record, growth: growth, expToLevel: table).map(CTLevelCurve.row)
            if json {
                let body = rows.map { "[" + $0.map(String.init).joined(separator: ", ") + "]" }.joined(separator: ", ")
                print("{\"columns\": [" + CTLevelCurve.columns.map { "\"\($0)\"" }.joined(separator: ", ") + "], \"rows\": [\(body)]}")
            } else {
                print(CTLevelCurve.columns.map { $0.padding(toLength: max(5, min(9, $0.count)), withPad: " ", startingAt: 0) }
                    .joined(separator: " "))
                for row in rows {
                    print(zip(row, CTLevelCurve.columns).map { v, name in
                        String(v).leftPad(max(5, min(9, name.count)))
                    }.joined(separator: " "))
                }
            }
        }
        return 0
    } catch {
        print("characters \(operation) failed: \(error)")
        return 1
    }
}

private extension String {
    func leftPad(_ width: Int) -> String { count >= width ? self : String(repeating: " ", count: width - count) + self }
}
