// ItemDatabaseEditor.swift — the Items pane's editor: category tables, the
// item form (record A and B, name, description, equip-by-character, boost,
// element bonus), ItemBoosts, and an equipment preview through the menu's
// own stat rule (CTEquipStats). Field names follow the evidence in
// docs/items.md; bits without a known reader are shown by number only.
import SwiftUI
import ChronoForgeCore

private enum Page: Hashable { case category(Int), boosts, project }

private let categoryTitles = ["Weapons", "Armour", "Helmets", "Accessories", "Consumables"]

private func charName(_ c: Int) -> String {
    CTCharacterROM.names.indices.contains(c) ? CTCharacterROM.names[c].capitalized : "#\(c)"
}

private func statLabel(_ name: String) -> String {
    CharacterDef.StatBlock.names.firstIndex(of: name).map { CharacterDef.StatBlock.labels[$0] } ?? name
}

struct ItemDatabaseEditor: View {
    @Binding var db: ItemDatabase
    let store: ProjectStore
    let project: CTProject
    @State private var page: Page = .category(0)
    @State private var selection: ItemDef.ID?

    var body: some View {
        HSplitView {
            List(selection: $page) {
                Section("Categories") {
                    ForEach(0..<5, id: \.self) { c in
                        Text("\(categoryTitles[c]) (\(CTItemROM.first[c + 1] - CTItemROM.first[c]))").tag(Page.category(c))
                    }
                }
                Section("Tables") { Text("Stat boosts").tag(Page.boosts) }
                Section("Project") { Text("Project items").tag(Page.project) }
            }
            .frame(minWidth: 160, idealWidth: 180, maxWidth: 230)
            VStack(alignment: .leading, spacing: 8) {
                header
                switch page {
                case .category(let c):
                    VSplitView {
                        CategoryTable(items: db.items.filter { CTItemROM.category(of: $0.rom!.itemId) == c },
                                      category: c, tables: db.tables, selection: $selection)
                            .frame(minHeight: 180)
                        ScrollView {
                            if let id = selection, let index = db.items.firstIndex(where: { $0.id == id }),
                               CTItemROM.category(of: db.items[index].rom!.itemId) == c {
                                ItemForm(item: $db.items[index], tables: db.tables, project: project)
                                    .padding(.vertical, 6)
                            } else {
                                Text("Select an item.").foregroundStyle(.secondary).padding()
                            }
                        }
                        .frame(minHeight: 220)
                    }
                case .boosts:
                    ScrollView { BoostsEditor(tables: $db.tables) }
                case .project:
                    ProjectItemsList(store: store, project: project)
                }
            }
            .padding(10)
        }
        .onChange(of: page) { _, new in
            if case .category(let c) = new { selection = db.items.first { $0.rom!.itemId == CTItemROM.first[c] }?.id }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            problems
            Spacer()
            Toggle("Write items to ROM", isOn: Binding(
                get: { project.project.rom?.items ?? false },
                set: { _ = store.updateROMItems($0) }))
            Button("Apply") { store.updateItemDatabase(db.items, tables: db.tables) }.keyboardShortcut("s", modifiers: .command)
        }
    }

