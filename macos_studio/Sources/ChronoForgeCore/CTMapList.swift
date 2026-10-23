// CTMapList.swift — the maps a ROM build writes (project.json rom.maps) and
// what a build of them would leave (docs/maps.md, "Listing maps in a build"):
// a dry run of CTROMBuilder on the base ROM, whose free space, TreasureRom
// placement and flag count, or first refusal, the Studio and `chronoforge maps
// rom-list --base` show before anything is written.
import Foundation

public enum CTMapList {
    /// Puts `ids` in rom.maps (or takes them out) and returns the ones that changed.
    @discardableResult
    public static func set(_ ids: [String], listed: Bool, in project: inout CTProject) throws -> [String] {
        var spec = project.project.rom ?? Project.ROMBuild()
        var changed: [String] = []
        for id in ids {
            guard let m = project.maps[id] else { throw CTROMBuildError("no map \(id)") }
            guard m.rom != nil else { throw CTROMBuildError("\(id) has no ROM location to write") }
            if listed, !spec.maps.contains(id) {
                spec.maps.append(id); changed.append(id)
            } else if !listed, let k = spec.maps.firstIndex(of: id) {
                spec.maps.remove(at: k); changed.append(id)
            }
        }
        project.project.rom = spec
        return changed
    }

    public static func listed(_ project: CTProject) -> [String] { project.project.rom?.maps ?? [] }

    public struct Budget: Equatable, Sendable {
        public var maps: Int                       // maps the build writes
        public var freeBytesLeft: Int?
        public var treasure: CTTreasure.ReportBlock?
        public var flags: [String: [Int]]          // the listed maps' chest flags
        public var refusal: String?                // the build's first refusal
        public init(maps: Int, freeBytesLeft: Int?, treasure: CTTreasure.ReportBlock?, flags: [String: [Int]], refusal: String? = nil) {
            self.maps = maps; self.freeBytesLeft = freeBytesLeft; self.treasure = treasure; self.flags = flags; self.refusal = refusal
        }
    }

    /// What building the project on `base` would give, without writing anything.
    public static func budget(base: [UInt8], project: CTProject) -> Budget {
        let maps = listed(project).count
        do {
            let (_, report) = try CTROMBuilder.build(base: base, project: project)
            var flags: [String: [Int]] = [:]
            for m in report.maps ?? [] { if let f = m.flags { flags[m.id] = f } }
            return Budget(maps: maps, freeBytesLeft: report.freeBytesLeft, treasure: report.treasureRom, flags: flags)
        } catch {
            return Budget(maps: maps, freeBytesLeft: nil, treasure: nil, flags: [:], refusal: "\(error)")
        }
    }
}
