// CharactersPane.swift
import SwiftUI
import ChronoForgeCore

struct CharactersPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?

    private static var zeroStats: CharacterDef.Stats {
        CharacterDef.Stats(hp: 0, mp: 0, atk: 0, def: 0, mag: 0, spd: 0)
    }

    var body: some View {
        EntityListView(title: "Characters", ids: project.characters.keys.sorted(),
                       selection: $selection) { id in
            if let c = project.characters[id] {
                EditorHost(entity: c, apply: { store.updateCharacter($0) }) { $c in
                    Form {
                        TextField("Name", text: $c.name)
                        TextField("Kind (playable|npc|enemy)", text: $c.kind)
                        OptionalTextField(label: "Sprite", value: $c.sprite)
                        OptionalIntField(label: "Level", value: $c.level, range: 1...99)
                        if c.stats != nil {
                            GroupBox("Stats") {
                                Grid {
                                    GridRow {
                                        StatField("HP", statsBinding($c.stats, \.hp))
                                        StatField("MP", statsBinding($c.stats, \.mp))
                                        StatField("ATK", statsBinding($c.stats, \.atk))
                                    }
                                    GridRow {
                                        StatField("DEF", statsBinding($c.stats, \.def))
                                        StatField("MAG", statsBinding($c.stats, \.mag))
                                        StatField("SPD", statsBinding($c.stats, \.spd))
                                    }
                                }
                            }
                        }
                        ApplyBar(apply: { store.updateCharacter($c.wrappedValue) })
                    }
                    .padding()
                }
                .id(id)
            }
        }
    }
}
