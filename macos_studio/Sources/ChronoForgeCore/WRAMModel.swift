// WRAMModel.swift — the 128 KiB of SNES work RAM ($7E:0000–$7F:FFFF) the
// embedded runtime keeps, with the addresses of the event VM's state named
// after ChronoRET's symbols (asm/include/ram_engine.inc, ram_menu.inc). One
// model holds the story block ($7F:0000–$01FF), the event words ($7F:0200 +
// 2a), the object tables ($7E:0A00–$1CFF, ObjX_* in bank $7F) and Loc_*, so
// the runtime, its inspector and the handler checks all read the same bytes.
import Foundation

public struct WRAMModel: Equatable, Sendable {
    public static let size = 0x20000
    public var bytes: [UInt8]
    /// Every write since `recording` was last turned on, in order.
    public private(set) var writes: [(address: Int, value: UInt8)] = []
    public var recording = false {
        didSet { if recording { writes.removeAll(keepingCapacity: true) } }
    }

    public init() { bytes = [UInt8](repeating: 0, count: Self.size) }

    public static func == (a: WRAMModel, b: WRAMModel) -> Bool { a.bytes == b.bytes }

    /// The canonical long address of a WRAM byte ($7E:0000–$7F:FFFF), with low
    /// WRAM's mirrors in banks $00–$3F and $80–$BF folded onto $7E; nil for
    /// anything else (ROM, hardware registers).
    public static func canonical(_ long: Int) -> Int? {
        let a = long & 0xFFFFFF, bank = a >> 16, low = a & 0xFFFF
        if bank == 0x7E || bank == 0x7F { return a }
        if (bank < 0x40 || (0x80..<0xC0).contains(bank)), low < 0x2000 { return 0x7E0000 | low }
        return nil
    }

    public subscript(_ long: Int) -> UInt8 {
        get { Self.canonical(long).map { bytes[$0 - 0x7E0000] } ?? 0 }
        set {
            guard let a = Self.canonical(long) else { return }
            bytes[a - 0x7E0000] = newValue
            if recording { writes.append((a, newValue)) }
        }
    }

    public func word(_ long: Int) -> Int { Int(self[long]) | Int(self[long + 1]) << 8 }
    public mutating func setWord(_ long: Int, _ value: Int) {
        self[long] = UInt8(value & 0xFF)
        self[long + 1] = UInt8(value >> 8 & 0xFF)
    }

    /// The final value of each address written since recording began.
    public var writtenValues: [Int: UInt8] {
        var out: [Int: UInt8] = [:]
        for w in writes { out[w.address] = w.value }
        return out
    }
}

