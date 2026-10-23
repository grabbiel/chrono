// PPUDemosWindow.swift — the PPU Demos window: the synthetic slice 2 scenes
// (PPUPreviewScenes.Demo) animated through SNESPPUView at 60 fps, drawn
// at 512 columns where they have hi-res lines and with the overscan border
// for that demo. Opened from the Window menu or with `--ppu-demo <slug>`.
import SwiftUI
import ChronoForgeCore
import ChronoForgeMetal

struct PPUDemosWindow: View {
    @State private var demo: PPUPreviewScenes.Demo

    init(initial: String? = nil) {
        let match = PPUPreviewScenes.Demo.allCases.first { $0.slug == initial || $0.rawValue == initial }
        _demo = State(initialValue: match ?? .hdmaGradient)
    }

    var body: some View {
        NavigationSplitView {
            List(PPUPreviewScenes.Demo.allCases, selection: Binding(get: { demo }, set: { if let d = $0 { demo = d } })) { d in
                Text(d.rawValue).tag(d)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            PPUDemoMetalView(demo: demo)
                .id(demo)
                .frame(minWidth: 512, minHeight: 478)
                .navigationTitle(demo.rawValue)
        }
    }
}

/// Window menu item that opens the PPU Demos window.
struct PPUDemosMenuButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View { Button("PPU Demos") { openWindow(id: "ppu-demos") } }
}

/// One demo on SNESPPUView: the base picture is built once and animated per frame.
struct PPUDemoMetalView: NSViewRepresentable {
    let demo: PPUPreviewScenes.Demo

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else {
            return NSView()
        }
        let demo = demo
        view.renderOptions = PPUPreviewScenes.options(demo)
        view.picture = PPUPreviewScenes.demo(demo)
        view.tick = { picture, n in PPUPreviewScenes.animate(demo, &picture, frame: n) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
