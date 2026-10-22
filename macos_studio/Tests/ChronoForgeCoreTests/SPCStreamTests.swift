// SPCStreamTests.swift — chunked rendering, sample previews, the playback
// ring and its producer. ROM-free except the CT song streams, which skip
// without the ROM.
import XCTest
@testable import ChronoForgeCore

final class SPCStreamTests: XCTestCase {
    /// Parked CPU (BRA $) at $0200, voice 0 keyed on from a looping BRR
    /// sample at $0400 (directory $0300), GAIN direct, no echo.
    private func parkedSnapshot() throws -> SPCFile {
        var ram = [UInt8](repeating: 0, count: 0x10000)
        ram[0x0200] = 0x2F; ram[0x0201] = 0xFE
        ram.replaceSubrange(0x0300..<0x0304, with: [0x00, 0x04, 0x00, 0x04])
        ram.replaceSubrange(0x0400..<0x0409, with: [0x93, 0x17, 0x7F, 0x80, 0xF1, 0x2C, 0xD3, 0x00, 0x7A])
        var dsp = [UInt8](repeating: 0, count: 128)
        dsp[0x00] = 0x40; dsp[0x01] = 0x40; dsp[0x03] = 0x10; dsp[0x07] = 0x60
        dsp[0x0C] = 0x60; dsp[0x1C] = 0x60; dsp[0x5D] = 0x03; dsp[0x6C] = 0x20; dsp[0x4C] = 0x01
        return try SPCFile(registers: SPC700.Registers(pc: 0x0200, sp: 0xEF), ram: ram, dsp: dsp)
    }

    private func render(_ stream: SPCStream, chunks: [Int]) throws -> [Int16] {
        try chunks.flatMap { try stream.render(frames: $0) }
    }

    private func hit() throws -> (file: [UInt8], meta: SampleMeta) {
        let file = [UInt8](try resourceData("MyGame.ctproj/audio/samples/hit.brr"))
        let meta = try JSONDecoder().decode(SampleMeta.self, from: try resourceData("MyGame.ctproj/audio/samples/hit.json"))
        return (file, meta)
    }

    func testChunkedStreamIsTheOneShotRender() throws {
        let snapshot = try parkedSnapshot()
        let pcm = try SPCRender.render(snapshot: snapshot, seconds: 0.05)
        XCTAssertEqual(try render(try SPCStream.snapshot(snapshot), chunks: [1, 31, 500, 1068]), pcm)
        let stream = try SPCStream.snapshot(snapshot)
        XCTAssertEqual(try render(stream, chunks: Array(repeating: 100, count: 16)), pcm)
        XCTAssertEqual(stream.framesRendered, 1600)
        XCTAssertFalse(stream.isFinished)
    }

    func testSampleFollowsTheSidecarLoop() throws {
        var (file, meta) = try hit()
        // The data's end block (header $85) has no loop flag; the sidecar loops it.
        XCTAssertEqual(file[file.count - 9], 0x85)
        let looping = try SPCStream.sample(file: file, meta: meta)
        let held = try render(looping, chunks: Array(repeating: 1024, count: 8))
        XCTAssertFalse(looping.isFinished)
        XCTAssertTrue(held.suffix(2048).contains { $0 != 0 }, "a looping sample still sounds")

        meta.loop = false
        let once = try SPCStream.sample(file: file, meta: meta)
        var pcm: [Int16] = []
        while !once.isFinished, pcm.count < 2 * 8192 { pcm += try once.render(frames: 128) }
        XCTAssertTrue(once.isFinished)
        // 40 blocks of 16 samples at pitch $1000, plus the decoder's lead-in.
        XCTAssertLessThanOrEqual(pcm.count / 2, 1024)
        XCTAssertTrue(pcm.contains { $0 != 0 })
        XCTAssertTrue(try once.render(frames: 256).allSatisfy { $0 == 0 })
    }

