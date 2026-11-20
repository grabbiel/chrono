// CTPPUCaptureTests.swift — the capture loader on synthetic data: the
// register write ports (the shared scroll latch, the mode-7 latch, COLDATA,
// the character bases, OAMADD's priority rotation), the HDMA expansion
// (indirect, repeat, a count of $80, an IRQ that stops a channel, two
// registers written twice), and a synthetic capture read into a PPUFrame.
// The same rules as re_workspace/tests/test_ppu_frames.py.
import XCTest
@testable import ChronoForgeCore

final class CTPPUCaptureTests: XCTestCase {
    func testScrollRegistersShareOneLatch() {
        var p = PPURegisterPorts()
        p.write(port: 0x210F, value: 0x2D)          // BG2HOFS: $2D << 8, 10 bits: $100
        p.write(port: 0x210F, value: 0x01)          // (1 << 8) | ($2D & ~7) | ($100 >> 8 & 7)
        XCTAssertEqual(p.registers.bg[1].hofs, 0x129)
        p.write(port: 0x2110, value: 0x34)
        p.write(port: 0x2110, value: 0x02)
        XCTAssertEqual(p.registers.bg[1].vofs, 0x234)
        p.write(port: 0x2111, value: 0x07)          // BG3HOFS: $700 & $3FF = $300
        p.write(port: 0x2111, value: 0x00)          // the latch's low three bits are not used
        XCTAssertEqual(p.registers.bg[2].hofs, 0x003)
    }

    func testBG1ScrollAlsoWritesTheMode7OffsetsAndTheMatrixLatch() {
        var p = PPURegisterPorts()
        p.write(port: 0x210D, value: 0xF0)
        p.write(port: 0x210D, value: 0x1F)          // M7HOFS = $1FF0: -16 in 13 bits
        XCTAssertEqual(p.registers.m7hofs, -16)
        p.write(port: 0x211B, value: 0x00)
        p.write(port: 0x211B, value: 0xFF)          // M7A = $FF00
        p.write(port: 0x2120, value: 0x10)
        p.write(port: 0x2120, value: 0x00)          // M7Y = $0010
        XCTAssertEqual(p.registers.m7a, -256)
        XCTAssertEqual(p.registers.m7y, 0x10)
    }

    func testCOLDATACharacterBasesAndTheOBJRotation() {
        var p = PPURegisterPorts()
        p.write(port: 0x2132, value: 0x3F)          // red 31
        p.write(port: 0x2132, value: 0x85)          // blue 5
        XCTAssertEqual(p.registers.fixedColor.word, 5 << 10 | 31)
        p.write(port: 0x210B, value: 0x52)
        p.write(port: 0x210C, value: 0x07)
        XCTAssertEqual(p.registers.bg.map { $0.charBase }, [2, 5, 7, 0])
        p.write(port: 0x2102, value: 0x0A)
        p.write(port: 0x2103, value: 0x80)          // rotation from OBJ (OAMADD >> 1) & 127
        XCTAssertEqual(p.registers.objFirst, 5)
        p.write(port: 0x2103, value: 0x00)
        XCTAssertEqual(p.registers.objFirst, 0)
    }

    typealias W = CTPPUCapture.Write

    func entry(_ count: Int, _ data: [[UInt8]]) -> CTPPUCapture.Entry {
        let lines = count & 0x7F == 0 ? 0x80 : count & 0x7F
        return CTPPUCapture.Entry(count: count, lines: lines, repeats: count & 0x80 != 0 && count != 0x80,
                                  address: 0x7E3000, data: data)
    }

