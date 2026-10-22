// StoryPane.swift — dialogue strings, flags, encounters, techs; Module 9's
// story flag registry and era graph (StoryRegistryViews.swift).
import SwiftUI
import ChronoForgeCore
import UniformTypeIdentifiers

struct StoryPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var strings: [String: String] = [:]
    @State private var selectedString: String?
    @State private var importROM = false
    @State private var showROMBuild = false
    @State private var tab = StoryPane.launchTab
    @State private var registry: CTStoryRegistry?
    @State private var graph: CTEraGraph?
    @State private var flagSelection: String? = StoryPane.launchSymbol
    @State private var location: Int?
    @State private var importStory = false

    /// `--select registry|graph|<symbol>` opens that part of the pane at launch.
    private static var launchTab: String {
        switch LaunchArguments.value("--select") {
        case "graph": return "Era Graph"
        case .some(let s) where s == "registry" || s.hasPrefix("flag_") || s.hasPrefix("var_"): return "Flag Registry"
        default: return "Dialogue"
        }
    }
    private static var launchSymbol: String? {
        LaunchArguments.value("--select").flatMap { $0.hasPrefix("flag_") || $0.hasPrefix("var_") ? $0 : nil }
    }

    var body: some View {
        Group {
            switch tab {
            case "Flag Registry":
                if let registry {
                    StoryFlagRegistryView(store: store, registry: Binding(get: { registry }, set: { self.registry = $0 }),
                                          graph: graph, selection: $flagSelection, location: $location)
                } else { storyMissing }
            case "Era Graph":
                if let graph {
                    StoryEraGraphView(store: store, graph: Binding(get: { graph }, set: { self.graph = $0 }),
                                      location: $location, showFlags: { _ in tab = "Flag Registry" })
                } else { storyMissing }
            default: dialogue
            }
        }
        .navigationTitle("Story")
        .toolbar {
            Picker("Section", selection: $tab) {
                ForEach(["Dialogue", "Flag Registry", "Era Graph"], id: \.self) { Text($0) }
            }.pickerStyle(.segmented)
            Button(registry == nil ? "Import Story from ROM…" : "Rescan Story from ROM…") { importStory = true }
        }
        .onAppear { (registry, graph) = store.loadStory() }
        .onChange(of: project.url) { (registry, graph) = store.loadStory() }
        .fileImporter(isPresented: $importStory, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first, let imported = store.importStory(rom: url) {
                (registry, graph) = (imported.registry, imported.graph)
            }
        }
    }

    private var storyMissing: some View {
        ContentUnavailableView("No story registry", systemImage: "flag",
            description: Text("Import Story from ROM scans the event packs of your US 1.0 ROM into story/flags.json and story/graph.json."))
    }

    private var dialogue: some View {
        let keys = project.dialogue.strings.keys.sorted()
        return NavigationSplitView {
            List(selection: $selectedString) {
                Section("Dialogue") {
                    ForEach(keys, id: \.self) { NavigationLink($0, value: $0) }
                }
                Section("Flags (\(project.project.flags.count))") {
                    ForEach(project.project.flags, id: \.symbol) { f in
                        Text("\(f.symbol) — \(f.bank) \(f.addr).\(f.bit)")
                            .font(.system(.caption, design: .monospaced))
                    }
                }
                Section("Techs (\(project.techs.count))") {
                    ForEach(project.techs.keys.sorted(), id: \.self) { id in
                        Text("\(id) — \(project.techs[id]?.name ?? "")")
                    }
                }
                Section("Encounters (\(project.project.encounters.count))") {
                    ForEach(project.project.encounters, id: \.id) { e in
                        Text("\(e.id) rate \(e.rate): \(e.enemies.joined(separator: ", "))")
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(alignment: .leading) {
                if let key = selectedString {
                    Text(key).font(.headline)
                    TextEditor(text: Binding(
                        get: { strings[key] ?? project.dialogue.strings[key] ?? "" },
                        set: { strings[key] = $0 }))
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 160)
                    CTTextInspector(source: strings[key] ?? project.dialogue.strings[key] ?? "",
                                    profile: project.textProfile)
                    HStack {
                        Spacer()
                        Button("Apply") {
                            var all = project.dialogue.strings
                            all[key] = strings[key] ?? all[key]
                            if store.updateDialogue(all) { strings = [:] }
                        }
                    }
                } else {
                    ContentUnavailableView("Story", systemImage: "book")
                }
            }
            .padding()
        }
        .toolbar {
            Button("Build ROM…") { showROMBuild = true }
            Button(project.textProfile == nil ? "Import ROM Text Dictionary…" : "Reimport ROM Text Dictionary…") {
                importROM = true
            }
        }
        .sheet(isPresented: $showROMBuild) { ROMBuildSheet(store: store, project: project) }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { store.importTextROM(url) }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
    }
}


private struct CTTextInspector: View {
    let source: String
    let profile: CTTextProfile?

    private var analysis: Result<CTTextCodec.Analysis, Error>? {
        guard let profile else { return nil }
        return Result { try CTTextCodec(profile: profile).analyzeMessage(source) }
    }
    var body: some View {
        GroupBox("ROM Dialogue") {
            VStack(alignment: .leading, spacing: 8) {
                switch analysis {
                case .none:
                    Text("Import the US 1.0 ROM text dictionary to check characters, controls and compression.")
                        .foregroundStyle(.secondary)
                case .success(let value):
                    HStack {
                        Text("\(value.bytes.count) bytes compiled")
                        Text("\(value.savedBytes) bytes saved").foregroundStyle(.secondary)
                    }.font(.callout)
                    DisclosureGroup("Canonical text and controls") {
                        ScrollView {
                            Text(value.canonical).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxHeight: 110)
                    }
                case .failure(let error):
                    Text(String(describing: error)).foregroundStyle(.red).textSelection(.enabled)
                }
                if profile != nil {
                    Text("Newlines start a line. Use {wait 03}, {page}, {char0}…{char6} and {item}. Old \\{wait} and named-character escapes require explicit conversion.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("ROM export needs every dialogue entry to pass Validate. Apply saves editable source, including drafts with errors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
        }
    }
}


/// The project's `rom.eventPacks` and the .sfc build (CTROMBuilder); `rom.songs` are set in the Music pane.
private struct ROMBuildSheet: View {
    let store: ProjectStore
    let project: CTProject
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row] = []
    @State private var pickBase = false
    @State private var result = ""

    struct Row: Identifiable {
        let id = UUID()
        var entry = 0
        var fromScenes = true
        var scenes = ""
        var listing = ""
    }

    private var spec: Project.ROMBuild? {
        let packs = rows.map { row in
            row.fromScenes
                ? Project.ROMBuild.EventPack(entry: row.entry, scenes: row.scenes.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
                : Project.ROMBuild.EventPack(entry: row.entry, listing: row.listing)
        }
        let songs = project.project.rom?.songs ?? []
        return packs.isEmpty && songs.isEmpty ? nil : Project.ROMBuild(eventPacks: packs, songs: songs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Build .sfc").font(.title2)
            Text("Each row replaces one Evt_PackPtrs entry of the clean US 1.0 ROM: scenes (comma-separated IDs, one per object slot) or a ct-events/1 listing in the project. `chronoforge rom locations` lists which entry each location uses.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                ForEach($rows) { $row in
                    HStack {
                        TextField("entry", value: $row.entry, format: .number).frame(width: 60)
                        Picker("", selection: $row.fromScenes) {
                            Text("Scenes").tag(true)
                            Text("Listing").tag(false)
                        }.frame(width: 110)
                        if row.fromScenes {
                            TextField("scene IDs", text: $row.scenes)
                        } else {
                            TextField("events/entry030.ctevents", text: $row.listing)
                        }
                        Button(role: .destructive) { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }.frame(minHeight: 160)
            let songs = project.project.rom?.songs ?? []
            if !songs.isEmpty {
                Text("Songs (set in Music): " + songs.map { String(format: "$%02X ← %@", $0.song, $0.listing) }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Add Pack") { rows.append(Row()) }
                Spacer()
                Button("Save Settings") { _ = store.updateROMBuild(spec) }
                Button("Build…") {
                    if store.updateROMBuild(spec) { pickBase = true }
                }.disabled(spec == nil).keyboardShortcut(.defaultAction)
            }
            if !result.isEmpty {
                ScrollView {
                    Text(result).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 140)
            }
            HStack { Spacer(); Button("Close") { dismiss() } }
        }
        .padding()
        .frame(minWidth: 620, minHeight: 420)
        .onAppear {
            rows = (project.project.rom?.eventPacks ?? []).map {
                Row(entry: $0.entry, fromScenes: $0.listing == nil,
                    scenes: ($0.scenes ?? []).joined(separator: ", "), listing: $0.listing ?? "")
            }
        }
        .fileImporter(isPresented: $pickBase, allowedContentTypes: [.data], allowsMultipleSelection: false) { picked in
            guard case .success(let urls) = picked, let base = urls.first else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "\(project.project.name).sfc"
            panel.allowedContentTypes = [UTType(filenameExtension: "sfc") ?? .data]
            guard panel.runModal() == .OK, let output = panel.url else { return }
            result = store.buildROM(base: base, output: output) ?? store.statusMessage
        }
    }
}
