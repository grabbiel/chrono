import Foundation
import ChronoForgeCore

private let eventUsage = """
usage: chronoforge event list <rom.sfc>
       chronoforge event disasm <rom.sfc> <pointer-index> [--out file.ctevt]
       chronoforge event asm <file.ctevt> --out pack.bin
       chronoforge event verify-rom <rom.sfc> --manifest event_pack_verification.json
       chronoforge event lower <project.ctproj> <scene-id>... --out lowered.json
"""

private func loadROM(_ path: String) throws -> [UInt8] {
    var data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    if data.count == 4_194_304 + 512 { data.removeFirst(512) }
    guard data.count == 4_194_304 else { throw CTEventError("expected a 4 MiB Chrono Trigger ROM") }
    return data
}

func cmdEvent(_ args: [String]) -> Int32 {
    guard let operation = args.first,
          ["list", "disasm", "asm", "verify-rom", "lower"].contains(operation), args.count >= 2 else {
        print(eventUsage); return 2
    }
    var positional: [String] = [], output: String?, manifest: String?
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--out", "--manifest":
            guard i + 1 < args.count else { print("missing value for \(args[i])"); return 2 }
            if args[i] == "--out" { output = args[i + 1] } else { manifest = args[i + 1] }
            i += 2
        default:
            positional.append(args[i]); i += 1
        }
    }
    do {
        switch operation {
        case "list":
            let rom = try loadROM(positional[0])
            var seen: [Int: Int] = [:]
            for entry in try CTEventROM.entries(rom: rom) {
                let address = String(format: "$%02X:%04X", entry.snesAddress >> 16, entry.snesAddress & 0xFFFF)
                if let first = seen[entry.snesAddress] {
                    print(String(format: "%3d  %@  same as %d", entry.index, address, first)); continue
                }
                seen[entry.snesAddress] = entry.index
                do {
                    let bytes = try CTEventROM.unpack(rom: rom, entry: entry)
                    let pack = try CTEventPack(bytes: bytes)
                    print(String(format: "%3d  %@  %5d B  %2d objects  %5d opcodes  %4d data B",
                                 entry.index, address, bytes.count, pack.objectCount,
                                 pack.instructions.count, pack.dataByteCount))
                } catch { print(String(format: "%3d  %@  not event data (%@)", entry.index, address, "\(error)")) }
            }
        case "disasm":
            guard positional.count == 2, let index = Int(positional[1]), (0..<CTEventROM.pointerCount).contains(index) else {
                print(eventUsage); return 2
            }
            let rom = try loadROM(positional[0])
            let entry = try CTEventROM.entries(rom: rom)[index]
            let pack = try CTEventPack(bytes: try CTEventROM.unpack(rom: rom, entry: entry))
            let title = String(format: "Evt_PackPtrs[%d] at $%06X — extracted from your ROM; do not distribute", index, entry.snesAddress)
            let text = CTEventListing.render(CTEventListing.program(pack), title: title)
            if let output { try Data(text.utf8).write(to: URL(fileURLWithPath: output), options: .atomic); print("wrote \(output)") }
            else { print(text, terminator: "") }
        case "asm":
            guard let output else { print("asm requires --out"); return 2 }
            let text = try String(contentsOf: URL(fileURLWithPath: positional[0]), encoding: .utf8)
            let bytes = try CTEventListing.parse(text).assemble()
            try Data(bytes).write(to: URL(fileURLWithPath: output), options: .atomic)
            print("wrote \(output) (\(bytes.count) bytes)")
        case "verify-rom":
            guard let manifest else { print("verify-rom requires --manifest"); return 2 }
            let rom = try loadROM(positional[0])
            let count = try verifyROMPacks(rom: rom, manifest: URL(fileURLWithPath: manifest))
            print("\(count) event packs: Swift decode matches the handler-traced records; listing round-trips byte-exact")
        default:
            guard let output, positional.count >= 2 else { print("lower requires a project, scene IDs and --out"); return 2 }
            let project = try CTProject.load(from: URL(fileURLWithPath: positional[0]))
            let lowered = try CTEventLowering.lower(project: project, scenes: Array(positional.dropFirst()))
            try CTProject.jsonEncoder.encode(lowered).write(to: URL(fileURLWithPath: output), options: .atomic)
            print("wrote \(output) (\(lowered.bytes.count) bytes, \(lowered.messages.count) messages)")
        }
        return 0
    } catch {
        print("event \(operation) failed: \(error)"); return 1
    }
}

/// Every pack recorded by tools/ct_event_packs.py: same opcodes reached
/// (digest), counts, and render → parse → assemble gives the ROM bytes.
func verifyROMPacks(rom: [UInt8], manifest: URL) throws -> Int {
    struct Manifest: Decodable {
        struct Pack: Decodable {
            let label: String; let pointerIndices: [Int]; let unpackedBytes: Int; let sha256: String
            let objects: Int?; let instructions: Int?; let innerInstructions: Int?
            let dataBytes: Int?; let instructionDigest: String?
        }
        let packs: [Pack]; let nonEventPointerIndices: [Int]
    }
    let doc = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifest))
    let entries = try CTEventROM.entries(rom: rom)
    var checked = 0
    for record in doc.packs {
        let bytes = try CTEventROM.unpack(rom: rom, entry: entries[record.pointerIndices[0]])
        guard bytes.count == record.unpackedBytes, CTEventPack.sha256(bytes) == record.sha256 else {
            throw CTEventError("\(record.label): unpacked bytes differ from the record")
        }
        checked += 1
        guard record.objects != nil else {
            guard bytes.isEmpty else { throw CTEventError("\(record.label): expected an empty pack") }
            continue
        }
        let pack = try CTEventPack(bytes: bytes)
        let inner = pack.layout.inner.count
        guard pack.objectCount == record.objects, pack.instructions.count == record.instructions,
              inner == record.innerInstructions, pack.dataByteCount == record.dataBytes,
              pack.instructionDigest == record.instructionDigest else {
            throw CTEventError("\(record.label): Swift decode differs from the handler-traced record")
        }
        let text = CTEventListing.render(CTEventListing.program(pack))
        guard try CTEventListing.parse(text).assemble() == bytes else {
            throw CTEventError("\(record.label): listing does not assemble back to the ROM bytes")
        }
    }
    return checked
}
