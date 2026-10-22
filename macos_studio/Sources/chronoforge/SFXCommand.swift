import Foundation
import ChronoForgeCore

private let sfxUsage = """
usage: chronoforge sfx encode <in.wav> [--out out.brr | --project <p.ctproj> --id <id>] [--rate Hz]
                       [--loop START:END] [--crossfade N] [--normalize dBFS|off] [--beam N] [--verify]
       chronoforge sfx synth <pulse|saw|triangle|sine|noise|fm> [--out out.brr | --project <p.ctproj> --id <id>]
                       [--freq Hz] [--end-freq Hz] [--duration s] [--duty 0-1] [--decay /s] [--amp 0-1]
                       [--fm-ratio R] [--fm-index I] [--fm-decay /s] [--seed N] [--loop] [--verify]
       chronoforge sfx info <file.brr | p.ctproj <id>> [--verify]
       chronoforge sfx render <file.brr | p.ctproj <id>> --out out.wav [--seconds s] [--rate Hz | --pitch $1000]
                       [--adsr A,D,SL,SR | --gain $XX] [--gain-start 0-127] [--key-off TICK] [--loop-block N]
                       [--bend SEMIS,TICKS] [--vibrato CENTS,PERIOD[,DELAY]] [--noise CLOCK] [--tick-div N]
                       [--envelope env.csv]
       chronoforge sfx import-rom <rom.sfc> --project <p.ctproj> [--samples 1,2,...]
       chronoforge sfx use <p.ctproj> <id> [--replace N] [--songs A,B,...] [--root NOTE | --tuning $WORD]
                       [--adsr $WORD] [--remove]
  Loop points are source samples (snapped to 16-sample BRR blocks); ticks are timer-0 ticks of
  tick-div/8000 s (default 32: 4 ms). SNR and errors compare the S-DSP's decode with the source.
  import-rom copies the ROM's samples into the project as rom_NN, each listed in rom.samples to be
  written back as it is. use lists a sample in rom.samples: --replace takes over ROM sample N
  (1-62), else it is appended after them; --songs adds it to those songs' sample lists; the
  tuning word comes from the sidecar's rate and the root note (the driver note that plays it at
  its own pitch: 12 x octave + index with transpose 10) unless --tuning gives it. See
  docs/sfx_lab.md.
"""

/// Options without a value; `synth --loop` is a flag, `encode --loop` takes START:END.
private func parse(_ args: [String], flags: Set<String>) -> (positional: [String], options: [String: String])? {
    var positional: [String] = [], options: [String: String] = [:]
    var i = 0
    while i < args.count {
        let a = args[i]
        if flags.contains(a) { options[a] = ""; i += 1 }
        else if a.hasPrefix("--") {
            guard i + 1 < args.count else { print("missing value for \(a)"); return nil }
            options[a] = args[i + 1]; i += 2
        } else { positional.append(a); i += 1 }
    }
    return (positional, options)
}

private func number(_ s: String) -> Int? {
    s.hasPrefix("$") ? Int(s.dropFirst(), radix: 16) : s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : Int(s)
}

private func numbers(_ s: String) -> [Double]? {
    let parts = s.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
    return parts.contains(nil) ? nil : parts.map { $0! }
}

private struct SFXError: Error, CustomStringConvertible { let description: String; init(_ d: String) { description = d } }

/// Writes encoded blocks to `--out` or into a project as sample `--id`.
private func store(_ report: SFXImport.Report, meta: SampleMeta, options: [String: String]) throws {
    if let project = options["--project"] {
        guard let id = options["--id"], !id.isEmpty else { throw SFXError("--project needs --id") }
        var p = try CTProject.load(from: URL(fileURLWithPath: project))
        var meta = meta
        meta.brr = "audio/samples/\(id).brr"
        let url = p.fileURL(relative: meta.brr)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(SFXImport.fileBytes(report.encoded.blocks)).write(to: url)
        let preview = report.encoded.decoded.map { Int16(clamping: Int($0) * 2) }
        try WAV.writeWav(samples: preview, rate: report.prepared.rate).write(to: url.deletingPathExtension().appendingPathExtension("wav"))
        p.samples[id] = meta
        try p.save()
        print("wrote \(meta.brr) and audio/samples/\(id).json in \(project)")
    } else {
        guard let out = options["--out"] else { throw SFXError("give --out or --project/--id") }
        try Data(SFXImport.fileBytes(report.encoded.blocks)).write(to: URL(fileURLWithPath: out))
        print("wrote \(out) ([u16 length][blocks])")
    }
}

