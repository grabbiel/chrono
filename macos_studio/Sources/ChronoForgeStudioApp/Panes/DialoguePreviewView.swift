// DialoguePreviewView.swift — the in-game dialogue box for one message: the
// ROM's font, frame and colours through the PPU (ChronoForgeMetal, or the
// reference renderer without Metal), page stepping, frame-by-frame playback
// at the field's own pace (one glyph a frame, waits of 15 frames) scaled by a
// viewer speed, and warnings for lines past the frame. The box's place as the
// field picks it (CTBoxPlace: the opcode's, or by the speaker's screen Y), a
// choice message's cursor stepped with the arrow keys (CTChoice /
// CTChoiceCursor), and the names and party from the project's characters.
// Reused by the item description editor and the Scene Director's message
// statements.
import SwiftUI
import AppKit
import MetalKit
import ChronoForgeCore
import ChronoForgeMetal

/// The ROM and its text codec, loaded once per path.
@MainActor
enum DialogueAssets {
    private static var cache: [String: (rom: [UInt8], codec: CTTextCodec?)] = [:]

    static func load(_ path: String) -> (rom: [UInt8], codec: CTTextCodec?)? {
        if let hit = cache[path] { return hit }
        guard let rom = try? ProjectStore.sceneROM(path) else { return nil }
        let codec = (try? CTTextProfile.fromROM(Data(rom))).flatMap { try? CTTextCodec(profile: $0) }
        cache[path] = (rom, codec)
        return (rom, codec)
    }

    private static var maps: [String: PPUFrame] = [:]

    /// A location's field picture with the camera at the map's centre (CTDialogueOverMap), once per project and location.
    static func map(_ project: CTProject, location: Int) -> PPUFrame? {
        let key = "\(project.url.path)/\(location)"
        if let hit = maps[key] { return hit }
        guard let m = project.maps[CTMaps.id(location)] else { return nil }
        let x = m.width * 8 - 128
        let y = m.height * 8 - 112
        guard let f = try? CTDialogueOverMap.picture(project: project, location: location, cameraX: x, cameraY: y) else { return nil }
        maps[key] = f
        return f
    }
}

struct DialoguePreviewView: View {
    enum Source: Equatable {
        /// Dialogue codec text (compiled with the ROM's dictionary).
        case text(String)
        /// A message by its table and index (OpB8_SetMsgPtr / OpBB_Msg).
        case message(table: Int, index: Int)
    }

    let source: Source
    let romPath: String?
    var place = 1
    /// Draw at 1x (256 x 224 cropped to the box) or 2x.
    var scale: CGFloat = 2
    /// A choice opcode's operand (OpC0/OpC3/OpC4): the cursor's first and last lines.
    var choice: Int? = nil
    /// Display names by character id (CTDialogueSettings.projectNames); the defaults otherwise.
    var names: [Int: String] = [:]
    /// The project whose imported locations can show behind the box.
    var project: CTProject? = nil
    /// The location to show behind the box at first (the event pack's, in a scene).
    var location: Int? = nil

    enum PlaceMode: Hashable { case given, top, bottom, speaker }

    @State private var page = 0
    @State private var playing = false
    @State private var speed = 1.0
    @State private var style = 0
    @State private var press = 30
    @State private var player = DialoguePlayer()
    @State private var placeMode = PlaceMode.given
    @State private var speakerY = 112.0
    @State private var choiceOn = false
    @State private var operand = 0x01
    @State private var cursor = 0
    @State private var party = [0, 1, 2]
    @State private var behind: Int?
    @FocusState private var focused: Bool

    private var boxPlace: Int {
        switch placeMode {
        case .given: return place
        case .top: return CTBoxPlace.top
        case .bottom: return CTBoxPlace.bottom
        case .speaker: return CTBoxPlace.place(unk30: 0, screenY: Int(speakerY))
        }
    }

    private var activeChoice: CTChoice? { choiceOn ? CTChoice(operand: operand) : nil }

    private struct Built {
        var layout: CTDialogueLayout?
        var box: CTDialogueBox?
        var map: PPUFrame?
        var problem: String?
    }

    private func build() -> Built {
        guard let romPath else { return Built(problem: "Choose a ROM (Music or Scenes) to preview the dialogue box") }
        guard let assets = DialogueAssets.load(romPath) else { return Built(problem: "\(romPath): not a Chrono Trigger ROM") }
        var settings = CTDialogueSettings.placeholder(press: press, place: boxPlace)
        if let codec = assets.codec {
            settings = CTDialogueSettings.named(names, codec: codec, party: party, press: press, place: boxPlace)
        }
        do {
            let layout: CTDialogueLayout
            switch source {
            case .text(let text):
                guard let codec = assets.codec else { return Built(problem: "The ROM's text dictionary did not load") }
                layout = try CTDialogueLayout.bytes(try codec.compileMessage(text), rom: assets.rom, settings: settings)
            case .message(let table, let index):
                let at = CTDialogueLayout.messageAddress(rom: assets.rom, table: table, index: index)
                layout = try CTDialogueLayout(mem: CTDialogueMemory(rom: assets.rom), text: at, settings: settings)
            }
            var map: PPUFrame?
            if let project, let behind { map = DialogueAssets.map(project, location: behind) }
            return Built(layout: layout, box: CTDialogueBox(rom: assets.rom, style: style), map: map)
        } catch {
            return Built(problem: String(describing: error))
        }
    }

