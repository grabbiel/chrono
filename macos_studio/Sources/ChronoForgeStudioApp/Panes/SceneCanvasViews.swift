// SceneCanvasViews.swift — Module 8's choreography canvas: the location
// through the map canvas (LocationPPUView, from the project's imported map),
// with the raised pack's objects on it: real PC sprites, placements, walk and
// move paths, camera keyframes, save points, encounters and the field's
// treasure. Tools add and drag waypoints and keyframes and copy objects; each
// edit re-assembles the pack (CTSceneDocument).
import SwiftUI
import ChronoForgeCore

struct SceneMapCanvas: View {
    let store: ProjectStore
    let project: CTProject
    let rom: [UInt8]
    let location: Int
    let document: CTSceneDocument
    let analysis: CTSceneAnalysis
    @Binding var selection: SceneSelection
    let edit: ((inout CTSceneDocument) throws -> Void) -> Void

    enum Tool: String, CaseIterable { case select = "Select", pan = "Pan", walk = "Walk", move = "Move", camera = "Camera", place = "Place", copy = "Copy Object" }

    @State private var tool: Tool = .select
    @State private var zoom = 2
    @State private var cameraX = 0
    @State private var cameraY = 0
    @State private var dragStart: (x: Int, y: Int)?
    @State private var dragging: Int?
    @State private var dragTile: TilePoint?
    @State private var hover: TilePoint?
    @State private var allPaths = false
    @State private var assets: LocationScene.Assets?
    @State private var assetsKey = ""
    @State private var sprites: [Int: NSImage] = [:]
    @State private var note = ""

    private var map: GameMap? { project.maps.values.first { $0.rom?.location == location } }
    private var width: Int { map?.width ?? 64 }
    private var height: Int { map?.height ?? 64 }
    private var choreography: [CTSceneChoreography] { (try? document.pack()).map(CTSceneChoreography.extract) ?? [] }
    private var treasure: [CTMapROM.TreasureRecord] { (try? CTMapROM.treasureList(rom, location).records) ?? [] }

    var body: some View {
        let paths = choreography
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Tool", selection: $tool) {
                    ForEach(Tool.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 480)
                Stepper("×\(zoom)", value: $zoom, in: 1...4)
                Toggle("All paths", isOn: $allPaths).toggleStyle(.checkbox)
            }.font(.caption)
            ScrollView([.horizontal, .vertical]) {
                canvas(paths)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                if let hover { Text("tile (\(hover.x), \(hover.y))").monospacedDigit() }
                Text(note.isEmpty ? help : note).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .onAppear(perform: load)
    }

    private var help: String {
        switch tool {
        case .select: return "Click an object or a point to select it; drag a point to move it."
        case .pan: return "Drag to scroll the view."
        case .walk: return "Click: $96 WalkToTile after the selected statement (facing and walk animation)."
        case .move: return "Click: $A0 MoveToTile after the selected statement (no facing or animation)."
        case .camera: return "Click: $E7 ScrollTo after the selected statement (the view scrolls to the tile)."
        case .place: return "Click: the selected object's $8B PlaceAtTile goes there."
        case .copy: return "Click: a copy of the selected object, placed there (every statement it reaches, relabelled)."
        }
    }

    private func load() {
        if let map {
            assets = store.mapAssets(map)
            assetsKey = [map.tileset, assets?.t3?.id ?? "", assets?.palette?.id ?? ""].joined(separator: "|")
        }
        for c in Set(analysis.objects.flatMap { $0.markers.filter { $0.kind == "pc" }.map { $0.operands[0] } }) where c < CTSpriteROM.sets {
            sprites[c] = Self.pcImage(rom, set: c)
        }
        if let k = selection.object, let p = analysis.objects[k].placement { center(p.column, p.row) }
    }

    private func center(_ c: Int, _ r: Int) {
        if let map {
            let v = LocationScene.clampCamera(map, x: c * 16 - 128, y: r * 16 - 112)
            cameraX = v.x; cameraY = v.y
        }
    }

    // MARK: Drawing

