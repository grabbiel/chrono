// CTEventVM.swift — Chrono Trigger's location event VM as executable models of
// its opcode handlers. Each modelled opcode does to WRAM what the ROM handler
// at Evt_OpcodeTable ($C0:5D6E) does (ChronoRET bankC0.asm: Evt_Op*), returns
// the handler's X (where the script goes on) and carry (C=1 go on in this run,
// C=0 stop the object until its next run), and is checked against the handler
// itself in ChronoRET's 65816 interpreter (re_workspace/tools/ct_event_vm.py).
// The scheduler around it follows Evt_InitObjects, Vblank_Unk59D9,
// Vblank_ReadScanlineCounters and Evt_RunObjScriptSteps. An opcode with no
// model stops its object with a reason; nothing is skipped silently.
import Foundation

public final class CTEventVM {
    /// What one handler did: go on at `x` (carry as the handler sets it), or
    /// no model (the object stops), or a handler that never returns (the game
    /// halts, or leaves the field: Sys_HaltWithColor, a warp through InitHW).
    public enum Outcome: Equatable, Sendable {
        case go(x: Int, carry: Bool)
        case unmodelled(String)
        case halted(String)
    }

    public static let objectLimit = 16

    public var wram: WRAMModel
    public let rom: [UInt8]
    public private(set) var pack: CTEventPack
    /// Objects stopped for good, by slot (object x 2): the reason shown.
    public private(set) var stopped: [Int: String] = [:]
    /// Sound-driver commands sent (Audio_DriverCommand), oldest first; the field drains them.
    public var audio: [AudioCommand] = []
    /// The field's party routines, called by `$B0`/`$AF` (nil: the handler alone).
    public var party: ((PartyRequest) -> Void)?

    /// Audio_CmdId and Audio_CmdArg0-2 as Audio_DriverCommand found them.
    public struct AudioCommand: Equatable, Sendable {
        public var id: UInt8, arg0: UInt8, arg1: UInt8, arg2: UInt8
    }
    /// Called when a handler leaves the field (`$E1`/`$DF` warp now, `$FF`
    /// below `$90`): the field runtime takes over.
    public var trace: ((TraceEvent) -> Void)?

    public struct TraceEvent: Sendable, Equatable {
        public var slot: Int, offset: Int, opcode: UInt8, outcome: Outcome
        public var storyWrites: [(address: Int, old: UInt8, new: UInt8)]
        public static func == (a: TraceEvent, b: TraceEvent) -> Bool {
            a.slot == b.slot && a.offset == b.offset && a.opcode == b.opcode && a.outcome == b.outcome
                && a.storyWrites.map { [$0.address, Int($0.old), Int($0.new)] } == b.storyWrites.map { [$0.address, Int($0.old), Int($0.new)] }
        }
    }

    /// `rom`: the 4 MiB image the handlers' tables are read from (BitSet,
    /// RandomTable); empty for synthetic packs, which then read zeroes there
    /// except BitSet/BitClear, whose eight bytes the ROM check pins.
    public init(pack: CTEventPack, rom: [UInt8] = [], wram: WRAMModel = WRAMModel()) {
        self.pack = pack
        self.rom = rom
        self.wram = wram
        load(pack: pack)
    }

    /// The pack at $7F:2000, as Evt_InitObjects finds it (unpacked by LZSS).
    public func load(pack: CTEventPack) {
        self.pack = pack
        stopped = [:]
        let rec = wram.recording
        wram.recording = false
        for (i, b) in pack.bytes.enumerated() where WRAM.evtObjCount + i <= 0x7FFFFF { wram[WRAM.evtObjCount + i] = b }
        wram.recording = rec
    }

    // MARK: Memory

    var objCur: Int { wram.word(WRAM.objCur) }
    /// A byte of Evt_Data ($7F:2001 + offset; the long address carries into bank $80).
    func data(_ offset: Int) -> Int { Int(read(WRAM.evtData + (offset & 0xFFFF))) }
    func dataWord(_ offset: Int) -> Int { data(offset) | data(offset + 1) << 8 }

    /// A byte at a 24-bit address: WRAM, or the ROM through the HiROM map
    /// (banks $C0–$FF and $40–$7D whole, the upper halves of $00–$3F/$80–$BF).
    public func read(_ long: Int) -> UInt8 {
        let a = long & 0xFFFFFF
        if let w = WRAMModel.canonical(a) { return wram.bytes[w - 0x7E0000] }
        if let pc = Self.romOffset(a) {
            if pc < rom.count { return rom[pc] }
            if (0xFF20..<0xFF30).contains(pc) {                    // BitSet / BitClear ($00:FF20)
                let n = pc - 0xFF20
                return n < 8 ? UInt8(1 << n) : ~UInt8(1 << (n - 8))
            }
        }
        return 0
    }

    public static func romOffset(_ long: Int) -> Int? {
        let bank = long >> 16 & 0xFF, low = long & 0xFFFF
        switch bank {
        case 0xC0...0xFF: return (bank - 0xC0) << 16 | low
        case 0x40...0x7D: return (bank - 0x40) << 16 | low
        case 0x00...0x3F, 0x80...0xBF: return low >= 0x8000 ? (bank & 0x3F) << 16 | low : nil
        default: return nil
        }
    }

    func eventWord(_ a: Int) -> Int { WRAM.eventWord(a & 0xFF) }

    // MARK: Scheduler

    /// Evt_InitObjects: clears the event words and the object tables as the
    /// routine does, points every object at its function 0 and runs each
    /// object's init (to its first `$00`), leaving it on the byte after.
    public func initObjects() {
        let n = pack.objectCount
        for a in WRAM.evtWords..<(WRAM.evtWords + 0x200) { wram[a] = 0 }
        for o in 0..<n {
            let s = 2 * o
            wram.setWord(WRAM.objScriptPos + s, pack.functions[o][0])
            wram.setWord(WRAM.objUnk1C00 + s, 7)                    // Obj_Unk1C00Init, Obj_Unk1C01 = 0
            wram.setWord(WRAM.objUnk1000 + s, 4)                    // Obj_Unk1000Init, Obj_Unk1001 = 0
            wram[WRAM.objUnk1080 + s] = 0x80; wram[WRAM.objUnk1080 + s + 1] = 0x80
            wram.setWord(WRAM.objPosX + s, 0xFF00); wram.setWord(WRAM.objPosY + s, 0xFF00)   // Obj_PosOffMap
            wram.setWord(WRAM.objSpeed + s, 0x10)                   // Obj_Unk1A00Init, Obj_MoveFrames = 0
            wram.setWord(WRAM.objUnk1A80 + s, 0x0100)               // Obj_Unk1A80 = 0, Obj_Unk1A81Init
            wram.setWord(WRAM.objAnimMode + s, 0)
            wram.setWord(WRAM.objUnk1C80 + s, 3)                    // Obj_Unk1C80Init
            wram.setWord(WRAM.objOamFlags + s, 0x80)                // Obj_OamFlagsInit
            wram.setWord(WRAM.objXUnk7F0B00 + s, 0)
            wram.setWord(WRAM.objXUnk7F0B80 + s, 0xFFFF)
        }
        for k in 0..<0x3F { wram.setWord(WRAM.objUnk1100 + 2 * k, 0x80) }   // Obj_Unk1100Skip, then 7 for the objects
        for o in 0..<n { wram.setWord(WRAM.objUnk1100 + 2 * o, 7) }
        for a in WRAM.objVelX..<(WRAM.objVelX + 0x100) { wram[a] = 0 }
        for a in WRAM.objXSave..<(WRAM.objXSave + 0x15C0) { wram[a] = 0 }
        wram[WRAM.objQUnk74] = 0x80; wram[WRAM.objQUnk75] = 0x80
        wram[WRAM.objQHead] = 0x80; wram[WRAM.objQTail] = 0x80
        wram.setWord(WRAM.objQUnk71, 0x8000); wram[WRAM.objQUnk73] = 0     // ObjQ_Unk71Init
        wram.setWord(WRAM.evtObjSlotEnd, 2 * n)
        for o in 0..<n {
            let s = 2 * o
            wram.setWord(WRAM.objState + s, 0)
            wram.setWord(WRAM.objArcMode + s, 0)
            wram.setWord(WRAM.objCur, s)
            var x = wram.word(WRAM.objScriptPos + s)
            var steps = 0
            while data(x) != 0 {
                steps += 1
                guard steps < 4096 else { stop(s, String(format: "init at $%04X does not reach its $00", x)); break }
                switch execute(at: x) {
                case .go(let next, _): x = next
                case .unmodelled(let why), .halted(let why):
                    stop(s, why)
                    steps = 4096
                }
                if stopped[s] != nil { break }
            }
            if stopped[s] == nil { wram.setWord(WRAM.objScriptPos + s, (x + 1) & 0xFFFF) }
        }
    }

