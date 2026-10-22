// CharactersPane.swift
import SwiftUI
import Charts
import UniformTypeIdentifiers
import ChronoForgeCore

struct CharactersPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?
    @State private var importROM = false
    @State private var pickBase = false
    @State private var buildResult = ""
    @State private var revision = 0          // re-seeds the editor after an import

    var body: some View {
        EntityListView(title: "Characters", ids: project.characters.keys.sorted(),
                       selection: $selection) { id in
            if let c = project.characters[id] {
                EditorHost(entity: c, apply: { store.updateCharacter($0) }) { $c in
                    ScrollView {
                        Form {
                            TextField("Name", text: $c.name)
                            TextField("Kind (playable|npc|enemy)", text: $c.kind)
                            OptionalTextField(label: "Sprite", value: $c.sprite)
                            if c.pc == nil {
                                OptionalIntField(label: "Level", value: $c.level, range: 1...99)
                                if c.stats != nil { LegacyStats(stats: $c.stats) }
                            } else {
                                PCRecordEditor(character: $c, store: store, project: project)
                            }
                            ApplyBar(apply: {
                                var applied = $c.wrappedValue
                                if let pc = applied.pc { applied.level = pc.level }
                                store.updateCharacter(applied)
                            })
                        }
                        .padding()
                    }
                }
                .id("\(id)#\(revision)")
            }
        }
        .toolbar {
            Button(project.party == nil ? "Import Characters from ROM…" : "Reimport Characters from ROM…") { importROM = true }
            Button("Build ROM…") { pickBase = true }
                .disabled((project.project.rom?.characters ?? []).isEmpty)
        }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importCharacters(url); revision += 1 }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
        .fileImporter(isPresented: $pickBase, allowedContentTypes: [.data], allowsMultipleSelection: false) { picked in
            guard case .success(let urls) = picked, let base = urls.first else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(project.project.name).sfc"
            panel.allowedContentTypes = [UTType(filenameExtension: "sfc") ?? .data]
            guard panel.runModal() == .OK, let output = panel.url else { return }
            buildResult = store.buildROM(base: base, output: output) ?? store.statusMessage
        }
        .alert("ROM build", isPresented: Binding(get: { !buildResult.isEmpty }, set: { if !$0 { buildResult = "" } })) {
            Button("OK") { buildResult = "" }
        } message: { Text(buildResult) }
    }
}

private struct LegacyStats: View {
    @Binding var stats: CharacterDef.Stats?
    var body: some View {
        GroupBox("Stats") {
            Grid {
                GridRow {
                    StatField("HP", statsBinding($stats, \.hp))
                    StatField("MP", statsBinding($stats, \.mp))
                    StatField("ATK", statsBinding($stats, \.atk))
                }
                GridRow {
                    StatField("DEF", statsBinding($stats, \.def))
                    StatField("MAG", statsBinding($stats, \.mag))
                    StatField("SPD", statsBinding($stats, \.spd))
                }
            }
        }
    }
}

/// The game record of a playable character (docs/characters.md): level,
/// HP/MP, stats with their growth, equipment, and the level curve the game's
/// rule gives (CTLevelCurve).
private struct PCRecordEditor: View {
    @Binding var character: CharacterDef
    let store: ProjectStore
    let project: CTProject

    private var record: Binding<CharacterDef.Record> {
        Binding(get: { character.pc! }, set: { character.pc = $0 })
    }
    private var growth: Binding<CharacterDef.Growth>? {
        character.growth == nil ? nil : Binding(get: { character.growth! }, set: { character.growth = $0 })
    }