    func testSampleLoopRangeAndFileLayouts() throws {
        let (file, meta) = try hit()
        let blocks = Array(file[2...])
        XCTAssertEqual(Array(try SPCStream.brrBlocks(file)), blocks)
        XCTAssertEqual(Array(try SPCStream.brrBlocks(blocks)), blocks)
        XCTAssertEqual(Array(try SPCStream.brrBlocks([0x00, 0x05] + blocks)), blocks)   // loop-offset header
        XCTAssertThrowsError(try SPCStream.brrBlocks([1, 2, 3]))
        XCTAssertThrowsError(try SPCStream.brrBlocks([]))

        // A bare file plays like the prefixed one.
        XCTAssertEqual(try render(try SPCStream.sample(file: blocks, meta: meta), chunks: [800]),
                       try render(try SPCStream.sample(file: file, meta: meta), chunks: [800]))
        var bad = meta
        bad.loopStartSample = 480   // the loop end is sample 480
        XCTAssertThrowsError(try SPCStream.sample(file: file, meta: bad))
        bad.loopStartSample = 464
        XCTAssertNoThrow(try SPCStream.sample(file: file, meta: bad))
        XCTAssertThrowsError(try SPCStream.sample(brr: [0x01], voice: .init()))
        XCTAssertThrowsError(try SPCStream.sample(brr: Array(blocks[..<18]), loopBlock: 2))
    }

    func testVoiceFromSidecar() {
        func meta(rate: Int? = nil, adsr: [Int]? = nil, gain: Int? = nil) -> SampleMeta {
            SampleMeta(brr: "x.brr", rate: rate, loop: false, loopStartSample: nil, loopEndSample: nil, adsr: adsr, gain: gain)
        }
        XCTAssertEqual(SPCStream.Voice(sample: meta()), SPCStream.Voice())
        XCTAssertEqual(SPCStream.Voice(sample: meta(rate: 32000)).pitch, 0x1000)
        XCTAssertEqual(SPCStream.Voice(sample: meta(rate: 16000)).pitch, 0x0800)
        XCTAssertEqual(SPCStream.Voice(sample: meta(rate: 200_000)).pitch, 0x3FFF)
        let fields = SPCStream.Voice(sample: meta(adsr: [15, 7, 7, 31])).adsr
        XCTAssertEqual(fields?.0, 0xFF); XCTAssertEqual(fields?.1, 0xFF)
        let packed = SPCStream.Voice(sample: meta(adsr: [10, 2, 5, 3])).adsr
        XCTAssertEqual(packed?.0, 0xAA); XCTAssertEqual(packed?.1, 0xA3)
        let raw = SPCStream.Voice(sample: meta(adsr: [0x8F, 0xE0])).adsr
        XCTAssertEqual(raw?.0, 0x8F); XCTAssertEqual(raw?.1, 0xE0)
        XCTAssertNil(SPCStream.Voice(sample: meta(adsr: [0x0F, 0xE0])).adsr, "ADSR1 bit 7 clear is not ADSR")
        XCTAssertNil(SPCStream.Voice(sample: meta(adsr: [10, 30, 150, 180])).adsr, "not register fields")
        XCTAssertEqual(SPCStream.Voice(sample: meta(gain: 200)).gain, 200)
        XCTAssertEqual(SPCStream.Voice(sample: meta(gain: 300)).gain, 0x7F)
    }

    func testRingWrapsScalesAndCountsUnderruns() {
        let ring = PCMRing(capacity: 5)
        XCTAssertEqual(ring.capacity, 8)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 16), right = UnsafeMutablePointer<Float>.allocate(capacity: 16)
        defer { left.deallocate(); right.deallocate() }

