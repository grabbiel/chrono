import Foundation
import ChronoForgeCore

private let storyUsage = """
usage: chronoforge story flags <rom.sfc> [--location N] [--addr 7F:XXXX] [--json out.json]
       chronoforge story graph <rom.sfc> [--json out.json]
       chronoforge story check <rom.sfc>
       chronoforge story import <rom.sfc> <project.ctproj> [--code-evidence code.json]
       chronoforge story annotate <project.ctproj> <symbol> [--name NAME] [--notes TEXT]
"""

private func storyROM(_ path: String) throws -> [UInt8] {
    var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    if data.count == 4_194_304 + 512 { data.removeFirst(512) }
    guard data.count == 4_194_304 else { throw CTEventError("expected a 4 MiB Chrono Trigger ROM") }
    return data
}

private func writeJSON<T: Encodable>(_ value: T, _ path: String) throws {
    try CTProject.jsonEncoder.encode(value).write(to: URL(fileURLWithPath: path), options: .atomic)
}

func cmdStory(_ args: [String]) -> Int32 {
    guard let operation = args.first, ["flags", "graph", "check", "import", "annotate"].contains(operation) else {
        print(storyUsage); return 2
    }
    var positional: [String] = [], options: [String: String] = [:]
    var i = 1
    while i < args.count {
        if args[i].hasPrefix("--") {
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            options[args[i]] = args[i + 1]; i += 2
        } else {
            positional.append(args[i]); i += 1
        }
    }
    let wanted = ["flags": 1, "graph": 1, "check": 1, "import": 2, "annotate": 2][operation]!
    guard positional.count == wanted else { print(storyUsage); return 2 }
    do {
        switch operation {
        case "flags":
            let rom = try storyROM(positional[0])
            let scan = try CTStory.scan(rom: rom)
            var registry = CTStoryRegistry.build(scan: scan, code: CTStory.longAddressPatterns(rom: rom),
                                                 romSHA256: CTEventPack.sha256(rom))
            if let loc = options["--location"].flatMap({ Int($0) }) {
                registry.entries = registry.entries.filter { $0.locations.contains(loc) }
            }
            if let addr = options["--addr"]?.uppercased() {
                registry.entries = registry.entries.filter { $0.addr == addr }
            }
            if let out = options["--json"] { try writeJSON(registry, out) }
            for e in registry.entries {
                let counts = CTStory.Kind.allCases.map { "\($0.rawValue) \(e.counts[$0.rawValue] ?? 0)" }.joined(separator: "  ")
                print(String(format: "%-18@ %@  %3d locations  %2d code", e.symbol, counts, e.locations.count, e.code.count))
            }
            let bits = registry.entries.filter(\.isBit).count
            print("\(registry.entries.count) entries (\(bits) bits, \(registry.entries.count - bits) bytes); "
                  + "\(registry.unused.count) of \(CTStory.memoryEnd) bytes unused; "
                  + "\(scan.references.count) references in \(scan.instructions) instructions of \(scan.packs) packs")
        case "graph":
            let scan = try CTStory.scan(rom: try storyROM(positional[0]))
            let graph = CTEraGraph.build(warps: scan.warps)
            if let out = options["--json"] { try writeJSON(graph, out) }
            for g in graph.groups {
                print(String(format: "group $%03X  %3d locations  (inferred)", g.seed, g.locations.count))
            }
            let cross = graph.edges.filter(\.crossGroup).count, guarded = graph.edges.filter { !$0.guards.isEmpty }.count
            print("\(graph.edges.count) edges (\(guarded) guarded, \(cross) cross-group) from \(scan.warps.count) location changes; "
                  + "\(graph.groups.reduce(0) { $0 + $1.locations.count }) locations grouped; hubs \(graph.hubs)")
        case "check":
            return try storyCheck(try storyROM(positional[0]))
        case "import":
            let rom = try storyROM(positional[0])
            var project = try CTProject.load(from: URL(fileURLWithPath: positional[1]))
            let code = try options["--code-evidence"].map {
                try CTStoryRegistry.codeEvidence(Data(contentsOf: URL(fileURLWithPath: $0)))
            }
            let (registry, graph) = try CTStory.importStory(rom: rom, project: &project, code: code)
            print("wrote \(CTStoryRegistry.path) (\(registry.entries.count) entries), \(CTEraGraph.path) "
                  + "(\(graph.edges.count) edges, \(graph.groups.count) groups) and "
                  + "\(registry.projectFlags.count) project flags")
        case "annotate":
            var project = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
            guard var registry = try CTStoryRegistry.load(project: project.url) else {
                print("no \(CTStoryRegistry.path): run `chronoforge story import` first"); return 1
            }
            let current = registry.entries.first { $0.symbol == positional[1] }
            try registry.annotate(symbol: positional[1], name: options["--name"] ?? current?.name,
                                  notes: options["--notes"] ?? current?.notes, project: project.project)
            registry.sync(into: &project.project)
            try registry.save(project: project.url)
            try project.save()
            print("annotated \(positional[1])")
        default: break
        }
        return 0
    } catch {
        print("error: \(error)")
        return 1
    }
}

