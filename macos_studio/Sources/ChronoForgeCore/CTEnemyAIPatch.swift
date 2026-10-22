// Enemy AI script write-back: an edited script goes back in place when it
// fits its own span and no other enemy's script overlaps it; else into the
// confirmed padding of bank $CC with its pointer rewritten. Evidence and
// the script region: docs/enemies.md ("Writing scripts"); the independent
// check: re_workspace/tools/ct_rom_check.py (check_enemy_scripts).
import Foundation

public enum CTEnemyAIPatch {
    /// BattleAi_RunMainPart / FindReactPart read `!BattleRom_AiScriptPtrs`
    /// ($CC:8B08 + id × 2, u16) and every script byte as `LDA.l $CC0000,X`
    /// with a 16-bit X: a script must lie inside bank $CC.
    public static let bankPC = CTEnemyROM.aiBankPC
    public static let pointers = 256
    /// The confirmed padding at the end of bank $CC (`Padding_CCFC4F`, 945 × $FF).
    public static let freePC = 0x0CFC4F, freeEnd = 0x0D0000
    public static var freeBytes: Int { freeEnd - freePC }

    /// One listed enemy's script text over the base ROM's enemy `enemyId`.
    public struct Request: Sendable {
        public let id: String
        public let enemyId: Int
        public let text: String
        public init(id: String, enemyId: Int, text: String) { self.id = id; self.enemyId = enemyId; self.text = text }
    }

    /// A script the build wrote: where, how it was placed and its text as the parser reads it back.
    public struct ReportScript: Codable, Equatable, Sendable {
        public let id: String
        public let enemyId: Int
        public let address: String
        public let pc: Int
        public let bytes: Int
        public let placement: String               // original (in place) | free (relocated)
        public let from: String?                   // the base ROM's address
        public let sha256: String
        public let text: String
    }

    // MARK: The base ROM's scripts

    public static func pointer(_ rom: [UInt8], _ id: Int) -> Int {
        Int(rom[CTEnemyROM.aiPointersPC + 2 * id]) | Int(rom[CTEnemyROM.aiPointersPC + 2 * id + 1]) << 8
    }

    /// The PC span of every pointer that leads to a script that parses (ids 0-255).
    public static func spans(rom: [UInt8], lengths: [Int]) -> [Int: Range<Int>] {
        let bank = Array(rom[bankPC..<(bankPC + 0x10000)])
        var out: [Int: Range<Int>] = [:]
        for id in 0..<pointers {
            let at = pointer(rom, id)
            if let (_, end) = try? CTEnemyAI.parse(bank, at: at, lengths: lengths) { out[id] = (bankPC + at)..<(bankPC + end) }
        }
        return out
    }

    /// For each id, the other ids whose scripts overlap its span.
    public static func sharers(_ spans: [Int: Range<Int>]) -> [Int: [Int]] {
        var out: [Int: [Int]] = [:]
        for (a, ra) in spans {
            for (b, rb) in spans where a != b && ra.overlaps(rb) { out[a, default: []].append(b) }
        }
        return out.mapValues { $0.sorted() }
    }

    // MARK: Checks

