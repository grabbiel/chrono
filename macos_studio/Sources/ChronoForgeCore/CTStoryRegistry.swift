// The project's story-flag registry (story/flags.json, ct-story-flags/1): one
// entry per bit or byte of $7F:0000-$7F:01FF the event packs use, with a stable
// generated symbol, its references, room for a maintainer's name and notes, and
// the bytes nothing uses. Bit entries become project flags, so scenes resolve
// them like any flag (CTEventLowering.flagResolver, EventReferences). See
// docs/story.md.
import Foundation

public struct CTStoryRegistry: Codable, Equatable, Sendable {
    public static let schema = "ct-story-flags/1"
    public static let path = "story/flags.json"
    /// Project flags the registry writes carry this origin; others are never touched.
    public static let origin = "story"

    public var schema: String = CTStoryRegistry.schema
    public var romSHA256: String
    public var entries: [Entry]
    /// Story bytes no event instruction and no proven code reference touches.
    public var unused: [String]
    public var totals: Totals

    public struct Totals: Codable, Equatable, Sendable {
        public var packs: Int
        public var instructions: Int
        public var references: Int
        public var warps: Int
        public var codeReferences: Int
    }

    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var symbol: String               // generated from the address: stable
        public var addr: String                 // "7F:0010"
        public var bit: Int?                    // nil: a byte variable
        public var name: String?                // the maintainer's, when evidence supports one
        public var notes: String?
        public var counts: [String: Int]        // CTStory.Kind raw value -> references
        public var locations: [Int]
        public var references: [CTStory.Reference]
        public var code: [CodeReference]
        public var id: String { symbol }
        public var address: Int { Int(addr.split(separator: ":").last ?? "", radix: 16) ?? 0 }
        public var isBit: Bool { bit != nil }
    }

    public static func symbol(addr: Int, bit: Int?) -> String {
        bit.map { String(format: "flag_7F%04X_%d", addr, $0) } ?? String(format: "var_7F%04X", addr)
    }

    /// The registry from a scan; names and notes of `previous` entries are kept
    /// by symbol. `code`: references outside the event VM (Python evidence or
    /// the ROM pattern scan).
    public static func build(scan: CTStory.Scan, code: [CodeReference], romSHA256: String,
                             previous: CTStoryRegistry? = nil) -> CTStoryRegistry {
        var bits: [String: (Int, Int, [CTStory.Reference])] = [:]
        var bytes: [Int: [CTStory.Reference]] = [:]
        var touched = Set<Int>()
        for r in scan.references {
            let a = r.access
            for addr in a.addr..<min(CTStory.memoryEnd, a.addr + max(1, a.width)) { touched.insert(addr) }
            if let bit = a.bit {
                bits[symbol(addr: a.addr, bit: bit), default: (a.addr, bit, [])].2.append(r)
            } else {
                for addr in a.addr..<min(CTStory.memoryEnd, a.addr + max(1, a.width)) { bytes[addr, default: []].append(r) }
            }
        }
        let codeBy = Dictionary(grouping: code, by: \.addr)
        let kept = Dictionary((previous?.entries ?? []).map { ($0.symbol, $0) }, uniquingKeysWith: { a, _ in a })
        func entry(_ symbol: String, _ addr: Int, _ bit: Int?, _ refs: [CTStory.Reference]) -> Entry {
            var counts: [String: Int] = [:]
            for r in refs { counts[r.access.kind.rawValue, default: 0] += 1 }
            return Entry(symbol: symbol, addr: String(format: "7F:%04X", addr), bit: bit,
                         name: kept[symbol]?.name, notes: kept[symbol]?.notes, counts: counts,
                         locations: Array(Set(refs.flatMap(\.site.locations))).sorted(), references: refs,
                         code: codeBy[addr] ?? [])
        }
        var entries = bits.map { entry($0.key, $0.value.0, $0.value.1, $0.value.2) }
        entries += bytes.map { entry(symbol(addr: $0.key, bit: nil), $0.key, nil, $0.value) }
        // Bytes only proven code touches get a byte entry too; a pattern match
        // alone (it also matches data) leaves a byte unused.
        let proven = Set(code.filter { $0.status != "pattern-matched" }.map(\.addr))
        for addr in proven.subtracting(touched) where addr < CTStory.memoryEnd {
            entries.append(entry(symbol(addr: addr, bit: nil), addr, nil, []))
        }
        entries.sort { ($0.address, $0.bit ?? -1) < ($1.address, $1.bit ?? -1) }
        let used = touched.union(proven)
        return CTStoryRegistry(romSHA256: romSHA256, entries: entries,
                               unused: (0..<CTStory.memoryEnd).filter { !used.contains($0) }.map { String(format: "7F:%04X", $0) },
                               totals: Totals(packs: scan.packs, instructions: scan.instructions,
                                              references: scan.references.count, warps: scan.warps.count,
                                              codeReferences: code.count))
    }

    /// The project flags for the registry's bit entries: the generated symbol,
    /// and the maintainer's name as a second symbol on the same bit.
    public var projectFlags: [Project.Flag] {
        entries.compactMap { e -> [Project.Flag]? in
            guard let bit = e.bit else { return nil }
            var out = [Project.Flag(symbol: e.symbol, bank: "story", addr: e.addr, bit: bit, origin: Self.origin)]
            if let name = e.name, !name.isEmpty, name != e.symbol {
                out.append(Project.Flag(symbol: name, bank: "story", addr: e.addr, bit: bit, origin: Self.origin,
                                        notes: e.notes))
            }
            return out
        }.flatMap { $0 }
    }

    /// Replaces the project's registry flags (origin "story") with the current
    /// ones; a flag the maintainer wrote keeps its symbol and wins over a
    /// registry symbol that collides with it.
    public func sync(into project: inout Project) {
        let own = project.flags.filter { $0.origin != Self.origin }
        let taken = Set(own.map(\.symbol))
        project.flags = own + projectFlags.filter { !taken.contains($0.symbol) }
    }

    /// Sets a maintainer name and notes. Names must be identifiers the scene
    /// language reads bare, unique among registry entries and project flags.
    public mutating func annotate(symbol: String, name: String?, notes: String?, project: Project) throws {
        guard let i = entries.firstIndex(where: { $0.symbol == symbol }) else {
            throw CTEventError("no registry entry \(symbol)")
        }
        let name = name?.trimmingCharacters(in: .whitespaces)
        if let name, !name.isEmpty {
            guard name.utf8.count <= 255, name.range(of: "^[A-Za-z_][A-Za-z0-9_.-]*$", options: .regularExpression) != nil else {
                throw CTEventError("\(name): use letters, digits, _ . - (starting with a letter or _)")
            }
            let others = entries.enumerated().filter { $0.offset != i }.flatMap { [$0.element.symbol, $0.element.name ?? ""] }
            let flags = project.flags.filter { $0.origin != Self.origin }.map(\.symbol)
            guard !others.contains(name), !flags.contains(name) else { throw CTEventError("\(name) is already used") }
        }
        entries[i].name = (name?.isEmpty ?? true) ? nil : name
        entries[i].notes = (notes?.isEmpty ?? true) ? nil : notes
    }

    // MARK: Files

    public static func load(project url: URL) throws -> CTStoryRegistry? {
        let file = url.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let doc = try CTProject.jsonDecoder.decode(CTStoryRegistry.self, from: Data(contentsOf: file))
        guard doc.schema == schema else { throw CTProjectError.badFormat("\(path): schema \(doc.schema)") }
        return doc
    }

    public func save(project url: URL) throws {
        let file = url.appendingPathComponent(Self.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CTProject.jsonEncoder.encode(self).write(to: file, options: .atomic)
    }

    /// Code references from `ct_story.py code --out` (ChronoRET source lines,
    /// and the ROM patterns with their status).
    public static func codeEvidence(_ data: Data) throws -> [CodeReference] {
        struct Use: Decodable { let file: String; let line: Int; let routine: String?; let mnemonic: String
                                let addr: Int; let access: String; let indexed: Bool }
        struct Hit: Decodable { let snes: Int; let mnemonic: String; let indexed: Bool; let addr: Int
                                let routine: String?; let status: String }
        struct Doc: Decodable { let schema: String; let source: [Use]; let romPatterns: [Hit] }
        let doc = try JSONDecoder().decode(Doc.self, from: data)
        guard doc.schema == "ct-story/1" else { throw CTEventError("code evidence schema \(doc.schema)") }
        let source = doc.source.filter { $0.addr < CTStory.memoryEnd }.map {
            CodeReference(addr: $0.addr, width: 1, access: $0.access, status: "code-proven",
                          where_: "\($0.file):\($0.line)", mnemonic: $0.mnemonic + ($0.indexed ? " ,X" : ""),
                          routine: $0.routine, source: "\($0.file):\($0.line)")
        }
        let rom = doc.romPatterns.map {
            CodeReference(addr: $0.addr, width: 1, access: $0.mnemonic == "STA" ? "write" : "read", status: $0.status,
                          where_: String(format: "$%02X:%04X", $0.snes >> 16, $0.snes & 0xFFFF),
                          mnemonic: $0.mnemonic + ($0.indexed ? " ,X" : ""), routine: $0.routine, source: nil)
        }
        return source + rom
    }
}