private func describe(_ report: SFXImport.Report) {
    let p = report.prepared
    print("rate \(p.rate) Hz, \(p.pcm.count) samples, \(report.encoded.blocks.count / 9) blocks (\(report.encoded.blocks.count + 2) bytes)"
          + String(format: ", gain %.3f", p.gain))
    print(String(format: "SNR %.2f dB, max error %d (16-bit units), beam %d", report.snrDB, report.maxError, report.options.beam))
    if let loop = p.loop {
        print("loop \(loop.lowerBound)..<\(loop.upperBound) (blocks \(loop.lowerBound / 16)..<\(loop.upperBound / 16)), seam error \(report.loopSeamError ?? 0)")
    } else {
        print("one-shot (ends on a silent block)")
    }
}

private func verify(_ blocks: [UInt8], loopBlock: Int) throws -> Bool {
    let r = try BRRParity.check(blocks: blocks, loopBlock: loopBlock)
    print(r.description)
    return r.passed
}

/// A sample's blocks and sidecar, from a `.brr` file or a project sample.
private func loadSample(_ positional: [String]) throws -> (blocks: [UInt8], meta: SampleMeta, title: String) {
    var isDir: ObjCBool = false
    if positional.count == 2, FileManager.default.fileExists(atPath: positional[0], isDirectory: &isDir), isDir.boolValue {
        let p = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
        guard let meta = p.samples[positional[1]] else { throw SFXError("no sample \(positional[1]) in \(positional[0])") }
        let file = [UInt8](try Data(contentsOf: p.fileURL(relative: meta.brr)))
        return (try blocks(of: file), meta, positional[1])
    }
    guard positional.count == 1 else { throw SFXError(sfxUsage) }
    let file = [UInt8](try Data(contentsOf: URL(fileURLWithPath: positional[0])))
    let b = try blocks(of: file)
    let loops = b[b.count - 9] & 2 != 0
    return (b, SampleMeta(brr: positional[0], rate: SPCRender.sampleRate, loop: loops, loopStartSample: loops ? 0 : nil,
                          loopEndSample: nil, adsr: nil, gain: nil), positional[0])
}

private func blocks(of file: [UInt8]) throws -> [UInt8] {
    if file.count >= 11, Int(file[0]) | Int(file[1]) << 8 == file.count - 2, (file.count - 2) % 9 == 0 { return Array(file[2...]) }
    if !file.isEmpty, file.count % 9 == 0 { return file }
    if file.count > 2, (file.count - 2) % 9 == 0 { return Array(file[2...]) }
    throw SFXError("\(file.count) bytes is not whole 9-byte BRR blocks")
}

