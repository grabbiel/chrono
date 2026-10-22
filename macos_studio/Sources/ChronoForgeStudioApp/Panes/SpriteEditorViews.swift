// SpriteEditorViews.swift — the Sprites pane's editor: a PPU stage with an
// OAM drag overlay, a pixel canvas over the indexed sheet, an OAM inspector
// and an animation timeline. Every preview is a PPUFrame (SpriteScene) on
// SNESPPUView; the logic lives in Core (SpriteScene, SpriteEditing).
import SwiftUI
import AppKit
import ChronoForgeCore
import ChronoForgeMetal

struct SpriteEditor: View {
    let store: ProjectStore
    @Binding var sprite: SpriteDef

    enum Mode: String, CaseIterable, Identifiable {
        case pixels = "Pixels", assembler = "OAM", timeline = "Timeline"
        var id: String { rawValue }
    }

    @State private var sheet: IndexedPNG?
    @State private var sheetTiles: [[UInt8]] = []
    @State private var sheetDirty = false
    @State private var mode: Mode = .assembler
    @State private var frame = 0
    @State private var selectedOBJ: Int?
    @State private var snap = false
    @State private var onion = false
    @State private var animationID: String?
    @State private var stepIndex = 0
    @State private var playStart: Date?
    @State private var tile = 0
    @State private var colour = 1
    @State private var selectedCell: Int?

