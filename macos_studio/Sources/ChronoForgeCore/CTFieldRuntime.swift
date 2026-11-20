// CTFieldRuntime.swift — the field around CTEventVM: a location's pack, map
// and tile properties loaded into one WRAMModel, and one frame of the field
// loop (GameLoop_FrameBody) at a time:
//
//   Field_SceneChangeTick  a pending warp (SceneFlag_Warp) loads Loc_Dest*
//   Field_FrameUpdate      the D-pad step (Field_DpadDispatch), the leader's
//                          probes and corner slides (Map_Unk8A6D), the
//                          tile effects (Map_StepTileEffects: level, exits,
//                          push; CTFieldProbes.swift), the column/row
//                          limits (Map_Unk9175) and
//                          the camera (Map_Unk99DE, Map_Unk91AC, layer 1 of
//                          Map_Unk93E1: CTFieldScroll.swift)
//   DefaultHandler         a map redraw ($E5) steps the camera to a 16-pixel
//                          boundary (Field_Unk885A) before its copy
//   Field_ActionButton     A in front of an object starts its function 1
//   Field_Unk1F87          the dialogue box, paced by CTDialogueLayout
//   Field_EndOfFrame       the scripts (Vblank_Unk59D9 + every queued object),
//                          then each object's motion and view (Vblank_UnkA810)
//
// What is not modelled is named where it is skipped (`limitations`), so the
// runtime never pretends: layers 2 and 3's scroll, Evt_PushTarget,
// battles, menus.
import Foundation

extension WRAM {
    public static let mapTileProps = 0x7E3000, mapTileHiBits = 0x7E30C0
    public static let mapTileAttrA = 0x7E7000, mapTileAttrB = 0x7E7040
    public static let mapTileExitIdx = 0x7E7080, mapTreasureIdx = 0x7E70C0
    public static let mapRowStride = 0x100
    public static let mapTileOriginX = 0x7E1D0A, mapUnk1D0C = 0x7E1D0C
    public static let mapTileOriginY = 0x7E1D0E, mapUnk1D10 = 0x7E1D10
    public static let mapLimitLeft = 0x7E1D1A, mapLimitRight = 0x7E1D1B   // Map_Unk1D1A-1D1D
    public static let mapLimitTop = 0x7E1D1C, mapLimitBottom = 0x7E1D1D
    public static let mapColMask1 = 0x7E1D1E, mapRowMask1 = 0x7E1D1F
    public static let mapUnk1D2A = 0x7E1D2A, mapUnk1D2B = 0x7E1D2B           // push steps
    public static let mapUnk1D2C = 0x7E1D2C, mapUnk1D2D = 0x7E1D2D           // D-pad steps
    public static let mapUnk1D2E = 0x7E1D2E, mapUnk1D30 = 0x7E1D30           // the frame's step
    public static let mapUnk1D32 = 0x7E1D32, mapUnk1D33 = 0x7E1D33           // the leader's velocity
    public static let mapUnk1D34 = 0x7E1D34
    public static let fieldUnk20 = dpField + 0x20, fieldUnk34 = dpField + 0x34
    public static let fieldUnk55 = dpField + 0x55
    public static let objScreenX = 0x7E0A00, objScreenY = 0x7E0A80
    public static let objVelYHi = 0x7E1981, objArcGravity = 0x7E1B81
    public static let objDrawPrev = 0x7E0E80, objDrawNext = 0x7E0E81
    public static let animRom = 0xE40000
    public static let charNames = 0x7E2C23
}

/// SNES pad bits (JOY1 order): B Y Select Start Up Down Left Right, A X L R.
public struct CTFieldInput: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let b = CTFieldInput(rawValue: 0x8000), y = CTFieldInput(rawValue: 0x4000)
    public static let select = CTFieldInput(rawValue: 0x2000), start = CTFieldInput(rawValue: 0x1000)
    public static let up = CTFieldInput(rawValue: 0x0800), down = CTFieldInput(rawValue: 0x0400)
    public static let left = CTFieldInput(rawValue: 0x0200), right = CTFieldInput(rawValue: 0x0100)
    public static let a = CTFieldInput(rawValue: 0x0080), x = CTFieldInput(rawValue: 0x0040)
    public static let l = CTFieldInput(rawValue: 0x0020), r = CTFieldInput(rawValue: 0x0010)

    public static let names: [(String, CTFieldInput)] = [("up", .up), ("down", .down), ("left", .left), ("right", .right),
                                                          ("a", .a), ("b", .b), ("x", .x), ("y", .y), ("l", .l), ("r", .r),
                                                          ("start", .start), ("select", .select)]

    /// An input script: entries `FROM[-TO] BUTTON[+BUTTON...]` separated by
    /// newlines or `;`, `#` to the end of a line a comment. A frame with no
    /// entry holds nothing.
    public struct Script: Equatable, Sendable {
        public var entries: [(frames: ClosedRange<Int>, buttons: CTFieldInput)]
        public init(entries: [(frames: ClosedRange<Int>, buttons: CTFieldInput)]) { self.entries = entries }
        public static func == (a: Script, b: Script) -> Bool {
            a.entries.map { [$0.frames.lowerBound, $0.frames.upperBound, Int($0.buttons.rawValue)] }
                == b.entries.map { [$0.frames.lowerBound, $0.frames.upperBound, Int($0.buttons.rawValue)] }
        }
        public func held(at frame: Int) -> CTFieldInput {
            var out: CTFieldInput = []
            for e in entries where e.frames.contains(frame) { out.formUnion(e.buttons) }
            return out
        }
        public var lastFrame: Int { entries.map(\.frames.upperBound).max() ?? -1 }
    }

    public static func parse(_ text: String) throws -> Script {
        var entries: [(ClosedRange<Int>, CTFieldInput)] = []
        for raw in text.split(whereSeparator: { $0.isNewline || $0 == ";" }) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { throw CTEventError("input: '\(line)' is not FROM[-TO] BUTTONS") }
            let bounds = parts[0].split(separator: "-").map { Int($0) }
            guard (1...2).contains(bounds.count), let from = bounds[0], let to = bounds.last ?? nil, from >= 0, to >= from else {
                throw CTEventError("input: bad frames '\(parts[0])'")
            }
            var buttons: CTFieldInput = []
            for name in parts[1].lowercased().split(separator: "+") {
                guard let b = names.first(where: { $0.0 == name })?.1 else { throw CTEventError("input: no button '\(name)'") }
                buttons.insert(b)
            }
            entries.append((from...to, buttons))
        }
        return Script(entries: entries)
    }
}

