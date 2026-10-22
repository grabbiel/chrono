import Foundation
import ChronoForgeCore

private let itemsUsage = """
usage: chronoforge items import <rom.sfc> --project <project.ctproj>
       chronoforge items show <project.ctproj | rom.sfc> [<category> | <item id>] [--json]
         <category>: weapon, armor, helmet, accessory or consumable; <item id>: 0-241 or $00-$F1
"""

/// The ROM items (by item id) and the shared tables, from a project or a ROM.
private func loadItems(_ path: String) throws -> (items: [ItemDef], tables: ItemTablesDef?) {
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
        let project = try CTProject.load(from: URL(fileURLWithPath: path))
        let items = project.items.values.filter { $0.rom != nil }.sorted { $0.rom!.itemId < $1.rom!.itemId }
        guard !items.isEmpty else { throw CTROMBuildError("\(path) has no ROM items (chronoforge items import)") }
        return (items, project.itemTables)
    }
    let rom = try readROM(path)
    let decoded = try CTItemROM.decode(rom: rom, codec: CTTextCodec(profile: CTTextProfile.fromROM(Data(rom))))
    return (decoded.items, decoded.tables)
}

private func itemLine(_ i: ItemDef, tables: ItemTablesDef?) -> String {
    let r = i.rom!
    var line = String(format: "$%02X %-10@ %-10@ price %5d", r.itemId, i.name as NSString, i.kind as NSString, i.price ?? 0)
    line += " " + CTItemROM.statFields[i.kind]!.map { "\($0) \(i.stats?[$0] ?? 0)" }.joined(separator: " ")
    if let e = r.equip {
        let who = (0..<CTCharacterROM.count).filter { e & (0x80 >> $0) != 0 }.map { CTCharacterROM.names[$0] }
        line += "  equip " + (who.isEmpty ? "none" : who.count == CTCharacterROM.count ? "all" : who.joined(separator: "+"))
    }
    if let b = r.boost, b != 0 {
        line += "  boost \(b)"
        if let t = tables, t.boosts.indices.contains(b) { line += " (+\(t.boosts[b].amount) \(t.boosts[b].stats.joined(separator: "/")))" }
    }
    if let e = r.elementBonus, e != 0 {
        let names = CTItemROM.elements.enumerated().filter { e & (0x80 >> $0.offset) != 0 }.map(\.element)
        line += String(format: "  element $%02X", e) + (names.isEmpty ? "" : " " + names.joined(separator: "+"))
    }
    if let t = r.targetMode { line += String(format: "  target %02X", t) }
    return line
}

func cmdItems(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["import", "show"].contains(operation) else { print(itemsUsage); return 2 }
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
            guard positional.count == 1, let path = options["--project"] else { print(itemsUsage); return 2 }
            var project = try CTProject.load(from: URL(fileURLWithPath: path))
            let ids = try CTItemROM.importItems(rom: try readROM(positional[0]), into: &project)
            try project.save()
            let kinds = Dictionary(grouping: ids.compactMap { project.items[$0] }, by: \.kind).mapValues(\.count)
            print("items/: " + CTItemROM.categories.map { "\(kinds[$0] ?? 0) \($0)" }.joined(separator: ", "))
            print("item_tables.json: \(project.itemTables!.boosts.count) boosts")
            print("rom.items: true")
        case "show":
            guard (1...2).contains(positional.count) else { print(itemsUsage); return 2 }
            var (items, tables) = try loadItems(positional[0])
            if positional.count == 2 {
                let key = positional[1]
                if CTItemROM.categories.contains(key) {
                    items = items.filter { $0.kind == key }
                } else if let n = key.hasPrefix("$") ? Int(key.dropFirst(), radix: 16) : Int(key), (0..<CTItemROM.count).contains(n) {
                    items = items.filter { $0.rom!.itemId == n }
                } else { print("no category or item \(key)"); return 1 }
            }
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(items), as: UTF8.self))
                return 0
            }
            for item in items {
                print(itemLine(item, tables: tables))
                if positional.count == 2, let d = item.description, !d.trimmingCharacters(in: .whitespaces).isEmpty { print("  " + d) }
            }
        default:
            print(itemsUsage); return 2
        }
    } catch {
        print("error: \(error)")
        return 1
    }
    return 0
}
