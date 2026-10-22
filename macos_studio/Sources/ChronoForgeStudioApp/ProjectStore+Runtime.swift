// ProjectStore+Runtime.swift — the Play window's session: a CTFieldRuntime
// for one ROM location under a CTFieldDebugger, the project's map picture
// for it, the keys held, and the flags to start with (docs/runtime.md).
import Foundation
import AppKit
import ChronoForgeCore

@MainActor
@Observable
final class RuntimeSession {
    let rom: [UInt8]
    let registry: CTStoryRegistry?
    private(set) var location: Int
    private(set) var debugger: CTFieldDebugger
    private(set) var map: GameMap?
    private(set) var assets: LocationScene.Assets?
    var running = false
    /// Bumped as the field changes (every few frames while running), for the inspector.
    private(set) var revision = 0
    private(set) var status = ""
    private(set) var box: NSImage?
    var held: CTFieldInput = []
    /// Story bytes to set before Evt_InitObjects runs (address -> value).
    var startFlags: [Int: UInt8] = [:]
    var party: [UInt8] = [0, 0x80, 0x80]
    private var baseKey: (x: Int, y: Int)?
    private var baseFrame: PPUFrame?
    private var boxKey: Int?
    private let store: ProjectStore

    init(store: ProjectStore, rom: [UInt8], location: Int, registry: CTStoryRegistry?) throws {
        self.store = store
        self.rom = rom
        self.registry = registry
        self.location = location
        debugger = CTFieldDebugger(field: try CTFieldRuntime(rom: rom, location: location))
        try restart(location: location)
    }

    var field: CTFieldRuntime { debugger.field }

    /// A fresh field at `location` (WRAM from zero, the start flags set), keeping the breakpoints.
    func restart(location: Int) throws {
        let breakpoints = debugger.breakpoints
        let f = try CTFieldRuntime(rom: rom, location: location, party: party)
        for (a, v) in startFlags { f.vm.wram[a] = v }
        debugger = CTFieldDebugger(field: f)
        debugger.breakpoints = breakpoints
        try f.start()
        self.location = location
        loadPicture()
        running = false
        status = "loc_\(String(format: "%03d", location)) loaded: \(f.vm.pack.objectCount) objects"
        boxKey = nil; box = nil
        revision += 1
    }

    private func loadPicture() {
        map = store.project?.maps[CTMaps.id(field.location)]
        assets = map.flatMap { store.mapAssets($0) }
        baseKey = nil; baseFrame = nil
    }

    /// One frame with the keys held; a breakpoint pauses.
    func stepFrame() {
        do {
            let before = field.location
            if let hit = try debugger.step(input: held) {
                running = false
                status = "frame \(hit.frame): \(Self.describe(hit.breakpoint)) — object \(hit.object) at "
                    + String(format: "$%04X (op $%02X)", hit.offset, hit.opcode)
            }
            if field.location != before { location = field.location; loadPicture() }
        } catch {
            running = false
            status = "stopped: \(error)"
        }
        if !running || field.frameCount % 6 == 0 { revision += 1 }
    }

    static func describe(_ b: CTFieldDebugger.Breakpoint) -> String {
        switch b {
        case .flag(let a, let bit):
            return String(format: "flag $%06X", a) + (bit.map { " bit \($0)" } ?? "") + " changed"
        case .instruction(let o, let obj):
            return String(format: "instruction $%04X", o) + (obj.map { " in object \($0)" } ?? "")
        }
    }

    /// The picture for the Metal view, with the location only re-built when the camera moves.
    func picture() -> PPUFrame {
        let cam = field.camera
        if baseKey?.x != cam.x || baseKey?.y != cam.y || baseFrame == nil {
            baseFrame = CTFieldPicture.base(field, map: map, assets: assets)
            baseKey = cam
        }
        updateBox()
        return CTFieldPicture.frame(field, base: baseFrame).picture
    }

    private func updateBox() {
        guard let d = field.dialogue else { if box != nil { box = nil; boxKey = nil }; return }
        let key = d.frame * 4096 + d.layout.frameCount
        guard key != boxKey else { return }
        boxKey = key
        guard let rgba = CTFieldPicture.dialogue(field) else { box = nil; return }
        box = Self.image(rgba, width: 256, height: 224)
    }

    static func image(_ rgba: [UInt8], width: Int, height: Int) -> NSImage? {
        var data = rgba
        guard let provider = CGDataProvider(data: Data(bytes: &data, count: data.count) as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    /// The registry's name for a story byte (or bit), else its address.
    func flagName(_ address: Int, bit: Int?) -> String {
        if let e = registry?.entries.first(where: { $0.address == (address & 0xFFFF) && $0.bit == bit }) {
            return e.name ?? e.symbol
        }
        return CTStoryRegistry.symbol(addr: address & 0xFFFF, bit: bit)
    }
}

extension ProjectStore {
    /// A Play session for `location` from the Scene Director's ROM.
    func runtimeSession(location: Int) throws -> RuntimeSession {
        guard let path = sceneROMPath else { throw CTEventError("no ROM: choose one in the Scenes or Music pane, or pass --rom") }
        let rom = try ProjectStore.sceneROM(path)
        return try RuntimeSession(store: self, rom: rom, location: location, registry: loadStory().registry)
    }
}
