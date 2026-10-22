// SpritesPane.swift — Sprite & Animation Studio: sprites, their sheets and
// animations, edited and previewed on the SNES PPU (SpriteEditorViews.swift).
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct SpritesPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String? = LaunchArguments.value("--select")   // e.g. --module Sprites --select enemy_059
    @State private var importROM = false
    @State private var revision = 0          // re-seeds the editor after an import
    @State private var family = LaunchArguments.value("--family").flatMap { Family(rawValue: $0) } ?? .all   // --family Enemy

    /// The sprite list's filter by ROM family.
    enum Family: String, CaseIterable, Identifiable {
        case all = "All", pc = "PC", enemy = "Enemy", other = "Other"
        var id: String { rawValue }
        func keeps(_ s: SpriteDef) -> Bool {
            switch self {
            case .all: return true
            case .pc: return s.rom?.family == CTSpritePatch.family
            case .enemy: return s.rom?.family == CTEnemySpritePatch.family
            case .other: return s.rom == nil
            }
        }
    }

    private var ids: [String] { project.sprites.filter { family.keeps($0.value) }.keys.sorted() }

    var body: some View {
        EntityListView(title: "Sprites", ids: ids, selection: $selection) { id in
            if let s = project.sprites[id] {
                SpriteHost(entity: s) { $s in SpriteEditor(store: store, sprite: $s) }
                .id("\(id)#\(revision)")
            }
        }
        .toolbar {
            Picker("Family", selection: $family) {
                ForEach(Family.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("Show all sprites, the playable characters', the enemies' or the project's own")
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

/// EditorHost's working copy, seeded before the first draw: EditorHost seeds it in
/// `onAppear` on an empty Group, which never appears, so its detail stayed blank.
private struct SpriteHost<Content: View>: View {
    @ViewBuilder let content: (Binding<SpriteDef>) -> Content
    @State private var copy: SpriteDef

    init(entity: SpriteDef, @ViewBuilder content: @escaping (Binding<SpriteDef>) -> Content) {
        self.content = content
        _copy = State(initialValue: entity)
    }

    var body: some View { content($copy) }
}
