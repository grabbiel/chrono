// TilesetEditorViews.swift — Module 3, the Tileset & Asset Workshop: the tile
// bank (sheet, pixel painter, VRAM budget), the metatile composer and the
// palette-cycle editor, each previewed on the SNES PPU with the field's
// animations running. The logic lives in Core (TilesetScene, TilesetPlayer,
// TilesetBudget, PaletteCycler); docs/tilesets.md describes the data.
import SwiftUI
import ChronoForgeCore
import ChronoForgeMetal

/// The palette a tileset is previewed in: `override`, the tileset's own
/// link, else the first palette entry of the project.
func previewPalette(_ project: CTProject, _ ts: Tileset, override: String? = nil) -> Tileset? {
    if let id = override ?? ts.preview?.palette, let p = project.tilesets[id], p.kind == "palette" { return p }
    return project.tilesets.values.filter { $0.kind == "palette" }.min { $0.id < $1.id }
}

/// CGRAM row `row` as the tile views draw it (4 colours for 2bpp).
func cgramRow(_ cgram: [UInt16], row: Int, bpp: Int) -> [UInt16] {
    let n = bpp == 2 ? 4 : 16
    return Array(cgram[(n * row)..<(n * row + n)])
}

/// CGRAM indices as an image (0 = the backdrop colour).
@MainActor
func cgramImage(width: Int, height: Int, indices: [Int], cgram: [UInt16]) -> NSImage {
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for (i, v) in indices.enumerated() {
        let c = BGR555(word: cgram[v & 0xFF]).srgb
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

// MARK: - The PPU preview

/// The field picture of a tileset's metatiles, 16 per row: palette cycles
/// every frame, a tile upload every other, scrolled with the wheel.
struct TilesetPPUPreview: NSViewRepresentable {
    let tileset: Tileset
    let tiles: [[UInt8]]
    let animTiles: [[UInt8]]
    let palette: Tileset?
    let animate: Bool

    struct Inputs: Equatable {
        var tileset: Tileset, tiles: [[UInt8]], animTiles: [[UInt8]], palette: Tileset?, animate: Bool
    }

    @MainActor final class Coordinator {
        var inputs: Inputs?
        var scrollY = 0
        var player: TilesetPlayer?
        var shownFrames: [Int] = []
        var start = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let device = StudioMetal.device, let view = try? SNESPPUView(device: device) else { return NSView() }
        view.addConstraint(NSLayoutConstraint(item: view, attribute: .height, relatedBy: .equal, toItem: nil,
                                              attribute: .notAnAttribute, multiplier: 1, constant: 224 * 2))
        configure(view, context.coordinator)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? SNESPPUView { configure(view, context.coordinator) }
    }

    private func configure(_ view: SNESPPUView, _ c: Coordinator) {
        let inputs = Inputs(tileset: tileset, tiles: tiles, animTiles: animTiles, palette: palette, animate: animate)
        guard c.inputs != inputs else { return }
        c.inputs = inputs
        let ts = tileset, anim = animTiles, layer = tileset.bpp == 2 ? 2 : 0
        let maxScroll = max(0, TilesetScene.rows(ts) * 16 - 224)
        c.scrollY = min(c.scrollY, maxScroll)
        let base = TilesetScene.cgram(palette)
        view.picture = TilesetScene.frame(ts, tiles: tiles, cgram: base, scrollY: c.scrollY)
        c.player = animate ? TilesetPlayer(tileset: ts, palette: palette, cgram: base) : nil
        c.shownFrames = []
        c.start = view.frameCount
        view.tick = { [weak c] picture, n in
            guard let c, var player = c.player else { return }
            player.advance(to: n - c.start)
            c.player = player
            if picture.cgram != player.cgram { picture.cgram = player.cgram }
            let frames = player.animator.frames
            if frames != c.shownFrames {
                TilesetScene.applyTileAnimations(&picture, ts, animTiles: anim, frames: frames)
                c.shownFrames = frames
            }
        }
        view.onScroll = { [weak view, weak c] _, dy in
            guard let c else { return }
            c.scrollY = min(maxScroll, max(0, c.scrollY - Int(dy)))
            let vofs = UInt16((c.scrollY - 1) & 0x3FF)
            view?.picture.setAllLines { $0.bg[layer].vofs = vofs }
        }
    }
}

/// The PPU preview beside the inspector when the pane is wide enough, above it otherwise.
struct SideBySide<P: View, I: View>: View {
    @ViewBuilder let preview: () -> P
    @ViewBuilder let inspector: () -> I

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { preview(); inspector() }
            VStack(alignment: .leading, spacing: 16) { preview(); inspector() }
        }
    }
}

