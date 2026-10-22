// Key-ons and song steps as the emulated driver plays a song, to check the
// event model's timeline (`CTSongTimeline`, `CTSongTempoMap`) against it.
import Foundation

public enum CTSongDriverTrace {
    /// Spc_StepTracks' `.song` label (driver.asm, $0377 + 34): reached once
    /// per song step, after the tempo carry. Its first byte is `mov x,#$00`.
    static let songStepPC: UInt16 = 0x0399, songStepOpcode: UInt8 = 0xCD
    /// Spc_StepTracks itself: entered once per main-loop pass.
    static let passPC: UInt16 = 0x0377

    public struct KeyOn: Codable, Equatable, Sendable {
        /// The song step whose notes these are (the KON shadow is written at
        /// the top of the next pass, before that pass can step again).
        public let step: Int
        public let voices: UInt8
    }

    public struct Trace: Codable, Sendable {
        public let format = "ct-song-driver-trace/1"
        public let song: Int
        /// The pass (0-based, from the stream's start) each step happened in.
        public let passOfStep: [Int]
        public let keyOns: [KeyOn]
        /// SMP clocks from the first rendered frame to the first song step.
        public let firstStepCycles: Int
    }

    /// Run song `song` (or `data`/`tables` in its place) on the driver until
    /// `steps` song steps have happened, or `maxPasses` main-loop passes
    /// (default 64 a step: a tempo byte below 4 is slower); the trace then
    /// has the steps reached.
    public static func trace(rom: [UInt8], song: Int, replacing data: [UInt8]? = nil,
                             tables: CTSongTables = .init(), steps: Int, maxPasses: Int? = nil) throws -> Trace {
        let plan: CTSPCTransfer.Plan
        if let data {
            let built = try CTROMBuilder.build(base: rom, requests: [],
                                               songs: [.init(song: song, source: "trace", data: data, tables: tables)],
                                               textProfile: nil).rom
            plan = try CTSPCTransfer.Plan(rom: built, song: song)
        } else {
            plan = try CTSPCTransfer.Plan(rom: rom, song: song)
        }
        let (session, load) = try CTSPCTransfer.loadSession(rom: rom, plan: plan, iplROM: nil, limits: .init())
        guard load.passed else { throw CTSongError("song load checks failed") }
        let cpu = session.cpu, bus = session.bus, dsp = session.dsp
        guard bus.ram[Int(songStepPC)] == songStepOpcode else {
            throw CTSongError("the driver at $0399 is not Spc_StepTracks' song step")
        }
        let start = bus.cycles
        var passOfStep: [Int] = [], keyOns: [KeyOn] = []
        var pass = -1, writes = dsp.registerWrites, firstStep = -1
        // Each step's KON is written at the next pass, so run one pass past the last step.
        let passLimit = maxPasses ?? 64 * steps + 512
        while passOfStep.count < steps || pass <= (passOfStep.last ?? 0) {
            if pass >= passLimit { break }
            let pc = cpu.registers.pc
            if pc == passPC { pass += 1 }
            else if pc == songStepPC {
                if firstStep < 0 { firstStep = bus.cycles - start }
                passOfStep.append(pass)
            }
            if cpu.stopped { bus.idle() } else { cpu.step() }
            if let fault = bus.fault { throw CTSongError("trace bus fault: \(fault)") }
            if dsp.registerWrites != writes {
                writes = dsp.registerWrites
                // Writes reach $F3 with the address in $F2 (whose RAM shadow
                // keeps the written value); KON is DSP register $4C.
                if bus.ram[0xF2] & 0x7F == 0x4C, dsp.registers[0x4C] != 0, !passOfStep.isEmpty {
                    keyOns.append(.init(step: passOfStep.count - 1, voices: dsp.registers[0x4C]))
                }
            }
        }
        return Trace(song: song, passOfStep: Array(passOfStep.prefix(steps)),
                     keyOns: keyOns.filter { $0.step < steps }, firstStepCycles: firstStep)
    }

    public struct Comparison: Codable, Sendable {
        public let format = "ct-song-model-check/1"
        public let song: Int
        public let steps: Int
        /// Key-ons the model predicts and the driver made, per voice, over
        /// steps [0, steps - 1).
        public let modelKeyOns: [Int], driverKeyOns: [Int]
        /// Voices whose key-on steps differ, with the first step that differs.
        public let mismatches: [String]
        /// Steps whose pass the tempo map predicts differently, and the most
        /// passes it is off by.
        public let passMismatches: Int, maxPassError: Int
        public var passed: Bool { mismatches.isEmpty && passMismatches == 0 }
    }

    /// Compare the model's key-on steps and pass timing with a driver trace.
    public static func compare(_ doc: CTSongDocument, tables: CTSongTables?, trace: Trace) throws -> Comparison {
        let steps = trace.passOfStep.count
        var options = CTSongTimeline.Options(untilLoop: false, maxSteps: steps)
        options.set = 0
        let timeline = try CTSongTimeline(doc, tables: tables, options: options)
        let window = steps - 1
        var mismatches: [String] = [], modelCounts: [Int] = [], driverCounts: [Int] = []
        for voice in 0..<8 {
            let model = timeline.tracks[voice].notes.filter { $0.keyOn && $0.start < window }.map(\.start)
            let driver = trace.keyOns.filter { $0.voices & (1 << voice) != 0 && $0.step < window }.map(\.step)
            modelCounts.append(model.count); driverCounts.append(driver.count)
            if model != driver {
                let k = (0..<min(model.count, driver.count)).first { model[$0] != driver[$0] } ?? min(model.count, driver.count)
                let at = [model.indices.contains(k) ? model[k] : nil, driver.indices.contains(k) ? driver[k] : nil].compactMap { $0 }.min() ?? 0
                mismatches.append("voice \(voice): model \(model.count), driver \(driver.count) key-ons; first difference at step \(at)")
            }
        }
        let map = CTSongTempoMap(timeline, steps: steps)
        var passMismatches = 0, maxError = 0
        for (a, b) in zip(map.passOfStep, trace.passOfStep) where a != b {
            passMismatches += 1; maxError = max(maxError, abs(a - b))
        }
        return Comparison(song: trace.song, steps: steps, modelKeyOns: modelCounts, driverKeyOns: driverCounts,
                          mismatches: mismatches, passMismatches: passMismatches, maxPassError: maxError)
    }
}
