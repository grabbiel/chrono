// MapEditorViews.swift — Module 7, the Multi-Plane Map Editor: the field
// picture of a location on the SNES PPU (layer and colour-math toggles, zoom,
// pan, the tileset's animations running), the collision painter over the
// tile-property plane, metatile painting from the tileset and exit placement.
// The logic lives in Core (LocationScene, CTTileProps, CTTilePropsPlane);
// docs/maps.md describes the data.
import SwiftUI
import ChronoForgeCore
import ChronoForgeMetal

struct TilePoint: Equatable { var x: Int, y: Int }

// MARK: - The PPU canvas

/// The field picture at the camera, 256 x 224, presented at `zoom`. Palette
/// cycles and tile animations run per frame; an edit re-renders the frame.
struct LocationPPUView: NSViewRepresentable {
    let map: GameMap
    let assets: LocationScene.Assets
    let assetsKey: String
    let show: LocationScene.Show
    let cameraX: Int, cameraY: Int
    let frame: Int
    let animate: Bool
    let onPan: (Int, Int) -> Void

    /// What the picture depends on (tile properties and exits are drawn by the overlay).
    struct Key: Equatable {
        var layers: [GameMap.Layer], settings: GameMap.Settings?, location: GameMap.Location?, treasure: [GameMap.Treasure]?
        var width: Int, height: Int, assets: String, show: LocationScene.Show, x: Int, y: Int, frame: Int, animate: Bool
    }

    @MainActor final class Coordinator {
        var key: Key?
        var player: TilesetPlayer?
        var shownFrames: [Int] = []
        var start = 0
        var onPan: ((Int, Int) -> Void)?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else { return NSView() }
        configure(view, context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? SNESPPUView { configure(view, context.coordinator) }
    }

    private func configure(_ view: SNESPPUView, _ c: Coordinator) {
        c.onPan = onPan
        let key = Key(layers: map.layers, settings: map.settings, location: map.location, treasure: map.treasure,
                      width: map.width, height: map.height, assets: assetsKey, show: show, x: cameraX, y: cameraY,
                      frame: frame, animate: animate)
        guard c.key != key else { return }
        let restart = c.key?.assets != key.assets || c.key?.animate != key.animate
        c.key = key
        let base = TilesetScene.cgram(assets.palette)
        if restart {
            c.player = animate ? assets.t12.map { TilesetPlayer(tileset: $0, palette: assets.palette, cgram: base) } : nil
            c.start = view.frameCount
        }
        view.picture = LocationScene.frame(map, assets: assets, cgram: c.player?.cgram ?? base, cameraX: cameraX, cameraY: cameraY,
                                           frame: frame, animFrames: c.player?.animator.frames, show: show)
        c.shownFrames = c.player?.animator.frames ?? []
        let t12 = assets.t12, anim = assets.animTiles
        view.tick = { [weak c] picture, n in
            guard let c, var player = c.player, let t12 else { return }
            player.advance(to: n - c.start)
            c.player = player
            if picture.cgram != player.cgram { picture.cgram = player.cgram }
            let frames = player.animator.frames
            if frames != c.shownFrames {
                TilesetScene.applyTileAnimations(&picture, t12, animTiles: anim, frames: frames)
                c.shownFrames = frames
            }
        }
        view.onScroll = { [weak c] dx, dy in c?.onPan?(-Int(dx), -Int(dy)) }
    }
}

// MARK: - Collision colours (Module 7 spec)

enum CollisionStyle {
    static func color(_ w: CTTileProps.Walk) -> Color? {
        switch w {
        case .plane1: return Color(red: 0.08, green: 0.16, blue: 0.62)       // walkable, plane 1: dark blue
        case .plane2: return Color(red: 0.45, green: 0.76, blue: 1.0)        // plane 2: light blue
        case .transition: return Color(white: 0.6)                            // transition: gray
        case .solid: return Color(red: 1.0, green: 0.42, blue: 0.72)         // solid: pink
        case .neutral: return nil                                             // no level: only blocks a leader on level 3
        }
    }

