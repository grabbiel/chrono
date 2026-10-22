import SwiftUI
import ChronoForgeCore

struct SceneDraft {
    var source: String
    var layout: [NodeMeta]
}

struct ScenesPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?
    @State private var newID = ""
    @State private var adding = false
    /// `--select loc_NNN` at launch opens that ROM location.
    @State private var mode = LaunchArguments.value("--select")?.hasPrefix("loc_") == true ? "rom" : "project"

    private var launchLocation: Int? {
        LaunchArguments.value("--select").flatMap { $0.hasPrefix("loc_") ? Int($0.dropFirst(4)) : nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Scenes", selection: $mode) {
                Text("Project Scenes").tag("project")
                Text("ROM Locations").tag("rom")
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360).padding(.top, 8)
            if mode == "rom" {
                LocationScenesView(store: store, project: project, initial: launchLocation)
            } else {
                projectScenes
            }
        }
    }

    private var projectScenes: some View {
        EntityListView(title: "Scenes", ids: project.scenes.keys.sorted(), selection: $selection) { id in
            if let doc = project.scenes[id] {
                SceneEditor(store: store, project: project, document: doc).id(project.url.path + "/" + id)
            }
        }
        .toolbar {
            Button("New Scene", systemImage: "plus") { newID = ""; adding = true }
        }
        .alert("New Scene", isPresented: $adding) {
            TextField("Scene ID", text: $newID)
            Button("Create") {
                let doc = SceneDoc(id: newID, scene: EventScene(object: 0,
                    funcs: [EventFunc(index: 0, stmts: [.nop])]))
                if store.updateScene(doc) { selection = newID }
            }
            .disabled(newID.isEmpty || newID.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) == nil
                      || project.scenes[newID] != nil)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use a unique ID containing letters, numbers, underscores or hyphens.")
        }
    }
}

private struct SceneEditor: View {
    let store: ProjectStore
    let project: CTProject
    let document: SceneDoc
    @State private var source: String
    @State private var parsed: EventScene?
    @State private var layout: [NodeMeta]
    @State private var diagnostic = ""
    @State private var tab = "Graph"
    @State private var entry = 0
    @State private var flags: Set<String> = []
    @State private var preview: EventPreview.Result?
    @State private var objectsPreview: EventScheduler.Result?
    @State private var allObjects = false
    @State private var partySlots = ""
    @State private var savedSource: String
    @State private var savedLayout: [NodeMeta]

    init(store: ProjectStore, project: CTProject, document: SceneDoc) {
        self.store = store; self.project = project; self.document = document
        let text = EventDSL.format(document.scene)
        let draft = store.sceneDrafts[document.id]
        _source = State(initialValue: draft?.source ?? text)
        _savedSource = State(initialValue: text)
        _parsed = State(initialValue: document.scene)
        _layout = State(initialValue: draft?.layout ?? document.scene.layout)
        _savedLayout = State(initialValue: document.scene.layout)
        _entry = State(initialValue: document.scene.funcs.first?.index ?? 0)
    }

