import Foundation
import ChronoForgeCore

func cmdScene(_ args: [String]) -> Int32 {
    guard args.count >= 2, ["compile", "decompile", "preview", "run"].contains(args[0]) else {
        print("""
        usage: chronoforge scene <compile|decompile|preview> <input.dsl|input.event.json|input.cfscene> [--out file] [--project path] [--entry 0] [--flag symbol] [--steps 1000]
               chronoforge scene run <input> --project path [--entry 0] [--flag symbol] [--steps 1000] [--frames 10000] [--party 1,2,3]
                 (every project scene as an object, with CT call levels; the input replaces the scene of its file name)
        """)
        return 2
    }
    let operation = args[0]
    let input = URL(fileURLWithPath: args[1]).standardizedFileURL
    var output: URL?, projectURL: URL?
    var entry = 0, steps = 1000, frames = 10_000
    var flags: Set<String> = []
    var party: [Int]?
    let previews = ["preview", "run"].contains(operation)
    var i = 2
    while i < args.count {
        let option = args[i]
        guard i + 1 < args.count else { print("missing value for \(option)"); return 2 }
        let value = args[i + 1]
        switch option {
        case "--out": output = URL(fileURLWithPath: value).standardizedFileURL
        case "--project": projectURL = URL(fileURLWithPath: value)
        case "--entry":
            guard previews, let n = Int(value), (0...15).contains(n) else {
                print("--entry requires preview and an integer in 0...15"); return 2
            }
            entry = n
        case "--steps":
            guard previews, let n = Int(value), (1...100_000).contains(n) else {
                print("--steps requires preview and an integer in 1...100000"); return 2
            }
            steps = n
        case "--flag":
            guard previews else { print("--flag requires preview"); return 2 }
            flags.insert(value)
        case "--frames":
            guard operation == "run", let n = Int(value), (1...1_000_000).contains(n) else {
                print("--frames requires run and an integer in 1...1000000"); return 2
            }
            frames = n
        case "--party":
            guard operation == "run" else { print("--party requires run"); return 2 }
            do {
                guard let slots = try EventScheduler.parsePartySlots(value) else {
                    print("--party requires 1-3 comma-separated object slots"); return 2
                }
                party = slots
            } catch { print("invalid --party: \(error)"); return 2 }
        default: print("unknown scene option \(option)"); return 2
        }
        i += 2
    }
    guard operation != "compile" || output != nil else { print("compile requires --out <file.cfscene>"); return 2 }
    guard operation != "run" || projectURL != nil else { print("run requires --project <path.ctproj>"); return 2 }
    if operation == "compile", output?.pathExtension != "cfscene" {
        print("Studio bytecode output must use .cfscene; ROM export is not implemented"); return 2
    }
    if let output, output.resolvingSymlinksInPath() == input.resolvingSymlinksInPath() {
        print("output must differ from input"); return 2
    }
    do {
        let data = try Data(contentsOf: input)
        let scene: EventScene
        switch input.pathExtension {
        case "dsl":
            guard let source = String(data: data, encoding: .utf8) else { throw CTProjectError.badFormat("DSL is not UTF-8") }
            scene = try EventDSL.parse(source)
        case "cfscene": scene = try EventSceneArchive.decode(data)
        case "json": scene = try JSONDecoder().decode(SceneDoc.self, from: data).scene
        default: throw CTProjectError.badFormat("expected .dsl, .event.json or .cfscene input")
        }
        try EventBytecode.validate(scene)
        var dialogue: [String: String] = [:]
        var scenes: [String: EventScene] = [:]
        var sceneID = input.deletingPathExtension().lastPathComponent
        if ["dsl", "json"].contains(input.pathExtension), sceneID.hasSuffix(".event") {
            sceneID.removeLast(".event".count)
        }
        if let projectURL {
            let project = try CTProject.load(from: projectURL)
            let symbols = Set(project.project.flags.map(\.symbol))
            scenes = project.scenes.mapValues(\.scene)
            scenes[sceneID] = scene
            let problems = EventReferences.issues(in: scene, flags: symbols,
                strings: Set(project.dialogue.strings.keys), maps: Set(project.maps.keys), scenes: scenes)
            guard problems.isEmpty else { throw CTProjectError.badFormat(problems.joined(separator: "\n")) }
            guard flags.isSubset(of: symbols) else { throw CTProjectError.badFormat("unknown initial flag") }
            dialogue = project.dialogue.strings
        }
        let result: Data
        switch operation {
        case "compile": result = try EventSceneArchive.encode(scene)
        case "decompile": result = Data(EventDSL.format(scene).utf8)
        case "run":
            let trace = try EventScheduler.run(scenes: scenes, entryScene: sceneID, entry: entry, flags: flags,
                                               dialogue: dialogue, party: party, frameLimit: frames, stepLimit: steps)
            result = try CTProject.jsonEncoder.encode(trace)
        default:
            let trace = try EventPreview.run(scene, entry: entry, flags: flags, dialogue: dialogue, stepLimit: steps)
            result = try CTProject.jsonEncoder.encode(trace)
        }
        if let output {
            try result.write(to: output, options: .atomic)
            print("wrote \(output.path)")
        } else {
            FileHandle.standardOutput.write(result)
            if result.last != 10 { FileHandle.standardOutput.write(Data([10])) }
        }
        return 0
    } catch { print("scene \(operation) failed: \(error)"); return 1 }
}
