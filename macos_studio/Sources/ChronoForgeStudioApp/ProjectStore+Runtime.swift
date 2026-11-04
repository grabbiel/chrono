// ProjectStore+Runtime.swift — the Play window's session: a CTFieldRuntime
// for one ROM location under a CTFieldDebugger, the project's map picture
// for it, the keys held, the flags to start with, and the field's music
// through the Studio's AKAOAudioEngine (docs/runtime.md).
import Foundation
import AppKit
import ChronoForgeCore
import ChronoForgeAudio

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
    /// Play the song the field asks for (Audio_CmdPlayMusic); off stops it.
    var musicOn = LaunchArguments.value("--play-music") != "off" { didSet { syncMusic() } }
    /// The song this session requested and its identity in the shared engine.
    private(set) var playing: Int?
    private var musicRequest: UUID?
    private var baseKey: (x: Int, y: Int, revision: Int)?
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
        syncMusic()
    }

    /// Starts the field's song when it changes (one asked for again keeps
    /// playing, not restarted), or stops ours when the music is off.
    func syncMusic() {
        guard musicOn, let song = field.music else { return stopMusic() }
        guard song != playing else { return }
        playing = song
        let rom = rom, title = String(format: "loc_%03d: song $%02X", location, song)
        let request = UUID()
        musicRequest = request
        Task { [weak self] in
            guard let self, self.musicOn, self.musicRequest == request else { return }
            await self.store.audio.play(title, owner: request) { try SPCStream.ctSong(rom: rom, song: song) }
        }
    }

    /// Stops our song, or our load still in flight (not a song another pane
    /// started since): `stop()` also discards a pending load.
    func stopMusic() {
        playing = nil
        guard let request = musicRequest else { return }
        musicRequest = nil
        store.audio.stop(ifOwnedBy: request)
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
            syncMusic()
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
        if baseKey?.x != cam.x || baseKey?.y != cam.y || baseKey?.revision != field.mapRevision || baseFrame == nil {
            baseFrame = CTFieldPicture.base(field, map: map, assets: assets)
            baseKey = (cam.x, cam.y, field.mapRevision)
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
