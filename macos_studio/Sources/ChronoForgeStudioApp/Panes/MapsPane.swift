// MapsPane.swift — Module 7, the Multi-Plane Map Editor. A map with location
// data or layers opens in the editor (MapEditorViews.swift); docs/maps.md
// describes the data. The toolbar makes a location the game never loads from
// a map ("New Location from…") and lists maps in the ROM build with a dry-run
// budget ("ROM Build Maps…"); `--map-sheet new-location|rom-list` opens them.
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct MapsPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String? = LaunchArguments.value("--select")   // e.g. --module Maps --select loc_001
    @State private var importROM = false
    @State private var revision = 0          // re-seeds the editor after an import
    @State private var sheet: MapSheet? = LaunchArguments.value("--map-sheet").flatMap(MapSheet.init)
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        EntityListView(title: "Maps", ids: project.maps.keys.sorted(), selection: $selection) { id in
            if let m = project.maps[id] {
                MapHost(store: store, project: project, entity: m)
                    .id("\(id)#\(revision)")
            }
        }
        .toolbar {
            if let loc = selection.flatMap({ project.maps[$0]?.rom?.location }) {
                Button("Play", systemImage: "play.fill") { openWindow(id: "runtime", value: loc) }
                    .help("Run this location in the embedded runtime (Play window)")
            }
            if let id = selection, project.maps[id]?.rom != nil {
                let listed = CTMapList.listed(project).contains(id)
                Button(listed ? "Take out of ROM Build" : "List in ROM Build", systemImage: listed ? "minus.circle" : "plus.circle") {
                    store.setMapsListed([id], listed: !listed)
                }
                .help("project.json rom.maps: the maps a ROM build writes")
                Button("New Location from…", systemImage: "square.on.square") { sheet = .newLocation }
                    .help("Make a location the game never loads from this map, with an entrance on another map")
            }
            Button("ROM Build Maps…", systemImage: "list.bullet.rectangle") { sheet = .romList }
                .help("The maps a ROM build writes, and what a build would leave: free space, chest flags, or the refusal")
            Button(project.maps.values.contains { $0.rom != nil } ? "Reimport Maps from ROM…" : "Import Maps from ROM…") {
                importROM = true
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .newLocation:
                NewLocationSheet(store: store, project: project, source: selection ?? "") { id in
                    if let id { selection = id; revision += 1 }
                    sheet = nil
                }
            case .romList:
                MapBuildSheet(store: store, project: project) { sheet = nil }
            }
        }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importMaps(url); revision += 1 }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
    }
}

/// Edits a copy of one map (seeded at init, so the editor shows at once, also
/// for a selection made at launch); Apply writes it back.
struct MapHost: View {
    let store: ProjectStore
    let project: CTProject
    @State private var map: GameMap

    init(store: ProjectStore, project: CTProject, entity: GameMap) {
        self.store = store; self.project = project
        _map = State(initialValue: entity)
    }

    var body: some View {
        MapEditor(store: store, project: project, map: $map)
    }
}

enum MapSheet: String, Identifiable {
    case newLocation = "new-location", romList = "rom-list"
    var id: String { rawValue }
}

/// A location the game never loads made from a map (CTNewLocation): the number, and optionally an exit on
/// another map leading to it; both can go in rom.maps.
struct NewLocationSheet: View {
    let store: ProjectStore
    let project: CTProject
    let done: (String?) -> Void
    @State private var source: String
    @State private var number: Int
    @State private var withEntrance = true
    @State private var entranceMap: String
    @State private var at = TilePoint(x: 0, y: 0)
    @State private var to = TilePoint(x: 0, y: 0)
    @State private var facing = 0
    @State private var list = true

    init(store: ProjectStore, project: CTProject, source: String, done: @escaping (String?) -> Void) {
        self.store = store; self.project = project; self.done = done
        _source = State(initialValue: source)
        let free = CTNewLocation.unused.filter { project.maps[CTMaps.id($0)]?.rom?.createdFrom == nil }
        _number = State(initialValue: free.first ?? CTNewLocation.unused[0])
        // The entrance defaults to a map with an exit into the source, next to that exit, arriving where it does.
        let into = project.maps.values.sorted { $0.id < $1.id }.lazy.compactMap { m in
            m.exits.first { $0.map == source }.map { (m, $0) }
        }.first
        _entranceMap = State(initialValue: into?.0.id ?? project.maps.keys.sorted().first ?? "")
        if let (m, e) = into {
            let x = min(m.width - 1, e.x + (e.vertical == true ? 0 : (e.span ?? 0) + 1))
            let y = min(m.height - 1, e.y + (e.vertical == true ? (e.span ?? 0) + 1 : 0))
            _at = State(initialValue: TilePoint(x: x, y: y))
            _to = State(initialValue: TilePoint(x: e.toX, y: e.toY))
            _facing = State(initialValue: e.facing ?? 0)
        }
    }

