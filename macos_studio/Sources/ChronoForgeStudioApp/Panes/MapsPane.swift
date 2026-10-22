// MapsPane.swift — Module 7, the Multi-Plane Map Editor. A map with location
// data or layers opens in the editor (MapEditorViews.swift); docs/maps.md
// describes the data.
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct MapsPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String? = LaunchArguments.value("--select")   // e.g. --module Maps --select loc_001
    @State private var importROM = false
    @State private var revision = 0          // re-seeds the editor after an import

    var body: some View {
        EntityListView(title: "Maps", ids: project.maps.keys.sorted(), selection: $selection) { id in
            if let m = project.maps[id] {
                MapHost(store: store, project: project, entity: m)
                    .id("\(id)#\(revision)")
            }
        }
        .toolbar {
            Button(project.maps.values.contains { $0.rom != nil } ? "Reimport Maps from ROM…" : "Import Maps from ROM…") {
                importROM = true
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