// MARK: - Tileset editor

struct TilesetEditor: View {
    let store: ProjectStore
    let project: CTProject
    @Binding var tileset: Tileset

    enum Mode: String, CaseIterable, Identifiable {
        case metatiles = "Metatiles", bank = "Tile bank", animation = "Animation"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .metatiles
    @State private var sheet: IndexedPNG?
    @State private var tiles: [[UInt8]] = []
    @State private var animTiles: [[UInt8]] = []
    @State private var sheetDirty = false
    @State private var paletteID: String?
    @State private var animate = true
    @State private var metatile = 0
    @State private var quadrant = 0
    @State private var bankTile = 256
    @State private var bankRow = 1
    @State private var colour = 1
    @State private var metatileSheet: NSImage?

    private var palette: Tileset? { previewPalette(project, tileset, override: paletteID) }
    private var cgram: [UInt16] { TilesetScene.cgram(palette) }
    private var paletteIDs: [String] { project.tilesets.values.filter { $0.kind == "palette" }.map(\.id).sorted() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                SideBySide(preview: { previewColumn }, inspector: { inspector })
                ApplyBar(apply: apply)
            }
            .padding()
        }
        .onAppear(perform: load)
        .onChange(of: tileset.metatiles) { refreshMetatileSheet() }
        .onChange(of: paletteID) { refreshMetatileSheet() }
    }

    private var previewColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            TilesetPPUPreview(tileset: tileset, tiles: tiles, animTiles: animTiles, palette: palette, animate: animate)
                .frame(width: 512)
            Text("Scroll to move through the \(tileset.metatiles.count) metatiles (16 per row). " +
                 "Mode 1, characters at VRAM $\(String(format: "%04X", TilesetScene.charBase(tileset))) as the field has them.")
                .font(.caption).foregroundStyle(.secondary).frame(width: 512, alignment: .leading)
        }
    }

    private var inspector: some View {
        Group {
            switch mode {
            case .metatiles: composer
            case .bank: bank
            case .animation: animation
            }
        }
        .frame(width: 400, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text(tileset.id).font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack(spacing: 12) {
            Picker("Palette", selection: Binding(get: { palette?.id ?? "" }, set: { paletteID = $0.isEmpty ? nil : $0 })) {
                Text("gray").tag("")
                ForEach(paletteIDs, id: \.self) { Text($0).tag($0) }
            }
            .frame(width: 160)
            Toggle("Animate", isOn: $animate)
            Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 280)
            Spacer()
            }
        }
    }

    private var summary: String {
        let source = tileset.rom.map { " · \($0.family) \($0.index), table \($0.table), \($0.locations.count) locations" } ?? ""
        return "\(tileset.kind ?? "tiles") \(tileset.bpp)bpp · \(tileset.metatiles.count) metatiles" + source
    }

    private func load() {
        sheet = store.tilesetSheet(tileset.sheet)
        tiles = sheet.map(SpriteSheet.tiles) ?? []
        animTiles = store.tilesetSheet(tileset.animSheet).map(SpriteSheet.tiles) ?? []
        bankTile = tileset.vram?.known.first?.firstTile ?? 0
        refreshMetatileSheet()
    }

    private func refreshMetatileSheet() {
        guard !tiles.isEmpty else { metatileSheet = nil; return }
        let d = TilesetScene.cgramIndices(tileset, tiles: tiles)
        metatileSheet = cgramImage(width: d.width, height: d.height, indices: d.indices, cgram: cgram)
    }

    private func apply() {
        if sheetDirty, let sheet, let rel = tileset.sheet, store.saveTilesetSheet(rel, sheet) { sheetDirty = false }
        store.updateTileset(tileset)
    }

    // MARK: Metatile composer

    private var chip: Binding<Tileset.Chip> {
        Binding(get: { tileset.metatiles[metatile].chips[quadrant] },
                set: { tileset.metatiles[metatile].chips[quadrant] = $0 })
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if tileset.metatiles.isEmpty {
                Text("No metatiles.").foregroundStyle(.secondary)
            } else {
                Stepper("Metatile \(metatile) of \(tileset.metatiles.count)", value: $metatile, in: 0...(tileset.metatiles.count - 1))
                metatilePicker
                HStack(alignment: .top, spacing: 16) {
                    quadrants
                    chipInspector
                }
                Text("Pick a quadrant, then a character in the bank below. Words are SNES tilemap words: " +
                     "character 0-9, palette 10-12, priority 13, H flip 14, V flip 15.")
                    .font(.caption).foregroundStyle(.secondary)
                if let sheet {
                    SheetPicker(png: sheet, palette: cgramRow(cgram, row: chip.wrappedValue.pal, bpp: tileset.bpp),
                                selected: chip.wrappedValue.tile) { chip.wrappedValue.tile = $0 }
                }
            }
        }
    }

    private var metatilePicker: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                if let metatileSheet {
                    Image(nsImage: metatileSheet).interpolation(.none).resizable()
                        .frame(width: metatileSheet.size.width, height: metatileSheet.size.height)
                }
                Rectangle().stroke(Color.accentColor, lineWidth: 2).frame(width: 16, height: 16)
                    .offset(x: CGFloat(metatile % 16 * 16), y: CGFloat(metatile / 16 * 16))
            }
            .contentShape(Rectangle())
            .onTapGesture { p in
                let m = Int(p.y) / 16 * 16 + Int(p.x) / 16
                if tileset.metatiles.indices.contains(m) { metatile = m }
            }
        }
        .frame(width: 256, height: 180)
        .background(Color.black)
    }

    private var quadrants: some View {
        let chips = tileset.metatiles[metatile].chips
        return Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            ForEach(0..<2, id: \.self) { r in
                GridRow {
                    ForEach(0..<2, id: \.self) { col in
                        let q = r * 2 + col
                        if q < chips.count {
                            let c = chips[q]
                            TileImage(pixels: c.tile < tiles.count ? tiles[c.tile] : [UInt8](repeating: 0, count: 64),
                                      palette: cgramRow(cgram, row: c.pal, bpp: tileset.bpp), scale: 8)
                                .scaleEffect(x: c.hflip ? -1 : 1, y: c.vflip ? -1 : 1)
                                .overlay(Rectangle().stroke(q == quadrant ? Color.accentColor : .gray.opacity(0.4),
                                                            lineWidth: q == quadrant ? 3 : 1))
                                .onTapGesture { quadrant = q }
                        }
                    }
                }
            }
        }
    }

    private var chipInspector: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(["Top left", "Top right", "Bottom left", "Bottom right"][quadrant]).font(.subheadline)
            Stepper("Character \(chip.wrappedValue.tile)", value: chip.tile, in: 0...1023)
            Stepper("Palette \(chip.wrappedValue.pal)", value: chip.pal, in: 0...7)
            Toggle("Priority", isOn: chip.priority)
            Toggle("H flip", isOn: chip.hflip)
            Toggle("V flip", isOn: chip.vflip)
            Text(String(format: "word $%04X", chip.wrappedValue.word)).font(.system(.caption, design: .monospaced))
            if !TilesetBudget(tileset).namedUnknown.isEmpty, !isKnown(chip.wrappedValue.tile) {
                Text("This character is not set by the tileset: the game shows whatever VRAM holds there.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func isKnown(_ t: Int) -> Bool {
        guard let known = tileset.vram?.known else { return t < tileset.tileCount }
        return known.contains { (($0.firstTile)..<($0.firstTile + $0.tiles)).contains(t) }
    }

    // MARK: Tile bank

    private var bank: some View {
        VStack(alignment: .leading, spacing: 10) {
            VRAMBudgetView(tileset: tileset)
            if let sheet {
                HStack {
                    Stepper("Character \(bankTile)", value: $bankTile, in: 0...max(0, tiles.count - 1))
                    Spacer()
                    Stepper("Drawn in row \(bankRow)", value: $bankRow, in: 0...7)
                }
                SheetPicker(png: sheet, palette: cgramRow(cgram, row: bankRow, bpp: tileset.bpp), selected: bankTile) { bankTile = $0 }
                if !isKnown(bankTile) {
                    Text("Character \(bankTile) is not set by this tileset (it is \(bankTile < 256 && tileset.bpp == 4 ? "below the packs' VRAM" : "past the uploads")).")
                        .font(.caption).foregroundStyle(.orange)
                }
                HStack(alignment: .top, spacing: 12) {
                    if bankTile < tiles.count {
                        TilePainter(pixels: tiles[bankTile], palette: cgramRow(cgram, row: bankRow, bpp: tileset.bpp)) { x, y in
                            paint(x, y)
                        }
                    }
                    colourPicker
                }
                if sheetDirty { Text("Sheet edited: Apply writes \(tileset.sheet ?? "")").font(.caption).foregroundStyle(.orange) }
            } else {
                Text("No sheet loaded.").foregroundStyle(.secondary)
            }
        }
    }

    private var colourPicker: some View {
        let row = cgramRow(cgram, row: bankRow, bpp: tileset.bpp)
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 2), count: 4), spacing: 2) {
            ForEach(0..<row.count, id: \.self) { i in
                Rectangle().fill(i == 0 ? Color(white: 0.16) : Color(bgr555: row[i]))
                    .frame(width: 22, height: 22)
                    .overlay(Rectangle().stroke(i == colour ? Color.accentColor : .clear, lineWidth: 2))
                    .overlay(Text("\(i)").font(.system(size: 8)).foregroundStyle(.white.opacity(0.7)))
                    .onTapGesture { colour = i }
            }
        }
        .frame(width: 100)
    }

    private func paint(_ x: Int, _ y: Int) {
        guard var png = sheet, bankTile < tiles.count else { return }
        var px = tiles[bankTile]
        let v = UInt8(min(colour, (1 << tileset.bpp) - 1))
        guard px[y * 8 + x] != v else { return }
        px[y * 8 + x] = v
        SpriteSheet.setTile(&png, bankTile, px)
        sheet = png
        tiles[bankTile] = px
        sheetDirty = true
        refreshMetatileSheet()
    }

    // MARK: Animation

    private var animation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tile animations").font(.subheadline)
            if (tileset.tileAnimations ?? []).isEmpty {
                Text("None.").foregroundStyle(.secondary).font(.caption)
            }
            ForEach(Array((tileset.tileAnimations ?? []).enumerated()), id: \.offset) { i, a in
                TileAnimationRow(animation: Binding(get: { tileset.tileAnimations![i] }, set: { tileset.tileAnimations![i] = $0 }),
                                 animTiles: animTiles, palette: cgramRow(cgram, row: dominantRow(a), bpp: tileset.bpp))
            }
            if tileset.animSheet == nil, !(tileset.tileAnimations ?? []).isEmpty {
                Text("No animation sheet: the frames are what an earlier location left in bank $7F (the game loads none for this tileset).")
                    .font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Text("Palette cycles of \(palette?.id ?? "the preview palette")").font(.subheadline)
            ForEach(Array((palette?.paletteCycles ?? []).enumerated()), id: \.offset) { _, c in
                Text(cycleText(c)).font(.system(.caption, design: .monospaced))
            }
            Text("Edit them in the palette entry; the preview runs both as the field does (cycles every frame, tile uploads every other).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The palette row the metatiles use most with an animation's characters.
    private func dominantRow(_ a: Tileset.TileAnimation) -> Int {
        var uses = [Int](repeating: 0, count: 8)
        for mt in tileset.metatiles { for c in mt.chips where (a.tile..<(a.tile + a.tiles)).contains(c.tile) { uses[c.pal] += 1 } }
        return uses.indices.max { uses[$0] < uses[$1] } ?? 0
    }
}

func cycleText(_ c: Tileset.PaletteCycle) -> String {
    let last = c.first + c.count - (c.kind.hasPrefix("rotate") ? 0 : 1)
    return String(format: "%@ $%02X-$%02X every %d", c.kind, c.first, last, c.delay == 0 ? 256 : c.delay)
        + (c.frames.map { ", \($0.count) frames" } ?? "") + (c.order.map { ", order \($0.map(String.init).joined(separator: " "))" } ?? "")
}

struct TileAnimationRow: View {
    @Binding var animation: Tileset.TileAnimation
    let animTiles: [[UInt8]]
    let palette: [UInt16]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Characters \(animation.tile)-\(animation.tile + animation.tiles - 1)").font(.caption)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(animation.frames.enumerated()), id: \.offset) { f, src in
                        VStack(spacing: 2) {
                            HStack(spacing: 0) {
                                ForEach(0..<animation.tiles, id: \.self) { k in
                                    TileImage(pixels: src + k < animTiles.count ? animTiles[src + k] : [UInt8](repeating: 0, count: 64),
                                              palette: palette, scale: 2)
                                }
                            }
                            Stepper("\(f < animation.steps.count ? animation.steps[f] : 0)",
                                    value: Binding(get: { f < animation.steps.count ? animation.steps[f] : 0 },
                                                   set: { if f < animation.steps.count { animation.steps[f] = $0 } }),
                                    in: 0...255)
                                .font(.system(size: 9))
                        }
                    }
                }
            }
            Text("Frame f lasts 512 / (4 x step f) uploads; step 0 holds the frame.").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