public final class CTFieldRuntime {
    public let rom: [UInt8]
    public let vm: CTEventVM
    public private(set) var location: Int
    public private(set) var map: CTMapROM.Decoded
    public private(set) var gameMap: GameMap
    public private(set) var props: CTTilePropsPlane?
    public private(set) var frameCount = 0
    /// The camera's top-left in pixels (CTEventVM.cameraPixels after the frame's scroll).
    public private(set) var camera = (x: 0, y: 0)
    public private(set) var held: CTFieldInput = []
    public private(set) var pressed: CTFieldInput = []

    public struct Message: Codable, Equatable, Sendable {
        public var frame: Int, slot: Int, table: Int, index: Int, text: Int, error: String?
        public var closedAt: Int?
    }
    public struct Warp: Codable, Equatable, Sendable {
        public var frame: Int, from: Int, to: Int, x: Int, y: Int, facing: Int
    }
    public private(set) var messages: [Message] = []
    public private(set) var warps: [Warp] = []
    /// The open box: its layout and the layout frame shown.
    public private(set) var dialogue: (layout: CTDialogueLayout, frame: Int)?
    /// Sound-driver commands, oldest first (drained from the VM each frame).
    public private(set) var audio: [(frame: Int, command: CTEventVM.AudioCommand)] = []
    /// Party, inventory and gold changes, oldest first (drained from the VM each frame).
    public private(set) var changes: [(frame: Int, change: CTEventVM.StateChange)] = []
    /// The map cells region copies changed since the location loaded, by layer (row << 8 | column).
    public private(set) var mapEdits: [Int: Set<Int>] = [:]
    /// Counts the region copies drained, so a cached picture of the map knows to rebuild.
    public private(set) var mapRevision = 0
    /// Packs to run instead of the ROM's, by location (an edited scene).
    public var packOverrides: [Int: CTEventPack] = [:]
    /// Opt-in: run Map_Unk91AC's scroll-to, so `$E7` moves the camera and
    /// arrives. Off, Map_ScrollToMode stays as `$E7` set it and the opcode
    /// waits (as `runtime run` and `scene vm --no-scroll` have it).
    public var runsScrollTo = false
    /// A loop count of 3 or more drops by two at a row's end, as
    /// Obj_AnimTickAndQueue does (DEC, DEC, STA; ct_scene_run.py durations:
    /// 24 of 24 animation cases). Off only to replay traces taken before
    /// 2026-10-23, when the model took one off.
    public var romAnimLoops = true

    public static let limitations = [
        "camera: layer 1 only (Map_Unk93E1's layers 2 and 3, their own steps and the edge builders are not run); the redraw's own frames after Field_Unk885A (Field_BuildC800Mode*) are not counted",
        "Evt_PushTarget (pushing objects) and treasure opening are not run",
        "the dialogue box's own code (Field_Unk1F87) is CTDialogueLayout's; the D-pad is held while the box is open; a choice answers its first line",
        "the frame-build queue (ObjQ_Head/Tail) is drained every frame, so every object's animation advances",
        "Party_LeaderAnim: no idle rows (Party_AnimIdle) and no shape-$1E stair row; followers hold their place (Party_UnkA26B/A2CE not run)",
        "battles, menus and fades are not run",
        "palettes: the location's own animation records (FieldFD_LoadAnimSetB) and Pal_Buf row 0 are not loaded; the picture takes the background from the project's palette and only the colours the palette opcodes wrote from Pal_CgramBuf",
        "after a party or item-count command, Menu_RunCommand's refresh (Menu_Unk834D: weapon records, BankFF_UnkF958, Menu_Unk82E1) is not run",
    ]

    /// `wram`: carried over (a warp keeps it); nil starts from zeroes with the
    /// default party.
    public init(rom: [UInt8], location: Int, party: [UInt8] = [0, 0x80, 0x80], wram: WRAMModel? = nil) throws {
        guard rom.count == 4_194_304 else { throw CTEventError("expected a 4 MiB unheadered ROM") }
        guard (0..<CTMapROM.locCount).contains(location) else { throw CTEventError("no location \(location)") }
        self.rom = rom
        self.location = location
        let decoded = try CTMapROM.decode(rom, location)
        map = decoded
        gameMap = CTMaps.gameMap(decoded)
        props = gameMap.tileProps.flatMap(CTTilePropsPlane.init)
        vm = CTEventVM(pack: try CTEventPack(bytes: [0]), rom: rom, wram: wram ?? WRAMModel())
        if wram == nil {
            for k in 0..<3 { vm.wram[WRAM.partyMembers + k] = k < party.count ? party[k] : 0x80 }
            for k in 3..<9 { vm.wram[WRAM.menuPartyOrder + k] = 0x80 }   // the reserve: empty places
            setEntry(x: (map.limits.left + map.limits.right) / 2, y: (map.limits.top + map.limits.bottom) / 2, facing: 1)
        }
        vm.party = { [unowned self] in self.partyRequest($0) }
    }

    /// The entry tile and facing the next `start` uses (Loc_EntryX/Y, Loc_EntryFacing).
    public func setEntry(x: Int, y: Int, facing: Int) {
        vm.wram[WRAM.locEntryX] = UInt8(x & 0xFF); vm.wram[WRAM.locEntryY] = UInt8(y & 0xFF)
        vm.wram[WRAM.locEntryFacing] = UInt8(facing & 0xFF)
    }

    // MARK: Loading

    /// GameLoop_LoadField for `location`: Field_InitLoadState, the map's
    /// planes, the pack and Evt_InitObjects (which places the party on the
    /// entry tile), then Map_InitEntryTile's level.
    public func start() throws {
        var w = vm.wram
        w.setWord(WRAM.locId, location)
        initLoadState(&w)
        audioSetup(&w)                                              // LoadLocation's sound step
        for a in WRAM.mapPage..<(WRAM.mapPage + 0x100) { w[a] = 0 }  // LocLoad_ClearPage1D00
        try loadMap(&w)
        vm.wram = w
        vm.exitRecords = map.exits.map(\.raw)
        vm.loadLocationPalette(map.header.palette)                 // LocLoad_Unk7084, Pal_LoadUnkRow0's copy
        let entry = try CTEventROM.entries(rom: rom)
        let events = map.header.events
        guard events < entry.count else { throw CTEventError("location \(location): no event pack \(events)") }
        let pack = try packOverrides[location] ?? CTEventPack(bytes: CTEventROM.unpack(rom: rom, entry: entry[events]))
        for a in 0..<16 { vm.wram[WRAM.evtUnk0920 + a] = 0xFF }     // Evt_ClearUnk0920
        vm.load(pack: pack)
        vm.seedPartyBlocks()                                        // LocLoad_InitUnk7F3700
        vm.initObjects()
        runObj0Func1()
        vm.initEntryTile()                                          // Map_InitEntryTile
        vm.initOrigin()                                             // LocLoad_DrawMap's Map_InitOrigin
        camera = vm.cameraPixels
    }