    func stop(_ slot: Int, _ why: String) { if stopped[slot] == nil { stopped[slot] = why } }

    /// Vblank_Unk59D9: counts down the objects' script timers and queues
    /// those that ran out (kind 0 at the head, others at the tail).
    public func queueScripts() {
        let end = 2 * pack.objectCount
        wram.setWord(WRAM.evtObjSlotEnd, end)
        var x = 0
        while x < end {
            defer { x += 2 }
            if wram[WRAM.objUnk1000 + x] & 0x80 != 0 { continue }
            if wram[WRAM.objUnk1001 + x] != 0 {
                wram[WRAM.objUnk1001 + x] &-= 1
                if wram[WRAM.objUnk1001 + x] != 0 { continue }
            }
            let kind = wram[WRAM.objUnk1100 + x]
            let head = Int(wram[WRAM.objQUnk74]), tail = Int(wram[WRAM.objQUnk75])
            if kind == 0 {
                if x == head { continue }
                if head & 0x80 != 0 { wram[WRAM.objQUnk74] = UInt8(x); wram[WRAM.objQUnk75] = UInt8(x) }
                else { wram[WRAM.objUnk1080 + x] = UInt8(head); wram[WRAM.objQUnk74] = UInt8(x) }
            } else {
                if kind & 0x80 != 0 || x == tail || wram[WRAM.objUnk1080 + x] & 0x80 == 0 { continue }
                if tail & 0x80 != 0 { wram[WRAM.objQUnk74] = UInt8(x); wram[WRAM.objQUnk75] = UInt8(x) }
                else { wram[WRAM.objUnk1080 + tail] = UInt8(x); wram[WRAM.objQUnk75] = UInt8(x) }
            }
            wram[WRAM.objUnk1001 + x] = wram[WRAM.objUnk1000 + x]
        }
    }

    /// Vblank_ReadScanlineCounters without the frame-time limit: every queued
    /// object runs (Evt_RunObjScriptSteps), head first, until the list is empty.
    public func runQueued() {
        var guardCount = 0
        while wram[WRAM.objQUnk74] & 0x80 == 0, guardCount < 64 {
            guardCount += 1
            let x = Int(wram[WRAM.objQUnk74])
            if x == Int(wram[WRAM.objQUnk75]) {
                wram[WRAM.objUnk1080 + x] = 0x80; wram[WRAM.objQUnk74] = 0x80; wram[WRAM.objQUnk75] = 0x80
            } else {
                wram[WRAM.objQUnk74] = wram[WRAM.objUnk1080 + x]
                wram[WRAM.objUnk1080 + x] = 0x80
            }
            runSteps(slot: x)
        }
    }

    /// Evt_RunObjScriptSteps: up to Field_Unk68 opcodes of one object, going on
    /// while each handler returns C=1; the last X becomes Obj_ScriptPos.
    public func runSteps(slot: Int) {
        if stopped[slot] != nil { return }
        wram[WRAM.evtStepsLeft] = wram[WRAM.fieldUnk68]
        wram[WRAM.objCur] = UInt8(slot)
        var x = wram.word(WRAM.objScriptPos + slot)
        while true {
            let outcome = execute(at: x)
            switch outcome {
            case .go(let next, let carry):
                x = next
                if !carry { break }
                wram[WRAM.evtStepsLeft] &-= 1
                if wram[WRAM.evtStepsLeft] != 0 { continue }
            case .unmodelled(let why), .halted(let why):
                stop(slot, why)
            }
            break
        }
        wram.setWord(WRAM.objScriptPos + slot, x)
    }

    /// One frame of the scheduler: queue, then run the queued scripts.
    public func frame() {
        queueScripts()
        runQueued()
    }

    // MARK: Dispatch

    /// The handler of the opcode at Evt_Data offset `y`, with Obj_Cur as WRAM
    /// holds it: its writes go to `wram`, its X and C come back.
    public func execute(at y: Int) -> Outcome {
        let op = UInt8(data(y))
        let before = wram.recording ? nil : storySnapshot()
        let outcome = dispatch(op, y & 0xFFFF)
        if let trace {
            var writes: [(Int, UInt8, UInt8)] = []
            if let before {
                for (i, old) in before.enumerated() where wram.bytes[0x10000 + i] != old {
                    writes.append((WRAM.evtMem7F + i, old, wram.bytes[0x10000 + i]))
                }
            }
            trace(TraceEvent(slot: objCur, offset: y, opcode: op, outcome: outcome, storyWrites: writes))
        }
        return outcome
    }

    private func storySnapshot() -> ArraySlice<UInt8>? {
        trace == nil ? nil : wram.bytes[0x10000..<0x10200]
    }