/// The 1024 characters a tilemap word can name: which the tileset's uploads
/// set, which an upload sends stale (a short pack), which animations rewrite.
struct VRAMBudgetView: View {
    let tileset: Tileset

    var body: some View {
        let b = TilesetBudget(tileset)
        VStack(alignment: .leading, spacing: 4) {
            Text("VRAM budget").font(.subheadline)
            Canvas { ctx, size in
                let w = size.width / 1024
                func fill(_ r: Range<Int>, _ color: Color) {
                    ctx.fill(Path(CGRect(x: CGFloat(r.lowerBound) * w, y: 0, width: CGFloat(r.count) * w, height: size.height)), with: .color(color))
                }
                fill(0..<1024, Color(white: 0.2))
                for s in tileset.vram?.slots ?? [] where s.pack != nil {
                    fill(s.firstTile..<(s.firstTile + s.tiles), .orange.opacity(0.7))
                }
                for s in tileset.vram?.known ?? [] { fill(s.firstTile..<(s.firstTile + s.tiles), .green.opacity(0.8)) }
                for a in tileset.tileAnimations ?? [] { fill(a.tile..<(a.tile + a.tiles), .purple) }
            }
            .frame(height: 14)
            HStack(spacing: 10) {
                legend(.green, "set by the tileset (\(b.known))")
                legend(.orange, "stale stage bytes")
                legend(.purple, "animated (\(b.animated))")
            }
            .font(.system(size: 9))
            Text("\(b.uploaded) characters uploaded = \(b.bytes) B of VRAM; the metatiles name \(b.named)" +
                 (b.namedUnknown.isEmpty ? "." : ", \(b.namedUnknown.count) of them not set here (the game shows what VRAM holds)."))
                .font(.caption).foregroundStyle(.secondary)
            if let slots = tileset.vram?.slots, !slots.isEmpty {
                ForEach(slots, id: \.slot) { s in
                    Text(String(format: "slot %d  $%04X  %4d-%4d  ", s.slot, s.vram, s.firstTile, s.firstTile + s.tiles - 1)
                         + (s.pack.map { "pack \($0) \(s.source ?? "")" + ((s.ownTiles ?? s.tiles) < s.tiles ? " (\(s.ownTiles!) own)" : "") } ?? "unused"))
                        .font(.system(size: 10, design: .monospaced))
                }
            }
        }
    }

