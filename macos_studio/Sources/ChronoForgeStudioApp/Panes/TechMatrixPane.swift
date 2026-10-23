// TechMatrixPane.swift — Module 1's Tech & Synergy Matrix: each character's
// single techs, the dual and triple techs with their requirements, target
// zones, and the tech-point rule (docs/techs.md).
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct TechMatrixPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var importROM = false
    @State private var revision = 0          // re-seeds the editor after an import

    var body: some View {
        Group {
            if let system = project.techSystem {
                EditorHost(entity: system, apply: { store.updateTechSystem($0) }) { $s in
                    TechMatrixEditor(system: $s, store: store, project: project)
                }
                .id(revision)
            } else {
                ContentUnavailableView {
                    Label("No tech tables", systemImage: "sparkles")
                } description: {
                    Text("Import the ROM's techs to edit the singles, the dual and triple techs and the tech points.")
                } actions: {
                    Button("Import Techs from ROM…") { importROM = true }
                }
            }
        }
        .toolbar {
            Button(project.techSystem == nil ? "Import Techs from ROM…" : "Reimport Techs from ROM…") { importROM = true }
        }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importTechs(url); revision += 1 }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
    }
}

private enum Page: Hashable { case character(Int), doubles, triples, points }

private func charName(_ c: Int) -> String {
    CTCharacterROM.names.indices.contains(c) ? CTCharacterROM.names[c].capitalized : "#\(c)"
}

private struct TechMatrixEditor: View {
    @Binding var system: TechSystemDef
    let store: ProjectStore
    let project: CTProject
    @State private var page: Page = .character(0)
    @State private var selected = 1

