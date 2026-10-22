// SongTrackerViews.swift — a ct-song/1 listing as a tracker grid and a piano
// roll (CTSongDocument / CTSongTimeline), with a note inspector and loop
// markers. Every edit goes through ProjectStore.editSong (saved, undoable).
import SwiftUI
import ChronoForgeCore

/// The listing's model, rebuilt when the text changes.
@MainActor
@Observable
final class SongModel {
    private(set) var text = ""
    private(set) var doc = CTSongDocument(items: [])
    private(set) var tables: CTSongTables?
    private(set) var timeline: CTSongTimeline?
    /// Steps to passes over a run long enough to cover the song loop twice.
    private(set) var tempo: CTSongTempoMap?
    private(set) var error: String?

    func update(_ text: String) {
        guard text != self.text || timeline == nil && error == nil else { return }
        self.text = text
        doc = CTSongDocument(listing: text)
        do {
            tables = try doc.assemble().tables
            let timeline = try CTSongTimeline(doc, tables: tables)
            let unrolled = try CTSongTimeline(doc, tables: tables, options: .init(untilLoop: false, maxSteps: 2 * timeline.length + 1))
            self.timeline = timeline
            tempo = CTSongTempoMap(unrolled, steps: 2 * timeline.length + 2)
            error = nil
        } catch {
            timeline = nil; tempo = nil
            self.error = String(describing: error)
        }
    }

    var length: Int { timeline?.length ?? 0 }

    /// The song step playing `seconds` into playback, folded into the song
    /// loop (the longest track's) once playback passes its end.
    func step(atSeconds seconds: Double) -> Int? {
        guard let timeline, let tempo else { return nil }
        var step = tempo.step(atSeconds: seconds)
        if let loop = timeline.tracks.filter({ $0.loopEnd != nil }).max(by: { $0.loopEnd! < $1.loopEnd! }),
           let start = loop.loopStart, let end = loop.loopEnd, end > start, step >= end {
            step = start + (step - start) % (end - start)
        }
        return step
    }

    func note(_ id: String?) -> CTSongTimeline.Note? {
        guard let id else { return nil }
        return timeline?.tracks.lazy.flatMap(\.notes).first { $0.id == id }
    }

    /// How many times the track runs a statement (more than 1 in a loop).
    func runs(_ item: Int, track: Int) -> Int {
        timeline?.tracks[track].events.filter { $0.item == item }.count ?? 0
    }
}

/// What the song views edit through: the store, the listing's path and the
/// editor's text.
struct SongEditing {
    let store: ProjectStore
    let rel: String
    let model: SongModel
    let undoManager: UndoManager?
    let show: @MainActor (String) -> Void

    @MainActor @discardableResult
    func callAsFunction(_ name: String, _ edit: (inout CTSongDocument) throws -> Void) -> Bool {
        store.editSong(rel, text: model.text, name: name, undoManager: undoManager, show: show, edit)
    }
}

// MARK: - Tracker grid

struct TrackerGridView: View {
    let model: SongModel
    let edit: SongEditing
    @Binding var selected: String?
    let cursor: Int?
    @State private var rowSteps = 12
    @State private var follow = true

    private static let cellWidth: CGFloat = 112