    /// Evt_RunObj0Func1: object 0's function 1 to its $00, at once (the
    /// position is not kept).
    func runObj0Func1() {
        guard vm.pack.objectCount > 0 else { return }
        vm.wram.setWord(WRAM.objCur, 0)
        var x = vm.pack.functions[0][1], steps = 0
        while vm.data(x) != 0, steps < 4096 {
            steps += 1
            guard case .go(let next, _) = vm.execute(at: x) else { return }
            x = next
        }
    }

    func initLoadState(_ w: inout WRAMModel) {
        w.setWord(WRAM.locPrevId, w.word(WRAM.locId))
        w.setWord(WRAM.locPrevX, w.word(WRAM.locEntryX))
        w[WRAM.locPrevFacing] = w[WRAM.locEntryFacing]
        for a in [WRAM.fieldSceneFlags, WRAM.fieldFadeFlags, WRAM.fieldUnk38, WRAM.fadeBrightness, WRAM.fieldUnk29,
                  WRAM.fieldUnk2D, WRAM.fieldUnk30, WRAM.objQUnk78, WRAM.fieldUnk62, WRAM.fieldUnk54] { w[a] = 0 }
        w.setWord(WRAM.fieldUnk2B, 0)
        w[WRAM.fieldControlEnabled] = 1; w[WRAM.fieldUnk20] = 1
        w[WRAM.fieldUnk68] = 5
        w[WRAM.fieldUnkEB] = 0x80
        for k in 0..<4 {                                            // Field_E4Ptr0-3 from RomE4_PtrInit
            let lo = Int(rom[0x24FFE0 + 2 * k]) | Int(rom[0x24FFE1 + 2 * k]) << 8
            w.setWord(WRAM.fieldE4Ptr0 + 3 * k, lo); w[WRAM.fieldE4Ptr0 + 3 * k + 2] = 0xE4
        }
        w.setWord(WRAM.padUnk00F6Latch, 0)
        for s in [WRAM.partyObjSlot, WRAM.partyObjSlot1, WRAM.partyObjSlot2] { w[s] = 0x80 }
    }

    /// LocLoad_AudioSetup: with Audio_Unk7F01ED set, Audio_CmdPlayMusic with
    /// Menu_Config1E; else Audio_CmdUnk81 (0, $FF, $FF), then the location's
    /// music (LocRom.Music, bit 7: no change), kept in Menu_Config1E and
    /// played. The commands join `audio` at the load's frame.
    func audioSetup(_ w: inout WRAMModel) {
        func send(_ id: UInt8) {
            w[0x7E1E00] = id                                        // Audio_CmdId
            audio.append((frameCount, CTEventVM.AudioCommand(id: id, arg0: w[0x7E1E01], arg1: w[0x7E1E02], arg2: w[0x7E1E03])))
        }
        var track = w[0x7E29AE]                                     // Menu_Config1E
        if w[0x7F01ED] == 0 {                                       // Audio_Unk7F01ED
            w[0x7E1E01] = 0; w[0x7E1E02] = 0xFF; w[0x7E1E03] = 0xFF
            send(0x81)                                              // Audio_CmdUnk81
            let music = UInt8(map.header.music & 0xFF)
            if music & 0x80 != 0 { return }
            w[0x7E29AE] = music
            track = music
        }
        w[0x7E1E01] = track
        send(0x10)                                                  // Audio_CmdPlayMusic
    }

    /// Map_InitMasksAndLimits and the tile planes: Map_TileHiBits/AttrA/AttrB
    /// from the props image, Map_TileExitIdx (Map_LoadExitTiles) and
    /// Map_TreasureIdx, each row << 8 | column; Map_ExitRec0 the location's
    /// ExitRom offset (the records themselves are the map's: `exitRecords`).
    func loadMap(_ w: inout WRAMModel) throws {
        let ptr = 0x250000 + 2 * (location & 0x1FF)
        let lo: Int = Int(rom[ptr]), hi: Int = Int(rom[ptr + 1])
        w.setWord(WRAM.mapExitRec0, lo | hi << 8)
        let (col, row) = map.masks[0]
        w[WRAM.mapColMask1] = UInt8(col); w[WRAM.mapRowMask1] = UInt8(row)
        w[WRAM.mapLimitLeft] = UInt8(map.limits.left & 0xFF); w[WRAM.mapLimitTop] = UInt8(map.limits.top & 0xFF)
        w[WRAM.mapLimitRight] = UInt8(map.limits.right & 0xFF); w[WRAM.mapLimitBottom] = UInt8(map.limits.bottom & 0xFF)
        for r in 0..<64 {
            for c in 0..<64 {
                let i = r * WRAM.mapRowStride + c
                w[WRAM.mapTileHiBits + i] = 0; w[WRAM.mapTileAttrA + i] = 0; w[WRAM.mapTileAttrB + i] = 0
                w[WRAM.mapTileExitIdx + i] = 0x80; w[WRAM.mapTreasureIdx + i] = 0x80
            }
        }
        for (k, plane) in [WRAM.mapLayer1Tiles, WRAM.mapLayer2Tiles, WRAM.mapLayer3Tiles].enumerated() {
            guard let tiles = map.props.planes[k + 1] else { continue }
            let size = map.props.sizes[k]
            for r in 0..<min(64, size.height) {
                for c in 0..<min(64, size.width) { w[plane + r * WRAM.mapRowStride + c] = UInt8(tiles[r * size.width + c] & 0xFF) }
            }
        }
        if let p = props {
            for r in 0..<min(64, p.height) {
                for c in 0..<min(64, p.width) {
                    let i = r * WRAM.mapRowStride + c, t = p[c, r]
                    w[WRAM.mapTileHiBits + i] = t.hiBits; w[WRAM.mapTileAttrA + i] = t.attrA; w[WRAM.mapTileAttrB + i] = t.attrB
                }
            }
        }
        let tiles = CTMapROM.exitTiles(map.exits.map { ($0.x, $0.y, $0.span, $0.vertical) }, colMask: col, rowMask: row)
        for (at, rec) in tiles { w[WRAM.mapTileExitIdx + at] = UInt8(rec & 0x7F) }
        for (k, t) in map.treasure.enumerated() where t.tile != 0 {
            w[WRAM.mapTreasureIdx + ((t.y & row) << 8 | (t.x & col))] = UInt8(k & 0x7F)
        }
    }