        XCTAssertEqual(ring.write((0..<6).flatMap { [Int16($0 * 1024), Int16(-$0 * 1024)] }), 6)
        XCTAssertEqual(ring.read(frames: 4, left: left, right: right), 4)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: left, count: 4)), [0, 1, 2, 3].map { Float($0) / 32 })
        XCTAssertEqual(Array(UnsafeBufferPointer(start: right, count: 4)), [0, -1, -2, -3].map { Float($0) / 32 })
        XCTAssertEqual(ring.writable, 6)
        // Wraps past the end; only the free frames are taken.
        XCTAssertEqual(ring.write((6..<14).flatMap { [Int16($0 * 1024), Int16.min] }), 6)
        XCTAssertEqual(ring.writable, 0)
        XCTAssertEqual(ring.write([1, 1]), 0)

        XCTAssertEqual(ring.read(frames: 10, left: left, right: right, gain: 0.5), 8)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: left, count: 10)), [4, 5, 6, 7, 8, 9, 10, 11].map { Float($0) / 64 } + [0, 0])
        XCTAssertEqual(right[2], -0.5)
        XCTAssertEqual(right[9], 0)
        XCTAssertEqual(ring.underrunFrames, 2)
        XCTAssertEqual(ring.underrunCallbacks, 1)
        XCTAssertEqual(ring.framesRead, 12)
        XCTAssertEqual(ring.read(frames: 3, left: left, right: right), 0)
        XCTAssertEqual(ring.underrunFrames, 5)
        XCTAssertEqual(ring.underrunCallbacks, 2)
    }

    func testProducerFillsUntilTheSampleEnds() throws {
        var (file, meta) = try hit()
        meta.loop = false
        let ring = PCMRing(capacity: 512)
        let producer = PCMProducer(stream: try SPCStream.sample(file: file, meta: meta), ring: ring, chunkFrames: 128)
        let left = UnsafeMutablePointer<Float>.allocate(capacity: 512), right = UnsafeMutablePointer<Float>.allocate(capacity: 512)
        defer { left.deallocate(); right.deallocate() }
        XCTAssertEqual(producer.fill(), 512)
        XCTAssertEqual(producer.fill(), 0, "a full ring takes no chunk")
        var played = 0
        while !producer.hasEnded, played < 8192 {
            played += ring.read(frames: 256, left: left, right: right)
            producer.fill()
        }
        XCTAssertTrue(producer.hasEnded)
        XCTAssertNil(producer.error)
        XCTAssertEqual(ring.underrunFrames, 0)
        let rendered = producer.framesRendered
        producer.fill()
        XCTAssertEqual(producer.framesRendered, rendered, "an ended source renders nothing more")
    }

    func testProducerThreadKeepsTheRingFull() throws {
        let ring = PCMRing(capacity: 1024)
        let producer = PCMProducer(stream: try SPCStream.snapshot(try parkedSnapshot()), ring: ring, chunkFrames: 256)
        producer.start()
        producer.start()   // already running: no second thread
        let deadline = Date.now.addingTimeInterval(10)
        while ring.writable >= 256, Date.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
        producer.stop()
        producer.stop()
        XCTAssertLessThan(ring.writable, 256)
        let rendered = producer.framesRendered
        XCTAssertEqual(rendered, ring.readable)
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(producer.framesRendered, rendered, "a stopped producer renders nothing")
    }

    func testProducerStopsWhenRenderingCannotKeepUp() throws {
        let ring = PCMRing(capacity: 1024)
        let producer = PCMProducer(stream: try SPCStream.snapshot(try parkedSnapshot()), ring: ring, chunkFrames: 256)
        let drained = DispatchSemaphore(value: 0)
        // Drains far faster than rendering, so the ring never fills.
        let consumer = Thread {
            let left = UnsafeMutablePointer<Float>.allocate(capacity: 1024), right = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
            defer { left.deallocate(); right.deallocate() }
            while !Thread.current.isCancelled { ring.read(frames: 1024, left: left, right: right) }
            drained.signal()
        }
        consumer.start()
        producer.start()
        let deadline = Date.now.addingTimeInterval(10)
        while ring.framesRead < 2048, Date.now < deadline { Thread.sleep(forTimeInterval: 0.001) }
        let stopped = expectation(description: "stop returns while the consumer keeps draining")
        DispatchQueue.global().async { producer.stop(); stopped.fulfill() }
        wait(for: [stopped], timeout: 10)
        consumer.cancel()
        drained.wait()
        XCTAssertGreaterThanOrEqual(ring.framesRead, 2048)
        XCTAssertGreaterThan(ring.underrunFrames, 0)
    }

    func testCTSongStreamIsTheRender() throws {
        let rom = [UInt8](try Repo.romData())
        let expected = try CTSPCRender.render(rom: rom, song: 0x18, seconds: 0.25).pcm
        XCTAssertEqual(try render(try SPCStream.ctSong(rom: rom, song: 0x18), chunks: [100, 2900, 5000]), expected)
        // The song's own bytes built back into its slot play the same.
        let data = try CTSong.romSongs(rom)[0x18].data
        XCTAssertEqual(try render(try SPCStream.ctSong(rom: rom, replacing: 0x18, data: data), chunks: [8000]), expected)
        XCTAssertThrowsError(try SPCStream.ctSong(rom: Array(rom.dropLast()), song: 0x18))
    }
}
