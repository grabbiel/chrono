// CTFieldDebugger.swift — a CTFieldRuntime under a debugger: every story-
// byte change ($7F:0000–$01FF) with the instruction that made it, and
// breakpoints on a flag (a byte, or one bit of it) or on an instruction
// (an Evt_Data offset, optionally of one object). The field steps whole
// frames, so a hit stops the run at the end of its frame and names what hit.
import Foundation

public final class CTFieldDebugger {
    public let field: CTFieldRuntime

    public struct Change: Equatable, Sendable, Identifiable {
        public var id: Int
        public var frame: Int, address: Int, old: UInt8, new: UInt8
        public var object: Int, offset: Int, opcode: UInt8
    }

    public enum Breakpoint: Hashable, Sendable {
        /// The byte at `address` changes (any bit, or bit `bit` with 0-7).
        case flag(address: Int, bit: Int?)
        /// An instruction at `offset` runs (in any object when `object` is nil).
        case instruction(offset: Int, object: Int?)
    }

    public struct Hit: Equatable, Sendable {
        public var breakpoint: Breakpoint, frame: Int, object: Int, offset: Int, opcode: UInt8
    }

    public private(set) var changes: [Change] = []
    public var breakpoints: Set<Breakpoint> = []
    public private(set) var lastHit: Hit?
    /// The last instruction each object ran: (offset, opcode).
    public private(set) var lastInstruction: [Int: (offset: Int, opcode: UInt8)] = [:]
    public private(set) var unmodelled: [Int: String] = [:]
    private var pendingHit: Hit?

    public init(field: CTFieldRuntime) {
        self.field = field
        field.vm.trace = { [weak self] e in self?.observe(e) }
    }

    func observe(_ e: CTEventVM.TraceEvent) {
        let o = e.slot / 2, frame = field.frameCount
        lastInstruction[o] = (e.offset, e.opcode)
        if case .unmodelled(let why) = e.outcome { unmodelled[o] = why }
        for w in e.storyWrites {
            changes.append(Change(id: changes.count, frame: frame, address: w.address, old: w.old, new: w.new,
                                  object: o, offset: e.offset, opcode: e.opcode))
            for b in breakpoints {
                guard case .flag(let address, let bit) = b, address == w.address else { continue }
                if let bit, (w.old ^ w.new) & UInt8(1 << (bit & 7)) == 0 { continue }
                if pendingHit == nil { pendingHit = Hit(breakpoint: b, frame: frame, object: o, offset: e.offset, opcode: e.opcode) }
            }
        }
        for b in breakpoints {
            guard case .instruction(let offset, let object) = b, offset == e.offset, object == nil || object == o else { continue }
            if pendingHit == nil { pendingHit = Hit(breakpoint: b, frame: frame, object: o, offset: e.offset, opcode: e.opcode) }
        }
    }

    /// One frame; the breakpoint it (or the load before it) hit, if any.
    @discardableResult
    public func step(input: CTFieldInput) throws -> Hit? {
        try field.step(input: input)
        let hit = pendingHit
        pendingHit = nil
        if let hit { lastHit = hit }
        return hit
    }

    /// Up to `frames` frames of `script` (frame numbers from the field's
    /// count), stopping after a frame that hits a breakpoint.
    public func run(frames: Int, script: CTFieldInput.Script) throws -> Hit? {
        for _ in 0..<frames {
            if let h = try step(input: script.held(at: field.frameCount)) { return h }
        }
        return nil
    }

    /// The story byte at `address` (before a run: the flags to start with).
    public func setStoryByte(_ address: Int, _ value: UInt8) { field.vm.wram[address] = value }

    /// The changes of the last `frames` frames to `address`, newest first.
    public func recentChanges(_ address: Int, within frames: Int) -> [Change] {
        changes.reversed().filter { $0.address == address && field.frameCount - $0.frame <= frames }
    }
}
