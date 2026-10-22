// The world graph: locations joined by the location changes event scripts
// perform, each with its flag guards, and era groups inferred from it
// (story/graph.json, ct-story-graph/1). Locations $1F0 and up go to bank $C2
// (GameLoop_Main, Loc_FirstBankC2): each one the scripts reach seeds a group,
// and other locations join the nearest seed over event edges. Groups are
// unnamed until the maintainer names them. See docs/story.md.
import Foundation

public struct CTEraGraph: Codable, Equatable, Sendable {
    public static let schema = "ct-story-graph/1"
    public static let path = "story/graph.json"

    public var schema: String = CTEraGraph.schema
    public var edges: [Edge]
    public var groups: [Group]
    /// Locations with event edges to three or more groups (inferred hubs).
    public var hubs: [Int]

    public struct Edge: Codable, Equatable, Sendable, Identifiable {
        public var from: Int
        public var to: Int
        public var kind: String
        public var entry: Int               // Evt_PackPtrs index of the script's pack
        public var offset: Int
        public var x: Int?, y: Int?
        public var guards: [CTStory.Guard]
        /// The two ends are in different groups: a candidate time-travel
        /// transition (inferred).
        public var crossGroup: Bool
        public var id: String { "\(from)-\(to)-\(entry)-\(offset)" }
    }

    public struct Group: Codable, Equatable, Sendable, Identifiable {
        public var seed: Int                // a bank-$C2 location
        public var name: String?            // the maintainer's
        public var locations: [Int]
        public var inferred: Bool = true
        public var id: Int { seed }
    }

    public func group(of location: Int) -> Group? { groups.first { $0.locations.contains(location) } }

    public static func build(warps: [CTStory.Warp], previous: CTEraGraph? = nil) -> CTEraGraph {
        var edges: [Edge] = []
        for w in warps where w.dest != nil && w.kind != "setPrevLoc" {
            for source in w.site.locations {
                edges.append(Edge(from: source, to: w.dest!, kind: w.kind, entry: w.site.entry, offset: w.site.offset,
                                  x: w.x, y: w.y, guards: w.guards, crossGroup: false))
            }
        }
        var adjacent: [Int: Set<Int>] = [:]
        for e in edges where e.from != e.to {
            adjacent[e.from, default: []].insert(e.to)
            adjacent[e.to, default: []].insert(e.from)
        }
        let seeds = Set(edges.flatMap { [$0.from, $0.to] }).filter { $0 >= CTStory.firstBankC2Location }.sorted()
        var distance: [Int: [Int: Int]] = [:]
        for s in seeds {
            var d = [s: 0], frontier = [s]
            while !frontier.isEmpty {
                var next: [Int] = []
                for n in frontier {
                    for m in adjacent[n] ?? [] where d[m] == nil && m < CTStory.firstBankC2Location {
                        d[m] = d[n]! + 1
                        next.append(m)
                    }
                }
                frontier = next
            }
            distance[s] = d
        }
        var member: [Int: Int] = [:]
        for s in seeds { member[s] = s }
        for n in 0..<CTStory.firstBankC2Location {
            let best = seeds.compactMap { s in distance[s]![n].map { ($0, s) } }.sorted { $0 < $1 }
            if let first = best.first, best.count == 1 || first.0 < best[1].0 { member[n] = first.1 }
        }
        for i in edges.indices {
            if let a = member[edges[i].from], let b = member[edges[i].to] { edges[i].crossGroup = a != b }
        }
        let names = Dictionary((previous?.groups ?? []).map { ($0.seed, $0.name) }, uniquingKeysWith: { a, _ in a })
        let groups = seeds.map { s in
            Group(seed: s, name: names[s] ?? nil, locations: member.filter { $0.value == s }.keys.sorted())
        }
        let hubs = adjacent.keys.filter { n in Set(adjacent[n]!.compactMap { member[$0] }).count >= 3 }.sorted()
        return CTEraGraph(edges: edges, groups: groups, hubs: hubs)
    }

    public static func load(project url: URL) throws -> CTEraGraph? {
        let file = url.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let doc = try CTProject.jsonDecoder.decode(CTEraGraph.self, from: Data(contentsOf: file))
        guard doc.schema == schema else { throw CTProjectError.badFormat("\(path): schema \(doc.schema)") }
        return doc
    }

    public func save(project url: URL) throws {
        let file = url.appendingPathComponent(Self.path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try CTProject.jsonEncoder.encode(self).write(to: file, options: .atomic)
    }
}

public extension CTStory {
    /// Scans the ROM and writes story/flags.json and story/graph.json into the
    /// project (keeping names and notes), and the registry's bit flags into
    /// project.json. `code`: references outside the event VM (nil: the ROM's
    /// long-address patterns).
    static func importStory(rom: [UInt8], project: inout CTProject, code: [CodeReference]? = nil) throws
        -> (CTStoryRegistry, CTEraGraph) {
        let scan = try scan(rom: rom)
        let sha = CTEventPack.sha256(rom)
        let registry = CTStoryRegistry.build(scan: scan, code: code ?? longAddressPatterns(rom: rom), romSHA256: sha,
                                             previous: try CTStoryRegistry.load(project: project.url))
        let graph = CTEraGraph.build(warps: scan.warps, previous: try CTEraGraph.load(project: project.url))
        registry.sync(into: &project.project)
        try registry.save(project: project.url)
        try graph.save(project: project.url)
        try project.save()
        return (registry, graph)
    }
}