func cmdSFX(_ args: [String]) -> Int32 {
    if let operation = args.first, ["import-rom", "use"].contains(operation) { return cmdSFXGame(args) }
    guard let operation = args.first, ["encode", "synth", "info", "render"].contains(operation),
          let (positional, options) = parse(Array(args.dropFirst()), flags: operation == "synth" ? ["--verify", "--loop"] : ["--verify"]) else { print(sfxUsage); return 2 }
    do {
        switch operation {
        case "encode":
            guard positional.count == 1 else { print(sfxUsage); return 2 }
            var o = SFXImport.Options()
            if let r = options["--rate"] { guard let v = Int(r) else { throw SFXError("bad --rate") }; o.rate = v }
            if let l = options["--loop"] {
                let parts = l.split(separator: ":").compactMap { Int($0) }
                guard parts.count == 2 else { throw SFXError("--loop is START:END in source samples") }
                o.loopStart = parts[0]; o.loopEnd = parts[1]
            }
            if let c = options["--crossfade"] { guard let v = Int(c), v >= 0 else { throw SFXError("bad --crossfade") }; o.crossfade = v }
            if let n = options["--normalize"] {
                if n == "off" { o.normalizeDBFS = nil } else { guard let v = Double(n), v <= 0 else { throw SFXError("--normalize is dBFS <= 0 or off") }; o.normalizeDBFS = v }
            }
            if let b = options["--beam"] { guard let v = Int(b), (1...64).contains(v) else { throw SFXError("--beam is 1...64") }; o.beam = v }
            let wav = try WAV.read(url: URL(fileURLWithPath: positional[0]))
            print("source \(positional[0]): \(wav.sampleRate) Hz, \(wav.samples.count) samples")
            let report = try SFXImport.encode(wav: wav, options: o)
            describe(report)
            var meta = report.meta
            meta.source?.wav = positional[0]
            meta.source?.sourceRate = wav.sampleRate
            try store(report, meta: meta, options: options)
            if options["--verify"] != nil, !(try verify(report.encoded.blocks, loopBlock: (report.prepared.loop?.lowerBound ?? 0) / 16)) { return 1 }
        case "synth":
            guard positional.count == 1, let wave = SynthSpec.Wave(rawValue: positional[0]) else { print(sfxUsage); return 2 }
            var spec = SynthSpec(wave: wave)
            func d(_ key: String, _ set: (Double) -> Void) throws {
                if let s = options[key] { guard let v = Double(s) else { throw SFXError("bad \(key)") }; set(v) }
            }
            try d("--freq") { spec.frequency = $0 }
            try d("--end-freq") { spec.endFrequency = $0 }
            try d("--duration") { spec.duration = $0 }
            try d("--duty") { spec.duty = $0 }
            try d("--decay") { spec.decay = $0 }
            try d("--amp") { spec.amplitude = $0 }
            try d("--fm-ratio") { spec.fmRatio = $0 }
            try d("--fm-index") { spec.fmIndex = $0 }
            try d("--fm-decay") { spec.fmDecay = $0 }
            if let s = options["--seed"] { guard let v = Int(s) else { throw SFXError("bad --seed") }; spec.seed = v }
            spec.loop = options["--loop"] != nil
            let report = try SFXSynth.encode(spec)
            describe(report)
            var meta = report.meta
            meta.synth = spec
            meta.source = nil
            try store(report, meta: meta, options: options)
            if options["--verify"] != nil, !(try verify(report.encoded.blocks, loopBlock: 0)) { return 1 }
        case "info":
            let (b, meta, title) = try loadSample(positional)
            let count = b.count / 9
            var filters = [Int](repeating: 0, count: 4), shifts = [Int](repeating: 0, count: 16), loops: [Int] = []
            for k in 0..<count {
                filters[Int(b[9 * k] >> 2 & 3)] += 1; shifts[Int(b[9 * k] >> 4)] += 1
                if b[9 * k] & 2 != 0 { loops.append(k) }
            }
            let decoded = BRR.decodeDSP(b)
            let rate = meta.rate ?? SPCRender.sampleRate
            print("\(title): \(count) blocks, \(count * 16) samples, " + String(format: "%.3f s at %d Hz", Double(count * 16) / Double(rate), rate))
            print("end flag \(b[b.count - 9] & 1 != 0), loop flag on blocks \(loops.isEmpty ? "none" : loops.map(String.init).joined(separator: ","))")
            print("filters " + filters.enumerated().map { "\($0.offset):\($0.element)" }.joined(separator: " "))
            print("shifts " + shifts.enumerated().filter { $0.element > 0 }.map { "\($0.offset):\($0.element)" }.joined(separator: " ")
                  + (shifts[13...].reduce(0, +) > 0 ? " (13-15 act as 12 with the nibble SAR 3)" : ""))
            print("S-DSP peak \(decoded.map { abs(Int($0)) }.max() ?? 0) of 16383 (15-bit)")
            let json = try JSONEncoder.sorted.encode(meta)
            print("sidecar " + String(decoding: json, as: UTF8.self))
            if options["--verify"] != nil, !(try verify(b, loopBlock: meta.loop ? (meta.loopStartSample ?? 0) / 16 : 0)) { return 1 }
        default: // render
            guard let out = options["--out"] else { print(sfxUsage); return 2 }
            var (b, meta, title) = try loadSample(positional)
            if let r = options["--rate"] { guard let v = Int(r), v > 0 else { throw SFXError("bad --rate") }; meta.rate = v }
            if let p = options["--pitch"] { guard let v = number(p), (0...0x3FFF).contains(v) else { throw SFXError("--pitch is 0...$3FFF") }; meta.rate = v * SPCRender.sampleRate / 0x1000 }
            if let a = options["--adsr"] {
                guard let v = numbers(a)?.map(Int.init), v.count == 4 else { throw SFXError("--adsr is A,D,SL,SR") }
                meta.adsr = v
            }
            if let g = options["--gain"] { guard let v = number(g), (0...255).contains(v) else { throw SFXError("--gain is 0...$FF") }; meta.adsr = nil; meta.gain = v }
            if let l = options["--loop-block"] {
                guard let v = Int(l), (0..<b.count / 9).contains(v) else { throw SFXError("--loop-block outside the sample") }
                meta.loop = true; meta.loopStartSample = v * 16; meta.loopEndSample = nil
            }
            var fx = meta.fx ?? SampleFX()
            if let t = options["--tick-div"] { guard let v = Int(t), (1...256).contains(v) else { throw SFXError("--tick-div is 1...256") }; fx.tickDivider = v }
            if let s = options["--gain-start"] { guard let v = Int(s), (0...127).contains(v) else { throw SFXError("--gain-start is 0...127") }; fx.gainStart = v }
            if let k = options["--key-off"] { guard let v = Int(k), v >= 0 else { throw SFXError("bad --key-off") }; fx.keyOffTick = v }
            if let s = options["--bend"] {
                guard let v = numbers(s), v.count == 2 else { throw SFXError("--bend is SEMIS,TICKS") }
                fx.bendSemitones = v[0]; fx.bendTicks = Int(v[1])
            }
            if let s = options["--vibrato"] {
                guard let v = numbers(s), (2...3).contains(v.count) else { throw SFXError("--vibrato is CENTS,PERIOD[,DELAY]") }
                fx.vibratoCents = v[0]; fx.vibratoPeriodTicks = Int(v[1]); fx.vibratoDelayTicks = v.count > 2 ? Int(v[2]) : nil
            }
            if let n = options["--noise"] { guard let v = Int(n), (0...31).contains(v) else { throw SFXError("--noise is a clock 0...31") }; fx.noise = true; fx.noiseClock = v }
            meta.fx = fx == SampleFX() ? nil : fx
            let seconds = Double(options["--seconds"] ?? "2") ?? 2
            let stream = try SPCStream.sample(file: SFXImport.fileBytes(b), meta: meta)
            var pcm: [Int16] = []
            let total = try SPCRender.frames(seconds: seconds)
            while pcm.count / 2 < total && !stream.isFinished { pcm += try stream.render(frames: min(1024, total - pcm.count / 2)) }
            try SPCRender.wav(pcm).write(to: URL(fileURLWithPath: out))
            let peak = pcm.map { abs(Int($0)) }.max() ?? 0
            print("rendered \(title) on the S-DSP: \(pcm.count / 2) frames" + String(format: " (%.3f s)", Double(pcm.count / 2) / Double(SPCRender.sampleRate))
                  + "\(stream.isFinished ? ", ended" : ""), peak \(peak) -> \(out)")
            if let csv = options["--envelope"] {
                let voice = SPCStream.Voice(sample: meta)
                let setting = DSPEnvelope.Setting(sample: meta)
                let curve = try DSPEnvelope.render(setting, keyOffTick: voice.keyOffTick, tickDivider: voice.tickDivider,
                                                   frames: max(1, pcm.count / 2), stride: 32)
                var text = "frame,level\n"
                for (i, level) in curve.levels.enumerated() { text += "\((i + 1) * curve.stride - 1),\(level)\n" }
                try text.write(toFile: csv, atomically: true, encoding: .utf8)
                print("envelope (\(setting.mode.rawValue), \(curve.levels.count) points, read back from S-DSP output) -> \(csv)")
            }
        }
        return 0
    } catch {
        print("sfx \(operation) failed: \(error)")
        return 1
    }
}

