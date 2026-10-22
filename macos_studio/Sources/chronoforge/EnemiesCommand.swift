import Foundation
import ChronoForgeCore

private let enemiesUsage = """
usage: chronoforge enemies import <rom.sfc> --project <project.ctproj>
       chronoforge enemies show <project.ctproj | rom.sfc> [<enemy>] [--json]
       chronoforge enemies verify <project.ctproj> <rom.sfc>
         <enemy>: an enemy id 0-254, a project file id (enemy_012) or a name
         verify: the ROM's stat records, rewards and names equal the project's enemies (e.g. after rom build)
"""

/// (file id, name, record) of every enemy, from a project's characters or a
/// ROM; item names for the rewards.
private func loadEnemies(_ path: String) throws -> (enemies: [(id: String, name: String, enemy: CharacterDef.Enemy)], items: [Int: String]) {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        let project = try CTProject.load(from: URL(fileURLWithPath: path))
        let enemies = project.characters.compactMap { id, c in c.enemy.map { (id: id, name: c.name, enemy: $0) } }
            .sorted { $0.enemy.enemyId < $1.enemy.enemyId }
        return (enemies, CTEnemyROM.itemNames(project: project, rom: nil))
    }
    let rom = try readROM(path)
    let lengths = CTEnemyROM.actLengths(rom: rom)
    let enemies = (0..<CTEnemyROM.count).map { n -> (id: String, name: String, enemy: CharacterDef.Enemy) in
        let name = CTEnemyROM.name(rom: rom, id: n) ?? ""
        return (CTEnemyROM.fileID(n), name.isEmpty ? CTEnemyROM.placeholder(n) : name,
                CTEnemyROM.decode(rom: rom, id: n, lengths: lengths))
    }
    return (enemies, CTEnemyROM.itemNames(project: nil, rom: rom))
}

private func printEnemy(_ id: String, _ name: String, _ e: CharacterDef.Enemy, items: [Int: String]) {
    func item(_ n: Int) -> String {
        if n == 0 { return "none" }
        return items[n].map { String(format: "$%02X %@", n, $0) } ?? String(format: "$%02X", n)
    }
    print("\(id) \(name) (enemy \(e.enemyId)) level \(e.level), HP \(e.hp)")
    print("  stats     " + zip(CharacterDef.Enemy.Stats.labels, e.stats.values).map { "\($0) \($1)" }.joined(separator: ", "))
    let affinity = zip(CharacterDef.Enemy.Affinity.names, e.affinity.values).map { label, v in
        String(format: "%@ $%02X ", label, v) + CTEnemyROM.affinityText(v)
    }
    print("  affinity  " + affinity.joined(separator: ", "))
    let status = e.status.map { String(format: "%02X", $0) }.joined(separator: " ")
    print(String(format: "  status %@  immunity $%02X  flags $%02X  attack $%02X", status, e.immunity, e.flags15, e.attackId))
    let r = e.reward
    print("  reward    exp \(r.exp), gold \(r.gold), tech points \(r.techPoints), drop \(item(r.drop)), charm \(item(r.charm))")
    if let a = e.attack {
        let part = a.part == CTEnemyROM.partNone ? "none" : String(format: "$%02X", a.part)
        print(String(format: "  attack    flags $%02X elements $%X effect ", a.flags, a.elementBits) + part)
    }
    if let s = e.ai {
        if let text = s.text {
            print("  ai at \(s.address)")
            for line in text.split(separator: "\n") { print("    " + line) }
        } else {
            print("  ai at \(s.address): \(s.error ?? "not decoded")")
        }
    }
}

func cmdEnemies(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show", "verify"].contains(operation) else {
        print(enemiesUsage); return 2
    }
    var positional: [String] = [], options: [String: String] = [:], json = false
    var i = 1
    while i < args.count {
        if args[i] == "--project" {
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
        case "import":
            guard positional.count == 1, let path = options["--project"] else { print(enemiesUsage); return 2 }
            var project = try CTProject.load(from: URL(fileURLWithPath: path))
            let ids = try CTEnemyROM.importEnemies(rom: try readROM(positional[0]), into: &project)
            try project.save()
            let scripts = ids.filter { project.characters[$0]?.enemy?.ai?.text != nil }.count
            let named = ids.filter { CTEnemyROM.writableName(project.characters[$0]!) != nil }.count
            print("characters: \(ids.count) enemies (\(named) named, \(scripts) AI scripts as text)")
            print("rom.enemies: \(ids.count) files, \(ids.first ?? "") ... \(ids.last ?? "")")
        case "show":
            guard (1...2).contains(positional.count) else { print(enemiesUsage); return 2 }
            let loaded = try loadEnemies(positional[0])
            var chosen = loaded.enemies
            if positional.count == 2 {
                let key = positional[1]
                chosen = loaded.enemies.filter { $0.id == key || $0.name == key || String($0.enemy.enemyId) == key }
                guard !chosen.isEmpty else { print("no enemy \(key)"); return 1 }
            }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(chosen.map(\.enemy)), as: UTF8.self))
                return 0
            }
            for c in chosen { printEnemy(c.id, c.name, c.enemy, items: loaded.items) }
        default:
            guard positional.count == 2 else { print(enemiesUsage); return 2 }
            let project = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
            let rom = try readROM(positional[1])
            var differences = 0, checked = 0
            for (id, c) in project.characters.sorted(by: { $0.key < $1.key }) {
                guard let e = c.enemy else { continue }
                checked += 1
                let n = e.enemyId
                let stats = Array(rom[CTEnemyROM.statsPC(n)..<(CTEnemyROM.statsPC(n) + CTEnemyROM.statsSize)])
                let reward = Array(rom[CTEnemyROM.rewardPC(n)..<(CTEnemyROM.rewardPC(n) + CTEnemyROM.rewardSize)])
                let got = CTEnemyROM.decode(stats: stats, reward: reward, id: n)
                var want = e
                want.ai = nil; want.attack = nil
                if got != want { print("\(id): the ROM's stat or reward record differs"); differences += 1 }
                if let name = CTEnemyROM.writableName(c), CTEnemyROM.name(rom: rom, id: n) != name {
                    print("\(id): the ROM's name is \(String(reflecting: CTEnemyROM.name(rom: rom, id: n) ?? ""))")
                    differences += 1
                }
            }
            print("\(checked) enemies checked, \(differences) differences")
            return differences == 0 ? 0 : 1
        }
        return 0
    } catch {
        print("enemies \(operation) failed: \(error)")
        return 1
    }
}
