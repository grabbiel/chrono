// EnemyEditorViews.swift — the Characters pane's Enemies tab: the enemy list,
// a stat editor with affinities and rewards, the attack record and the AI
// script as text (docs/enemies.md), and the import and ROM-build settings.
import SwiftUI
import ChronoForgeCore

extension ProjectStore {
    /// The ROM's enemies 0-254 into the project (CTEnemyROM.importEnemies);
    /// sets `rom.enemies`.
    public func importEnemies(_ url: URL) {
        guard var candidate = project else { return }
        do {
            let ids = try CTEnemyROM.importEnemies(rom: [UInt8](Data(contentsOf: url)), into: &candidate)
            try candidate.save()
            project = candidate
            statusMessage = "imported \(ids.count) enemies from the ROM"
            statusIsError = false
        } catch {
            statusMessage = "enemy import failed: \(error)"
            statusIsError = true
        }
    }

    /// Saves which enemies `rom build` writes (`rom.enemies`).
    public func updateROMEnemies(_ ids: [String]) -> Bool {
        guard var candidate = project else { return false }
        var spec = candidate.project.rom ?? Project.ROMBuild()
        spec.enemies = ids
        candidate.project.rom = Self.isEmpty(spec) ? nil : spec
        do {
            try candidate.save()
            project = candidate
            statusMessage = "saved ROM build settings"
            statusIsError = false
            return true
        } catch {
            statusMessage = "save failed: \(error)"
            statusIsError = true
            return false
        }
    }
}

/// Every character with an enemy record, by enemy id.
struct EnemiesPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?
    @State private var importROM = false
    @State private var filter = ""
    @State private var revision = 0          // re-seeds the editor after an import

    private var rows: [(id: String, label: String)] {
        let enemies = project.characters.values.filter { $0.enemy != nil }
        let sorted = enemies.sorted { $0.enemy!.enemyId < $1.enemy!.enemyId }
        let all = sorted.map { c -> (id: String, label: String) in
            (c.id, String(format: "%03d  ", c.enemy!.enemyId) + c.name)
        }
        if filter.isEmpty { return all }
        return all.filter { $0.label.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).padding(6)
                List(rows, id: \.id, selection: $selection) { row in
                    NavigationLink(row.label, value: row.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let selection, let c = project.characters[selection], c.enemy != nil {
                EditorHost(entity: c, apply: { store.updateCharacter($0) }) { $c in
                    ScrollView {
                        Form {
                            TextField("Name", text: $c.name)
                            EnemyRecordEditor(character: $c, store: store, project: project)
                            ApplyBar(apply: {
                                var applied = $c.wrappedValue
                                if let e = applied.enemy { applied.level = e.level }
                                store.updateCharacter(applied)
                            })
                        }
                        .padding()
                    }
                }
                .id("\(selection)#\(revision)")
            } else if rows.isEmpty && filter.isEmpty {
                ContentUnavailableView("No enemies", systemImage: "list.bullet",
                                       description: Text("Import the ROM's enemies to edit their stats, rewards and names."))
            } else {
                ContentUnavailableView("Enemies", systemImage: "list.bullet")
            }
        }
        .toolbar {
            let any = project.characters.values.contains { $0.enemy != nil }
            Button(any ? "Reimport Enemies from ROM…" : "Import Enemies from ROM…") { importROM = true }
        }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importEnemies(url); revision += 1 }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
    }
}

/// One enemy's game data: the fields `rom build` writes (stats, affinities,
/// status bytes, rewards, the name) and, read-only, its attack record and AI script.
private struct EnemyRecordEditor: View {
    @Binding var character: CharacterDef
    let store: ProjectStore
    let project: CTProject

    private var enemy: Binding<CharacterDef.Enemy> {
        Binding(get: { character.enemy! }, set: { character.enemy = $0 })
    }

    private var items: [(id: Int, name: String)] {
        var out: [(id: Int, name: String)] = [(0, "none")]
        let named = CTEnemyROM.itemNames(project: project, rom: nil)
        for id in 1..<CTEnemyROM.itemCount {
            let name = named[id] ?? ""
            out.append((id, name.isEmpty ? String(format: "$%02X", id) : String(format: "$%02X %@", id, name)))
        }
        return out
    }

