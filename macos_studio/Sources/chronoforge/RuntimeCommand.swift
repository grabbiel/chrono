import Foundation
import ChronoForgeCore

private let runtimeUsage = """
usage: chronoforge runtime run <rom.sfc> <location> [--frames N] [--input script] [--trace] [--json out.json]
                              [--party 0,1,2] [--entry x,y[,facing]] [--flag addr=value ...]
       chronoforge runtime vectors <rom.sfc> <cases.json> --out <results.json>
"""

private func runtimeROM(_ path: String) throws -> [UInt8] {
    var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    if data.count == 4_194_304 + 512 { data.removeFirst(512) }
    guard data.count == 4_194_304 else { throw CTEventError("expected a 4 MiB Chrono Trigger ROM") }
    return data
}

func cmdRuntime(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["run", "vectors"].contains(operation) else { print(runtimeUsage); return 2 }
    var positional: [String] = [], options: [String: String] = [:], flags: Set<String> = []
    var i = 1
    while i < args.count {
        if args[i] == "--trace" {
            flags.insert(args[i]); i += 1
        } else if args[i].hasPrefix("--") {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            options[args[i]] = args[i + 1]; i += 2
        } else {
            positional.append(args[i]); i += 1
        }
    }
    guard positional.count == 2 else { print(runtimeUsage); return 2 }
    do {
        let rom = try runtimeROM(positional[0])
        switch operation {
        case "vectors":
            guard let out = options["--out"] else { print(runtimeUsage); return 2 }
            let input = try Data(contentsOf: URL(fileURLWithPath: positional[1]))
            let results = try CTEventVMVectors.run(rom: rom, casesJSON: input)
            try results.write(to: URL(fileURLWithPath: out), options: .atomic)
            return 0
        default:
            return try runtimeRun(rom: rom, location: positional[1], options: options, trace: flags.contains("--trace"))
        }
    } catch {
        print("error: \(error)")
        return 1
    }
}

/// A location as a number (decimal, $hex or 0xhex) or loc_NNN.
private func runtimeLocation(_ s: String) -> Int? {
    if s.hasPrefix("loc_") { return Int(s.dropFirst(4)) }
    if s.hasPrefix("$") { return Int(s.dropFirst(), radix: 16) }
    if s.hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16) }
    return Int(s)
}

private func runtimeInts(_ s: String) -> [Int]? {
    let v = s.split(separator: ",").map { runtimeLocation(String($0)) }
    return v.contains(where: { $0 == nil }) ? nil : v.map { $0! }
}

private func runtimeRun(rom: [UInt8], location: String, options: [String: String], trace: Bool) throws -> Int32 {
    guard let loc = runtimeLocation(location) else { print("bad location \(location)"); return 2 }
    let frames = Int(options["--frames"] ?? "120") ?? -1
    guard frames >= 0 else { print("bad --frames"); return 2 }
    var script = CTFieldInput.Script(entries: [])
    if let input = options["--input"] {
        let text = FileManager.default.fileExists(atPath: input) ? try String(contentsOfFile: input, encoding: .utf8) : input
        script = try CTFieldInput.parse(text)
    }
    var party: [UInt8] = [0, 0x80, 0x80]
    if let p = options["--party"] {
        guard let v = runtimeInts(p), (1...3).contains(v.count) else { print("bad --party"); return 2 }
        party = v.map { UInt8($0 & 0xFF) }
    }
    let field = try CTFieldRuntime(rom: rom, location: loc, party: party)
    if let e = options["--entry"] {
        guard let v = runtimeInts(e), (2...3).contains(v.count) else { print("bad --entry"); return 2 }
        field.setEntry(x: v[0], y: v[1], facing: v.count == 3 ? v[2] : 1)
    }
    if let f = options["--flag"] {
        for item in f.split(separator: " ") {
            let kv = item.split(separator: "=")
            guard kv.count == 2, let a = runtimeLocation(String(kv[0])), let v = runtimeLocation(String(kv[1])),
                  WRAMModel.canonical(a) != nil else { print("bad --flag \(item)"); return 2 }
            field.vm.wram[a] = UInt8(v & 0xFF)
        }
    }
    if trace {
        field.vm.trace = { e in
            var line = String(format: "obj %2d $%04X %02X ", e.slot / 2, e.offset, e.opcode)
            switch e.outcome {
            case .go(let x, let c): line += String(format: "-> $%04X%@", x, c ? "" : " (yield)")
            case .halted(let why): line += "halted: \(why)"
            case .unmodelled(let why): line += "unmodelled: \(why)"
            }
            for w in e.storyWrites { line += String(format: "  [$%06X] %02X->%02X", w.address, w.old, w.new) }
            print(line)
        }
    }
    try field.start()
    for f in 0..<frames {
        try field.step(input: script.held(at: f))
    }
    let s = field.summary()
    if let out = options["--json"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(s).write(to: URL(fileURLWithPath: out), options: .atomic)
    }
    print(String(format: "location %d (loc_%03d): %d frames, %d objects, leader level %d", s.location, s.location, s.frames,
                 s.objects.count, s.level))
    for o in s.objects {
        var line = String(format: "  obj %2d kind $%02X level %d at $%04X tile %3d,%3d", o.object, o.kind, o.level, o.scriptPos,
                          o.tileX, o.tileY)
        if o.object == s.leader { line += "  leader" }
        if let why = o.stopped { line += "  STOPPED: \(why)" }
        print(line)
    }
    for m in s.messages {
        print(String(format: "  message %d from obj %d at frame %d (table $%06X)%@", m.index, m.slot / 2, m.frame, m.table,
                     m.error.map { " error: \($0)" } ?? (m.closedAt.map { " closed at \($0)" } ?? " open")))
    }
    for w in s.warps { print("  warp at frame \(w.frame): \(w.from) -> \(w.to) tile \(w.x),\(w.y)") }
    return 0
}
