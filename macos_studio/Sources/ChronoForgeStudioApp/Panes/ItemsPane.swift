// ItemsPane.swift — Module 4's Item, Gear & Lore Database: a table per
// category, a form for the selected item, ItemBoosts, and the project's own
// (non-ROM) items (docs/items.md).
import SwiftUI
import UniformTypeIdentifiers
import ChronoForgeCore

struct ItemsPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var importROM = false
    @State private var revision = 0          // re-seeds the editor after an import

    private var database: ItemDatabase {
        ItemDatabase(items: project.items.values.filter { $0.rom != nil }.sorted { $0.rom!.itemId < $1.rom!.itemId },
                     tables: project.itemTables)
    }

    var body: some View {
        Group {
            if !database.items.isEmpty {
                EditorHost(entity: database, apply: { store.updateItemDatabase($0.items, tables: $0.tables) }) { $db in
                    ItemDatabaseEditor(db: $db, store: store, project: project)
                }
                .id(revision)
            } else {
                VStack(spacing: 0) {
                    ContentUnavailableView {
                        Label("No ROM items", systemImage: "shield.lefthalf.filled")
                    } description: {
                        Text("Import the ROM's items to edit weapons, armour, helmets, accessories and consumables.")
                    } actions: {
                        Button("Import Items from ROM…") { importROM = true }
                    }
                    .frame(maxHeight: 220)
                    Divider()
                    ProjectItemsList(store: store, project: project)
                }
            }
        }
        .toolbar {
            Button(database.items.isEmpty ? "Import Items from ROM…" : "Reimport Items from ROM…") { importROM = true }
        }
        .fileImporter(isPresented: $importROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { store.importItems(url); revision += 1 }
            case .failure(let error):
                store.statusMessage = "ROM selection failed: \(error)"; store.statusIsError = true
            }
        }
    }
}

/// The ROM items (by item id) and item_tables.json, edited together.
struct ItemDatabase: Equatable {
    var items: [ItemDef]
    var tables: ItemTablesDef?
}

/// Items without a ROM record (the project's own), edited as plain fields.
struct ProjectItemsList: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?

    var body: some View {
        EntityListView(title: "Project items", ids: project.items.filter { $0.value.rom == nil }.keys.sorted(),
                       selection: $selection) { id in
            if let it = project.items[id] {
                EditorHost(entity: it, apply: { store.updateItem($0) }) { $it in
                    Form {
                        TextField("Name", text: $it.name)
                        Picker("Kind", selection: $it.kind) {
                            ForEach(CTItemROM.categories, id: \.self) { Text($0).tag($0) }
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
                                        TextField("", value: dictBinding($it.stats, k), format: .number)
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
