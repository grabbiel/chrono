// MusicPane.swift — CT song sequences (audio/songs/*.ctsong, ct-song/1) and
// .akao.json tracker scores.
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
        }
    }
}

/// ct-song/1 listings: edit, assemble live, choose the Audio_SongTable index
/// `rom build` writes them to, import from a ROM.
private struct SongListingsView: View {
    let store: ProjectStore
    let project: CTProject
    @State private var selection: String?
    @State private var listings: [String] = []
    @State private var pickROM = false
    @State private var importIndex = 1

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
                HStack {
                    Stepper(String(format: "song $%02X", importIndex), value: $importIndex, in: 0...(CTSongISA.romSongCount - 1))
                    Button("Import from ROM…") { pickROM = true }
                }.padding(8)
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
        .onAppear { listings = store.songListings() }
        .fileImporter(isPresented: $pickROM, allowedContentTypes: [.data], allowsMultipleSelection: false) { picked in
            guard case .success(let urls) = picked, let url = urls.first else { return }
            if let rel = store.importSong(rom: url, song: importIndex) {
                listings = store.songListings()
                selection = rel
            }
        }
    }
}

private struct SongEditor: View {
    let store: ProjectStore
    let project: CTProject
    let rel: String
    @State private var text = ""
    @State private var saved = ""
    @State private var target = 0
    @State private var builds = false

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
                Button("Save") {
                    if store.writeSongListing(rel, text) { saved = text }
                    store.setSongTarget(rel, song: builds ? target : nil)
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(text == saved && builds == (current != nil) && (current ?? target) == target)
            }
            summary
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
        }
        .padding()
        .onAppear {
            text = store.readText(rel) ?? ""
            saved = text
            if let current { builds = true; target = current }
        }
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
