import Foundation
import XCTest
@testable import ChronoForgeCore

final class SPCFileTests: XCTestCase {
    // Constructed independently at the published offsets, with nonzero tag and
    // reserved bytes so a serializer cannot pass by silently discarding them.
    private func fixture() -> Data {
        var bytes = (0..<0x10200).map { UInt8(truncatingIfNeeded: $0 * 17 + 3) }
        bytes.replaceSubrange(0..<33, with: Array("SNES-SPC700 Sound File Data v0.30".utf8))
        bytes[0x21] = 26; bytes[0x22] = 26; bytes[0x23] = 26; bytes[0x24] = 30
        bytes.replaceSubrange(0x25..<0x2C, with: [0x34, 0x12, 1, 2, 3, 0xA5, 0xFE])
        bytes.append(contentsOf: Array("xid6".utf8) + [0, 0, 0, 0])
        return Data(bytes)
    }

    func testDecodeAndLosslessRoundTrip() throws {
        let data = fixture(), file = try SPCFile(data: data)
        XCTAssertEqual(file.registers, .init(pc: 0x1234, a: 1, x: 2, y: 3, sp: 0xFE, psw: 0xA5))
        XCTAssertEqual(file.ram, Array(data[0x100..<0x10100]))
        XCTAssertEqual(file.dsp, Array(data[0x10100..<0x10180]))
        XCTAssertEqual(file.extraRAM, Array(data[0x101C0..<0x10200]))
        XCTAssertTrue(try file.encode() == data)
        var edited = file
        edited.registers.pc = 0xABCD
        edited.ram[0x1234] = 0x77; edited.dsp[0x4C] = 0x80
        edited.extraRAM[0] = 0x55
        var expected = data
        expected[0x25] = 0xCD; expected[0x26] = 0xAB
        expected[0x1334] = 0x77; expected[0x1014C] = 0x80; expected[0x101C0] = 0x55
        XCTAssertTrue(try edited.encode() == expected)
    }

    func testFreshSnapshotAndValidation() throws {
        let ram = [UInt8](repeating: 0xCC, count: 65536)
        let dsp = [UInt8](repeating: 0, count: 128)
        let file = try SPCFile(registers: .init(pc: 0x200), ram: ram, dsp: dsp)
        let encoded = try file.encode()
        XCTAssertEqual(encoded.count, 0x10200)
        XCTAssertEqual(encoded[0x23], 0x1B)
        XCTAssertEqual(file.extraRAM, [UInt8](repeating: 0xCC, count: 64))
        XCTAssertEqual(try SPCFile(data: encoded).registers.pc, 0x200)
        XCTAssertThrowsError(try SPCFile(registers: .init(), ram: [], dsp: dsp))
        XCTAssertThrowsError(try SPCFile(registers: .init(), ram: ram, dsp: []))
        XCTAssertThrowsError(try SPCFile(registers: .init(), ram: ram, dsp: dsp, extraRAM: []))
        var invalid = file; invalid.ram.removeLast()
        XCTAssertThrowsError(try invalid.encode())
        for length in [0, 32, 256, 0x10180, 0x101FF] {
            XCTAssertThrowsError(try SPCFile(data: encoded.prefix(length)))
        }
        for offset in [0, 32, 0x21, 0x22, 0x23, 0x24] {
            var bad = encoded; bad[offset] = 0
            XCTAssertThrowsError(try SPCFile(data: bad), "offset \(offset)")
        }
    }
}