    /// Half B's area in a tile for the shapes that name it (slopes drawn schematically).
    static func halfB(_ shape: Int, _ r: CGRect) -> Path {
        let w = r.width / 2, h = r.height / 2
        switch shape {
        case 1: return Path(r)
        case 0x18: return Path(CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
        case 0x19: return Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
        case 0x1A: return Path(CGRect(x: r.minX, y: r.midY, width: w, height: h))
        case 0x1B: return Path(CGRect(x: r.midX, y: r.midY, width: w, height: h))
        case 0x1C: return Path(CGRect(x: r.midX, y: r.minY, width: w, height: h))
        case 0x1D: return Path(CGRect(x: r.minX, y: r.minY, width: w, height: h))
        default:
            var p = Path()
            p.move(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: shape & 1 == 0 ? CGPoint(x: r.maxX, y: r.minY) : CGPoint(x: r.minX, y: r.minY)); p.closeSubpath()
            return p
        }
    }

    /// An arrow for a push tile: direction 0 up, 1 down, 2 left, 3 right; longer for faster.
    static func arrow(direction: Int, speed: Int, in r: CGRect) -> Path {
        let len = r.width * (0.2 + 0.1 * CGFloat(speed))
        let (dx, dy): (CGFloat, CGFloat) = [(0, -1), (0, 1), (-1, 0), (1, 0)][direction & 3]
        let c = CGPoint(x: r.midX, y: r.midY)
        let tip = CGPoint(x: c.x + dx * len, y: c.y + dy * len), tail = CGPoint(x: c.x - dx * len, y: c.y - dy * len)
        var p = Path()
        p.move(to: tail); p.addLine(to: tip)
        let back = r.width * 0.15
        p.move(to: CGPoint(x: tip.x - dx * back - dy * back, y: tip.y - dy * back - dx * back)); p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - dx * back + dy * back, y: tip.y - dy * back + dx * back))
        return p
    }
}

// MARK: - The editor

struct MapEditor: View {
    let store: ProjectStore
    let project: CTProject
    @Binding var map: GameMap

    enum Tool: String, CaseIterable, Identifiable {
        case pan = "Pan", metatiles = "Metatiles", collision = "Collision", exits = "Exits"
        var id: String { rawValue }
    }

    enum Brush: String, CaseIterable, Identifiable {
        case plane1 = "Plane 1", plane2 = "Plane 2", transition = "Transition", solid = "Solid", neutral = "No level"
        case push = "Push", overhead = "Overhead", objectWall = "Object wall", clear = "Clear flags"
        var id: String { rawValue }
        var walk: CTTileProps.Walk? {
            switch self {
            case .plane1: return .plane1
            case .plane2: return .plane2
            case .transition: return .transition
            case .solid: return .solid
            case .neutral: return .neutral
            default: return nil
            }
        }
    }

    @State private var assets: LocationScene.Assets?
    @State private var assetsKey = ""
    @State private var plane: CTTilePropsPlane?
    @State private var show = LocationScene.Show()
    @State private var zoom = 2
    @State private var cameraX = 0
    @State private var cameraY = 0
    @State private var frame = 0
    @State private var animate = true
    @State private var tool: Tool = .pan
    @State private var showCollision = false
    @State private var showExits = true
    @State private var brush: Brush = .plane1
    @State private var halfB = false
    @State private var pushDirection = 0
    @State private var pushSpeed = 1
    @State private var paintLayer = 1
    @State private var metatile = 0
    @State private var selectedExit: Int?
    @State private var hover: TilePoint?
    @State private var dragStart: (x: Int, y: Int)?
    @State private var dirtyProps = false