    // MARK: One frame

    public func step(input: CTFieldInput) throws {
        pressed = input.subtracting(held)
        held = input
        if vm.wram[WRAM.fieldSceneFlags] & 0x80 != 0 { try warp(); return }
        if vm.wram[WRAM.fieldSceneFlags] & 0x20 != 0 {                 // DefaultHandler: SceneFlag_MapRedraw
            vm.wram[WRAM.fieldSceneFlags] &= ~0x20
            vm.wram[WRAM.fieldUnk38] = 1
        }
        if vm.wram[WRAM.fieldUnk38] != 0 { redrawFrame(); return }
        frameUpdate()
        actionButton()
        dialogueFrame()
        vm.frame()
        for c in vm.audio { audio.append((frameCount, c)) }
        vm.audio.removeAll()
        for c in vm.changes { changes.append((frameCount, c)) }
        vm.changes.removeAll()
        drainMapCopies()
        vm.palAnimTick()                                            // FdVec_FFF7: PalAnim_TickAll
        objectMotion()
        frameCount += 1
    }

    /// One frame of DefaultHandler's redraw loop: Field_Unk885A, then
    /// Field_EndOfFrame (the scripts and the objects); once Field_Unk38 is
    /// clear, the copy (Field_UnkAF4E) and FdVec_FFF7.
    func redrawFrame() {
        let mode = vm.wram[WRAM.mapScrollToMode]
        if !runsScrollTo { vm.wram[WRAM.mapScrollToMode] = 0 }
        vm.recentreStep()
        if !runsScrollTo { vm.wram[WRAM.mapScrollToMode] = mode }
        camera = vm.cameraPixels
        vm.frame()
        for c in vm.audio { audio.append((frameCount, c)) }
        vm.audio.removeAll()
        for c in vm.changes { changes.append((frameCount, c)) }
        vm.changes.removeAll()
        objectMotion()
        if vm.wram[WRAM.fieldUnk38] == 0 {
            vm.copyMapRegion()
            drainMapCopies()
            vm.palAnimTick()
        }
        frameCount += 1
    }

    /// Field_SceneChangeTick's warp: Loc_Return* from the leader, Loc_Id and
    /// the entry from Loc_Dest*, then the load (WRAM kept).
    func warp() throws {
        var w = vm.wram
        let leader = Int(w[WRAM.partyObjSlot])
        w.setWord(WRAM.locReturnId, w.word(WRAM.locId))
        if leader & 0x80 == 0 {
            w[WRAM.locReturnX] = w[WRAM.objTileX + leader]; w[WRAM.locReturnY] = w[WRAM.objTileY + leader]
            w[WRAM.locReturnFacing] = w[WRAM.objFacing + leader] ^ 1
        }
        let dest = w.word(WRAM.locDestId) & 0x1FF
        w.setWord(WRAM.locId, dest)
        w.setWord(WRAM.locEntryX, w.word(WRAM.locDestX))
        w[WRAM.locEntryFacing] = w[WRAM.locDestFacing]
        vm.wram = w
        warps.append(Warp(frame: frameCount, from: location, to: dest, x: Int(w[WRAM.locDestX]),
                          y: Int(w[WRAM.locDestX + 1]), facing: Int(w[WRAM.locDestFacing])))
        frameCount += 1
        guard dest < CTMapROM.locCount, dest < CTMapROM.destWorld else {
            throw CTEventError("warp to \(dest): not a field location (overworld or a special destination)")
        }
        location = dest
        mapEdits = [:]
        map = try CTMapROM.decode(rom, dest)
        gameMap = CTMaps.gameMap(map)
        props = gameMap.tileProps.flatMap(CTTilePropsPlane.init)
        dialogue = nil
        try start()
    }

    /// Field_FrameUpdate: Field_UnkEB reset, the push step, the D-pad, the
    /// leader's probes and the limits.
    func frameUpdate() {
        vm.wram[WRAM.fieldUnkEB] = 0x80
        vm.wram[WRAM.mapUnk1D2E] = vm.wram[WRAM.mapUnk1D2A]         // Map_ResetUnk1D2E
        vm.wram[WRAM.mapUnk1D30] = vm.wram[WRAM.mapUnk1D2B]
        vm.wram[WRAM.mapUnk1D2C] = 0; vm.wram[WRAM.mapUnk1D2D] = 0
        if vm.wram[WRAM.fieldUnk62] == 0, vm.wram[WRAM.fieldControlEnabled] != 0, dialogue == nil {
            dpad()
        }
        if vm.wram[WRAM.fieldUnk20] != 0 { leaderProbes() }
        vm.limitLeaderSteps()                                       // Map_Unk9175
        vm.dropCameraSteps()                                        // Map_Unk99DE
        let mode = vm.wram[WRAM.mapScrollToMode]
        if !runsScrollTo { vm.wram[WRAM.mapScrollToMode] = 0 }
        vm.accumulateScroll()                                       // Map_Unk91AC
        if !runsScrollTo { vm.wram[WRAM.mapScrollToMode] = mode }
        vm.stepScroll()                                             // Map_Unk93E1, layer 1
        camera = vm.cameraPixels
    }

    /// Field_DpadDispatch: ±$10 a frame, ±$20 with run (B, Pad_Unk00F8 bit 1).
    func dpad() {
        guard vm.wram[WRAM.fieldUnk38] == 0 else { return }
        let run = held.contains(.b)
        let pos: UInt8 = run ? 0x20 : 0x10, neg: UInt8 = run ? 0xE0 : 0xF0
        var dx: UInt8 = 0, dy: UInt8 = 0
        let dirs = (held.rawValue >> 8) & 0x0F                     // Pad_Unk00F9: R L D U
        switch dirs {
        case 1: dx = pos
        case 2: dx = neg
        case 4: dy = pos
        case 5: dx = pos; dy = pos
        case 6: dx = neg; dy = pos
        case 8: dy = neg
        case 9: dx = pos; dy = neg
        case 10: dx = neg; dy = neg
        default: return
        }
        if dx != 0 { vm.wram[WRAM.mapUnk1D2C] = dx; vm.wram[WRAM.mapUnk1D2E] &+= dx }
        if dy != 0 { vm.wram[WRAM.mapUnk1D2D] = dy; vm.wram[WRAM.mapUnk1D30] &+= dy }
    }

