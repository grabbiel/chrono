import Foundation
import ChronoForgeCore

func cmdText(_ args: [String]) -> Int32 {
    let operations = ["profile", "encode", "decode", "message", "build", "verify-corpus"]
    guard args.count >= 2, operations.contains(args[0]) else {
        print("usage: chronoforge text <profile|encode|decode|message|build|verify-corpus> <input> [--profile profile.json] [--out file]")
        return 2
    }
    let operation = args[0], input = URL(fileURLWithPath: args[1]).standardizedFileURL
    var output: URL?, profileURL: URL?
    var i = 2
    while i < args.count {
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
