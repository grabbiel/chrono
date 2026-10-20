// TilesetsPane.swift — tile bank + metatiles, rendered via Metal.
import SwiftUI
import ChronoForgeCore

struct TilesetsPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?

    var body: some View {
        EntityListView(title: "Tilesets", ids: project.tilesets.keys.sorted(),
                       selection: $selection) { id in
            if let ts = project.tilesets[id] {
                EditorHost(entity: ts, apply: { store.updateTileset($0) }) { $ts in
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
                                ApplyBar(apply: { store.updateTileset($ts.wrappedValue) })
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
