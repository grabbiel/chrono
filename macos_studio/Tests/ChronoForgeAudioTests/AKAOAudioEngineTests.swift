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

    @MainActor
    func testOldOwnerCannotCancelAReplacementLoadWithTheSameTitle() async {
        let engine = AKAOAudioEngine()
        let firstOwner = UUID(), secondOwner = UUID()
        let firstStarted = expectation(description: "first load started")
        let secondStarted = expectation(description: "replacement load started")
        let releaseFirst = DispatchSemaphore(value: 0), releaseSecond = DispatchSemaphore(value: 0)
        defer { releaseFirst.signal(); releaseSecond.signal(); engine.stop() }
        let first = Task {
            await engine.play("same title", owner: firstOwner) {
                firstStarted.fulfill()
                _ = releaseFirst.wait(timeout: .now() + 10)
                throw CTSongError("superseded load")
            }
        }
        await fulfillment(of: [firstStarted], timeout: 5)
        let second = Task {
            await engine.play("same title", owner: secondOwner) {
                secondStarted.fulfill()
                _ = releaseSecond.wait(timeout: .now() + 10)
                throw CTSongError("replacement load")
            }
        }
        await fulfillment(of: [secondStarted], timeout: 5)
        engine.stop(ifOwnedBy: firstOwner)
        XCTAssertTrue(engine.isLoading, "closing the old client must leave the new load alone")
        releaseFirst.signal()
        await first.value
        XCTAssertTrue(engine.isLoading, "completion of the old load must leave the new load alone")
        XCTAssertNil(engine.error)
        releaseSecond.signal()
        await second.value
        XCTAssertEqual(engine.error, "replacement load", "the replacement must reach completion")
        XCTAssertFalse(engine.isLoading)
    }

    @MainActor
    func testOwnerCanCancelItsPendingLoad() async {
        let engine = AKAOAudioEngine(), owner = UUID()
        let started = expectation(description: "owned load started")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); engine.stop() }
        let load = Task {
            await engine.play("pending", owner: owner) {
                started.fulfill()
                _ = release.wait(timeout: .now() + 10)
                throw CTSongError("cancelled load must be discarded")
            }
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(engine.isLoading)
        engine.stop(ifOwnedBy: owner)
        XCTAssertFalse(engine.isLoading)
        release.signal()
        await load.value
        XCTAssertNil(engine.error)
        XCTAssertFalse(engine.isPlaying)
    }
}