    var body: some View {
        let e = character.enemy!
        header(e)
        HStack(alignment: .top, spacing: 12) {
            spritePlaceholder
            GroupBox("Level and HP") {
                Grid(alignment: .leading) {
                    GridRow {
                        StatField("Level", enemy.level)
                        StatField("HP", enemy.hp)
                    }
                }
                Text("HP is at most 32767 (the lowest-HP target search starts at $7FFF).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        statsBox
        affinityBox(e)
        flagsBox
        rewardsBox
        attackBox(e)
        scriptBox(e)
    }

    private func header(_ e: CharacterDef.Enemy) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    let pc = CTEnemyROM.statsPC(e.enemyId)
                    Text(String(format: "Enemy %d at $CC:%04X", e.enemyId, pc & 0xFFFF)).font(.headline)
                    Spacer()
                    Toggle("Write to ROM", isOn: Binding(
                        get: { (project.project.rom?.enemies ?? []).contains(character.id) },
                        set: { on in
                            var ids = project.project.rom?.enemies ?? []
                            ids.removeAll { $0 == character.id }
                            if on { ids.append(character.id) }
                            _ = store.updateROMEnemies(ids)
                        }))
                }
                problems(e)
            }
        }
    }

    private func problems(_ e: CharacterDef.Enemy) -> some View {
        let message: String? = {
            do { try CTEnemyROM.check(e, name: CTEnemyROM.writableName(character)); return nil }
            catch { return "\(error)" }
        }()
        return Group {
            if let message {
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
            } else {
                Label("In the ranges the battle code keeps; the builder will accept it.", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    /// No battle-sprite decoder covers enemies yet (docs/enemies.md).
    private var spritePlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
            .foregroundStyle(.secondary)
            .frame(width: 96, height: 96)
            .overlay(Text("battle sprite\nnot decoded").font(.caption2).multilineTextAlignment(.center).foregroundStyle(.secondary))
    }

    private var statsBox: some View {
        GroupBox("Stats") {
            Grid(alignment: .leading) {
                ForEach(0..<2, id: \.self) { row in
                    GridRow {
                        ForEach(0..<4, id: \.self) { col in
                            let i = 4 * row + col
                            StatField(CharacterDef.Enemy.Stats.labels[i], enemy.stats.values[i])
                        }
                    }
                }
            }
            Text("Each 0-255. Speed above 16 is capped to 16 when the battle starts (BattleFD_UnkB7EB).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func affinityBox(_ e: CharacterDef.Enemy) -> some View {
        GroupBox("Elements (damage divisor; 4 is normal)") {
            Grid(alignment: .leading) {
                ForEach(0..<4, id: \.self) { i in
                    GridRow {
                        Text(CharacterDef.Enemy.Affinity.names[i].capitalized).foregroundStyle(.secondary)
                        TextField("", value: enemy.affinity.values[i], format: .number).frame(width: 60)
                        Text(String(format: "$%02X", e.affinity.values[i])).font(.caption.monospaced())
                        Text(CTEnemyROM.affinityText(e.affinity.values[i])).font(.caption)
                    }
                }
            }
            Text("Bit 7 absorbs; bits 5-0 are the divisor, less 2 with bit 6 (BattleSys_HitModUnk6CScale).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var flagsBox: some View {
        GroupBox("Status and flag bytes") {
            Grid(alignment: .leading) {
                GridRow {
                    ForEach(0..<5, id: \.self) { i in
                        StatField(String(format: "+$%02X", 3 + i), enemy.status[i])
                    }
                }
                GridRow {
                    StatField("Immunity", enemy.immunity)
                    StatField("Flags", enemy.flags15)
                    StatField("Attack", enemy.attackId)
                }
            }
            Text("Copied as they are into the battler's status block; their bits are not all named yet.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var rewardsBox: some View {
        let choices = items
        return GroupBox("Rewards") {
            Grid(alignment: .leading) {
                GridRow {
                    StatField("Exp", enemy.reward.exp)
                    StatField("Gold", enemy.reward.gold)
                    StatField("Tech points", enemy.reward.techPoints)
                }
                GridRow {
                    Text("Drop").foregroundStyle(.secondary)
                    itemPicker(enemy.reward.drop, choices)
                    Text("Charm").foregroundStyle(.secondary)
                    itemPicker(enemy.reward.charm, choices)
                }
            }
            Text("The drop comes 90% of the time, always when it equals the charm item; Charm steals the charm item.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func itemPicker(_ value: Binding<Int>, _ choices: [(id: Int, name: String)]) -> some View {
        Picker("", selection: value) {
            if !(0..<CTEnemyROM.itemCount).contains(value.wrappedValue) {
                Text(String(format: "$%02X (not an item)", value.wrappedValue & 0xFF)).tag(value.wrappedValue)
            }
            ForEach(choices, id: \.id) { item in Text(item.name).tag(item.id) }
        }
        .labelsHidden()
        .frame(maxWidth: 220)
    }

    private func attackBox(_ e: CharacterDef.Enemy) -> some View {
        GroupBox("Plain attack (read-only)") {
            if let a = e.attack {
                let part = a.part == CTEnemyROM.partNone ? "no effect record" : String(format: "effect record $%02X", a.part)
                let line = String(format: "Attack record %d: flags $%02X, element bits $%X, ", a.id, a.flags, a.elementBits) + part
                VStack(alignment: .leading, spacing: 4) {
                    Text(line).font(.caption.monospaced())
                    if let effect = a.effect {
                        Text("effect bytes " + effect.map { String(format: "%02X", $0) }.joined(separator: " "))
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("No attack record (reimport the ROM's enemies).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The tech ids the script's tech actions name (`tech=$hh`).
    private func techIDs(_ text: String) -> [String] {
        var out: [String] = []
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\n" }) where token.hasPrefix("tech=$") {
            let id = String(token.dropFirst(5))
            if !out.contains(id) { out.append(id) }
        }
        return out
    }

    private func scriptBox(_ e: CharacterDef.Enemy) -> some View {
        GroupBox("AI script (read-only)") {
            if let s = e.ai, let text = s.text {
                VStack(alignment: .leading, spacing: 6) {
                    let techs = techIDs(text)
                    Text("At \(s.address)" + (techs.isEmpty ? "" : "; enemy techs " + techs.joined(separator: ", ")))
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView([.horizontal, .vertical]) {
                        Text(text).font(.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160, maxHeight: 320)
                }
            } else if let s = e.ai {
                Text("At \(s.address): \(s.error ?? "not decoded")").font(.caption).foregroundStyle(.orange)
            } else {
                Text("No AI script (reimport the ROM's enemies).").font(.caption).foregroundStyle(.secondary)
            }
            Text("Tests and actions are named only where the battle code proves them; other bytes show as b1=$hh.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
