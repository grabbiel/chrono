// ItemsPane.swift
import SwiftUI
import ChronoForgeCore

struct ItemsPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?

    var body: some View {
        EntityListView(title: "Items", ids: project.items.keys.sorted(),
                       selection: $selection) { id in
            if let it = project.items[id] {
                EditorHost(entity: it, apply: { store.updateItem($0) }) { $it in
                    Form {
                        TextField("Name", text: $it.name)
                        Picker("Kind", selection: $it.kind) {
                            ForEach(["weapon", "helmet", "armor", "accessory", "consumable"], id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                        StatField("Price", Binding(
                            get: { $it.wrappedValue.price ?? 0 },
                            set: { v in $it.wrappedValue.price = v }))
                        OptionalTextField(label: "Effect", value: $it.effect)
                        if let stats = it.stats, !stats.isEmpty {
                            GroupBox("Stats") {
                                ForEach(stats.keys.sorted(), id: \.self) { k in
                                    HStack {
                                        Text(k).foregroundStyle(.secondary)
                                        TextField("", value: dictBinding($it.stats, k),
                                                  format: .number)
                                            .frame(width: 70)
                                    }
                                }
                            }
                        }
                        ApplyBar(apply: { store.updateItem($it.wrappedValue) })
                    }
                    .padding()
                }
                .id(id)
            }
        }
    }
}
