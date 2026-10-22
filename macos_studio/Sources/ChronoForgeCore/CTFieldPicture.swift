// CTFieldPicture.swift — what a CTFieldRuntime frame looks like: the
// location's layers at the runtime's camera (LocationScene, when the project
// has the map and its tilesets), each active object's current frame as four
// 16x16 OBJs, and the dialogue box as an RGBA band to lay over the picture.
//
// An object's frame comes from the tables its init opcode filled
// (Obj_GfxBank/Ofs: the 4bpp tiles, in the ROM or unpacked to bank $7F;
// Obj_FrameBank/Ofs: 40-byte frame records; Obj_AnimFrameTbl/FacingStride:
// the frame ids in bank $E4; Obj_PalSrc: 12 colours in bank $E4) and the
// animation state Obj_AnimTickAndQueue keeps. The game streams the cells
// through SprBuf and Obj_DrawLink's OAM lists; here each object gets its own
// OBJ tiles and the OAM is ordered by Y (lower on screen in front).
import Foundation

public enum CTFieldPicture {
    public static let objFixedFrame = 0x7E1301
    /// 16x16 blocks of OBJ tiles (block b: tiles 2(b % 8) + 32(b / 8) and the
    /// three after it); block 0 stays LocationScene's treasure placeholder.
    static let blocks = 1..<64

    public struct Sprite: Equatable, Sendable {
        public var object: Int, frame: Int, x: Int, y: Int, palette: Int, priority: Int
    }

    /// The frame id object `slot` shows, nil when it draws nothing.
    public static func frameID(_ vm: CTEventVM, slot s: Int) -> Int? {
        let w = vm.wram
        guard w[WRAM.objUnk0F00 + s] & 0x80 != 0, w[WRAM.objUnk1100 + s] & 0x80 == 0 else { return nil }
        let u = w[WRAM.objUnk1A81 + s]
        guard u != 0, u & 0x80 == 0 else { return nil }
        let mode = w[WRAM.objAnimMode + s]
        if mode == 3 { return Int(w[objFixedFrame + s]) }
        let row = Int(mode <= 1 ? w[WRAM.objAnimRow + s] : w[WRAM.objAnimRowAlt + s])
        guard row != 0xFF else { return nil }
        let facing = Int(w[WRAM.objFacing + s] & 3), stride = w.word(WRAM.objAnimFacingStride + s)
        let column = Int(w[WRAM.objAnimColumn + s])
        let at = (w.word(WRAM.objAnimFrameTbl + s) + facing * stride + row * 4 + column) & 0xFFFF
        let id = Int(vm.read(WRAM.animRom | at))
        if id != 0xFF { return id }
        let first = (w.word(WRAM.objAnimFrameTbl + s) + facing * stride + row * 4) & 0xFFFF
        let f = Int(vm.read(WRAM.animRom | first))
        return f == 0xFF ? nil : f
    }