    private var options: SpriteScene.Options { SpriteScene.Options() }
    private var sheetPalette: [BGR555] { sheet?.palette ?? [] }
    private var palette: [UInt16] { SpriteScene.palettes(sprite, sheetPalette: sheetPalette)[0] }
    private var animation: SpriteDef.Animation? { sprite.animations.first { $0.id == animationID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    stage
                    Text(budgetText).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
                ScrollView {
                    Group {
                        switch mode {
                        case .pixels: pixelsInspector
                        case .assembler: oamInspector
                        case .timeline: timelineInspector
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minWidth: 340, maxWidth: 420)
            }
            ApplyBar(apply: apply)
        }
        .padding()
        .onAppear(perform: loadSheet)
    }

    // MARK: Header and apply

    private var header: some View {
        HStack(spacing: 12) {
            Text(sprite.id).font(.headline)
            Text(summary).foregroundStyle(.secondary).font(.caption)
            Spacer()
            Stepper("Frame \(frame) / \(max(0, sprite.frames.count - 1))", value: frameBinding,
                    in: 0...max(0, sprite.frames.count - 1))
                .disabled(playStart != nil)
            Toggle("Onion skin", isOn: $onion)
            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
        }
    }

    private var summary: String {
        var parts = ["\(sprite.frames.count) frames", "\(sprite.animations.count) animations", sprite.sheet]
        if let st = sprite.stream { parts.append("streams \(st.columns)x\(st.rows) cells at OBJ tile \(st.baseTile)") }
        if let r = sprite.rom { parts.append("set \(r.set) from \(r.frames)") }
        if sheetDirty { parts.append("sheet modified") }
        return parts.joined(separator: " · ")
    }

    private var frameBinding: Binding<Int> {
        Binding(get: { frame }, set: { frame = $0; selectedOBJ = nil; selectedCell = nil })
    }

    private func apply() {
        if sheetDirty, let sheet, store.saveSpriteSheet(sprite, sheet) { sheetDirty = false }
        store.updateSprite(sprite)
    }

    private func loadSheet() {
        sheet = store.spriteSheet(sprite)
        sheetTiles = sheet.map(SpriteSheet.tiles) ?? []
        frame = min(frame, max(0, sprite.frames.count - 1))
        if animationID == nil { animationID = sprite.animations.first?.id }
    }

    // MARK: Stage

    /// The frame and onion frame shown at `date` (playing) or now.
    private func shown(at date: Date) -> (frame: Int, onion: Int?) {
        guard let a = animation, !a.frames.isEmpty else {
            return (frame, onion && frame > 0 ? frame - 1 : nil)
        }
        let step: Int
        if let start = playStart {
            step = SpriteEditing.step(a, at: Int(date.timeIntervalSince(start) * 60))
        } else if mode == .timeline {
            step = min(stepIndex, a.frames.count - 1)
        } else {
            return (frame, onion && frame > 0 ? frame - 1 : nil)
        }
        let previous = a.frames[(step + a.frames.count - 1) % a.frames.count]
        return (a.frames[step], onion && a.frames.count > 1 ? previous : nil)
    }

    private var stage: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: playStart == nil)) { context in
            let now = shown(at: context.date)
            SpriteStage(picture: picture(frame: now.frame, onion: now.onion), sprite: sprite, frame: now.frame,
                        options: options, selected: mode == .assembler ? selectedOBJ : nil,
                        editable: mode == .assembler && playStart == nil, snap: snap,
                        onSelect: { selectedOBJ = $0 },
                        onMove: { obj, x, y in
                            guard sprite.frames.indices.contains(frame),
                                  sprite.frames[frame].tiles.indices.contains(obj) else { return }
                            sprite.frames[frame].tiles[obj].x = x
                            sprite.frames[frame].tiles[obj].y = y
                        })
        }
    }

    private func picture(frame f: Int, onion: Int?) -> PPUFrame {
        var o = options
        o.onionFrame = onion
        return SpriteScene.frame(sprite, frame: f, sheet: sheetTiles, sheetPalette: sheetPalette, options: o)
    }

    private var budgetText: String {
        guard sprite.frames.indices.contains(frame) else { return "no frames" }
        let b = SpriteScene.budget(sprite, frame: frame, options: options)
        var text = "OAM \(b.objs)/128 · OBJ tiles \(b.tiles)"
        if sprite.stream != nil { text += " · streamed \(b.streamedTiles)" }
        text += " · worst line \(b.maxOBJsOnALine)/\(PPUOBJEvaluator.maxOBJsPerLine) OBJs, "
            + "\(b.maxSliversOnALine)/\(PPUOBJEvaluator.maxSliversPerLine) slivers"
        if b.rangeOver { text += " · RANGE OVER" }
        if b.timeOver { text += " · TIME OVER" }
        return text
    }

    // MARK: Pixels

    @ViewBuilder
    private var pixelsInspector: some View {
        if let sheet {
            VStack(alignment: .leading, spacing: 10) {
                Text("Palette (BGR555; index 0 is transparent)").font(.subheadline)
                swatches
                colourEditor
                Divider()
                Text("Sheet tile \(tile) of \(sheetTiles.count)").font(.subheadline)
                TilePainter(pixels: tile < sheetTiles.count ? sheetTiles[tile] : [UInt8](repeating: 0, count: 64),
                            palette: palette) { x, y in paint(x: x, y: y) }
                SheetPicker(png: sheet, palette: palette, selected: tile) { tile = $0 }
                HStack {
                    Button("Add Tile Row") {
                        self.sheet = SpriteEditing.grow(sheet)
                        sheetTiles = SpriteSheet.tiles(self.sheet!)
                        sheetDirty = true
                    }
                    Spacer()
                    Button("Save Sheet") { if store.saveSpriteSheet(sprite, sheet) { sheetDirty = false } }
                        .disabled(!sheetDirty)
                }
                if sprite.stream != nil { cellEditor }
            }
        } else {
            ContentUnavailableView("Sheet PNG missing or not indexed", systemImage: "photo")
        }
    }

    private var swatches: some View {
        let count = sprite.bpp == 2 ? 4 : 16
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 3), count: 8), spacing: 3) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(bgr555: palette[i]))
                    .frame(width: 22, height: 22)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(i == colour ? Color.accentColor : Color.gray,
                                                                       lineWidth: i == colour ? 3 : 1))
                    .onTapGesture { colour = i }
                    .help(BGR555(word: palette[i]).hex)
            }
        }
    }

    private var colourEditor: some View {
        let c = BGR555(word: palette[min(colour, 15)])
        return HStack {
            Text("\(colour): \(c.hex)").font(.system(.caption, design: .monospaced))
            channel("R", c.r5) { setColour(r5: $0, g5: c.g5, b5: c.b5) }
            channel("G", c.g5) { setColour(r5: c.r5, g5: $0, b5: c.b5) }
            channel("B", c.b5) { setColour(r5: c.r5, g5: c.g5, b5: $0) }
        }
    }

    private func channel(_ label: String, _ value: UInt8, _ set: @escaping (UInt8) -> Void) -> some View {
        Stepper("\(label) \(value)", value: Binding(get: { Int(value) }, set: { set(UInt8($0)) }), in: 0...31)
            .font(.caption)
    }

    /// A colour edit goes to `palettes[0]` when the sprite has OBJ palettes,
    /// and always to the sheet's PLTE, so the PNG shows the same colours.
    private func setColour(r5: UInt8, g5: UInt8, b5: UInt8) {
        let c = BGR555(r5: r5, g5: g5, b5: b5)
        if sprite.palettes != nil {
            while sprite.palettes![0].count < 16 { sprite.palettes![0].append("0x0000") }
            sprite.palettes![0][colour] = c.hex
        }
        guard var png = sheet else { return }
        while png.palette.count <= colour { png.palette.append(BGR555(word: 0)) }
        png.palette[colour] = c
        sheet = png
        sheetDirty = true
    }

    private func paint(x: Int, y: Int) {
        guard var png = sheet, tile < sheetTiles.count, sheetTiles[tile][y * 8 + x] != UInt8(colour) else { return }
        SpriteEditing.paint(&png, tile: tile, x: x, y: y, index: UInt8(colour))
        sheetTiles[tile] = SpriteSheet.tile(png, tile)
        sheet = png
        sheetDirty = true
    }

    /// The current frame's streamed cells: pick one, give it the selected
    /// sheet tile, mirror it or clear it (other bits are kept).
    @ViewBuilder
    private var cellEditor: some View {
        if let st = sprite.stream, sprite.frames.indices.contains(frame) {
            let cells = sprite.frames[frame].cells ?? []
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                Text("Frame \(frame) cells (\(st.columns) x \(st.rows), OBJ tiles \(st.baseTile)+)").font(.subheadline)
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    ForEach(0..<st.rows, id: \.self) { r in
                        GridRow {
                            ForEach(0..<st.columns, id: \.self) { c in
                                let k = r * st.columns + c
                                let w = k < cells.count ? cells[k] : 0
                                TileImage(pixels: cellPixels(w), palette: palette, scale: 3)
                                    .overlay(Rectangle().stroke(selectedCell == k ? Color.accentColor : Color.gray.opacity(0.4),
                                                                lineWidth: selectedCell == k ? 2 : 1))
                                    .onTapGesture { selectedCell = k }
                                    .help(String(format: "cell %d: %04X", k, w))
                            }
                        }
                    }
                }
                if let k = selectedCell {
                    let w = k < cells.count ? cells[k] : 0
                    HStack {
                        Text(String(format: "cell %d = tile %d%@", k, w & CTSpriteROM.tileMask,
                                    w & CTSpriteROM.hflip != 0 ? ", mirrored" : ""))
                            .font(.system(.caption, design: .monospaced))
                        Button("Use Tile \(tile)") { setCell(k) { $0 & ~CTSpriteROM.tileMask | tile & CTSpriteROM.tileMask } }
                        Button("Mirror") { setCell(k) { $0 ^ CTSpriteROM.hflip } }
                        Button("Clear") { setCell(k) { $0 & ~(CTSpriteROM.tileMask | CTSpriteROM.hflip) } }
                    }
                }
            }
        }
    }

    private func cellPixels(_ w: Int) -> [UInt8] {
        let t = w & CTSpriteROM.tileMask
        guard t != 0, t < sheetTiles.count else { return [UInt8](repeating: 0, count: 64) }
        return w & CTSpriteROM.hflip != 0 ? SpriteSheet.mirrored(sheetTiles[t]) : sheetTiles[t]
    }

    private func setCell(_ k: Int, _ change: (Int) -> Int) {
        guard let st = sprite.stream, sprite.frames.indices.contains(frame) else { return }
        var cells = sprite.frames[frame].cells ?? []
        if cells.count < st.columns * st.rows { cells += [Int](repeating: 0, count: st.columns * st.rows - cells.count) }
        cells[k] = change(cells[k])
        sprite.frames[frame].cells = cells
    }

    // MARK: OAM assembler

    @ViewBuilder
    private var oamInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Duplicate Frame") {
                    guard sprite.frames.indices.contains(frame) else { return }
                    frame = SpriteEditing.duplicateFrame(&sprite, frame)
                }
                Button("Delete Frame") {
                    SpriteEditing.deleteFrame(&sprite, frame)
                    frame = min(frame, max(0, sprite.frames.count - 1))
                    selectedOBJ = nil
                }
                .disabled(sprite.frames.count <= 1)
                Button("New Frame") {
                    sprite.frames.append(SpriteDef.Frame(cells: sprite.stream.map { [Int](repeating: 0, count: $0.columns * $0.rows) }))
                    frame = sprite.frames.count - 1
                }
            }
            Toggle("Snap drags to the 8-pixel grid", isOn: $snap)
            if sprite.frames.indices.contains(frame) {
                Text("OBJs, front to back (drag them on the stage)").font(.subheadline)
                ForEach(Array(sprite.frames[frame].tiles.enumerated()), id: \.offset) { n, t in
                    Text(objLine(n, t))
                        .font(.system(.caption, design: .monospaced))
                        .padding(2)
                        .background(selectedOBJ == n ? Color.accentColor.opacity(0.25) : Color.clear)
                        .onTapGesture { selectedOBJ = n }
                }
                HStack {
                    Button("Add 8x8") { addOBJ(size16: false) }
                    Button("Add 16x16") { addOBJ(size16: true) }
                }
                if let n = selectedOBJ, sprite.frames[frame].tiles.indices.contains(n) {
                    objEditor(n)
                }
            }
        }
    }

    private func objLine(_ n: Int, _ t: SpriteDef.OAMTile) -> String {
        String(format: "%2d  x %4d  y %4d  tile %3d  %@  pal %d  prio %d%@%@%@", n, t.x, t.y,
               SpriteScene.objTile(sprite, t), t.size16 ? "16" : " 8", t.pal, t.priority ?? CTSpriteROM.priority,
               t.hflip ? " H" : "", t.vflip ? " V" : "", t.anchor ? " anchor" : "")
    }

    private func addOBJ(size16: Bool) {
        guard sprite.frames.indices.contains(frame) else { return }
        let t = sprite.stream == nil ? tile : 0
        sprite.frames[frame].tiles.append(SpriteDef.OAMTile(x: size16 ? -8 : -4, y: size16 ? -16 : -8, tile: t,
                                                            size16: size16, priority: CTSpriteROM.priority))
        selectedOBJ = sprite.frames[frame].tiles.count - 1
    }

    private func objBinding(_ n: Int) -> Binding<SpriteDef.OAMTile> {
        Binding(get: { sprite.frames[frame].tiles[n] }, set: { sprite.frames[frame].tiles[n] = $0 })
    }

    @ViewBuilder
    private func objEditor(_ n: Int) -> some View {
        let t = objBinding(n)
        GroupBox("OBJ \(n)") {
            VStack(alignment: .leading, spacing: 4) {
                Stepper("x \(t.wrappedValue.x)", value: t.x, in: -256...255)
                Stepper("y \(t.wrappedValue.y)", value: t.y, in: -128...127)
                Stepper("tile \(t.wrappedValue.tile)" + (sprite.stream != nil ? " (slot)" : ""), value: t.tile, in: 0...511)
                Toggle("16x16 (OBSEL 0 large)", isOn: t.size16)
                Toggle("Flip H", isOn: t.hflip)
                Toggle("Flip V", isOn: t.vflip)
                Picker("Palette", selection: t.pal) { ForEach(0..<8, id: \.self) { Text("\($0)").tag($0) } }
                Picker("Priority", selection: Binding(get: { t.wrappedValue.priority ?? CTSpriteROM.priority },
                                                      set: { t.wrappedValue.priority = $0 })) {
                    ForEach(0..<4, id: \.self) { Text("\($0)").tag($0) }
                }
                Toggle("Anchor", isOn: t.anchor)
                HStack {
                    Button("Forward") { moveOBJ(n, by: -1) }.disabled(n == 0)
                    Button("Back") { moveOBJ(n, by: 1) }.disabled(n == sprite.frames[frame].tiles.count - 1)
                    Spacer()
                    Button("Remove", role: .destructive) {
                        sprite.frames[frame].tiles.remove(at: n)
                        selectedOBJ = nil
                    }
                }
            }
        }
    }

    private func moveOBJ(_ n: Int, by d: Int) {
        let m = n + d
        guard sprite.frames[frame].tiles.indices.contains(m) else { return }
        sprite.frames[frame].tiles.swapAt(n, m)
        selectedOBJ = m
    }

    // MARK: Timeline

    @ViewBuilder
    private var timelineInspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Animation", selection: Binding(get: { animationID ?? "" },
                                                       set: { animationID = $0; stepIndex = 0; playStart = nil })) {
                    ForEach(sprite.animations.map(\.id), id: \.self) { Text($0).tag($0) }
                }
                Button("New") {
                    let id = "anim\(sprite.animations.count)"
                    sprite.animations.append(SpriteDef.Animation(id: id, frames: [frame], durations: [8]))
                    animationID = id
                    stepIndex = 0
                }
            }
            if let i = sprite.animations.firstIndex(where: { $0.id == animationID }) {
                animationEditor(i)
            }
            Divider()
            frameMetadata
        }
    }

    @ViewBuilder
    private func animationEditor(_ i: Int) -> some View {
        let a = sprite.animations[i]
        HStack {
            Button(playStart == nil ? "Play" : "Pause") {
                if let start = playStart {
                    stepIndex = SpriteEditing.step(a, at: Int(Date().timeIntervalSince(start) * 60))
                    playStart = nil
                } else {
                    playStart = Date()
                }
            }
            .disabled(a.frames.isEmpty)
            Button("◀︎") { stepIndex = (stepIndex + a.frames.count - 1) % max(1, a.frames.count) }
                .disabled(playStart != nil || a.frames.isEmpty)
            Button("▶︎") { stepIndex = (stepIndex + 1) % max(1, a.frames.count) }
                .disabled(playStart != nil || a.frames.isEmpty)
            Toggle("Loop", isOn: Binding(get: { sprite.animations[i].loop }, set: { sprite.animations[i].loop = $0 }))
        }
        Text(animationInfo(a)).font(.caption).foregroundStyle(.secondary)
        ForEach(Array(a.frames.indices), id: \.self) { k in
            HStack {
                Text("\(k)").font(.system(.caption, design: .monospaced)).frame(width: 22, alignment: .trailing)
                Stepper("frame \(a.frames[k])", value: stepFrame(i, k), in: 0...max(0, sprite.frames.count - 1))
                Stepper("\(k < a.durations.count ? a.durations[k] : 0) ticks", value: stepDuration(i, k), in: 1...255)
                Button { removeStep(i, k) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(2)
            .background(playStart == nil && k == stepIndex ? Color.accentColor.opacity(0.2) : Color.clear)
            .onTapGesture { stepIndex = k; frame = a.frames[k] }
        }
        Button("Add Step (frame \(frame))") {
            sprite.animations[i].frames.append(frame)
            sprite.animations[i].durations.append(8)
        }
    }

    private func animationInfo(_ a: SpriteDef.Animation) -> String {
        let total = a.durations.prefix(a.frames.count).reduce(0, +)
        var text = "\(a.frames.count) steps, \(total) ticks (\(String(format: "%.2f", Double(total) / 60)) s at 60 Hz)"
        if let row = a.row { text += " · row \(row)" }
        if let f = a.facing, (0..<4).contains(f) { text += " · facing \(CTSpriteROM.facings[f])" }
        return text
    }

    private func stepFrame(_ i: Int, _ k: Int) -> Binding<Int> {
        Binding(get: { sprite.animations[i].frames[k] },
                set: { sprite.animations[i].frames[k] = $0; frame = $0; stepIndex = k })
    }

    private func stepDuration(_ i: Int, _ k: Int) -> Binding<Int> {
        Binding(get: { k < sprite.animations[i].durations.count ? sprite.animations[i].durations[k] : 1 },
                set: { v in
                    while sprite.animations[i].durations.count <= k { sprite.animations[i].durations.append(1) }
                    sprite.animations[i].durations[k] = v
                })
    }

    private func removeStep(_ i: Int, _ k: Int) {
        sprite.animations[i].frames.remove(at: k)
        if k < sprite.animations[i].durations.count { sprite.animations[i].durations.remove(at: k) }
        stepIndex = min(stepIndex, max(0, sprite.animations[i].frames.count - 1))
    }

    /// Hitbox and weapon anchor of the current frame (Studio metadata).
    @ViewBuilder
    private var frameMetadata: some View {
        if sprite.frames.indices.contains(frame) {
            Text("Frame \(frame): hitbox and weapon anchor (about the origin)").font(.subheadline)
            Toggle("Hitbox", isOn: Binding(get: { sprite.frames[frame].hitbox != nil },
                                           set: { sprite.frames[frame].hitbox = $0 ? .init(x: -8, y: -32, w: 16, h: 32) : nil }))
            if sprite.frames[frame].hitbox != nil {
                HStack {
                    boxField("x", \.x); boxField("y", \.y); boxField("w", \.w); boxField("h", \.h)
                }
            }
            Toggle("Weapon anchor", isOn: Binding(get: { sprite.frames[frame].weapon != nil },
                                                  set: { sprite.frames[frame].weapon = $0 ? .init(x: 0, y: -16) : nil }))
            if sprite.frames[frame].weapon != nil {
                HStack {
                    Stepper("x \(sprite.frames[frame].weapon!.x)",
                            value: Binding(get: { sprite.frames[frame].weapon?.x ?? 0 }, set: { sprite.frames[frame].weapon?.x = $0 }),
                            in: -128...127)
                    Stepper("y \(sprite.frames[frame].weapon!.y)",
                            value: Binding(get: { sprite.frames[frame].weapon?.y ?? 0 }, set: { sprite.frames[frame].weapon?.y = $0 }),
                            in: -128...127)
                }
                .font(.caption)
            }
        }
    }

    private func boxField(_ label: String, _ key: WritableKeyPath<SpriteDef.Box, Int>) -> some View {
        Stepper("\(label) \(sprite.frames[frame].hitbox?[keyPath: key] ?? 0)",
                value: Binding(get: { sprite.frames[frame].hitbox?[keyPath: key] ?? 0 },
                               set: { sprite.frames[frame].hitbox?[keyPath: key] = $0 }),
                in: -128...255)
            .font(.caption)
    }
}

// MARK: - The stage: PPU picture + anchor grid + OBJ drag overlay

struct SpriteStage: View {
    static let scale = 2
    let picture: PPUFrame
    let sprite: SpriteDef
    let frame: Int
    let options: SpriteScene.Options
    let selected: Int?
    let editable: Bool
    let snap: Bool
    let onSelect: (Int?) -> Void
    let onMove: (Int, Int, Int) -> Void
    @State private var drag: (obj: Int, x: Int, y: Int)?

    var body: some View {
        let s = CGFloat(Self.scale)
        ZStack(alignment: .topLeading) {
            PPUPictureView(picture: picture)
                .frame(width: 256 * s, height: CGFloat(picture.height) * s)
            Canvas { ctx, _ in overlay(ctx, s) }
                .frame(width: 256 * s, height: CGFloat(picture.height) * s)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged(dragged).onEnded { _ in drag = nil })
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func overlay(_ ctx: GraphicsContext, _ s: CGFloat) {
        let ox = CGFloat(options.originX) * s, oy = CGFloat(options.originY) * s
        var grid = Path()
        for k in -8...8 {
            grid.move(to: CGPoint(x: ox + CGFloat(8 * k) * s, y: oy - 64 * s))
            grid.addLine(to: CGPoint(x: ox + CGFloat(8 * k) * s, y: oy + 64 * s))
            grid.move(to: CGPoint(x: ox - 64 * s, y: oy + CGFloat(8 * k) * s))
            grid.addLine(to: CGPoint(x: ox + 64 * s, y: oy + CGFloat(8 * k) * s))
        }
        ctx.stroke(grid, with: .color(.white.opacity(0.08)), lineWidth: 1)
        var cross = Path()
        cross.move(to: CGPoint(x: ox - 6 * s, y: oy)); cross.addLine(to: CGPoint(x: ox + 6 * s, y: oy))
        cross.move(to: CGPoint(x: ox, y: oy - 6 * s)); cross.addLine(to: CGPoint(x: ox, y: oy + 6 * s))
        ctx.stroke(cross, with: .color(.yellow.opacity(0.8)), lineWidth: 1)
        guard sprite.frames.indices.contains(frame) else { return }
        let f = sprite.frames[frame]
        if editable {
            for (n, t) in f.tiles.enumerated() {
                let size = CGFloat(t.size16 ? 16 : 8) * s
                let r = CGRect(x: ox + CGFloat(t.x) * s, y: oy + CGFloat(t.y) * s, width: size, height: size)
                ctx.stroke(Path(r), with: .color(n == selected ? .orange : .cyan.opacity(0.45)),
                           lineWidth: n == selected ? 2 : 1)
            }
        }
        if let h = f.hitbox {
            let r = CGRect(x: ox + CGFloat(h.x) * s, y: oy + CGFloat(h.y) * s, width: CGFloat(h.w) * s, height: CGFloat(h.h) * s)
            ctx.stroke(Path(r), with: .color(.red.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        if let w = f.weapon {
            let p = CGPoint(x: ox + CGFloat(w.x) * s, y: oy + CGFloat(w.y) * s)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(.green))
        }
    }

    private func dragged(_ v: DragGesture.Value) {
        guard editable, sprite.frames.indices.contains(frame) else { return }
        let px = Int(v.startLocation.x) / Self.scale, py = Int(v.startLocation.y) / Self.scale
        if drag == nil {
            guard let n = SpriteEditing.hit(sprite, frame: frame, x: px, y: py, options: options) else {
                onSelect(nil); return
            }
            onSelect(n)
            let t = sprite.frames[frame].tiles[n]
            drag = (n, t.x, t.y)
        }
        guard let d = drag else { return }
        var x = d.x + Int((v.translation.width / CGFloat(Self.scale)).rounded())
        var y = d.y + Int((v.translation.height / CGFloat(Self.scale)).rounded())
        if snap {
            x = Int((Double(x) / 8).rounded()) * 8
            y = Int((Double(y) / 8).rounded()) * 8
        }
        onMove(d.obj, max(-256, min(255, x)), max(-128, min(127, y)))
    }
}

/// A PPUFrame on SNESPPUView (integer scale, nearest sampling).
struct PPUPictureView: NSViewRepresentable {
    let picture: PPUFrame

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else { return NSView() }
        view.picture = picture
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SNESPPUView)?.picture = picture
    }
}

// MARK: - Pixel canvas pieces

/// An 8x8 tile at 24 points per pixel; click or drag paints.
struct TilePainter: View {
    let pixels: [UInt8]
    let palette: [UInt16]
    let paint: (Int, Int) -> Void
    static let cell: CGFloat = 24

    var body: some View {
        Canvas { ctx, _ in
            for i in 0..<64 {
                let r = CGRect(x: CGFloat(i % 8) * Self.cell, y: CGFloat(i / 8) * Self.cell, width: Self.cell, height: Self.cell)
                let v = Int(pixels[i])
                ctx.fill(Path(r), with: .color(v == 0 ? Color(white: 0.16) : Color(bgr555: palette[min(v, palette.count - 1)])))
                ctx.stroke(Path(r), with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
            }
        }
        .frame(width: 8 * Self.cell, height: 8 * Self.cell)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { v in
            let x = Int(v.location.x / Self.cell), y = Int(v.location.y / Self.cell)
            if (0..<8).contains(x), (0..<8).contains(y) { paint(x, y) }
        })
    }
}

/// The sheet at 2x; click picks a tile.
struct SheetPicker: View {
    let png: IndexedPNG
    let palette: [UInt16]
    let selected: Int
    let pick: (Int) -> Void

    var body: some View {
        let cols = max(1, png.width / 8)
        ScrollView {
            ZStack(alignment: .topLeading) {
                Image(nsImage: indexedImage(width: png.width, height: png.height, indices: png.indices, palette: palette))
                    .interpolation(.none)
                    .resizable()
                    .frame(width: CGFloat(png.width * 2), height: CGFloat(png.height * 2))
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 2)
                    .frame(width: 16, height: 16)
                    .offset(x: CGFloat(selected % cols * 16), y: CGFloat(selected / cols * 16))
            }
            .contentShape(Rectangle())
            .onTapGesture { p in pick(Int(p.y) / 16 * cols + Int(p.x) / 16) }
        }
        .frame(height: 260)
        .background(Color.black)
    }
}

/// One 8x8 tile as an image.
struct TileImage: View {
    let pixels: [UInt8]
    let palette: [UInt16]
    let scale: Int

    var body: some View {
        Image(nsImage: indexedImage(width: 8, height: 8, indices: pixels, palette: palette))
            .interpolation(.none)
            .resizable()
            .frame(width: CGFloat(8 * scale), height: CGFloat(8 * scale))
    }
}

/// Indexed pixels as an image; index 0 is drawn dark grey (transparent).
@MainActor
func indexedImage(width: Int, height: Int, indices: [UInt8], palette: [UInt16]) -> NSImage {
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<min(indices.count, width * height) {
        let v = Int(indices[i])
        let c = v == 0 ? (r: UInt8(40), g: UInt8(40), b: UInt8(40)) : BGR555(word: palette[min(v, palette.count - 1)]).srgb
        rgba[4 * i] = c.r; rgba[4 * i + 1] = c.g; rgba[4 * i + 2] = c.b
    }
    guard let provider = CGDataProvider(data: Data(rgba) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
        return NSImage(size: NSSize(width: width, height: height))
    }
    return NSImage(cgImage: image, size: NSSize(width: width, height: height))
}

extension Color {
    /// A BGR555 word through the SNES DAC ramp.
    init(bgr555 word: UInt16) {
        let c = BGR555(word: word).srgb
        self.init(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
    }
}
