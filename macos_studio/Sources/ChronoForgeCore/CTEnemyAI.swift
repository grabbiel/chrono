// Enemy AI scripts: the block format BattleAi_RunMainPart / FindReactPart
// read, shown as text with the names of the handlers that read each byte,
// and assembled back. The twin of re_workspace/tools/ct_enemies.py
// (parse_script, format_parts, ai_assemble); docs/enemies.md.
import Foundation

public enum CTEnemyAI {
    public static let blockEnd: UInt8 = 0xFE, partEnd: UInt8 = 0xFF
    public static let testSize = 4
    /// BattleFD_AiActLength ($FD:BA4A) as ChronoRET lists it: bytes per action code.
    public static let actLengthsPC = 0x3DBA4A
    public static let restartCode: UInt8 = 0x04          // BattleAi_ChooseByChance: the code byte alone

    public struct ScriptError: Error, CustomStringConvertible, Sendable {
        public let description: String
        init(_ d: String) { description = d }
    }

    /// Test codes $00-$28: display name and the labels of bytes 1-3 (ChronoRET's handler headers).
    public static let tests: [UInt8: (name: String, labels: [String])] = {
        var t: [UInt8: (String, [String])] = [
            0x00: ("Always", ["b1", "b2", "b3"]), 0x01: ("HpHalfOrLess", ["target", "b2", "b3"]),
            0x02: ("StatusBits", ["which", "offset", "mask"]), 0x03: ("TargetId", ["target", "id", "b3"]),
            0x04: ("EnemyIdPresent", ["b1", "id", "absent"]), 0x05: ("EnemyCountAtMost", ["n", "b2", "b3"]),
            0x06: ("TimeAtLeast", ["low", "middle", "high"]), 0x07: ("UnkB320", ["value", "mode", "b3"]),
            0x08: ("HpAtMost", ["target", "hpLow", "hpHigh"]), 0x09: ("StatByteAtLeast", ["target", "offset", "value"]),
            0x0A: ("StatByteBits", ["target", "offset", "mask"]), 0x0B: ("StatByteAtMost", ["target", "offset", "value"]),
            0x0C: ("TargetWithin32", ["target", "invert", "b3"]), 0x0D: ("AnySameRow", ["target", "invert", "b3"]),
            0x0E: ("AnyAboveOrLeft", ["target", "invert", "dir"]), 0x0F: ("PathClear", ["target", "invert", "arg"]),
            0x10: ("ScreenArea", ["b1", "which", "columns"]), 0x11: ("B19EKind", ["kind", "b2", "invert"]),
            0x12: ("B19EKindAndId", ["kind", "id", "invert"]), 0x13: ("B19EBit4", ["value", "b2", "invert"]),
            0x14: ("B19ESlot", ["id", "mode", "invert"]), 0x15: ("B19EByte2Bits", ["mask", "b2", "invert"]),
            0x16: ("Always16", ["b1", "b2", "b3"]), 0x17: ("Chance", ["percent", "b2", "b3"]),
            0x18: ("StatByteEquals", ["value", "target", "offset"]), 0x19: ("Always19", ["b1", "b2", "b3"]),
            0x1A: ("OtherEnemy", ["id", "skipSelf", "want"]), 0x1B: ("PcCountAtMost", ["n", "b2", "b3"]),
            0x1C: ("UnkAF0AMatch", ["target", "any", "absent"]), 0x1D: ("TargetGone", ["target", "b2", "gone"]),
            0x1E: ("ChooseAndGoOn", ["b1", "b2", "b3"]), 0x1F: ("TargetWithin48", ["target", "invert", "b3"]),
            0x20: ("UnkAEB3Set", ["b1", "b2", "b3"]), 0x21: ("UnkAF15Set", ["b1", "b2", "b3"]),
            0x22: ("UnkB158", ["target", "value", "atLeast"]),
        ]
        for c in UInt8(0x23)...UInt8(0x28) { t[c] = ("StatByteEquals", ["value", "target", "offset"]) }
        return t.mapValues { (name: $0.0, labels: $0.1) }
    }()