private extension JSONEncoder {
    static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }
}

/// `sfx import-rom` and `sfx use`: project samples in the game (rom.samples).
private func cmdSFXGame(_ args: [String]) -> Int32 {
    let operation = args[0]
    guard let (positional, options) = parse(Array(args.dropFirst()), flags: ["--remove"]) else { print(sfxUsage); return 2 }
    func list(_ key: String) throws -> [Int] {
        guard let text = options[key] else { return [] }
        let values = text.split(separator: ",").map { number(String($0)) }
        guard !values.contains(nil) else { throw SFXError("\(key) takes numbers separated by commas") }
        return values.map { $0! }
    }
    do {
        if operation == "import-rom" {
            guard positional.count == 1, let path = options["--project"] else { print(sfxUsage); return 2 }
            let rom = try readROM(positional[0])
            let tables = try CTSampleTables.locate(rom)
            var p = try CTProject.load(from: URL(fileURLWithPath: path))
            let wanted = try list("--samples")
            var spec = p.project.rom ?? .init()
            for n in wanted.isEmpty ? Array(1...tables.count) : wanted {
                let e = try tables.entry(rom, n)
                let id = String(format: "rom_%02d", n)
                let brr = tables.brr(rom, e)
                var meta = SampleMeta(brr: "audio/samples/\(id).brr")
                let looped = brr.count >= 9 && brr[brr.count - 9] & 2 != 0
                meta.loop = looped
                if looped { meta.loopStartSample = e.loopOffset / 9 * 16 }
                let a1 = e.adsr & 0xFF, a2 = e.adsr >> 8
                meta.adsr = [a1 & 0x0F, a1 >> 4 & 7, a2 >> 5, a2 & 0x1F]
                let url = p.fileURL(relative: meta.brr)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(SFXImport.fileBytes(brr)).write(to: url)
                p.samples[id] = meta
                spec.samples.removeAll { $0.id == id || $0.replace == n }
                spec.samples.append(.init(id: id, replace: n, tuning: e.tuning, adsr: e.adsr, asIs: true, loopOffset: e.loopOffset))
            }
            spec.samples.sort { ($0.replace ?? Int.max, $0.id) < ($1.replace ?? Int.max, $1.id) }
            p.project.rom = spec
            try p.save()
            print("imported \(wanted.isEmpty ? tables.count : wanted.count) samples into \(path) (rom.samples, written back as they are)")
            return 0
        }
        // use
        guard positional.count == 2 else { print(sfxUsage); return 2 }
        var p = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
        let id = positional[1]
        guard p.samples[id] != nil else { throw SFXError("no audio/samples/\(id).json") }
        var spec = p.project.rom ?? .init()
        if options["--remove"] != nil {
            spec.samples.removeAll { $0.id == id }
            p.project.rom = spec
            try p.save()
            print("removed \(id) from rom.samples")
            return 0
        }
        var entry = spec.samples.first { $0.id == id } ?? .init(id: id)
        if let r = options["--replace"] {
            guard let n = number(r), (1...CTSampleTables.rom.count).contains(n) else { throw SFXError("--replace takes 1-62") }
            entry.replace = n
        }
        if options["--songs"] != nil { entry.songs = try list("--songs") }
        if let r = options["--root"] { guard let n = number(r) else { throw SFXError("--root takes a note number") }; entry.rootNote = n; entry.tuning = nil }
        if let t = options["--tuning"] { guard let n = number(t), (0...0xFFFF).contains(n) else { throw SFXError("--tuning takes a word") }; entry.tuning = n }
        if let a = options["--adsr"] { guard let n = number(a), (0...0xFFFF).contains(n) else { throw SFXError("--adsr takes a word") }; entry.adsr = n }
        entry.asIs = false
        entry.loopOffset = nil
        // Resolve now, so a bad sample is refused before it is listed.
        let request = try CTROMBuilder.sampleRequest(entry, project: p)
        if let i = spec.samples.firstIndex(where: { $0.id == id }) { spec.samples[i] = entry } else { spec.samples.append(entry) }
        p.project.rom = spec
        try p.save()
        let tune = request.tune.map { String(format: " (root note %d, %d Hz: pitch $%04X, %.1f cents)", $0.rootNote, $0.rate, $0.pitch, $0.cents) } ?? ""
        print(String(format: "rom.samples: %@ %@, %d BRR bytes, tuning $%04X%@, ADSR $%04X, songs %@", id,
                     entry.replace.map { "replaces sample \($0)" } ?? "is appended", request.brr.count, request.tuning, tune,
                     request.adsr, entry.songs.isEmpty ? "none" : entry.songs.map { String(format: "$%02X", $0) }.joined(separator: ", ")))
        return 0
    } catch {
        print("sfx \(operation) failed: \(error)")
        return 1
    }
}