    private var referenceIssues: [String] {
        guard let parsed else { return [] }
        var scenes = project.scenes.mapValues(\.scene)
        scenes[document.id] = parsed
        return EventReferences.issues(in: parsed, flags: Set(project.project.flags.map(\.symbol)),
                                      strings: Set(project.dialogue.strings.keys), maps: Set(project.maps.keys),
                                      scenes: scenes)
    }
    private var compiledSize: Int {
        guard let parsed else { return 0 }
        return (try? EventBytecode.compile(parsed.funcs).count) ?? 0
    }
    private var dirty: Bool { source != savedSource || layout != savedLayout }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(document.id).font(.title2)
                if dirty { Text("Unsaved changes").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Revert") {
                    source = savedSource; layout = savedLayout; parse()
                }.disabled(!dirty)
                Button("Format") { if let parsed { source = EventDSL.format(parsed) } }.disabled(parsed == nil)
                Button("Apply & Save", action: apply)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(parsed == nil || !referenceIssues.isEmpty || !dirty)
            }
            HSplitView {
                VStack(alignment: .leading) {
                    Text("Scene Script").font(.headline)
                    TextEditor(text: $source)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Scene script")
                    Text("obj 0 { func 0 { text greeting wait 60 } }")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }.frame(minWidth: 280)
                VStack {
                    Picker("View", selection: $tab) {
                        Text("Function Graph").tag("Graph")
                        Text("Execution Timeline").tag("Timeline")
                        Text("CT Bytecode").tag("CT")
                    }.pickerStyle(.segmented)
                    if let parsed {
                        if tab == "Graph" {
                            SceneFunctionGraph(scene: parsed, layout: $layout)
                        } else if tab == "CT" { ctBytecode(parsed) } else { timeline(parsed) }
                    } else {
                        ContentUnavailableView("Fix the script to preview", systemImage: "exclamationmark.triangle")
                    }
                }.frame(minWidth: 300)
            }
            if !diagnostic.isEmpty {
                Text(diagnostic).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if !referenceIssues.isEmpty {
                ScrollView {
                    Text(referenceIssues.joined(separator: "\n")).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                }.frame(maxHeight: 85)
            } else {
                Text("\(parsed?.funcs.count ?? 0) functions · \(compiledSize) compiled bytes")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear { parse() }
        .onChange(of: source) { parse(); rememberDraft() }
        .onChange(of: layout) { rememberDraft() }
        .onDisappear { rememberDraft() }
    }

    private func rememberDraft() {
        // Keep drafts when changing scenes or navigating to another Studio pane.
        guard store.project?.url == project.url else { return }
        if dirty { store.sceneDrafts[document.id] = SceneDraft(source: source, layout: layout) }
        else { store.sceneDrafts.removeValue(forKey: document.id) }
    }

    private func parse() {
        preview = nil
        objectsPreview = nil
        do {
            parsed = try EventDSL.parse(source)
            diagnostic = ""
            if !(parsed?.funcs.contains { $0.index == entry } ?? false) { entry = parsed?.funcs.first?.index ?? 0 }
        } catch { parsed = nil; diagnostic = String(describing: error) }
    }

    private func apply() {
        guard var scene = parsed, referenceIssues.isEmpty else { return }
        let validIDs = Set(scene.funcs.map(\.index))
        scene.layout = layout.filter { validIDs.contains($0.nodeID) }
        if store.updateScene(SceneDoc(id: document.id, scene: scene)) {
            source = EventDSL.format(scene)
            savedSource = source; layout = scene.layout; savedLayout = layout
            diagnostic = ""
        } else { diagnostic = store.statusMessage }
    }

    /// This scene alone lowered to a Chrono Trigger event pack (docs/event_bytecode.md).
    @ViewBuilder private func ctBytecode(_ scene: EventScene) -> some View {
        let result = Result {
            try CTEventLowering.lower(scenes: [scene], flag: CTEventLowering.flagResolver(project.project.flags))
        }
        VStack(alignment: .leading, spacing: 6) {
            switch result {
            case .success(let out):
                Text("\(out.bytes.count) bytes · \(out.messages.count) messages · \(out.relocations.count) relocation\(out.relocations.count == 1 ? "" : "s")")
                    .font(.callout)
                ScrollView {
                    Text(out.listing).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            case .failure(let error):
                Text(String(describing: error)).foregroundStyle(.red).textSelection(.enabled)
                Spacer()
            }
            Text("Event pack for this scene alone. Its message pointer stays unrelocated until a ROM build places the message table.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func timeline(_ scene: EventScene) -> some View {
        VStack(alignment: .leading) {
            HStack {
                Picker("Entry", selection: $entry) {
                    ForEach(scene.funcs, id: \.index) { Text("func \($0.index)").tag($0.index) }
                }
                Toggle("All scenes as objects", isOn: $allObjects).toggleStyle(.checkbox)
                if allObjects {
                    TextField("party slots, e.g. 1,2,3", text: $partySlots).frame(width: 150)
                }
                Button("Run Preview") {
                    preview = nil
                    objectsPreview = nil
                    do {
                        if allObjects {
                            var scenes = project.scenes.mapValues(\.scene)
                            scenes[document.id] = scene
                            let slots = try EventScheduler.parsePartySlots(partySlots)
                            objectsPreview = try EventScheduler.run(scenes: scenes, entryScene: document.id, entry: entry, flags: flags,
                                                                    dialogue: project.dialogue.strings,
                                                                    party: slots)
                            preview = nil
                        } else {
                            preview = try EventPreview.run(scene, entry: entry, flags: flags, dialogue: project.dialogue.strings)
                            objectsPreview = nil
                        }
                        diagnostic = ""
                    } catch { diagnostic = String(describing: error) }
                }.disabled(scene.funcs.isEmpty || !referenceIssues.isEmpty)
            }
            if !project.project.flags.isEmpty {
                DisclosureGroup("Initial flags (\(flags.count) set)") {
                    ScrollView {
                        ForEach(project.project.flags, id: \.symbol) { flag in
                            Toggle(flag.symbol, isOn: Binding(
                                get: { flags.contains(flag.symbol) },
                                set: { if $0 { flags.insert(flag.symbol) } else { flags.remove(flag.symbol) }; preview = nil; objectsPreview = nil }))
                        }
                    }.frame(maxHeight: 100)
                }
            }
            Text(allObjects
                 ? "Logical frames: each scene is an object, 5 statements per frame, CT call levels (start preempts or queues, retry and wait block). Dialogue adds no delay; map calls stop the preview."
                 : "Logical frames. Dialogue adds no delay; map calls stop the preview; other objects are not simulated.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let run = objectsPreview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(run.entries) { row in
                            HStack(alignment: .top) {
                                Text("f\(row.frame)").monospacedDigit().frame(width: 55, alignment: .trailing)
                                Text("\(row.scene) (obj \(row.object))").font(.caption.bold()).frame(width: 120, alignment: .leading)
                                VStack(alignment: .leading) {
                                    Text("L\(row.level) · func \(row.function) · \(row.action)").font(.system(.caption, design: .monospaced))
                                    if !row.detail.isEmpty { Text(row.detail).font(.callout) }
                                }
                            }
                            Divider()
                        }
                    }
                }
                Text("\(run.elapsedFrames) frames · \(run.stopReason)").font(.caption)
                Text(run.objects.map { "\($0.scene): L\($0.level) \($0.status)" }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                Text("Final flags: \(run.flags.isEmpty ? "none" : run.flags.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let preview {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(preview.entries) { row in
                            HStack(alignment: .top) {
                                Text("f\(row.frame)").monospacedDigit().frame(width: 55, alignment: .trailing)
                                VStack(alignment: .leading) {
                                    Text("func \(row.function) · \(row.action)").font(.system(.caption, design: .monospaced))
                                    if !row.detail.isEmpty { Text(row.detail).font(.callout) }
                                }
                            }
                            Divider()
                        }
                    }
                }
                Text("\(preview.elapsedFrames) frames · \(preview.stopReason)").font(.caption)
                Text("Final flags: \(preview.flags.isEmpty ? "none" : preview.flags.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.secondary)
            } else { Spacer(); Text("Run the script to inspect branches, dialogue and waits.").foregroundStyle(.secondary); Spacer() }
        }.onChange(of: entry) { preview = nil; objectsPreview = nil }
            .onChange(of: allObjects) { preview = nil; objectsPreview = nil }
            .onChange(of: partySlots) { preview = nil; objectsPreview = nil }
    }
}

