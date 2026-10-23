import Foundation
import ChronoForgeCore

let sceneVMUsage = """
       chronoforge scene vm <rom.sfc> <location> [--frames 600] [--input script] [--flag NAME=value ...]
                 [--project p.ctproj] [--trigger obj.func[@frame]] [--party 0,1,2] [--entry x,y[,facing]]
                 [--keep-battles] [--no-scroll] [--model-anim-loops] [--json] [--out file]
                 (the location run in CTEventVM/CTFieldRuntime: per object, each instruction's frames)
       chronoforge scene vm-vectors <rom.sfc> <cases.json> --out <results.json> [--model-anim-loops]
                 (ct_scene_run.py's duration and formation cases on the model)
"""

private func vmNumber(_ s: String) -> Int? {
    if s.hasPrefix("loc_") { return Int(s.dropFirst(4)) }
    if s.hasPrefix("$") { return Int(s.dropFirst(), radix: 16) }
    if s.hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16) }
    return Int(s)
}

func cmdSceneVM(_ args: [String]) -> Int32 {
    let operation = args[0]
    var positional: [String] = [], options: [String: String] = [:], flags: [String] = []
    var json = false, keepBattles = false, noScroll = false, modelLoops = false
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--json": json = true; i += 1
        case "--keep-battles": keepBattles = true; i += 1
        case "--no-scroll": noScroll = true; i += 1
        case "--model-anim-loops": modelLoops = true; i += 1
        case let o where o.hasPrefix("--"):
            guard i + 1 < args.count else { print("missing value for \(o)"); return 2 }
            if o == "--flag" { flags.append(args[i + 1]) } else { options[o] = args[i + 1] }
            i += 2
        default: positional.append(args[i]); i += 1
        }
    }
    guard positional.count == 2 else { print("usage:\n" + sceneVMUsage); return 2 }
    do {
        var rom = [UInt8](try Data(contentsOf: URL(fileURLWithPath: positional[0])))
        if rom.count == 4_194_304 + 512 { rom.removeFirst(512) }
        guard rom.count == 4_194_304 else { throw CTEventError("expected a 4 MiB Chrono Trigger ROM") }
        if operation == "vm-vectors" {
            guard let out = options["--out"] else { print("vm-vectors requires --out"); return 2 }
            let input = try Data(contentsOf: URL(fileURLWithPath: positional[1]))
            try CTSceneRunVectors.run(rom: rom, casesJSON: input, romAnimLoops: !modelLoops).write(to: URL(fileURLWithPath: out), options: .atomic)
            return 0
        }
        guard let location = vmNumber(positional[1]), (0..<CTMapROM.locCount).contains(location) else {
            print("bad location \(positional[1])"); return 2
        }
        var o = CTSceneRun.Options()
        if let f = options["--frames"] {
            guard let n = Int(f), (1...100_000).contains(n) else { print("--frames takes 1-100000"); return 2 }
            o.frames = n
        }
        if let input = options["--input"] {
            let text = FileManager.default.fileExists(atPath: input) ? try String(contentsOfFile: input, encoding: .utf8) : input
            o.input = try CTFieldInput.parse(text)
        }
        let registry = try options["--project"].flatMap { try CTStoryRegistry.load(project: URL(fileURLWithPath: $0)) }
        for f in flags { o.flags.append(try CTSceneRun.flag(f, registry: registry)) }
        if let t = options["--trigger"] {
            let at = t.split(separator: "@"), parts = at[0].split(separator: ".")
            guard parts.count == 2, at.count <= 2, let obj = Int(parts[0]), let fn = Int(parts[1]), [1, 2].contains(fn) else {
                print("--trigger takes OBJECT.FUNCTION[@FRAME] with function 1 or 2"); return 2
            }
            let frame = at.count == 2 ? Int(at[1]) : 0
            guard let frame else { print("bad --trigger frame"); return 2 }
            o.trigger = .init(object: obj, function: fn, frame: frame)
        }
        if let p = options["--party"] {
            let v = p.split(separator: ",").compactMap { vmNumber(String($0)) }
            guard (1...3).contains(v.count), v.count == p.split(separator: ",").count else { print("bad --party"); return 2 }
            o.party = v.map { UInt8($0 & 0xFF) } + Array(repeating: 0x80, count: 3 - v.count)
        }
        if let e = options["--entry"] {
            let v = e.split(separator: ",").compactMap { vmNumber(String($0)) }
            guard (2...3).contains(v.count) else { print("bad --entry"); return 2 }
            o.entry = v
        }
        o.skipBattles = !keepBattles
        o.scrollTo = !noScroll
        o.romAnimLoops = !modelLoops
        let r = try CTSceneRun.run(rom: rom, location: location, options: o)
        let data: Data
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            data = try encoder.encode(r)
        } else {
            data = Data(CTSceneRun.render(r).utf8)
        }
        if let out = options["--out"] {
            try data.write(to: URL(fileURLWithPath: out), options: .atomic)
        } else {
            FileHandle.standardOutput.write(data)
            if data.last != 10 { FileHandle.standardOutput.write(Data([10])) }
        }
        return 0
    } catch {
        print("scene \(operation) failed: \(error)")
        return 1
    }
}