    /// The opcodes with a model, by family (the evidence tool reads this list).
    public static let families: [String: [UInt8]] = [
        "flow": [0x00, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x10, 0x11, 0x87, 0xAD, 0xB1, 0xB2, 0xB9, 0xBA, 0xBC, 0xBD],
        "conditions": [0x12, 0x13, 0x14, 0x15, 0x16, 0x18, 0x1A, 0x27, 0x28, 0x2D, 0x30, 0x31, 0x34, 0x35, 0x36, 0x37,
                       0x38, 0x39, 0x3B, 0x3C, 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44],
        "memory": [0x19, 0x1C, 0x20, 0x21, 0x22, 0x23, 0x24, 0x47, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F,
                   0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x58, 0x59, 0x5A, 0x5B, 0x5D, 0x5E, 0x5F, 0x60, 0x61,
                   0x63, 0x64, 0x65, 0x66, 0x67, 0x69, 0x6B, 0x6F, 0x71, 0x72, 0x73, 0x75, 0x76, 0x77, 0x7F],
        "calls": [0x02, 0x03, 0x04, 0x05, 0x06, 0x07],
        "objects": [0x0F, 0x17, 0x1B, 0x1D, 0x1E, 0x1F, 0x25, 0x26, 0xA6, 0xA7, 0x7C, 0x7D, 0x7E, 0x84, 0x89, 0x8A,
                    0x8B, 0x8C, 0x8D, 0x8E, 0x90, 0x91],
        "animation": [0xAA, 0xAB, 0xAC, 0xAE, 0xB3, 0xB4, 0xB7],
        "messages": [0xB8, 0xBB, 0xC0, 0xC1, 0xC2, 0xC3, 0xC4],
        "warps": [0xDC, 0xDD, 0xDE, 0xE0, 0xE2],
        "field": [0xD8, 0xE3, 0xE6, 0xE7, 0xF0, 0xF1, 0xF2, 0xF3, 0xF4],
        "characters": [0x57, 0x5C, 0x62, 0x68, 0x6A, 0x6C, 0x6D, 0x80, 0x81, 0x82, 0x83],
        "sound": [0xE8, 0xEA, 0xEB, 0xEC],
        "movement": [0x8F, 0x92, 0x94, 0x95, 0x96, 0x9C, 0xA0, 0xA8, 0xA9, 0xB5, 0xB6],
        "party": [0xAF, 0xB0],
    ]
    public static let modelled: Set<UInt8> = Set(families.values.joined())