    private var problems: some View {
        let message: String? = {
            do { try CTItemROM.check(db.items, tables: db.tables); return nil } catch { return "\(error)" }
        }()
        return Group {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            } else {
                Label("In the ranges the game keeps; the builder will accept it.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}

// MARK: - Category table

private struct CategoryTable: View {
    let items: [ItemDef]
    let category: Int
    let tables: ItemTablesDef?
    @Binding var selection: ItemDef.ID?

    private var fields: [String] { CTItemROM.statFields[CTItemROM.categories[category]]! }

    var body: some View {
        Table(items, selection: $selection) {
            TableColumn("ID") { Text(String(format: "$%02X", $0.rom!.itemId)).monospacedDigit() }.width(40)
            TableColumn("Name") { Text($0.name) }.width(min: 90, ideal: 110)
            TableColumn("Price") { Text("\($0.price ?? 0)").monospacedDigit() }.width(56)
            TableColumn(ItemForm.label(fields[0])) { Text("\($0.stats?[fields[0]] ?? 0)").monospacedDigit() }.width(56)
            TableColumn(category == 4 ? "Restores" : category == 3 ? "Special" : "Boost") { i in
                Text(summary(i)).font(.caption)
            }
            .width(min: 90, ideal: 150)
            TableColumn(category == 4 ? "Target" : "Equip") { i in
                Text(category == 4 ? String(format: "$%02X", i.rom!.targetMode ?? 0) : equipText(i.rom!.equip ?? 0)).font(.caption)
            }
            .width(min: 80, ideal: 140)
        }
    }

    private func summary(_ i: ItemDef) -> String {
        let s = i.stats ?? [:]
        switch category {
        case 4:
            let r = s["restores"] ?? 0, amount = (s["amount"] ?? 0) & 0x0F
            let what = [r & 0x80 != 0 ? "HP" : nil, r & 0x40 != 0 ? "MP" : nil].compactMap { $0 }.joined(separator: "+")
            return what.isEmpty ? "—" : what + (amount == 0x0F ? " (full)" : "")
        case 3:
            let special = s["special"] ?? 0
            if special & CTItemROM.accessoryBoostBit != 0 { return boostText(s["specialArg"] ?? 0, tables) }
            return special & 0x80 != 0 ? String(format: "status bits $%02X", s["specialBits"] ?? 0) : "—"
        default:
            return boostText(i.rom!.boost ?? 0, tables)
        }
    }
}

func equipText(_ mask: Int) -> String {
    let who = (0..<CTCharacterROM.count).filter { mask & (0x80 >> $0) != 0 }
    if who.isEmpty { return "none" }
    if who.count == CTCharacterROM.count { return "all" }
    return who.map { charName($0) }.joined(separator: ", ")
}

func boostText(_ n: Int, _ tables: ItemTablesDef?) -> String {
    guard n != 0 else { return "—" }
    guard let t = tables, t.boosts.indices.contains(n) else { return "boost \(n)" }
    let b = t.boosts[n]
    return "\(n): " + (b.stats.isEmpty ? "none" : b.stats.map(statLabel).joined(separator: "/") + " +\(b.amount)")
}

// MARK: - Item form

private struct ItemForm: View {
    @Binding var item: ItemDef
    let tables: ItemTablesDef?
    let project: CTProject

    private var category: Int { CTItemROM.category(of: item.rom!.itemId) }

    static func label(_ field: String) -> String {
        [
            "attack": "Attack", "byte1": "Byte 1 (battle +$71, unknown)", "critical": "Critical % (probable)",
            "modifier": "Hit modifier (record)", "modifierArg": "Modifier argument",
            "defence": "Defence", "modifierOn": "Modifier on",
            "battleFlags": "Battle flags (+$78)", "special": "Special", "specialArg": "Special argument",
            "specialBits": "Status bits to set",
            "useKind": "Use kind", "restores": "Restores", "amount": "Amount", "byte3": "Byte 3",
        ][field] ?? field
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Item").foregroundStyle(.secondary)
                Text(String(format: "$%02X  %@  —  icon $%02X (read-only)", item.rom!.itemId, item.kind, item.rom!.icon))
                    .monospacedDigit()
            }
            GridRow {
                Text("Name").foregroundStyle(.secondary)
                TextField("", text: $item.name).frame(maxWidth: 160)
                    .help("Up to 10 glyphs; a space is the $FF blank")
            }
            GridRow {
                Text("Price").foregroundStyle(.secondary)
                TextField("", value: Binding(get: { item.price ?? 0 }, set: { item.price = $0 }), format: .number)
                    .frame(width: 80)
                    .help("Shops buy at price × factor / 256 and sell at half, rounded up")
            }
            GridRow {
                Text("Flags").foregroundStyle(.secondary)
                FlagToggles(value: Binding(get: { item.rom!.flags }, set: { item.rom!.flags = $0 }), category: category)
            }
            if category < 4 {
                GridRow {
                    Text("Equip").foregroundStyle(.secondary)
                    EquipToggles(mask: Binding(get: { item.rom!.equip ?? 0 }, set: { item.rom!.equip = $0 }))
                }
            }
            if category < 3 {
                GridRow {
                    Text("Boost").foregroundStyle(.secondary)
                    BoostPicker(value: Binding(get: { item.rom!.boost ?? 0 }, set: { item.rom!.boost = $0 }), tables: tables)
                }
                GridRow {
                    Text("Element bonus").foregroundStyle(.secondary)
                    ElementBonus(value: Binding(get: { item.rom!.elementBonus ?? 0 }, set: { item.rom!.elementBonus = $0 }))
                }
            }
            recordB
            if category == 4 {
                GridRow {
                    Text("Target mode").foregroundStyle(.secondary)
                    ByteField(value: Binding(get: { item.rom!.targetMode ?? 0 }, set: { item.rom!.targetMode = $0 }))
                        .help("ItemTargetMode ($CC:1BB5)")
                }
            }
            GridRow {
                Text("Description").foregroundStyle(.secondary)
                TextField("", text: Binding(get: { item.description ?? "" }, set: { item.description = $0 }), axis: .vertical)
                    .lineLimit(2...4).frame(maxWidth: 420)
                    .help("Dialogue codec text; the builder repacks the description table only when a text changes")
            }
            if let profile = project.textProfile, let text = item.description {
                GridRow {
                    Text("")
                    DescriptionAnalysis(text: text, profile: profile)
                }
            }
            if category < 4 { EquipPreview(item: item, tables: tables, project: project) }
        }
    }

    private func stat(_ k: String) -> Binding<Int> { dictBinding($item.stats, k) }

    @ViewBuilder private var recordB: some View {
        switch category {
        case 0:
            fieldRow("attack", "Menu_WeaponPower; the battle damage's caster stat")
            fieldRow("critical", "BattleSys_HitModChanceMul's 0-99 roll (probable)")
            fieldRow("modifier", "Hit modifier record (BattleRom_UnkCC2A05), below 57")
            fieldRow("modifierArg", "Its argument")
            fieldRow("byte1", "Copied to the battle stats (+$71); no reader named")
        case 1, 2:
            fieldRow("defence", "Added to the armour sum (defence = stamina + armour + helmet)")
            fieldRow("modifier", "Modifier record (BattleRom_UnkCC2A05), below 57")
            GridRow {
                Text(Self.label("modifierOn")).foregroundStyle(.secondary)
                Toggle("", isOn: Binding(get: { stat("modifierOn").wrappedValue != 0 }, set: { stat("modifierOn").wrappedValue = $0 ? 1 : 0 }))
                    .labelsHidden()
            }
        case 3:
            GridRow {
                Text(Self.label("special")).foregroundStyle(.secondary)
                HStack {
                    Toggle("Sets status bits (bit 7)", isOn: bit(stat("special"), 0x80))
                    Toggle("Stat boost (bit 6)", isOn: bit(stat("special"), CTItemROM.accessoryBoostBit))
                    ByteField(value: stat("special"))
                }
            }
            if stat("special").wrappedValue & CTItemROM.accessoryBoostBit != 0 {
                GridRow {
                    Text("Boost").foregroundStyle(.secondary)
                    BoostPicker(value: stat("specialArg"), tables: tables)
                }
            } else {
                fieldRow("specialArg", "With bit 7: the status byte (+$Status + this) the bits go to")
            }
            GridRow {
                Text(Self.label("specialBits")).foregroundStyle(.secondary)
                RawBits(value: stat("specialBits"))
            }
            GridRow {
                Text(Self.label("battleFlags")).foregroundStyle(.secondary)
                RawBits(value: stat("battleFlags"))
            }
        default:
            GridRow {
                Text(Self.label("useKind")).foregroundStyle(.secondary)
                HStack {
                    ByteField(value: stat("useKind"))
                    Text(useKindText(stat("useKind").wrappedValue)).font(.caption).foregroundStyle(.secondary)
                }
            }
            GridRow {
                Text(Self.label("restores")).foregroundStyle(.secondary)
                HStack {
                    Toggle("HP (bit 7)", isOn: bit(stat("restores"), 0x80))
                    Toggle("MP (bit 6)", isOn: bit(stat("restores"), 0x40))
                    ByteField(value: stat("restores"))
                }
            }
            GridRow {
                Text(Self.label("amount")).foregroundStyle(.secondary)
                HStack {
                    ByteField(value: stat("amount"))
                    Text("low nibble \(stat("amount").wrappedValue & 0x0F)" + (stat("amount").wrappedValue & 0x0F == 0x0F ? " = full" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            fieldRow("byte3", "No reader named")
        }
    }

    private func fieldRow(_ k: String, _ help: String) -> some View {
        GridRow {
            Text(Self.label(k)).foregroundStyle(.secondary)
            TextField("", value: stat(k), format: .number).frame(width: 64).help(help)
        }
    }

    private func useKindText(_ v: Int) -> String {
        if v & 0x80 != 0 { return "heal (bit 7)" }
        if v & 0x10 != 0 { return "random (bit 4)" }
        if v & 0x08 != 0 { return "full (bit 3)" }
        return v == 0 ? "stat item (no bit)" : "first set bit \(Int.bitWidth - 1 - v.leadingZeroBitCount)"
    }
}

private func bit(_ value: Binding<Int>, _ mask: Int) -> Binding<Bool> {
    Binding(get: { value.wrappedValue & mask != 0 },
            set: { value.wrappedValue = $0 ? value.wrappedValue | mask : value.wrappedValue & ~mask })
}

private struct ByteField: View {
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 4) {
            TextField("", value: $value, format: .number).frame(width: 48)
            Text(String(format: "$%02X", value & 0xFF)).monospacedDigit().foregroundStyle(.secondary).font(.caption)
        }
    }
}

/// Eight unnamed bits, 7 down (no reader names them).
private struct RawBits: View {
    @Binding var value: Int
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<8, id: \.self) { k in
                Toggle(String(7 - k), isOn: bit($value, 0x80 >> k)).toggleStyle(.button).font(.caption.monospacedDigit())
            }
            Text(String(format: "$%02X", value & 0xFF)).monospacedDigit().foregroundStyle(.secondary).font(.caption)
        }
    }
}

private struct FlagToggles: View {
    @Binding var value: Int
    let category: Int
    var body: some View {
        HStack {
            Toggle("Usable in the menu", isOn: bit($value, 0x02)).help("Bit 1 (Menu_ItemInfo0)")
            Toggle("Bit 2", isOn: bit($value, 0x04)).help("Set on accessories and some gear (Menu_ItemInfo0)")
            Toggle("Sorted first", isOn: bit($value, 0x08)).help("Bit 3")
            Toggle("Dropped on load", isOn: bit($value, 0x10)).help("Bit 4: BankFF_LoadSlotPart removes it")
            if category == 4 { Toggle("Battle list", isOn: bit($value, 0x80)).help("Bit 7: BattleFD_AddItemEntry") }
        }
        .toggleStyle(.checkbox)
    }
}

private struct EquipToggles: View {
    @Binding var mask: Int
    var body: some View {
        HStack {
            ForEach(0..<CTCharacterROM.count, id: \.self) { c in
                Toggle(charName(c), isOn: bit($mask, 0x80 >> c)).toggleStyle(.checkbox)
            }
        }
    }
}

private struct BoostPicker: View {
    @Binding var value: Int
    let tables: ItemTablesDef?
    var body: some View {
        Picker("", selection: $value) {
            ForEach(0..<CTItemROM.boostCount, id: \.self) { n in Text(n == 0 ? "none" : boostText(n, tables)).tag(n) }
        }
        .labelsHidden().frame(maxWidth: 260)
    }
}

private struct ElementBonus: View {
    @Binding var value: Int
    var body: some View {
        HStack {
            ForEach(Array(CTItemROM.elements.enumerated()), id: \.offset) { k, name in
                Toggle(name.capitalized, isOn: bit($value, 0x80 >> k)).toggleStyle(.checkbox)
            }
            Stepper(value: Binding(get: { value & 0x0F }, set: { value = value & 0xF0 | $0 & 0x0F }), in: 0...15) {
                Text("+\(value & 0x0F) resistance").monospacedDigit()
            }
            .help("BattleSys_UnkCF69 adds the low nibble to the resistance of each element bit set")
        }
    }
}

/// The description's dictionary compression as the builder compiles it (CTTextAnalyzer), live.
private struct DescriptionAnalysis: View {
    let text: String
    let profile: CTTextProfile