    static func pairs(_ n: Int, _ second: String) -> [String] {
        var out: [String] = []
        for i in 1...n { out.append("offset\(i)"); out.append("\(second)\(i)") }
        return out
    }

    /// Action codes $00-$16: display name and the labels of the bytes after
    /// the code; nil labels: the length table gives no usable length.
    public static let actions: [UInt8: (name: String, labels: [String]?)] = {
        let tech = ["tech", "b2", "helper1", "helper2"]
        let restore: [String] = ["b1", "action"] + (1...8).map { "p\($0)" } + ["message"]
        let t: [UInt8: (String, [String]?)] = [
            0x00: ("AnimTarget", ["b1", "target", "anim"]), 0x01: ("Attack", ["id", "target", "arg"]),
            0x02: ("Tech", ["tech", "target", "helper1", "helper2", "message"]), 0x03: ("Nop03", nil),
            0x04: ("ByChance", []), 0x05: ("ChooseRepeat", nil), 0x06: ("Nop06", ["b1", "b2", "b3"]),
            0x07: ("SwapInEnemy", ["id", "action", "rebuild"]), 0x08: ("Nop08", ["b1", "b2", "b3"]),
            0x09: ("Leave", ["action"]), 0x0A: ("KoSelf", ["action", "message"]),
            0x0B: ("SetStatByte", ["offset", "value", "or", "message"]), 0x0C: ("AddStatByte", ["offset", "delta", "message"]),
            0x0D: ("SetFlags", ["flags", "message"]), 0x0E: ("Nop0E", ["b1"]), 0x0F: ("Message", ["byte"]),
            0x10: ("RestoreEnemies", ["hpMode", "action", "message"]),
            0x11: ("SetStatBytes", pairs(4, "value") + ["message"]),
            0x12: ("SetStatsTech", tech + pairs(5, "value") + ["message"]),
            0x13: ("AddUnkB158", ["target", "delta"]), 0x14: ("AddStatBytes", pairs(4, "delta") + ["message"]),
            0x15: ("AddStatsTech", tech + pairs(5, "delta") + ["message"]),
            0x16: ("RestoreAndSetStats", restore),
        ]
        return t.mapValues { (name: $0.0, labels: $0.1) }
    }()

    /// Target codes $00-$38: the BattleAi_TargetTable handlers' names.
    public static let targets = [
        "None", "Pcs", "All", "Self", "FromUnkB19E", "RandomPc", "NearestPc", "FarthestPc", "LowestHpPc",
        "PcStatus", "PcStatus2", "PcUnk1F", "PcUnk20", "PcUnk21", "PcStatus2Bit1", "PcStatus2Bit7",
        "PcStatus2Bit2", "PcUnk21Bit2", "PcUnk21Bit6", "PcUnk20Bit4", "PcUnk01Bit3", "OtherEnemies",
        "Enemies", "NearestEnemy", "FarthestEnemy", "LowestHpEnemy", "OtherEnemyStatus", "EnemyStatus",
        "OtherEnemyStatus2", "EnemyStatus2", "OtherEnemyUnk1F", "EnemyUnk1F", "OtherEnemyStatus2Bit1",
        "OtherEnemyStatus2Bit7", "OtherEnemyStatus2Bit2", "OtherEnemyUnk21Bit6", "OtherEnemyStatusBit1",
        "OtherEnemyUnk19Bit0", "LowestHpOtherEnemy", "Enemy0", "Enemy1", "Enemy2", "Enemy3", "Enemy4",
        "Enemy5", "Enemy6", "Enemy7", "RandomUnkAF15", "Slot0", "Slot1", "Slot2", "Slot3", "Slot4",
        "Slot5", "Slot6", "HighestHpPc", "RandomOtherEnemy",
    ]