    func dispatch(_ op: UInt8, _ y: Int) -> Outcome {
        switch op {
        case 0x00: return op00(y)
        case 0x02: return callObj(y: y, slot: data(y + 1), arg: y + 2, kind: .start, next: y + 3)
        case 0x03: return callObj(y: y, slot: data(y + 1), arg: y + 2, kind: .retry, next: y + 3)
        case 0x04: return op04(y)
        case 0x05, 0x06:
            let p = data(y + 1), slot = Int(wram[WRAM.partyObjSlot + p])
            if slot & 0x80 != 0 { return .go(x: y + 3, carry: true) }
            return callObj(y: y, slot: slot, arg: y + 2, kind: op == 0x05 ? .start : .retry, next: y + 3)
        case 0x07: return op07(y)
        case 0x08: wram[WRAM.objUnk1C01 + objCur] = 1; return .go(x: y + 1, carry: true)
        case 0x09: wram[WRAM.objUnk1C01 + objCur] = 0; return .go(x: y + 1, carry: true)
        case 0x0A:
            let s = data(y + 1)
            wram[WRAM.objUnk1100 + s] = 0x80; wram[WRAM.objUnk1A81 + s] = 0
            return .go(x: y + 2, carry: true)
        case 0x0B:
            let s = data(y + 1)
            wram[WRAM.objUnk1000 + s] |= 0x80
            return .go(x: y + 2, carry: s != objCur)
        case 0x0C:
            let s = data(y + 1)
            wram[WRAM.objUnk1000 + s] &= 0x7F
            return .go(x: y + 2, carry: true)
        case 0x0D: wram[WRAM.objUnk1C80 + objCur] = UInt8(data(y + 1)); return .go(x: y + 2, carry: true)
        case 0x0E: wram[WRAM.objUnk1C81 + objCur] = UInt8(data(y + 1)); return .go(x: y + 2, carry: true)
        case 0x0F, 0x17, 0x1B, 0x1D:
            return setFacing(objCur, [0x0F: 0, 0x17: 1, 0x1B: 2, 0x1D: 3][op]!, next: y + 1)
        case 0x10: return .go(x: (y + 1 + data(y + 1)) & 0xFFFF, carry: true)
        case 0x11: return .go(x: (y + 1 - data(y + 1)) & 0xFFFF, carry: true)
        case 0x12:
            let left = Int(wram[eventWord(data(y + 1))])
            return compare8(left, data(y + 2), cmp: data(y + 3), ofsPos: y + 4)
        case 0x13:
            let left = wram.word(eventWord(data(y + 1)))
            return compare16(left, dataWord(y + 2), cmp: data(y + 4), ofsPos: y + 5)
        case 0x14:
            let left = Int(wram[eventWord(data(y + 1))]), right = Int(wram[eventWord(data(y + 2))])
            return compare8(left, right, cmp: data(y + 3), ofsPos: y + 4)
        case 0x15:
            let left = wram.word(eventWord(data(y + 1))), right = wram.word(eventWord(data(y + 2)))
            return compare16(left, right, cmp: data(y + 3), ofsPos: y + 4)
        case 0x16:
            let m = data(y + 1), value = data(y + 2), cmp = data(y + 3)
            let left = Int(wram[WRAM.evtMem7F + (cmp & 0x80 != 0 ? 0x100 : 0) + m])
            return compare8(left, value, cmp: cmp & 0x7F, ofsPos: y + 4)
        case 0x18:
            return Int(wram[WRAM.evtMem7F]) < data(y + 1) ? .go(x: y + 3, carry: true) : jump(from: y + 2)
        case 0x19:
            wram.setWord(WRAM.objXUnk7F0A80 + objCur, wram.word(eventWord(data(y + 1))))
            return .go(x: y + 2, carry: true)
        case 0x1A:
            return Int(wram[WRAM.objXUnk7F0A80 + objCur]) == data(y + 1) ? .go(x: y + 3, carry: true) : jump(from: y + 2)
        case 0x1C:
            wram.setWord(WRAM.objXUnk7F0A80 + objCur, wram.word(WRAM.evtMem7F + dataWord(y + 1)))
            return .go(x: y + 3, carry: true)
        case 0x1E, 0x1F, 0x25, 0x26:
            return setFacing(data(y + 1), [0x1E: 0, 0x1F: 1, 0x25: 2, 0x26: 3][op]!, next: y + 2)
        case 0x20:
            wram[eventWord(data(y + 1))] = wram[WRAM.partyMembers]
            return .go(x: y + 2, carry: true)
        case 0x21, 0x22:
            var s = data(y + 1)
            if op == 0x22 { s = Int(wram[WRAM.partyObjSlot + s]) }
            let col = wram[WRAM.objTileX + s], row = wram[WRAM.objTileY + s]
            wram[eventWord(data(y + 2))] = col
            wram[eventWord(data(y + 3))] = row
            return .go(x: y + 4, carry: true)
        case 0x23, 0x24:
            var s = data(y + 1)
            if op == 0x24 { s = Int(wram[WRAM.partyObjSlot + s]) }
            wram[eventWord(data(y + 2))] = wram[WRAM.objFacing + s]
            return .go(x: y + 3, carry: true)
        case 0x27:
            return wram[WRAM.objUnk0F00 + data(y + 1)] != 0 ? .go(x: y + 3, carry: true) : jump(from: y + 2)
        case 0x28: return op28(y)
        case 0x2D:
            let held = wram[WRAM.padUnk00F8] != 0 || wram[WRAM.padUnk00F9] != 0
            return held ? .go(x: y + 2, carry: true) : jump(from: y + 1)
        case 0x30, 0x31:
            let bit: UInt8 = op == 0x30 ? 0x02 : 0x80
            return wram[WRAM.padUnk00F8] & bit != 0 ? .go(x: y + 2, carry: true) : jump(from: y + 1)
        case 0x34, 0x35, 0x36, 0x37, 0x38, 0x39:
            let bit: UInt8 = [0x34: 0x80, 0x35: 0x08, 0x36: 0x40, 0x37: 0x04, 0x38: 0x20, 0x39: 0x10][op]!
            return wram[WRAM.menuPadHeld] & bit != 0 ? .go(x: y + 2, carry: true) : jump(from: y + 1)
        case 0x3B, 0x3C:
            let bit: UInt8 = op == 0x3B ? 0x02 : 0x80
            guard wram[WRAM.padUnk00F6Latch] & bit != 0 else { return jump(from: y + 1) }
            wram[WRAM.padUnk00F6Latch] &= ~bit
            return .go(x: y + 2, carry: true)
        case 0x3F, 0x40, 0x41, 0x42, 0x43, 0x44:
            let bit: UInt8 = [0x3F: 0x80, 0x40: 0x08, 0x41: 0x40, 0x42: 0x04, 0x43: 0x20, 0x44: 0x10][op]!
            guard wram[WRAM.padPressedLatch] & bit != 0 else { return jump(from: y + 1) }
            wram[WRAM.padPressedLatch] &= ~bit
            return .go(x: y + 2, carry: true)
        case 0x47: wram[WRAM.objQScanlineLimit] = UInt8(data(y + 1)); return .go(x: y + 2, carry: true)
        case 0x48, 0x49:
            let src = data(y + 1) | data(y + 2) << 8 | data(y + 3) << 16, v = eventWord(data(y + 4))
            wram[v] = read(src)
            if op == 0x49 { wram[v + 1] = read((src & 0xFF0000) | ((src + 1) & 0xFFFF)) }
            return .go(x: y + 5, carry: true)
        case 0x4A, 0x4B, 0x4C, 0x4D:
            let dst = data(y + 1) | data(y + 2) << 8 | data(y + 3) << 16
            let word = op == 0x4B || op == 0x4D
            let value: Int
            switch op {
            case 0x4A: value = data(y + 4)
            case 0x4B: value = dataWord(y + 4)
            case 0x4C: value = Int(wram[eventWord(data(y + 4))])
            default: value = wram.word(eventWord(data(y + 4)))
            }
            writeLong(dst, UInt8(value & 0xFF))
            if word { writeLong((dst & 0xFF0000) | ((dst + 1) & 0xFFFF), UInt8(value >> 8)) }
            return .go(x: y + (op == 0x4B ? 6 : 5), carry: true)
        case 0x4E: return op4E(y)
        case 0x4F: wram[eventWord(data(y + 2))] = UInt8(data(y + 1)); return .go(x: y + 3, carry: true)
        case 0x50: wram.setWord(eventWord(data(y + 3)), dataWord(y + 1)); return .go(x: y + 4, carry: true)
        case 0x51: wram[eventWord(data(y + 2))] = wram[eventWord(data(y + 1))]; return .go(x: y + 3, carry: true)
        case 0x52: wram.setWord(eventWord(data(y + 2)), wram.word(eventWord(data(y + 1)))); return .go(x: y + 3, carry: true)
        case 0x53:
            wram[eventWord(data(y + 3))] = wram[WRAM.evtMem7F + dataWord(y + 1)]
            return .go(x: y + 4, carry: true)
        case 0x54:
            wram.setWord(eventWord(data(y + 3)), wram.word(WRAM.evtMem7F + dataWord(y + 1)))
            return .go(x: y + 4, carry: true)
        case 0x55: wram[eventWord(data(y + 1))] = wram[WRAM.evtMem7F]; return .go(x: y + 2, carry: true)
        case 0x56: wram[WRAM.evtMem7F + dataWord(y + 2)] = UInt8(data(y + 1)); return .go(x: y + 4, carry: true)
        case 0x58:
            wram[WRAM.evtMem7F + dataWord(y + 2)] = wram[eventWord(data(y + 1))]
            return .go(x: y + 4, carry: true)
        case 0x59:
            let m = dataWord(y + 2), v = wram.word(eventWord(data(y + 1)))
            wram[WRAM.evtMem7F + m] = UInt8(v & 0xFF)
            wram[WRAM.evtMem7F + ((m + 1) & 0xFFFF)] = UInt8(v >> 8)
            return .go(x: y + 4, carry: true)
        case 0x5A: wram[WRAM.evtMem7F] = UInt8(data(y + 1)); return .go(x: y + 2, carry: true)
        case 0x5B, 0x5F, 0x67, 0x69, 0x6B:
            let v = UInt8(data(y + 1)), a = eventWord(data(y + 2)), old = wram[a]
            switch op {
            case 0x5B: wram[a] = old &+ v
            case 0x5F: wram[a] = old &- v
            case 0x67: wram[a] = old & v
            case 0x69: wram[a] = old | v
            default: wram[a] = old ^ v
            }
            return .go(x: y + 3, carry: true)
        case 0x5D, 0x61:
            let v = wram[eventWord(data(y + 1))], a = eventWord(data(y + 2))
            wram[a] = op == 0x5D ? wram[a] &+ v : wram[a] &- v
            return .go(x: y + 3, carry: true)
        case 0x5E:
            let v = wram.word(eventWord(data(y + 1))), a = eventWord(data(y + 2))
            wram.setWord(a, (wram.word(a) + v) & 0xFFFF)
            return .go(x: y + 3, carry: true)
        case 0x60:
            let a = eventWord(data(y + 3))
            wram.setWord(a, (wram.word(a) - dataWord(y + 1)) & 0xFFFF)
            return .go(x: y + 4, carry: true)
        case 0x63, 0x64:
            let n = data(y + 1), a = eventWord(data(y + 2))
            let mask = read(0x00FF20 + (op == 0x63 ? 0 : 8) + n)
            wram[a] = op == 0x63 ? wram[a] | mask : wram[a] & mask
            return .go(x: y + 3, carry: true)
        case 0x65, 0x66:
            let arg = data(y + 1), m = data(y + 2)
            let mask = read(0x00FF20 + (op == 0x65 ? 0 : 8) + (arg & 0x0F))
            let a = WRAM.evtMem7F + (arg & 0x80 != 0 ? 0x100 : 0) + m
            wram[a] = op == 0x65 ? wram[a] | mask : wram[a] & mask
            return .go(x: y + 3, carry: true)
        case 0x6F:
            let a = eventWord(data(y + 2))
            var count = UInt8(data(y + 1)), v = wram[a]
            repeat { v >>= 1; count &-= 1 } while count != 0
            wram[a] = v
            return .go(x: y + 3, carry: true)
        case 0x71: let a = eventWord(data(y + 1)); wram[a] &+= 1; return .go(x: y + 2, carry: true)
        case 0x72: let a = eventWord(data(y + 1)); wram.setWord(a, (wram.word(a) + 1) & 0xFFFF); return .go(x: y + 2, carry: true)
        case 0x73: let a = eventWord(data(y + 1)); wram[a] &-= 1; return .go(x: y + 2, carry: true)
        case 0x75: wram[eventWord(data(y + 1))] = 1; return .go(x: y + 2, carry: true)
        case 0x76: wram.setWord(eventWord(data(y + 1)), 1); return .go(x: y + 2, carry: true)
        case 0x77: wram[eventWord(data(y + 1))] = 0; return .go(x: y + 2, carry: true)
        case 0x7F:
            let k = WRAM.dpField + 0xF8                           // Field_Unk0400Copy
            wram[k] &+= 1
            wram[eventWord(data(y + 1))] = read(0xC0FE00 + Int(wram[k]))   // RandomTable
            return .go(x: y + 2, carry: true)
        case 0x7C: wram[WRAM.objUnk1A81 + data(y + 1)] = 1; return .go(x: y + 2, carry: false)
        case 0x7D: wram[WRAM.objUnk1A81 + data(y + 1)] = 0; return .go(x: y + 2, carry: false)
        case 0x7E: wram[WRAM.objUnk1A81 + objCur] = 0x80; return .go(x: y + 1, carry: false)
        case 0x90: wram[WRAM.objUnk1A81 + objCur] = 1; return .go(x: y + 1, carry: false)
        case 0x91: wram[WRAM.objUnk1A81 + objCur] = 0; return .go(x: y + 1, carry: false)
        case 0x84: wram[WRAM.objUnk1B01 + objCur] = UInt8(data(y + 1)); return .go(x: y + 2, carry: true)
        case 0x87:
            let c = objCur, v = (wram[WRAM.objUnk1000 + c] & 0x80) | UInt8((data(y + 1) + 1) & 0xFF)
            wram[WRAM.objUnk1000 + c] = v; wram[WRAM.objUnk1001 + c] = v
            return .go(x: y + 2, carry: true)
        case 0x89: wram[WRAM.objSpeed + objCur] = UInt8(data(y + 1)); return .go(x: y + 2, carry: true)
        case 0x8A: wram[WRAM.objSpeed + objCur] = wram[eventWord(data(y + 1))]; return .go(x: y + 2, carry: true)
        case 0x8B, 0x8C:
            let c = objCur
            let col = op == 0x8B ? UInt8(data(y + 1)) : wram[eventWord(data(y + 1))]
            let row = op == 0x8B ? UInt8(data(y + 2)) : wram[eventWord(data(y + 2))]
            wram[WRAM.objTileX + c] = col
            if op == 0x8B { wram[WRAM.objPosX + c] = 0x80 }        // EvtChar_SubXCentre
            wram[WRAM.objTileY + c] = row
            wram[WRAM.objPosY + c] = 0xFF                          // EvtChar_SubYLower
            if wram[WRAM.objOamFlags + c] & 0x80 != 0 { tilePriorities(c, tile: Int(row) << 8 | Int(col)) }
            return .go(x: y + 3, carry: true)
        case 0x8D:
            let c = objCur
            wram.setWord(WRAM.objPosX + c, dataWord(y + 1))
            wram.setWord(WRAM.objPosY + c, dataWord(y + 3))
            if wram[WRAM.objOamFlags + c] & 0x80 != 0 {
                tilePriorities(c, tile: Int(wram[WRAM.objTileY + c]) << 8 | Int(wram[WRAM.objTileX + c]))
            }
            return .go(x: y + 5, carry: true)
        case 0x8E:
            let c = objCur, flags = UInt8(data(y + 1))
            wram[WRAM.objOamFlags + c] = flags
            if flags & 0x80 != 0 {
                tilePriorities(c, tile: Int(wram[WRAM.objTileY + c]) << 8 | Int(wram[WRAM.objTileX + c]))
            } else {
                wram[WRAM.objPrioHigh + c] = flags & 0x30
                wram[WRAM.objPrioLow + c] = (flags << 4) & 0x30
            }
            wram[WRAM.objLastFrame + c] = 0xFF
            wram[WRAM.objAnimTimer + c] = 0
            return .go(x: y + 2, carry: true)
        case 0xA6: return setFacing(objCur, data(y + 1), next: y + 2)
        case 0xA7: return setFacing(objCur, Int(wram[eventWord(data(y + 1))]), next: y + 2)
        case 0xAA, 0xB3, 0xB4:
            let row = op == 0xAA ? data(y + 1) : op == 0xB3 ? 0 : 1
            let c = objCur
            wram[WRAM.objAnimRow + c] = UInt8(row)
            return setAnimMode(c, 1, next: op == 0xAA ? y + 2 : y + 1)
        case 0xAE:
            let c = objCur
            wram[WRAM.objAnimRow + c] = 0
            return setAnimMode(c, 0, next: y + 1)
        case 0xAB, 0xB7: return playAnim(y, loops: op == 0xB7)
        case 0xAC:
            let c = objCur
            wram[WRAM.objFixedFrame + c] = UInt8(data(y + 1))
            wram[WRAM.objAnimColumn + c] = 0
            wram[WRAM.objAnimTimer + c] = 0
            if wram[WRAM.objAnimMode + c] == 0 { wram[WRAM.objAnimRow + c] = 0xFF }
            wram[WRAM.objAnimMode + c] = 3
            return .go(x: y + 2, carry: false)
        case 0xAD: return waitRuns(UInt8(data(y + 1)), y: y, next: y + 2)
        case 0xB9, 0xBA, 0xBC, 0xBD:
            return waitRuns([0xB9: 4, 0xBA: 8, 0xBC: 0x10, 0xBD: 0x20][op]!, y: y, next: y + 1)
        case 0xB1: return .go(x: y + 1, carry: false)
        case 0xB2: return .go(x: y, carry: false)
        case 0xB8:
            wram[WRAM.fieldUnk2B] = UInt8(data(y + 1)); wram[WRAM.fieldUnk2B + 1] = UInt8(data(y + 2))
            wram[WRAM.fieldUnk2D] = UInt8(data(y + 3))
            return .go(x: y + 4, carry: true)
        case 0xBB, 0xC1, 0xC2: return message(y, unk30: op == 0xBB ? 0 : op == 0xC1 ? 1 : 2, choice: false)
        case 0xC0, 0xC3, 0xC4: return message(y, unk30: op == 0xC0 ? 0 : op == 0xC3 ? 1 : 2, choice: true)
        case 0xD8: return opD8(y)
        case 0xDC, 0xDD, 0xDE:
            if op == 0xDE { wram[WRAM.fieldUnk1E] = 1 }
            let (id, xy, facing) = (op == 0xDC) ? (WRAM.locPrevId, WRAM.locPrevX, WRAM.locPrevFacing)
                                                : (WRAM.locId, WRAM.locEntryX, WRAM.locEntryFacing)
            setLocation(y, id: id, xy: xy, facing: facing)
            return .go(x: y + 5, carry: true)
        case 0xE0:
            if wram[WRAM.fieldSceneFlags] & 0x80 == 0 {
                setLocation(y, id: WRAM.locDestId, xy: WRAM.locDestX, facing: WRAM.locDestFacing)
                wram[WRAM.fieldSceneFlags] |= 0x80                 // SceneFlag_Warp
                wram[WRAM.fadeBrightness] = 0x0F                   // Fade_BrightnessMax
            }
            return .go(x: y, carry: false)
        case 0xE2:
            if wram[WRAM.fieldSceneFlags] & 0x80 == 0 {
                wram.setWord(WRAM.locDestId, wram.word(eventWord(data(y + 1))))
                wram[WRAM.locDestX] = wram[eventWord(data(y + 2))]
                wram[WRAM.locDestX + 1] = wram[eventWord(data(y + 3))]
                wram[WRAM.locDestFacing] = wram[eventWord(data(y + 4))]
                wram[WRAM.fieldSceneFlags] |= 0x80
                wram[WRAM.fadeBrightness] = 0x0F
            }
            return .go(x: y, carry: false)
        case 0x57, 0x5C, 0x62, 0x68, 0x6A, 0x6C, 0x6D, 0x80: return initCharacter(op, y)
        case 0x81: return initSprite(y)
        case 0x92, 0x9C: return walkDirection(y, animate: op == 0x92)
        case 0x96, 0xA0: return walkToTile(y, animate: op == 0x96)
        case 0x94, 0x95:
            if wram[WRAM.objMoveFrames + objCur] != 0 { return .go(x: y, carry: false) }
            let t = op == 0x94 ? data(y + 1) : Int(wram[WRAM.partyObjSlot + data(y + 1)])
            return walkToObject(y, target: t)
        case 0x8F: return followPartyMember(y)
        case 0xB0: return partyControl(y)
        case 0xAF:                                                     // Evt_OpAF_PartyControlOnce
            let r = partyControl(y)
            guard case .go(let x, _) = r else { return r }
            return .go(x: x + 1, carry: false)
        case 0xB5, 0xB6:                                               // Evt_OpB5_FollowObj / Evt_OpB6_FollowPc
            wram.setWord(WRAM.evtUnk0920Key, y)                        // EvtFollow_SavedY
            let walked = dispatch(op == 0xB5 ? 0x94 : 0x95, y)
            guard case .go(_, let carry) = walked else { return walked }
            return .go(x: y, carry: op == 0xB5 ? false : carry)
        case 0xA8: return faceObject(y, target: data(y + 1))
        case 0xA9: return faceObject(y, target: Int(wram[WRAM.partyObjSlot + data(y + 1)]))
        case 0x82: return initNpcSprite(y)
        case 0x83: return initEnemySprite(y)
        case 0xE8, 0xEA, 0xEB, 0xEC: return sound(op, y)
        case 0xE3: wram[WRAM.fieldControlEnabled] = UInt8(data(y + 1)); return .go(x: y + 2, carry: true)
        case 0xE6:
            let amount = dataWord(y + 1), layers = data(y + 3)
            wram[0x7E1D4D] = UInt8(data(y + 4))                     // Map_DriftTimer
            for (bit, at) in [(1, 0x7E1D24), (2, 0x7E1D26), (4, 0x7E1D28)] where layers & bit != 0 {
                wram.setWord(at, amount)                            // Map_Drift1X/2X/3X
            }
            return .go(x: y + 5, carry: true)
        case 0xE7:
            let mode = wram[0x7E1D00]                               // Map_ScrollToMode
            if mode == 0 {
                wram[0x7E1D02] = UInt8((data(y + 1) << 1) & 0xFF)   // Map_ScrollToX/Y
                wram[0x7E1D03] = UInt8((data(y + 2) << 1) & 0xFF)
                wram[0x7E1D00] = 1
                wram[WRAM.fieldControlEnabled] = 0
                return .go(x: y, carry: false)
            }
            if mode == 1 { return .go(x: y, carry: false) }
            wram[0x7E1D00] = 0
            return .go(x: y + 3, carry: true)
        case 0xF0:
            let arg = data(y + 1), delay = arg & 0x0F
            if delay == 0 {
                wram[WRAM.fadeBrightness] = UInt8(arg >> 4 & 0x0F)
            } else {
                wram[WRAM.fadeBrightnessDelay] = UInt8(delay); wram[WRAM.fadeBrightnessTimer] = UInt8(delay)
                wram[WRAM.fadeBrightnessTarget] = UInt8(arg >> 4 & 0x0F)
                wram[WRAM.fieldFadeFlags] |= 0x02
            }
            return .go(x: y + 2, carry: false)
        case 0xF1: return opF1(y)
        case 0xF2: return .go(x: wram[WRAM.fieldFadeFlags] & 0x02 != 0 ? y : y + 1, carry: false)
        case 0xF3: return .go(x: wram[WRAM.fieldFadeFlags] & 0x08 != 0 ? y : y + 1, carry: false)
        case 0xF4:
            let v = UInt8(data(y + 1))
            wram[WRAM.fieldUnkBC] = v
            if v == 0 { wram[0x7E1D4E] = 0; wram[0x7E1D4F] = 0 }   // Map_ShakeX/Y
            return .go(x: y + 2, carry: true)
        default:
            let name = CTEventISA.opcodes[Int(op)].name
            return .unmodelled(String(format: "opcode $%02X (%@) at $%04X has no model yet", Int(op), name, y))
        }
    }

