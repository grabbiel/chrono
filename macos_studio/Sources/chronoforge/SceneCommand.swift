import Foundation
import ChronoForgeCore

private let sceneROMUsage = """
       chronoforge scene raise <rom.sfc> <location> [--pack entry] [--json] [--out file]
                 (a location's event pack as a scene: objects, functions, calls, map objects)
       chronoforge scene graph <rom.sfc> <location> [--pack entry] [--json] [--out file]
       chronoforge scene timeline <rom.sfc> <location> [--pack entry] [--trigger obj.func] [--level 1]
                 [--frames 600] [--steps 5000] [--party a,b,c] [--json] [--out file]
       chronoforge scene verify-rom <rom.sfc> --manifest event_pack_verification.json
                 (every pack raised, through ct-scene/1 JSON, lowered back byte-exact)
"""

func cmdScene(_ args: [String]) -> Int32 {
    if let op = args.first, ["raise", "graph", "timeline", "verify-rom"].contains(op) { return cmdSceneROM(args) }
    guard args.count >= 2, ["compile", "decompile", "preview", "run"].contains(args[0]) else {
        print("""
        usage: chronoforge scene <compile|decompile|preview> <input.dsl|input.event.json|input.cfscene> [--out file] [--project path] [--entry 0] [--flag symbol] [--steps 1000]
               chronoforge scene run <input> --project path [--entry 0] [--flag symbol] [--steps 1000] [--frames 10000] [--party 1,2,3]
                 (every project scene as an object, with CT call levels; the input replaces the scene of its file name)
        """ + "\n" + sceneROMUsage)
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

// MARK: - Scenes raised from the ROM's event packs (docs/scene_director.md)

private func sceneROM(_ path: String) throws -> [UInt8] {
    var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    if data.count == 4_194_304 + 512 { data.removeFirst(512) }
    guard data.count == 4_194_304 else { throw CTEventError("expected a 4 MiB Chrono Trigger ROM") }
    return data
}

func cmdSceneROM(_ args: [String]) -> Int32 {
    let operation = args[0]
    var positional: [String] = [], json = false, output: String?, manifest: String?
    var pack: Int?, trigger: CTSceneTimeline.Trigger?, level = 1, frames = 600, steps = 5000
    var party: [Int]?
    var i = 1
    while i < args.count {
        let option = args[i]
        if option == "--json" { json = true; i += 1; continue }
        guard option.hasPrefix("--") else { positional.append(option); i += 1; continue }
        guard i + 1 < args.count else { print("missing value for \(option)"); return 2 }
        let value = args[i + 1]
        switch option {
        case "--out": output = value
        case "--manifest": manifest = value
        case "--pack":
            guard let n = Int(value), (0..<CTEventROM.pointerCount).contains(n) else {
                print("--pack takes an Evt_PackPtrs entry 0-\(CTEventROM.pointerCount - 1)"); return 2
            }
            pack = n
        case "--trigger":
            let parts = value.split(separator: ".")
            guard operation == "timeline", parts.count == 2, let o = Int(parts[0]), let f = Int(parts[1]), (0...15).contains(f) else {
                print("--trigger takes OBJECT.FUNCTION with timeline"); return 2
            }
            trigger = CTSceneTimeline.Trigger(object: o, function: f)
        case "--level":
            guard operation == "timeline", let n = Int(value), (0...6).contains(n) else { print("--level takes 0-6 with timeline"); return 2 }
            level = n
        case "--frames":
            guard operation == "timeline", let n = Int(value), (1...1_000_000).contains(n) else {
                print("--frames takes 1-1000000 with timeline"); return 2
            }
            frames = n
        case "--steps":
            guard operation == "timeline", let n = Int(value), (1...100_000).contains(n) else {
                print("--steps takes 1-100000 with timeline"); return 2
            }
            steps = n
        case "--party":
            let slots = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard operation == "timeline", (1...3).contains(slots.count), slots.count == value.split(separator: ",").count else {
                print("--party takes 1-3 comma-separated object numbers with timeline"); return 2
            }
            party = slots
        default: print("unknown scene option \(option)"); return 2
        }
        i += 2
    }
    trigger?.level = level
    let wantsLocation = operation != "verify-rom"
    guard positional.count == (wantsLocation && pack == nil ? 2 : 1) else { print(sceneROMUsage); return 2 }
    do {
        let rom = try sceneROM(positional[0])
        func emit(_ text: String) throws {
            if let output { try Data(text.utf8).write(to: URL(fileURLWithPath: output), options: .atomic); print("wrote \(output)") }
            else { print(text, terminator: text.hasSuffix("\n") ? "" : "\n") }
        }
        func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try CTProject.jsonEncoder.encode(value), as: UTF8.self) + "\n" }
        let entries = try CTEventROM.entries(rom: rom)
        if operation == "verify-rom" {
            guard let manifest else { print("verify-rom requires --manifest"); return 2 }
            struct Manifest: Decodable {
                struct Pack: Decodable { let label: String; let pointerIndices: [Int]; let objects: Int? }
                let packs: [Pack]
            }
            let doc = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: manifest)))
            let packs = doc.packs.filter { $0.objects != nil }
            var ok = 0
            for record in packs {
                let bytes = try CTEventROM.unpack(rom: rom, entry: entries[record.pointerIndices[0]])
                let raised = try CTSceneDocument.raise(bytes: bytes, packEntry: record.pointerIndices[0])
                let back = try JSONDecoder().decode(CTSceneDocument.self, from: try JSONEncoder().encode(raised))
                guard try back.lower() == bytes else { throw CTEventError("\(record.label): the scene does not lower to the ROM bytes") }
                _ = try back.analyze()
                ok += 1
            }
            print("\(ok) of \(packs.count) non-empty event packs raise to ct-scene/1 and lower back byte-exact")
            return 0
        }
        let location = pack == nil ? Int(positional[1]) : nil
        if pack == nil {
            guard let location, (0..<CTMapROM.locCount).contains(location) else {
                print("location must be 0-\(CTMapROM.locCount - 1)"); return 2
            }
        }
        let entry = pack ?? CTMapROM.header(rom, location!).events
        let bytes = try CTEventROM.unpack(rom: rom, entry: entries[entry])
        guard !bytes.isEmpty else { throw CTEventError("event pack \(entry) is empty") }
        let doc = try CTSceneDocument.raise(bytes: bytes, location: location, packEntry: entry)
        let analysis = try doc.analyze()
        switch operation {
        case "raise":
            if json {
                struct Raised: Encodable { let document: CTSceneDocument; let analysis: CTSceneAnalysis }
                try emit(try encoded(Raised(document: doc, analysis: analysis)))
            } else { try emit(renderScene(analysis, location: location, entry: entry)) }
        case "graph":
            let graph = CTSceneGraph(analysis)
            try emit(json ? try encoded(graph) : graph.render())
        default:
            let result = try CTSceneTimeline.run(try doc.pack(), trigger: trigger, party: party, frameLimit: frames, stepLimit: steps)
            try emit(json ? try encoded(result) : CTSceneTimeline.render(result))
        }
        return 0
    } catch { print("scene \(operation) failed: \(error)"); return 1 }
}

