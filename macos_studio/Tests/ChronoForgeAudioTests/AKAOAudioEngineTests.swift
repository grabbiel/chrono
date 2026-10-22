// AKAOAudioEngineTests.swift — the engine's render callback and load errors,
// without starting an audio device.
import XCTest
import AVFoundation
@testable import ChronoForgeAudio
import ChronoForgeCore

final class AKAOAudioEngineTests: XCTestCase {
    func testFormatIsTheEmulationOutput() {
        let format = AKAOAudioEngine.format
        XCTAssertEqual(format.sampleRate, 32000)
        XCTAssertEqual(format.channelCount, 2)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
    }

    func testRenderBlockCopiesTheRingThenSilence() throws {
        let ring = PCMRing(capacity: 64)
        ring.write((0..<40).flatMap { [Int16($0 * 256), Int16(-$0 * 256)] })
        let block = AKAOAudioEngine.renderBlock(ring: ring)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AKAOAudioEngine.format, frameCapacity: 64))
        buffer.frameLength = 64
        var silence: ObjCBool = false
        var time = AudioTimeStamp()
        XCTAssertEqual(block(&silence, &time, 64, buffer.mutableAudioBufferList), noErr)
        let left = try XCTUnwrap(buffer.floatChannelData?[0]), right = try XCTUnwrap(buffer.floatChannelData?[1])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: left, count: 40)), (0..<40).map { Float($0) / 128 })
        XCTAssertEqual(right[39], -39 / 128)
        XCTAssertTrue(UnsafeBufferPointer(start: left + 40, count: 24).allSatisfy { $0 == 0 })
        XCTAssertEqual(ring.underrunFrames, 24)

        let mono = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 32000, channels: 1)),
                                                  frameCapacity: 8))
        XCTAssertNotEqual(block(&silence, &time, 8, mono.mutableAudioBufferList), noErr)
    }

    @MainActor
    func testFailedLoadReportsAndDoesNotPlay() async {
        let engine = AKAOAudioEngine()
        await engine.play("bad") { throw CTSongError("no such song") }
        XCTAssertFalse(engine.isPlaying)
        XCTAssertFalse(engine.isLoading)
        XCTAssertEqual(engine.error, "no such song")
        engine.stop()
        XCTAssertEqual(engine.error, "no such song", "stop keeps the last error")
    }
}
