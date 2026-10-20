// CTProject.swift — .ctproj directory-bundle loader/saver.
import Foundation

public enum CTProjectError: Error, CustomStringConvertible {
    case notFound(String), badFormat(String)
    public var description: String {
        switch self {
        case .notFound(let s): return "ctproj member not found: \(s)"
        case .badFormat(let s): return "ctproj bad format: \(s)"
        }
    }
}

public struct CTProject: Sendable {
    public var url: URL                 // the .ctproj directory
    public var project: Project
    public var characters: [String: CharacterDef]
    public var sprites: [String: SpriteDef]
    public var items: [String: ItemDef]
    public var techs: [String: TechDef]
    public var dialogue: Dialogue
    public var tracks: [String: Track]
    public var samples: [String: SampleMeta]
    public var tilesets: [String: Tileset]
    public var maps: [String: GameMap]
    public var scenes: [String: SceneDoc]
    public var textProfile: CTTextProfile? = nil

    public static let jsonDecoder: JSONDecoder = JSONDecoder()
    public static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static func decode<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard let data = try? Data(contentsOf: url) else { throw CTProjectError.notFound(url.path) }
        do { return try jsonDecoder.decode(T.self, from: data) }
        catch { throw CTProjectError.badFormat("\(url.lastPathComponent): \(error)") }
    }
    static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try jsonEncoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    // MARK: Load
    public static func load(from url: URL) throws -> CTProject {
        let project: Project = try decode(Project.self, from: url.appendingPathComponent("project.json"))
        func loadDir<T: Decodable>(_ type: T.Type, dir: String, suffix: String = ".json",
                                   idFrom: @escaping (URL) -> String) throws -> [String: T] {
            var out: [String: T] = [:]
            let d = url.appendingPathComponent(dir)
            let files = (try? FileManager.default.contentsOfDirectory(at: d,
                includingPropertiesForKeys: nil))?.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            for f in files where f.lastPathComponent.hasSuffix(suffix) && !f.hasDirectoryPath {
                out[idFrom(f)] = try decode(T.self, from: f)
            }
            return out
        }
        let characters: [String: CharacterDef] = try loadDir(CharacterDef.self, dir: "characters") {
            String($0.deletingPathExtension().lastPathComponent)
        }
        let sprites: [String: SpriteDef] = try loadDir(SpriteDef.self, dir: "sprites", suffix: ".sprite.json") {
            $0.deletingPathExtension().deletingPathExtension().lastPathComponent
        }
        let items: [String: ItemDef] = try loadDir(ItemDef.self, dir: "items") {
            String($0.deletingPathExtension().lastPathComponent)
        }
        let techs: [String: TechDef] = try loadDir(TechDef.self, dir: "techs") {
            String($0.deletingPathExtension().lastPathComponent)
        }
        var dialogue = Dialogue(strings: [:])
        let dialURL = url.appendingPathComponent("strings/dialogue.json")
        if FileManager.default.fileExists(atPath: dialURL.path) {
            dialogue = try decode(Dialogue.self, from: dialURL)
        }
        let tracks: [String: Track] = try loadDir(Track.self, dir: "audio/tracks", suffix: ".akao.json") {
            $0.deletingPathExtension().deletingPathExtension().lastPathComponent
        }
        let samples: [String: SampleMeta] = try loadDir(SampleMeta.self, dir: "audio/samples") {
            String($0.deletingPathExtension().lastPathComponent)
        }
        let tilesets: [String: Tileset] = try loadDir(Tileset.self, dir: "tilesets", suffix: ".tileset.json") {
            $0.deletingPathExtension().deletingPathExtension().lastPathComponent
        }
        let maps: [String: GameMap] = try loadDir(GameMap.self, dir: "maps", suffix: ".map.json") {
            $0.deletingPathExtension().deletingPathExtension().lastPathComponent
        }
        var scenes: [String: SceneDoc] = try loadDir(SceneDoc.self, dir: "scenes", suffix: ".event.json") {
            $0.deletingPathExtension().deletingPathExtension().lastPathComponent
        }
        // DSL is authoritative when present; JSON retains graph metadata.
        for id in scenes.keys.sorted() {
            guard scenes[id]!.id == id else { throw CTProjectError.badFormat("scene ID differs from filename: \(id)") }
            let sourceURL = url.appendingPathComponent("scenes/\(id).event.dsl")
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                do {
                    var parsed = try EventDSL.parse(String(contentsOf: sourceURL, encoding: .utf8))
                    let cached = scenes[id]!.scene
                    if parsed.funcs == cached.funcs { parsed.layout = cached.layout }
                    scenes[id]!.scene = parsed
                } catch { throw CTProjectError.badFormat("\(id).event.dsl: \(error)") }
            }
        }
        for doc in scenes.values { try EventBytecode.validate(doc.scene) }
        let profileURL = url.appendingPathComponent("strings/ct-text-profile.json")
        let profile: CTTextProfile? = FileManager.default.fileExists(atPath: profileURL.path)
            ? try decode(CTTextProfile.self, from: profileURL) : nil
        try profile?.validate()
        return CTProject(url: url, project: project, characters: characters, sprites: sprites,
                         items: items, techs: techs, dialogue: dialogue, tracks: tracks,
                         samples: samples, tilesets: tilesets, maps: maps, scenes: scenes, textProfile: profile)
    }

    // MARK: Save (keys ordered by the Studio on save; 2-space indent via prettyPrinted)
    public func save() throws {
        try textProfile?.validate()
        // Preflight all scenes before touching project files.
        var sceneSources: [String: Data] = [:]
        for (id, doc) in scenes {
            guard id == doc.id, !id.isEmpty, !id.contains("/"), id != ".", id != ".." else {
                throw CTProjectError.badFormat("invalid scene ID \(id)")
            }
            try EventBytecode.validate(doc.scene)
            sceneSources[id] = Data(EventDSL.format(doc.scene).utf8)
        }
        let fm = FileManager.default
        func dir(_ p: String) throws { try fm.createDirectory(at: url.appendingPathComponent(p), withIntermediateDirectories: true) }
        try dir(""); try dir("characters"); try dir("sprites"); try dir("items"); try dir("techs")
        try dir("strings"); try dir("audio/tracks"); try dir("audio/samples")
        try dir("tilesets"); try dir("maps"); try dir("scenes")
        try CTProject.encode(project, to: url.appendingPathComponent("project.json"))
        for (id, c) in characters { try CTProject.encode(c, to: url.appendingPathComponent("characters/\(id).json")) }
        for (id, s) in sprites { try CTProject.encode(s, to: url.appendingPathComponent("sprites/\(id).sprite.json")) }
        for (id, i) in items { try CTProject.encode(i, to: url.appendingPathComponent("items/\(id).json")) }
        for (id, t) in techs { try CTProject.encode(t, to: url.appendingPathComponent("techs/\(id).json")) }
        try CTProject.encode(dialogue, to: url.appendingPathComponent("strings/dialogue.json"))
        if let textProfile {
            try CTProject.encode(textProfile, to: url.appendingPathComponent("strings/ct-text-profile.json"))
        }
        for (id, t) in tracks { try CTProject.encode(t, to: url.appendingPathComponent("audio/tracks/\(id).akao.json")) }
        for (id, s) in samples { try CTProject.encode(s, to: url.appendingPathComponent("audio/samples/\(id).json")) }
        for (id, t) in tilesets { try CTProject.encode(t, to: url.appendingPathComponent("tilesets/\(id).tileset.json")) }
        for (id, m) in maps { try CTProject.encode(m, to: url.appendingPathComponent("maps/\(id).map.json")) }
        for (id, s) in scenes {
            try CTProject.encode(s, to: url.appendingPathComponent("scenes/\(id).event.json"))
            try sceneSources[id]!.write(to: url.appendingPathComponent("scenes/\(id).event.dsl"), options: .atomic)
        }
    }

    // MARK: Asset access
    public func fileURL(relative: String) -> URL { url.appendingPathComponent(relative) }

    /// Tile index bytes for a tileset: from its planar .bin blob or its
    /// indexed PNG sheet (8x8 blocks, row-major).
    public func tileIndices(of ts: Tileset) throws -> [UInt8] {
        if let blob = ts.blob {
            let data = try Data(contentsOf: fileURL(relative: blob))
            return TileDecoder.decodeIndices([UInt8](data), depth: ts.bpp == 2 ? .bpp2 : .bpp4,
                                             tileCount: ts.tileCount)
        }
        if let sheet = ts.sheet {
            let png = try PNG.readIndexed(url: fileURL(relative: sheet))
            let cols = png.width / 8
            var out = [UInt8](repeating: 0, count: ts.tileCount * 64)
            for t in 0..<ts.tileCount {
                let tx = (t % cols) * 8, ty = (t / cols) * 8
                for r in 0..<8 {
                    for c in 0..<8 {
                        out[t * 64 + r * 8 + c] = png.indices[(ty + r) * png.width + tx + c]
                    }
                }
            }
            return out
        }
        throw CTProjectError.notFound("tileset \(ts.id): no blob or sheet")
    }
}