    var body: some View {
        if let timeline = model.timeline {
            let rows = model.length / rowSteps + 1
            let cells = Self.cells(timeline, rowSteps: rowSteps)
            VStack(spacing: 0) {
                HStack {
                    Picker("Row", selection: $rowSteps) {
                        ForEach([3, 6, 12, 24, 48], id: \.self) { Text("\($0) steps").tag($0) }
                    }.frame(width: 150)
                    Toggle("Follow playback", isOn: $follow).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(rows) rows · \(model.length) steps").foregroundStyle(.secondary)
                }.font(.caption).padding(6)
                ScrollViewReader { proxy in
                    ScrollView([.vertical, .horizontal]) {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            Section(header: header(timeline)) {
                                ForEach(0..<rows, id: \.self) { r in row(r, cells: cells, timeline: timeline).id(r) }
                            }
                        }
                    }
                    .onChange(of: cursor.map { $0 / rowSteps }) { _, r in
                        if follow, let r { proxy.scrollTo(r, anchor: .center) }
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            }
        } else {
            Label(model.error ?? "no song", systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding()
        }
    }

    private func header(_ timeline: CTSongTimeline) -> some View {
        HStack(spacing: 0) {
            Text("step").frame(width: 56, alignment: .trailing).padding(.trailing, 6)
            ForEach(0..<8, id: \.self) { t in
                let track = timeline.tracks[t]
                Text(track.stop == "none" ? "—" : "track \(t)" + (track.loopStart != nil ? " ⟲" : ""))
                    .frame(width: Self.cellWidth, alignment: .leading)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .padding(.vertical, 3).background(.bar)
    }

    private func row(_ r: Int, cells: [[Int: Cell]], timeline: CTSongTimeline) -> some View {
        let playing = cursor.map { $0 / rowSteps == r } ?? false
        return HStack(spacing: 0) {
            Text(String(r * rowSteps)).foregroundStyle(.secondary).frame(width: 56, alignment: .trailing).padding(.trailing, 6)
            ForEach(0..<8, id: \.self) { t in
                let cell = cells[t][r]
                let isLoop = timeline.tracks[t].loopStart.map { $0 / rowSteps == r } ?? false
                Text(cell?.text ?? (isLoop ? "⟲ loop" : "·"))
                    .foregroundStyle(cell?.note == nil ? Color.secondary : (cell?.note == selected ? Color.accentColor : .primary))
                    .lineLimit(1)
                    .frame(width: Self.cellWidth, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { if let id = cell?.note { selected = id } }
            }
        }
        .padding(.vertical, 1)
        .background(playing ? Color.accentColor.opacity(0.25) : (r % 4 == 0 ? Color.secondary.opacity(0.08) : .clear))
    }

    struct Cell { var text: String; var note: String? }

    /// Per track, the first event starting in each row: a note as name,
    /// sample and volume; a rest as ===; a tie as ~~~; else the command.
    static func cells(_ timeline: CTSongTimeline, rowSteps: Int) -> [[Int: Cell]] {
        timeline.tracks.map { track in
            var out: [Int: Cell] = [:]
            let notes = Dictionary(track.notes.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
            for e in track.events {
                let r = e.step / rowSteps
                if let have = out[r], have.note != nil { continue }
                switch e.statement {
                case .note:
                    guard let n = notes[e.step] else { continue }
                    out[r] = Cell(text: CTSongTimeline.noteName(n.number).padding(toLength: 4, withPad: " ", startingAt: 0)
                                  + (n.sample.map { String(format: " %02X", $0) } ?? " --")
                                  + (n.volume.map { String(format: " v%02X", $0) } ?? "")
                                  + (n.keyOn ? "" : " ⌒"), note: n.id)
                case .rest: if out[r] == nil { out[r] = Cell(text: "===") }
                case .tie: if out[r] == nil { out[r] = Cell(text: "~~~") }
                case .command: if out[r] == nil { out[r] = Cell(text: e.statement.name) }
                }
            }
            return out
        }
    }
}

// MARK: - Piano roll

struct PianoRollView: View {
    let model: SongModel
    let edit: SongEditing
    @Binding var selected: String?
    @Binding var track: Int
    let cursor: Int?
    @State private var zoom: CGFloat = 2
    @State private var quantize = 12
    @State private var drag: (note: CTSongTimeline.Note, resize: Bool, offset: CGSize)?

    private let keyHeight: CGFloat = 9

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Track", selection: $track) {
                    ForEach(0..<8, id: \.self) { t in
                        Text("\(t)").tag(t).disabled(model.timeline?.tracks[t].stop == "none")
                    }
                }.pickerStyle(.segmented).frame(width: 260)
                Picker("Grid", selection: $quantize) {
                    ForEach([3, 6, 12, 24, 48], id: \.self) { Text("\($0)").tag($0) }
                }.frame(width: 110)
                Slider(value: $zoom, in: 0.5...8) { Text("Zoom") }.frame(width: 160)
                Spacer()
                Text("double-click: add · drag: move · drag the right edge: resize · ⌫: delete")
                    .foregroundStyle(.secondary)
            }
            .font(.caption).padding(6)
            if let timeline = model.timeline {
                roll(timeline)
            } else {
                Label(model.error ?? "no song", systemImage: "exclamationmark.triangle").foregroundStyle(.red).padding()
            }
        }
    }

    private func range(_ notes: [CTSongTimeline.Note]) -> (low: Int, high: Int) {
        let numbers = notes.map(\.number)
        let low = (numbers.min() ?? 36) - 5, high = (numbers.max() ?? 60) + 5
        return (max(0, low), max(low + 24, high))
    }

    private func roll(_ timeline: CTSongTimeline) -> some View {
        let t = timeline.tracks[track]
        let (low, high) = range(t.notes)
        let width = CGFloat(max(model.length, 1) + 96) * zoom
        let height = CGFloat(high - low + 1) * keyHeight
        func y(_ number: Int) -> CGFloat { CGFloat(high - number) * keyHeight }
        func rect(_ n: CTSongTimeline.Note) -> CGRect {
            CGRect(x: CGFloat(n.start) * zoom, y: y(n.number), width: max(2, CGFloat(n.length) * zoom - 1), height: keyHeight - 1)
        }
        func hit(_ p: CGPoint) -> CTSongTimeline.Note? { t.notes.last { rect($0).insetBy(dx: -1, dy: 0).contains(p) } }
        return ScrollView([.horizontal, .vertical]) {
            Canvas { context, size in
                for number in low...high where [1, 3, 6, 8, 10].contains(number % 12) {
                    context.fill(Path(CGRect(x: 0, y: y(number), width: size.width, height: keyHeight)), with: .color(.secondary.opacity(0.08)))
                }
                for number in low...high where number % 12 == 0 {
                    context.draw(Text(CTSongTimeline.noteName(number)).font(.system(size: 8)), at: CGPoint(x: 14, y: y(number) + keyHeight / 2))
                }
                for s in stride(from: 0, through: model.length, by: 48) {
                    context.stroke(Path { $0.move(to: CGPoint(x: CGFloat(s) * zoom, y: 0)); $0.addLine(to: CGPoint(x: CGFloat(s) * zoom, y: size.height)) },
                                   with: .color(.secondary.opacity(s % 192 == 0 ? 0.35 : 0.15)))
                }
                // Other tracks, faint.
                for other in timeline.tracks where other.index != track {
                    for n in other.notes where (low...high).contains(n.number) {
                        context.fill(Path(rect(n)), with: .color(.secondary.opacity(0.12)))
                    }
                }
                for n in t.notes {
                    var r = rect(n)
                    if let drag, drag.note == n {
                        if drag.resize { r.size.width = max(2, r.width + drag.offset.width) }
                        else { r = r.offsetBy(dx: drag.offset.width, dy: drag.offset.height) }
                    }
                    let color: Color = n.id == selected ? .orange : (n.pass > 0 ? .teal : .accentColor)
                    context.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(color.opacity(n.keyOn ? 0.9 : 0.55)))
                }
                if let start = t.loopStart, let end = t.loopEnd {
                    for (x, label) in [(start, "loop"), (end, "jump")] {
                        let px = CGFloat(x) * zoom
                        context.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                                       with: .color(.green), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        context.draw(Text(label).font(.system(size: 9)).foregroundStyle(.green), at: CGPoint(x: px + 14, y: 8))
                    }
                }
                if let cursor {
                    let px = CGFloat(cursor) * zoom
                    context.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) },
                                   with: .color(.red), lineWidth: 1.5)
                }
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { tap in
                guard hit(tap.location) == nil else { return }
                let step = Int(tap.location.x / zoom) / quantize * quantize
                let number = high - Int(tap.location.y / keyHeight)
                edit("Add Note") { doc in
                    try doc.insertNote(track: track, step: step, number: number, steps: quantize, timeline: timeline)
                }
                selected = "\(track):\(step)"
            })
            .simultaneousGesture(SpatialTapGesture().onEnded { tap in selected = hit(tap.location)?.id })
            .simultaneousGesture(DragGesture(minimumDistance: 4).onChanged { g in
                if drag == nil, let n = hit(g.startLocation) {
                    drag = (n, g.startLocation.x > rect(n).maxX - 6, .zero)
                    selected = n.id
                }
                drag?.offset = g.translation
            }.onEnded { g in
                guard let d = drag else { return }
                drag = nil
                let steps = Int((g.translation.width / zoom / CGFloat(quantize)).rounded()) * quantize
                if d.resize {
                    edit("Resize Note") { doc in try doc.setLength(d.note, max(3, d.note.length + steps)) }
                } else {
                    let keys = -Int((g.translation.height / keyHeight).rounded())
                    guard steps != 0 || keys != 0 else { return }
                    if edit("Move Note", { doc in
                        try doc.moveNote(d.note, toStep: max(0, d.note.start + steps), number: d.note.number + keys, tables: model.tables)
                    }) { selected = "\(track):\(max(0, d.note.start + steps))" }
                }
            })
        }
        .focusable()
        .onDeleteCommand {
            guard let n = model.note(selected) else { return }
            if edit("Delete Note", { try $0.deleteNote(n) }) { selected = nil }
        }
    }
}