// MARK: - A ROM script path in the scene preview

public extension CTStory {
    struct PathCheck: Equatable, Sendable {
        public var entry: Int                   // Evt_PackPtrs index
        public var offset: Int                  // where the raised path starts
        public var statements: Int
        public var flagChanges: [String]        // "set S" / "clear S", in order
        public var previewFlags: [String]       // EventPreview's final flags
        public var schedulerFlags: [String]     // EventScheduler's final flags
        public var expectedFlags: [String]      // from the recorded references
        public var loweredMatches: Bool         // lowering gives back the ROM's bytes for the path
        public var passed: Bool { previewFlags == expectedFlags && schedulerFlags == expectedFlags && loweredMatches }
    }

    /// Raises the straight-line path at `start` (opcodes that only go on) into
    /// a scene: $65/$66 on a registry bit become set_flag/clear_flag with its
    /// symbol, other opcodes `ct` statements. Stops at the first opcode that
    /// branches, ends or is a message opcode. nil when the path sets no flag.
    static func raisePath(_ pack: CTEventPack, start: Int, registry: CTStoryRegistry)
        -> (scene: EventScene, changes: [String], end: Int)? {
        let bits = Dictionary(registry.entries.compactMap { e in e.bit.map { ("\(e.address).\($0)", e.symbol) } },
                              uniquingKeysWith: { a, _ in a })
        let none = [UInt8](repeating: 0, count: 16)
        var stmts: [EventStmt] = [], changes: [String] = [], y = start
        while let ins = pack.instructions[y], ins.flow == .next, !CTEventLowering.reservedOpcodes.contains(ins.opcode) {
            if ins.opcode == 0x65 || ins.opcode == 0x66 {
                let a = accesses(pack, at: y, bitSet: [1, 2, 4, 8, 16, 32, 64, 128] + none.prefix(8))
                guard let access = a.first, let bit = access.bit, let symbol = bits["\(access.addr).\(bit)"] else { break }
                stmts.append(ins.opcode == 0x65 ? .setFlag(symbol: symbol) : .clearFlag(symbol: symbol))
                changes.append((ins.opcode == 0x65 ? "set " : "clear ") + symbol)
            } else {
                stmts.append(.ct(opcode: ins.opcode, operands: Array(pack.bytes[(y + 2)..<(y + 1 + ins.length)])))
            }
            y += ins.length
        }
        guard changes.contains(where: { $0.hasPrefix("set ") }) else { return nil }
        return (EventScene(object: 0, funcs: [EventFunc(index: 0, stmts: stmts)]), changes, y)
    }