    // MARK: Handlers with more than a line

    /// Evt_Op00_Return.
    func op00(_ y: Int) -> Outcome {
        let c = objCur, level = Int(wram[WRAM.objUnk1C00 + c])
        if level == 7 { return .go(x: y, carry: false) }
        var index = (level * WRAM.evtPrioStride + c) & 0xFFFF
        wram.setWord(WRAM.objXSave + index, 0)
        for _ in 0..<0x200 {
            index = (index + WRAM.evtPrioStride) & 0xFFFF
            wram[WRAM.objUnk1C00 + c] &+= 1
            let saved = wram.word(WRAM.objXSave + index)
            if saved != 0 { return .go(x: saved, carry: true) }
        }
        return .halted(String(format: "$00 at $%04X: no saved position anywhere in bank $7F, so the ROM loops for ever", y))
    }

    enum CallKind { case start, retry }

    /// Evt_Op02_Body / Evt_Op03_Body (and Evt_Op04_Start's first phase through `op04`).
    func callObj(y: Int, slot: Int, arg argAt: Int, kind: CallKind, next: Int) -> Outcome {
        let s = slot & 0xFF
        if wram[WRAM.objUnk1C01 + s] != 0 { return kind == .start ? .go(x: next, carry: true) : .go(x: y, carry: false) }
        if wram[WRAM.objUnk1100 + s] & 0x80 != 0 || wram[WRAM.objUnk1000 + s] & 0x80 != 0 { return .go(x: next, carry: true) }
        let level = Int(wram[WRAM.objUnk1C00 + s]), arg = data(argAt), newLevel = arg >> 4
        if newLevel == level { return kind == .start ? .go(x: next, carry: true) : .go(x: y, carry: false) }
        if newLevel > level {
            if kind == .retry { return .go(x: y, carry: false) }
            let index = (newLevel * WRAM.evtPrioStride + s) & 0xFFFF
            if wram.word(WRAM.objXSave + index) == 0 { wram.setWord(WRAM.objXSave + index, functionOffset(s, arg & 15)) }
            return .go(x: next, carry: true)
        }
        start(s, level: level, newLevel: newLevel, function: arg & 15)
        return .go(x: next, carry: true)
    }

