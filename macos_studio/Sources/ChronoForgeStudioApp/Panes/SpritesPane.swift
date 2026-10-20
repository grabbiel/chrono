// SpritesPane.swift — OAM sprite assemblies + indexed PNG sheet preview.
import SwiftUI
import AppKit
import ChronoForgeCore

struct SpritesPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?

    var body: some View {
        EntityListView(title: "Sprites", ids: project.sprites.keys.sorted(),
                       selection: $selection) { id in
            if let s = project.sprites[id] {
                EditorHost(entity: s, apply: { store.updateSprite($0) }) { $s in
                    ScrollView {
                        VStack(alignment: .leading) {
                            sheetPreview(s.sheet)
                            Form {
                                TextField("Sheet", text: $s.sheet)
                                Picker("BPP", selection: $s.bpp) {
                                    Text("4 (16-col)").tag(4)
                                    Text("2 (4-col)").tag(2)
                                }
                                Text("\(s.frames.count) frames, \(s.animations.count) animations")
                                    .foregroundStyle(.secondary)
                                ForEach(Array(s.frames.enumerated()), id: \.offset) { i, f in
                                    Text("frame \(i): \(f.tiles.count) OAM entries"
                                        + (f.large == true ? " (large)" : ""))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                ApplyBar(apply: { store.updateSprite($s.wrappedValue) })
                            }
                        }
                        .padding()
                    }
                }
                .id(id)
            }
        }
    }

    @ViewBuilder
    func sheetPreview(_ sheet: String) -> some View {
        if let url = store.fileURL(sheet), let img = NSImage(contentsOf: url) {
            Image(nsImage: img)
                .interpolation(.none)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxHeight: 260)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            ContentUnavailableView("Sheet PNG missing", systemImage: "photo")
        }
    }
}
