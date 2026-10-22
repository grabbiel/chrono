// SpritesPane.swift — Sprite & Animation Studio: sprites, their sheets and
// animations, edited and previewed on the SNES PPU (SpriteEditorViews.swift).
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct SpritesPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?
    @State private var importROM = false
    @State private var revision = 0          // re-seeds the editor after an import

    var body: some View {
        EntityListView(title: "Sprites", ids: project.sprites.keys.sorted(),
                       selection: $selection) { id in
            if let s = project.sprites[id] {
                EditorHost(entity: s, apply: { store.updateSprite($0) }) { $s in
                    SpriteEditor(store: store, sprite: $s)
                }
                .id("\(id)#\(revision)")
            }
        }
        .toolbar {
            Button(project.sprites.values.contains { $0.rom != nil } ? "Reimport Sprites from ROM…"
                                                                       : "Import Sprites from ROM…") { importROM = true }
        }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importSprites(url); revision += 1 }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
    }
}