    func testHDMAExpansionRepeatCount80AndAnIRQStop() {
        let mode = CTPPUCapture.Channel(channel: 2, dmap: 0x40, bbad: 0x2105, table: 0x7E2000, indirectBank: 0x7E,
                                        entries: [entry(0x03, [[0x41]]), entry(0x82, [[0x51], [0x52]])])
        XCTAssertEqual(CTPPUCapture.expandHDMA([mode]),
                       [W(line: 0, port: 0x2105, value: 0x41), W(line: 3, port: 0x2105, value: 0x51),
                        W(line: 4, port: 0x2105, value: 0x52)])
        let long = CTPPUCapture.Channel(channel: 0, dmap: 0x00, bbad: 0x2105, table: 0x7E2100, indirectBank: 0,
                                        entries: [entry(0x80, [[0x07]]), entry(0x01, [[0x09]])])
        XCTAssertEqual(CTPPUCapture.expandHDMA([long]),
                       [W(line: 0, port: 0x2105, value: 0x07), W(line: 128, port: 0x2105, value: 0x09)])
        XCTAssertEqual(CTPPUCapture.expandHDMA([long], stops: [0: 100]), [W(line: 0, port: 0x2105, value: 0x07)])
    }

    func testTwoRegistersWrittenTwiceAndChannelOrderWithinALine() {
        let matrix = CTPPUCapture.Channel(channel: 1, dmap: 0x43, bbad: 0x211B, table: 0x7E2200, indirectBank: 0x7E,
                                          entries: [entry(0x01, [[1, 2, 3, 4]])])
        let mode = CTPPUCapture.Channel(channel: 0, dmap: 0x40, bbad: 0x2105, table: 0x7E2300, indirectBank: 0x7E,
                                        entries: [entry(0x01, [[7]])])
        let got = CTPPUCapture.expandHDMA([matrix, mode])
        XCTAssertEqual(got.map { $0.port }, [0x2105, 0x211B, 0x211B, 0x211C, 0x211C])
        XCTAssertEqual(got.map { $0.value }, [7, 1, 2, 3, 4])
    }

    // MARK: A synthetic capture

    func registersJSON(_ r: PPURegisters) -> [String: Any] {
        var d: [String: Any] = [
            "inidisp": Int(r.inidisp), "obsel": Int(r.obsel), "objFirst": Int(r.objFirst), "bgmode": Int(r.bgmode),
            "mosaic": Int(r.mosaic), "m7sel": Int(r.m7sel), "m7a": Int(r.m7a), "m7b": Int(r.m7b), "m7c": Int(r.m7c),
            "m7d": Int(r.m7d), "m7x": Int(r.m7x), "m7y": Int(r.m7y), "m7hofs": Int(r.m7hofs), "m7vofs": Int(r.m7vofs),
            "w12sel": Int(r.w12sel), "w34sel": Int(r.w34sel), "wobjsel": Int(r.wobjsel), "wh0": Int(r.wh0),
            "wh1": Int(r.wh1), "wh2": Int(r.wh2), "wh3": Int(r.wh3), "wbglog": Int(r.wbglog),
            "wobjlog": Int(r.wobjlog), "tm": Int(r.tm), "ts": Int(r.ts), "tmw": Int(r.tmw), "tsw": Int(r.tsw),
            "cgwsel": Int(r.cgwsel), "cgadsub": Int(r.cgadsub), "fixedColor": Int(r.fixedColor.word),
            "setini": Int(r.setini),
        ]
        var bgs: [[String: Int]] = []
        for b in r.bg {
            bgs.append(["sc": Int(b.sc), "charBase": Int(b.charBase), "hofs": Int(b.hofs), "vofs": Int(b.vofs)])
        }
        d["bg"] = bgs
        return d
    }