    private func legend(_ c: Color, _ s: String) -> some View {
        HStack(spacing: 3) { Rectangle().fill(c).frame(width: 8, height: 8); Text(s) }
    }
}

// MARK: - Palette editor

struct PaletteEditor: View {
    let store: ProjectStore
    let project: CTProject
    @Binding var palette: Tileset

    @State private var selected = 0x11
    @State private var previewID: String?
    @State private var tiles: [[UInt8]] = []
    @State private var animTiles: [[UInt8]] = []
    @State private var animate = true

    private var tilesetIDs: [String] {
        project.tilesets.values.filter { $0.kind != "palette" && $0.sheet != nil }.map(\.id).sorted()
    }
    private var preview: Tileset? {
        let id = previewID ?? project.tilesets.values.filter { $0.preview?.palette == palette.id }.map(\.id).min()
        return id.flatMap { project.tilesets[$0] }
    }

    @ViewBuilder private var previewPane: some View {
        if let preview {
            TilesetPPUPreview(tileset: preview, tiles: tiles, animTiles: animTiles, palette: palette, animate: animate)
                .frame(width: 512)
        } else {
            ContentUnavailableView("No tileset to preview", systemImage: "square.grid.3x3")
                .frame(width: 512, height: 448)
        }
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(palette.id).font(.headline)
                Text(palette.rom.map { "\($0.family) \($0.index), set \($0.table), cycles \($0.animations ?? "-"), \($0.locations.count) locations" } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            HStack {
                Picker("Preview", selection: Binding(get: { preview?.id ?? "" }, set: { previewID = $0.isEmpty ? nil : $0 })) {
                    Text("none").tag("")
                    ForEach(tilesetIDs, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 180)
                Toggle("Animate", isOn: $animate)
                Spacer()
            }
            SideBySide(preview: { previewPane }, inspector: {
                VStack(alignment: .leading, spacing: 10) {
                    swatches
                    colourEditor
                    Divider()
                    cycles
                }
                .frame(width: 400, alignment: .leading)
            })
            ApplyBar(apply: { store.updateTileset(palette) })
        }
        .padding()
        }
        .onAppear(perform: loadPreview)
        .onChange(of: previewID) { loadPreview() }
    }