    func functionOffset(_ slot: Int, _ f: Int) -> Int { dataWord((slot * 16 + f * 2) & 0xFFFF) }

    func start(_ s: Int, level: Int, newLevel: Int, function f: Int) {
        let index = (level * WRAM.evtPrioStride + s) & 0xFFFF
        wram.setWord(WRAM.objXSave + index, wram.word(WRAM.objScriptPos + s))
        wram.setWord(WRAM.objScriptPos + s, functionOffset(s, f))
        wram[WRAM.objUnk1C00 + s] = UInt8(newLevel)
        wram[WRAM.objUnk1A80 + s] = 0
        wram[WRAM.objMoveFrames + s] = 0
    }

    /// Evt_Op04_CallObjFuncWait.
    func op04(_ y: Int) -> Outcome {
        if wram[WRAM.objXCallWait + objCur] != 0 { return waitSlot(y, slot: data(y + 1)) }
        return startAndWait(y, slot: data(y + 1))
    }

    /// Evt_Op07_CallPcFuncWait.
    func op07(_ y: Int) -> Outcome {
        let p = data(y + 1), slot = Int(wram[WRAM.partyObjSlot + p])
        if wram[WRAM.objXCallWait + objCur] != 0 { return waitSlot(y, slot: slot) }
        if slot & 0x80 != 0 { return .go(x: y + 3, carry: true) }
        return startAndWait(y, slot: slot)
    }

