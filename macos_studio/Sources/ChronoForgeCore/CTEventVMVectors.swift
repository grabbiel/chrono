// CTEventVMVectors.swift — runs CTEventVM's handler models on the cases
// re_workspace/tools/ct_event_vm.py builds, so the tool can compare each one
// with the ROM handler run in ChronoRET's interpreter on the same WRAM.
//
// cases.json: {"packs": {"<label>": "<hex>"}, "cases": [{"id": n, "pack":
// "<label>", "y": offset, "regions": [[address, "<hex>"], ...]}]}: the pack
// is at $7F:2000, the regions over a zeroed WRAM, Obj_Cur among them.
// results.json: {"families": {name: [opcode]}, "results": [{"id", "kind": "go"|"halted"|"unmodelled", "x", "carry",
// "reason", "mem": {"<address>": byte}}], mem holding the final value of each
// WRAM byte the model wrote.}
import Foundation

public enum CTEventVMVectors {
    struct Case: Decodable { let id: Int; let pack: String; let y: Int; let regions: [[Region]] }
    enum Region: Decodable {
        case address(Int), hex(String)
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let n = try? c.decode(Int.self) { self = .address(n) } else { self = .hex(try c.decode(String.self)) }
        }
    }
    struct Input: Decodable { let packs: [String: String]; let cases: [Case] }

    public struct Result: Encodable {
        public var id: Int, kind: String, x: Int?, carry: Bool?, reason: String?, mem: [String: Int]
    }

    static func bytes(hex: String) -> [UInt8] {
        var out: [UInt8] = [], hi: UInt8? = nil
        out.reserveCapacity(hex.utf8.count / 2)
        for c in hex.utf8 {
            let v: UInt8
            switch c {
            case 48...57: v = c - 48
            case 97...102: v = c - 87
            case 65...70: v = c - 55
            default: continue
            }
            if let h = hi { out.append(h << 4 | v); hi = nil } else { hi = v }
        }
        return out
    }

    public static func run(rom: [UInt8], casesJSON: Data) throws -> Data {
        let input = try JSONDecoder().decode(Input.self, from: casesJSON)
        var packs: [String: CTEventPack] = [:]
        var results: [Result] = []
        results.reserveCapacity(input.cases.count)
        for c in input.cases {
            let pack: CTEventPack
            if let p = packs[c.pack] { pack = p } else {
                guard let hex = input.packs[c.pack] else { throw CTEventError("case \(c.id): no pack \(c.pack)") }
                pack = try CTEventPack(bytes: bytes(hex: hex))
                packs[c.pack] = pack
            }
            let vm = CTEventVM(pack: pack, rom: rom)
            for r in c.regions {
                guard r.count == 2, case .address(let at) = r[0], case .hex(let hex) = r[1] else {
                    throw CTEventError("case \(c.id): a region is [address, hex]")
                }
                for (i, b) in bytes(hex: hex).enumerated() { vm.wram[at + i] = b }
            }
            vm.wram.recording = true
            let outcome = vm.execute(at: c.y)
            var mem: [String: Int] = [:]
            for (a, v) in vm.wram.writtenValues { mem[String(a)] = Int(v) }
            switch outcome {
            case .go(let x, let carry):
                results.append(Result(id: c.id, kind: "go", x: x, carry: carry, reason: nil, mem: mem))
            case .halted(let why):
                results.append(Result(id: c.id, kind: "halted", x: nil, carry: nil, reason: why, mem: mem))
            case .unmodelled(let why):
                results.append(Result(id: c.id, kind: "unmodelled", x: nil, carry: nil, reason: why, mem: mem))
            }
        }
        struct Output: Encodable { let families: [String: [Int]]; let results: [Result] }
        let families = CTEventVM.families.mapValues { $0.map { Int($0) } }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Output(families: families, results: results))
    }
}