// MARK: - Note inspector and loops

struct NoteInspector: View {
    let model: SongModel
    let edit: SongEditing
    @Binding var selected: String?
    let track: Int
    @State private var length = 0
    @State private var volume = 0.0

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            if let n = model.note(selected) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(CTSongTimeline.noteName(n.number))  track \(n.track) · step \(n.start) · \(n.length) steps")
                        .font(.headline)
                    Text("line \(n.item + 1)" + (model.runs(n.item, track: n.track) > 1 ? " · runs \(model.runs(n.item, track: n.track))× (a loop: every pass changes)" : "")
                         + (n.keyOn ? "" : " · legato (no key-on)") + (n.drum ? " · drum kit" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Picker("Note", selection: Binding(get: { n.semitone }, set: { s in
                            edit("Set Note") { try $0.setSemitone(n.item, s) }
                        })) { ForEach(0..<12, id: \.self) { Text(CTSongISA.noteNames[$0]).tag($0) } }
                            .frame(width: 120).disabled(n.drum)
                        TextField("Length", value: $length, format: .number).frame(width: 60)
                            .onSubmit { edit("Set Length") { try $0.setLength(n, length) } }
                        Text("steps").foregroundStyle(.secondary)
                        Button("Delete", systemImage: "trash") {
                            if edit("Delete Note", { try $0.deleteNote(n) }) { selected = nil }
                        }
                    }
                    HStack {
                        Stepper(String(format: "sample $%02X", n.sample ?? 0x20), onIncrement: {
                            edit("Set Instrument") { try $0.setControl(before: n.item, "sample", UInt8(min(0x2F, (n.sample ?? 0x1F) + 1))) }
                        }, onDecrement: {
                            edit("Set Instrument") { try $0.setControl(before: n.item, "sample", UInt8(max(0x20, (n.sample ?? 0x21) - 1))) }
                        })
                        Slider(value: $volume, in: 0...127) { Text(String(format: "volume $%02X", Int(volume))) } onEditingChanged: { editing in
                            if !editing { edit("Set Volume") { try $0.setControl(before: n.item, "volume", UInt8(volume)) } }
                        }.frame(width: 240)
                    }
                    Text("sample and volume apply from this note on, as a tracker's effect column does")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .onAppear { length = n.length; volume = Double(n.volume ?? 0x7F) }
                .onChange(of: n) { _, n in length = n.length; volume = Double(n.volume ?? 0x7F) }
            } else {
                Text("Select a note (click it in the grid or the roll).").foregroundStyle(.secondary)
            }
            Divider()
            LoopMarkers(model: model, edit: edit, selected: selected, track: track)
        }
        .padding(8)
        .frame(height: 150)
    }
}