    /// The bytes to write for `text`: what `CTEnemyAI.assemble(text:)`
    /// accepts, ended by an `end` line, with no test byte $FF
    /// (BattleAi_FindReactPart takes the first $FF as the main part's end)
    /// and every target-code byte a BattleAi_TargetTable entry.
    public static func assemble(text raw: String, lengths: [Int]) throws -> [UInt8] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let ended = text.split(separator: "\n").contains { line in
            let content = line.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return content.trimmingCharacters(in: .whitespaces) == "end"
        }
        guard ended else { throw CTEnemyAI.ScriptError("the script has no end line") }
        let bytes = try CTEnemyAI.assemble(text: text, lengths: lengths)
        let parts = try CTEnemyAI.parse(bytes, at: 0, lengths: lengths).parts
        for blocks in parts {
            for b in blocks {
                for t in b.tests {
                    if t.dropFirst().contains(CTEnemyAI.partEnd) {
                        throw CTEnemyAI.ScriptError(String(format: "test $%02X holds $FF, which ends the main part for BattleAi_FindReactPart", t[0]))
                    }
                    try checkTargets(t, labels: CTEnemyAI.tests[t[0]]!.labels, kind: "test")
                }
                for a in b.actions { try checkTargets(a, labels: CTEnemyAI.actions[a[0]]!.labels ?? [], kind: "act") }
            }
        }
        return bytes
    }

    static func checkTargets(_ rec: [UInt8], labels: [String], kind: String) throws {
        for (i, label) in labels.enumerated() where label == "target" && Int(rec[1 + i]) >= CTEnemyAI.targets.count {
            throw CTEnemyAI.ScriptError(String(format: "%@ $%02X: target $%02X is past BattleAi_TargetTable ($00-$%02X)",
                                               kind, rec[0], rec[1 + i], CTEnemyAI.targets.count - 1))
        }
    }

    // MARK: Write-back

    /// The listed enemies' scripts that differ from the base ROM's, written
    /// in place or into bank $CC's padding. Unchanged text writes nothing.
    static func apply(_ requests: [Request], base: [UInt8], space: inout FreeSpace,
                      write: ([UInt8], Int, String) -> Void,
                      relocated: (String, Int?, Int, Int) -> Void) throws -> [ReportScript] {
        guard !requests.isEmpty else { return [] }
        let lengths = CTEnemyROM.actLengths(rom: base)
        let spans = spans(rom: base, lengths: lengths)
        let shared = sharers(spans)
        var seen = Set<Int>()
        var planned: [(r: Request, bytes: [UInt8])] = []
        for r in requests {
            guard (0..<CTEnemyROM.count).contains(r.enemyId) else {
                throw CTROMBuildError("enemy \(r.id): the enemy id must be 0-254")
            }
            guard seen.insert(r.enemyId).inserted else { throw CTROMBuildError("enemy \(r.id): script \(r.enemyId) is built twice") }
            let bytes: [UInt8]
            do { bytes = try assemble(text: r.text, lengths: lengths) }
            catch { throw CTROMBuildError("enemy \(r.id) AI: \(error)") }
            guard let span = spans[r.enemyId] else {
                throw CTROMBuildError("enemy \(r.id) AI: its pointer in the base ROM does not lead to a script " +
                                      "(enemy 127's); it is kept as it is, so drop ai.text")
            }
            if Array(base[span]) == bytes { continue }
            planned.append((r, bytes))
        }
        var out: [ReportScript] = []
        for (r, bytes) in planned {
            let old = spans[r.enemyId]!
            let pc: Int, placement: String
            if bytes.count <= old.count, shared[r.enemyId] == nil {
                pc = old.lowerBound; placement = "original"
            } else {
                guard let at = space.allocate(bytes.count, reclaimed: false, bank: bankPC >> 16) else {
                    throw CTROMBuildError("enemy \(r.id) AI: no room for its \(bytes.count) bytes in bank $CC's free space " +
                                          "(\(freeBytes) bytes in all; edited scripts that are shared or grow are placed there)")
                }
                pc = at; placement = "free"
                let address = pc & 0xFFFF
                write([UInt8(address & 0xFF), UInt8(address >> 8)], CTEnemyROM.aiPointersPC + 2 * r.enemyId,
                      "BattleRom_AiScriptPtrs[\(r.enemyId)]")
                relocated("enemy \(r.id) AI script", CTEnemyROM.aiBankPC + pointer(base, r.enemyId), pc, bytes.count)
            }
            write(bytes, pc, "enemy \(r.id) AI script")
            let text = CTEnemyAI.format(try CTEnemyAI.parse(bytes, at: 0, lengths: lengths).parts)
            out.append(.init(id: r.id, enemyId: r.enemyId, address: CTROMBuilder.snes(pc), pc: pc, bytes: bytes.count,
                             placement: placement, from: CTROMBuilder.snes(CTEnemyROM.aiBankPC + pointer(base, r.enemyId)),
                             sha256: CTEventPack.sha256(bytes), text: text))
        }
        return out
    }

    // MARK: Budget (no ROM needed)

    /// What a build would do with a listed enemy's script, from the facts
    /// the import records (`size`, `shared`, `sha256`).
    public enum Plan: Equatable, Sendable { case unchanged, inPlace, relocated, unknown }

    public static func plan(_ script: CharacterDef.Enemy.Script, bytes: [UInt8]) -> Plan {
        guard let size = script.size, let origin = script.sha256 else { return .unknown }
        if CTEventPack.sha256(bytes) == origin { return .unchanged }
        return bytes.count <= size && (script.shared ?? []).isEmpty ? .inPlace : .relocated
    }

    /// The bytes of bank $CC's padding the project's listed scripts would
    /// take, and the files whose plan is unknown (imported before the facts
    /// were recorded) or whose text does not assemble. `lengths` defaults to
    /// the length table ChronoRET lists (BattleFD_AiActLength).
    public static func budget(_ project: CTProject, lengths: [Int] = listedLengths) -> (used: Int, unknown: [String], broken: [String]) {
        var used = 0, unknown: [String] = [], broken: [String] = []
        for id in project.project.rom?.enemies ?? [] {
            guard let s = project.characters[id]?.enemy?.ai, let text = s.text else { continue }
            guard let bytes = try? assemble(text: text, lengths: lengths) else { broken.append(id); continue }
            switch plan(s, bytes: bytes) {
            case .relocated: used += bytes.count
            case .unknown: unknown.append(id)
            case .unchanged, .inPlace: break
            }
        }
        return (used, unknown, broken)
    }

    /// BattleFD_AiActLength ($FD:BA4A) as ChronoRET lists it; `ct_enemies.py
    /// check` proves the ROM's table equals it.
    public static let listedLengths = [4, 4, 6, 0, 0xFF, 0xFF, 4, 4, 4, 2, 3, 5, 4, 3, 2, 2, 4, 10, 16, 3, 10, 16, 12]
}
