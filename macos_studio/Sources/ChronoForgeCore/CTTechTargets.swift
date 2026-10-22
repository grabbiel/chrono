// Where a tech aims and what its area takes in: the menu's target modes
// (BattleTgt_ModeTable, 33 handlers) and the area records' entries
// (BattleTgt_AreaTable shapes, BattleSys_AreaParamTable centres), with the
// tests the area routines make on battlers' screen positions. Source:
// ChronoRET's bank $C1 headers; docs/techs.md says which parts are inferred.
import Foundation

public enum CTTechTargets {
    public static let partySlots = 0..<3, enemySlots = 3..<11

    public struct Point: Equatable, Sendable {
        public var x: Int, y: Int
        public init(x: Int, y: Int) { self.x = x; self.y = y }
    }

    /// An area query as BattleTgt_RunAreaQuery takes it (battler slots; sizes as stored).
    public enum Shape: Equatable, Sendable {
        case line(source: Int, aim: Int, size: Int, box: Bool)   // half-width size * 8 px; box: ends at the aim
        case circle(centre: Int, size: Int)                      // dx² + dy² <= size, in 16-pixel cells
        case partyTriangle                                       // enemies inside the PCs' triangle
        case row(centre: Int)                                    // y within ±$20 of the centre's
    }

    public struct Zone: Equatable, Sendable {
        public var shape: Shape
        public var scansParty: Bool                              // AreaSide != 0: PCs, else enemies
        public init(_ shape: Shape, scansParty: Bool = false) { self.shape = shape; self.scansParty = scansParty }
    }

    /// BattleTgt_ModeTable's handlers by target mode (unlisted: one ally).
    public static let modes: [String] = [
        "one ally", "all allies", "self", "one KO'd ally", "all allies", "the PC with id 5", "the PC with id 4",
        "one enemy", "all enemies", "everyone", "all enemies", "line from the caster", "line from the caster to the enemy",
        "line from the PC with id 3", "one ally", "row around an enemy", "one ally", "radius 4 around the caster",
        "radius 3 around an enemy", "radius 4 around the PC with id 3", "radius 5 around the PC with id 3", "one ally",
        "one ally", "one ally", "the party's triangle", "one ally", "radius 5 around an enemy",
        "radius 5 around the PC with id 6", "one ally", "one ally", "one ally", "one ally", "one ally"]

    /// BattleTgt_AreaTable's routines by an area entry's byte 0.
    public static let shapes = ["line", "circle", "circle", "party triangle", "line", "party triangle", "row"]

    /// BattleSys_AreaParamTable's routines by an entry's byte 1 bits 6-0.
    public static let params = ["centre user 1, aim the target", "centre the target", "centre the slot in the size byte",
                                "centre the target, aim user 2", "centre user 2", "centre the caster",
                                "centre the caster, aim the target"]

    /// What menu target mode `mode` lists: an area (enemy side) or a fixed set of
    /// slots. `party` holds each PC slot's character id.
    public static func menu(_ mode: Int, caster: Int, target: Int, party: [Int?]) -> (zone: Zone?, slots: [Int]) {
        let slotOf = { (id: Int) in party.firstIndex { $0 == id } }
        let all = Array(enemySlots)
        switch mode & 0x7F {
        case 0x01, 0x04: return (nil, Array(partySlots))
        case 0x02: return (nil, [caster])
        case 0x05: return (nil, slotOf(5).map { [$0] } ?? [])
        case 0x06: return (nil, slotOf(4).map { [$0] } ?? [])
        case 0x07: return (nil, [target])
        case 0x08, 0x0A: return (nil, all)
        case 0x09: return (nil, Array(partySlots) + all)
        case 0x0B: return (Zone(.line(source: caster, aim: target, size: 2, box: false)), [])
        case 0x0C: return (Zone(.line(source: caster, aim: target, size: 2, box: true)), [])
        case 0x0D: return (slotOf(3).map { Zone(.line(source: $0, aim: target, size: 2, box: false)) }, [])
        case 0x0F: return (Zone(.row(centre: target)), [])
        case 0x11: return (Zone(.circle(centre: caster, size: 0x10)), [])
        case 0x12, 0x1A: return (Zone(.circle(centre: target, size: mode == 0x1A ? 0x19 : 0x09)), [])
        case 0x13, 0x14: return (slotOf(3).map { Zone(.circle(centre: $0, size: mode == 0x14 ? 0x19 : 0x10)) }, [])
        case 0x18: return (Zone(.partyTriangle), [])
        case 0x1B: return (slotOf(6).map { Zone(.circle(centre: $0, size: 0x19)) }, [])
        default: return (nil, [caster])                       // $00, $03 and the unlisted modes: one ally
        }
    }