    static func signed(_ b: UInt8) -> Int { Int(Int8(bitPattern: b)) }

    /// Map_Unk8A6D (CTFieldProbes.swift): the leader's box against objects
    /// and tiles, its corner slides, then Map_StepTileEffects. No leader
    /// (slot $80) probes nothing here; the ROM would read slot $80.
    func leaderProbes() {
        guard vm.wram[WRAM.partyObjSlot] & 0x80 == 0 else { return }
        vm.leaderProbes()
    }

    /// Field_ActionButton: A (Pad_Unk00F6 bit 7) starts function 1 of the
    /// touched object, or of the object Field_FindObjInFront finds.
    func actionButton() {
        guard pressed.contains(.a), dialogue == nil else { return }
        let f34 = vm.wram.word(WRAM.fieldUnk34)
        if f34 == 0xFFFF { vm.wram.setWord(WRAM.fieldUnk34, 0); return }
        guard vm.wram[WRAM.fieldControlEnabled] != 0 else { return }
        if vm.wram[WRAM.fieldUnkEB] & 0x80 != 0 {
            guard findObjInFront() else { return }
        }
        startFunction(Int(vm.wram[WRAM.fieldUnkEB]), function: 1)
    }

    /// Field_FindObjInFront: from the last slot down to slot 2, the first
    /// in-view object within reach of the leader's facing (kind 7 objects
    /// count even when they are the leader).
    func findObjInFront() -> Bool {
        let w = vm.wram
        let leader = Int(w[WRAM.partyObjSlot])
        guard leader & 0x80 == 0 else { return false }
        let facing = Int(w[WRAM.objFacing + leader]) & 3
        let lx = w.word(WRAM.objPosX + leader), ly = w.word(WRAM.objPosY + leader)
        var slot = 2 * Int(w[WRAM.evtObjCount])
        while slot > 0 {
            defer { slot -= 2 }
            guard w[WRAM.objUnk0F00 + slot] != 0, w[WRAM.objUnk1100 + slot] & 0x80 == 0 else { continue }
            let kind7 = w[WRAM.objUnk1100 + slot] == 7
            if !kind7 && slot == leader { continue }
            let borrow = kind7 || slot >= leader ? 0 : 1                // SBC after CMP #7 / CPX Party_ObjSlot
            vm.wram[WRAM.fieldUnkEB] = UInt8(slot)
            let ox = w.word(WRAM.objPosX + slot), oy = w.word(WRAM.objPosY + slot)
            if inReach(facing: facing, ahead: (facing < 2 ? oy - ly : ox - lx) - borrow,
                       side: (facing < 2 ? ox - lx : oy - ly)) { return true }
        }
        vm.wram[WRAM.fieldUnkEB] = 0x80
        return false
    }

    /// Field_ObjInReachUp/Down/Left/Right: $1C0 ahead, $C0 to the side (the
    /// differences one's-complemented when negative, as the ROM does).
    func inReach(facing: Int, ahead: Int, side: Int) -> Bool {
        let a = Int16(truncatingIfNeeded: ahead), s = Int16(truncatingIfNeeded: side)
        let forward = facing == 0 || facing == 2 ? a < 0 : a >= 0
        guard forward else { return false }
        let distance = a < 0 ? Int(~a) : Int(a)
        guard distance < 0x1C0 else { return false }
        let across = s < 0 ? Int(~s) : Int(s)
        return across < 0xC0
    }

    /// Evt_StartTargetFunc1 (function 1, level 1, from level 2 up) and
    /// Evt_StartTargetFunc2 (function 2, level 2, from level 3 up): the
    /// position saved at the old level, the function's start the new.
    func startFunction(_ s: Int, function f: Int) {
        guard s & 0x80 == 0 else { return }
        if vm.wram[WRAM.objUnk1C01 + s] != 0 || vm.wram[WRAM.objUnk1100 + s] & 0x80 != 0
            || vm.wram[WRAM.objUnk1000 + s] & 0x80 != 0 { return }
        let level = Int(vm.wram[WRAM.objUnk1C00 + s])
        guard level >= (f == 1 ? 2 : 3) else { return }
        let index = (level * WRAM.evtPrioStride + s) & 0xFFFF
        vm.wram.setWord(WRAM.objXSave + index, vm.wram.word(WRAM.objScriptPos + s))
        vm.wram.setWord(WRAM.objScriptPos + s, vm.functionOffset(s, f))
        vm.wram[WRAM.objUnk1C00 + s] = UInt8(f)
        vm.wram[WRAM.objUnk1A80 + s] = 0; vm.wram[WRAM.objMoveFrames + s] = 0; vm.wram[WRAM.objUnk1001 + s] = 0
    }

    /// `$B0`'s field half: the leader takes the frame's step (Party_Unk9E29's
    /// velocity; its move log and animation rows are not kept), followers
    /// hold, and a touched object starts function 2.
    func partyRequest(_ r: CTEventVM.PartyRequest) {
        switch r {
        case .step(let kind, let slot):
            if kind == 0 {
                leaderAnim(slot)
                vm.wram[WRAM.objVelX + slot] = vm.wram[WRAM.mapUnk1D32]; vm.wram[WRAM.objVelY + slot] = vm.wram[WRAM.mapUnk1D33]
            } else {
                vm.wram[WRAM.objVelX + slot] = 0; vm.wram[WRAM.objVelY + slot] = 0
            }
        case .touch(let target):
            startFunction(target, function: 2)
        }
    }

