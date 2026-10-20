// MapsPane.swift — location header, layers (Metal preview), exits, triggers.
import SwiftUI
import ChronoForgeCore

struct MapsPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?

    var body: some View {
        EntityListView(title: "Maps", ids: project.maps.keys.sorted(),
                       selection: $selection) { id in
            if let m = project.maps[id] {
                EditorHost(entity: m, apply: { store.updateMap($0) }) { $m in
                    ScrollView {
                        VStack(alignment: .leading) {
                            if let ts = project.tilesets[m.tileset] {
                                MapMetalView(project: project, map: m, ts: ts)
                                    .frame(maxWidth: .infinity)
                            } else {
                                ContentUnavailableView("Tileset missing", systemImage: "photo")
                            }
                            Form {
                                TextField("Name", text: $m.name)
                                TextField("Tileset", text: $m.tileset)
                                StatField("Width", $m.width)
                                StatField("Height", $m.height)
                                Text("\(m.layers.count) layers · \(m.exits.count) exits · \(m.triggers.count) triggers")
                                    .foregroundStyle(.secondary)
                                ForEach(Array(m.layers.enumerated()), id: \.offset) { i, l in
                                    Text("BG\(l.bg): \(l.metatiles.count) metatiles")
                                        .font(.system(.caption, design: .monospaced))
                                }
                                ApplyBar(apply: { store.updateMap($m.wrappedValue) })
                            }
                        }
                        .padding()
                    }
                }
                .id(id)
            }
        }
    }
}
