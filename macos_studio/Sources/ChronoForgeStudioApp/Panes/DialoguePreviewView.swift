// DialoguePreviewView.swift — the in-game dialogue box for one message: the
// ROM's font, frame and colours through the PPU (ChronoForgeMetal, or the
// reference renderer without Metal), page stepping, frame-by-frame playback
// at the field's own pace (one glyph a frame, waits of 15 frames) scaled by a
// viewer speed, and warnings for lines past the frame. Reused by the item
// description editor and the Scene Director's message statements.
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

    @State private var page = 0
    @State private var playing = false
    @State private var speed = 1.0
    @State private var style = 0
    @State private var press = 30
    @State private var player = DialoguePlayer()

    private struct Built {
        var layout: CTDialogueLayout?
        var box: CTDialogueBox?
        var problem: String?
    }

    private func build() -> Built {
        guard let romPath else { return Built(problem: "Choose a ROM (Music or Scenes) to preview the dialogue box") }
        guard let assets = DialogueAssets.load(romPath) else { return Built(problem: "\(romPath): not a Chrono Trigger ROM") }
        let settings = CTDialogueSettings.placeholder(press: press, place: place)
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
            return Built(layout: layout, box: CTDialogueBox(rom: assets.rom, style: style))
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
                                   speed: speed, player: player, scale: scale)
                    .frame(width: 256 * scale, height: CGFloat(CTDialogueROM.bandLines) * scale)
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
                overflowWarnings(layout)
            } else {
                Text(built.problem ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onChange(of: source) { _, _ in page = 0; playing = false }
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
        }
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
        let picture: (Int) -> PPUFrame = { n in
            var f = blank
            let t = min(max(0, n), layout.frames.count - 1)
            CTDialogueBox.storeText(&f, layout, through: t)
            let s = layout.frames[t]
            CTDialogueBox.applyBand(&f, open: s.open, place: s.place)
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