    /// The zone an area record entry runs (BattleSys_UnkC1DD), or nil for a
    /// position query (byte 1 bit 7). `users` holds the users' slots.
    public static func zone(_ entry: TechSystemDef.Area, users: [Int], caster: Int, target: Int) -> Zone? {
        guard entry.param & 0x80 == 0 else { return nil }
        let user = { (k: Int) in users.indices.contains(k) ? users[k] : 0xFF }
        let p = entry.param & 0x7F
        let size = [0, 1, 4, 5, 6].contains(p) ? entry.size & 0x7F : 0
        let variant = (p == 0 || p == 6) && entry.size & 0x80 != 0
        let centre = [user(0), target, entry.size & 0x7F, target, user(1), caster, caster][min(p, 6)]
        let aim = [target, 0xFF, 0xFF, user(1), 0xFF, 0xFF, target][min(p, 6)]
        // Set 3 takes the side from user 0's slot; the others take DP $0A, which
        // the target-mode handler sets. Approximated here by the target's side.
        let scansParty = p == 3 ? user(0) != 0 : partySlots.contains(target)
        let shape: Shape
        switch entry.shape {
        case 0, 4: shape = .line(source: centre, aim: aim, size: size, box: variant)
        case 1, 2: shape = .circle(centre: centre, size: size)
        case 3, 5: shape = .partyTriangle
        default: shape = .row(centre: centre)
        }
        return Zone(shape, scansParty: scansParty)
    }

    /// The slots a zone takes in, given each slot's screen position (nil:
    /// absent). Circle and row are the routines' arithmetic; the line's strip
    /// and box are their inferred geometry (BattleTgt_AreaLine); the triangle
    /// is exact where the routine compares 8-bit angles from each corner.
    public static func hits(_ zone: Zone, positions: [Point?]) -> [Int] {
        let side = zone.scansParty ? Array(partySlots) : Array(enemySlots)
        let present = side.filter { positions.indices.contains($0) && positions[$0] != nil }
        func at(_ slot: Int) -> Point? { positions.indices.contains(slot) ? positions[slot] : nil }
        /// The anchor heads the list when it is on the scanned side (BattleTgt_AreaAddAnchor).
        func withAnchor(_ anchor: Int, _ found: [Int]) -> [Int] { (side.contains(anchor) && at(anchor) != nil ? [anchor] : []) + found }
        switch zone.shape {
        case .circle(let centre, let size):
            guard let c = at(centre) else { return [] }
            let found = present.filter { slot in
                guard slot != centre, let p = at(slot) else { return false }
                let dx = abs(p.x >> 4 - c.x >> 4), dy = abs(p.y >> 4 - c.y >> 4)
                return (dx * dx + dy * dy) & 0xFF <= size                // the 8-bit sum wraps (a quirk kept)
            }
            return withAnchor(centre, found)
        case .row(let centre):
            guard let c = at(centre) else { return [] }
            let top = max(c.y - 0x20, 0), bottom = min(c.y + 0x20, 0xFF)
            return [centre] + present.filter { $0 != centre && (top...bottom).contains(at($0)!.y) }
        case .partyTriangle:
            let corners = partySlots.compactMap(at)
            guard corners.count == 3 else { return [] }
            return enemySlots.filter { slot in at(slot).map { inside($0, corners[0], corners[1], corners[2]) } ?? false }
        case .line(let source, let aim, let size, let box):
            guard let s = at(source), let a = at(aim), s != a else { return [] }
            let (ux, uy) = (Double(a.x - s.x), Double(a.y - s.y))
            let length = (ux * ux + uy * uy).squareRoot()
            let found = present.filter { slot in
                guard slot != aim, let p = at(slot) else { return false }
                let (px, py) = (Double(p.x - s.x), Double(p.y - s.y))
                let along = (px * ux + py * uy) / length, across = abs(px * uy - py * ux) / length
                return across <= Double(size * 8) && along >= 0 && (!box || along <= length)
            }
            return withAnchor(aim, found)
        }
    }

    static func inside(_ p: Point, _ a: Point, _ b: Point, _ c: Point) -> Bool {
        func cross(_ o: Point, _ u: Point, _ v: Point) -> Int { (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x) }
        let d = [cross(a, b, p), cross(b, c, p), cross(c, a, p)]
        return d.allSatisfy { $0 >= 0 } || d.allSatisfy { $0 <= 0 }
    }
}
