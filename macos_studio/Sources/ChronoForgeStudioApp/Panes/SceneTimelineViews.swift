// SceneTimelineViews.swift — Module 8's chronological view: the raised pack
// run in EventScheduler (CTSceneTimeline) with one lane per object over
// logical frames. Waits are bars as long as their runs; moves, animations,
// dialogue, flags and calls are ticks coloured by category.
import SwiftUI
import ChronoForgeCore

struct SceneTimelineView: View {
    let document: CTSceneDocument
    let analysis: CTSceneAnalysis
    @Binding var selection: SceneSelection
    @State private var trigger = "none"
    @State private var level = 1
    @State private var party = ""
    @State private var frames = 600
    @State private var scale: CGFloat = 4
    @State private var result: CTSceneTimeline.Result?
    @State private var problem = ""

    private static let laneH: CGFloat = 26, labelW: CGFloat = 92

    /// Party members 0-2: the first objects that set up characters (an assumption; the party is runtime state).
    private var defaultParty: String {
        analysis.objects.filter { $0.markers.contains { $0.kind == "pc" } }.prefix(3).map { String($0.index) }.joined(separator: ",")
    }

    private var triggers: [(tag: String, label: String)] {
        [("none", "Location load only")] + analysis.objects.flatMap { o in
            o.functions.filter { $0.inScripts && !$0.stub && $0.alias == nil && $0.index > 0 }.map {
                ("\(o.index).\($0.index)", "obj \(o.index) func \($0.index) (\($0.role))")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Start", selection: $trigger) {
                    ForEach(triggers, id: \.tag) { Text($0.label).tag($0.tag) }
                }.frame(maxWidth: 280)
                Stepper("level \(level)", value: $level, in: 0...6).disabled(trigger == "none")
                TextField("party objects", text: $party).frame(width: 90)
                Stepper("\(frames) frames", value: $frames, in: 60...20_000, step: 60)
                Button("Run", action: run)
            }
            .font(.caption)
            if let result {
                lanes(result)
                Text("\(result.frames) frames · \(result.stopReason). " + result.notes.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("Zoom").font(.caption)
                    Slider(value: $scale, in: 1...16).frame(width: 140)
                }
                legend
            } else {
                Spacer()
                Text(problem.isEmpty ? "Run the location to see each object's lane." : problem)
                    .foregroundStyle(problem.isEmpty ? Color.secondary : Color.red)
                Spacer()
            }
        }
        .onAppear { if party.isEmpty { party = defaultParty }; run() }
        .onChange(of: document) { _, _ in run() }
    }

    private var legend: some View {
        HStack(spacing: 6) {
            ForEach([CTSceneAnalysis.Category.move, .camera, .animation, .dialogue, .wait, .call, .memory, .battle, .menu], id: \.self) { c in
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(SceneColors.color(c)).frame(width: 8, height: 8)
                    Text(c.rawValue).font(.caption2).fixedSize()
                }
            }
        }
    }

    private func run() {
        do {
            let t: CTSceneTimeline.Trigger? = trigger == "none" ? nil : {
                let p = trigger.split(separator: ".").compactMap { Int($0) }
                return CTSceneTimeline.Trigger(object: p[0], function: p[1], level: level)
            }()
            let slots = party.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            result = try CTSceneTimeline.run(try document.pack(), trigger: t, party: slots.isEmpty ? nil : slots,
                                             frameLimit: frames, stepLimit: 20_000)
            problem = ""
        } catch { result = nil; problem = "\(error)" }
    }

    private func lanes(_ r: CTSceneTimeline.Result) -> some View {
        let width = Self.labelW + CGFloat(max(r.frames, 1) + 40) * scale
        return ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    // Frame ruler every 60 frames.
                    var f = 0
                    while CGFloat(f) * scale < size.width {
                        let x = Self.labelW + CGFloat(f) * scale
                        ctx.stroke(Path { $0.move(to: CGPoint(x: x, y: 0)); $0.addLine(to: CGPoint(x: x, y: size.height)) },
                                   with: .color(.secondary.opacity(0.15)))
                        ctx.draw(Text("f\(f)").font(.system(size: 8)), at: CGPoint(x: x + 10, y: 6))
                        f += 60
                    }
                    for (row, lane) in r.lanes.enumerated() {
                        let y = 14 + CGFloat(row) * Self.laneH
                        let selectedLane = selection.object == lane.object
                        if selectedLane {
                            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: Self.laneH)), with: .color(.accentColor.opacity(0.08)))
                        }
                        ctx.draw(Text("obj \(lane.object)").font(.caption2.bold()), at: CGPoint(x: 26, y: y + Self.laneH / 2))
                        var stack: [Int: Int] = [:]
                        for e in lane.events {
                            let k = stack[e.frame, default: 0]
                            stack[e.frame] = k + 1
                            let x = Self.labelW + CGFloat(e.frame) * scale + CGFloat(k) * 3
                            let color = SceneColors.color(e.category)
                            let hot = e.offset != nil && e.offset == selection.offset && selectedLane
                            let rect = e.duration > 0
                                ? CGRect(x: x, y: y + 8, width: max(3, CGFloat(e.duration) * scale), height: Self.laneH - 16)
                                : CGRect(x: x, y: y + 4, width: 2.5, height: Self.laneH - 8)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color.opacity(hot ? 1 : 0.75)))
                            if hot { ctx.stroke(Path(rect.insetBy(dx: -2, dy: -2)), with: .color(.primary), lineWidth: 1.5) }
                        }
                    }
                }
                .frame(width: width, height: 20 + CGFloat(r.lanes.count) * Self.laneH)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { tap in pick(r, at: tap.location) })
            }
        }
    }

    /// The event under a click: its lane by row, the nearest event by frame.
    private func pick(_ r: CTSceneTimeline.Result, at p: CGPoint) {
        let row = Int((p.y - 14) / Self.laneH)
        guard r.lanes.indices.contains(row) else { return }
        let lane = r.lanes[row]
        let frame = (p.x - Self.labelW) / scale
        guard let e = lane.events.min(by: { abs(CGFloat($0.frame) - frame) < abs(CGFloat($1.frame) - frame) }) else { return }
        selection = SceneSelection(object: lane.object, function: e.function, offset: e.offset)
    }
}