    var body: some View {
        Group {
            do {
                let r = try CTTextAnalyzer.analyze([text], codec: CTTextCodec(profile: profile))
                let runs = (r.segments ?? []).filter { $0.kind == "dictionary" }.map { "[\($0.text)]" }.joined(separator: " ")
                return Text("\(r.compressedBytes) bytes (\(r.rawBytes) raw, \(r.savedBytes) saved)" + (runs.isEmpty ? "" : ": " + runs))
                    .foregroundStyle(.secondary)
            } catch {
                return Text(String(describing: error)).foregroundStyle(.orange)
            }
        }
        .font(.caption).lineLimit(2)
    }
}

// MARK: - Equipment preview

/// The selected item in a character's slot, through the menu's own rule.
private struct EquipPreview: View {
    let item: ItemDef
    let tables: ItemTablesDef?
    let project: CTProject
    @State private var character = ""

    private var characters: [(id: String, record: CharacterDef.Record)] {
        project.characters.compactMap { id, c in c.pc.map { (id, $0) } }.sorted { $0.record.charId < $1.record.charId }
    }

    var body: some View {
        GridRow {
            Text("Preview").foregroundStyle(.secondary)
            if let tables, !characters.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("", selection: $character) {
                        ForEach(characters, id: \.id) { Text($0.id.capitalized).tag($0.id) }
                    }
                    .labelsHidden().frame(maxWidth: 160)
                    if let c = characters.first(where: { $0.id == character }) ?? characters.first {
                        result(c.record, tables)
                    }
                }
            } else {
                Text("Import the characters to preview their stats with this item.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func record(_ r: CharacterDef.Record, slot: Int?, id: Int) -> [UInt8] {
        var raw = CTCharacterROM.encode(r, over: [UInt8](repeating: 0, count: 0x50))
        raw[0] = UInt8(r.charId)
        if let slot { raw[slot] = UInt8(id) }
        return raw
    }

    @ViewBuilder private func result(_ r: CharacterDef.Record, _ t: ItemTablesDef) -> some View {
        let all = project.items.values.map { $0.rom?.itemId == item.rom!.itemId ? item : $0 }
        let tables = CTEquipStats.tables(items: all, tables: t)
        let slot = [0x29, 0x28, 0x27, 0x2A][CTItemROM.category(of: item.rom!.itemId)]
        let before = try? CTEquipStats.compute(record: record(r, slot: nil, id: 0), tables: tables)
        let after = try? CTEquipStats.compute(record: record(r, slot: slot, id: item.rom!.itemId), tables: tables)
        if let before, let after {
            let labels = CharacterDef.StatBlock.labels + ["Attack", "Defence", "Max HP"]
            let a = after.stats + [after.attack, after.defence, after.maxHp], b = before.stats + [before.attack, before.defence, before.maxHp]
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow { ForEach(labels, id: \.self) { Text($0).font(.caption2).foregroundStyle(.secondary) } }
                GridRow {
                    ForEach(0..<a.count, id: \.self) { k in
                        Text("\(a[k])").monospacedDigit().foregroundStyle(a[k] > b[k] ? .green : a[k] < b[k] ? .red : .primary)
                            .help("now \(b[k])")
                    }
                }
            }
            if !(r.equipment.weapon == item.rom!.itemId || [r.equipment.armor, r.equipment.helmet, r.equipment.accessory].contains(item.rom!.itemId)),
               (item.rom!.equip ?? 0) & (0x80 >> r.charId) == 0 {
                Text("\(charName(r.charId)) cannot equip it (equip mask).").font(.caption).foregroundStyle(.orange)
            }
        } else {
            Text("The rule reads past a table with these values.").font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Boosts

private struct BoostsEditor: View {
    @Binding var tables: ItemTablesDef?

    var body: some View {
        if tables != nil {
            let t = tables!
            VStack(alignment: .leading, spacing: 8) {
                Text("ItemBoosts: the stats each boost raises and by how much. Weapons, armour and helmets name one by "
                     + "their boost byte; accessories with special bit 6 by their special argument. Boost 0 is none.")
                    .font(.caption).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("#").font(.caption).foregroundStyle(.secondary)
                        ForEach(t.statOrder, id: \.self) { Text(statLabel($0)).font(.caption).foregroundStyle(.secondary) }
                        Text("Amount").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(1..<t.boosts.count, id: \.self) { n in
                        GridRow {
                            Text("\(n)").monospacedDigit()
                            ForEach(t.statOrder, id: \.self) { s in
                                Toggle("", isOn: Binding(
                                    get: { tables!.boosts[n].stats.contains(s) },
                                    set: { on in
                                        var b = tables!.boosts[n]
                                        b.stats = tables!.statOrder.filter { $0 == s ? on : b.stats.contains($0) }
                                        tables!.boosts[n] = b
                                    }))
                                .labelsHidden().toggleStyle(.checkbox)
                            }
                            TextField("", value: Binding(get: { tables!.boosts[n].amount }, set: { tables!.boosts[n].amount = $0 }),
                                      format: .number).frame(width: 52)
                        }
                    }
                }
                Text("Stat caps (read-only): " + zip(t.statOrder, t.statCaps).map { "\(statLabel($0)) \($1)" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No item_tables.json; reimport the ROM's items.").foregroundStyle(.secondary)
        }
    }
}