    private var problems: [String] {
        guard let m = project.maps[source], let loc = m.rom?.location else { return ["choose a map imported from the ROM"] }
        var out = CTNewLocation.problems(number: number, from: loc)
        if m.rom?.createdFrom != nil { out.append("\(source) was itself created; choose an imported map") }
        if let old = project.maps[CTMaps.id(number)]?.rom?.createdFrom { out.append("\(CTMaps.id(number)) was already created from \(old)") }
        return out
    }

    var body: some View {
        let ids = project.maps.keys.sorted()
        VStack(alignment: .leading, spacing: 10) {
            Text("New Location").font(.headline)
            Text("Copies the source's map, header, MapProps (a free Map_PropsPtrs slot when built), exits and event pack; " +
                 "its chests get flags of their own.").font(.caption).foregroundStyle(.secondary)
            Form {
                Picker("From", selection: $source) {
                    ForEach(ids.filter { project.maps[$0]?.rom.map { $0.createdFrom == nil } == true }, id: \.self) { Text($0).tag($0) }
                }
                Picker("Number", selection: $number) {
                    ForEach(CTNewLocation.unused, id: \.self) { n in
                        Text("\(n)" + (project.maps[CTMaps.id(n)]?.rom?.createdFrom != nil ? " (created)" : "")).tag(n)
                    }
                }
                Toggle("Entrance on another map", isOn: $withEntrance)
                if withEntrance {
                    Picker("Entrance map", selection: $entranceMap) { ForEach(ids, id: \.self) { Text($0).tag($0) } }
                    StatField("Exit X", $at.x)
                    StatField("Exit Y", $at.y)
                    StatField("Arrive X", $to.x)
                    StatField("Arrive Y", $to.y)
                    StatField("Facing", Binding(get: { facing }, set: { facing = max(0, min(15, $0)) }))
                }
                Toggle("List both in the ROM build", isOn: $list)
            }
            ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let e = withEntrance ? CTNewLocation.Entrance(map: entranceMap, x: at.x, y: at.y, toX: to.x, toY: to.y, facing: facing) : nil
                    if let id = store.createLocation(from: source, number: number, entrance: e, list: list) { done(id) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!problems.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
    }
}

/// project.json rom.maps and a dry-run build of them on the scene ROM.
struct MapBuildSheet: View {
    let store: ProjectStore
    let project: CTProject
    let done: () -> Void
    @State private var budget: CTMapList.Budget?
    @State private var running = false

    var body: some View {
        let listed = CTMapList.listed(project)
        VStack(alignment: .leading, spacing: 10) {
            Text("ROM Build Maps").font(.headline)
            Text(listed.isEmpty ? "No maps are listed in rom.maps." : "\(listed.count) maps in rom.maps")
                .font(.caption).foregroundStyle(.secondary)
            List(listed, id: \.self) { id in
                HStack {
                    Text(id).font(.system(.body, design: .monospaced))
                    if let r = project.maps[id]?.rom {
                        Text(r.createdFrom.map { "location \(r.location), from \($0)" } ?? "location \(r.location)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let f = budget?.flags[id], !f.isEmpty {
                        Text(f.count == 1 ? "flag \(f[0])" : "flags \(f.first!)–\(f.last!)").font(.caption.monospaced())
                    }
                    Button("Remove", systemImage: "minus.circle") { store.setMapsListed([id], listed: false); budget = nil }
                        .labelStyle(.iconOnly).buttonStyle(.borderless)
                }
            }
            .frame(height: 200)
            GroupBox("Build budget") {
                VStack(alignment: .leading, spacing: 4) {
                    if store.sceneROMPath == nil {
                        Text("Choose a ROM in the Scenes or Music pane, or pass --rom.").foregroundStyle(.secondary)
                    } else if running {
                        ProgressView().controlSize(.small)
                    } else if let b = budget {
                        if let r = b.refusal {
                            Label(r, systemImage: "xmark.octagon").foregroundStyle(.red)
                        } else {
                            Text("A build would leave \(b.freeBytesLeft ?? 0) bytes of free space.")
                            if let t = b.treasure {
                                Text("TreasureRom: \(t.records) records, \(t.flagsLeft) of \(CTTreasure.flagCount) flags left, " +
                                     "\(t.placement == "moved" ? "moved to" : t.placement == "grown" ? "grown in place at" : "in place at") \(t.address)" + (t.from.map { " (from \($0))" } ?? "") +
                                     ", \(t.renumbered) chests renumbered")
                                ForEach(t.evicted ?? [], id: \.from) { e in
                                    Text("moves MapProps entry \(e.entries.map(String.init).joined(separator: ", ")) \(e.from) → \(e.to)")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            } else {
                                Text("TreasureRom: unchanged")
                            }
                        }
                    } else {
                        Text("Run a dry build to see the free space and the chests' flags.").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Dry Run") {
                    running = true
                    Task { budget = await store.mapBudget(); running = false }
                }
                .disabled(store.sceneROMPath == nil || running)
                Spacer()
                Button("Done") { done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
        .task { if LaunchArguments.value("--map-sheet") == "rom-list", store.sceneROMPath != nil { running = true; budget = await store.mapBudget(); running = false } }
    }
}