    /// The first ROM path (by pack and offset) that sets a registry flag, run
    /// in EventPreview and EventScheduler: the flags must change as the
    /// registry's references record, and lowering must give back its bytes.
    static func previewCheck(rom: [UInt8], registry: CTStoryRegistry) throws -> PathCheck {
        let entries = try CTEventROM.entries(rom: rom)
        var tried = Set<Int>()
        for e in entries where !CTROMLayout.notEventPackEntries.contains(e.index) && tried.insert(e.snesAddress).inserted {
            let bytes = try CTEventROM.unpack(rom: rom, entry: e)
            guard !bytes.isEmpty else { continue }
            let pack = try CTEventPack(bytes: bytes)
            for start in pack.instructions.keys.sorted() where pack.instructions[start]!.opcode == 0x65 {
                guard let (scene, changes, end) = raisePath(pack, start: start, registry: registry) else { continue }
                var expected = Set<String>()
                for c in changes {
                    let symbol = String(c.split(separator: " ")[1])
                    if c.hasPrefix("set ") { expected.insert(symbol) } else { expected.remove(symbol) }
                }
                let preview = try EventPreview.run(scene, stepLimit: 100_000)
                let scheduled = try EventScheduler.run(scenes: ["path": scene], entryScene: "path", stepLimit: 100_000)
                let lowered = try CTEventLowering.lower(scenes: [scene], flag: CTEventLowering.flagResolver(registry.projectFlags))
                let loweredPack = try CTEventPack(bytes: lowered.bytes)
                let first = loweredPack.functions[0][0]
                let span = end - start
                let matches = first + span <= loweredPack.scriptSize
                    && Array(lowered.bytes[(first + 1)..<(first + 1 + span)]) == Array(pack.bytes[(start + 1)..<(end + 1)])
                return PathCheck(entry: e.index, offset: start, statements: scene.funcs[0].stmts.count, flagChanges: changes,
                                 previewFlags: preview.flags, schedulerFlags: scheduled.flags,
                                 expectedFlags: expected.sorted(), loweredMatches: matches)
            }
        }
        throw CTEventError("no straight-line path sets a registry flag")
    }
}
