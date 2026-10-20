/// Bounded host-side implementation of CT's Audio_Boot transfer protocol.
/// The caller supplies the 64-byte IPL image; no firmware is bundled here.
/// Protocol evidence: ChronoRET af992bdd99603332ac91b32c621dfbfec3ae816a,
/// asm/bankC7/bankC7.asm, Audio_Boot ($C7:0038...$C7:013F).
/// This drives host ports while executing the SPC700, not the 65816 sender.
/// Host writes take no SMP clocks; physical host/APU scheduling is not modeled.
public final class SPCIPLHost {
    public struct Block: Equatable, Sendable {
        public let destination: UInt16
        public let bytes: [UInt8]
        public init(destination: UInt16, bytes: [UInt8]) {
            self.destination = destination; self.bytes = bytes
        }
    }

    public struct Limits: Equatable, Sendable {
        public let totalCycles, waitCycles: Int
        /// Budgets are checked at instruction boundaries. A failed operation
        /// can exceed its budget by the last instruction, but cannot succeed
        /// beyond the budget. A host can be used for only one upload attempt.
        public init(totalCycles: Int = 4_000_000, waitCycles: Int = 100_000) {
            self.totalCycles = totalCycles; self.waitCycles = waitCycles
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case invalidInput(String)
        case alreadyUsed
        case budgetExceeded(phase: String, cycles: Int, pc: UInt16)
        case stopped(phase: String, pc: UInt16)
        case busFault(SSMPBus.Fault)
        case integrity(block: Int, address: UInt16, expected: UInt8, actual: UInt8)
        case wrongEntry(expected: UInt16, actual: UInt16)

        public var description: String {
            switch self {
            case .invalidInput(let message): return "IPL upload: \(message)"
            case .alreadyUsed: return "IPL upload host has already been used"
            case .budgetExceeded(let phase, let cycles, let pc):
                return "IPL upload \(phase) exceeded cycle budget at \(cycles) cycles (PC $\(String(pc, radix: 16)))"
            case .stopped(let phase, let pc):
                return "IPL upload CPU stopped during \(phase) (PC $\(String(pc, radix: 16)))"
            case .busFault(let fault): return "IPL upload bus fault: \(fault)"
            case .integrity(let block, let address, let expected, let actual):
                return "IPL upload block \(block) differs at $\(String(address, radix: 16)): expected \(expected), got \(actual)"
            case .wrongEntry(let expected, let actual):
                return "IPL left its ROM at $\(String(actual, radix: 16)) instead of entry $\(String(expected, radix: 16))"
            }
        }
    }

    public struct BlockReport: Codable, Equatable, Sendable {
        public let destination: UInt16
        public let byteCount: Int
        public let sha256: String
        public let startToken, lastByteToken, nextToken: UInt8
    }

    public struct Report: Codable, Equatable, Sendable {
        public let totalCycles, bytesTransferred, acknowledgementCount: Int
        public let entry: UInt16
        /// Token of the final (start) header; IPL echoes it before jumping.
        public let startToken: UInt8
        public let blocks: [BlockReport]
        public let payloadVerified: Bool
        public var blockCount: Int { blocks.count }
    }

    public let bus: SSMPBus
    public let cpu: SPC700
    private let limits: Limits
    private var used = false

    /// Zero-filled ARAM, zero input/output latches, normal timer phases, IPL
    /// overlay enabled, PC $FFC0. This is a diagnostic state, not power-on fidelity.
    public init(iplROM: [UInt8], dsp: any SSMPDSPPort, limits: Limits = .init()) throws {
        try Self.validate(limits)
        bus = try SSMPBus(iplROM: iplROM, iplROMEnabled: true, dsp: dsp)
        cpu = SPC700(bus: bus, registers: .init(pc: 0xFFC0))
        self.limits = limits
    }

    /// Upload nonoverlapping blocks in order, then stop at `entry` BEFORE its
    /// first instruction. Compare physical RAM only after the final jump: IPL
    /// byte acknowledgements may precede the corresponding RAM store.
    /// Reject the first two pages (IPL scratch/stack/MMIO) and IPL overlay.
    @discardableResult
    public func upload(blocks: [Block], entry: UInt16) throws -> Report {
        guard !used else { throw Failure.alreadyUsed }
        used = true
        return try Self.upload(to: Machine(cpu: cpu, bus: bus), blocks: blocks, entry: entry, limits: limits)
    }

    private static func validate(_ limits: Limits) throws {
        guard (1...100_000_000).contains(limits.totalCycles),
              (1...100_000_000).contains(limits.waitCycles) else {
            throw Failure.invalidInput("cycle budgets must be 1...100000000")
        }
    }