    /// One block: one or two 4-byte tests, then its action records.
    public struct Block: Equatable, Sendable {
        public var tests: [[UInt8]]
        public var actions: [[UInt8]]
        public init(tests: [[UInt8]], actions: [[UInt8]]) { self.tests = tests; self.actions = actions }
    }
    /// The main part and the reaction part.
    public typealias Parts = [[Block]]

    public static func actionLength(_ code: UInt8, lengths: [Int]) -> Int? {
        if code == restartCode { return 1 }
        guard Int(code) < lengths.count, let entry = actions[code], entry.labels != nil else { return nil }
        return lengths[Int(code)]
    }

    /// The two parts of the script at `at` in `data` (bank $CC, or a whole
    /// synthetic script) and its end. A record holding $FE or $FF before its
    /// end would be cut there by the game's byte scan, so it is refused.
    public static func parse(_ data: [UInt8], at start: Int, lengths: [Int]) throws -> (parts: Parts, end: Int) {
        var parts: Parts = [], x = start
        func byte(_ i: Int) throws -> UInt8 {
            guard i < data.count else { throw ScriptError("runs past the data") }
            return data[i]
        }
        for _ in 0..<2 {
            var blocks: [Block] = []
            while true {
                if try byte(x) == partEnd { x += 1; break }
                var end = x
                while try byte(end) != blockEnd { end += 1 }
                let count = end - x
                guard count == testSize || count == 2 * testSize else {
                    throw ScriptError("a test part of \(count) bytes at +\(x - start)")
                }
                var tests: [[UInt8]] = []
                for i in stride(from: x, to: end, by: testSize) {
                    guard Self.tests[data[i]] != nil else { throw ScriptError(String(format: "test code $%02X past the table", data[i])) }
                    tests.append(Array(data[i..<(i + testSize)]))
                }
                x = end + 1
                var acts: [[UInt8]] = []
                while try byte(x) != blockEnd {
                    let code = data[x]
                    guard code < 0x80, let n = actionLength(code, lengths: lengths) else {
                        throw ScriptError(String(format: "action code $%02X at +%d has no length", code, x - start))
                    }
                    guard x + n <= data.count else { throw ScriptError("runs past the data") }
                    let rec = Array(data[x..<(x + n)])
                    guard !rec.dropFirst().contains(blockEnd), !rec.dropFirst().contains(partEnd) else {
                        throw ScriptError(String(format: "action $%02X at +%d holds $FE or $FF", code, x - start))
                    }
                    acts.append(rec)
                    x += n
                }
                x += 1
                blocks.append(Block(tests: tests, actions: acts))
            }
            parts.append(blocks)
        }
        return (parts, x)
    }

    public static func assemble(_ parts: Parts) -> [UInt8] {
        var out: [UInt8] = []
        for blocks in parts {
            for b in blocks {
                for t in b.tests { out += t }
                out.append(blockEnd)
                for a in b.actions { out += a }
                out.append(blockEnd)
            }
            out.append(partEnd)
        }
        return out
    }

    static func hex(_ b: UInt8) -> String { String(format: "$%02X", b) }

    static func targetNote(_ labels: [String], _ rec: [UInt8]) -> String {
        var notes: [String] = []
        for (i, label) in labels.enumerated() where ["target", "helper1", "helper2"].contains(label) {
            let v = Int(rec[1 + i])
            if v < targets.count && !(label.hasPrefix("helper") && v == 0) { notes.append(targets[v]) }
        }
        return notes.isEmpty ? "" : "  ; " + notes.joined(separator: ", ")
    }

    /// One record's line: `test $01 HpHalfOrLess target=$03 b2=$00 b3=$00  ; Self`.
    public static func line(kind: String, _ rec: [UInt8]) -> String {
        let name: String, labels: [String]
        if kind == "test" { (name, labels) = (tests[rec[0]]!.name, tests[rec[0]]!.labels) }
        else { (name, labels) = (actions[rec[0]]!.name, actions[rec[0]]!.labels ?? []) }
        var args: [String] = []
        for (label, b) in zip(labels, rec.dropFirst()) { args.append("\(label)=\(hex(b))") }
        let head = "\(kind) \(hex(rec[0])) \(name)"
        return (args.isEmpty ? head : head + " " + args.joined(separator: " ")) + targetNote(labels, rec)
    }

