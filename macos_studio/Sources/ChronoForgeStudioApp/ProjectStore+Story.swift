// ProjectStore+Story.swift — the Story pane's flag registry and world graph.
import Foundation
import ChronoForgeCore

extension ProjectStore {
    /// story/flags.json and story/graph.json, when the project has them.
    func loadStory() -> (registry: CTStoryRegistry?, graph: CTEraGraph?) {
        guard let project else { return (nil, nil) }
        do {
            return (try CTStoryRegistry.load(project: project.url), try CTEraGraph.load(project: project.url))
        } catch {
            statusMessage = "story load failed: \(error)"
            statusIsError = true
            return (nil, nil)
        }
    }

    /// Scans the ROM's event packs into the registry and the graph (keeping
    /// names and notes) and writes the registry's bit flags into project.json.
    func importStory(rom url: URL) -> (registry: CTStoryRegistry, graph: CTEraGraph)? {
        guard var candidate = project else { return nil }
        do {
            let result = try CTStory.importStory(rom: [UInt8](Data(contentsOf: url)), project: &candidate)
            project = candidate
            statusMessage = "imported \(result.0.entries.count) story entries and \(result.1.edges.count) location changes"
            statusIsError = false
            return result
        } catch {
            statusMessage = "story import failed: \(error)"
            statusIsError = true
            return nil
        }
    }

    /// Names or annotates a registry entry; its name becomes a project flag too.
    func annotateStory(_ registry: CTStoryRegistry, symbol: String, name: String, notes: String) -> CTStoryRegistry? {
        guard var candidate = project else { return nil }
        var updated = registry
        do {
            try updated.annotate(symbol: symbol, name: name, notes: notes, project: candidate.project)
            updated.sync(into: &candidate.project)
            try updated.save(project: candidate.url)
            try candidate.save()
            project = candidate
            statusMessage = "saved \(symbol)"
            statusIsError = false
            return updated
        } catch {
            statusMessage = "annotation failed: \(error)"
            statusIsError = true
            return nil
        }
    }

    /// Names an inferred era group (empty: unnamed).
    func nameEraGroup(_ graph: CTEraGraph, seed: Int, name: String) -> CTEraGraph? {
        guard let project, let i = graph.groups.firstIndex(where: { $0.seed == seed }) else { return nil }
        var updated = graph
        let name = name.trimmingCharacters(in: .whitespaces)
        updated.groups[i].name = name.isEmpty ? nil : name
        do {
            try updated.save(project: project.url)
            statusMessage = "saved the group name"
            statusIsError = false
            return updated
        } catch {
            statusMessage = "save failed: \(error)"
            statusIsError = true
            return nil
        }
    }
}