    private func loadPreview() {
        tiles = store.tilesetSheet(preview?.sheet).map(SpriteSheet.tiles) ?? []
        animTiles = store.tilesetSheet(preview?.animSheet).map(SpriteSheet.tiles) ?? []
    }

    private var rows: [[String]] { palette.palettes ?? [] }

    private func colour(_ i: Int) -> UInt16 {
        let r = i / 16, c = i % 16
        return r < rows.count && c < rows[r].count ? CTTilesetsHex.word(rows[r][c]) : 0
    }

    private func cycled(_ i: Int) -> Bool {
        (palette.paletteCycles ?? []).contains { c in
            (c.first...(c.first + c.count - (c.kind.hasPrefix("rotate") ? 0 : 1))).contains(i)
        }
    }

    private var swatches: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("CGRAM rows (the location sets colours 1-15 of rows 1-7)").font(.subheadline)
            ForEach(0..<max(rows.count, 8), id: \.self) { r in
                HStack(spacing: 2) {
                    Text("\(r)").font(.system(size: 9, design: .monospaced)).frame(width: 12)
                    ForEach(0..<16, id: \.self) { c in
                        let i = r * 16 + c
                        Rectangle().fill(Color(bgr555: colour(i)))
                            .frame(width: 18, height: 18)
                            .overlay(Rectangle().stroke(i == selected ? Color.accentColor : cycled(i) ? .yellow.opacity(0.8) : .clear,
                                                        lineWidth: i == selected ? 2 : 1))
                            .onTapGesture { selected = i }
                    }
                }
            }
            Text("Yellow: colours a cycle changes.").font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }

    private func channel(_ shift: UInt16) -> Binding<Int> {
        Binding(get: { Int(colour(selected) >> shift & 31) },
                set: { v in
                    let w = colour(selected) & ~(31 << shift) | UInt16(max(0, min(31, v))) << shift
                    setColour(selected, w)
                })
    }

    private func setColour(_ i: Int, _ w: UInt16) {
        var rs = rows
        while rs.count < 8 { rs.append([String](repeating: "0x0000", count: 16)) }
        rs[i / 16][i % 16] = BGR555(word: w).hex
        palette.palettes = rs
    }

    private var colourEditor: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color(bgr555: colour(selected))).frame(width: 36, height: 36)
            VStack(alignment: .leading) {
                Text(String(format: "colour $%02X (row %d, %d): %@", selected, selected / 16, selected % 16, BGR555(word: colour(selected)).hex))
                    .font(.system(.caption, design: .monospaced))
                HStack {
                    Stepper("R \(channel(0).wrappedValue)", value: channel(0), in: 0...31)
                    Stepper("G \(channel(5).wrappedValue)", value: channel(5), in: 0...31)
                    Stepper("B \(channel(10).wrappedValue)", value: channel(10), in: 0...31)
                }
                .font(.caption)
            }
        }
    }

    private var cycles: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Palette cycles").font(.subheadline)
                Spacer()
                Button("Add rotation") {
                    palette.paletteCycles = (palette.paletteCycles ?? []) + [Tileset.PaletteCycle(kind: "rotate-down", first: selected, count: 3, delay: 4)]
                }
                .disabled((palette.paletteCycles ?? []).count >= CTTilesetROM.bFilled)
            }
            ForEach(Array((palette.paletteCycles ?? []).enumerated()), id: \.offset) { i, _ in
                PaletteCycleRow(cycle: Binding(get: { palette.paletteCycles![i] }, set: { palette.paletteCycles![i] = $0 }),
                                remove: { palette.paletteCycles!.remove(at: i); if palette.paletteCycles!.isEmpty { palette.paletteCycles = nil } })
            }
            Text("The game runs at most \(CTTilesetROM.bFilled) per location palette. Delay 0 waits 256 frames.")
                .font(.system(size: 9)).foregroundStyle(.secondary)
        }
    }
}