    var body: some View {
        HSplitView {
            List(selection: $page) {
                Section("Single techs") {
                    ForEach(0..<CTCharacterROM.count, id: \.self) { c in Text(charName(c)).tag(Page.character(c)) }
                }
                Section("Synergy") {
                    Text("Dual techs").tag(Page.doubles)
                    Text("Triple techs").tag(Page.triples)
                }
                Section("Rule") { Text("Tech points").tag(Page.points) }
            }
            .frame(minWidth: 150, idealWidth: 170, maxWidth: 220)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    switch page {
                    case .character(let c):
                        SinglesTable(system: $system, character: c, selected: $selected)
                    case .doubles:
                        DoublesMatrix(system: $system, selected: $selected)
                    case .triples:
                        TriplesList(system: $system, selected: $selected)
                    case .points:
                        TechPointsSimulator(system: system, project: project)
                    }
                    if page != .points && system.techs.indices.contains(selected) {
                        TechEditor(system: $system, id: selected)
                        TechHelpLine(id: selected, romPath: store.sceneROMPath,
                                     names: CTDialogueSettings.projectNames(project))
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { select(page) }
        .onChange(of: page) { _, new in select(new) }
    }

    /// The tech the editor shows when a page opens.
    private func select(_ page: Page) {
        switch page {
        case .character(let c): selected = 1 + 8 * c
        case .doubles: selected = system.combos.first?.first ?? CTTechROM.firstDouble
        case .triples: selected = CTTechROM.firstTriple
        case .points: break
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            problems
            Spacer()
            Toggle("Write techs to ROM", isOn: Binding(
                get: { project.project.rom?.techs ?? false },
                set: { _ = store.updateROMTechs($0) }))
            Button("Apply") { store.updateTechSystem(system) }.keyboardShortcut("s", modifiers: .command)
        }
    }

    private var problems: some View {
        let message: String? = {
            do { try CTTechROM.check(system); return nil } catch { return "\(error)" }
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

// MARK: - Singles

private struct SinglesTable: View {
    @Binding var system: TechSystemDef
    let character: Int
    @Binding var selected: Int

    var body: some View {
        let c = character
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(charName(c))'s single techs").font(.headline)
                    Spacer()
                    Stepper(value: learnedCount, in: 0...CTTechROM.singlesPerCharacter) {
                        Text("Learned at a new game: \(system.learned.counts[c])").monospacedDigit()
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["", "Tech", "MP", "TP to learn", "Target", "Area", "Element", ""], id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(0..<CTTechROM.singlesPerCharacter, id: \.self) { k in
                        let id = 1 + 8 * c + k
                        let t = system.techs[id]
                        GridRow {
                            Image(systemName: k < system.learned.counts[c] ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(k < system.learned.counts[c] ? Color.accentColor : .secondary)
                                .help("Learned at a new game")
                            Button { selected = id } label: {
                                Text(String(format: "$%02X %@", id, t.name)).fontWeight(selected == id ? .bold : .regular)
                            }
                            .buttonStyle(.plain)
                            Text(mpText(t)).monospacedDigit()
                            TextField("", value: $system.tpCost[c][k], format: .number).frame(width: 64)
                            Text(String(format: "$%02X", t.targetMode)).monospacedDigit()
                                .help(CTTechTargets.modes[min(t.targetMode, CTTechTargets.modes.count - 1)])
                            Text(t.area == 0 ? "—" : String(format: "$%02X", t.area)).monospacedDigit()
                            Text(t.element ?? "—")
                            Text(t.needsUnlock ? "needs the unlock" : "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("TP to learn is TechTpCost: the points from the previous single to this one. The first single needing the unlock ($7F:01E0) waits for it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        CombinationsOf(system: system, character: c, selected: $selected)
    }

    private var learnedCount: Binding<Int> {
        Binding(get: { system.learned.counts[character] }, set: { n in
            system.learned.counts[character] = n
            system.learned.bits1[character] = CTTechROM.topBits(n)
        })
    }

    private func mpText(_ t: TechSystemDef.Tech) -> String {
        t.parts.map { $0 & 0x80 != 0 ? "–" : String(system.parts[$0 & 0x7F].mp) }.joined(separator: "/")
    }
}

/// The dual and triple techs a character takes part in, with their requirements.
private struct CombinationsOf: View {
    let system: TechSystemDef
    let character: Int
    @Binding var selected: Int

    var body: some View {
        let combos = system.combos.filter { $0.members.contains(character) }
        if !combos.isEmpty {
            GroupBox("Dual and triple techs with \(charName(character))") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                    ForEach(combos, id: \.first) { combo in
                        ForEach(combo.requirements.indices, id: \.self) { k in
                            GridRow {
                                Button(String(format: "$%02X %@", combo.first + k, system.techs[combo.first + k].name)) {
                                    selected = combo.first + k
                                }
                                .buttonStyle(.plain)
                                Text(combo.members.map(charName).joined(separator: " + ")).foregroundStyle(.secondary)
                                Text("needs " + zip(combo.members, combo.requirements[k])
                                    .map { "\(charName($0)) \($1)" }.joined(separator: ", ")).font(.caption)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Dual techs: the 7 x 7 matrix

private struct DoublesMatrix: View {
    @Binding var system: TechSystemDef
    @Binding var selected: Int
    @State private var pair: Int?             // index into system.combos

    var body: some View {
        GroupBox("Dual techs: one ComboTechs record per pair") {
            VStack(alignment: .leading, spacing: 8) {
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    GridRow {
                        Text("")
                        ForEach(0..<CTCharacterROM.count, id: \.self) { Text(charName($0)).font(.caption).frame(width: 64) }
                    }
                    ForEach(0..<CTCharacterROM.count, id: \.self) { a in
                        GridRow {
                            Text(charName(a)).font(.caption).frame(width: 56, alignment: .trailing)
                            ForEach(0..<CTCharacterROM.count, id: \.self) { b in cell(a, b) }
                        }
                    }
                }
                Text("Each cell is the pair's record: how many dual techs it holds and how many are learned at a new game. A dual tech is learned once both members have learned the singles its requirements name.")
                    .font(.caption).foregroundStyle(.secondary)
                if let i = pair, system.combos.indices.contains(i) {
                    RequirementsEditor(system: $system, index: i, selected: $selected)
                }
            }
        }
    }

    @ViewBuilder private func cell(_ a: Int, _ b: Int) -> some View {
        let mask = (0x80 >> a) | (0x80 >> b)
        if a == b {
            Text("—").foregroundStyle(.tertiary).frame(width: 64, height: 34)
        } else if let i = system.combos.firstIndex(where: { $0.mask == mask }) {
            let combo = system.combos[i]
            let learned = (0..<combo.requirements.count).filter { system.comboLearned(i, $0) }.count
            Button { pair = i; selected = combo.first } label: {
                VStack(spacing: 0) {
                    Text("\(combo.requirements.count)").font(.headline)
                    Text("\(learned) learned").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 34)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(pair == i ? Color.accentColor.opacity(0.35) : Color.accentColor.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help(combo.members.map(charName).joined(separator: " + "))
        } else {
            Text("").frame(width: 64, height: 34)
                .background(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
        }
    }
}

// MARK: - Triple techs

private struct TriplesList: View {
    @Binding var system: TechSystemDef
    @Binding var selected: Int
    @State private var record: Int?

    var body: some View {
        let triples = system.combos.indices.filter { system.combos[$0].members.count == 3 }
        GroupBox("Triple techs") {
            VStack(alignment: .leading, spacing: 8) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    ForEach(triples, id: \.self) { i in
                        let combo = system.combos[i]
                        GridRow {
                            Button(String(format: "$%02X %@", combo.first, system.techs[combo.first].name)) {
                                record = i; selected = combo.first
                            }
                            .buttonStyle(.plain)
                            .fontWeight(record == i ? .bold : .regular)
                            Text(combo.members.map(charName).joined(separator: " + ")).foregroundStyle(.secondary)
                            Text("needs " + zip(combo.members, combo.requirements[0]).map { "\(charName($0)) \($1)" }
                                .joined(separator: ", ")).font(.caption)
                            Image(systemName: system.comboLearned(i, 0) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(.secondary).help("Learned at a new game")
                        }
                    }
                    let rest = (CTTechROM.firstTriple..<CTTechROM.count).filter { system.combo(of: $0) == nil }
                    ForEach(rest, id: \.self) { id in
                        GridRow {
                            Button(String(format: "$%02X %@", id, system.techs[id].name)) { record = nil; selected = id }
                                .buttonStyle(.plain)
                            Text(system.users(of: id).map(charName).joined(separator: " + ")).foregroundStyle(.secondary)
                            Text("in no combination record: tech points never teach it").font(.caption).foregroundStyle(.secondary)
                            Image(systemName: system.isLearned(id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.secondary)
                        }
                    }
                }
                if let i = record { RequirementsEditor(system: $system, index: i, selected: $selected) }
            }
        }
    }
}

/// One ComboTechs record's techs: each member's required single count (1-8)
/// and whether the tech is learned at a new game.
private struct RequirementsEditor: View {
    @Binding var system: TechSystemDef
    let index: Int
    @Binding var selected: Int

    var body: some View {
        let combo = system.combos[index]
        GroupBox(combo.members.map(charName).joined(separator: " + ") + String(format: " (record %d, first tech $%02X)", index, combo.first)) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Tech").font(.caption).foregroundStyle(.secondary)
                    ForEach(combo.members, id: \.self) { Text("\(charName($0)) singles").font(.caption).foregroundStyle(.secondary) }
                    Text("At a new game").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(combo.requirements.indices, id: \.self) { k in
                    GridRow {
                        Button(String(format: "$%02X %@", combo.first + k, system.techs[combo.first + k].name)) { selected = combo.first + k }
                            .buttonStyle(.plain)
                            .fontWeight(selected == combo.first + k ? .bold : .regular)
                        ForEach(combo.members.indices, id: \.self) { m in
                            Stepper(value: $system.combos[index].requirements[k][m], in: 1...8) {
                                Text("\(system.combos[index].requirements[k][m])").monospacedDigit()
                            }
                        }
                        Toggle("learned", isOn: Binding(
                            get: { system.comboLearned(index, k) },
                            set: { on in
                                let bit = 0x80 >> k
                                system.learned.comboBits[index] = on ? system.learned.comboBits[index] | bit
                                                                     : system.learned.comboBits[index] & ~bit
                            }))
                    }
                }
            }
        }
    }
}

extension TechSystemDef {
    /// Whether record `index`'s tech `k` is learned at a new game.
    fileprivate func comboLearned(_ index: Int, _ k: Int) -> Bool { learned.comboBits[index] & (0x80 >> k) != 0 }
}

// MARK: - One tech

private struct TechEditor: View {
    @Binding var system: TechSystemDef
    let id: Int

    var body: some View {
        let t = system.techs[id]
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(String(format: "$%02X %@", id, t.name)).font(.headline)
                    Text("\(t.kind) · " + system.users(of: id).map(charName).joined(separator: " + ")).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 24) {
                    fields(t)
                    TargetZonePreview(system: system, id: id)
                }
                ForEach(0..<3, id: \.self) { k in
                    if t.parts[k] & 0x80 == 0 { PartEditor(system: $system, part: t.parts[k] & 0x7F, user: k) }
                }
            }
        }
    }

    private func fields(_ t: TechSystemDef.Tech) -> some View {
        Grid(alignment: .leading, verticalSpacing: 6) {
            GridRow {
                Text("Target").foregroundStyle(.secondary)
                Picker("", selection: $system.techs[id].targetMode) {
                    ForEach(0..<CTTechROM.targetModes, id: \.self) { m in
                        Text(String(format: "$%02X %@", m, CTTechTargets.modes[m])).tag(m)
                    }
                }
                .labelsHidden().frame(maxWidth: 300)
            }
            GridRow {
                Text("")
                Toggle("Usable from the field menu", isOn: $system.techs[id].fieldMenu)
            }
            GridRow {
                Text("Area").foregroundStyle(.secondary)
                Picker("", selection: $system.techs[id].area) {
                    Text("none").tag(0)
                    ForEach(1..<system.areas.count, id: \.self) { a in
                        if let e = system.areas[a].first { Text(String(format: "$%02X ", a) + areaText(e)).tag(a) }
                    }
                }
                .labelsHidden().frame(maxWidth: 300)
            }
            GridRow {
                Text("Element").foregroundStyle(.secondary)
                Picker("", selection: $system.techs[id].element) {
                    Text("none").tag(String?.none)
                    ForEach(CTTechROM.elements, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .labelsHidden().frame(maxWidth: 160)
            }
            GridRow {
                Text("")
                Toggle("Needs the character's unlock bit ($7F:01E0)", isOn: $system.techs[id].needsUnlock)
            }
            GridRow {
                Text("Parts").foregroundStyle(.secondary)
                HStack {
                    ForEach(0..<3, id: \.self) { k in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("user \(k + 1): part, modifier").font(.caption2).foregroundStyle(.secondary)
                            HStack(spacing: 2) {
                                TextField("", value: partNumber(k), format: .number).frame(width: 40)
                                    .disabled(t.parts[k] & 0x80 != 0)
                                Toggle("none", isOn: partNone(k)).toggleStyle(.checkbox).font(.caption)
                            }
                            TextField("", value: $system.techs[id].modifiers[k], format: .number).frame(width: 40)
                                .help("Modifier record (BattleRom_UnkCC2A05), below 57")
                        }
                    }
                }
            }
            GridRow {
                Text("Animation").foregroundStyle(.secondary)
                HStack {
                    Text("script"); TextField("", value: $system.techs[id].anim.script, format: .number).frame(width: 48)
                    Text("frames"); TextField("", value: $system.techs[id].anim.frames, format: .number).frame(width: 48)
                }
            }
        }
    }

    private func areaText(_ e: TechSystemDef.Area) -> String {
        let shape = CTTechTargets.shapes[min(e.shape, CTTechTargets.shapes.count - 1)]
        if e.param & 0x80 != 0 { return "\(shape): position query" }
        return "\(shape), \(CTTechTargets.params[min(e.param & 0x7F, 6)]), size \(e.size & 0x7F)" + (e.size & 0x80 != 0 ? " (box)" : "")
    }

    private func partNumber(_ k: Int) -> Binding<Int> {
        Binding(get: { system.techs[id].parts[k] & 0x7F }, set: { system.techs[id].parts[k] = system.techs[id].parts[k] & 0x80 | $0 & 0x7F })
    }

    private func partNone(_ k: Int) -> Binding<Bool> {
        Binding(get: { system.techs[id].parts[k] & 0x80 != 0 },
                set: { system.techs[id].parts[k] = $0 ? system.techs[id].parts[k] | 0x80 : system.techs[id].parts[k] & 0x7F })
    }
}

/// A part: its MP cost and its effect record's 12 bytes.
private struct PartEditor: View {
    @Binding var system: TechSystemDef
    let part: Int
    let user: Int

    var body: some View {
        DisclosureGroup {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    ForEach(0..<6, id: \.self) { i in field(i) }
                }
                GridRow {
                    ForEach(6..<12, id: \.self) { i in field(i) }
                }
            }
            Text("Type is the BattleSys_EffectTable handler (0-44); docs/techs.md says what each byte does for the types decoded.")
                .font(.caption).foregroundStyle(.secondary)
        } label: {
            HStack {
                Text("User \(user + 1): part \(part)")
                Text("MP").foregroundStyle(.secondary)
                TextField("", value: $system.parts[part].mp, format: .number).frame(width: 44)
                Text("power \(system.parts[part].effect.power), type \(system.parts[part].effect.type)").foregroundStyle(.secondary)
            }
        }
    }

    private func field(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(TechSystemDef.Effect.names[i]).font(.caption2).foregroundStyle(.secondary)
            TextField("", value: Binding(get: { system.parts[part].effect.values[i] },
                                         set: { system.parts[part].effect.values[i] = $0 }), format: .number)
                .frame(width: 52)
        }
    }
}

// MARK: - Target zones

/// Screen positions for the preview: PC slots 0-2, then enemies 3-10
/// (illustrative; the game's come from the battle).
private let sampleLayout: [CTTechTargets.Point?] = [
    .init(x: 96, y: 160), .init(x: 144, y: 184), .init(x: 192, y: 160),
    .init(x: 40, y: 56), .init(x: 88, y: 40), .init(x: 136, y: 56), .init(x: 184, y: 40),
    .init(x: 232, y: 56), .init(x: 64, y: 100), .init(x: 128, y: 92), .init(x: 200, y: 104)]

/// The tech's menu target and its area record drawn over a sample battle
/// layout.
private struct TargetZonePreview: View {
    let system: TechSystemDef
    let id: Int
    @State private var target = 5

    var body: some View {
        let t = system.techs[id]
        let users = system.users(of: id)
        // The users in slots 0.., the rest of the party after them.
        let party: [Int?] = Array((users + (0..<CTCharacterROM.count).filter { !users.contains($0) }).prefix(3))
        let caster = 0
        let menu = CTTechTargets.menu(t.targetMode, caster: caster, target: target, party: party)
        let entry = t.area == 0 ? nil : system.areas[t.area].first
        let zone = entry.flatMap { CTTechTargets.zone($0, users: Array(0..<users.count), caster: caster, target: target) }
        let menuSlots = menu.zone.map { CTTechTargets.hits($0, positions: sampleLayout) } ?? menu.slots
        let areaSlots = zone.map { CTTechTargets.hits($0, positions: sampleLayout) } ?? []
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                let scale = min(size.width / 256, size.height / 224)
                func p(_ slot: Int) -> CGPoint {
                    let q = sampleLayout[slot]!
                    return CGPoint(x: CGFloat(q.x) * scale, y: CGFloat(q.y) * scale)
                }
                context.fill(Path(CGRect(origin: .zero, size: CGSize(width: 256 * scale, height: 224 * scale))),
                             with: .color(.gray.opacity(0.08)))
                if let z = menu.zone { draw(z, in: &context, scale: scale, p: p, color: .orange, filled: false) }
                if let z = zone { draw(z, in: &context, scale: scale, p: p, color: .purple, filled: true) }
                for slot in 0..<sampleLayout.count {
                    let at = p(slot)
                    let pc = CTTechTargets.partySlots.contains(slot)
                    let hit = areaSlots.contains(slot) || menuSlots.contains(slot)
                    let r: CGFloat = 9 * scale
                    let dot = Path(ellipseIn: CGRect(x: at.x - r, y: at.y - r, width: 2 * r, height: 2 * r))
                    context.fill(dot, with: .color((pc ? Color.blue : Color.red).opacity(hit ? 0.9 : 0.35)))
                    if slot == target { context.stroke(dot, with: .color(.primary), lineWidth: 2) }
                    let label = pc ? (party[slot].map { String(charName($0).prefix(3)) } ?? "–") : "E\(slot)"
                    context.draw(Text(label).font(.system(size: 9)), at: CGPoint(x: at.x, y: at.y + r + 7))
                }
            }
            .frame(width: 300, height: 262)
            .border(.quaternary)
            Stepper(value: $target, in: CTTechTargets.enemySlots.lowerBound...(CTTechTargets.enemySlots.upperBound - 1)) {
                Text("Chosen enemy: E\(target)").font(.caption)
            }
            .frame(width: 300)
            Text(String(format: "Menu ($%02X): %@", t.targetMode, CTTechTargets.modes[min(t.targetMode, 32)]))
                .font(.caption).foregroundStyle(.orange)
            if let entry {
                Text(entry.param & 0x80 != 0 ? "Area: position query (no zone)"
                     : "Area: \(CTTechTargets.shapes[min(entry.shape, 6)]), \(CTTechTargets.params[min(entry.param & 0x7F, 6)])")
                    .font(.caption).foregroundStyle(.purple)
            }
            Text("Takes in: " + (areaSlots.isEmpty ? menuSlots : areaSlots).map { $0 < 3 ? (party[$0].map(charName) ?? "–") : "E\($0)" }
                .joined(separator: ", ")).font(.caption)
            Text("Sample positions. Circles are the 16-pixel cells the routine accepts; the line's strip is its inferred geometry.")
                .font(.caption2).foregroundStyle(.secondary).frame(width: 300, alignment: .leading)
        }
    }

    private func draw(_ z: CTTechTargets.Zone, in context: inout GraphicsContext, scale: CGFloat,
                      p: (Int) -> CGPoint, color: Color, filled: Bool) {
        let path: Path
        switch z.shape {
        case .circle(let centre, let size):
            // The 16-pixel cells BattleTgt_AreaCircle accepts around the centre's cell.
            guard sampleLayout.indices.contains(centre), let c = sampleLayout[centre] else { return }
            var cells = Path()
            for dy in -15...15 {
                for dx in -15...15 where dx * dx + dy * dy <= size {
                    let (x, y) = (c.x >> 4 + dx, c.y >> 4 + dy)
                    guard (0..<16).contains(x), (0..<14).contains(y) else { continue }
                    cells.addRect(CGRect(x: CGFloat(x * 16) * scale, y: CGFloat(y * 16) * scale,
                                         width: 16 * scale, height: 16 * scale))
                }
            }
            path = cells
        case .row(let centre):
            guard sampleLayout.indices.contains(centre), sampleLayout[centre] != nil else { return }
            let c = p(centre)
            path = Path(CGRect(x: 0, y: c.y - 32 * scale, width: 256 * scale, height: 64 * scale))
        case .partyTriangle:
            var t = Path()
            t.addLines([p(0), p(1), p(2)])
            t.closeSubpath()
            path = t
        case .line(let source, let aim, let size, let box):
            guard [source, aim].allSatisfy({ sampleLayout.indices.contains($0) && sampleLayout[$0] != nil }) else { return }
            let s = p(source), a = p(aim)
            let (dx, dy) = (a.x - s.x, a.y - s.y)
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 0 else { return }
            let (ux, uy) = (dx / length, dy / length)
            let w = CGFloat(size * 8) * scale
            let reach = box ? length : 400 * scale
            var l = Path()
            l.addLines([CGPoint(x: s.x - uy * w, y: s.y + ux * w), CGPoint(x: s.x + uy * w, y: s.y - ux * w),
                        CGPoint(x: s.x + uy * w + ux * reach, y: s.y - ux * w + uy * reach),
                        CGPoint(x: s.x - uy * w + ux * reach, y: s.y + ux * w + uy * reach)])
            l.closeSubpath()
            path = l
        }
        if filled { context.fill(path, with: .color(color.opacity(0.18))) }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: filled ? [] : [4, 3]))
    }
}

// MARK: - Tech points

/// The game's tech-point award (CTTechPoints) over a party and awards, from
/// the project's records and the new-game tech state.
private struct TechPointsSimulator: View {
    let system: TechSystemDef
    let project: CTProject
    @State private var party: [Int?] = [0, 1, 2]
    @State private var unlock = 0
    @State private var awards = "7, 30, 99, 400"

    var body: some View {
        var records: [Int: CharacterDef.Record] = [:]
        for c in project.characters.values { if let r = c.pc { records[r.charId] = r } }
        return GroupBox("Tech points: what a battle's award teaches") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ForEach(0..<3, id: \.self) { slot in
                        Picker("Slot \(slot + 1)", selection: $party[slot]) {
                            Text("empty").tag(Int?.none)
                            ForEach(0..<CTCharacterROM.count, id: \.self) { Text(charName($0)).tag(Int?.some($0)) }
                        }
                        .frame(maxWidth: 170)
                    }
                }
                HStack {
                    Text("Unlocked ($7F:01E0)").foregroundStyle(.secondary)
                    ForEach(0..<CTCharacterROM.count, id: \.self) { c in
                        Toggle(charName(c), isOn: Binding(get: { unlock & (1 << c) != 0 },
                                                          set: { unlock = $0 ? unlock | 1 << c : unlock & ~(1 << c) }))
                            .toggleStyle(.checkbox)
                    }
                }
                HStack {
                    Text("Awards").foregroundStyle(.secondary)
                    TextField("comma-separated tech points", text: $awards).frame(maxWidth: 260)
                }
                let missing = party.compactMap { $0 }.filter { records[$0] == nil }
                if !missing.isEmpty {
                    Label("Import the characters first: no record for " + missing.map(charName).joined(separator: ", "),
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.caption)
                } else {
                    steps(records)
                }
                Text("The rule is the ROM's AwardTechPoints with its quirks: a cost above the leftover is paid with the award again, and the total stops at 9,999,999 (docs/techs.md).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func steps(_ records: [Int: CharacterDef.Record]) -> some View {
        let values = awards.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let tables = CTTechPoints.tables(system)
        let start = CTTechPoints.startingState(system, records: records, party: party, unlock: unlock)
        switch Result(catching: { try values.reduce(into: [start]) { $0.append(try CTTechPoints.award($0.last!, tables: tables, award: $1)) } }) {
        case .failure(let error):
            Label(String(describing: error), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        case .success(let states):
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text("Award").font(.caption).foregroundStyle(.secondary)
                    Text("Learned").font(.caption).foregroundStyle(.secondary)
                    ForEach(party.compactMap { $0 }, id: \.self) { Text("\(charName($0)) TP / next").font(.caption).foregroundStyle(.secondary) }
                }
                ForEach(values.indices, id: \.self) { i in
                    GridRow {
                        Text("\(values[i])").monospacedDigit()
                        Text(learned(states[i], states[i + 1])).frame(maxWidth: 320, alignment: .leading)
                        ForEach(states[i + 1].slots.compactMap { $0 }, id: \.char) { s in
                            Text("\(s.tp) / \(s.toNext)").monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private func learned(_ a: CTTechPoints.State, _ b: CTTechPoints.State) -> String {
        var names: [String] = []
        for c in 0..<CTCharacterROM.count where b.counts[c] > a.counts[c] {
            names += (a.counts[c]..<b.counts[c]).map { system.techs[1 + 8 * c + $0].name }
        }
        for (i, (x, y)) in zip(a.comboBits, b.comboBits).enumerated() where x != y {
            for k in 0..<8 where (y & ~x) & (0x80 >> k) != 0 {
                let id = i < system.combos.count ? system.combos[i].first + k : CTTechROM.firstTriple + i - CTTechROM.doubleRecords
                if system.techs.indices.contains(id) { names.append(system.techs[id].name) }
            }
        }
        return names.isEmpty ? "—" : names.joined(separator: ", ")
    }
}

/// The tech's description in the menu's help line (Menu_TechDescText, BG3 rows
/// 21-22), from the ROM; a draft text previews live. Tech descriptions are
/// not part of the project yet, so a draft is not saved.
private struct TechHelpLine: View {
    let id: Int
    let romPath: String?
    let names: [Int: String]
    @State private var drafts: [Int: String] = [:]

    var body: some View {
        GroupBox("Help line") {
            VStack(alignment: .leading, spacing: 6) {
                if id < CTHelpLineROM.techCount {
                    HStack {
                        TextField("Draft a description (preview only)", text: Binding(
                            get: { drafts[id] ?? romText ?? "" }, set: { drafts[id] = $0 }))
                            .frame(maxWidth: 420)
                        if drafts[id] != nil { Button("Revert") { drafts[id] = nil } }
                    }
                    HelpLinePreviewView(source: drafts[id].map { .text($0) } ?? .rom(id), place: .tech,
                                        romPath: romPath, names: names, scale: 1.5)
                    Text("Tech descriptions are not saved in the project yet: a draft only previews.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(String(format: "Tech $%02X has no description (the table covers $00-$75)", id))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The ROM's description decoded with its dictionary.
    private var romText: String? {
        guard let romPath, let assets = DialogueAssets.load(romPath), let codec = assets.codec else { return nil }
        let bytes = CTHelpLine.description(CTDialogueMemory(rom: assets.rom), place: .tech, index: id)
        return try? codec.decode(bytes)
    }
}
