import Foundation
import ChronoForgeAudio
import ChronoForgeCore

/// Plays `make`'s stream live on the default output for `seconds` (or until it
/// ends) at `volume` and prints what the device was given: the Studio's playback path,
/// checked without the Studio.
@MainActor
func playLive(_ title: String, seconds: Double, volume: Float, _ make: @escaping @Sendable () throws -> SPCStream) -> Int32 {
    let audio = AKAOAudioEngine()
    audio.volume = volume
    Task { await audio.play(title, make) }
    let loadLimit = Date.now.addingTimeInterval(120)
    while audio.nowPlaying == nil, audio.error == nil, Date.now < loadLimit { RunLoop.main.run(until: .now.addingTimeInterval(0.01)) }
    guard audio.isPlaying else {
        print("play failed: \(audio.error ?? "load timed out")")
        return 1
    }
    let start = Date.now, end = start.addingTimeInterval(seconds)
    while audio.isPlaying, Date.now < end { RunLoop.main.run(until: .now.addingTimeInterval(0.05)) }
    let wall = Date.now.timeIntervalSince(start), status = audio.status, ended = !audio.isPlaying
    audio.stop()
    print(String(format: #"{"format": "music-play/1", "title": "%@", "wall_seconds": %.2f, "played_seconds": %.2f, "#
                 + #""buffered_frames": %d, "underrun_frames": %d, "underrun_callbacks": %d, "ended": %@}"#,
                 title, wall, status.seconds, status.bufferedFrames, status.underrunFrames, status.underrunCallbacks,
                 ended ? "true" : "false"))
    return audio.error == nil ? 0 : 1
}
