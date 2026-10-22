import Foundation
import CryptoKit
import ChronoForgeCore

func cmdText(_ args: [String]) -> Int32 {
    if let first = args.first, ["preview", "font", "fit"].contains(first) { return cmdTextBox(args) }
    let operations = ["profile", "encode", "decode", "message", "build", "verify-corpus", "analyze"]
    guard args.count >= 2, operations.contains(args[0]) else {
        print("usage: chronoforge text <profile|encode|decode|message|build|verify-corpus> <input> [--profile profile.json] [--out file]")
        print("       chronoforge text analyze <message.txt | dialogue.json> --profile profile.json [--json]")
        print(textBoxUsage)
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

// MARK: - The dialogue box (CTDialogueFont / CTDialogueLayout / CTDialogueBox)

let textBoxUsage = """
       chronoforge text preview <rom> <TABLE:INDEX | --text "..."> [--page N | --frame F] [--png out.png]
                    [--frames] [--layout-json] [--press N] [--place 1|2] [--style 0-7]
                    [--opcode BB|C0-C4 [--speaker-y Y]] [--choice K] [--location N --project P [--camera X,Y]]
                    (--opcode: the box's place as that opcode sets it, by the speaker's screen Y for BB/C0;
                     --choice: a choice message's cursor on box line K, from the end wait;
                     --location: the box over that imported location's field picture)
       chronoforge text preview <rom> --help-line item|tech <N | --text "..."> [--png out.png] [--layout-json]
                    (an item's or a tech's description in the menu's help line)
       chronoforge text font <rom> [--json]
       chronoforge text fit <rom> <message.txt | dialogue.json> [--json]   (report only: lines past the frame)
"""

private func boxROM(_ path: String) throws -> [UInt8] {
    var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    if data.count == CTROMBuilder.romSize + 512 { data.removeFirst(512) }
    guard data.count == CTROMBuilder.romSize else { throw CTTextError("expected a 4 MiB Chrono Trigger ROM") }
    return data
}

/// `[Messages_]D8D000:12` -> (table, index).
func parseMessageLabel(_ s: String) -> (Int, Int)? {
    let body = s.hasPrefix("Messages_") ? String(s.dropFirst(9)) : s
    let parts = body.split(separator: ":")
    guard parts.count == 2, parts[0].count == 6, let table = Int(parts[0], radix: 16), let index = Int(parts[1]),
          table >> 16 >= 0xC0 else { return nil }
    return (table, index)
}

private func jsonLine<T: Encodable>(_ value: T) throws -> Data {
    let e = JSONEncoder()
    e.outputFormatting = [.sortedKeys]
    return try e.encode(value) + Data("\n".utf8)
}

func cmdTextBox(_ args: [String]) -> Int32 {
    let operation = args[0]
    var positional: [String] = [], options: [String: String] = [:], flags: Set<String> = []
    var i = 1
    while i < args.count {
        let a = args[i]
        if ["--frames", "--layout-json", "--json"].contains(a) {
            flags.insert(a)
            i += 1
        } else if ["--text", "--page", "--frame", "--png", "--press", "--place", "--style", "--help-line",
                    "--opcode", "--speaker-y", "--choice", "--location", "--project", "--camera"].contains(a) {
            guard i + 1 < args.count else { print("missing value for \(a)"); return 2 }
            options[a] = args[i + 1]
            i += 2
        } else if a.hasPrefix("--") {
            print("unknown text \(operation) option \(a)"); return 2
        } else {
            positional.append(a)
            i += 1
        }
    }
    guard let romPath = positional.first else { print("usage:\n" + textBoxUsage); return 2 }
    func int(_ key: String, _ fallback: Int) -> Int? {
        guard let v = options[key] else { return fallback }
        return Int(v)
    }
    guard let press = int("--press", 1), let place = int("--place", 1), [1, 2].contains(place),
          let style = int("--style", 0), (0...7).contains(style) else {
        print("--press takes a number, --place 1 or 2, --style 0-7"); return 2
    }
    var boxPlace = place
    if let op = options["--opcode"] {
        guard options["--place"] == nil else { print("give --place or --opcode, not both"); return 2 }
        guard let code = Int(op.hasPrefix("$") ? String(op.dropFirst()) : op, radix: 16),
              let y = parseNumber(options["--speaker-y"] ?? "0"),
              let p = CTBoxPlace.place(opcode: code, screenY: y) else {
            print("--opcode takes a message opcode BB or C0-C4 (hex), --speaker-y a number"); return 2
        }
        boxPlace = p
    } else if options["--speaker-y"] != nil {
        print("--speaker-y needs --opcode"); return 2
    }
    var cursor: Int?
    if let k = options["--choice"] {
        guard let line = Int(k), (0...3).contains(line) else { print("--choice takes a box line 0-3"); return 2 }
        cursor = line
    }
    do {
        let rom = try boxROM(romPath)
        let mem = CTDialogueMemory(rom: rom)
        switch operation {
        case "font":
            return try textFont(mem, json: flags.contains("--json"))
        case "fit":
            guard positional.count == 2 else { print("usage:\n" + textBoxUsage); return 2 }
            return try textFit(rom, URL(fileURLWithPath: positional[1]), json: flags.contains("--json"))
        default:
            break
        }
        let settings = CTDialogueSettings.placeholder(press: press, place: boxPlace)
        if let where_ = options["--help-line"] {
            guard let helpPlace = CTHelpLine.Place(rawValue: where_) else { print("--help-line takes item or tech"); return 2 }
            return try helpLinePreview(rom, place: helpPlace, positional: Array(positional.dropFirst()), options: options,
                                       flags: flags, settings: settings)
        }
        let layout: CTDialogueLayout
        if let text = options["--text"] {
            guard positional.count == 1 else { print("give a message id or --text, not both"); return 2 }
            let codec = try CTTextCodec(profile: CTTextProfile.fromROM(Data(rom)))
            layout = try CTDialogueLayout.bytes(try codec.compileMessage(text), rom: rom, settings: settings)
        } else {
            guard positional.count == 2, let (table, index) = parseMessageLabel(positional[1]) else {
                print("give a message id TABLE:INDEX (e.g. D8D000:12) or --text \"...\""); return 2
            }
            let at = CTDialogueLayout.messageAddress(rom: rom, table: table, index: index)
            layout = try CTDialogueLayout(mem: mem, text: at, settings: settings)
        }
        if flags.contains("--layout-json") {
            FileHandle.standardOutput.write(try jsonLine(layout.summary))
            return 0
        }
        if flags.contains("--frames") {
            FileHandle.standardOutput.write(Data(frameTimeline(layout).utf8))
        } else {
            FileHandle.standardOutput.write(Data(layoutReport(layout).utf8))
        }
        if let png = options["--png"] {
            let frame: Int
            if let f = options["--frame"] {
                guard let n = Int(f) else { print("--frame takes a number"); return 2 }
                frame = n
            } else {
                guard let page = int("--page", 0), let at = layout.pageFrame(page) else {
                    print("no page \(options["--page"] ?? "0") (the message has \(layout.pageCount))"); return 1
                }
                frame = at
            }
            let box = CTDialogueBox(mem: mem, style: style)
            var picture = box.frame(layout, at: frame, cursor: cursor)
            if let loc = options["--location"] {
                guard let n = parseNumber(loc), let path = options["--project"] else {
                    print("--location takes a location number and needs --project P"); return 2
                }
                let xy = (options["--camera"] ?? "0,0").split(separator: ",").compactMap { Int($0) }
                guard xy.count == 2 else { print("--camera takes X,Y"); return 2 }
                let project = try CTProject.load(from: URL(fileURLWithPath: path))
                let map = try CTDialogueOverMap.picture(project: project, location: n, cameraX: xy[0], cameraY: xy[1])
                picture = box.frame(layout, at: frame, over: map, cursor: cursor)
            }
            let rgba = PPUReferenceRenderer.render(picture)
            let url = URL(fileURLWithPath: png)
            try PNG.writeRGBA(width: PPUFrame.width, height: 224, rgba: rgba).write(to: url, options: .atomic)
            print("wrote \(url.path) (frame \(min(frame, layout.frameCount - 1)))")
        }
        if let cursor {
            let from = CTChoiceCursor.firstFrame(layout).map { "from frame \($0)" } ?? "no end wait: not drawn"
            print("choice cursor: box line \(cursor), \(from)")
        }
        if options["--opcode"] != nil {
            print("box place: \(boxPlace == CTBoxPlace.top ? "top (1)" : "bottom (2)")")
        }
        return 0
    } catch {
        print("text \(operation) failed: \(error)"); return 1
    }
}

private func textFont(_ mem: CTDialogueMemory, json: Bool) throws -> Int32 {
    struct Box: Encodable {
        var lines: Int, lineHeight: Int, penLeft: Int, penIndent: Int, innerRight: Int, bandLines: Int
        var framesPerGlyph: Int, waitUnitFrames: Int
    }
    struct Font: Encodable {
        var schema: String, font: String, fontRight: String, glyphs: Int, glyphPixels: String, widthsAt: String
        var glyphDigest: String, widths: [Int], frameDigests: [String], palettes: [[Int]], box: Box
    }
    var frames: [String] = [], palettes: [[Int]] = []
    for k in 0..<CTDialogueROM.styles {
        let (tiles, alt) = CTDialogueWindow.frameSet(mem, style: k)
        frames.append(CTDialogueFont.hex(SHA256Digest(tiles + alt)))
        palettes.append(CTDialogueWindow.palette(mem, style: k).dropFirst().map { Int($0 ?? 0) })
    }
    let widths: [Int] = (0xA0..<0x100).map { CTDialogueFont.width(mem, $0) }
    let box = Box(lines: CTDialogueROM.lines, lineHeight: CTDialogueROM.lineHeight, penLeft: CTDialogueROM.penLeft,
                  penIndent: CTDialogueROM.penIndent, innerRight: CTDialogueROM.innerRight,
                  bandLines: CTDialogueROM.bandLines, framesPerGlyph: 1, waitUnitFrames: CTDialogueROM.waitUnit)
    let font = Font(schema: "ct-dialogue-font/1", font: CTDialogueROM.snes(CTDialogueROM.font),
                    fontRight: CTDialogueROM.snes(CTDialogueROM.fontRight), glyphs: CTDialogueFont.glyphCodes.count,
                    glyphPixels: "12x12 2bpp", widthsAt: CTDialogueROM.snes(CTDialogueROM.widths),
                    glyphDigest: CTDialogueFont.digest(mem), widths: widths, frameDigests: frames, palettes: palettes,
                    box: box)
    if json {
        FileHandle.standardOutput.write(try jsonLine(font))
        return 0
    }
    print("font \(font.font) + \(font.fontRight): \(font.glyphs) glyphs, 12x12 2bpp; widths at \(font.widthsAt)")
    print("advances $A0-$FF: " + widths.map(String.init).joined(separator: " "))
    print("glyph digest \(font.glyphDigest)")
    print("box: 4 lines of 16 px, pen 8 (indent $14) to the frame edge at 248; 1 glyph a frame, waits of 15 frames")
    print("\(CTDialogueROM.styles) frame styles (Menu_Config01 bits 0-2), colours 9-11 the text greys")
    return 0
}

/// SHA-256 bytes of `bytes` (for hex()).
private func SHA256Digest(_ bytes: [UInt8]) -> [UInt8] {
    Array(SHA256.hash(data: Data(bytes)))
}

private func layoutReport(_ layout: CTDialogueLayout) -> String {
    var out: [String] = []
    let glyphs = layout.glyphs
    out.append("\(layout.frameCount) frames (\(String(format: "%.2f", Double(layout.frameCount) / 60.0)) s at 60 fps), "
               + "\(glyphs.count) glyphs, \(layout.pageCount) page(s), "
               + "\(layout.events.filter { $0.kind == .key }.count) key wait(s)")
    for p in 0..<layout.pageCount {
        let mine = glyphs.filter { $0.page == p }
        let at = layout.pageFrame(p).map(String.init) ?? "-"
        out.append("page \(p): drawn by frame \(at)")
        for line in 0..<CTDialogueROM.lines {
            let g = mine.filter { $0.line == line }
            guard !g.isEmpty else { continue }
            let end = g.map { ($0.pen ?? 0) + $0.width }.max() ?? 0
            out.append("  line \(line): \(g.count) glyphs, pen \(g.first?.pen ?? 0)-\(end)"
                       + (end > CTDialogueROM.innerRight ? "  PAST THE FRAME (248)" : ""))
        }
    }
    let codes = layout.events.filter { $0.kind == .code }.map { String(format: "$%02X", $0.value) }
    if !codes.isEmpty { out.append("codes: " + codes.joined(separator: " ")) }
    for o in layout.overflows.prefix(8) {
        out.append(String(format: "overflow: page %d line %d glyph $%02X at pen %d ends at %d%@", o.page, o.line,
                          o.glyph, o.pen, o.end, o.wraps ? " (the 8-bit pen wraps)" : ""))
    }
    return out.joined(separator: "\n") + "\n"
}

private func frameTimeline(_ layout: CTDialogueLayout) -> String {
    var byFrame: [Int: [CTDialogueEvent]] = [:]
    for e in layout.events { byFrame[e.frame, default: []].append(e) }
    var out = ["frame state open page wait  events"]
    for (n, s) in layout.frames.enumerated() {
        let events = (byFrame[n] ?? []).map { e -> String in
            switch e.kind {
            case .glyph: return String(format: "glyph $%02X @%d", e.value, e.pen ?? 0)
            case .code: return String(format: "code $%02X", e.value)
            case .key: return "key"
            }
        }
        out.append(String(format: "%5d %5d %4d %4d %4@  ", n, s.state, s.open, s.page, s.keyWait ? "key" : "")
                   + events.joined(separator: ", "))
    }
    return out.joined(separator: "\n") + "\n"
}

/// Report-only: every message laid out with placeholder names, lines past the frame listed.
private func textFit(_ rom: [UInt8], _ input: URL, json: Bool) throws -> Int32 {
    let codec = try CTTextCodec(profile: CTTextProfile.fromROM(Data(rom)))
    var texts: [(String, String)] = []
    if input.pathExtension == "json" {
        let dialogue = try CTProject.jsonDecoder.decode(Dialogue.self, from: Data(contentsOf: input))
        texts = dialogue.strings.keys.sorted().map { ($0, dialogue.strings[$0]!) }
    } else {
        texts = [(input.lastPathComponent, try String(contentsOf: input, encoding: .utf8))]
    }
    struct Finding: Encodable { var id: String, page: Int, line: Int, pen: Int, end: Int, wraps: Bool }
    struct Report: Encodable { var messages: Int, failed: [String], findings: [Finding] }
    var report = Report(messages: texts.count, failed: [], findings: [])
    for (id, text) in texts {
        do {
            let layout = try CTDialogueLayout.bytes(try codec.compileMessage(text), rom: rom, settings: .placeholder())
            var seen = Set<[Int]>()
            for o in layout.overflows where seen.insert([o.page, o.line]).inserted {
                report.findings.append(Finding(id: id, page: o.page, line: o.line, pen: o.pen, end: o.end, wraps: o.wraps))
            }
        } catch {
            report.failed.append("\(id): \(error)")
        }
    }
    if json {
        FileHandle.standardOutput.write(try jsonLine(report))
        return 0
    }
    print("\(report.messages) message(s), \(report.findings.count) line(s) past the frame edge (x 248)"
          + (report.failed.isEmpty ? "" : ", \(report.failed.count) not laid out"))
    for f in report.findings {
        print("  \(f.id): page \(f.page) line \(f.line) ends at \(f.end)" + (f.wraps ? " (the pen wraps)" : ""))
    }
    for f in report.failed { print("  \(f)") }
    return 0
}

// MARK: - The menu's help line (CTHelpLine)

/// `--help-line item|tech`: description N of the ROM's table, or `--text`, as the menu draws it.
private func helpLinePreview(_ rom: [UInt8], place: CTHelpLine.Place, positional: [String], options: [String: String],
                             flags: Set<String>, settings: CTDialogueSettings) throws -> Int32 {
    let mem = CTDialogueMemory(rom: rom)
    let line: CTHelpLine
    var label: String
    if let text = options["--text"] {
        guard positional.isEmpty else { print("give a description number or --text, not both"); return 2 }
        let codec = try CTTextCodec(profile: CTTextProfile.fromROM(Data(rom)))
        line = try CTHelpLine.bytes(try codec.compileMessage(text), rom: rom, place: place, settings: settings)
        label = "--text"
    } else {
        guard positional.count == 1, let n = parseNumber(positional[0]), (0..<place.count).contains(n) else {
            print("give a \(place.rawValue) number 0-\(place.count - 1) (decimal or $hex) or --text \"...\""); return 2
        }
        line = try CTHelpLine(mem: mem, text: CTHelpLine.stringAddress(mem, place: place, index: n), place: place,
                              settings: settings, stopAtRunaway: true)
        label = String(format: "%@ $%02X", place.rawValue, n)
    }
    if flags.contains("--layout-json") {
        FileHandle.standardOutput.write(try jsonLine(line.summary))
        return 0
    }
    var out = ["\(label): \(line.glyphs.count) glyphs in \(line.frames) frames (one a frame), "
               + "BG3 rows \(line.place.row)-\(line.place.row + 1), map to VRAM "
               + String(format: "$%04X", line.place.vramMap)]
    out.append("pen 8-\(line.right): screen x 24-\(line.rightX) of 256; \(line.fits ? "fits" : "OVERFLOWS")")
    if line.lineCount > 1 { out.append("  \(line.lineCount) lines: only the first is sent to the screen") }
    if line.pastRow { out.append("  tile words run past column 31 into the next row") }
    if line.wraps { out.append("  the 8-bit pen wraps") }
    if let why = line.runaway { out.append("  the game would not survive it: \(why); stopped there") }
    print(out.joined(separator: "\n"))
    if let png = options["--png"] {
        let (backdrop, colours) = CTHelpLine.palette(mem)
        let rgba = line.renderStrip(backdrop: backdrop, colours: colours)
        let url = URL(fileURLWithPath: png)
        try PNG.writeRGBA(width: PPUFrame.width, height: 16, rgba: rgba).write(to: url, options: .atomic)
        print("wrote \(url.path) (256 x 16, BG3 over the menu's colour 0; the window frame is not drawn)")
    }
    return 0
}

/// `12`, `$0C` or `0x0C`.
func parseNumber(_ s: String) -> Int? {
    if s.hasPrefix("$") { return Int(s.dropFirst(), radix: 16) }
    if s.hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16) }
    return Int(s)
}