    /// Evt_Op04_Start.
    func startAndWait(_ y: Int, slot: Int) -> Outcome {
        let s = slot & 0xFF
        if wram[WRAM.objUnk1C01 + s] != 0 { return .go(x: y, carry: false) }
        if wram[WRAM.objUnk1100 + s] & 0x80 != 0 || wram[WRAM.objUnk1000 + s] & 0x80 != 0 { return .go(x: y + 3, carry: true) }
        let level = Int(wram[WRAM.objUnk1C00 + s]), arg = data(y + 2), newLevel = arg >> 4
        if newLevel >= level { return .go(x: y, carry: false) }
        start(s, level: level, newLevel: newLevel, function: arg & 15)
        wram[WRAM.objXCallWait + objCur] = 1
        return .go(x: y, carry: false)
    }

    /// Evt_Op04_WaitSlot.
    func waitSlot(_ y: Int, slot: Int) -> Outcome {
        let s = slot & 0xFF
        if wram[WRAM.objUnk1100 + s] & 0x80 == 0, wram[WRAM.objUnk1000 + s] & 0x80 == 0 {
            let level = Int(wram[WRAM.objUnk1C00 + s]), newLevel = data(y + 2) >> 4
            if newLevel >= level { return .go(x: y, carry: false) }
        }
        wram[WRAM.objXCallWait + objCur] = 0
        return .go(x: y + 3, carry: true)
    }

    /// Evt_JumpFromOfsPos and the other forward jumps: X = the n byte's offset + n.
    func jump(from n: Int) -> Outcome { .go(x: (n + data(n)) & 0xFFFF, carry: true) }

    /// Evt_CmpTable8: C=0 when the comparison holds; X = the next opcode then.
    func compare8(_ left: Int, _ right: Int, cmp: Int, ofsPos: Int) -> Outcome {
        guard (cmp << 1) & 0xFF < 16 else {
            return .unmodelled(String(format: "comparison %d indexes past Evt_CmpTable8", cmp))
        }
        let holds: Bool
        switch (cmp << 1 & 0xFF) >> 1 {
        case 0: holds = left == right
        case 1: holds = left != right
        case 2: holds = left > right
        case 3: holds = left < right
        case 4: holds = left >= right
        case 5: holds = left <= right
        case 6: holds = left & right != 0
        default: holds = left | right != 0
        }
        return holds ? .go(x: ofsPos + 1, carry: true) : jump(from: ofsPos)
    }

    func compare16(_ left: Int, _ right: Int, cmp: Int, ofsPos: Int) -> Outcome {
        guard (cmp << 1) & 0xFF < 16 else {
            return .unmodelled(String(format: "comparison %d indexes past Evt_CmpTable16", cmp))
        }
        return compare8(left, right, cmp: (cmp << 1 & 0xFF) >> 1, ofsPos: ofsPos)
    }

    /// Evt_Op28_IfObjInsideScreen.
    func op28(_ y: Int) -> Outcome {
        let s = data(y + 1)
        let col = Int(wram[0x7E1D0A]) >> 1, row = Int(wram[0x7E1D0E]) >> 1   // Map_TileOriginX/Y / 2
        let dx = (Int(wram[WRAM.objTileX + s]) - col) & 0xFF, dy = (Int(wram[WRAM.objTileY + s]) - row) & 0xFF
        if dx == 0 || dx == 1 || dx >= 0x0E || dy == 0 || dy == 1 || dy >= 0x0D { return jump(from: y + 2) }
        return .go(x: y + 3, carry: true)
    }

    /// Evt_Op4E_CopyData: the data bytes after the header to dst in bank $7E
    /// (bank byte $7E) or $7F (any other), with MVN's byte order.
    func op4E(_ y: Int) -> Outcome {
        let dst = dataWord(y + 1), bank = data(y + 3) == 0x7E ? 0x7E0000 : 0x7F0000
        let len = dataWord(y + 4), count = (len - 3) & 0xFFFF
        var src = (y + 6 + 0x2001) & 0xFFFF, d = dst
        for _ in 0...count {
            wram[bank | d] = wram[0x7F0000 | src]
            src = (src + 1) & 0xFFFF; d = (d + 1) & 0xFFFF
        }
        return .go(x: (src - 0x2001) & 0xFFFF, carry: true)
    }

    func writeLong(_ long: Int, _ v: UInt8) {
        if WRAMModel.canonical(long) != nil { wram[long] = v }
    }

    func setFacing(_ slot: Int, _ facing: Int, next: Int) -> Outcome {
        wram[WRAM.objFacing + slot] = UInt8(facing & 0xFF)
        wram[WRAM.objAnimTimer + slot] = 0
        return .go(x: next, carry: false)
    }

    /// Map_TileAttrA/B's priority bits (bit 6) as OAM priority, A to Obj_PrioHigh.
    func tilePriorities(_ c: Int, tile: Int) {
        let a = (wram[0x7E7000 + tile] & 0x40) >> 2 | 0x20, b = (wram[0x7E7040 + tile] & 0x40) >> 2 | 0x20
        wram[WRAM.objPrioLow + c] = b
        wram[WRAM.objPrioHigh + c] = a
    }

    /// Evt_SetAnimMode.
    func setAnimMode(_ c: Int, _ mode: UInt8, next: Int) -> Outcome {
        wram[WRAM.objAnimMode + c] = mode
        wram[WRAM.objAnimTimer + c] = 0
        wram[WRAM.objXAnimLoops + c] = 0
        wram[WRAM.objAnimColumn + c] = 0
        return .go(x: next, carry: true)
    }

    /// Evt_OpAB_PlayAnimOnce / Evt_OpB7_PlayAnimLoops.
    func playAnim(_ y: Int, loops: Bool) -> Outcome {
        let c = objCur, left = wram[WRAM.objXAnimLoops + c], row = UInt8(data(y + 1))
        if left == 1 {
            wram[WRAM.objXAnimLoops + c] = 0
            wram[WRAM.objAnimTimer + c] = 0
            wram[WRAM.objAnimColumn + c] = 0
            if wram[WRAM.objAnimRow + c] == 0xFF {
                wram[WRAM.objAnimRow + c] = 0
                wram[WRAM.objAnimMode + c] = 0
            } else {
                wram[WRAM.objAnimMode + c] = 1
            }
            return .go(x: y + (loops ? 3 : 2), carry: true)
        }
        if left != 0, wram[WRAM.objAnimRowAlt + c] == row { return .go(x: y, carry: false) }
        wram[WRAM.objAnimRowAlt + c] = row
        wram[WRAM.objAnimColumn + c] = 0
        wram[WRAM.objAnimTimer + c] = 0
        if wram[WRAM.objAnimMode + c] == 0 { wram[WRAM.objAnimRow + c] = 0xFF }
        wram[WRAM.objAnimMode + c] = 2
        if !loops { wram[WRAM.objXAnimLoops + c] = 2 }             // Evt_AnimLoopsOnce
        else { wram[WRAM.objXAnimLoops + c] = UInt8((data(y + 2) + 1) & 0xFF) }
        return .go(x: y, carry: false)
    }

