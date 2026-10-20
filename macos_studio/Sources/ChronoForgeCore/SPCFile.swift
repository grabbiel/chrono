import Foundation

/// SPC v0.30 interchange snapshot. Tag bytes (including binary ID666 and xid6)
/// are preserved without interpretation. This is not a cycle-exact save state:
/// the format does not carry internal timer phases or DSP voice history.
/// Layout: https://snesmusic.org/files/spc_file_format.txt
public struct SPCFile: Sendable {
    public static let size = 0x10200
    public static let signature = Array("SNES-SPC700 Sound File Data v0.30".utf8)
    public var registers: SPC700.Registers
    public var ram: [UInt8]
    public var dsp: [UInt8]
    /// RAM underneath the IPL overlay, not the IPL ROM itself.
    public var extraRAM: [UInt8]
    public var trailer: [UInt8]
    private var header: [UInt8]
    private var reserved: [UInt8]

    public init(registers: SPC700.Registers, ram: [UInt8], dsp: [UInt8], extraRAM: [UInt8]? = nil) throws {
        self.registers = registers; self.ram = ram; self.dsp = dsp
        self.extraRAM = extraRAM ?? Array(ram.suffix(64))
        trailer = []; header = [UInt8](repeating: 0, count: 256)
        reserved = [UInt8](repeating: 0, count: 64)
        header.replaceSubrange(0..<33, with: Self.signature)
        header[0x21] = 0x1A; header[0x22] = 0x1A
        header[0x23] = 0x1B // no ID666 tag
        header[0x24] = 30
        try validateSizes()
    }

    /// Requires the complete standard snapshot, including the extra RAM tail.
    /// Shortened 0x10180-byte dumps accepted by some players are not accepted.
    public init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.size else { throw FormatError("truncated SPC: need at least \(Self.size) bytes") }
        guard Array(bytes[0..<33]) == Self.signature, bytes[0x21] == 0x1A, bytes[0x22] == 0x1A,
              [0x1A, 0x1B].contains(bytes[0x23]), bytes[0x24] == 30 else {
            throw FormatError("unsupported SPC header (expected v0.30)")
        }
        header = Array(bytes[0..<256])
        registers = SPC700.Registers(pc: UInt16(bytes[0x25]) | UInt16(bytes[0x26]) << 8,
                                    a: bytes[0x27], x: bytes[0x28], y: bytes[0x29],
                                    sp: bytes[0x2B], psw: bytes[0x2A])
        ram = Array(bytes[0x100..<0x10100])
        dsp = Array(bytes[0x10100..<0x10180])
        reserved = Array(bytes[0x10180..<0x101C0])
        extraRAM = Array(bytes[0x101C0..<Self.size])
        trailer = Array(bytes[Self.size...])
    }

    public func encode() throws -> Data {
        try validateSizes()
        var bytes = header
        bytes[0x25] = UInt8(truncatingIfNeeded: registers.pc)
        bytes[0x26] = UInt8(registers.pc >> 8)
        bytes[0x27] = registers.a; bytes[0x28] = registers.x; bytes[0x29] = registers.y
        bytes[0x2A] = registers.psw; bytes[0x2B] = registers.sp
        bytes.append(contentsOf: ram); bytes.append(contentsOf: dsp)
        bytes.append(contentsOf: reserved); bytes.append(contentsOf: extraRAM)
        bytes.append(contentsOf: trailer)
        return Data(bytes)
    }

    private func validateSizes() throws {
        guard ram.count == 65536, dsp.count == 128, extraRAM.count == 64 else {
            throw FormatError("SPC requires 65536 RAM bytes, 128 DSP bytes and 64 extra RAM bytes")
        }
    }
    public struct FormatError: Error, CustomStringConvertible {
        public let description: String
        init(_ message: String) { description = message }
    }
}