    var body: some View {
        let r = character.pc!
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(String(format: "Record %d at $CC:%04X", r.charId, 0x50 * r.charId)).font(.headline)
                    Spacer()
                    Toggle("Write to ROM", isOn: Binding(
                        get: { (project.project.rom?.characters ?? []).contains(character.id) },
                        set: { on in
                            var ids = project.project.rom?.characters ?? []
                            ids.removeAll { $0 == character.id }
                            if on { ids.append(character.id) }
                            _ = store.updateROMCharacters(ids)
                        }))
                }
                problems
            }
        }
        GroupBox("Level and experience") {
            Grid(alignment: .leading) {
                GridRow {
                    Text("Level").foregroundStyle(.secondary)
                    Stepper(value: Binding(get: { r.level }, set: { setLevel($0) }), in: 1...CTLevelCurve.levelMax) {
                        Text("\(r.level)").monospacedDigit()
                    }
                    StatField("Exp", record.exp)
                    StatField("To next", record.expToNext)
                }
            }
            Text("Changing the level sets the experience to the start of that level (party.json's table).")
                .font(.caption).foregroundStyle(.secondary)
        }
        GroupBox("HP and MP") {
            Grid {
                GridRow {
                    StatField("HP", record.hp)
                    StatField("Max HP", record.maxHp)
                    StatField("MP", record.mp)
                    StatField("Max MP", record.maxMp)
                }
            }
        }
        statsBox(r)
        if let growth { rowsBox(growth) }
        equipmentBox(r)
        GroupBox("Tech points (partially decoded)") {
            Grid {
                GridRow {
                    StatField("Total", record.techPoints)
                    StatField("To next tech", record.techPointsToNext)
                }
            }
        }
        if let g = character.growth, let table = project.party?.expToLevel {
            CurveView(record: r, growth: g, expToLevel: table)
        }
    }

    private var problems: some View {
        let message: String? = {
            guard let party = project.party else { return "Import the ROM's characters to check equipment." }
            do { try CTCharacterROM.check(character.pc!, growth: character.growth, party: party); return nil }
            catch { return "\(error)" }
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

    private func setLevel(_ level: Int) {
        var r = character.pc!
        r.level = level
        if let table = project.party?.expToLevel {
            let at = CTLevelCurve.expAt(level: level, expToLevel: table)
            r.exp = at.exp; r.expToNext = at.toNext
        }
        character.pc = r
    }

    private func statsBox(_ r: CharacterDef.Record) -> some View {
        let off = character.growth.map { CTLevelCurve.offCurve(r, growth: $0) } ?? [:]
        return GroupBox("Stats") {
            Grid(alignment: .leading) {
                GridRow {
                    Text("")
                    Text("Now").foregroundStyle(.secondary)
                    Text("Growth base").foregroundStyle(.secondary)
                    if character.growth != nil { Text("Growth / level (÷100)").foregroundStyle(.secondary) }
                    Text("")
                }
                ForEach(0..<7, id: \.self) { i in
                    GridRow {
                        Text(CharacterDef.StatBlock.labels[i])
                        TextField("", value: record.stats[i], format: .number).frame(width: 60)
                        TextField("", value: record.growthBase[i], format: .number).frame(width: 60)
                            .disabled(i == CTCharacterROM.speed)
                        if let growth {
                            TextField("", value: growth.stats[i], format: .number).frame(width: 60)
                                .disabled(i == CTCharacterROM.speed)
                        }
                        if let (now, curve) = off[i] {
                            Image(systemName: "circle.fill").foregroundStyle(.orange).font(.caption2)
                                .help("Off the curve: \(now) now; the first level-up sets it to \(curve) or more.")
                        } else if i == CTCharacterROM.speed {
                            Text("not grown by levels (capped at 50 by a level-up)").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("")
                        }
                    }
                }
            }
        }
    }

    private func rowsBox(_ growth: Binding<CharacterDef.Growth>) -> some View {
        GroupBox("HP and MP growth (gain per level up to a level)") {
            Grid(alignment: .leading) {
                ForEach([("HP", \CharacterDef.Growth.hp), ("MP", \CharacterDef.Growth.mp)], id: \.0) { name, path in
                    GridRow {
                        Text(name).foregroundStyle(.secondary)
                        ForEach(0..<4, id: \.self) { k in
                            HStack(spacing: 4) {
                                TextField("gain", value: growth[dynamicMember: path][k].gain, format: .number).frame(width: 44)
                                Text("to")
                                TextField("level", value: growth[dynamicMember: path][k].toLevel, format: .number).frame(width: 44)
                            }
                        }
                    }
                }
            }
            Text("Each level-up adds the gain of the first step whose level reaches the new level; one step must reach 99.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func equipmentBox(_ r: CharacterDef.Record) -> some View {
        GroupBox("Equipment") {
            Grid(alignment: .leading) {
                ForEach([("Weapon", "weapon", \CharacterDef.Record.Equipment.weapon),
                         ("Armor", "armor", \CharacterDef.Record.Equipment.armor),
                         ("Helmet", "helmet", \CharacterDef.Record.Equipment.helmet),
                         ("Accessory", "accessory", \CharacterDef.Record.Equipment.accessory)], id: \.1) { label, slot, path in
                    GridRow {
                        Text(label).foregroundStyle(.secondary)
                        let binding = record.equipment[dynamicMember: path]
                        if let party = project.party {
                            let items = party.equipment.filter { $0.slot == slot && $0.equipMask & (0x80 >> r.charId) != 0 }
                            Picker("", selection: binding) {
                                if !items.contains(where: { $0.id == binding.wrappedValue }) {
                                    Text(String(format: "$%02X (not equippable)", binding.wrappedValue)).tag(binding.wrappedValue)
                                }
                                ForEach(items) { item in
                                    Text(String(format: "$%02X %@", item.id, item.name)).tag(item.id)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 260)
                        } else {
                            TextField("", value: binding, format: .number).frame(width: 60)
                        }
                    }
                }
            }
        }
    }
}

/// Levels from the record's own to 99 by the game's rule: a chart of one
/// series and the table.
private struct CurveView: View {
    let record: CharacterDef.Record
    let growth: CharacterDef.Growth
    let expToLevel: [Int]
    @State private var series = 3                   // CTLevelCurve.columns index (max HP)

    var body: some View {
        GroupBox("Level curve (the game's rule)") {
            switch Result(catching: { try CTLevelCurve.curve(record, growth: growth, expToLevel: expToLevel) }) {
            case .failure(let error):
                Label(String(describing: error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .success(let curve):
                let rows = curve.map(CTLevelCurve.row)
                VStack(alignment: .leading) {
                    Picker("Series", selection: $series) {
                        ForEach(1..<CTLevelCurve.columns.count, id: \.self) { i in Text(CTLevelCurve.columns[i]).tag(i) }
                    }
                    .frame(maxWidth: 260)
                    Chart(rows.indices, id: \.self) { i in
                        LineMark(x: .value("Level", rows[i][0]), y: .value(CTLevelCurve.columns[series], rows[i][series]))
                    }
                    .chartXScale(domain: 1...CTLevelCurve.levelMax)
                    .frame(height: 180)
                    ScrollView {
                        Grid(alignment: .trailing, horizontalSpacing: 10) {
                            GridRow {
                                ForEach(CTLevelCurve.columns, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                            ForEach(rows.indices, id: \.self) { i in
                                GridRow {
                                    ForEach(rows[i].indices, id: \.self) { k in
                                        Text("\(rows[i][k])").font(.caption.monospacedDigit())
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 200)
                }
            }
        }
    }
}