    /// A capture as ct_ppu_frames.py writes one: mode 1 from the start, HDMA
    /// channel 2 switching BGMODE and a COLDATA ramp on channel 3, an IRQ that
    /// forces blank at line 211, a few VRAM words and colours.
    func syntheticCapture() throws -> (Data, [PPURegisters]) {
        var start = PPURegisterPorts()
        start.write(port: 0x2100, value: 0x0F)
        start.write(port: 0x2105, value: 0x01)
        start.write(port: 0x212C, value: 0x11)
        let mode: [String: Any] = [
            "channel": 2, "dmap": 0x40, "bbad": 0x2105, "table": 0x7E2000, "indirectBank": 0x7E,
            "entries": [["count": 0x70, "lines": 0x70, "repeat": false, "address": 0x7E3000, "data": [[0x07]]],
                        ["count": 0x01, "lines": 1, "repeat": false, "address": 0x7E3001, "data": [[0x01]]]]]
        var ramp: [[Int]] = []
        for k in 0..<4 { ramp.append([0x80 | k]) }
        let colour: [String: Any] = [
            "channel": 3, "dmap": 0x40, "bbad": 0x2132, "table": 0x7E2100, "indirectBank": 0x7E,
            "entries": [["count": 0x84, "lines": 4, "repeat": true, "address": 0x7E3100, "data": ramp]]]
        let chans = [CTPPUCapture.Channel(channel: 2, dmap: 0x40, bbad: 0x2105, table: 0x7E2000, indirectBank: 0x7E,
                                          entries: [entry(0x70, [[0x07]]), entry(0x01, [[0x01]])]),
                     CTPPUCapture.Channel(channel: 3, dmap: 0x40, bbad: 0x2132, table: 0x7E2100, indirectBank: 0x7E,
                                          entries: [entry(0x84, ramp.map { $0.map { UInt8($0) } })])]
        let hdma = CTPPUCapture.expandHDMA(chans)
        let irq = [W(line: 211, port: 0x420C, value: 0), W(line: 211, port: 0x2100, value: 0x80)]
        var probe = CTPPUCapture(kind: .battle, runs: [], meta: [:], irqLine: 211, vblank: [], irq: irq,
                                 channels: chans, hdma: hdma, start: start, lines: [],
                                 vram: [], cgram: [], oam: [])
        let lines = probe.replayLines()
        probe.lines = lines
        var vram = [UInt8](repeating: 0, count: PPUFrame.vramWords * 2)
        vram[0x2000 * 2] = 0x34; vram[0x2000 * 2 + 1] = 0x12
        var cgram = [UInt8](repeating: 0, count: 512)
        cgram[2] = 0xFF; cgram[3] = 0x7F
        let file: [String: Any] = [
            "format": CTPPUCapture.format, "version": 1, "frame": "battle", "runs": ["Synthetic"],
            "location": 7, "irqLine": 211,
            "start": ["registers": registersJSON(start.registers), "bgLatch": 0, "m7Latch": 0, "oamadd": 0],
            "vblank": [[0x2100, 0x0F], [0x420C, 0x0C]],
            "irq": irq.map { [$0.line ?? 0, $0.port, Int($0.value)] },
            "hdma": hdma.map { [$0.line ?? 0, $0.port, Int($0.value)] },
            "channels": [mode, colour],
            "lines": lines.map { registersJSON($0) },
            "vram": Data(vram).base64EncodedString(), "cgram": Data(cgram).base64EncodedString(),
            "oam": Data(count: PPUFrame.oamBytes).base64EncodedString(),
        ]
        return (try JSONSerialization.data(withJSONObject: file), lines)
    }

