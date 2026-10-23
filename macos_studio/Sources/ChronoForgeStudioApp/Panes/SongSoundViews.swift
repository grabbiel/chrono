// SongSoundViews.swift — a song's instrument rack (its @samples row, the ROM's
// tuning and ADSR words or a project sample's, the build's budget, one-note
// auditions through the driver, with project samples from a scratch ROM built
// in memory), its drum kit (the @drum pads, each auditioned in drum mode) and
// its echo designer (EDL, EVOL, EFB, FIR set, echo per track, and their responses).
import SwiftUI
import ChronoForgeCore

struct InstrumentRackView: View {
    let store: ProjectStore
    let model: SongModel
    let edit: SongEditing
    let target: Int
    @State private var auditionNumber = 48
    @State private var rack: [CTSongInstrument]?
    @State private var placed: [CTProjectSamples.Placed] = []
    @State private var budget: Result<CTSongBudget, Error>?

    private var samples: [Int] { model.tables?.samples ?? [] }

    var body: some View {
        ScrollView(.vertical) { content }
            .onAppear(perform: reload)
            .onChange(of: samples) { _, _ in reload() }
            .onChange(of: model.text) { _, _ in budget = store.songBudget(target, listing: model.text) }
    }

    // The rack's column, apart from body: CI's older type checker (Xcode 26.6) is slow on deep view builders.
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Instruments: @samples loads these into directory entries $20–$2F").font(.headline)
                Spacer()
                Stepper("audition note \(CTSongTimeline.noteName(auditionNumber))", value: $auditionNumber, in: 12...96)
            }
            if model.tables?.samples == nil {
                Text("This listing has no @samples row: the ROM song's list is kept. Add one to choose instruments.")
                    .foregroundStyle(.secondary)
                Button("Add @samples (one sample, number 1)") { edit("Add Samples") { $0.setDirective("@samples", "1") } }
            }
            Table(rack ?? []) {
                TableColumn("Slot") { i in Text(String(format: "$%02X", 0x20 + i.slot)).monospaced() }.width(min: 36, ideal: 44)
                TableColumn("ROM sample") { i in
                    Stepper("\(i.sample)", onIncrement: { setSample(i.slot, min(sampleCount, i.sample + 1)) },
                            onDecrement: { setSample(i.slot, max(1, i.sample - 1)) })
                }.width(min: 80, ideal: 110)
                TableColumn("Project sample") { i in
                    Menu(projectSample(i.sample)?.id ?? "ROM's") {
                        ForEach(placed, id: \.number) { p in
                            Button("\(p.id) (sample \(p.number))") { setSample(i.slot, p.number) }
                        }
                    }
                    .disabled(placed.isEmpty || model.tables?.samples == nil)
                    .help("Load a sample rom.samples writes (SFX Lab › Use in game) in this slot")
                }.width(min: 80, ideal: 130)
                TableColumn("Tuning") { i in Text(String(format: "$%04X ×%.4f", i.tuning, i.pitchFactor)).monospaced() }.width(min: 80, ideal: 130)
                TableColumn("ADSR") { i in
                    let e = i.envelope
                    Text(e.on ? "A\(e.attack) D\(e.decay) SL\(e.sustainLevel) SR\(e.sustainRate)" : String(format: "GAIN $%04X", i.adsr))
                        .monospaced()
                }.width(min: 90, ideal: 140)
                TableColumn("BRR") { i in Text("\(i.length) B, loop at \(i.loopOffset)").monospaced() }.width(min: 90, ideal: 150)
                TableColumn("Uses") { i in Text("\(uses[0x20 + i.slot, default: 0]) notes") }.width(min: 50, ideal: 70)
                TableColumn("") { i in
                    Button("Audition", systemImage: "play.fill") {
                        store.audition(slot: i.slot, number: auditionNumber, tables: model.tables ?? .init(), replacing: target)
                    }.labelStyle(.iconOnly)
                    .help(projectSample(i.sample) != nil
                          ? "Audition: the driver loads this project sample from a ROM built in memory with rom.samples"
                          : "Audition")
                }.width(min: 24, ideal: 30)
            }
            .frame(height: CGFloat(max(3, rack?.count ?? 0)) * 30 + 40)
            HStack {
                Button("Add slot") { setSamples(samples + [samples.last ?? 1]) }.disabled(samples.count >= 16 || model.tables?.samples == nil)
                Button("Remove last slot") { setSamples(Array(samples.dropLast())) }.disabled(samples.count <= 1)
                Spacer()
                switch budget {
                case .success(let b):
                    Text(String(format: "budget as built into $%02X: samples %d bytes from $%04X, %d free below the echo buffer ($%04X); sequence %d of %d bytes%@",
                                target, b.sampleBytes, b.sampleStart, b.freeBytes, b.echoStart, b.sequenceBytes, b.sequenceMax,
                                b.reachesEffectsBlock ? " (reaches the $2F00 effects block)" : ""))
                        .foregroundStyle(b.fits ? Color.secondary : Color.red).font(.caption)
                        .lineLimit(3).frame(minWidth: 120, alignment: .trailing)
                        .help("The build refuses a song whose samples reach the echo buffer or whose sequence reaches $4700")
                case .failure(let error):
                    Text(String(describing: error)).foregroundStyle(.secondary).font(.caption)
                case nil:
                    EmptyView()
                }
            }
            Divider()
            DrumKitView(store: store, model: model, edit: edit, target: target, placed: placed)
            overrides
        }
        .padding()
    }

    /// The ROM's samples and the ones rom.samples appends.
    private var sampleCount: Int { CTSampleTables.rom.count + placed.filter { $0.number > CTSampleTables.rom.count }.count }

    private func projectSample(_ number: Int) -> CTProjectSamples.Placed? { placed.first { $0.number == number } }

    private var uses: [Int: Int] {
        Dictionary(grouping: model.timeline?.tracks.flatMap(\.notes) ?? [], by: { $0.sample ?? -1 }).mapValues(\.count)
    }

    /// Per-track envelope and tuning commands, which change an instrument for that track.
    private var overrides: some View {
        let names: Set<String> = ["attack", "decay", "sustain_level", "sustain_rate", "adsr_reset", "fine_tune"]
        let lines = (model.timeline?.tracks ?? []).compactMap { t -> String? in
            let found = t.events.filter { names.contains($0.statement.name) }
            guard !found.isEmpty else { return nil }
            let first = Dictionary(found.map { ($0.statement.name, $0) }, uniquingKeysWith: { a, _ in a })
            return "track \(t.index): " + first.keys.sorted().map { k in first[k]!.statement.text.trimmingCharacters(in: .whitespaces) }.joined(separator: ", ")
        }
        return VStack(alignment: .leading) {
            Text("Per-track envelope and tuning (sequence commands)").font(.subheadline)
            Text(lines.isEmpty ? "none" : lines.joined(separator: "\n")).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    private func reload() {
        placed = store.project.map { CTProjectSamples.placed($0).placed } ?? []
        rack = samples.isEmpty ? [] : store.instrumentRack(samples: samples)
        budget = store.songBudget(target, listing: model.text)
    }

    private func setSample(_ slot: Int, _ number: Int) {
        var list = samples
        list[slot] = number
        setSamples(list)
    }

    private func setSamples(_ list: [Int]) {
        edit("Set Samples") { $0.setDirective("@samples", list.isEmpty ? "none" : list.map(String.init).joined(separator: " ")) }
    }
}

/// The song's drum kit (its @drum rows, CTDrumKit): twelve pads, each a
/// directory entry ($20 + slot of @samples), a note and a pan, as
/// Spc_DrumNote plays them for a note of index 0-11 in drum mode (`drums_on`).
/// Each pad auditions through the driver in drum mode.
struct DrumKitView: View {
    let store: ProjectStore
    let model: SongModel
    let edit: SongEditing
    let target: Int
    let placed: [CTProjectSamples.Placed]

    private var samples: [Int] { model.tables?.samples ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Drum kit: in drum mode (drums_on) a note's index 0–11 plays that pad").font(.headline)
                Spacer()
                if let kit = model.doc.drumKit, !kit.isEmpty {
                    Button("Clear kit") { set(.empty, "Clear Drum Kit") }
                }
            }
            if let kit = model.doc.drumKit {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8)], spacing: 8) {
                    ForEach(0..<CTDrumKit.padCount, id: \.self) { k in pad(k, kit) }
                }
                let problems = kit.problems(listed: model.tables?.samples?.count)
                if !problems.isEmpty {
                    Text(problems.joined(separator: "\n")).font(.caption).foregroundStyle(.red)
                }
                Text(drumTracks).font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Text("This listing has no @drum rows: the ROM song's kit stays as it is.").foregroundStyle(.secondary)
                    Button("Add a kit") { set(.empty, "Add Drum Kit") }
                }
            }
        }
    }

    /// Which tracks play in drum mode, and how many notes.
    private var drumTracks: String {
        let tracks = (model.timeline?.tracks ?? []).compactMap { t -> String? in
            let n = t.notes.filter(\.drum).count
            return n > 0 ? "track \(t.index) (\(n) notes)" : nil
        }
        return tracks.isEmpty ? "No track turns drum mode on: put drums_on before a track's notes (Listing view)."
                              : "Drum mode: " + tracks.joined(separator: ", ")
    }

    private func uses(_ k: Int) -> Int {
        let tracks: [CTSongTimeline.Track] = model.timeline?.tracks ?? []
        var count = 0
        for t in tracks { for n in t.notes where n.drum && n.semitone == k { count += 1 } }
        return count
    }

    private func name(_ slot: Int) -> String {
        guard samples.indices.contains(slot) else { return String(format: "$%02X (not listed)", CTDrumKit.firstEntry + slot) }
        let n = samples[slot]
        let id = placed.first { $0.number == n }?.id
        let label: String = String(format: "$%02X: sample %d", CTDrumKit.firstEntry + slot, n)
        guard let id else { return label }
        return label + " (\(id))"
    }

    @ViewBuilder private func pad(_ k: Int, _ kit: CTDrumKit) -> some View {
        let p = kit.pads[k]
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Pad \(k) · \(CTSongISA.noteNames[k])").font(.subheadline.bold())
                    Spacer()
                    Button("Audition pad \(k)", systemImage: "play.fill") {
                        store.auditionPad(k, kit: kit, tables: model.tables ?? .init(), replacing: target)
                    }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(p.isEmpty)
                    .help("Play this pad once in drum mode through the driver")
                }
                Menu(p.isEmpty ? "unused" : p.slot.map(name) ?? String(format: "$%02X", p.sample)) {
                    ForEach(samples.indices, id: \.self) { slot in
                        Button(name(slot)) {
                            var q = p
                            q.sample = CTDrumKit.firstEntry + slot
                            if p.isEmpty { q.note = CTSampleTuning.defaultRoot; q.pan = 0x40 }
                            setPad(k, q, kit)
                        }
                    }
                    Divider()
                    Button("Unused") { setPad(k, .init(), kit) }
                }
                .disabled(samples.isEmpty)
                Stepper("note \(CTSongTimeline.noteName(p.number()))", onIncrement: {
                    var q = p; q.note = min(CTDrumKit.noteRange.upperBound, p.note + 1); setPad(k, q, kit)
                }, onDecrement: {
                    var q = p; q.note = max(CTDrumKit.noteRange.lowerBound, p.note - 1); setPad(k, q, kit)
                }).disabled(p.isEmpty).help("The note the driver plays (at transpose $0A: the note number)")
                HStack {
                    Toggle("track's pan", isOn: Binding(get: { p.keepsPan }, set: { keep in
                        var q = p; q.pan = keep ? 0x80 : 0x40; setPad(k, q, kit)
                    })).toggleStyle(.checkbox)
                    Stepper(p.keepsPan ? "" : String(format: "$%02X", p.pan), onIncrement: {
                        var q = p; q.pan = min(0x7F, p.pan + 8); setPad(k, q, kit)
                    }, onDecrement: {
                        var q = p; q.pan = max(0, p.pan - 8); setPad(k, q, kit)
                    }).disabled(p.isEmpty || p.keepsPan)
                }
                .disabled(p.isEmpty)
                Text("\(uses(k)) notes").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func setPad(_ k: Int, _ pad: CTDrumKit.Pad, _ kit: CTDrumKit) {
        var pads = kit.pads
        pads[k] = pad
        guard let next = try? CTDrumKit(pads: pads) else { return }
        set(next, "Drum Pad \(k)")
    }

    private func set(_ kit: CTDrumKit, _ name: String) {
        edit(name) { $0.setDrumKit(kit) }
    }
}

