// SceneRunTimelineViews.swift — Module 8's timeline as the game times it:
// the location run headless in CTEventVM/CTFieldRuntime (CTSceneRun), one
// lane per object, each instruction a bar from the frame its handler first ran
// to the frame it let the object go on. Story flags set before the run choose
// the branches; conditions show whether they jumped; an unmodelled opcode
// ends its lane with the VM's reason; battles name their enemies. A playhead
// scrubs and plays the run, and the map canvas follows it.
import SwiftUI
import ChronoForgeCore

struct SceneRunTimelineView: View {
    let store: ProjectStore
    let rom: [UInt8]
    let location: Int
    let document: CTSceneDocument
    let analysis: CTSceneAnalysis
    @Binding var selection: SceneSelection
    @Binding var run: CTSceneRun.Result?
    @Binding var playhead: Int

    @State private var frames = 600
    @State private var input = ""
    @State private var trigger = "none"
    @State private var triggerFrame = 0
    @State private var flagValues: [String: Int] = [:]
    @State private var extraFlags = ""
    @State private var flagFilter = ""
    @State private var showFlags = false
    @State private var registry: CTStoryRegistry?
    @State private var scale: CGFloat = 2
    @State private var playing = false
    @State private var problem = ""

    private static let laneH: CGFloat = 24, labelW: CGFloat = 70, rulerH: CGFloat = 18

    private var triggers: [(tag: String, label: String)] {
        [("none", "Location load only")] + analysis.objects.flatMap { o in
            o.functions.filter { [1, 2].contains($0.index) && $0.inScripts && !$0.stub }.map {
                ("\(o.index).\($0.index)", "obj \(o.index) func \($0.index) (\($0.role))")
            }
        }
    }

    /// The registry's story flags this location reads or writes (all of them when filtered by name).
    private var flagEntries: [CTStoryRegistry.Entry] {
        guard let registry else { return [] }
        let q = flagFilter.lowercased()
        if !q.isEmpty {
            return registry.entries.filter { ($0.name ?? "").lowercased().contains(q) || $0.symbol.lowercased().contains(q) }.prefix(60).map { $0 }
        }
        return registry.entries.filter { $0.locations.contains(location) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            controls
            flagPanel
            if let run {
                summary(run)
                lanes(run)
                detail(run)
            } else {
                Spacer()
                Text(problem.isEmpty ? "Run the location to see what each object does, frame by frame." : problem)
                    .foregroundStyle(problem.isEmpty ? Color.secondary : Color.red)
                Spacer()
            }
        }
        .onAppear {
            registry = store.loadStory().registry
            if run == nil { start() }
        }
        .task(id: playing) {
            while playing, let r = run {
                try? await Task.sleep(nanoseconds: 16_666_667)
                if playhead + 1 >= r.frames { playing = false; break }
                playhead += 1
            }
        }
    }

    private var controls: some View {
        HStack {
            Picker("Start", selection: $trigger) {
                ForEach(triggers, id: \.tag) { Text($0.label).tag($0.tag) }
            }.frame(maxWidth: 260)
            Stepper("at f\(triggerFrame)", value: $triggerFrame, in: 0...max(0, frames - 1), step: 10).disabled(trigger == "none")
            Stepper("\(frames) frames", value: $frames, in: 60...20_000, step: 60)
            TextField("input, e.g. 0-19 up; 20 a", text: $input).frame(width: 170)
                .help("FROM[-TO] BUTTON[+BUTTON] entries separated by ';' (A pages messages)")
            Button("Run", action: start).keyboardShortcut("r", modifiers: [.command, .shift])
        }
        .font(.caption)
    }

