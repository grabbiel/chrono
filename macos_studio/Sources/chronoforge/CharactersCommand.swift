import Foundation
import ChronoForgeCore

private let charactersUsage = """
usage: chronoforge characters import <rom.sfc> --project <project.ctproj>
       chronoforge characters show <project.ctproj | rom.sfc>
       chronoforge characters curve <project.ctproj | rom.sfc> <character> [--json]
         <character>: a project character id, a name (crono ... magus) or 0-6
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

func cmdCharacters(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show", "curve"].contains(operation) else {
        print(charactersUsage); return 2
    }
    var positional: [String] = [], options: [String: String] = [:], json = false
    var i = 1
    while i < args.count {
        if args[i] == "--project" {
            guard i + 1 < args.count else { print("missing value for --project"); return 2 }
            options[args[i]] = args[i + 1]; i += 2
        } else if args[i] == "--json" {
            json = true; i += 1
        } else {
            positional.append(args[i]); i += 1
        }
    }
    do {
        switch operation {
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