    /// The field picture: `base` (the location at the runtime's camera, or a
    /// blank frame) with the objects' OBJs.
    public static func frame(_ field: CTFieldRuntime, base: PPUFrame?) -> (picture: PPUFrame, sprites: [Sprite]) {
        var f = base ?? {
            var r = PPURegisters()
            r.tm = 0x10
            var p = PPUFrame(registers: r)
            p.cgram[0] = 0x0C63
            return p
        }()
        f.setAllLines { $0.obsel = 0x00; $0.tm |= 0x10 }
        for i in 0..<128 { f.setOBJ(i, x: 0, y: 240, tile: 0) }
        let vm = field.vm, w = vm.wram
        var order: [(slot: Int, y: Int)] = []
        for o in 0..<vm.pack.objectCount where frameID(vm, slot: 2 * o) != nil {
            order.append((2 * o, w.word(WRAM.objPosY + 2 * o)))
        }
        order.sort { $0.y > $1.y }
        var palettes: [Int: Int] = [:], nextOBJ = 0, nextBlock = blocks.lowerBound
        var sprites: [Sprite] = []
        for (s, _) in order {
            guard let id = frameID(vm, slot: s), nextBlock + 4 <= blocks.upperBound, nextOBJ + 4 <= 128 else { continue }
            let palSrc = w.word(WRAM.objPalSrc + s)
            let pal: Int
            if let p = palettes[palSrc] { pal = p } else {
                guard palettes.count < 8 else { continue }
                pal = palettes.count
                palettes[palSrc] = pal
                for c in 0..<12 {
                    let at = WRAM.animRom | ((palSrc + 2 * c) & 0xFFFF)
                    f.cgram[128 + 16 * pal + 1 + c] = UInt16(vm.read(at)) | UInt16(vm.read(at + 1)) << 8
                }
            }
            let frames = Int(w[WRAM.objFrameBank + s]) << 16 | w.word(WRAM.objFrameOfs + s)
            let gfx = Int(w[WRAM.objGfxBank + s]) << 16 | w.word(WRAM.objGfxOfs + s)
            let rec = (0..<CTSpriteROM.frameBytes).map { vm.read(frames + CTSpriteROM.frameBytes * id + $0) }
            let decoded = CTSpriteROM.decodeFrame(rec[...])
            let sx = (w.word(WRAM.objPosX + s) >> 4) - field.camera.x
            let sy = (w.word(WRAM.objPosY + s) >> 4) - field.camera.y
            let priority = Int(w[WRAM.objPrioHigh + s] >> 4 & 3)
            for n in 0..<CTSpriteROM.pieces {
                let block = nextBlock + n
                let tile0 = 2 * (block % 8) + 32 * (block / 8)
                for (r, c) in [(0, 0), (0, 1), (1, 0), (1, 1)] {
                    let cell = decoded.cells[r * CTSpriteROM.columns + 2 * n + c]
                    let t = cell & CTSpriteROM.tileMask
                    var px = [UInt8](repeating: 0, count: 64)
                    if t != 0 {
                        let bytes = (0..<CTSpriteROM.tileBytes).map { vm.read(gfx + CTSpriteROM.tileBytes * t + $0) }
                        px = TileDecoder.decodeIndices(bytes, depth: .bpp4)
                        if cell & CTSpriteROM.hflip != 0 { px = SpriteSheet.mirrored(px) }
                    }
                    f.storeTiles(px, bpp: 4, atWord: PPUOBJEvaluator.tileAddress(tile0 + CTSpriteROM.vramRow * r + c, obsel: 0))
                }
                let p = decoded.pieces[n]
                let ox = sx + p.x, oy = sy + p.y
                guard (-16..<256).contains(ox), (-16..<224).contains(oy) else { continue }
                f.setOBJ(nextOBJ, x: ox, y: oy & 0xFF, tile: tile0, palette: pal, priority: priority, large: true)
                nextOBJ += 1
            }
            nextBlock += CTSpriteROM.pieces
            sprites.append(Sprite(object: s / 2, frame: id, x: sx, y: sy, palette: pal, priority: priority))
        }
        return (f, sprites)
    }

    /// The location under the runtime's camera, when the project has its map.
    public static func base(_ field: CTFieldRuntime, map: GameMap?, assets: LocationScene.Assets?,
                            cgram: [UInt16]? = nil) -> PPUFrame? {
        guard let map, let assets else { return nil }
        return LocationScene.frame(map, assets: assets, cgram: cgram ?? TilesetScene.cgram(assets.palette),
                                   cameraX: field.camera.x, cameraY: field.camera.y)
    }

    /// 256 x 224 RGBA: the picture with the box over it.
    public static func render(_ field: CTFieldRuntime, map: GameMap?, assets: LocationScene.Assets?) -> [UInt8] {
        var rgba = PPUReferenceRenderer.render(frame(field, base: base(field, map: map, assets: assets)).picture)
        if let box = dialogue(field) {
            for i in stride(from: 0, to: rgba.count, by: 4) where box[i + 3] != 0 {
                rgba.replaceSubrange(i..<(i + 4), with: box[i..<(i + 4)])
            }
        }
        return rgba
    }

    /// The open dialogue box as 256 x 224 RGBA, transparent outside its band.
    public static func dialogue(_ field: CTFieldRuntime) -> [UInt8]? {
        guard let d = field.dialogue, !d.layout.frames.isEmpty else { return nil }
        let t = min(d.frame, d.layout.frames.count - 1)
        let state = d.layout.frames[t]
        guard state.open > 0 else { return nil }
        var rgba = CTDialogueBox(rom: field.rom).render(d.layout, at: t)
        let band = CTDialogueBox.boxLines(place: state.place)
        let mid = band.lowerBound + band.count / 2
        let rows = max(0, mid - state.open)..<min(224, mid + state.open)
        for y in 0..<224 where !rows.contains(y) {
            for x in 0..<256 { rgba[(y * 256 + x) * 4 + 3] = 0 }
        }
        return rgba
    }
}