    private var flagPanel: some View {
        DisclosureGroup(isExpanded: $showFlags) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    TextField("filter by name (default: this location's flags)", text: $flagFilter).frame(maxWidth: 260)
                    TextField("more: NAME=1; 7F:0010.3=1; $7F0123=$12", text: $extraFlags).frame(maxWidth: 300)
                    Button("Clear") { flagValues = [:]; extraFlags = "" }
                }
                if registry == nil {
                    Text("No story registry: Story → Import Story from ROM names the flags. Addresses work without it.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), alignment: .leading)], alignment: .leading, spacing: 2) {
                        ForEach(flagEntries) { e in flagRow(e) }
                    }
                }.frame(maxHeight: 120)
            }
            .font(.caption)
        } label: {
            Text("Story flags before the run" + (flagValues.isEmpty ? "" : " (\(flagValues.count) set)")).font(.caption.bold())
        }
    }

    @ViewBuilder private func flagRow(_ e: CTStoryRegistry.Entry) -> some View {
        let label = e.name ?? e.symbol
        HStack(spacing: 4) {
            if e.bit != nil {
                Toggle(isOn: Binding(get: { (flagValues[e.symbol] ?? 0) != 0 }, set: { flagValues[e.symbol] = $0 ? 1 : 0 })) {
                    Text(label).lineLimit(1)
                }.toggleStyle(.checkbox)
            } else {
                Text(label).lineLimit(1)
                TextField("", value: Binding(get: { flagValues[e.symbol] ?? 0 }, set: { flagValues[e.symbol] = min(255, max(0, $0)) }),
                          format: .number).frame(width: 40)
            }
            Text(e.addr + (e.bit.map { ".\($0)" } ?? "")).foregroundStyle(.secondary).monospaced()
        }
        .help(e.notes ?? e.symbol)
    }

    private func settings() throws -> [CTSceneRun.FlagSetting] {
        var out: [CTSceneRun.FlagSetting] = []
        for (symbol, v) in flagValues.sorted(by: { $0.key < $1.key }) {
            out.append(try CTSceneRun.flag("\(symbol)=\(v)", registry: registry))
        }
        for item in extraFlags.split(separator: ";") where !item.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append(try CTSceneRun.flag(String(item), registry: registry))
        }
        return out
    }

    private func start() {
        playing = false
        do {
            var o = CTSceneRun.Options()
            o.frames = frames
            o.pack = try document.pack()
            o.flags = try settings()
            if !input.isEmpty { o.input = try CTFieldInput.parse(input) }
            if trigger != "none" {
                let p = trigger.split(separator: ".").compactMap { Int($0) }
                o.trigger = .init(object: p[0], function: p[1], frame: triggerFrame)
            }
            run = try CTSceneRun.run(rom: rom, location: location, options: o)
            playhead = min(playhead, max(0, (run?.frames ?? 1) - 1))
            problem = ""
        } catch { run = nil; problem = "\(error)" }
    }

    // MARK: Lanes

    private func summary(_ r: CTSceneRun.Result) -> some View {
        HStack(spacing: 8) {
            Button(playing ? "Pause" : "Play") { playing.toggle() }
            Button("|◀") { playing = false; playhead = 0 }
            Slider(value: Binding(get: { Double(playhead) }, set: { playhead = Int($0) }), in: 0...Double(max(1, r.frames - 1)))
                .frame(maxWidth: 260)
            Text("f\(playhead)").monospacedDigit().frame(width: 52, alignment: .leading)
            Text("\(r.frames) frames · \(r.steps) handler runs · \(r.branches.count) conditions · \(r.battles.count) battles"
                 + (r.error.map { " · stopped: \($0)" } ?? ""))
                .foregroundStyle(r.error == nil ? Color.secondary : Color.red).lineLimit(1)
            Spacer()
            Text("Zoom")
            Slider(value: $scale, in: 0.25...12).frame(width: 110)
        }
        .font(.caption)
    }

    private func x(_ frame: Int) -> CGFloat { Self.labelW + CGFloat(frame + 1) * scale }

    private func lanes(_ r: CTSceneRun.Result) -> some View {
        let width = x(r.frames + 20)
        let height = Self.rulerH + CGFloat(r.lanes.count) * Self.laneH + 8
        return ScrollView([.horizontal, .vertical]) {
            Canvas { ctx, size in draw(r, ctx, size) }
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    if v.startLocation.y < Self.rulerH { playhead = frame(at: v.location.x, r) }
                }.onEnded { v in
                    if v.startLocation.y >= Self.rulerH, abs(v.translation.width) < 3 { pick(r, at: v.location) }
                })
        }
        .frame(minHeight: 160, maxHeight: .infinity)
    }

    private func frame(at px: CGFloat, _ r: CTSceneRun.Result) -> Int {
        min(max(0, Int((px - Self.labelW) / scale) - 1), max(0, r.frames - 1))
    }

    private func draw(_ r: CTSceneRun.Result, _ ctx: GraphicsContext, _ size: CGSize) {
        // Ruler: a tick every 10 frames, a label every 60 (one second); "load" before frame 0.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: Self.rulerH)), with: .color(.secondary.opacity(0.08)))
        ctx.draw(Text("load").font(.system(size: 8)), at: CGPoint(x: x(-1) - 12, y: 8))
        let step = scale < 1 ? 60 : 10
        var f = 0
        while x(f) < size.width {
            let major = f % 60 == 0
            ctx.stroke(Path { $0.move(to: CGPoint(x: x(f), y: major ? 2 : 10)); $0.addLine(to: CGPoint(x: x(f), y: major ? size.height : Self.rulerH)) },
                       with: .color(.secondary.opacity(major ? 0.18 : 0.3)))
            if major { ctx.draw(Text("f\(f)").font(.system(size: 8)), at: CGPoint(x: x(f) + 10, y: 7)) }
            f += step
        }
        for (row, lane) in r.lanes.enumerated() {
            let y = Self.rulerH + CGFloat(row) * Self.laneH
            let hot = selection.object == lane.object
            if hot { ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.laneH)), with: .color(.accentColor.opacity(0.08))) }
            let kind = analysis.objects.indices.contains(lane.object) ? analysis.objects[lane.object].kind : ""
            ctx.draw(Text("obj \(lane.object)").font(.caption2.bold()), at: CGPoint(x: 22, y: y + 8))
            ctx.draw(Text(kind).font(.system(size: 7)).foregroundColor(.secondary), at: CGPoint(x: 30, y: y + 17))
            for b in lane.bars {
                let x0 = x(b.start)
                let x1 = b.end.map { x($0) } ?? x(r.frames)
                let color = SceneColors.color(b.category)
                let selected = hot && selection.offset == b.offset
                let rect = x1 - x0 >= 1
                    ? CGRect(x: x0, y: y + 6, width: max(2, x1 - x0), height: Self.laneH - 12)
                    : CGRect(x: x0, y: y + 3, width: 1.5, height: Self.laneH - 6)
                ctx.fill(Path(rect), with: .color(color.opacity(selected ? 1 : b.end == nil ? 0.45 : 0.75)))
                if selected { ctx.stroke(Path(rect.insetBy(dx: -1.5, dy: -1.5)), with: .color(.primary), lineWidth: 1.5) }
                if let j = b.jumped {                                   // branch marker: ▼ jumped, ▽ went on
                    var t = Path()
                    t.move(to: CGPoint(x: x0 - 3, y: y + 1)); t.addLine(to: CGPoint(x: x0 + 3, y: y + 1)); t.addLine(to: CGPoint(x: x0, y: y + 6))
                    t.closeSubpath()
                    if j { ctx.fill(t, with: .color(.orange)) } else { ctx.stroke(t, with: .color(.secondary), lineWidth: 0.8) }
                }
            }
            if let why = lane.stopped, let at = lane.stoppedAt {
                let sx = x(at) + 2
                ctx.stroke(Path { $0.move(to: CGPoint(x: sx, y: y + 5)); $0.addLine(to: CGPoint(x: sx + 8, y: y + Self.laneH - 5))
                    $0.move(to: CGPoint(x: sx + 8, y: y + 5)); $0.addLine(to: CGPoint(x: sx, y: y + Self.laneH - 5)) },
                           with: .color(.red), lineWidth: 2)
                ctx.draw(Text(why).font(.system(size: 8)).foregroundColor(.red), at: CGPoint(x: sx + 12, y: y + Self.laneH / 2), anchor: .leading)
            }
            for b in r.battles where b.object == lane.object {
                let bx = x(b.frame)
                ctx.fill(Path { $0.move(to: CGPoint(x: bx, y: y + 2)); $0.addLine(to: CGPoint(x: bx + 5, y: y + 12))
                    $0.addLine(to: CGPoint(x: bx, y: y + 22)); $0.addLine(to: CGPoint(x: bx - 5, y: y + 12)); $0.closeSubpath() },
                         with: .color(.red))
                let names = b.enemies.map { $0.name ?? String(format: "$%02X", $0.enemyId) }.joined(separator: ", ")
                ctx.draw(Text(names.isEmpty ? "battle" : names).font(.system(size: 8, weight: .bold)).foregroundColor(.red),
                         at: CGPoint(x: bx + 8, y: y + 4), anchor: .leading)
            }
            for m in r.messages where m.slot / 2 == lane.object {
                ctx.draw(Text("✉").font(.system(size: 9)), at: CGPoint(x: x(m.frame), y: y + Self.laneH - 4))
            }
        }
        let px = x(playhead)
        ctx.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) }, with: .color(.red), lineWidth: 1)
    }

    /// The bar under a click: the lane by row, the bar covering the frame (else the nearest start).
    private func pick(_ r: CTSceneRun.Result, at p: CGPoint) {
        let row = Int((p.y - Self.rulerH) / Self.laneH)
        guard r.lanes.indices.contains(row) else { return }
        let lane = r.lanes[row]
        let f = Int((p.x - Self.labelW) / scale) - 1
        // Typed closures keep this cheap for CI's older type checker (Xcode 26.6).
        let covering = lane.bars.last { (bar: CTSceneRun.Bar) -> Bool in
            let end: Int = bar.end ?? r.frames
            return bar.start <= f && end >= f
        }
        let nearest = lane.bars.min { (x: CTSceneRun.Bar, y: CTSceneRun.Bar) -> Bool in
            let dx: Int = abs(x.start - f), dy: Int = abs(y.start - f)
            return dx < dy
        }
        guard let b = covering ?? nearest else { return }
        selection = SceneLocationEditorSelection.select(offset: b.offset, object: lane.object, in: analysis)
        playhead = max(0, b.start)
    }

    @ViewBuilder private func detail(_ r: CTSceneRun.Result) -> some View {
        if let o = selection.object, let y = selection.offset,
           let lane = r.lanes.first(where: { $0.object == o }) {
            let bars = lane.bars.filter { $0.offset == y }
            if let b = bars.last(where: { $0.start <= playhead }) ?? bars.first {
                let span = b.end.map { "f\(b.start)–f\($0), \($0 - b.start) frames" } ?? "from f\(b.start), still running at the end"
                let branch = b.jumped.map { $0 ? " · jumped" : " · went on" } ?? ""
                Text(String(format: "obj %d $%04X ", o, y) + "\(b.text): \(span), \(b.runs) handler runs, level \(b.level)\(branch)"
                     + (b.interrupted ? " · left before it finished" : "") + (b.stop.map { " · STOP: \($0)" } ?? "")
                     + (bars.count > 1 ? " · ran \(bars.count) times" : ""))
                    .font(.caption).monospaced().lineLimit(2).textSelection(.enabled)
            } else {
                Text(String(format: "obj %d never ran $%04X in this run.", o, y)).font(.caption).foregroundStyle(.secondary)
            }
        }
        Text(r.notes.joined(separator: " ")).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// Selecting a statement of a given object from outside the editor.
enum SceneLocationEditorSelection {
    static func select(offset y: Int, object k: Int, in a: CTSceneAnalysis) -> SceneSelection {
        guard a.objects.indices.contains(k) else { return SceneSelection(object: k, function: nil, offset: y) }
        let o = a.objects[k]
        if let f = o.functions.first(where: { $0.alias == nil && $0.statements.contains(y) }) {
            return SceneSelection(object: k, function: f.index, offset: y)
        }
        return SceneSelection(object: k, function: o.continuation.contains(y) ? CTSceneGraph.continuation : nil, offset: y)
    }
}