    var body: some View {
        ScrollView {
            SideBySide {
                VStack(alignment: .leading, spacing: 8) {
                    canvas
                    viewControls
                    toolControls
                }
            } inspector: {
                inspector.frame(minWidth: 280, maxWidth: 380)
            }
            .padding()
        }
        .onAppear(perform: load)
        .onChange(of: map.tileset) { _, _ in load() }
        .onChange(of: tool) { _, t in if t == .collision { showCollision = true } }
    }

    private func load() {
        assets = store.mapAssets(map)
        assetsKey = [map.tileset, assets?.t3?.id ?? "", assets?.palette?.id ?? ""].joined(separator: "|")
        plane = map.tileProps.flatMap(CTTilePropsPlane.init)
        let c = LocationScene.clampCamera(map, x: cameraX, y: cameraY)
        cameraX = c.x; cameraY = c.y
        if !map.layers.contains(where: { $0.bg == paintLayer }) { paintLayer = map.layers.first?.bg ?? 1 }
    }

    private func pan(_ dx: Int, _ dy: Int) {
        let c = LocationScene.clampCamera(map, x: cameraX + dx, y: cameraY + dy)
        cameraX = c.x; cameraY = c.y
    }

    // MARK: Canvas

    @ViewBuilder private var canvas: some View {
        let w = CGFloat(256 * zoom), h = CGFloat(224 * zoom)
        ZStack(alignment: .topLeading) {
            if let assets {
                LocationPPUView(map: map, assets: assets, assetsKey: assetsKey, show: show, cameraX: cameraX, cameraY: cameraY,
                                frame: frame, animate: animate, onPan: pan)
            } else {
                ContentUnavailableView("Tileset missing", systemImage: "photo",
                                       description: Text("Import the location tilesets, or set this map's tileset."))
            }
            overlay
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged(dragChanged).onEnded(dragEnded))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = tile(at: p)
                    case .ended: hover = nil
                    }
                }
        }
        .frame(width: w, height: h)
        .border(Color.secondary.opacity(0.4))
    }

    private func tile(at p: CGPoint) -> TilePoint? {
        let x = (cameraX + Int(p.x) / zoom) / 16, y = (cameraY + Int(p.y) / zoom) / 16
        return (0..<map.width).contains(x) && (0..<map.height).contains(y) ? TilePoint(x: x, y: y) : nil
    }

    private func rect(_ x: Int, _ y: Int, _ s: CGFloat) -> CGRect {
        CGRect(x: CGFloat(x * 16 - cameraX) * CGFloat(zoom), y: CGFloat(y * 16 - cameraY) * CGFloat(zoom), width: s, height: s)
    }

    private var overlay: some View {
        Canvas { ctx, _ in
            let s = CGFloat(16 * zoom)
            let xs = (cameraX / 16)...min(map.width - 1, (cameraX + 255) / 16)
            let ys = (cameraY / 16)...min(map.height - 1, (cameraY + 223) / 16)
            if showCollision, let plane, map.width > 0, map.height > 0 {
                for y in ys where y < plane.height {
                    for x in xs where x < plane.width {
                        let t = plane[x, y], r = rect(x, y, s)
                        if let c = CollisionStyle.color(t.walkA) { ctx.fill(Path(r), with: .color(c.opacity(0.45))) }
                        if t.hasHalfB {
                            let p = CollisionStyle.halfB(t.shape, r)
                            ctx.fill(p, with: .color((CollisionStyle.color(t.walkB) ?? .clear).opacity(0.55)))
                            ctx.stroke(p, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
                        }
                        if t.shape == 0x1E {
                            for k in 1...3 {
                                let yy = r.minY + r.height * CGFloat(k) / 4
                                ctx.stroke(Path { $0.move(to: CGPoint(x: r.minX, y: yy)); $0.addLine(to: CGPoint(x: r.maxX, y: yy)) },
                                           with: .color(.white.opacity(0.6)), lineWidth: 1)
                            }
                        }
                        if t.overheadLow || t.overheadHigh {
                            ctx.draw(Text("Z").font(.system(size: s * 0.4, weight: .bold)).foregroundColor(.yellow),
                                     at: CGPoint(x: r.minX + s * 0.22, y: r.minY + s * 0.25))
                        }
                        if t.pushSpeed > 0 {
                            ctx.stroke(CollisionStyle.arrow(direction: t.pushDirection, speed: t.pushSpeed, in: r),
                                       with: .color(.orange), lineWidth: max(1.5, s / 12))
                        }
                        if t.blocksObjects {
                            ctx.fill(Path(CGRect(x: r.maxX - s * 0.2, y: r.maxY - s * 0.2, width: s * 0.16, height: s * 0.16)),
                                     with: .color(.red))
                        }
                    }
                }
            }
            if showExits {
                for (n, e) in map.exits.enumerated() {
                    for k in 0...max(0, e.span ?? 0) {
                        let x = e.vertical == true ? e.x : e.x + k, y = e.vertical == true ? e.y + k : e.y
                        let r = rect(x, y, s)
                        ctx.fill(Path(r), with: .color(.yellow.opacity(0.25)))
                        ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(n == selectedExit ? .orange : .yellow),
                                   lineWidth: n == selectedExit ? 3 : 1.5)
                    }
                    ctx.draw(Text("\(n)→\(e.map)").font(.system(size: max(9, s * 0.3))).foregroundColor(.yellow),
                             at: CGPoint(x: rect(e.x, e.y, s).midX, y: rect(e.x, e.y, s).minY - 6))
                }
                for t in map.treasure ?? [] {
                    let r = rect(t.x, t.y, s).insetBy(dx: s * 0.3, dy: s * 0.3)
                    ctx.stroke(Path(ellipseIn: r), with: .color(.yellow), lineWidth: 2)
                }
            }
            if let hover {
                ctx.stroke(Path(rect(hover.x, hover.y, s)), with: .color(.white), lineWidth: 1)
            }
        }
    }

    // MARK: Painting

    private func dragChanged(_ v: DragGesture.Value) {
        switch tool {
        case .pan:
            if dragStart == nil { dragStart = (cameraX, cameraY) }
            let c = LocationScene.clampCamera(map, x: dragStart!.x - Int(v.translation.width) / zoom,
                                              y: dragStart!.y - Int(v.translation.height) / zoom)
            cameraX = c.x; cameraY = c.y
        case .collision:
            if let p = tile(at: v.location) { paintProps(p) }
        case .metatiles:
            paintMetatile(at: v.location)
        case .exits:
            break
        }
    }

    private func dragEnded(_ v: DragGesture.Value) {
        dragStart = nil
        if tool == .collision, dirtyProps, let plane { map.tileProps = plane.json; dirtyProps = false }
        if tool == .exits, let p = tile(at: v.location) { pickOrAddExit(p) }
    }

    private func paintProps(_ p: TilePoint) {
        guard var plane, p.x < plane.width, p.y < plane.height else { return }
        var t = plane[p.x, p.y]
        if let w = brush.walk {
            t.setWalk(w, halfB: halfB)
        } else {
            switch brush {
            case .push: t.setPush(direction: pushDirection, speed: pushSpeed)
            case .overhead: t.attrA |= 0x40; t.attrB |= 0x40
            case .objectWall: t.attrB |= 0x80
            case .clear: t.setPush(direction: 0, speed: 0); t.attrA &= ~0x40; t.attrB &= ~0xC0
            default: break
            }
        }
        guard t != plane[p.x, p.y] else { return }
        plane[p.x, p.y] = t
        self.plane = plane
        dirtyProps = true
    }

    /// The cell of layer `paintLayer` under a canvas point, where that layer scrolls.
    private func paintMetatile(at point: CGPoint) {
        guard let k = map.layers.firstIndex(where: { $0.bg == paintLayer }) else { return }
        let l = map.layers[k], size = LocationScene.layerSize(map, l)
        guard size.width > 0, size.height > 0 else { return }
        let sc = LocationScene.scroll(map, layer: l.bg, cameraX: cameraX, cameraY: cameraY, frame: frame)
        let x = ((sc.x + Int(point.x) / zoom) / 16 % size.width + size.width) % size.width
        let y = ((sc.y + Int(point.y) / zoom) / 16 % size.height + size.height) % size.height
        let i = y * size.width + x
        guard i < l.metatiles.count, l.metatiles[i] != metatile else { return }
        map.layers[k].metatiles[i] = metatile
        // HiBits bits 0 / 1 carry bit 8 of layers 1 / 2 (Map_WriteRow1 / Map_WriteRow2).
        if l.bg <= 2, var plane, x < plane.width, y < plane.height {
            let bit: UInt8 = l.bg == 1 ? 1 : 2, j = y * plane.width + x
            plane.hiBits[j] = metatile >= 256 ? plane.hiBits[j] | bit : plane.hiBits[j] & ~bit
            self.plane = plane
            map.tileProps = plane.json
        }
    }

    private func exitTiles(_ e: GameMap.Exit) -> [TilePoint] {
        (0...max(0, e.span ?? 0)).map { k in e.vertical == true ? TilePoint(x: e.x, y: e.y + k) : TilePoint(x: e.x + k, y: e.y) }
    }

    private func pickOrAddExit(_ p: TilePoint) {
        if let n = map.exits.indices.last(where: { exitTiles(map.exits[$0]).contains(p) }) {
            selectedExit = n
            return
        }
        let dest = map.exits.last?.map ?? map.id
        map.exits.append(GameMap.Exit(x: p.x, y: p.y, map: dest, toX: 0, toY: 0, span: 0, vertical: false, facing: 0,
                                      facingBit7: false))
        selectedExit = map.exits.count - 1
    }

    // MARK: Controls

    private var viewControls: some View {
        HStack(spacing: 12) {
            Toggle("BG1", isOn: $show.bg1)
            Toggle("BG2", isOn: $show.bg2)
            Toggle("BG3", isOn: $show.bg3)
            Toggle("Sprites", isOn: $show.obj)
            Toggle("Colour math", isOn: $show.colorMath)
            Divider().frame(height: 16)
            Toggle("Collision", isOn: $showCollision)
            Toggle("Exits", isOn: $showExits)
            Divider().frame(height: 16)
            Picker("Zoom", selection: $zoom) { ForEach(1...4, id: \.self) { Text("\($0)×").tag($0) } }
                .frame(width: 110)
            Toggle("Animate", isOn: $animate)
            Stepper("Frame \(frame)", value: $frame, in: 0...9999, step: 16)
                .help("Own-step drift of layers 2 and 3 after this many frames")
        }
        .toggleStyle(.checkbox)
        .font(.caption)
    }

    @ViewBuilder private var toolControls: some View {
        Picker("Tool", selection: $tool) { ForEach(Tool.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
        switch tool {
        case .pan:
            Text("Drag or scroll to pan. Camera \(cameraX), \(cameraY) px.").font(.caption).foregroundStyle(.secondary)
        case .collision:
            if plane == nil {
                Text("This map has no tile properties.").foregroundStyle(.secondary)
            } else {
                HStack {
                    Picker("Brush", selection: $brush) { ForEach(Brush.allCases) { Text($0.rawValue).tag($0) } }
                        .frame(width: 200)
                    if brush.walk != nil { Toggle("Half B", isOn: $halfB).toggleStyle(.checkbox) }
                    if brush == .push {
                        Picker("Direction", selection: $pushDirection) {
                            Text("Up").tag(0); Text("Down").tag(1); Text("Left").tag(2); Text("Right").tag(3)
                        }.frame(width: 160)
                        Picker("Speed", selection: $pushSpeed) {
                            Text("Off").tag(0); Text("$08").tag(1); Text("$10").tag(2); Text("$20").tag(3)
                        }.frame(width: 140)
                    }
                }
                legend
            }
        case .metatiles:
            metatilePicker
        case .exits:
            Text("Click an exit to select it, or an empty tile to add one.").font(.caption).foregroundStyle(.secondary)
            if let n = selectedExit, n < map.exits.count { exitForm(n) }
        }
    }

    private var legend: some View {
        HStack(spacing: 10) {
            ForEach([CTTileProps.Walk.plane1, .plane2, .transition, .solid], id: \.self) { w in
                HStack(spacing: 4) {
                    Rectangle().fill(CollisionStyle.color(w)!).frame(width: 12, height: 12)
                    Text(w.rawValue)
                }
            }
            Text("Z overhead · arrows push · red object wall · lines stair").foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    @ViewBuilder private var metatilePicker: some View {
        HStack {
            Picker("Layer", selection: $paintLayer) { ForEach(map.layers.map(\.bg), id: \.self) { Text("BG\($0)").tag($0) } }
                .pickerStyle(.segmented).frame(width: 200)
            Stepper("Metatile \(metatile)", value: $metatile, in: 0...(paintLayer == 3 ? 255 : 1023))
        }
        if let assets {
            let ts = paintLayer == 3 ? assets.t3 : assets.t12
            let tiles = paintLayer == 3 ? assets.t3Tiles : assets.t12Tiles
            if let ts, !tiles.isEmpty, !ts.metatiles.isEmpty {
                let sheet = TilesetScene.cgramIndices(ts, tiles: tiles)
                let image = cgramImage(width: sheet.width, height: sheet.height, indices: sheet.indices,
                                       cgram: TilesetScene.cgram(assets.palette))
                ScrollView {
                    Image(nsImage: image).interpolation(.none).resizable()
                        .frame(width: CGFloat(sheet.width * 2), height: CGFloat(sheet.height * 2))
                        .overlay(alignment: .topLeading) {
                            Rectangle().stroke(Color.yellow, lineWidth: 2)
                                .frame(width: 32, height: 32)
                                .offset(x: CGFloat(metatile % 16 * 32), y: CGFloat(metatile / 16 * 32))
                        }
                        .onTapGesture { p in
                            let n = Int(p.y) / 32 * 16 + Int(p.x) / 32
                            if n < ts.metatiles.count { metatile = n }
                        }
                }
                .frame(height: 260)
            } else {
                Text("No metatiles for BG\(paintLayer).").foregroundStyle(.secondary)
            }
        }
    }

    private func exitForm(_ n: Int) -> some View {
        GroupBox("Exit \(n)") {
            Form {
                StatField("X", $map.exits[n].x)
                StatField("Y", $map.exits[n].y)
                StatField("Span", Binding(get: { map.exits[n].span ?? 0 }, set: { map.exits[n].span = max(0, min(127, $0)) }))
                Toggle("Down the column", isOn: Binding(get: { map.exits[n].vertical ?? false }, set: { map.exits[n].vertical = $0 }))
                Picker("Destination", selection: $map.exits[n].map) {
                    ForEach(project.maps.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
                StatField("Arrive X", $map.exits[n].toX)
                StatField("Arrive Y", $map.exits[n].toY)
                StatField("Facing", Binding(get: { map.exits[n].facing ?? 0 }, set: { map.exits[n].facing = max(0, min(15, $0)) }))
                Button("Delete Exit", role: .destructive) { map.exits.remove(at: n); selectedExit = nil }
            }
        }
        .frame(maxWidth: 420)
    }

    // MARK: Inspector

    private var inspector: some View {
        Form {
            Section("Map") {
                TextField("Name", text: $map.name)
                TextField("Tileset", text: $map.tileset)
                Text("\(map.width) × \(map.height) · " + map.layers.map { l in
                    let s = LocationScene.layerSize(map, l); return "BG\(l.bg) \(s.width)×\(s.height)"
                }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            }
            if let hover { Section("Tile \(hover.x), \(hover.y)") { tileInfo(hover) } }
            if let l = map.location {
                Section("Location header") {
                    mono(String(format: "music $%02X · Tileset12 %@ · Tileset3 %@", l.music,
                                l.tileset12 == CTMapROM.none ? "—" : "\(l.tileset12)", l.tileset3 == CTMapROM.none ? "—" : "\(l.tileset3)"))
                    mono("palette \(l.palette) · events \(l.events)")
                    mono(l.limits.first.map { $0 & CTMapROM.limitsNone != 0 } == true ? "camera: layer 1's edges"
                         : "camera: columns \(l.limits[0])–\(l.limits[2]), rows \(l.limits[1])–\(l.limits[3])")
                }
            }
            Section("Screens") {
                let r = LocationScene.registers(map, show: show)
                mono(String(format: "TM $%02X · TS $%02X · CGWSEL $%02X · CGADSUB $%02X", r.tm, r.ts, r.cgwsel, r.cgadsub))
                if let s = map.settings {
                    let s2 = CTMapROM.ownStep(s.move2), s3 = CTMapROM.ownStep(s.move3)
                    mono("BG2 " + (s.halfRate2 ? "half rate" : "with the camera") + (s.ownStep2 ? ", own step" : "")
                         + " (\(s2.x), \(s2.y))/16 px")
                    mono("BG3 " + (s.ownStep3 ? "own step" : "with the camera") + " (\(s3.x), \(s3.y))/16 px")
                }
            }
            if let t = map.treasure, !t.isEmpty {
                Section("Treasure (\(t.count))") {
                    ForEach(Array(t.enumerated()), id: \.offset) { _, c in mono("(\(c.x), \(c.y)) " + treasureName(c.contents)) }
                }
            }
            let problems = LocationScene.invariants(map, project: project)
            if !problems.isEmpty {
                Section("Checks") { ForEach(problems, id: \.self) { Text($0).foregroundStyle(.red).font(.caption) } }
            }
            ApplyBar(apply: { store.updateMap(map) })
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func tileInfo(_ p: TilePoint) -> some View {
        let cells = map.layers.compactMap { l -> String? in
            let s = LocationScene.layerSize(map, l)
            guard p.x < s.width, p.y < s.height, p.y * s.width + p.x < l.metatiles.count else { return nil }
            return "BG\(l.bg) \(l.metatiles[p.y * s.width + p.x])"
        }
        mono(cells.joined(separator: " · "))
        if let plane, p.x < plane.width, p.y < plane.height {
            let t = plane[p.x, p.y]
            mono("\(t.shapeName) · A \(t.walkA.rawValue)" + (t.hasHalfB ? " · B \(t.walkB.rawValue)" : ""))
            mono(String(format: "HiBits $%02X AttrA $%02X AttrB $%02X", t.hiBits, t.attrA, t.attrB))
            let flags = [t.pushSpeed > 0 ? "push \(["up", "down", "left", "right"][t.pushDirection]) $\(String(format: "%02X", t.pushAmount))" : nil,
                         t.overheadLow || t.overheadHigh ? "overhead" : nil, t.blocksObjects ? "object wall" : nil,
                         t.animTrigger ? "animation trigger" : nil].compactMap { $0 }
            if !flags.isEmpty { mono(flags.joined(separator: " · ")) }
        }
        if let n = map.exits.indices.last(where: { exitTiles(map.exits[$0]).contains(p) }) {
            mono("exit \(n) → \(map.exits[n].map) (\(map.exits[n].toX), \(map.exits[n].toY))")
        }
    }

    private func treasureName(_ contents: Int) -> String {
        switch CTMapROM.TreasureKind(contents: contents) {
        case .gold(let g): return "\(g) G"
        case .empty: return "nothing"
        case .item(let i): return String(format: "item $%03X", i)
        }
    }

    private func mono(_ s: String) -> some View { Text(s).font(.system(.caption, design: .monospaced)) }
}