    private func canvas(_ paths: [CTSceneChoreography]) -> some View {
        let w = CGFloat((map == nil || assets == nil ? width * 16 : 256) * zoom)
        let h = CGFloat((map == nil || assets == nil ? height * 16 : 224) * zoom)
        return ZStack(alignment: .topLeading) {
            if let map, let assets {
                LocationPPUView(map: map, assets: assets, assetsKey: assetsKey, show: LocationScene.Show(), cameraX: cameraX,
                                cameraY: cameraY, frame: 0, animate: false, onPan: pan)
            } else {
                Rectangle().fill(Color(white: 0.12))
            }
            overlay(paths)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { dragChanged($0, paths) }.onEnded { dragEnded($0, paths) })
                .onContinuousHover { phase in
                    if case .active(let p) = phase { hover = tile(at: p) } else { hover = nil }
                }
        }
        .frame(width: w, height: h)
        .border(Color.secondary.opacity(0.4))
        .overlay(alignment: .bottomLeading) {
            if map == nil {
                Text("Import Maps from ROM (Maps pane) to draw the location under its objects.")
                    .font(.caption).padding(4).background(.background.opacity(0.8))
            }
        }
    }

    private var picture: Bool { map != nil && assets != nil }

    private func rect(_ x: Int, _ y: Int, _ s: CGFloat) -> CGRect {
        let ox = picture ? cameraX : 0, oy = picture ? cameraY : 0
        return CGRect(x: CGFloat(x * 16 - ox) * CGFloat(zoom), y: CGFloat(y * 16 - oy) * CGFloat(zoom), width: s, height: s)
    }

    private func tile(at p: CGPoint) -> TilePoint? {
        let ox = picture ? cameraX : 0, oy = picture ? cameraY : 0
        let x = (ox + Int(p.x) / zoom) / 16, y = (oy + Int(p.y) / zoom) / 16
        return (0..<max(width, 1)).contains(x) && (0..<max(height, 1)).contains(y) ? TilePoint(x: x, y: y) : nil
    }

    private func color(_ o: CTSceneAnalysis.Object) -> Color {
        switch o.kind {
        case "save point": return .cyan
        case "encounter": return .red
        case "enemy sprite": return .orange
        default: return o.kind.hasPrefix("PC") ? .green : .white
        }
    }

    private func overlay(_ paths: [CTSceneChoreography]) -> some View {
        Canvas { ctx, size in
            let s = CGFloat(16 * zoom)
            if !picture {
                for x in 0...width { ctx.stroke(Path { $0.move(to: CGPoint(x: CGFloat(x) * s, y: 0)); $0.addLine(to: CGPoint(x: CGFloat(x) * s, y: size.height)) }, with: .color(.white.opacity(0.06))) }
                for y in 0...height { ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: CGFloat(y) * s)); $0.addLine(to: CGPoint(x: size.width, y: CGFloat(y) * s)) }, with: .color(.white.opacity(0.06))) }
            }
            // Treasure: TreasureRom records (Field_CheckTileInFront opens them; not event objects).
            for (n, t) in treasure.enumerated() {
                let r = rect(t.x, t.y, s).insetBy(dx: s * 0.18, dy: s * 0.28)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(.brown.opacity(0.85)))
                ctx.stroke(Path(roundedRect: r, cornerRadius: 2), with: .color(.yellow), lineWidth: 1.5)
                ctx.draw(Text("\(n)").font(.system(size: max(8, s * 0.28))).foregroundColor(.yellow), at: CGPoint(x: r.midX, y: r.midY))
            }
            // Paths and keyframes.
            for c in paths where allPaths || c.object == selection.object {
                let hot = c.object == selection.object
                var last: [Int: CGPoint] = [:]
                if let p = analysis.objects[c.object].placement { last[-1] = center(p.column, p.row, s) }
                for p in c.points {
                    let at = dragging == p.offset && dragTile != nil ? center(dragTile!.x, dragTile!.y, s) : center(p.column, p.row, s)
                    let selected = selection.offset == p.offset
                    switch p.kind {
                    case .camera:
                        let r = rect(p.column, p.row, s)
                        let view = CGRect(x: r.minX, y: r.minY, width: 16 * s, height: 14 * s)
                        ctx.stroke(Path(view), with: .color(.purple.opacity(hot ? 0.6 : 0.25)), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                        ctx.fill(Path(ellipseIn: CGRect(x: at.x - s * 0.25, y: at.y - s * 0.25, width: s * 0.5, height: s * 0.5)),
                                 with: .color(.purple.opacity(hot ? 1 : 0.5)))
                        ctx.draw(Text("cam").font(.system(size: 9)).foregroundColor(.purple), at: CGPoint(x: at.x, y: at.y - s * 0.45))
                    case .place, .walk, .move:
                        let from = last[p.function] ?? last[-1]
                        if let from, p.kind != .place {
                            var line = Path(); line.move(to: from); line.addLine(to: at)
                            ctx.stroke(line, with: .color((p.kind == .walk ? Color.blue : Color.teal).opacity(hot ? 0.95 : 0.35)),
                                       style: StrokeStyle(lineWidth: hot ? 2.5 : 1.2, dash: p.kind == .move ? [5, 3] : []))
                        }
                        last[p.function] = at
                        let d = s * (selected ? 0.42 : 0.3)
                        ctx.fill(Path(ellipseIn: CGRect(x: at.x - d / 2, y: at.y - d / 2, width: d, height: d)),
                                 with: .color(p.kind == .place ? .white : p.kind == .walk ? .blue : .teal))
                        if hot { ctx.draw(Text("f\(p.function)").font(.system(size: 8)).foregroundColor(.white), at: CGPoint(x: at.x + d, y: at.y - d)) }
                    }
                    if selected {
                        ctx.stroke(Path(ellipseIn: CGRect(x: at.x - s * 0.4, y: at.y - s * 0.4, width: s * 0.8, height: s * 0.8)),
                                   with: .color(.yellow), lineWidth: 2)
                    }
                }
            }
            // Objects at their placement: PC sprites where the handlers name the character.
            for o in analysis.objects {
                guard let p = o.placement else { continue }
                let r = rect(p.column, p.row, s), selected = selection.object == o.index
                if let pc = o.markers.first(where: { $0.kind == "pc" })?.operands.first, let image = sprites[pc] {
                    let iw = CGFloat(image.size.width) * CGFloat(zoom), ih = CGFloat(image.size.height) * CGFloat(zoom)
                    ctx.draw(Image(nsImage: image).interpolation(.none),
                             in: CGRect(x: r.midX - iw / 2, y: r.maxY - ih, width: iw, height: ih))
                } else {
                    let d = r.insetBy(dx: s * 0.2, dy: s * 0.2)
                    ctx.fill(Path(ellipseIn: d), with: .color(color(o).opacity(0.75)))
                }
                ctx.stroke(Path(r.insetBy(dx: 1, dy: 1)), with: .color(selected ? .yellow : color(o).opacity(0.6)), lineWidth: selected ? 2.5 : 1)
                ctx.draw(Text("\(o.index)").font(.system(size: max(8, s * 0.3), weight: .bold)).foregroundColor(.white),
                         at: CGPoint(x: r.minX + s * 0.18, y: r.minY + s * 0.2))
                if o.kind == "save point" || o.kind == "encounter" {
                    ctx.draw(Text(o.kind).font(.system(size: 9)).foregroundColor(color(o)), at: CGPoint(x: r.midX, y: r.maxY + 6))
                }
            }
            if let hover { ctx.stroke(Path(rect(hover.x, hover.y, s)), with: .color(.white.opacity(0.7)), lineWidth: 1) }
        }
    }

    private func center(_ c: Int, _ r: Int, _ s: CGFloat) -> CGPoint {
        let t = rect(c, r, s)
        return CGPoint(x: t.midX, y: t.midY)
    }

    // MARK: Interaction

    private func pan(_ dx: Int, _ dy: Int) {
        guard let map else { return }
        let c = LocationScene.clampCamera(map, x: cameraX + dx, y: cameraY + dy)
        cameraX = c.x; cameraY = c.y
    }

    /// The selected object's point on tile `t`, if any.
    private func point(at t: TilePoint, _ paths: [CTSceneChoreography]) -> CTSceneChoreography.Point? {
        guard let k = selection.object, paths.indices.contains(k) else { return nil }
        return paths[k].points.last { $0.column == t.x && $0.row == t.y }
    }

    private func dragChanged(_ v: DragGesture.Value, _ paths: [CTSceneChoreography]) {
        if dragStart == nil {
            dragStart = (cameraX, cameraY)
            if tool == .select, let t = tile(at: v.startLocation), let p = point(at: t, paths) {
                dragging = p.offset
                selection = SceneSelection(object: selection.object, function: p.function, offset: p.offset)
            }
        }
        if dragging != nil { dragTile = tile(at: v.location); return }
        if tool == .pan, let map, let start = dragStart {
            let c = LocationScene.clampCamera(map, x: start.x - Int(v.translation.width) / zoom, y: start.y - Int(v.translation.height) / zoom)
            cameraX = c.x; cameraY = c.y
        }
    }

    private func dragEnded(_ v: DragGesture.Value, _ paths: [CTSceneChoreography]) {
        defer { dragStart = nil; dragging = nil; dragTile = nil }
        if let y = dragging, let t = dragTile ?? tile(at: v.location) {
            edit { try $0.movePoint(at: y, column: t.x, row: t.y) }
            return
        }
        guard abs(v.translation.width) < 3, abs(v.translation.height) < 3, let t = tile(at: v.location) else { return }
        note = ""
        switch tool {
        case .pan: break
        case .select: select(at: t, paths)
        case .walk: add(.walk, t, paths)
        case .move: add(.move, t, paths)
        case .camera: add(.camera, t, paths)
        case .place:
            guard let k = selection.object else { note = "Select an object first."; return }
            if let y = analysis.objects[k].placementOffset {
                edit { try $0.movePoint(at: y, column: t.x, row: t.y) }
            } else {
                edit { try $0.addPoint(.place, column: t.x, row: t.y, after: nil, object: k, function: 0) }
            }
        case .copy:
            guard let k = selection.object else { note = "Select an object to copy first."; return }
            let new = analysis.objectCount
            edit { try $0.duplicateObject(k, placeAt: (t.x, t.y)) }
            selection = SceneSelection(object: new, function: 0, offset: nil)
        }
    }

    private func select(at t: TilePoint, _ paths: [CTSceneChoreography]) {
        if let p = point(at: t, paths) {
            selection = SceneSelection(object: selection.object, function: p.function, offset: p.offset); return
        }
        if let o = analysis.objects.last(where: { $0.placement.map { $0.column == t.x && $0.row == t.y } ?? false }) {
            selection = SceneSelection(object: o.index, function: 0, offset: o.placementOffset); return
        }
        for c in paths {
            if let p = c.points.last(where: { $0.column == t.x && $0.row == t.y }) {
                selection = SceneSelection(object: c.object, function: p.function, offset: p.offset); return
            }
        }
    }

    /// A point after the selected statement, or after the function's last point, or at its start.
    private func add(_ kind: CTSceneChoreography.Kind, _ t: TilePoint, _ paths: [CTSceneChoreography]) {
        guard let k = selection.object else { note = "Select an object first."; return }
        let f = selection.function ?? 0
        let o = analysis.objects[k]
        let body = f == CTSceneGraph.continuation ? o.continuation : o.functions[f].statements
        let after = selection.offset.flatMap { body.contains($0) ? $0 : nil } ?? paths[k].points.last { $0.function == f }?.offset
        guard after != nil || f != CTSceneGraph.continuation else { note = "Select a statement of the continuation first."; return }
        let length = after.flatMap { analysis.statement(at: $0)?.length } ?? 0
        edit { try $0.addPoint(kind, column: t.x, row: t.y, after: after, object: k, function: f) }
        selection = SceneSelection(object: k, function: f, offset: after.map { $0 + length } ?? o.functions[f].entry)
    }

    // MARK: PC sprites (CTSpriteROM: frame 0 of the character's set)

    static func pcImage(_ rom: [UInt8], set c: Int) -> NSImage? {
        let d = CTSpriteROM.decode(rom: rom, set: c)
        guard let f = d.frames.first else { return nil }
        let pixels = TileDecoder.decodeIndices(d.tiles.flatMap { $0 }, depth: .bpp4)
        let palette = CTSpriteROM.objPalette(d)
        let w = 32, h = 48, ox = 16, oy = 40
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        for (n, piece) in f.pieces.enumerated() where n < 4 {
            for dy in 0..<2 {
                for dx in 0..<2 {
                    let word = f.cells[dy * CTSpriteROM.columns + 2 * n + dx]
                    let t = word & CTSpriteROM.tileMask, flip = word & CTSpriteROM.hflip != 0
                    guard t > 0, (t + 1) * 64 <= pixels.count else { continue }
                    for py in 0..<8 {
                        for px in 0..<8 {
                            let v = Int(pixels[t * 64 + py * 8 + (flip ? 7 - px : px)])
                            guard v != 0 else { continue }
                            let x = ox + piece.x + dx * 8 + px, y = oy + piece.y + dy * 8 + py
                            guard (0..<w).contains(x), (0..<h).contains(y) else { continue }
                            let rgb = BGR555(word: palette[min(v, palette.count - 1)]).srgb
                            let i = (y * w + x) * 4
                            rgba[i] = rgb.r; rgba[i + 1] = rgb.g; rgba[i + 2] = rgb.b; rgba[i + 3] = 255
                        }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: w, height: h))
    }
}
