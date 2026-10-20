import XCTest
@testable import ChronoForgeCore

final class CTSPCDriverTests: XCTestCase {
    private func rom() throws -> [UInt8] {
        guard let data = try? Repo.romData() else { throw XCTSkip("local ROM not present") }
        return [UInt8](data)
    }

    func testBootBlocksMatchROMPayloadBeforeExecution() throws {
        let source = try rom()
        let image = try CTSPCDriver.bootImage(rom: source)
        // Independent table transcription from the matching bank C7 assembly.
        XCTAssertEqual(image.blocks.map(\.sourcePC), [0x724C3, 0x74309, 0x740B4, 0x742B7, 0x742DD, 0x742F3])
        XCTAssertEqual(image.blocks.map(\.destination), [0x200, 0x2F00, 0x4700, 0x1E00, 0x1F80, 0x1F00])
        XCTAssertEqual(image.blocks.map(\.length), [0x1BEF, 0x1800, 0x201, 0x24, 0x14, 0x14])
        for block in image.blocks {
            XCTAssertEqual(Array(image.ram[block.destination..<(block.destination + block.length)]),
                           Array(source[(block.sourcePC + 2)..<(block.sourcePC + 2 + block.length)]))
        }
        XCTAssertEqual(Array(image.ram[0x200..<0x208]), [0x20, 0xC0, 0xCD, 0xFF, 0xBD, 0xE8, 0, 0x5D])
        XCTAssertEqual(image.ram[0x1DEF], 0)
    }

    func testDriverBootAndCommands() throws {
        let report = try CTSPCDriver.check(rom: rom())
        XCTAssertTrue(report.passed, report.checks.filter { !$0.passed }.map(\.name).joined(separator: ", "))
        XCTAssertEqual(report.checks.count, 12)
        XCTAssertGreaterThanOrEqual(report.bootCycles, 81_920)
        XCTAssertLessThan(report.totalCycles, 250_000)
        XCTAssertGreaterThan(report.dspWrites, 16)
    }

    func testBoundedExecutionAndIdentityRefusals() throws {
        let source = try rom()
        XCTAssertThrowsError(try CTSPCDriver.check(rom: source, cycleLimit: 100)) {
            XCTAssertTrue(String(describing: $0).contains("did not complete"))
        }
        XCTAssertThrowsError(try CTSPCDriver.check(rom: source, cycleLimit: 0))
        XCTAssertThrowsError(try CTSPCDriver.check(rom: source, cycleLimit: 2_000_001))
        var changed = source
        changed[0x724C5] ^= 1
        XCTAssertThrowsError(try CTSPCDriver.bootImage(rom: changed))
        XCTAssertThrowsError(try CTSPCDriver.bootImage(rom: Array(source.dropLast())))
    }
}
