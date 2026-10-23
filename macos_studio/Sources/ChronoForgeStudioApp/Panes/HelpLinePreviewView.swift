// HelpLinePreviewView.swift — an item's or a tech's description in the menu's
// help line (CTHelpLine): the two BG3 rows through the PPU (ChronoForgeMetal,
// or the reference renderer without Metal) with the menu's colours, live as
// the text is edited, and a fits / overflows indicator. The names come from
// the project's characters. Used by the item description editor and the Tech
// matrix.
import SwiftUI
import AppKit
import ChronoForgeCore
import ChronoForgeMetal

struct HelpLinePreviewView: View {
    enum Source: Equatable {
        /// Dialogue codec text (compiled with the ROM's dictionary, as the builder does).
        case text(String)
        /// The ROM's own description `index`.
        case rom(Int)
    }

    let source: Source
    let place: CTHelpLine.Place
    let romPath: String?
    var names: [Int: String] = [:]
    var scale: CGFloat = 2

    private struct Built {
        var line: CTHelpLine?
        var backdrop: UInt16 = 0
        var colours: [UInt16] = []
        var problem: String?
    }

    private func build() -> Built {
        guard let romPath else { return Built(problem: "Choose a ROM (Music or Scenes) to preview the help line") }
        guard let assets = DialogueAssets.load(romPath) else { return Built(problem: "\(romPath): not a Chrono Trigger ROM") }
        guard let codec = assets.codec else { return Built(problem: "The ROM's text dictionary did not load") }
        let settings = CTDialogueSettings.named(names, codec: codec)
        let mem = CTDialogueMemory(rom: assets.rom)
        let (backdrop, colours) = CTHelpLine.palette(mem)
        do {
            let line: CTHelpLine
            switch source {
            case .text(let text):
                line = try CTHelpLine.bytes(try codec.compileMessage(text), rom: assets.rom, place: place, settings: settings)
            case .rom(let index):
                line = try CTHelpLine(mem: mem, text: CTHelpLine.stringAddress(mem, place: place, index: index),
                                      place: place, settings: settings, stopAtRunaway: true)
            }
            return Built(line: line, backdrop: backdrop, colours: colours)
        } catch {
            return Built(problem: String(describing: error))
        }
    }

    var body: some View {
        let built = build()
        VStack(alignment: .leading, spacing: 4) {
            if let line = built.line {
                HelpLinePicture(line: line, backdrop: built.backdrop, colours: built.colours, scale: scale)
                    .frame(width: 256 * scale, height: 16 * scale)
                indicator(line)
            } else {
                Text(built.problem ?? "").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func indicator(_ line: CTHelpLine) -> some View {
        if line.fits {
            Label("Fits: ends at x \(line.rightX) of 256 · \(line.glyphs.count) glyphs, \(line.frames) frames",
                  systemImage: "checkmark.circle")
                .font(.caption).foregroundStyle(.green)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label("Overflows the help line", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                if line.lineCount > 1 {
                    Text("· \(line.lineCount) lines: the menu sends only the first two rows, so only line 1 shows")
                }
                if line.pastRow || line.right > CTHelpLineROM.rightLimit {
                    Text("· ends at x \(line.rightX): past column 31 the tile words spill into the next row")
                }
                if line.wraps { Text("· the 8-bit pen wraps past 255") }
                if let why = line.runaway { Text("· the game's tile loop would run away (\(why))") }
            }
            .font(.caption)
        }
    }
}

/// The help line's 16 lines through SNESPPUView (or a reference-rendered image without Metal).
private struct HelpLinePicture: NSViewRepresentable {
    let line: CTHelpLine
    let backdrop: UInt16
    let colours: [UInt16]
    let scale: CGFloat

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
        guard let sub = host.subviews.first else { return }
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        if let view = sub as? SNESPPUView {
            // The 224-line picture, placed so lines topLine..topLine+15 fill the view.
            let fullHeight = 224 * scale
            let top = CGFloat(line.topLine) * scale
            sub.frame = NSRect(x: 0, y: -(fullHeight - top - 16 * scale), width: 256 * scale, height: fullHeight)
            view.tick = nil
            view.picture = line.frame(backdrop: backdrop, colours: colours)
        } else if let image = sub as? NSImageView {
            sub.frame = NSRect(x: 0, y: 0, width: 256 * scale, height: 16 * scale)
            let rgba = line.renderStrip(backdrop: backdrop, colours: colours)
            if let png = try? PNG.writeRGBA(width: PPUFrame.width, height: 16, rgba: rgba) {
                image.image = NSImage(data: png)
            }
            image.imageScaling = .scaleAxesIndependently
        }
    }
}