/// Reconciles the scan with an independent count over the decoded packs, and
/// runs a flag-setting ROM path through the scene preview.
private func storyCheck(_ rom: [UInt8]) throws -> Int32 {
    let scan = try CTStory.scan(rom: rom)
    var failures = 0
    func expect(_ ok: Bool, _ message: String) {
        print((ok ? "ok    " : "FAIL  ") + message)
        if !ok { failures += 1 }
    }
    // An independent count: the opcodes whose every instance addresses story memory.
    var instances: [Int: Int] = [:], warps = 0, instructions = 0
    var seen = Set<Int>()
    for e in try CTEventROM.entries(rom: rom) where !CTROMLayout.notEventPackEntries.contains(e.index)
        && seen.insert(e.snesAddress).inserted {
        let bytes = try CTEventROM.unpack(rom: rom, entry: e)
        guard !bytes.isEmpty else { continue }
        let pack = try CTEventPack(bytes: bytes)
        instructions += pack.instructions.count
        for ins in pack.instructions.values {
            instances[Int(ins.opcode), default: 0] += 1
            if [0xDC, 0xDD, 0xDE, 0xDF, 0xE0, 0xE1, 0xE2].contains(ins.opcode) { warps += 1 }
        }
    }
    let byOpcode = Dictionary(grouping: scan.references, by: \.site.opcode).mapValues(\.count)
    let always = [0x65, 0x66, 0x16, 0x18, 0x55, 0x5A]
    let agree = always.filter { byOpcode[$0, default: 0] == instances[$0, default: 0] }.count
    expect(agree == always.count, "\(agree) of \(always.count) always-story opcodes: references = instructions")
    expect(scan.warps.count == warps, "\(scan.warps.count) location changes = \(warps) warp instructions")
    expect(scan.instructions == instructions, "\(scan.instructions) instructions in \(scan.packs) packs")
    let bitSet = Array(rom[CTStory.bitSetPC..<(CTStory.bitSetPC + 8)])
    expect(bitSet == (0..<8).map { UInt8(1 << $0) }, "BitSet at $00:FF20 is 01 02 ... 80")
    let registry = CTStoryRegistry.build(scan: scan, code: CTStory.longAddressPatterns(rom: rom),
                                         romSHA256: CTEventPack.sha256(rom))
    let flags = registry.projectFlags
    let resolve = CTEventLowering.flagResolver(flags)
    let resolved = flags.filter { f in
        guard let r = try? resolve(f.symbol) else { return false }
        return Int(r.m) + (r.page ? 0x100 : 0) == Int(f.addr.suffix(4), radix: 16) && Int(r.bit) == f.bit
    }.count
    expect(resolved == flags.count, "\(resolved) of \(flags.count) registry flags resolve through the scene lowering")
    let path = try CTStory.previewCheck(rom: rom, registry: registry)
    expect(path.passed, "pack entry \(path.entry) offset \(String(format: "$%04X", path.offset)): \(path.statements) statements, "
           + "\(path.flagChanges.count) flag changes; preview \(path.previewFlags) scheduler \(path.schedulerFlags) "
           + "expected \(path.expectedFlags); lowering gives back the ROM bytes: \(path.loweredMatches)")
    print(failures == 0 ? "OK" : "\(failures) check(s) failed")
    return failures == 0 ? 0 : 1
}