    /// Evt_WaitRuns and Evt_OpAD_WaitRuns.
    func waitRuns(_ n: UInt8, y: Int, next: Int) -> Outcome {
        let c = objCur, count = wram[WRAM.objXEvtWait + c]
        if n == count { wram[WRAM.objXEvtWait + c] = 0; return .go(x: next, carry: true) }
        if n < count { wram[WRAM.objXEvtWait + c] = 0; return .go(x: y, carry: true) }
        wram[WRAM.objXEvtWait + c] = count &+ 1
        return .go(x: y, carry: false)
    }

    /// Evt_OpBB_Msg and its variants, Evt_OpC0_MsgChoice and Evt_MsgChoiceStart.
    func message(_ y: Int, unk30: UInt8, choice: Bool) -> Outcome {
        if wram[WRAM.fieldUnk2D] == 0 { return .halted("message opcode with no message pointer ($B8): Sys_HaltWithColor") }
        if wram[WRAM.fieldUnk29] != 0 { return .go(x: y, carry: false) }
        let c = objCur
        if wram[WRAM.objXLeaveView + c] != 0 {
            wram[WRAM.objXLeaveView + c] = 0
            if !choice { return .go(x: y + 2, carry: true) }
            wram[WRAM.objXUnk7F0A80 + c] = wram[WRAM.fieldUnk66]
            wram[WRAM.fieldUnk62] = 0
            return .go(x: y + 3, carry: true)
        }
        if choice { wram[WRAM.fieldUnk30] = unk30 }
        wram[WRAM.objXLeaveView + c] = 1
        wram[WRAM.fieldUnk2A] = UInt8(data(y + 1))
        if choice {
            let choices = data(y + 2)
            wram[WRAM.fieldUnk65] = UInt8(choices & 3)
            wram[WRAM.fieldUnk64] = UInt8(choices >> 2 & 3)
            wram[WRAM.fieldUnk62] = 1
        }
        wram[WRAM.fieldUnk2E] = wram[WRAM.objCur]
        wram[WRAM.fieldUnk32] = 0
        wram[WRAM.fieldUnk29] = 1
        if !choice { wram[WRAM.fieldUnk30] = unk30 }
        wram[WRAM.fieldUnk54] &= ~0x20
        return .go(x: y, carry: false)
    }

    /// Evt_OpD8_StartBattle: the request and the wait; the battle is the field's.
    func opD8(_ y: Int) -> Outcome {
        if wram[WRAM.fieldSceneFlags] & 0x01 != 0 { return .go(x: y, carry: false) }
        if wram[WRAM.fieldFadeFlags] & 0x01 != 0 {
            wram[WRAM.fieldFadeFlags] &= ~0x01
            return .go(x: y + 3, carry: false)
        }
        wram[0x7E2989] = UInt8(data(y + 1))                         // Field_Unk7E2989
        wram[0x7E2A1F] = UInt8(data(y + 2))                         // FieldBtl_EvtFlags
        wram[WRAM.fieldSceneFlags] |= 0x21
        wram[WRAM.fieldControlEnabled] = 0
        return .go(x: y, carry: false)
    }

    /// The location word (Loc_IdMask) and the column/row word, and the facing
    /// from the word's high byte (bits 1-4, and bit 7 kept).
    func setLocation(_ y: Int, id: Int, xy: Int, facing: Int) {
        let w = dataWord(y + 1)
        wram.setWord(id, w & 0x1FF)
        wram.setWord(xy, dataWord(y + 3))
        let hi = UInt8(w >> 8)
        wram[facing] = (hi >> 1) & 0x0F
        wram[facing] |= hi & 0x80
    }

    /// Evt_OpF1_FadeFixedColor.
    func opF1(_ y: Int) -> Outcome {
        let colour = UInt8(data(y + 1))
        if colour == 0 {
            wram[WRAM.fadeFixedColorTarget] = 0xE0; wram[WRAM.fadeFixedColor] = 0xE0
            wram[0x7E0BE0] = wram[0x7E0BDF]
            return .go(x: y + 2, carry: true)
        }
        wram[WRAM.fadeFixedColorTarget] = colour
        wram[WRAM.fadeFixedColor] = wram[WRAM.fadeFixedColor] & 0x1F | colour & 0xE0
        let s = UInt8(data(y + 2))
        let delay = s & 0x80 != 0 ? s & 0x7F : s
        wram[0x7E0BE0] = s & 0x80 != 0 ? 0x97 : 0x17
        if delay == 0 {
            wram[WRAM.fadeFixedColor] = colour
            return .go(x: y + 3, carry: true)
        }
        wram[WRAM.dpField + 0x23] = delay; wram[WRAM.dpField + 0x24] = delay   // Fade_FixedColorDelay / Timer
        wram[WRAM.fadeFixedColor] = wram[WRAM.fadeFixedColor] & 0x1F | colour & 0xE0
        wram[WRAM.fieldFadeFlags] |= 0x18
        return .go(x: y + 3, carry: false)
    }

    /// Evt_OpE8/EA/EB/EC: the Audio_Cmd* block, then Audio_DriverCommand (the
    /// APU handshake is the driver's; the command is queued in `audio`).
    func sound(_ op: UInt8, _ y: Int) -> Outcome {
        func send(_ id: UInt8, _ a0: UInt8, _ a1: UInt8) {
            wram[0x7E1E00] = id; wram[0x7E1E01] = a0; wram[0x7E1E02] = a1   // Audio_CmdId, Arg0, Arg1
            audio.append(AudioCommand(id: id, arg0: a0, arg1: a1, arg2: wram[0x7E1E03]))
        }
        switch op {
        case 0xE8:
            wram.setWord(WRAM.evtOpSavedPos, y + 1)
            send(0x18, UInt8(data(y + 1)), 0x80)                        // Audio_Cmd18, Audio_Cmd18Arg1
            return .go(x: y + 2, carry: false)
        case 0xEA:
            let track = UInt8(data(y + 1))
            wram[0x7E29AE] = track                                      // Menu_Config1E
            wram.setWord(WRAM.evtOpSavedPos, y + 1)
            send(0x10, track, wram[0x7E1E02])                           // Audio_CmdPlayMusic
            return .go(x: y + 2, carry: false)
        case 0xEB:
            wram[0x7E1E03] = 0xFF                                       // Audio_Cmd81Arg
            wram.setWord(WRAM.evtOpSavedPos, y + 2)
            send(0x81, UInt8(data(y + 1)), UInt8(data(y + 2)))         // Audio_CmdUnk81
            send(0x82, 0, 0xFF)
            send(0x83, 0, 0xFF)
            return .go(x: y + 3, carry: false)
        default:
            wram.setWord(WRAM.evtOpSavedPos, y + 4)
            send(UInt8(data(y + 1)), UInt8(data(y + 2)), UInt8(data(y + 3)))
            return .go(x: y + 4, carry: false)
        }
    }
}
