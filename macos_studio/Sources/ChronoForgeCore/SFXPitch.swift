// SFXPitch.swift — a sample's voice effects (pitch bend, vibrato, noise,
// envelope start and preview key-off) and the per-tick pitch curve they make.
import Foundation

/// Sidecar `fx`: what the SFX Lab plays a sample with beyond its rate and
/// envelope. Ticks are timer-0 ticks of the preview program
/// (`tickDivider` / 8000 s each). Every field is optional.
public struct SampleFX: Codable, Equatable, Sendable {
    /// Timer 0 divider, 1-256 (default 32: 4 ms ticks).
    public var tickDivider: Int?
    /// Pitch at the end of the bend, in semitones from the base pitch, and
    /// how many ticks the bend takes (0: a fixed transpose).
    public var bendSemitones: Double?
    public var bendTicks: Int?
    /// Vibrato depth (cents either side), period and delay, in ticks.
    public var vibratoCents: Double?
    public var vibratoPeriodTicks: Int?
    public var vibratoDelayTicks: Int?
    /// The noise generator replaces the sample (NON), at FLG noise clock 0-31.
    public var noise: Bool?
    public var noiseClock: Int?
    /// GAIN direct level (0-127) at key-on, before the envelope takes over
    /// on the first tick: where GAIN decrease modes start from.
    public var gainStart: Int?
    /// Tick at which previews key the voice off (to hear the release).
    public var keyOffTick: Int?

    public init(tickDivider: Int? = nil, bendSemitones: Double? = nil, bendTicks: Int? = nil,
                vibratoCents: Double? = nil, vibratoPeriodTicks: Int? = nil, vibratoDelayTicks: Int? = nil,
                noise: Bool? = nil, noiseClock: Int? = nil, gainStart: Int? = nil, keyOffTick: Int? = nil) {
        self.tickDivider = tickDivider; self.bendSemitones = bendSemitones; self.bendTicks = bendTicks
        self.vibratoCents = vibratoCents; self.vibratoPeriodTicks = vibratoPeriodTicks
        self.vibratoDelayTicks = vibratoDelayTicks; self.noise = noise; self.noiseClock = noiseClock
        self.gainStart = gainStart; self.keyOffTick = keyOffTick
    }
}

public enum SFXPitch {
    /// Seconds per tick for a timer-0 divider (0 or 256 is 256).
    public static func tickSeconds(divider: Int) -> Double { Double(divider == 0 ? 256 : divider) / 8000 }

    /// Pitch register per tick: the bend moves linearly in semitones over
    /// `bendTicks`, then holds; the vibrato is a sine of `vibratoCents` after
    /// `vibratoDelayTicks`. With a vibrato the curve ends with one whole
    /// period that repeats (`repeatFrom`); without one it ends on the held
    /// pitch. No bend or vibrato: an empty curve (the base pitch).
    public static func curve(base: UInt16, fx: SampleFX) -> (pitches: [UInt16], repeatFrom: Int?) {
        let semis = fx.bendSemitones ?? 0, bendTicks = max(0, fx.bendTicks ?? 0)
        let cents = fx.vibratoCents ?? 0, period = max(0, fx.vibratoPeriodTicks ?? 0)
        let delay = max(0, fx.vibratoDelayTicks ?? 0)
        let vibrato = cents != 0 && period > 0
        guard semis != 0 || vibrato else { return ([], nil) }
        let steady = vibrato ? max(bendTicks, delay) : bendTicks
        let count = vibrato ? steady + period : bendTicks + 1
        let pitches = (0..<count).map { t -> UInt16 in
            let bend = bendTicks == 0 ? semis : semis * min(1, Double(t) / Double(bendTicks))
            let wobble = vibrato && t >= delay ? cents * sin(2 * .pi * Double(t - delay) / Double(period)) : 0
            let p = Double(base) * pow(2, (bend * 100 + wobble) / 1200)
            return UInt16(max(0, min(0x3FFF, p.rounded())))
        }
        return (pitches, vibrato ? steady : nil)
    }

    /// Noise frequency for an FLG noise clock (the envelope rate table: 32 kHz / period).
    public static func noiseHz(clock: Int) -> Double {
        let period = SDSP.ratePeriods[max(0, min(31, clock))]
        return period == 0 ? 0 : Double(SPCRender.sampleRate) / Double(period)
    }
}