enum CTTilesetsHex {
    static func word(_ s: String) -> UInt16 {
        UInt16(s.hasPrefix("0x") || s.hasPrefix("0X") ? String(s.dropFirst(2)) : s, radix: 16) ?? 0
    }
}

struct PaletteCycleRow: View {
    @Binding var cycle: Tileset.PaletteCycle
    let remove: () -> Void
    static let kinds = ["rotate-down", "rotate-up", "rom-frames", "list-frames"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("", selection: $cycle.kind) {
                    ForEach(Self.kinds, id: \.self) { Text($0).tag($0) }
                    if !Self.kinds.contains(cycle.kind) { Text(cycle.kind).tag(cycle.kind) }
                }
                .frame(width: 130)
                Spacer()
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            HStack {
                Stepper(String(format: "first $%02X", cycle.first), value: $cycle.first, in: 0...255)
                Stepper("count \(cycle.count)", value: $cycle.count, in: 1...(cycle.kind.hasPrefix("rotate") ? 254 : 16))
                Stepper("every \(cycle.delay == 0 ? 256 : cycle.delay)", value: $cycle.delay, in: 0...255)
            }
            .font(.caption)
            if let frames = cycle.frames {
                ForEach(Array(frames.enumerated()), id: \.offset) { f, colours in
                    HStack(spacing: 1) {
                        Text("\(f)").font(.system(size: 9, design: .monospaced)).frame(width: 14)
                        ForEach(Array(colours.enumerated()), id: \.offset) { _, h in
                            Rectangle().fill(Color(bgr555: CTTilesetsHex.word(h))).frame(width: 14, height: 14)
                        }
                    }
                }
            }
            if cycle.kind == "list-frames" {
                TextField("order", text: Binding(
                    get: { (cycle.order ?? []).map(String.init).joined(separator: " ") },
                    set: { cycle.order = $0.split(separator: " ").compactMap { Int($0) }.filter { $0 < (cycle.frames?.count ?? 0) } }))
                    .font(.caption)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }
}
