import Foundation
import Synchronization

/// Single-producer/single-consumer ring of stereo Float32 frames for real-time
/// playback. The producer thread renders into it ahead of time; the audio
/// callback only copies out. Indices are monotonic frame counts published
/// with acquire/release atomics; storage is allocated once, so `read` never
/// allocates, locks or calls into code that can block.
public final class PCMRing: @unchecked Sendable {
    /// Frames; a power of two.
    public let capacity: Int
    private let mask: Int
    private let left: UnsafeMutablePointer<Float>
    private let right: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)
    private let missing = Atomic<Int>(0)
    private let callbacks = Atomic<Int>(0)

    public init(capacity frames: Int) {
        precondition(frames > 0, "ring capacity must be positive")
        var size = 1
        while size < frames { size <<= 1 }
        capacity = size; mask = size - 1
        left = .allocate(capacity: size); left.initialize(repeating: 0, count: size)
        right = .allocate(capacity: size); right.initialize(repeating: 0, count: size)
    }

    deinit {
        left.deallocate()
        right.deallocate()
    }

    /// Frames ready for the consumer.
    public var readable: Int { written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring) }
    /// Free frames for the producer.
    public var writable: Int { capacity - readable }
    /// Frames the consumer asked for but found empty (played as silence).
    public var underrunFrames: Int { missing.load(ordering: .relaxed) }
    /// Frames delivered to the consumer.
    public var framesRead: Int { consumed.load(ordering: .acquiring) }
    /// Consumer calls that hit an underrun.
    public var underrunCallbacks: Int { callbacks.load(ordering: .relaxed) }

    /// Producer side: append interleaved L/R 16-bit frames, scaled by 1/32768.
    /// Returns the frames written (fewer when the ring is full).
    @discardableResult
    public func write(_ samples: UnsafeBufferPointer<Int16>) -> Int {
        let head = written.load(ordering: .relaxed)
        let free = capacity - (head - consumed.load(ordering: .acquiring))
        let frames = min(samples.count / 2, free)
        for i in 0..<frames {
            let slot = (head + i) & mask
            left[slot] = Float(samples[2 * i]) / 32768
            right[slot] = Float(samples[2 * i + 1]) / 32768
        }
        written.store(head + frames, ordering: .releasing)
        return frames
    }

    @discardableResult
    public func write(_ samples: [Int16]) -> Int { samples.withUnsafeBufferPointer { write($0) } }

    /// Consumer side (real-time safe): fill `frames` frames of planar output,
    /// multiplied by `gain`; frames the ring cannot supply are silence and
    /// count as an underrun. Returns the frames taken from the ring.
    @discardableResult
    public func read(frames: Int, left outLeft: UnsafeMutablePointer<Float>, right outRight: UnsafeMutablePointer<Float>,
                     gain: Float = 1) -> Int {
        let tail = consumed.load(ordering: .relaxed)
        let available = written.load(ordering: .acquiring) - tail
        let count = min(frames, available)
        for i in 0..<count {
            let slot = (tail + i) & mask
            outLeft[i] = left[slot] * gain
            outRight[i] = right[slot] * gain
        }
        if count < frames {
            (outLeft + count).update(repeating: 0, count: frames - count)
            (outRight + count).update(repeating: 0, count: frames - count)
            missing.wrappingAdd(frames - count, ordering: .relaxed)
            callbacks.wrappingAdd(1, ordering: .relaxed)
        }
        consumed.store(tail + count, ordering: .releasing)
        return count
    }
}

/// Renders an `SPCStream` into a `PCMRing` ahead of the consumer, on its own
/// thread or on the caller's (`fill`). The stream is touched only by one of
/// them at a time: `fill` is for before `start` and after `stop`.
public final class PCMProducer: @unchecked Sendable {
    public let ring: PCMRing
    /// Frames rendered per step.
    public let chunkFrames: Int
    private let stream: SPCStream
    private let running = Atomic<Bool>(false)
    private let ended = Atomic<Bool>(false)
    private let failure = Mutex<String?>(nil)
    private let exited = DispatchSemaphore(value: 0)
    private var thread: Thread?

    public init(stream: SPCStream, ring: PCMRing, chunkFrames: Int = 512) {
        precondition(chunkFrames > 0 && chunkFrames <= ring.capacity, "chunk must fit the ring")
        self.stream = stream; self.ring = ring; self.chunkFrames = chunkFrames
    }

    /// The source finished (a non-looping sample ended) or rendering failed.
    public var hasEnded: Bool { ended.load(ordering: .acquiring) }
    /// Why rendering stopped early, if it failed.
    public var error: String? { failure.withLock { $0 } }
    /// Frames rendered so far (read it while the thread is stopped).
    public var framesRendered: Int { stream.framesRendered }

    /// Render chunks while a whole chunk fits; returns the frames written.
    @discardableResult
    public func fill() -> Int {
        var total = 0
        while let frames = step() { total += frames }
        return total
    }

    /// Render one chunk if it fits and the source has not ended; returns its
    /// frames, or nil when nothing was rendered.
    private func step() -> Int? {
        guard !hasEnded, ring.writable >= chunkFrames else { return nil }
        do {
            let frames = ring.write(try stream.render(frames: chunkFrames))
            if stream.isFinished { ended.store(true, ordering: .releasing) }
            return frames
        } catch {
            failure.withLock { $0 = String(describing: error) }
            ended.store(true, ordering: .releasing)
            return nil
        }
    }

    /// Keep the ring filled on a background thread until `stop`. The thread
    /// checks for `stop` after every chunk, so it stops promptly even when
    /// rendering cannot keep up and the ring never fills.
    public func start() {
        guard !running.exchange(true, ordering: .acquiringAndReleasing) else { return }
        let thread = Thread { [self] in
            while running.load(ordering: .acquiring) {
                if step() == nil { Thread.sleep(forTimeInterval: 0.002) }
            }
            exited.signal()
        }
        thread.name = "ChronoForge PCM producer"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Stop the thread and wait for it to leave its loop.
    public func stop() {
        guard running.exchange(false, ordering: .acquiringAndReleasing) else { return }
        exited.wait()
        thread = nil
    }

    deinit { stop() }
}
