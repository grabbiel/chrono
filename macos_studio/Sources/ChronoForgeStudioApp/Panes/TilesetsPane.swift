// TilesetsPane.swift — Module 3, the Tileset & Asset Workshop. Imported
// location tilesets open in the workshop (TilesetEditorViews.swift); a plain
// tile bank keeps the original form and Metal preview.
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct TilesetsPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String? = LaunchArguments.value("--select")   // e.g. --module Tilesets --select t12_02
    @State private var importROM = false
    @State private var revision = 0          // re-seeds the editor after an import

    var body: some View {
        EntityListView(title: "Tilesets", ids: project.tilesets.keys.sorted(),
                       selection: $selection) { id in
            if let ts = project.tilesets[id] {
                TilesetHost(store: store, project: project, entity: ts)
                    .id("\(id)#\(revision)")
            }
        }
        .toolbar {
            Button(project.tilesets.values.contains { $0.rom != nil } ? "Reimport Tilesets from ROM…"
                                                                        : "Import Tilesets from ROM…") { importROM = true }
        }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importTilesets(url); revision += 1 }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
    }
}

/// Edits a copy of one tileset (seeded at init, so the editor shows at once,
/// also for a selection made at launch); Apply writes it back.
struct TilesetHost: View {
    let store: ProjectStore
    let project: CTProject
    @State private var ts: Tileset

    init(store: ProjectStore, project: CTProject, entity: Tileset) {
        self.store = store; self.project = project
        _ts = State(initialValue: entity)
    }

    var body: some View {
        switch ts.kind {
        case "palette": PaletteEditor(store: store, project: project, palette: $ts)
        case "bg12", "bg3": TilesetEditor(store: store, project: project, tileset: $ts)
        default: PlainTilesetForm(store: store, project: project, ts: $ts)
        }
    }
}

/// A tile bank without location data: sheet or blob, depth and metatiles.
struct PlainTilesetForm: View {
    let store: ProjectStore
    let project: CTProject
    @Binding var ts: Tileset

    var body: some View {
        ScrollView {
            VStack(alignment: .leading) {
                TilesetMetalView(project: project, tileset: ts)
                    .frame(maxWidth: .infinity)
                Form {
                    OptionalTextField(label: "Sheet", value: $ts.sheet)
                    OptionalTextField(label: "Blob", value: $ts.blob)
                    Picker("BPP", selection: $ts.bpp) {
                        Text("4").tag(4); Text("2").tag(2)
                    }
                    StatField("Tile count", $ts.tileCount)
                    Text("\(ts.metatiles.count) metatiles · \(ts.collision.count) collision props")
                        .foregroundStyle(.secondary)
                    if let mt = ts.metatiles.first {
                        GroupBox("Metatile 0") {
                            ForEach(Array(mt.chips.enumerated()), id: \.offset) { i, chip in
                                Text("chip \(i): tile \(chip.tile) pal \(chip.pal)"
                                    + (chip.hflip ? " H" : "") + (chip.vflip ? " V" : "")
                                    + (chip.priority ? " P" : ""))
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                    }
                    ApplyBar(apply: { store.updateTileset(ts) })
                }
            }
            .padding()
        }
    }
}
