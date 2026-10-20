/// Register and clock boundary for an attached S-DSP. Addresses are 0...127.
/// `clock()` advances one normal-speed SMP clock (nominally 1.024 MHz).
/// This interface deliberately supplies no default synthesizer or DSP state.
public protocol SSMPDSPPort: AnyObject {
    func readRegister(_ address: UInt8) -> UInt8
    func writeRegister(_ address: UInt8, _ value: UInt8)
    func clock()
}

/// Deterministic, single-owner normal-speed S-SMP bus, not a hardware reset or
/// an SPC snapshot restore. Initial RAM does not initialize MMIO latches.
///
/// Register behavior was checked against the primary Snes9x implementations:
/// https://github.com/snes9xgit/snes9x/blob/master/apu/bapu/smp/memory.cpp
/// https://github.com/snes9xgit/snes9x/blob/master/apu/bapu/smp/timing.cpp
/// and RAM/TEST behavior against ares/sfc/smp/{memory,io}.cpp in ares-emulator/ares.
/// These are behavioral references, not hardware conformance evidence. Unlike
/// their scheduler, this bus performs accesses BEFORE clocking, as SPC700Bus
/// requires. Subcycle port races and nonstandard TEST modes are not modeled.
public final class SSMPBus: SPC700Bus {
    public enum ConfigurationError: Error, Equatable {
        case ramSize(Int)
        case iplROMSize(Int)
        case missingIPLROM
    }

    public enum Fault: Error, Equatable, CustomStringConvertible {
        case unsupportedTEST(UInt8)
        case missingIPLROM

        public var description: String {
            switch self {
            case .unsupportedTEST(let value):
                return "unsupported S-SMP TEST value \(value); only normal-speed 0x0A is supported"
            case .missingIPLROM:
                return "S-SMP IPL overlay enabled without a supplied 64-byte IPL ROM"
            }
        }
    }

    /// Raw physical memory, including RAM behind MMIO and the IPL overlay.
    /// Observation has no device side effects and consumes no clocks.
    public private(set) var ram: [UInt8]
    public private(set) var cycles = 0
    public private(set) var control: UInt8
    public private(set) var iplROMEnabled: Bool
    /// Sticky failure. The failed access and all subsequent bus operations do
    /// not modify state or advance time. Owners must stop the CPU on a fault;
    /// SPC700Bus cannot throw and the CPU's own cycle counter can still advance.
    public private(set) var fault: Fault?

    private let iplROM: [UInt8]?
    private let dsp: any SSMPDSPPort
    private var dspAddress: UInt8 = 0
    private var hostToAPU = [UInt8](repeating: 0, count: 4)
    private var apuToHost = [UInt8](repeating: 0, count: 4)
    private var auxiliary = [UInt8](repeating: 0, count: 2)
    private var timers = [Timer(period: 128), Timer(period: 128), Timer(period: 16)]

    /// All timer phases, targets and latches start at zero; timers are disabled.
    /// Supply a real IPL image explicitly when using the boot overlay. A RAM
    /// tail or SPC extraRAM field is never treated as IPL ROM.
    public init(ram: [UInt8] = [UInt8](repeating: 0, count: 65536),
                iplROM: [UInt8]? = nil, iplROMEnabled: Bool = false,
                dsp: any SSMPDSPPort) throws {
        guard ram.count == 65536 else { throw ConfigurationError.ramSize(ram.count) }
        if let iplROM, iplROM.count != 64 { throw ConfigurationError.iplROMSize(iplROM.count) }
        if iplROMEnabled && iplROM == nil { throw ConfigurationError.missingIPLROM }
        self.ram = ram; self.iplROM = iplROM; self.dsp = dsp
        self.iplROMEnabled = iplROMEnabled
        control = iplROMEnabled ? 0x80 : 0
    }

    /// Host port indices are 0...3 (SNES $2140...$2143). Host operations never
    /// advance the SMP clock and never touch the RAM backing $F4...$F7.
    public func hostRead(port: Int) -> UInt8 {
        precondition((0..<4).contains(port), "S-SMP host port must be 0...3")
        return apuToHost[port]
    }

    public func hostWrite(port: Int, value: UInt8) {
        precondition((0..<4).contains(port), "S-SMP host port must be 0...3")
        guard fault == nil else { return }
        hostToAPU[port] = value
    }

    public func read(_ address: UInt16) -> UInt8 {
        guard fault == nil else { return 0 }
        let value: UInt8
        switch address {
        case 0xF0, 0xF1, 0xFA...0xFC: value = 0
        case 0xF2: value = dspAddress
        case 0xF3: value = dsp.readRegister(dspAddress & 0x7F)
        case 0xF4...0xF7: value = hostToAPU[Int(address - 0xF4)]
        case 0xF8...0xF9: value = auxiliary[Int(address - 0xF8)]
        case 0xFD...0xFF:
            let index = Int(address - 0xFD)
            value = timers[index].output
            timers[index].output = 0
        case 0xFFC0...0xFFFF where iplROMEnabled:
            // Initialization and CONTROL writes enforce availability.
            value = iplROM![Int(address - 0xFFC0)]
        default: value = ram[Int(address)]
        }
        advanceClock()
        return value
    }

    public func write(_ address: UInt16, _ value: UInt8) {
        guard fault == nil else { return }
        // TEST also depends on the CPU P flag, which SPC700Bus does not expose.
        // Accept only the normal configuration (a no-op regardless of P) and
        // fail explicitly on all other writes instead of guessing that flag.
        if address == 0xF0 && value != 0x0A {
            fault = .unsupportedTEST(value)
            return
        }
        if address == 0xF1 && value & 0x80 != 0 && iplROM == nil {
            fault = .missingIPLROM
            return
        }

        // Even writes to read-only MMIO update the physical RAM underneath.
        ram[Int(address)] = value
        switch address {
        case 0xF1:
            for index in 0..<3 {
                let enabled = value & (1 << index) != 0
                if enabled && !timers[index].enabled {
                    timers[index].divider = 0
                    timers[index].output = 0
                }
                timers[index].enabled = enabled
            }
            if value & 0x10 != 0 { hostToAPU[0] = 0; hostToAPU[1] = 0 }
            if value & 0x20 != 0 { hostToAPU[2] = 0; hostToAPU[3] = 0 }
            iplROMEnabled = value & 0x80 != 0
            control = value
        case 0xF2: dspAddress = value
        case 0xF3:
            // DSP addresses 0x80...0xFF are read-only aliases.
            if dspAddress & 0x80 == 0 { dsp.writeRegister(dspAddress, value) }
        case 0xF4...0xF7: apuToHost[Int(address - 0xF4)] = value
        case 0xF8...0xF9: auxiliary[Int(address - 0xF8)] = value
        case 0xFA...0xFC: timers[Int(address - 0xFA)].target = value
        default: break
        }
        advanceClock()
    }

    public func idle() {
        guard fault == nil else { return }
        advanceClock()
    }

    private func advanceClock() {
        cycles += 1
        for index in 0..<3 { timers[index].clock() }
        dsp.clock()
    }

    private struct Timer {
        let period: Int
        var phase = 0
        var enabled = false
        var target: UInt8 = 0
        var divider: UInt8 = 0
        var output: UInt8 = 0

        mutating func clock() {
            // The prescaler free-runs even while CONTROL disables the timer.
            phase += 1
            guard phase == period else { return }
            phase = 0
            guard enabled else { return }
            divider &+= 1
            // Equality after 8-bit increment makes target zero mean 256 ticks.
            guard divider == target else { return }
            divider = 0
            output = (output + 1) & 0x0F
        }
    }
}
