import Foundation
import ChronoForgeCore

private let runtimeUsage = """
usage: chronoforge runtime run <rom.sfc> <location> [--frames N] [--input script] [--trace] [--json out.json]
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

private func runtimeRun(rom: [UInt8], location: String, options: [String: String], trace: Bool) throws -> Int32 {
    print("runtime run: not yet"); return 1
}