struct EchoDesignerView: View {
    let store: ProjectStore
    let model: SongModel
    let edit: SongEditing
    let play: () -> Void
    @State private var evol = 0.0
    @State private var efb = 0.0
    @State private var sets: [[Int8]]?
    @State private var custom: [Int8]?

    var body: some View {
        let s = CTSongEcho.settings(model.doc, model.timeline ?? .empty)
        let taps = custom ?? sets.flatMap { sets in s.firSet.map { sets[$0] } } ?? [127, 0, 0, 0, 0, 0, 0, 0]
        let edl = s.edl ?? 0
        HStack(alignment: .top, spacing: 20) {
            Form {
                Section("Delay (the song's AudioRom_SongEcho row)") {
                    Stepper("EDL \(edl): \(edl * 16) ms", onIncrement: {
                        edit("Echo Delay") { try $0.setEchoDelay(min(15, edl + 1)) }
                    }, onDecrement: {
                        edit("Echo Delay") { try $0.setEchoDelay(max(0, edl - 1)) }
                    })
                    Text(String(format: "buffer $%04X–$F0FF (%d KB)", CTSongEcho.buffer(edl: edl).lowerBound, 2 * edl))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Sequence commands (the first each track runs)") {
                    Slider(value: $evol, in: -128...127) { Text("EVOL \(Int(evol))") } onEditingChanged: { editing in
                        if !editing { edit("Echo Volume") { try $0.setEcho("echo_volume", item: s.evolItem, value: UInt8(bitPattern: Int8(evol))) } }
                    }
                    Slider(value: $efb, in: -128...127) { Text("EFB \(Int(efb))") } onEditingChanged: { editing in
                        if !editing { edit("Echo Feedback") { try $0.setEcho("efb_fade", item: s.efbItem, value: UInt8(bitPattern: Int8(efb))) } }
                    }
                    Picker("FIR set", selection: Binding(get: { s.firSet ?? -1 }, set: { k in
                        custom = nil
                        edit("FIR Set") { try $0.setEcho("fir", item: s.firItem, value: UInt8(k)) }
                    })) {
                        if s.firSet == nil { Text("not set").tag(-1) }
                        ForEach(0..<4, id: \.self) { Text("set \($0)").tag($0) }
                    }
                    Text("taps " + taps.map { String(format: "%d", $0) }.joined(separator: " ") + (custom != nil ? " (custom: analysis only)" : ""))
                        .font(.caption.monospaced())
                    Toggle("Try custom taps (the driver plays only its four sets)", isOn: Binding(
                        get: { custom != nil }, set: { custom = $0 ? taps : nil }))
                    if custom != nil {
                        HStack {
                            ForEach(0..<8, id: \.self) { k in
                                TextField("", value: Binding(get: { Int(custom![k]) }, set: { custom![k] = Int8(clamping: $0) }), format: .number)
                                    .frame(width: 44)
                            }
                        }
                    }
                }
                Section("Echo per track (EON at its first note)") {
                    ForEach(0..<8, id: \.self) { t in
                        if let on = s.eon[t], let track = model.timeline?.tracks[t] {
                            Toggle("track \(t)", isOn: Binding(get: { on }, set: { v in
                                edit(v ? "Echo On" : "Echo Off") { try $0.setTrackEcho(track, on: v) }
                            }))
                        }
                    }
                }
                Button("Preview the edited song", systemImage: "play.fill", action: play)
            }
            .formStyle(.grouped)
            .frame(width: 380)
            VStack(alignment: .leading) {
                Text("FIR frequency response (0–16 kHz)").font(.headline)
                ResponsePlot(values: CTSongEcho.frequencyResponse(taps).map(\.db), range: -40...12, zeroLine: 0)
                    .frame(height: 170)
                Text("Echo impulse response, 1 s (EDL \(edl), EFB \(Int(efb)), EVOL \(Int(evol)))").font(.headline)
                ResponsePlot(values: CTSongEcho.impulseResponse(taps: taps, edl: edl, efb: Int(efb), evol: Int(evol)).map(abs),
                             range: 0...0.6, zeroLine: nil)
                    .frame(height: 170)
                Text("Floating-point model of the S-DSP echo path; the preview plays the driver's own.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear {
            sets = store.driverFIRSets()
            evol = Double(s.evol ?? 0); efb = Double(s.efb ?? 0)
        }
        .onChange(of: model.text) { _, _ in
            let s = CTSongEcho.settings(model.doc, model.timeline ?? .empty)
            evol = Double(s.evol ?? 0); efb = Double(s.efb ?? 0)
        }
    }
}

/// A line plot of `values` across the width, clipped to `range`.
struct ResponsePlot: View {
    let values: [Double]
    let range: ClosedRange<Double>
    let zeroLine: Double?

    var body: some View {
        Canvas { context, size in
            func y(_ v: Double) -> CGFloat {
                let c = min(range.upperBound, max(range.lowerBound, v))
                return size.height * CGFloat(1 - (c - range.lowerBound) / (range.upperBound - range.lowerBound))
            }
            context.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(.secondary.opacity(0.3)))
            if let zeroLine {
                context.stroke(Path { $0.move(to: CGPoint(x: 0, y: y(zeroLine))); $0.addLine(to: CGPoint(x: size.width, y: y(zeroLine))) },
                               with: .color(.secondary.opacity(0.5)), style: StrokeStyle(dash: [3, 3]))
            }
            guard values.count > 1 else { return }
            // Draw at most one point per pixel column (the column's peak).
            let columns = max(1, Int(size.width))
            var path = Path()
            for c in 0..<columns {
                let lo = c * values.count / columns, hi = max(lo + 1, (c + 1) * values.count / columns)
                let v = values[lo..<min(hi, values.count)].max() ?? 0
                let p = CGPoint(x: CGFloat(c), y: y(v))
                if c == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            context.stroke(path, with: .color(.accentColor), lineWidth: 1.5)
        }
    }
}

extension CTSongTimeline {
    /// A timeline with no tracks, for views of a listing that does not assemble.
    static var empty: CTSongTimeline { try! CTSongTimeline(CTSongDocument(items: [])) }
}