    public static func format(_ parts: Parts) -> String {
        var lines: [String] = []
        for (title, blocks) in zip(["main", "reaction"], parts) {
            lines.append(title)
            for b in blocks {
                lines.append("  block")
                for t in b.tests { lines.append("    " + line(kind: "test", t)) }
                for a in b.actions { lines.append("    " + line(kind: "act", a)) }
            }
        }
        lines.append("end")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func text(_ data: [UInt8], at start: Int, lengths: [Int]) throws -> String {
        format(try parse(data, at: start, lengths: lengths).parts)
    }

    static func hexByte(_ token: Substring) -> UInt8? {
        guard token.count == 3, token.first == "$" else { return nil }
        return UInt8(token.dropFirst(), radix: 16)
    }

    /// The bytes of a script in `format`'s text: names are checked against
    /// the codes; arguments are read as `label=$hh` or `$hh`; `;` starts a comment.
    public static func assemble(text: String, lengths: [Int]) throws -> [UInt8] {
        var parts: Parts = []
        var number = 0
        lineLoop: for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            let content = raw.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let head = content.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let first = head.first else { continue }
            let open = !parts.isEmpty, inBlock = open && !parts[parts.count - 1].isEmpty
            if (first == "main" || first == "reaction") && head.count == 1 {
                guard (first == "main") == parts.isEmpty else { throw ScriptError("line \(number): main, then reaction") }
                parts.append([])
            } else if first == "end" {
                break lineLoop
            } else if first == "block" && open {
                parts[parts.count - 1].append(Block(tests: [], actions: []))
            } else if (first == "test" || first == "act") && inBlock {
                let isTest = first == "test"
                guard head.count > 1, let code = hexByte(head[1]) else { throw ScriptError("line \(number): expected a $code") }
                let name: String, labels: [String]
                if isTest, let t = tests[code] { (name, labels) = (t.name, t.labels) }
                else if !isTest, let a = actions[code], let l = a.labels { (name, labels) = (a.name, l) }
                else { throw ScriptError("line \(number): no \(first) \(hex(code))") }
                var rest = Array(head.dropFirst(2))
                if let r = rest.first, !r.hasPrefix("$"), !r.contains("=") {
                    guard r == name else { throw ScriptError("line \(number): \(hex(code)) is \(name), not \(r)") }
                    rest.removeFirst()
                }
                var values: [UInt8] = [code]
                for token in rest {
                    let pieces = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    let label = pieces.count == 2 ? pieces[0] : ""
                    guard !(pieces.count == 2 && label.isEmpty), label.allSatisfy({ $0.isLetter || $0.isNumber }),
                          let v = hexByte(pieces[pieces.count - 1]) else {
                        throw ScriptError("line \(number): bad byte \(String(reflecting: String(token)))")
                    }
                    values.append(v)
                }
                guard values.count == 1 + labels.count else {
                    throw ScriptError("line \(number): \(name) takes \(labels.count) bytes, not \(values.count - 1)")
                }
                if !isTest && actionLength(code, lengths: lengths) != values.count {
                    throw ScriptError("line \(number): the length table gives \(hex(code)) another length")
                }
                let p = parts.count - 1, b = parts[p].count - 1
                if isTest { parts[p][b].tests.append(values) } else { parts[p][b].actions.append(values) }
            } else {
                throw ScriptError("line \(number): \(String(reflecting: content.trimmingCharacters(in: .whitespaces)))")
            }
        }
        guard parts.count == 2 else { throw ScriptError("a script has a main and a reaction part") }
        for blocks in parts {
            for b in blocks where !(1...2).contains(b.tests.count) { throw ScriptError("a block has one or two tests") }
        }
        let out = assemble(parts)
        _ = try parse(out, at: 0, lengths: lengths)
        return out
    }
}
