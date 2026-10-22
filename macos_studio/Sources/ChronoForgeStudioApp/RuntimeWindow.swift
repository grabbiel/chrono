// RuntimeWindow.swift — Module 9's Play window: a ROM location running in
// the embedded runtime (CTFieldRuntime under CTFieldDebugger) on a Metal
// SNESPPUView, with the dialogue box over it, keyboard control, pause and
// step, and the inspector (RuntimeInspectorViews.swift). Opened by "Play" in
// the Maps, Scenes and Story panes, or `--play N` at launch.
import SwiftUI
import AppKit
import ChronoForgeCore
import ChronoForgeMetal

struct RuntimeWindow: View {
    let store: ProjectStore
    @State private var location: Int
    @State private var session: RuntimeSession?
    @State private var problem = ""
    @State private var keyMonitor: Any?
    @State private var tab = LaunchArguments.value("--play-tab") ?? "Objects"

    init(store: ProjectStore, location: Int) {
        self.store = store
        _location = State(initialValue: location)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            controls
            if let session {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topLeading) {
                            FieldPPUView(session: session)
                            if let box = session.box {
                                Image(nsImage: box).interpolation(.none).resizable().allowsHitTesting(false)
                            }
                        }
                        .frame(width: 512, height: 448)
                        .border(Color.secondary.opacity(0.4))
                        Text("Arrows walk · X is A (talk, next) · Z is B (run) · Space plays/pauses · . steps a frame")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(session.status).font(.caption.monospaced()).lineLimit(2)
                    }
                    VStack(alignment: .leading) {
                        Picker("Inspector", selection: $tab) {
                            ForEach(["Objects", "Flags", "Breakpoints", "Changes"], id: \.self) { Text($0) }
                        }.pickerStyle(.segmented).labelsHidden()
                        switch tab {
                        case "Flags": RuntimeFlagsView(session: session)
                        case "Breakpoints": RuntimeBreakpointsView(session: session)
                        case "Changes": RuntimeChangesView(session: session)
                        default: RuntimeObjectsView(session: session)
                        }
                    }
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView("No runtime", systemImage: "play.slash",
                                       description: Text(problem.isEmpty ? "Loading…" : problem))
            }
        }
        .padding()
        .frame(minWidth: 1000, minHeight: 560)
        .navigationTitle(String(format: "Play loc_%03d", session?.location ?? location))
        .onAppear { load(); installKeys() }
        .onDisappear { if let m = keyMonitor { NSEvent.removeMonitor(m) }; keyMonitor = nil }
    }

    private var controls: some View {
        HStack {
            Text("Location").font(.headline)
            TextField("0-\(CTMapROM.locCount - 1)", value: $location, format: .number).frame(width: 60)
            Stepper("", value: $location, in: 0...(CTMapROM.locCount - 1)).labelsHidden()
            Button("Load") { load() }
            Divider().frame(height: 18)
            if let session {
                Button(session.running ? "Pause" : "Play", systemImage: session.running ? "pause.fill" : "play.fill") {
                    session.running.toggle()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button("Step", systemImage: "forward.frame") { session.running = false; session.stepFrame() }
                    .keyboardShortcut(".", modifiers: [])
                Button("Step 10") { session.running = false; for _ in 0..<10 { session.stepFrame() } }
                Button("Restart", systemImage: "arrow.counterclockwise") {
                    do { try session.restart(location: session.location) } catch { problem = "\(error)" }
                }
                Text("frame \(session.field.frameCount)").font(.caption.monospaced()).foregroundStyle(.secondary)
                    .id(session.revision)
            }
            Spacer()
        }
    }

    private func load() {
        do {
            if let session {
                try session.restart(location: location)
            } else {
                let s = try store.runtimeSession(location: location)
                if let frames = LaunchArguments.value("--play-frames").flatMap({ Int($0) }),
                   let script = try? CTFieldInput.parse(LaunchArguments.value("--play-input") ?? "") {
                    for f in 0..<frames {
                        s.held = script.held(at: f)
                        s.stepFrame()
                    }
                    s.held = []
                }
                session = s
            }
            problem = ""
        } catch {
            session = nil
            problem = "\(error)"
        }
    }

    /// Arrows, X (A), Z (B), A/S (Y/X), Return (Start) while the window is key.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard let session, event.window?.title.hasPrefix("Play") == true,
                  !(event.window?.firstResponder is NSTextView) else { return event }
            let map: [UInt16: CTFieldInput] = [123: .left, 124: .right, 125: .down, 126: .up, 7: .a, 6: .b, 0: .y, 1: .x,
                                               36: .start]
            guard let button = map[event.keyCode] else { return event }
            if event.type == .keyDown { session.held.insert(button) } else { session.held.remove(button) }
            return nil
        }
    }
}

/// The Metal view: steps the session once per displayed frame while it runs.
struct FieldPPUView: NSViewRepresentable {
    let session: RuntimeSession

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else { return NSView() }
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? SNESPPUView { configure(view) }
    }

    private func configure(_ view: SNESPPUView) {
        let session = session
        view.picture = session.picture()
        view.tick = { picture, _ in
            MainActor.assumeIsolated {
                if session.running { session.stepFrame() }
                picture = session.picture()
            }
        }
    }
}
