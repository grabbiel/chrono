// SceneLocationViews.swift — Module 8, the Scene Director on a real location:
// the event pack it loads, raised into a scene (CTSceneDocument), shown as
// its listing, a node graph, a timeline and on the map canvas, with one
// selection shared by all four. Edits re-assemble through CTEventProgram;
// Save keeps them as a listing the ROM build writes over the pack.
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

/// What the views have selected: an object, one of its functions
/// (CTSceneGraph.continuation for the continuation) and a statement.
struct SceneSelection: Equatable {
    var object: Int?
    var function: Int?
    var offset: Int?
}

/// The ROM locations, by LocRom index, named after the project's maps.
struct LocationScenesView: View {
    let store: ProjectStore
    let project: CTProject
    @State private var rom: [UInt8]?
    @State private var problem = ""
    @State private var location: Int?
    @State private var choosing = false

    init(store: ProjectStore, project: CTProject, initial: Int?) {
        self.store = store; self.project = project
        _location = State(initialValue: initial)
    }

    private var names: [Int: String] {
        Dictionary(project.maps.values.compactMap { m in m.rom.map { ($0.location, m.name) } }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Location").font(.headline)
                TextField("0-\(CTMapROM.locCount - 1)", value: $location, format: .number).frame(width: 60)
                Stepper("", value: Binding(get: { location ?? 0 }, set: { location = $0 }), in: 0...(CTMapROM.locCount - 1)).labelsHidden()
                Menu("Imported Maps") {
                    ForEach(names.keys.sorted(), id: \.self) { i in
                        Button(String(format: "loc_%03d  %@", i, names[i]!)) { location = i }
                    }
                }.frame(maxWidth: 160).disabled(names.isEmpty)
                if let location, let n = names[location] { Text(n).foregroundStyle(.secondary) }
                Spacer()
                Button("Choose ROM…") { choosing = true }
            }
            .padding(.horizontal).padding(.top, 8)
            Group {
                if let rom, let location, (0..<CTMapROM.locCount).contains(location) {
                    LocationSceneEditor(store: store, project: project, rom: rom, location: location)
                        .id("\(project.url.path)#\(location)")
                } else if rom == nil {
                    ContentUnavailableView("No ROM", systemImage: "externaldrive",
                                           description: Text(problem.isEmpty ? "Choose your Chrono Trigger (US 1.0) ROM to read its event packs." : problem))
                } else {
                    ContentUnavailableView("Choose a location", systemImage: "map")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: loadROM)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                if store.setPlaybackROM(url) { rom = nil; loadROM() } else { problem = store.statusMessage }
            }
        }
    }

    private func loadROM() {
        guard rom == nil, let path = store.sceneROMPath else { return }
        do { rom = try ProjectStore.sceneROM(path) } catch { problem = "\(path): \(error)" }
    }
}

struct LocationSceneEditor: View {
    let store: ProjectStore
    let project: CTProject
    let rom: [UInt8]
    let location: Int
    @State private var doc: CTSceneDocument?
    @State private var savedDoc: CTSceneDocument?
    @State private var fromProject = false
    @State private var analysis: CTSceneAnalysis?
    @State private var text = ""
    @State private var textOffsets: [Int?] = []
    @State private var textSelection: TextSelection?
    @State private var listingEdited = false
    /// `--scene-object N` at launch selects object N (screenshots, demos).
    @State private var selection = SceneSelection(object: LaunchArguments.value("--scene-object").flatMap { Int($0) }, function: 0,
                                                  offset: LaunchArguments.value("--scene-statement").flatMap { Int($0, radix: 16) })
    @State private var tab = LaunchArguments.value("--scene-tab") ?? "Map"
    @State private var diagnostic = ""
    @State private var showListing = LaunchArguments.value("--scene-listing") != "hide"

