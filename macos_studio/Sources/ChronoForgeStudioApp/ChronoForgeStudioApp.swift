// ChronoForgeStudioApp — SwiftUI IDE shell (NavigationSplitView, 9 modules).
import SwiftUI

@main
struct ChronoForgeStudioApp: App {
    @State private var store = ProjectStore()

    var body: some Scene {
        WindowGroup("ChronoForge Studio") {
            RootView(store: store)
                .frame(minWidth: 1080, minHeight: 700)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open .ctproj…") { store.requestOpen = true }
                    .keyboardShortcut("o")
            }
        }
        WindowGroup("Play", id: "runtime", for: Int.self) { $location in
            RuntimeWindow(store: store, location: location ?? 0)
        }
        .defaultSize(width: 1180, height: 640)
    }
}

enum StudioModule: String, CaseIterable, Identifiable {
    case characters = "Characters"
    case sprites = "Sprites"
    case tilesets = "Tilesets"
    case items = "Items"
    case sfx = "SFX"
    case music = "Music"
    case maps = "Maps"
    case scenes = "Scenes"
    case story = "Story"
    var id: String { rawValue }
}

/// `--open <project.ctproj>` loads a project at launch and `--module <name>`
/// (e.g. Tilesets) opens that module.
enum LaunchArguments {
    static func value(_ flag: String) -> String? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static var module: StudioModule? {
        value("--module").flatMap { name in StudioModule.allCases.first { $0.rawValue.lowercased() == name.lowercased() } }
    }
}

struct RootView: View {
    @Bindable var store: ProjectStore
    @State private var selection: StudioModule? = LaunchArguments.module ?? .characters
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Project") {
                    Label(store.project?.project.name ?? "No project", systemImage: "gamecontroller")
                        .font(.headline)
                }
                Section("Modules") {
                    ForEach(StudioModule.allCases) { m in
                        NavigationLink(m.rawValue, value: m)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            Group {
                if let proj = store.project {
                    switch selection ?? .characters {
                    case .characters: CharactersPane(store: store, project: proj)
                    case .sprites: SpritesPane(store: store, project: proj)
                    case .tilesets: TilesetsPane(store: store, project: proj)
                    case .items: ItemsPane(store: store, project: proj)
                    case .sfx: SFXPane(store: store, project: proj)
                    case .music: MusicPane(store: store, project: proj)
                    case .maps: MapsPane(store: store, project: proj)
                    case .scenes: ScenesPane(store: store, project: proj)
                    case .story: StoryPane(store: store, project: proj)
                    }
                } else {
                    ContentUnavailableView("Open a .ctproj",
                        systemImage: "folder",
                        description: Text("⌘O to open a ChronoForge project bundle"))
                }
            }
            .toolbar {
                ToolbarItem {
                    Button("Validate") { store.validateNow() }
                }
                ToolbarItem {
                    Text(store.statusMessage)
                        .font(.caption)
                        .foregroundStyle(store.statusIsError ? .red : .secondary)
                }
            }
        }
        .onAppear {
            if store.project == nil, let path = LaunchArguments.value("--open") {
                store.load(url: URL(fileURLWithPath: path))
            }
            if let play = LaunchArguments.value("--play").flatMap({ Int($0) }) { openWindow(id: "runtime", value: play) }
        }
        .fileImporter(isPresented: $store.requestOpen,
                      allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            if case let .success(urls) = result, let url = urls.first {
                store.load(url: url)
            }
        }
        .alert("Issues", isPresented: $store.showIssues) {
            Button("OK") {}
        } message: {
            Text(store.issuesText)
        }
    }
}
