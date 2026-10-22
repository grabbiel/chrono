// AKAOAudioEngine.swift — real-time playback of the S-SMP/S-DSP emulation.
import AVFoundation
import Observation
import ChronoForgeCore

/// Plays an `SPCStream` live: a producer thread renders 32 kHz PCM into a
/// `PCMRing` ahead of the audio device, and an `AVAudioSourceNode` copies it
/// out on the render thread (the main mixer converts to the device rate).
/// The stream is built and the ring prefilled off the main thread, so a song
/// load (driver boot and transfer) never blocks the UI. A source that ends (a
/// non-looping sample) stops once the ring drains; underruns play silence and
/// are counted in `status`.
@MainActor
@Observable
public final class AKAOAudioEngine {
    /// The emulation's output: 32 kHz stereo planar Float32.
    nonisolated public static let format = AVAudioFormat(standardFormatWithSampleRate: Double(SPCRender.sampleRate), channels: 2)!
    /// Ring size in frames (256 ms at 32 kHz) and producer step.
    nonisolated public static let ringFrames = 8192, chunkFrames = 512

    public struct Status: Equatable, Sendable {
        /// Seconds delivered to the device since `play`.
        public var seconds = 0.0
        /// Frames rendered but not yet played.
        public var bufferedFrames = 0
        /// Frames the device asked for while the ring was empty, and in how many callbacks.
        public var underrunFrames = 0, underrunCallbacks = 0
    }

    /// What is playing (`play`'s title), or nil.
    public private(set) var nowPlaying: String?
    /// True while a source is being loaded before it plays.
    public private(set) var isLoading = false
    public private(set) var status = Status()
    /// Why the last `play` failed or playback stopped early.
    public private(set) var error: String?
    /// Output volume, 0...1.
    public var volume: Float = 0.8 { didSet { engine.mainMixerNode.outputVolume = volume } }

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var source: AVAudioSourceNode?
    @ObservationIgnored private var producer: PCMProducer?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    /// Bumped by every `play` and `stop`, so a slow load that was superseded
    /// is discarded instead of starting.
    @ObservationIgnored private var generation = 0

    public init() {}

    public var isPlaying: Bool { nowPlaying != nil }

    /// Stop what is playing, build a source with `make` on a background task,
    /// prefill the ring and start the device.
    public func play(_ title: String, _ make: @escaping @Sendable () throws -> SPCStream) async {
        stop()
        generation += 1
        let mine = generation
        isLoading = true
        defer { if generation == mine { isLoading = false } }
        let ring = PCMRing(capacity: Self.ringFrames)
        let loaded = await Task.detached(priority: .userInitiated) { () -> Result<PCMProducer, any Error> in
            Result {
                let producer = PCMProducer(stream: try make(), ring: ring, chunkFrames: Self.chunkFrames)
                producer.fill()
                if let error = producer.error { throw PlaybackError(error) }
                return producer
            }
        }.value
        guard generation == mine else { return }
        switch loaded {
        case .failure(let failure):
            error = String(describing: failure)
        case .success(let producer):
            do {
                let node = AVAudioSourceNode(format: Self.format, renderBlock: Self.renderBlock(ring: ring))
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: Self.format)
                engine.mainMixerNode.outputVolume = volume
                source = node
                self.producer = producer
                try engine.start()
                producer.start()
                nowPlaying = title
                error = nil
                status = Status()
                monitor = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(100))
                        self?.poll()
                    }
                }
            } catch {
                stop()
                self.error = "audio output failed: \(error)"
            }
        }
    }

    /// Stop playback and release the producer.
    public func stop() {
        generation += 1
        monitor?.cancel()
        monitor = nil
        producer?.stop()
        producer = nil
        engine.stop()
        if let source {
            engine.detach(source)
            self.source = nil
        }
        nowPlaying = nil
        isLoading = false
    }

    private func poll() {
        guard let producer else { return }
        let ring = producer.ring
        status = Status(seconds: Double(ring.framesRead) / Double(SPCRender.sampleRate), bufferedFrames: ring.readable,
                        underrunFrames: ring.underrunFrames, underrunCallbacks: ring.underrunCallbacks)
        if producer.hasEnded, ring.readable == 0 {
            let failure = producer.error
            stop()
            if let failure { error = failure }
            return
        }
        // A device or route change stops the engine; pick the new output up.
        if !engine.isRunning { try? engine.start() }
    }

    /// The source node's render callback: copies from `ring` only (no locks,
    /// no allocation), filling what the ring cannot supply with silence.
    /// Built outside the main actor so the audio thread runs no isolation check.
    nonisolated static func renderBlock(ring: PCMRing) -> AVAudioSourceNodeRenderBlock {
        { _, _, frameCount, audioBufferList in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count == 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return kAudio_ParamError }
            ring.read(frames: Int(frameCount), left: left, right: right)
            return noErr
        }
    }
}

struct PlaybackError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