    // Transport boundary permits independent protocol tests without embedding
    // copyrighted IPL bytes or pretending a synthetic receiver is real firmware.
    static func upload(to machine: any SPCIPLTransport, blocks: [Block], entry: UInt16,
                       limits: Limits) throws -> Report {
        try validate(limits)
        guard !blocks.isEmpty, blocks.count <= 256 else {
            throw Failure.invalidInput("supply 1...256 blocks")
        }
        var occupied = Set<Int>()
        for block in blocks {
            let start = Int(block.destination)
            guard !block.bytes.isEmpty, block.bytes.count <= 65536,
                  start >= 0x0200, start + block.bytes.count <= 0xFFC0 else {
                throw Failure.invalidInput("blocks must be nonempty and fit ARAM $0200...$FFBF")
            }
            for address in start..<(start + block.bytes.count) {
                guard occupied.insert(address).inserted else {
                    throw Failure.invalidInput("upload blocks must not overlap")
                }
            }
        }
        guard occupied.contains(Int(entry)) else {
            throw Failure.invalidInput("entry must lie in an uploaded block")
        }
        let initialCycles = machine.cycles
        var failure: Failure?
        func wait(_ phase: String, until predicate: () -> Bool) throws {
            let start = machine.cycles
            while true {
                if let fault = machine.fault { throw Failure.busFault(fault) }
                if machine.stopped { throw Failure.stopped(phase: phase, pc: machine.pc) }
                if machine.cycles - initialCycles > limits.totalCycles || machine.cycles - start > limits.waitCycles {
                    throw Failure.budgetExceeded(phase: phase, cycles: machine.cycles - initialCycles, pc: machine.pc)
                }
                if predicate() { return }
                guard machine.cycles - initialCycles < limits.totalCycles,
                      machine.cycles - start < limits.waitCycles else {
                    throw Failure.budgetExceeded(phase: phase, cycles: machine.cycles - initialCycles, pc: machine.pc)
                }
                machine.step()
            }
        }
        func header(destination: UInt16, command: UInt8, token: UInt8, phase: String) throws {
            machine.hostWrite(port: 2, value: UInt8(truncatingIfNeeded: destination))
            machine.hostWrite(port: 3, value: UInt8(destination >> 8))
            machine.hostWrite(port: 1, value: command)
            machine.hostWrite(port: 0, value: token)
            try wait(phase, until: { machine.hostRead(port: 0) == token })
        }

        try wait("ready signature", until: { machine.hostRead(port: 0) == 0xAA && machine.hostRead(port: 1) == 0xBB })
        var token: UInt8 = 0xCC
        var byteCount = 0, acknowledgements = 0
        var reports: [BlockReport] = []
        for (index, block) in blocks.enumerated() {
            let startToken = token
            try header(destination: block.destination, command: token, token: token, phase: "block \(index) header")
            acknowledgements += 1
            for (offset, byte) in block.bytes.enumerated() {
                let counter = UInt8(truncatingIfNeeded: offset)
                machine.hostWrite(port: 1, value: byte)
                machine.hostWrite(port: 0, value: counter)
                try wait("block \(index) byte \(offset)", until: { machine.hostRead(port: 0) == counter })
                byteCount += 1; acknowledgements += 1
            }
            let last = UInt8(truncatingIfNeeded: block.bytes.count - 1)
            token = last &+ 4
            if token == 0 { token = 1 }
            reports.append(.init(destination: block.destination, byteCount: block.bytes.count,
                                 sha256: CTEventPack.sha256(block.bytes), startToken: startToken,
                                 lastByteToken: last, nextToken: token))
        }
        try header(destination: entry, command: 0, token: token, phase: "start acknowledgement")
        acknowledgements += 1
        machine.hostWrite(port: 0, value: 0)
        // Between its start echo and the jump, IPL code stays in $FFC0...$FFFF;
        // stop at the first PC outside it rather than run a wrong target.
        try wait("entry jump", until: {
            if machine.pc == entry { return true }
            if machine.pc < 0xFFC0 { failure = .wrongEntry(expected: entry, actual: machine.pc); return true }
            return false
        })
        if let failure { throw failure }
        for (index, block) in blocks.enumerated() {
            for (offset, expected) in block.bytes.enumerated() {
                let address = Int(block.destination) + offset
                let actual = machine.ram[address]
                guard actual == expected else {
                    throw Failure.integrity(block: index, address: UInt16(address), expected: expected, actual: actual)
                }
            }
        }
        return .init(totalCycles: machine.cycles - initialCycles, bytesTransferred: byteCount,
                     acknowledgementCount: acknowledgements, entry: entry, startToken: token, blocks: reports, payloadVerified: true)
    }

    /// The real CPU and bus behind the transport; also used by `CTSPCTransfer`.
    final class Machine: SPCIPLTransport {
        let cpu: SPC700
        let bus: SSMPBus
        init(cpu: SPC700, bus: SSMPBus) { self.cpu = cpu; self.bus = bus }
        var cycles: Int { cpu.cycles }
        var pc: UInt16 { cpu.registers.pc }
        var stopped: Bool { cpu.stopped }
        var fault: SSMPBus.Fault? { bus.fault }
        var ram: [UInt8] { bus.ram }
        func hostWrite(port: Int, value: UInt8) { bus.hostWrite(port: port, value: value) }
        func hostRead(port: Int) -> UInt8 { bus.hostRead(port: port) }
        func step() { cpu.step() }
    }
}

protocol SPCIPLTransport: AnyObject {
    var cycles: Int { get }
    var pc: UInt16 { get }
    var stopped: Bool { get }
    var fault: SSMPBus.Fault? { get }
    var ram: [UInt8] { get }
    func hostWrite(port: Int, value: UInt8)
    func hostRead(port: Int) -> UInt8
    func step()
}