/// Function IDs are graph node IDs. Branches are shown inside each function;
/// arrows represent local jumps, never guessed cross-map connections.
private struct SceneFunctionGraph: View {
    let scene: EventScene
    @Binding var layout: [NodeMeta]
    private func position(_ id: Int) -> CGPoint {
        if let node = layout.first(where: { $0.nodeID == id }) {
            return CGPoint(x: max(0, min(4000, node.x)), y: max(0, min(4000, node.y)))
        }
        let order = scene.funcs.firstIndex(where: { $0.index == id }) ?? 0
        return CGPoint(x: 30 + (order % 2) * 310, y: 30 + (order / 2) * 240)
    }
    private func targets(_ body: [EventStmt]) -> [Int] {
        body.flatMap { stmt -> [Int] in
            switch stmt {
            case .jump(let id): return [id]
            case .ifFlag(_, let t, let e): return targets(t) + targets(e)
            default: return []
            }
        }
    }
    var body: some View {
        HStack {
            Text("Local jump connections").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Arrange") {
                layout = scene.funcs.enumerated().map { index, function in
                    NodeMeta(nodeID: function.index, x: 30 + (index % 2) * 310, y: 30 + (index / 2) * 240)
                }
            }
        }
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    for f in scene.funcs {
                        for target in Set(targets(f.stmts)).sorted() {
                            let a = position(f.index), b = position(target)
                            var path = Path()
                            let start = CGPoint(x: a.x + 260, y: a.y + 32)
                            let end = CGPoint(x: b.x, y: b.y + 32)
                            path.move(to: start)
                            path.addCurve(to: end, control1: CGPoint(x: start.x + 45, y: start.y),
                                          control2: CGPoint(x: end.x - 45, y: end.y))
                            path.move(to: CGPoint(x: end.x - 8, y: end.y - 5)); path.addLine(to: end)
                            path.addLine(to: CGPoint(x: end.x - 8, y: end.y + 5))
                            context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                        }
                    }
                }
                ForEach(scene.funcs, id: \.index) { function in
                    FunctionCard(function: function, origin: position(function.index)) { point in
                        layout.removeAll { $0.nodeID == function.index }
                        layout.append(NodeMeta(nodeID: function.index, x: Int(point.x), y: Int(point.y)))
                        layout.sort { $0.nodeID < $1.nodeID }
                    }
                }
            }
            .frame(width: max(650, (scene.funcs.map { position($0.index).x }.max() ?? 0) + 320),
                   height: max(500, (scene.funcs.map { position($0.index).y }.max() ?? 0) + 260))
        }
        Text("Drag function headers to arrange. Edit statements in the script.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

private struct FunctionCard: View {
    let function: EventFunc
    let origin: CGPoint
    let moved: (CGPoint) -> Void
    @GestureState private var translation = CGSize.zero
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("func \(function.index)")
                .font(.headline).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.tint.opacity(0.15))
                .gesture(DragGesture().updating($translation) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        moved(CGPoint(x: max(0, min(4000, origin.x + value.translation.width)),
                                      y: max(0, min(4000, origin.y + value.translation.height))))
                    })
            ScrollView {
                Text(EventDSL.format(EventScene(object: 0, funcs: [function]))
                    .split(separator: "\n").dropFirst(2).dropLast(2).joined(separator: "\n"))
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }.frame(height: 150)
        }
        .frame(width: 260)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.secondary.opacity(0.5)))
        .offset(x: origin.x + translation.width, y: origin.y + translation.height)
    }
}