/// The track's loop_start statements (passes) and its song loop point.
struct LoopMarkers: View {
    let model: SongModel
    let edit: SongEditing
    let selected: String?
    let track: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let t = model.timeline?.tracks[track] {
                Text("Loops on track \(track)").font(.headline)
                Text(t.loopStart.map { "song loop: steps \($0)–\(t.loopEnd!)" } ?? "no song loop (\(t.stop))")
                    .font(.caption)
                let starts = Dictionary(t.events.filter { $0.statement.name == "loop_start" }.map { ($0.item, $0) }, uniquingKeysWith: { a, _ in a })
                ScrollView {
                    VStack(alignment: .leading) {
                        ForEach(starts.keys.sorted(), id: \.self) { item in
                            if case .command(_, let ops, _) = starts[item]!.statement {
                                let passes = ops[0] == 0 || ops[0] == 0xFF ? 0 : Int(ops[0]) + 1
                                Stepper("line \(item + 1), step \(starts[item]!.step): " + (passes == 0 ? "endless" : "\(passes) passes"),
                                        onIncrement: { edit("Loop Passes") { try $0.setLoopPasses(item, passes == 0 ? 2 : min(255, passes + 1)) } },
                                        onDecrement: { edit("Loop Passes") { try $0.setLoopPasses(item, max(2, passes - 1)) } })
                                    .font(.caption)
                            }
                        }
                    }
                }.frame(maxHeight: 70)
                Button("Song loop starts at the selected note") {
                    guard let n = model.note(selected), n.track == track else { return }
                    edit("Set Song Loop") { try $0.setSongLoop(track: t, at: n.item) }
                }
                .disabled(model.note(selected)?.track != track || t.stop != "loop")
                .font(.caption)
            }
        }
        .frame(width: 330, alignment: .leading)
    }
}