    /// Party_LeaderAnim's step code (Party_AnimTable): the pad's X step
    /// >> 3 with its Y step, negative steps as |v| + $20. Straight steps set
    /// the facing, a diagonal keeps a facing it names (else the horizontal
    /// one); walking shows row 1, running row 6 (row $17 while blocked); no
    /// step shows the stand row (Party_AnimIdle's idle rows are not kept).
    func leaderAnim(_ slot: Int) {
        func code(_ v: UInt8) -> Int { v & 0x80 != 0 ? (Int(v ^ 0xFF) + 0x21) & 0xFF : Int(v) }
        let index = (code(vm.wram[WRAM.mapUnk1D2D]) | code(vm.wram[WRAM.mapUnk1D2C]) >> 3) & 0x7E
        let entries: [Int: (facing: [Int], run: Bool)] = [
            1: ([3], false), 2: ([3], true), 3: ([2], false), 4: ([2], true),
            8: ([1], false), 9: ([3, 1], false), 10: ([3, 1], true), 11: ([2, 1], false), 12: ([2, 1], true),
            16: ([1], true), 17: ([3, 1], true), 18: ([3, 1], true), 19: ([2, 1], true), 20: ([2, 1], true),
            24: ([0], false), 25: ([3, 0], false), 26: ([3, 0], true), 27: ([2, 0], false), 28: ([2, 0], true),
            32: ([0], true), 33: ([3, 0], true), 34: ([3, 0], true), 35: ([2, 0], true), 36: ([2, 0], true)]
        func row(_ r: UInt8) {
            guard vm.wram[WRAM.objAnimRow + slot] != r else { return }
            vm.wram[WRAM.objAnimRow + slot] = r; vm.wram[WRAM.objAnimColumn + slot] = 0; vm.wram[WRAM.objAnimTimer + slot] = 0
        }
        guard let e = entries[index / 2] else { row(0); return }
        if !e.facing.contains(Int(vm.wram[WRAM.objFacing + slot])) { vm.wram[WRAM.objFacing + slot] = UInt8(e.facing[0]) }
        if !e.run { row(1); return }
        let still = vm.wram[WRAM.mapUnk1D32] == 0 && vm.wram[WRAM.mapUnk1D33] == 0 && vm.wram[WRAM.mapUnk1D34] == 0
        row(still ? 0x17 : 6)
    }

    // MARK: Dialogue

    /// Field_Unk29 = 1 opens a box: the message Field_Unk2A of the table at
    /// Field_Unk2B-2D, laid out to its close; each frame shows the next layout
    /// frame except at a key wait without a new A press.
    func dialogueFrame() {
        if var d = dialogue {
            let state = d.layout.frames[min(d.frame, d.layout.frames.count - 1)]
            if !(state.keyWait && !pressed.contains(.a)) { d.frame += 1 }
            if d.frame >= d.layout.frames.count || vm.wram[WRAM.fieldUnk29] == 0x0D {
                dialogue = nil
                vm.wram[WRAM.fieldUnk29] = 0
                if !messages.isEmpty { messages[messages.count - 1].closedAt = frameCount }
            } else {
                dialogue = d
            }
            return
        }
        guard vm.wram[WRAM.fieldUnk29] == 1 else { return }
        let table = vm.wram.word(WRAM.fieldUnk2B) | Int(vm.wram[WRAM.fieldUnk2D]) << 16
        let index = Int(vm.wram[WRAM.fieldUnk2A])
        let text = CTDialogueLayout.messageAddress(rom: rom, table: table, index: index)
        var m = Message(frame: frameCount, slot: Int(vm.wram[WRAM.fieldUnk2E]), table: table, index: index, text: text, error: nil)
        do {
            var mem = CTDialogueMemory(rom: rom)
            for a in 0..<0x2000 { mem.ram[0x7E0000 + a] = vm.wram[0x7E0000 + a] }
            for a in 0..<0x0300 { mem.ram[0x7F0000 + a] = vm.wram[0x7F0000 + a] }
            for a in 0..<0x40 { mem.ram[WRAM.charNames + a] = vm.wram[WRAM.charNames + a] }
            let place = vm.wram[WRAM.fieldUnk30] == 1 ? 1 : 2
            let names: [[UInt8]] = (0..<8).map { i in (0..<6).map { vm.wram[WRAM.charNames + 6 * i + $0] } }
            let party = (0..<3).map { Int(vm.wram[WRAM.partyMembers + $0]) }
            let args = (0..<12).map { vm.wram[0x7E0200 + $0] }
            let settings = CTDialogueSettings(names: names, party: party, item: vm.wram.word(0x7F0200), args: args,
                                              place: place, press: 1)
            let layout = try CTDialogueLayout(mem: mem, text: text, settings: settings)
            dialogue = (layout, 0)
            vm.wram[WRAM.fieldUnk66] = 0
        } catch {
            m.error = "\(error)"
            m.closedAt = frameCount
            vm.wram[WRAM.fieldUnk29] = 0
        }
        messages.append(m)
    }

    // MARK: Objects

    /// Vblank_UnkA810: each object's motion, view and animation.
    func objectMotion() {
        let end = 2 * Int(vm.wram[WRAM.evtObjCount])
        var x = 0
        while x < end {
            defer { x += 2 }
            vm.wram.setWord(WRAM.objCur, x)
            let kind = vm.wram[WRAM.objUnk1100 + x]
            if kind < 3 {
                moveStepFree(x)
            } else if kind == 8 {
                continue
            } else if kind == 7 {
                flagInView(x); continue
            } else {
                moveStep(x)
            }
            if updateInView(x) { animTick(x) }
            screenPosition(x)
        }
    }

    /// Obj_MoveStep (tile movers): in a tile the 8-bit add stops at the edge
    /// (MoveFrames 0, nothing stored); crossing (ObjX_Unk7F0B00) carries into
    /// the tile byte.
    func moveStep(_ x: Int) {
        if vm.wram[WRAM.objArcMode + x] != 0 { moveStepArc(x); return }
        let frames = vm.wram[WRAM.objMoveFrames + x]
        guard frames != 0 else { return }
        vm.wram[WRAM.objMoveFrames + x] = frames - 1
        let cross = vm.wram[WRAM.objXUnk7F0B00 + x]
        if cross != 0 {
            if cross & 0x80 == 0 { vm.wram[WRAM.objXUnk7F0B00 + x] = 0 }
            for (pos, tile, vel) in [(WRAM.objPosX, WRAM.objTileX, WRAM.objVelX), (WRAM.objPosY, WRAM.objTileY, WRAM.objVelY)] {
                let v = Int(vm.wram[vel + x]), p = Int(vm.wram[pos + x])
                if v & 0x80 != 0 {
                    let r = p - ((v ^ 0xFF) + 1)
                    vm.wram[pos + x] = UInt8(r & 0xFF)
                    if r < 0 { vm.wram[tile + x] &-= 1 }
                } else {
                    let r = p + v
                    vm.wram[pos + x] = UInt8(r & 0xFF)
                    if r > 0xFF { vm.wram[tile + x] &+= 1 }
                }
            }
        } else {
            for (pos, vel) in [(WRAM.objPosX, WRAM.objVelX), (WRAM.objPosY, WRAM.objVelY)] {
                let v = Int(vm.wram[vel + x]), p = Int(vm.wram[pos + x])
                let r = v & 0x80 != 0 ? p - ((v ^ 0xFF) + 1) : p + v
                if (0...0xFF).contains(r) { vm.wram[pos + x] = UInt8(r) } else { vm.wram[WRAM.objMoveFrames + x] = 0 }
            }
        }
    }