    private var dirty: Bool { doc != savedDoc }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if let doc, let analysis {
                HStack(alignment: .top, spacing: 10) {
                    if showListing { listing.frame(width: 300) }
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("View", selection: $tab) {
                            Text("Map").tag("Map")
                            Text("Node Graph").tag("Graph")
                            Text("Timeline").tag("Timeline")
                            Text("Objects").tag("Objects")
                        }.pickerStyle(.segmented)
                        switch tab {
                        case "Graph": SceneNodeGraph(analysis: analysis, selection: $selection)
                        case "Timeline": SceneTimelineView(document: doc, analysis: analysis, selection: $selection)
                        case "Objects": objects(analysis)
                        default:
                            SceneMapCanvas(store: store, project: project, rom: rom, location: location, document: doc,
                                           analysis: analysis, selection: $selection, edit: edit)
                        }
                        Divider()
                        SceneStatementInspector(analysis: analysis, selection: $selection, edit: edit,
                                                romPath: store.sceneROMPath)
                    }
                    .frame(minWidth: 340, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
                }
            } else {
                ContentUnavailableView("Cannot open this location", systemImage: "exclamationmark.triangle",
                                       description: Text(diagnostic))
            }
            if !diagnostic.isEmpty, doc != nil {
                Text(diagnostic).font(.callout).foregroundStyle(.red).textSelection(.enabled).lineLimit(3)
            }
        }
        .padding()
        .onAppear(perform: open)
        .onChange(of: selection) { _, s in followSelectionInText(s) }
        .onChange(of: textSelection) { _, t in followTextSelection(t) }
    }

    private var header: some View {
        HStack {
            Text(String(format: "loc_%03d", location)).font(.title2)
            if let doc { Text("event pack \(doc.packEntry ?? 0)").foregroundStyle(.secondary) }
            if fromProject { Text("saved listing").font(.caption).padding(3).background(.tint.opacity(0.15)) }
            if dirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Toggle("Listing", isOn: $showListing).toggleStyle(.button)
            Button("Revert") { if let savedDoc { set(savedDoc) } }.disabled(!dirty)
            Button("Reraise from ROM") {
                if let entry = doc?.packEntry, store.revertLocationScene(entry: entry) { open() }
            }.disabled(!fromProject)
            Button("Save") {
                if let doc, store.saveLocationScene(doc) { savedDoc = doc; fromProject = true; diagnostic = "" }
                else { diagnostic = store.statusMessage }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(!dirty || listingEdited)
        }
    }

    // MARK: Listing (the scene's text form)

    private var listing: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Listing").font(.headline)
                Spacer()
                Button("Apply Listing", action: applyListing).disabled(!listingEdited)
            }
            TextEditor(text: Binding(get: { text }, set: { text = $0; listingEdited = true }), selection: $textSelection)
                .font(.system(.caption, design: .monospaced))
                .accessibilityLabel("Scene listing")
            Text(listingEdited ? "Edited: Apply re-assembles and checks every opcode." :
                    "ct-events/1; the cursor selects a statement in every view.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func open() {
        do {
            let (d, saved) = try store.raiseLocation(location, rom: rom)
            fromProject = saved
            savedDoc = d
            set(d)
            diagnostic = ""
        } catch { doc = nil; diagnostic = "\(error)" }
    }

    private func set(_ d: CTSceneDocument) {
        do {
            let a = try d.analyze()
            let (t, offsets) = try d.annotatedListing(title: String(format: "loc_%03d", location))
            doc = d; analysis = a; text = t; textOffsets = offsets; listingEdited = false
            if let k = selection.object, k >= a.objectCount { selection = SceneSelection() }
        } catch { diagnostic = "\(error)" }
    }

    private func applyListing() {
        guard var d = doc else { return }
        do {
            d.program = try CTEventListing.parse(text)
            _ = try d.lower()
            set(d); diagnostic = ""
        } catch { diagnostic = "listing: \(error)" }
    }

    /// Runs an edit on a copy; the document changes only when it re-assembles.
    private func edit(_ change: (inout CTSceneDocument) throws -> Void) {
        guard var d = doc else { return }
        if listingEdited { diagnostic = "apply or revert the listing first"; return }
        do { try change(&d); set(d); diagnostic = "" } catch { diagnostic = "\(error)" }
    }

    private func line(of index: String.Index) -> Int { text[..<index].reduce(0) { $1 == "\n" ? $0 + 1 : $0 } }

    private func followTextSelection(_ t: TextSelection?) {
        guard let t, case .selection(let range) = t.indices, range.upperBound <= text.endIndex else { return }
        let n = line(of: range.lowerBound)
        guard n < textOffsets.count, let y = textOffsets[n], y != selection.offset else { return }
        selection = Self.select(offset: y, in: analysis, keeping: selection)
    }

    private func followSelectionInText(_ s: SceneSelection) {
        guard let y = s.offset, let n = textOffsets.firstIndex(of: y) else { return }
        if let t = textSelection, case .selection(let r) = t.indices, r.upperBound <= text.endIndex, line(of: r.lowerBound) == n { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard n < lines.count else { return }
        textSelection = TextSelection(range: lines[n].startIndex..<lines[n].endIndex)
    }

    /// The selection for statement `y`: the current object and function if they reach it.
    static func select(offset y: Int, in a: CTSceneAnalysis?, keeping s: SceneSelection) -> SceneSelection {
        guard let a else { return SceneSelection(object: s.object, function: s.function, offset: y) }
        func reaches(_ o: CTSceneAnalysis.Object, _ f: Int?) -> Bool {
            guard let f else { return false }
            return f == CTSceneGraph.continuation ? o.continuation.contains(y) : o.functions[f].statements.contains(y)
        }
        if let k = s.object, a.objects.indices.contains(k), reaches(a.objects[k], s.function) {
            return SceneSelection(object: k, function: s.function, offset: y)
        }
        for o in a.objects {
            if let f = o.functions.first(where: { $0.alias == nil && !$0.stub && $0.statements.contains(y) }) {
                return SceneSelection(object: o.index, function: f.index, offset: y)
            }
            if o.continuation.contains(y) { return SceneSelection(object: o.index, function: CTSceneGraph.continuation, offset: y) }
        }
        return SceneSelection(object: s.object, function: s.function, offset: y)
    }

    // MARK: Objects

    private func objects(_ a: CTSceneAnalysis) -> some View {
        let treasure = (try? CTMapROM.treasureList(rom, location).records) ?? []
        return List {
            Section("Event objects (\(a.objectCount))") {
                ForEach(a.objects) { o in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("obj \(o.index)").bold()
                            Text(o.kind)
                            if let p = o.placement { Text("at (\(p.column), \(p.row))").foregroundStyle(.secondary) }
                        }
                        ForEach(Array(o.markers.enumerated()), id: \.offset) { _, m in
                            Text(String(format: "$%04X ", m.offset) + m.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { selection = SceneSelection(object: o.index, function: 0, offset: o.markers.first?.offset) }
                    .listRowBackground(selection.object == o.index ? Color.accentColor.opacity(0.15) : Color.clear)
                }
            }
            Section("Treasure (\(treasure.count)) — the field engine's TreasureRom records, not event objects") {
                ForEach(Array(treasure.enumerated()), id: \.offset) { n, t in
                    Text("chest \(n) at (\(t.x), \(t.y)): " + Self.contents(t.contents)).font(.caption)
                }
                Text("Field_CheckTileInFront ($C0:1DF4) opens a chest on the tile in front of the leader; edit chests in Maps.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func contents(_ c: Int) -> String {
        if c & 0x8000 != 0 { return "\((c & 0x7FFF) * 2) gold" }
        if c & 0x4000 != 0 { return "empty" }
        return "item \(c & 0x1FF)"
    }
}

// MARK: - The selected statement

struct SceneStatementInspector: View {
    let analysis: CTSceneAnalysis
    @Binding var selection: SceneSelection
    let edit: ((inout CTSceneDocument) throws -> Void) -> Void
    /// The ROM a message statement's dialogue box preview reads.
    var romPath: String? = nil
    @State private var operands = ""
    @State private var insertOp = "OpAD_WaitRuns"
    @State private var insertOperands = "$10"

    private static let insertable = ["OpAD_WaitRuns", "OpBB_Msg", "Op96_WalkToTile", "OpA0_MoveToTile", "Op8B_PlaceAtTile",
                                     "OpE7_ScrollTo", "OpAA_SetAnimRow", "OpAB_PlayAnimOnce", "OpB7_PlayAnimLoops", "OpA6_Face",
                                     "Op89_SetSpeed", "OpD8_StartBattle", "OpC8_EnterBankC2", "OpEA_PlayMusic"]

    var body: some View {
        if let y = selection.offset, let s = analysis.statement(at: y) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(String(format: "$%04X", y)).monospaced().bold()
                    Text(s.name).monospaced()
                    Text(s.category.rawValue).font(.caption).padding(.horizontal, 4).background(SceneColors.color(s.category).opacity(0.3))
                    if let o = selection.object { Text("obj \(o)").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Remove") { edit { try $0.remove(at: y) }; selection.offset = nil }
                }
                HStack {
                    TextField("operands, e.g. $05 $07", text: $operands).font(.system(.body, design: .monospaced))
                        .onSubmit(applyOperands)
                    Button("Set Operands", action: applyOperands).disabled(s.operands.isEmpty || s.jumpTarget != nil)
                }
                parameters(s)
                HStack {
                    Picker("Insert after", selection: $insertOp) {
                        ForEach(Self.insertable, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 300)
                    TextField("operands", text: $insertOperands).font(.system(.body, design: .monospaced)).frame(width: 110)
                    Button("Insert") {
                        guard let op = CTEventISA.opcodes.firstIndex(where: { $0.name == insertOp }) else { return }
                        let bytes = Self.parse(insertOperands) ?? []
                        edit { try $0.insert(UInt8(op), bytes, after: y) }
                        selection.offset = y + s.length
                    }
                }
            }
            .onAppear { operands = Self.render(s.operands) }
            .onChange(of: selection.offset) { _, _ in
                if let s = selection.offset.flatMap(analysis.statement) { operands = Self.render(s.operands) }
            }
        } else {
            Text("Select a statement in the listing, the graph, the timeline or on the map.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// Named fields for what the handlers prove of an opcode's operands.
    @ViewBuilder private func parameters(_ s: CTSceneAnalysis.Statement) -> some View {
        if s.opcode == 0xD8, s.operands.count == 2 {
            HStack {
                Text(String(format: "Battle_Unk2989 $%02X", s.operands[0])).monospaced()
                ForEach([(0x20, "no reset"), (0x40, "keep music"), (0x80, "Unk80")], id: \.0) { bit, name in
                    Toggle(name, isOn: Binding(get: { s.operands[1] & bit != 0 }, set: { on in
                        let b = on ? s.operands[1] | bit : s.operands[1] & ~bit
                        edit { try $0.setOperands(at: s.offset, [UInt8(s.operands[0]), UInt8(b)]) }
                    })).toggleStyle(.checkbox)
                }
            }.font(.caption)
            Text("Evt_OpD8_StartBattle: FieldBtl_EvtFlags bit 5 FieldBtl_EvtNoReset, bit 6 FieldBtl_EvtKeepMusic, bit 7 FieldBtl_EvtUnk80.")
                .font(.caption2).foregroundStyle(.secondary)
        } else if s.opcode == 0xC8, let arg = s.operands.first {
            let m = CTSceneAnalysis.menu(arg)
            Text(String(format: "BankC2 argument %d → menu mode $%02X", m.bankArgument, m.mode)
                 + (m.mode == 0x0B ? " — the save-slot list" : m.mode == 0x0C ? " — the shop list" : "")
                 + (m.list.map { ", list \($0)" } ?? ""))
                .font(.caption)
        } else if let message = Self.message(s, analysis) {
            DialoguePreviewView(source: .message(table: message.table, index: message.index), romPath: romPath,
                                place: message.place, scale: 1.5)
        }
    }

    /// A message statement's table (the last OpB8_SetMsgPtr before it) and index; OpC1/OpC3 put
    /// the box at the top, OpC2/OpC4 at the bottom (Field_Unk30), OpBB/OpC0 shown at the top.
    static func message(_ s: CTSceneAnalysis.Statement, _ analysis: CTSceneAnalysis) -> (table: Int, index: Int, place: Int)? {
        guard [0xBB, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4].contains(s.opcode), let index = s.operands.first,
              let set = analysis.statements.last(where: { $0.opcode == 0xB8 && $0.offset < s.offset && $0.operands.count == 3 })
        else { return nil }
        let table = set.operands[0] | set.operands[1] << 8 | set.operands[2] << 16
        guard table >> 16 >= 0xC0 else { return nil }
        return (table, index, [0xC2, 0xC4].contains(s.opcode) ? 2 : 1)
    }

    private func applyOperands() {
        guard let y = selection.offset, let bytes = Self.parse(operands) else { return }
        edit { try $0.setOperands(at: y, bytes) }
    }

    static func render(_ b: [Int]) -> String { b.map { String(format: "$%02X", $0) }.joined(separator: " ") }

    static func parse(_ text: String) -> [UInt8]? {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "," })
        let bytes = words.compactMap { w -> UInt8? in
            w.hasPrefix("$") ? UInt8(w.dropFirst(), radix: 16) : UInt8(w)
        }
        return bytes.count == words.count ? bytes : nil
    }
}

enum SceneColors {
    static func color(_ c: CTSceneAnalysis.Category) -> Color {
        switch c {
        case .move: return .blue
        case .camera: return .purple
        case .animation: return .teal
        case .dialogue: return .green
        case .wait: return .gray
        case .call: return .orange
        case .memory: return .brown
        case .battle: return .red
        case .menu: return .pink
        case .sprite: return .mint
        case .sound: return .indigo
        case .warp: return .yellow
        case .control, .screen, .party, .other: return .secondary
        }
    }
}