    func testASyntheticCaptureBecomesAFrame() throws {
        let (data, lines) = try syntheticCapture()
        let c = try CTPPUCapture.decode(data)
        XCTAssertEqual(c.kind, .battle)
        XCTAssertEqual(c.meta["location"], 7)
        XCTAssertEqual(c.lines, lines)
        XCTAssertEqual(c.replayLines(), c.lines)
        XCTAssertEqual(CTPPUCapture.expandHDMA(c.channels, stops: c.irqStops), c.hdma)
        XCTAssertEqual(c.irqStops[2], 211)
        let f = c.frame(field: 1)
        XCTAssertEqual(f.height, 224)
        XCTAssertEqual(f.field, 1)
        XCTAssertEqual(f.vram[0x2000], 0x1234)
        XCTAssertEqual(f.cgram[1], 0x7FFF)
        XCTAssertEqual(f.lines[0].mode, 7)
        XCTAssertEqual(f.lines[0x70].mode, 1)
        XCTAssertEqual(f.lines[2].fixedColor.b5, 2)
        XCTAssertEqual(f.lines[200].fixedColor.b5, 3)
        XCTAssertTrue(f.lines[211].forcedBlank)
        XCTAssertFalse(f.lines[210].forcedBlank)
        let text = c.listing().joined(separator: "\n")
        XCTAssertTrue(text.contains("HDMA channel 3: indirect, pattern 0, B-bus COLDATA, table $7E2100"), text)
        XCTAssertTrue(text.contains("lines   0-  3 (repeat) from $7E3100: 80 ..."), text)
        XCTAssertTrue(text.contains("IRQ writes at line 211: HDMAEN = $00, INIDISP = $80"), text)
    }

    func testCapturesOfAnotherFormatAreRefused() throws {
        let (data, _) = try syntheticCapture()
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        obj["version"] = 2
        XCTAssertThrowsError(try CTPPUCapture.decode(try JSONSerialization.data(withJSONObject: obj)))
        obj["version"] = 1
        obj["frame"] = "credits"
        XCTAssertThrowsError(try CTPPUCapture.decode(try JSONSerialization.data(withJSONObject: obj)))
    }

    func assertMalformed(_ change: (inout [String: Any]) -> Void,
                         file: StaticString = #filePath, line: UInt = #line) throws {
        let (data, _) = try syntheticCapture()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        change(&object)
        let changed = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try CTPPUCapture.decode(changed), file: file, line: line)
    }

    func testMalformedWriteRecordsAreRefusedBeforeIndexingOrReplay() throws {
        try assertMalformed { $0["vblank"] = [[0x2100]] }
        try assertMalformed { $0["irq"] = [[211, 0x2100]] }
        try assertMalformed { $0["hdma"] = [[0, 0x2100, 256]] }
        try assertMalformed { $0["hdma"] = [[-1, 0x2100, 0]] }
        try assertMalformed { $0["hdma"] = [[224, 0x2100, 0]] }
        try assertMalformed { $0["hdma"] = [[1, 0x2100, 0], [0, 0x2100, 0]] }
    }

    func testCapturedTablesWritesAndRegistersMustAgree() throws {
        try assertMalformed { $0["hdma"] = [] }
        try assertMalformed { object in
            var lines = object["lines"] as! [[String: Any]]
            lines[0]["bgmode"] = 4
            object["lines"] = lines
        }
    }

    func testMalformedHDMAEntriesAreRefusedBeforeExpansion() throws {
        for values: [[String: Any]] in [
            [["count": 0x80, "lines": 128, "repeat": false, "address": 0, "data": []]],
            [["count": 0x80, "lines": -1, "repeat": false, "address": 0, "data": [[0]]]],
            [["count": 0x82, "lines": 2, "repeat": true, "address": 0, "data": [[0]]]],
            [["count": 1, "lines": 1, "repeat": false, "address": 0, "data": [[0, 0]]]],
        ] {
            try assertMalformed { object in
                object["channels"] = [["channel": 0, "dmap": 0, "bbad": 0x2105,
                                       "table": 0, "indirectBank": 0, "entries": values]]
            }
        }
        try assertMalformed { $0["irqLine"] = -1 }
    }

    func testTheToolIsFoundUpwardFromAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ppu-tool-\(UUID().uuidString)")
        let tools = dir.appendingPathComponent("re_workspace/tools")
        try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data().write(to: tools.appendingPathComponent("ct_ppu_frames.py"))
        let rom = dir.appendingPathComponent("re_workspace/game.sfc")
        XCTAssertEqual(CTPPUCapture.locateTool(from: rom)?.standardizedFileURL.path,
                       tools.appendingPathComponent("ct_ppu_frames.py").standardizedFileURL.path)
    }
}