    /// Obj_MoveStep_Arc: 16-bit X step, gravity into VelY (carry into its high byte), 16-bit Y step.
    func moveStepArc(_ x: Int) {
        let frames = vm.wram[WRAM.objMoveFrames + x]
        guard frames != 0 else { return }
        vm.wram[WRAM.objMoveFrames + x] = frames - 1
        vm.wram.setWord(WRAM.objPosX + x, (vm.wram.word(WRAM.objVelX + x) + vm.wram.word(WRAM.objPosX + x)) & 0xFFFF)
        let vy = Int(vm.wram[WRAM.objVelY + x]) + Int(vm.wram[WRAM.objArcGravity + x])
        if vy > 0xFF { vm.wram[WRAM.objVelYHi + x] &+= 1 }
        vm.wram[WRAM.objVelY + x] = UInt8(vy & 0xFF)
        vm.wram.setWord(WRAM.objPosY + x, (vm.wram.word(WRAM.objVelY + x) + vm.wram.word(WRAM.objPosY + x)) & 0xFFFF)
    }

    /// Obj_MoveStepFree (party kinds 0-2): sign-extended 16-bit adds.
    func moveStepFree(_ x: Int) {
        if vm.wram[WRAM.objArcMode + x] != 0 { moveStepArc(x); return }
        let frames = vm.wram[WRAM.objMoveFrames + x]
        guard frames != 0 else { return }
        vm.wram[WRAM.objMoveFrames + x] = frames - 1
        for (pos, vel) in [(WRAM.objPosX, WRAM.objVelX), (WRAM.objPosY, WRAM.objVelY)] {
            let v = Self.signed(vm.wram[vel + x])
            vm.wram.setWord(pos + x, (vm.wram.word(pos + x) + v) & 0xFFFF)
        }
    }

    /// The view window Obj_UpdateInView builds, in 8-pixel columns and rows.
    func viewWindow(margins: Bool) -> (left: Int, right: Int, top: Int, bottom: Int) {
        let ox = Int(vm.wram[WRAM.mapTileOriginX]), oy = Int(vm.wram[WRAM.mapTileOriginY])
        let rx = Int(vm.wram[WRAM.mapUnk1D0C]), by = Int(vm.wram[WRAM.mapUnk1D10])
        return (max(0, ox - 4), min(0xFF, rx + 4), max(0, oy - 2), min(0xFF, by + 5))
    }

    /// Obj_UpdateInView: inside the window an object is active (Obj_Unk0F00
    /// bit 7, its animation reset and a palette slot claimed on entry);
    /// leaving it, the slot goes back and a message's speaker
    /// (ObjX_LeaveView) closes the box (Field_Unk29 = $0D).
    func updateInView(_ x: Int) -> Bool {
        let kind = vm.wram[WRAM.objUnk1100 + x], u = vm.wram[WRAM.objUnk1A81 + x]
        let v = viewWindow(margins: true)
        let cx = Int(vm.wram[WRAM.objTileX + x]) << 1 & 0xFF, cy = Int(vm.wram[WRAM.objTileY + x]) << 1 & 0xFF
        let inside = kind & 0x80 == 0 && u != 0 && u & 0x80 == 0 && cx >= v.left && cx < v.right && cy >= v.top && cy < v.bottom
        if inside {
            if vm.wram[WRAM.objUnk0F00 + x] & 0x80 == 0 {
                vm.wram[WRAM.objUnk0F00 + x] = 0x80
                vm.wram[WRAM.objAnimColumn + x] = 0; vm.wram[WRAM.objAnimTimer + x] = 0
                vm.wram[WRAM.objState + x] = 0; vm.wram[WRAM.objLastFrame + x] = 0xFF
                vm.claimPaletteSlot()                                  // Obj_Unk7170
            }
            return true
        }
        if vm.wram[WRAM.objUnk0F00 + x] & 0x80 != 0 {
            vm.wram[WRAM.objUnk0F00 + x] = 0
            vm.releasePaletteSlot()                                    // Obj_Unk734C
            if vm.wram[WRAM.objXLeaveView + x] != 0, vm.wram[WRAM.fieldUnk30] == 0 { vm.wram[WRAM.fieldUnk29] = 0x0D }
        }
        if vm.wram[WRAM.objXAnimLoops + x] != 0 { vm.wram[WRAM.objXAnimLoops + x] = 2 }
        return false
    }

    /// Obj_FlagInView (kind 7): active while inside the window, no margins above.
    func flagInView(_ x: Int) {
        let v = viewWindow(margins: false)
        let cx = Int(vm.wram[WRAM.objTileX + x]) << 1, cy = Int(vm.wram[WRAM.objTileY + x]) << 1
        let top = Int(vm.wram[WRAM.mapTileOriginY])
        let inside = cx >= v.left && cx < v.right && cy >= top && cy < v.bottom
        vm.wram[WRAM.objUnk0F00 + x] = inside ? 0x80 : 0
    }

    /// Obj_AnimTickAndQueue's animation half: when the timer runs out the
    /// column steps on; a zero duration ends the row (mode 2 counts its loops
    /// and holds the last frame).
    func animTick(_ x: Int) {
        let t = vm.wram[WRAM.objAnimTimer + x]
        if t != 0 {
            vm.wram[WRAM.objAnimTimer + x] = t - 1
            if t - 1 != 0 { return }
        }
        if vm.wram[WRAM.objUnk1100 + x] & 0x80 != 0 { return }
        vm.wram[WRAM.objAnimColumn + x] &+= 1
        let mode = vm.wram[WRAM.objAnimMode + x]
        let row = Int(mode <= 1 ? vm.wram[WRAM.objAnimRow + x] : vm.wram[WRAM.objAnimRowAlt + x])
        let rowAddr = (row * 4 + vm.wram.word(WRAM.objAnimTimeTbl + x)) & 0xFFFF
        let column = Int(vm.wram[WRAM.objAnimColumn + x])
        let d = vm.read(WRAM.animRom | ((rowAddr + column) & 0xFFFF))
        if d != 0 { vm.wram[WRAM.objAnimTimer + x] = d; return }
        vm.wram[WRAM.objAnimTimer + x] = vm.read(WRAM.animRom | rowAddr)
        if mode == 2 {
            let loops = vm.wram[WRAM.objXAnimLoops + x]
            if loops == 1 { vm.wram[WRAM.objAnimColumn + x] &-= 1; return }
            if loops == 2 { vm.wram[WRAM.objXAnimLoops + x] = 1; vm.wram[WRAM.objAnimColumn + x] &-= 1; return }
            vm.wram[WRAM.objXAnimLoops + x] = romAnimLoops ? loops &- 2 : loops &- 1
        }
        vm.wram[WRAM.objAnimColumn + x] = 0
    }