/// Objects, functions, markers and calls of a raised pack (no script bytes beyond names and operands).
func renderScene(_ a: CTSceneAnalysis, location: Int?, entry: Int) -> String {
    var lines = ["; ct-scene/1 " + (location.map { "location \($0), " } ?? "") + "event pack \(entry) — extracted from your ROM; do not distribute",
                 "objects \(a.objectCount), statements \(a.statements.count), calls \(a.calls.count), data bytes \(a.dataBytes)"]
    for o in a.objects {
        let place = o.placement.map { " at (\($0.column), \($0.row))" } ?? ""
        lines.append("obj \(o.index): \(o.kind)\(place)")
        for f in o.functions where f.inScripts && f.alias == nil && (!f.stub || f.index == 0) {
            let same = o.functions.filter { $0.alias == f.index }.map(\.index)
            let also = same.isEmpty ? "" : " (also func " + same.map(String.init).joined(separator: ", ") + ")"
            lines.append(String(format: "  func %d %@ $%04X: %d statements", f.index, f.role, f.entry, f.statements.count) + also)
        }
        if !o.continuation.isEmpty { lines.append("  continuation: \(o.continuation.count) statements") }
        for m in o.markers {
            lines.append(String(format: "  %@ $%04X ", m.kind, m.offset) + "(\(m.function.map { "func \($0)" } ?? "continuation")): \(m.detail)")
        }
    }
    for c in a.calls {
        let target = c.targetObject.map { "obj \($0)" } ?? "party member \(c.member ?? 0)"
        lines.append(String(format: "call $%04X ", c.offset)
                     + "obj \(c.object) \(c.function.map { "func \($0)" } ?? "continuation") -> \(target) func \(c.targetFunction) [\(c.mode.rawValue), level \(c.level)]")
    }
    return lines.joined(separator: "\n") + "\n"
}