    var body: some View {
        let built = build()
        VStack(alignment: .leading, spacing: 4) {
            if let layout = built.layout, let box = built.box {
                let pages = layout.pageCount
                let shown = min(page, pages - 1)
                DialogueBoxPicture(layout: layout, box: box, frame: layout.pageFrame(shown) ?? 0, playing: playing,
                                   speed: speed, player: player, scale: scale, cursor: activeChoice == nil ? nil : cursor,
                                   map: built.map)
                    .frame(width: 256 * scale, height: CGFloat(CTDialogueROM.bandLines) * scale)
                    .focusable()
                    .focused($focused)
                    .onTapGesture { focused = true }
                    .onKeyPress(.downArrow) { stepChoice(.down, pages: pages) }
                    .onKeyPress(.upArrow) { stepChoice(.up, pages: pages) }
                HStack(spacing: 6) {
                    Button { page = max(0, shown - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(shown == 0)
                    Text("Page \(shown + 1) of \(pages)").monospacedDigit()
                    Button { page = min(pages - 1, shown + 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(shown >= pages - 1)
                    Button {
                        playing.toggle()
                        if playing { player.restart() }
                    } label: { Image(systemName: playing ? "stop.fill" : "play.fill") }
                        .help("Play frame by frame: one glyph a frame, waits of 15 frames, keys \(press) frames after each wait")
                    Picker("", selection: $speed) {
                        Text("¼×").tag(0.25)
                        Text("½×").tag(0.5)
                        Text("1×").tag(1.0)
                        Text("2×").tag(2.0)
                        Text("4×").tag(4.0)
                    }.frame(width: 70).labelsHidden()
                    Picker("", selection: $style) {
                        ForEach(0..<CTDialogueROM.styles, id: \.self) { Text("Frame \($0 + 1)").tag($0) }
                    }.frame(width: 100).labelsHidden()
                    Text(String(format: "%d frames, %.1f s", layout.frameCount, Double(layout.frameCount) / 60))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
                placeAndChoice(pages: pages)
                overflowWarnings(layout)
            } else {
                Text(built.problem ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: source) { _, _ in page = 0; playing = false }
        .onAppear {
            if behind == nil { behind = location }
            if let choice {
                choiceOn = true
                operand = choice & 0x0F
                cursor = CTChoice(operand: choice).first
            }
        }
    }

    private func stepChoice(_ key: CTChoice.Key, pages: Int) -> KeyPress.Result {
        guard let c = activeChoice else { return .ignored }
        cursor = c.step(cursor, key)
        page = pages - 1
        playing = false
        return .handled
    }

    private func nameOf(_ id: Int) -> String { names[id] ?? CTDialogueSettings.defaultNames[id] }

    @ViewBuilder private func placeAndChoice(pages: Int) -> some View {
        HStack(spacing: 6) {
            Picker("Place", selection: $placeMode) {
                Text(place == CTBoxPlace.top ? "As set (top)" : "As set (bottom)").tag(PlaceMode.given)
                Text("Top").tag(PlaceMode.top)
                Text("Bottom").tag(PlaceMode.bottom)
                Text("By speaker").tag(PlaceMode.speaker)
            }.frame(width: 170)
                .help("OpC1/OpC3 put the box at the top, OpC2/OpC4 at the bottom; OpBB/OpC0 by the speaker's screen Y")
            if placeMode == .speaker {
                Slider(value: $speakerY, in: 0...223, step: 1).frame(width: 110)
                Text("Y \(Int(speakerY)) → \(boxPlace == CTBoxPlace.top ? "top" : "bottom")").monospacedDigit()
            }
            Toggle("Choice", isOn: $choiceOn).toggleStyle(.checkbox)
                .onChange(of: choiceOn) { _, on in
                    if on { cursor = CTChoice(operand: operand).first; page = pages - 1; focused = true }
                }
            if let c = activeChoice {
                Picker("", selection: Binding(get: { c.first }, set: { operand = $0 << 2 | max($0, c.last); cursor = $0 })) {
                    ForEach(0..<4, id: \.self) { Text("from line \($0 + 1)").tag($0) }
                }.frame(width: 110).labelsHidden()
                Picker("", selection: Binding(get: { c.last }, set: { operand = min(c.first, $0) << 2 | $0; cursor = min(c.first, $0) })) {
                    ForEach(0..<4, id: \.self) { Text("to line \($0 + 1)").tag($0) }
                }.frame(width: 100).labelsHidden()
                Text("cursor line \(cursor + 1) · ↑↓ to move").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.caption)
        if let project {
            let locations = CTDialogueOverMap.locations(project)
            Picker("Behind", selection: $behind) {
                Text("Backdrop").tag(Int?.none)
                ForEach(locations, id: \.self) { n in
                    Text(String(format: "Location $%03X", n) + (project.maps[CTMaps.id(n)].map { " \($0.name)" } ?? ""))
                        .tag(Int?.some(n))
                }
            }.frame(width: 230)
                .help(locations.isEmpty ? "Import locations (Maps) to show the field behind the box"
                                        : "The location's field picture (camera at its centre) behind the box")
                .font(.caption)
        }
        HStack(spacing: 6) {
            Text("Party").foregroundStyle(.secondary)
            ForEach(0..<3, id: \.self) { slot in
                Picker("", selection: Binding(get: { party[slot] }, set: { party[slot] = $0 })) {
                    ForEach(0..<7, id: \.self) { Text(nameOf($0)).tag($0) }
                }.frame(width: 100).labelsHidden()
            }
        }
        .font(.caption)
        .help("The names party codes $1B-$1D draw; names come from the project's characters")
    }

    @ViewBuilder private func overflowWarnings(_ layout: CTDialogueLayout) -> some View {
        let lines = Dictionary(grouping: layout.overflows, by: { [$0.page, $0.line] }).keys.sorted { $0.lexicographicallyPrecedes($1) }
        if !lines.isEmpty {
            let text = lines.prefix(4).map { "page \($0[0] + 1) line \($0[1] + 1)" }.joined(separator: ", ")
            Label("Runs past the frame (x 248): \(text)" + (lines.count > 4 ? " …" : ""), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

/// The playback clock (frames at 60 fps scaled by the speed).
@MainActor
final class DialoguePlayer {
    var position = 0.0
    func restart() { position = 0 }
}

/// The box's 80 lines through SNESPPUView (or a reference-rendered image without Metal).
private struct DialogueBoxPicture: NSViewRepresentable {
    let layout: CTDialogueLayout
    let box: CTDialogueBox
    let frame: Int
    let playing: Bool
    let speed: Double
    let player: DialoguePlayer
    let scale: CGFloat
    var cursor: Int?
    var map: PPUFrame?

    final class Coordinator {
        var key: String = ""
        var blank: PPUFrame?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let host = NSView()
        if let device = StudioMetal.device, let view = try? SNESPPUView(device: device) {
            host.addSubview(view)
        } else {
            host.addSubview(NSImageView())
        }
        return host
    }

    func updateNSView(_ host: NSView, context: Context) {
        let c = context.coordinator
        let key = "\(box.style)/\(layout.summary.uploadDigest)/\(layout.settings.place)"
        if c.key != key || c.blank == nil {
            c.key = key
            c.blank = box.blankFrame()
            player.restart()
        }
        guard !layout.frames.isEmpty else { return }
        let lines = CTDialogueBox.boxLines(place: layout.settings.place)
        // The 224-line picture, shown so the 80 box lines fill the view.
        let fullHeight = 224 * scale
        let top = CGFloat(lines.lowerBound) * scale
        guard let sub = host.subviews.first else { return }
        sub.frame = NSRect(x: 0, y: -(fullHeight - top - CGFloat(lines.count) * scale), width: 256 * scale,
                           height: fullHeight)
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        let blank = c.blank!
        let mem = box.mem
        let cursorFrom = cursor == nil ? nil : CTChoiceCursor.firstFrame(layout)
        let picture: (Int) -> PPUFrame = { [cursor, map] n in
            if let map { return box.frame(layout, at: n, over: map, cursor: cursor) }
            var f = blank
            let t = min(max(0, n), layout.frames.count - 1)
            CTDialogueBox.storeText(&f, layout, through: t)
            let s = layout.frames[t]
            CTDialogueBox.applyBand(&f, open: s.open, place: s.place)
            if let cursor, let from = cursorFrom, t >= from {
                CTChoiceCursor.apply(&f, row: cursor, mem: mem)
            }
            return f
        }
        if let view = sub as? SNESPPUView {
            if playing {
                let last = layout.frames.count - 1
                view.tick = { [player, speed] pic, _ in
                    player.position = min(Double(last), player.position + speed)
                    pic = picture(Int(player.position))
                }
            } else {
                view.tick = nil
                view.picture = picture(frame)
            }
        } else if let image = sub as? NSImageView {
            let rgba = PPUReferenceRenderer.render(picture(frame))
            image.image = Self.image(rgba)
            image.imageScaling = .scaleAxesIndependently
        }
    }

    static func image(_ rgba: [UInt8]) -> NSImage? {
        guard let png = try? PNG.writeRGBA(width: PPUFrame.width, height: 224, rgba: rgba) else { return nil }
        return NSImage(data: png)
    }
}