    /// Obj_CalcScreenPos without the fine scroll: the sprite's screen origin.
    func screenPosition(_ x: Int) {
        let sx = (vm.wram.word(WRAM.objPosX + x) >> 4) - camera.x
        let sy = (vm.wram.word(WRAM.objPosY + x) >> 4) - camera.y
        vm.wram.setWord(WRAM.objScreenX + x, sx & 0x1FF); vm.wram.setWord(WRAM.objScreenY + x, sy & 0x1FF)
    }

    // MARK: Inspection

    public struct ObjectState: Codable, Equatable, Sendable {
        public var object: Int, kind: Int, level: Int, scriptPos: Int, tileX: Int, tileY: Int
        public var posX: Int, posY: Int, facing: Int, active: Bool, moveFrames: Int, waitTimer: Int
        public var callStack: [Frame], stopped: String?
        public struct Frame: Codable, Equatable, Sendable { public var level: Int, resume: Int }
    }

    public func objectState(_ o: Int) -> ObjectState {
        let s = 2 * o, w = vm.wram
        let level = Int(w[WRAM.objUnk1C00 + s])
        var stack: [ObjectState.Frame] = []
        if level < 7 {
            for l in (level + 1)...7 {
                let saved = w.word(WRAM.objXSave + ((l * WRAM.evtPrioStride + s) & 0xFFFF))
                if saved != 0 { stack.append(.init(level: l, resume: saved)) }
            }
        }
        return ObjectState(object: o, kind: Int(w[WRAM.objUnk1100 + s]), level: level,
                           scriptPos: w.word(WRAM.objScriptPos + s), tileX: Int(w[WRAM.objTileX + s]),
                           tileY: Int(w[WRAM.objTileY + s]), posX: w.word(WRAM.objPosX + s), posY: w.word(WRAM.objPosY + s),
                           facing: Int(w[WRAM.objFacing + s]), active: w[WRAM.objUnk0F00 + s] & 0x80 != 0,
                           moveFrames: Int(w[WRAM.objMoveFrames + s]), waitTimer: Int(w[WRAM.objUnk1001 + s]),
                           callStack: stack, stopped: vm.stopped[s])
    }

    public struct Summary: Codable, Equatable, Sendable {
        public var location: Int, frames: Int, objects: [ObjectState], messages: [Message], warps: [Warp]
        public var audio: Int, leader: Int?, level: Int
        /// The track the last Audio_CmdPlayMusic asked for (nil: none yet).
        public var music: Int?
        /// Menu_PartyOrder (9 places, nil empty), the gold, and the opcodes' party / item / gold changes.
        public var partyOrder: [Int?], gold: Int, changes: [String]
        public var limitations: [String]
    }

    func drainMapCopies() {
        for copy in vm.mapCopies {
            for layer in copy.layers { mapEdits[layer, default: []].formUnion(copy.cells) }
            mapRevision += 1
        }
        vm.mapCopies.removeAll()
    }

    /// `m` (the location's map) with the cells region copies changed read back
    /// from the WRAM planes: layer 1 Map_TileProps | Map_TileHiBits bit 0 << 8,
    /// layer 2 Map_Layer2Tiles | bit 1 << 8, layer 3 Map_Layer3Tiles.
    public func liveMap(_ m: GameMap) -> GameMap {
        guard !mapEdits.isEmpty else { return m }
        var out = m
        for (i, layer) in m.layers.enumerated() {
            guard let cells = mapEdits[layer.bg], (1...3).contains(layer.bg) else { continue }
            let width = layer.width ?? m.width, height = layer.height ?? m.height
            let plane = [WRAM.mapLayer1Tiles, WRAM.mapLayer2Tiles, WRAM.mapLayer3Tiles][layer.bg - 1]
            for cell in cells {
                let r = cell >> 8, c = cell & 0xFF
                guard c < min(64, width), r < min(64, height), r * width + c < layer.metatiles.count else { continue }
                let at = r * WRAM.mapRowStride + c
                var tile = Int(vm.wram[plane + at])
                if layer.bg < 3 { tile |= Int(vm.wram[WRAM.mapTileHiBits + at] >> (layer.bg - 1) & 1) << 8 }
                out.layers[i].metatiles[r * width + c] = tile
            }
        }
        return out
    }

    /// Menu_PartyOrder: the active party (0-2) and the reserve (3-8); nil where a place is empty.
    public var partyOrder: [Int?] {
        (0..<9).map { k -> Int? in
            let c = vm.wram[WRAM.menuPartyOrder + k]
            return c & 0x80 != 0 ? nil : Int(c)
        }
    }

    /// The track the last Audio_CmdPlayMusic asked for (LocLoad_AudioSetup
    /// or `$EA`), nil before one.
    public var music: Int? {
        audio.last { $0.command.id == 0x10 }.map { Int($0.command.arg0) }
    }

    /// The 24-bit gold (Battle_Gold).
    public var gold: Int { Int(vm.wram[WRAM.goldHi]) << 16 | vm.wram.word(WRAM.gold) }

    /// The held items (Battle_InvIds / Battle_InvCounts), id and count, in entry order.
    public var inventory: [(item: Int, count: Int)] {
        (0..<0x100).compactMap { k -> (item: Int, count: Int)? in
            let id = vm.wram[WRAM.invIds + k]
            return id == 0 ? nil : (Int(id), Int(vm.wram[WRAM.invCounts + k]))
        }
    }

    public func summary() -> Summary {
        let leader = Int(vm.wram[WRAM.partyObjSlot])
        return Summary(location: location, frames: frameCount, objects: (0..<vm.pack.objectCount).map(objectState),
                       messages: messages, warps: warps, audio: audio.count, leader: leader & 0x80 == 0 ? leader / 2 : nil,
                       level: Int(vm.wram[WRAM.fieldUnk55]), music: music, partyOrder: partyOrder, gold: gold,
                       changes: changes.map { c in
                           String(format: "frame %d obj %d $%04X %02X: %@", c.frame, c.change.slot / 2, c.change.offset,
                                  Int(c.change.opcode), c.change.what)
                       },
                       limitations: Self.limitations)
    }
}
