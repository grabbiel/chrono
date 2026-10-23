// MusicPane.swift — CT song sequences (audio/songs/*.ctsong, ct-song/1) as a
// listing, tracker, piano roll, instrument rack and echo designer, and
// .akao.json tracker scores. `--song <name>` and `--music-view <view>` at
// launch open a listing on a view (Listing, Tracker, Piano Roll, Instruments, Echo);
// `--music-new` opens the New… sheet and `--import-midi <file.mid>` the Import MIDI sheet.
import SwiftUI
import ChronoForgeCore
import UniformTypeIdentifiers

struct MusicPane: View {
    let store: ProjectStore
    let project: CTProject
    @State private var mode = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                Text("CT Songs").tag(0)
                Text("Tracker Scores").tag(1)
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320).padding(8)
            if mode == 0 { SongListingsView(store: store, project: project) }
            else { TrackerScoresView(store: store, project: project) }
            Divider()
            PlaybackBar(store: store, choosesROM: true)
        }
    }
}

/// ct-song/1 listings: edit, assemble live, choose the Audio_SongTable index
/// `rom build` writes them to, import from a ROM, play ROM songs and listings.
private struct SongListingsView: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?
    @State private var listings: [String] = []
    @State private var pickROM = false
    @State private var importIndex = 1
    @State private var newSong = false
    @State private var pickMIDI = false
    @State private var midi: MIDIPick?

    var body: some View {
        NavigationSplitView {
            List(listings, id: \.self, selection: $selection) { rel in
                let target = project.project.rom?.songs.first { $0.listing == rel }
                HStack {
                    Text((rel as NSString).lastPathComponent)
                    Spacer()
                    if let target { Text(String(format: "→ $%02X", target.song)).foregroundStyle(.secondary) }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Stepper(String(format: "song $%02X", importIndex), value: $importIndex, in: 0...(CTSongISA.romSongCount - 1))
                            .fixedSize()
                        Button("Play", systemImage: "play.fill") { store.playROMSong(importIndex) }
                            .labelStyle(.iconOnly).help("Play this ROM song")
                        Spacer()
                        Button("New…") { newSong = true }.help("Start a song from the template, built into this song number")
                    }
                    Menu("Import") {
                        Button("From the ROM…") { pickROM = true }
                        Button("MIDI File…") { pickMIDI = true }
                    }
                    .help("Import this song number from the ROM, or convert a MIDI file into a listing built into it")
                }.padding(8)
                .fileImporter(isPresented: $pickMIDI, allowedContentTypes: [.midi], allowsMultipleSelection: false) { picked in
                    guard case .success(let urls) = picked, let url = urls.first else { return }
                    midi = MIDIPick(url: url)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let selection {
                SongEditor(store: store, project: project, rel: selection).id(selection)
            } else {
                Text("Import a song from the ROM, or add .ctsong listings under audio/songs.")
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear {
            listings = store.songListings()
            if selection == nil, let song = LaunchArguments.value("--song") { selection = listings.first { $0.hasSuffix("/" + song) } }
        }
        .task {
            // Sheets asked for at launch open once the window is up.
            try? await Task.sleep(for: .milliseconds(500))
            if CommandLine.arguments.contains("--music-new") { newSong = true }
            if let path = LaunchArguments.value("--import-midi") { midi = MIDIPick(url: URL(fileURLWithPath: path)) }
        }
        .sheet(isPresented: $newSong) {
            NewSongSheet(song: importIndex) { song, options in
                if let rel = store.newSong(song, options: options) {
                    listings = store.songListings()
                    selection = rel
                }
            }
        }
        .sheet(item: $midi) { pick in
            MIDIImportSheet(store: store, url: pick.url, song: importIndex) { rel in
                listings = store.songListings()
                selection = rel
            }
        }
        .fileImporter(isPresented: $pickROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { picked in
            guard case .success(let urls) = picked, let url = urls.first else { return }
            if let rel = store.importSong(rom: url, song: importIndex) {
                listings = store.songListings()
                selection = rel
            }
        }
    }
}

/// A new song from the template (CTSongTemplate, docs/music_tracker.md):
/// its sample list, tracks of rests the given length that loop, and tempo
/// and echo delay; notes are then added in the tracker or piano roll.
private struct NewSongSheet: View {
    @State var song: Int
    let create: (Int, CTSongTemplate.Options) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var samplesText = "1"
    @State private var tracks = 1
    @State private var bars = 8
    @State private var tempo = 0x40
    @State private var edl = 0

    private var samples: [Int]? {
        let values = samplesText.split(whereSeparator: { $0 == "," || $0 == " " }).map { Int($0) }
        return values.isEmpty || values.contains(nil) ? nil : values.map { $0! }
    }

    var body: some View {
        Form {
            Stepper(String(format: "Build into song $%02X", song), value: $song, in: 0...(CTSongISA.romSongCount - 1))
            TextField("@samples (sample numbers)", text: $samplesText)
                .help("Audio_SampleTable numbers, 63 on for samples rom.samples appends; track k plays slot k (the last slot for the rest)")
            Stepper("\(tracks) tracks", value: $tracks, in: 1...8)
            Stepper("\(bars) bars of 96 steps", value: $bars, in: 1...64)
            Stepper(String(format: "tempo $%02X", tempo), value: $tempo, in: 1...0xFF)
            Stepper("EDL \(edl) (echo buffer $\(String(format: "%04X", CTSongEcho.buffer(edl: edl).lowerBound)))", value: $edl, in: 0...15)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Create") {
                    guard let samples else { return }
                    let list: [CTSongTemplate.Track] = (0..<tracks).map { CTSongTemplate.Track(slot: min($0, samples.count - 1)) }
                    var o = CTSongTemplate.Options(samples: samples, tracks: list, steps: 96 * bars)
                    o.tempo = tempo
                    o.edl = edl
                    create(song, o)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(samples == nil)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

/// A MIDI file chosen for the Import MIDI sheet.
private struct MIDIPick: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

/// Import MIDI (CTMIDIImport, docs/music_tracker.md): the file's channels
/// and programs, the program → sample table, channel 10 as a drum kit, the
/// grid and transpose; a live conversion shows the voices, tempo and rounding
/// or why it is refused, and Import checks the budgets with rom.samples.
private struct MIDIImportSheet: View {
    let store: ProjectStore
    let url: URL
    @State var song: Int
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: Result<CTMIDIFile, Error>?
    @State private var programs: [Int: Int] = [:]
    @State private var drumKeys: [Int: Int] = [:]
    @State private var drums = true
    @State private var grid = 3
    @State private var transpose = 0
    @State private var loop = true
    @State private var failure: String?

    /// Programs at the notes of each channel (channel 10 apart), and channel 10's keys.
    private var used: (programs: [Int], keys: [Int], channels: [Int: Int]) {
        guard case .success(let f)? = file else { return ([], [], [:]) }
        var program = [Int](repeating: 0, count: 16), programs = Set<Int>(), keys = Set<Int>(), channels: [Int: Int] = [:]
        for e in f.events {
            switch e.kind {
            case .program(let c, let p): program[c] = p
            case .noteOn(let c, let k, _):
                channels[c + 1, default: 0] += 1
                if c == CTMIDIImport.percussionChannel && drums { keys.insert(k) } else { programs.insert(program[c]) }
            default: break
            }
        }
        return (programs.sorted(), keys.sorted(), channels)
    }

    /// "1 (12 notes), 10 (4 notes)": its own function for CI's older type checker (Xcode 26.6).
    private func channelList(_ channels: [Int: Int]) -> String {
        var parts: [String] = []
        for c in channels.keys.sorted() { parts.append("\(c) (\(channels[c] ?? 0) notes)") }
        return parts.joined(separator: ", ")
    }

    private var options: CTMIDIImport.Options {
        var o = CTMIDIImport.Options()
        // Every program the file plays maps to what its stepper shows (sample 1 until changed).
        // Typed closures keep these cheap for CI's older type checker (Xcode 26.6).
        let pairs: [(Int, Int)] = used.programs.map { (p: Int) -> (Int, Int) in (p, programs[p] ?? 1) }
        o.programs = Dictionary(uniqueKeysWithValues: pairs)
        o.grid = grid
        o.transpose = transpose
        o.loop = loop
        if drums {
            o.drums = used.keys.prefix(CTDrumKit.padCount).map { (k: Int) -> CTMIDIImport.DrumPad in
                CTMIDIImport.DrumPad(key: k, sample: drumKeys[k] ?? 1)
            }
        }
        return o
    }

    var body: some View {
        let u = used
        VStack(spacing: 0) {
        Form {
            Section(url.lastPathComponent) {
                switch file {
                case .success(let f)?:
                    Text("format \(f.format), \(f.division) ticks a quarter; channels \(channelList(u.channels))")
                        .font(.caption)
                case .failure(let e)?: Text("\(e)").foregroundStyle(.red)
                case nil: ProgressView()
                }
                Stepper(String(format: "Build into song $%02X", song), value: $song, in: 0...(CTSongISA.romSongCount - 1))
            }
            Section("Programs → samples (Audio_SampleTable numbers; 63 on for rom.samples' appended ones)") {
                ForEach(u.programs, id: \.self) { p in
                    Stepper("program \(p) → sample \(programs[p] ?? 1)", value: Binding(get: { programs[p] ?? 1 }, set: { programs[p] = $0 }),
                            in: 1...CTSongISA.sampleNumberMax)
                }
            }
            Section("Channel 10") {
                Toggle("as a drum kit (each key a pad, played at note 60)", isOn: $drums)
                if drums {
                    ForEach(u.keys.prefix(CTDrumKit.padCount), id: \.self) { k in
                        Stepper("key \(k) → sample \(drumKeys[k] ?? 1)", value: Binding(get: { drumKeys[k] ?? 1 }, set: { drumKeys[k] = $0 }),
                                in: 1...CTSongISA.sampleNumberMax)
                    }
                }
            }
            Section("Timing and notes") {
                Picker("grid", selection: $grid) {
                    ForEach([3, 6, 12, 24], id: \.self) { Text("\($0) steps").tag($0) }
                }
                Stepper("transpose \(transpose) semitones", value: $transpose, in: -48...48)
                Toggle("loop back to the start at the end", isOn: $loop)
            }
        }
        .formStyle(.grouped)
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            if case .success(let f)? = file {
                switch Result(catching: { try CTMIDIImport.convert(f, options: options) }) {
                case .success(let (_, r)):
                    Text(summary(r)).font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                case .failure(let e):
                    Text("\(e)").foregroundStyle(.red).font(.caption)
                }
            }
            if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Import") {
                    do {
                        let (rel, _) = try store.importMIDI(url, song: song, options: options)
                        done(rel)
                        dismiss()
                    } catch { failure = "\(error)" }
                }
                .keyboardShortcut(.defaultAction)
                .disabled((try? file?.get()) == nil)
            }
        }
        .padding()
        }
        .frame(width: 520, height: 640)
        .onAppear {
            file = Result { try CTMIDIFile(bytes: [UInt8](try Data(contentsOf: url))) }
        }
    }

    private func summary(_ r: CTMIDIImport.Report) -> String {
        // Built line by line for CI's older type checker (Xcode 26.6).
        var lines: [String] = []
        for v in r.voices {
            let kit: String = v.drums ? " (drum kit)" : ""
            var line: String = "voice \(v.voice): channel \(v.channel)\(kit), \(v.notes) notes"
            if v.droppedFromChords > 0 { line += ", \(v.droppedFromChords) chord notes dropped" }
            lines.append(line)
        }
        for t in r.tempo {
            lines.append(String(format: "step %d: %.1f BPM → tempo $%02X (plays %.1f)", t.step, t.bpm, t.byte, t.playedBPM))
        }
        let sampleList: String = r.samples.map { (n: Int) -> String in String(n) }.joined(separator: " ")
        lines.append(String(format: "@samples %@; %d steps, %d bytes; rounding ≤ %.2f steps (%.1f ms)",
                            sampleList, r.steps, r.sequenceBytes, r.maxErrorSteps, r.maxErrorMilliseconds))
        return lines.joined(separator: "\n")
    }
}

enum SongView: String, CaseIterable, Identifiable {
    case listing = "Listing", tracker = "Tracker", pianoRoll = "Piano Roll", instruments = "Instruments", echo = "Echo"
    var id: String { rawValue }
}

private struct SongEditor: View {
    let store: ProjectStore
    let project: CTProject
    let rel: String
    @State private var text = ""
    @State private var saved = ""
    @State private var target = 0
    @State private var builds = false
    @State private var view = LaunchArguments.value("--music-view").flatMap { v in
        SongView.allCases.first { $0.rawValue.lowercased() == v.lowercased() }
    } ?? .listing
    @State private var model = SongModel()
    @State private var selectedNote: String?
    @State private var track = 0
    @Environment(\.undoManager) private var undoManager

    private var playingTitle: String { String(format: "%@ as song $%02X", (rel as NSString).lastPathComponent, target) }

    /// The step playing now, while this listing plays.
    private var cursor: Int? {
        guard store.audio.nowPlaying == playingTitle else { return nil }
        return model.step(atSeconds: store.audio.status.seconds)
    }

    private var editing: SongEditing {
        SongEditing(store: store, rel: rel, model: model, undoManager: undoManager) { [self] new in
            text = new
            saved = new
        }
    }

    private var assembled: Result<(song: CTSong, tables: CTSongTables), Error> {
        Result {
            let (data, tables) = try CTSongListing.assembleSong(text)
            return (try CTSong(data: data), tables)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text((rel as NSString).lastPathComponent).font(.headline)
                Spacer()
                Toggle("Build into song", isOn: $builds).toggleStyle(.checkbox)
                Stepper(String(format: "$%02X", target), value: $target, in: 0...(CTSongISA.romSongCount - 1)).disabled(!builds)
                Button("Play", systemImage: "play.fill", action: play)
                .help(String(format: "Play this listing (as edited) in place of song $%02X", target))
                .keyboardShortcut("p", modifiers: .command)
                .disabled((try? assembled.get()) == nil)
                Button("Save") {
                    if store.writeSongListing(rel, text) { saved = text }
                    store.setSongTarget(rel, song: builds ? target : nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(text == saved && builds == (current != nil) && (current ?? target) == target)
            }
            summary
            Picker("", selection: $view) {
                ForEach(SongView.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 520)
            switch view {
            case .listing:
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
            case .tracker:
                TrackerGridView(model: model, edit: editing, selected: $selectedNote, cursor: cursor)
                Divider()
                NoteInspector(model: model, edit: editing, selected: $selectedNote, track: model.note(selectedNote)?.track ?? track)
            case .pianoRoll:
                PianoRollView(model: model, edit: editing, selected: $selectedNote, track: $track, cursor: cursor)
                Divider()
                NoteInspector(model: model, edit: editing, selected: $selectedNote, track: track)
            case .instruments:
                InstrumentRackView(store: store, model: model, edit: editing, target: target)
            case .echo:
                EchoDesignerView(store: store, model: model, edit: editing, play: play)
            }
        }
        .padding()
        .onAppear {
            text = store.readText(rel) ?? ""
            saved = text
            if let current { builds = true; target = current }
            model.update(text)
            if let first = model.timeline?.tracks.first(where: { $0.stop != "none" }) { track = first.index }
        }
        .onChange(of: text) { _, new in model.update(new) }
        .onChange(of: selectedNote) { _, id in if let n = model.note(id) { track = n.track } }
    }

    /// Play the listing as edited (saved or not) in place of the target song.
    private func play() {
        store.playListing(text, replacing: target, title: (rel as NSString).lastPathComponent)
    }

    private func tableSummary(_ t: CTSongTables) -> String {
        let samples = t.samples.map { $0.isEmpty ? "samples: none" : "samples: " + $0.map(String.init).joined(separator: " ") }
        let echo = t.echo.map { String(format: "echo delay %d, Arg1 $%02X", $0[0] & 0x0F, $0[1]) }
        let drums = t.drums.map { $0.allSatisfy { $0 == 0 } ? "no drum kit" : "drum kit" }
        let parts = [samples, echo, drums].compactMap { $0 }
        return parts.isEmpty ? "per-song tables: left as they are" : parts.joined(separator: "; ")
    }

    private var current: Int? { project.project.rom?.songs.first { $0.listing == rel }?.song }

    @ViewBuilder private var summary: some View {
        switch assembled {
        case .success(let (song, tables)):
            let reached = (try? song.walk()) ?? [:]
            let tracksA = song.tracks.prefix(8).filter { $0 != song.noTrack }.count
            let tracksB = song.tracks.suffix(8).filter { $0 != song.noTrack }.count
            let notes = reached.keys.filter { song.data[$0] < CTSongISA.firstTie }.count
            Text("\(song.data.count) bytes (at most \(CTSongISA.maxLength)); tracks: set A \(tracksA), set B \(tracksB); "
                 + "\(reached.count) statements, \(notes) notes"
                 + (song.data.count >= CTSongISA.songRoom ? "; overwrites the $2F00 effects block while it plays" : "")
                 + "\n" + tableSummary(tables))
                .font(.caption).foregroundStyle(.secondary)
        case .failure(let error):
            Label(String(describing: error), systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
        }
    }
}

/// .akao.json tracker scores (the Studio's own format).
private struct TrackerScoresView: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?

    var body: some View {
        EntityListView(title: "Music", ids: project.tracks.keys.sorted(),
                       selection: $selection) { id in
            if let t = project.tracks[id] {
                EditorHost(entity: t, apply: { store.updateTrack($0) }) { $t in
                    ScrollView {
                        Form {
                            StatField("Tempo", $t.tempo)
                            if let echo = t.echo {
                                GroupBox("Echo") {
                                    Text("edl \(echo.edl) efb \(echo.efb) evoll \(echo.evoll) evolr \(echo.evolr)")
                                        .font(.system(.caption, design: .monospaced))
                                    Text("fir [\(echo.fir.map(String.init).joined(separator: ", "))]")
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                            ForEach(Array(t.tracks.enumerated()), id: \.offset) { i, part in
                                GroupBox("Track \(i) — voice \(part.voice) program \(part.program)") {
                                    Text("\(part.events.count) events")
                                        .foregroundStyle(.secondary)
                                    if let first = part.events.first {
                                        Text("first: t=\(first.t) dur=\(first.dur) note=\(first.note)")
                                            .font(.system(.caption, design: .monospaced))
                                    }
                                    Stepper("Program \(part.program)", value: Binding(
                                        get: { $t.wrappedValue.tracks[i].program },
                                        set: { v in $t.wrappedValue.tracks[i].program = v }), in: 0...99)
                                }
                            }
                            ApplyBar(apply: { store.updateTrack($t.wrappedValue) })
                        }
                        .padding()
                    }
                }
                .id(id)
            }
        }
    }
}
