import Foundation
import ChronoForgeCore

func cmdText(_ args: [String]) -> Int32 {
    let operations = ["profile", "encode", "decode", "message", "build", "verify-corpus", "analyze"]
    guard args.count >= 2, operations.contains(args[0]) else {
        print("usage: chronoforge text <profile|encode|decode|message|build|verify-corpus> <input> [--profile profile.json] [--out file]")
        print("       chronoforge text analyze <message.txt | dialogue.json> --profile profile.json [--json]")
        return 2
    }
    let operation = args[0], input = URL(fileURLWithPath: args[1]).standardizedFileURL
    var output: URL?, profileURL: URL?, json = false
    var i = 2
    while i < args.count {
        if args[i] == "--json", operation == "analyze" { json = true; i += 1; continue }
        guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
        switch args[i] {
        case "--out": output = URL(fileURLWithPath: args[i + 1]).standardizedFileURL
        case "--profile": profileURL = URL(fileURLWithPath: args[i + 1])
        default: print("unknown text option \(args[i])"); return 2
        }
        i += 2
    }
    if ["encode", "message", "profile", "build"].contains(operation), output == nil {
        print("\(operation) requires --out"); return 2
    }
    if let output, output.resolvingSymlinksInPath() == input.resolvingSymlinksInPath() {
        print("output must differ from input"); return 2
    }
    if ["profile", "build"].contains(operation), profileURL != nil {
        print("--profile does not apply to \(operation)"); return 2
    }
    do {
        let result: Data
        if operation == "profile" {
            let profile = try CTTextProfile.fromROM(Data(contentsOf: input))
            result = try CTProject.jsonEncoder.encode(profile)
        } else if operation == "build" {
            let project = try CTProject.load(from: input)
            result = try CTProject.jsonEncoder.encode(CTDialogueArchive.compile(project))
        } else {
            guard let profileURL else { print("\(operation) requires --profile"); return 2 }
            let profile = try CTProject.jsonDecoder.decode(CTTextProfile.self, from: Data(contentsOf: profileURL))
            let codec = try CTTextCodec(profile: profile)
            switch operation {
            case "encode", "message":
                let source = try String(contentsOf: input, encoding: .utf8)
                result = Data(try operation == "message" ? codec.compileMessage(source) : codec.encode(source))
            case "decode": result = Data(try codec.decode(Array(Data(contentsOf: input))).utf8)
            case "analyze":
                // A .json input is a dialogue.json (every string); anything else is one message.
                let texts: [String]
                if input.pathExtension == "json" {
                    let dialogue = try CTProject.jsonDecoder.decode(Dialogue.self, from: Data(contentsOf: input))
                    texts = dialogue.strings.keys.sorted().map { dialogue.strings[$0]! }
                } else {
                    texts = [try String(contentsOf: input, encoding: .utf8)]
                }
                result = try analysisOutput(CTTextAnalyzer.analyze(texts, codec: codec), json: json)
            default:
                struct Corpus: Decodable {
                    struct Case: Decodable { let label: String; let bytes: [UInt8]; let text: String }
                    let cases: [Case]
                }
                let corpus = try CTProject.jsonDecoder.decode(Corpus.self, from: Data(contentsOf: input))
                guard !corpus.cases.isEmpty else { throw CTTextError("corpus is empty") }
                for sample in corpus.cases {
                    do {
                        guard try codec.encode(sample.text) == sample.bytes else {
                            throw CTTextError("reference text did not encode to original bytes")
                        }
                        guard try codec.encode(codec.decode(sample.bytes)) == sample.bytes else {
                            throw CTTextError("lossless Swift decode/encode failed")
                        }
                    } catch { throw CTTextError("corpus case \(sample.label): \(error)") }
                }
                result = Data("\(corpus.cases.count) ROM text cases passed (reference encode + Swift byte round-trip)\n".utf8)
            }
        }
        if let output {
            try result.write(to: output, options: .atomic)
            print("wrote \(output.path)")
        } else { FileHandle.standardOutput.write(result) }
        return 0
    } catch { print("text \(operation) failed: \(error)"); return 1 }
}

private func analysisOutput(_ r: CTTextAnalyzer.Report, json: Bool) throws -> Data {
    if json { return try CTProject.jsonEncoder.encode(r) + Data("\n".utf8) }
    let ratio = r.rawBytes == 0 ? 0 : 100 * r.savedBytes / r.rawBytes
    var lines = ["\(r.messages) message(s): \(r.rawBytes) bytes raw, \(r.compressedBytes) with the dictionary, "
                 + "\(r.savedBytes) saved (\(ratio)%)"]
    if let segments = r.segments {
        lines.append("runs: " + segments.map { s in
            switch s.kind {
            case "dictionary": return String(format: "[$%02X %@]", s.bytes[0], s.text)
            case "control": return "{" + s.bytes.map { String(format: "%02X", $0) }.joined() + "}"
            default: return s.text
            }
        }.joined())
    }
    for e in r.entries.prefix(20) {
        lines.append(String(format: "  $%02X %-14@ used %4d  saves %5d", 0x21 + e.entry, "\"\(e.text)\"" as NSString, e.uses, e.savedBytes))
    }
    if r.entries.count > 20 { lines.append("  … \(r.entries.count - 20) more entries used") }
    lines.append("\(r.unusedEntries.count) of 127 entries unused")
    return Data((lines.joined(separator: "\n") + "\n").utf8)
}