/// WRAM addresses the event VM and the field use (ChronoRET names; the DP_Field
/// page $0100 is folded in, so `Obj_Cur` is $7E:016D).
public enum WRAM {
    public static let dpField = 0x7E0100
    // Loc_* (DP_Field)
    public static let locId = dpField + 0x00, locEntryX = dpField + 0x02, locEntryY = dpField + 0x03
    public static let locEntryFacing = dpField + 0x04, locReturnId = dpField + 0x05, locReturnX = dpField + 0x07
    public static let locReturnY = dpField + 0x08, locReturnFacing = dpField + 0x09
    public static let locPrevId = dpField + 0x0A, locPrevX = dpField + 0x0C, locPrevFacing = dpField + 0x0E
    public static let locDestId = dpField + 0x12, locDestX = dpField + 0x14, locDestFacing = dpField + 0x16
    // Field state (DP_Field)
    public static let fieldSceneFlags = dpField + 0x17, fieldFadeFlags = dpField + 0x18
    public static let fadeBrightness = dpField + 0x19, fadeBrightnessTarget = dpField + 0x1B
    public static let fadeBrightnessDelay = dpField + 0x1C, fadeBrightnessTimer = dpField + 0x1D
    public static let fieldUnk1E = dpField + 0x1E, fieldControlEnabled = dpField + 0x1F
    public static let fadeFixedColor = dpField + 0x21, fadeFixedColorTarget = dpField + 0x22
    public static let fieldBankC2Arg = dpField + 0x25
    public static let fieldUnk29 = dpField + 0x29, fieldUnk2A = dpField + 0x2A, fieldUnk2B = dpField + 0x2B
    public static let fieldUnk2D = dpField + 0x2D, fieldUnk2E = dpField + 0x2E, fieldUnk30 = dpField + 0x30
    public static let fieldUnk32 = dpField + 0x32, fieldUnk38 = dpField + 0x38
    public static let padUnk00F6Latch = dpField + 0x50, padPressedLatch = dpField + 0x51
    public static let fieldUnk54 = dpField + 0x54
    public static let fieldUnk62 = dpField + 0x62, fieldUnk63 = dpField + 0x63, fieldUnk64 = dpField + 0x64
    public static let fieldUnk65 = dpField + 0x65, fieldUnk66 = dpField + 0x66
    public static let evtStepsLeft = dpField + 0x67, fieldUnk68 = dpField + 0x68
    public static let objQScanlineLimit = dpField + 0x6B
    public static let objCur = dpField + 0x6D
    public static let objQUnk74 = dpField + 0x74, objQUnk75 = dpField + 0x75
    public static let objQUnk71 = dpField + 0x71, objQUnk73 = dpField + 0x73, objQUnk78 = dpField + 0x78
    public static let objQHead = dpField + 0x76, objQTail = dpField + 0x77
    public static let chrObjSlot = dpField + 0x8D, partyObjSlot = dpField + 0x97
    public static let partyObjSlot1 = dpField + 0x99, partyObjSlot2 = dpField + 0x9B
    public static let fieldUnkAB = dpField + 0xAB, fieldUnkAEObj = dpField + 0xAE
    /// Field_E4Ptr0-3: 24-bit pointers into bank $E4 (tile graphics, frames, animation frame and time tables).
    public static let fieldE4Ptr0 = dpField + 0xAF, fieldE4Ptr1 = dpField + 0xB2
    public static let fieldE4Ptr2 = dpField + 0xB5, fieldE4Ptr3 = dpField + 0xB8
    public static let evtSprRecOfs = dpField + 0xBF, evtOpSavedPos = dpField + 0xC7
    public static let evtSprIdx = dpField + 0xD9, evtCharId = dpField + 0xD9
    public static let evtSprSlotArg = dpField + 0xE1, evtUnk0920Key = dpField + 0xE3
    public static let evtObjSlotEnd = dpField + 0xBD
    public static let fieldUnkBC = dpField + 0xBC
    public static let fieldUnkEB = dpField + 0xEB
    /// The DP scratch the handlers use within one opcode (Eng_Scratch and the
    /// slots aliased on it: EvtIf_*, EvtCall_*, EvtJump_Dist, ObjFront_*, ...).
    /// The handler checks leave it out; Field_UnkEB ($01EB) lies between.
    public static func isScratch(_ a: Int) -> Bool {
        (0x7E01C1...0x7E01EA).contains(a) || (0x7E01EE...0x7E01F7).contains(a)
    }
    // Pad (absolute)
    public static let padPressed = 0x7E00F0, menuPadHeld = 0x7E00F2
    public static let padUnk00F6 = 0x7E00F6, padUnk00F8 = 0x7E00F8, padUnk00F9 = 0x7E00F9
    // Sprite bookkeeping and the decompressor's block (absolute)
    public static let objTileSlot = 0x7E0B88
    public static let evtUnk0920 = 0x7E0920, evtUnk0930 = 0x7E0930
    public static let decompSrc = 0x7E0300, decompSrcBank = 0x7E0302, decompDest = 0x7E0303
    public static let decompDestBank = 0x7E0305, decompOutLen = 0x7E0306
    /// FieldBtlObj[k].GfxOfs (12-byte records from $7E:29BF).
    public static func fieldBtlObjGfxOfs(_ k: Int) -> Int { 0x7E29BF + 12 * k + 9 }
    // Object tables: object x 2 indexes them
    public static let objPrioLow = 0x7E0C00, objPrioHigh = 0x7E0C01
    public static let objVramTile = 0x7E0D00, objTileBuf = 0x7E0D80
    public static let objGfxBank = 0x7E1200, objSprSize = 0x7E1201, objGfxOfs = 0x7E1280
    public static let objFrameBank = 0x7E1300, objFrameOfs = 0x7E1380, objPalSrc = 0x7E1400
    public static let objAnimFacingStride = 0x7E1480, objAnimFrameTbl = 0x7E1500, objAnimTimeTbl = 0x7E1580
    public static let objTileRecOfs = 0x7E1700
    public static let objUnk0F00 = 0x7E0F00, objLastFrame = 0x7E0F01, objOamFlags = 0x7E0F80, objOamAttr = 0x7E0F81
    public static let objUnk1000 = 0x7E1000, objUnk1001 = 0x7E1001, objUnk1080 = 0x7E1080, objQueueNext = 0x7E1081
    public static let objUnk1100 = 0x7E1100, objUnk1101 = 0x7E1101, objScriptPos = 0x7E1180
    public static let objFixedFrame = 0x7E1301
    public static let objFacing = 0x7E1600, objAnimTimer = 0x7E1601
    public static let objAnimRow = 0x7E1680, objAnimColumn = 0x7E1681
    public static let objAnimMode = 0x7E1780, objAnimRowAlt = 0x7E1781
    public static let objPosX = 0x7E1800, objTileX = 0x7E1801, objPosY = 0x7E1880, objTileY = 0x7E1881
    public static let objVelX = 0x7E1900, objVelY = 0x7E1980
    public static let objSpeed = 0x7E1A00, objMoveFrames = 0x7E1A01, objUnk1A80 = 0x7E1A80, objUnk1A81 = 0x7E1A81
    public static let objState = 0x7E1B00, objUnk1B01 = 0x7E1B01, objArcMode = 0x7E1B80
    public static let objUnk1C00 = 0x7E1C00, objUnk1C01 = 0x7E1C01, objUnk1C80 = 0x7E1C80, objUnk1C81 = 0x7E1C81
    // Bank $7F
    public static let evtMem7F = 0x7F0000
    public static let storyEnd = 0x7F0200
    public static let evtWords = 0x7F0200
    public static let objXSave = 0x7F0580            // ObjX_Unk7F0580 + level x $80
    public static let objXCallWait = 0x7F0980
    public static let objXLeaveView = 0x7F0A00, objXEvtWait = 0x7F0A01
    public static let objXUnk7F0A80 = 0x7F0A80
    public static let objXUnk7F0B00 = 0x7F0B00, objXAnimLoops = 0x7F0B01, objXUnk7F0B80 = 0x7F0B80
    public static let evtObjCount = 0x7F2000, evtData = 0x7F2001
    public static let partyMembers = 0x7E2980
    public static let evtPrioStride = 0x80

    /// Event word a ($7F:0200 + 2a).
    public static func eventWord(_ a: Int) -> Int { evtWords + 2 * a }
}
