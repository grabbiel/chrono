// StoryRegistryViews.swift — Module 9's flag registry manager and era graph.
import SwiftUI
import AppKit
import ChronoForgeCore

/// Search, filter, inspect and annotate story/flags.json.
struct StoryFlagRegistryView: View {
    let store: ProjectStore
    @Binding var registry: CTStoryRegistry
    let graph: CTEraGraph?
    @Binding var selection: String?
    @Binding var location: Int?
    @State private var search = ""
    @State private var kind = "All"
    @State private var era: Int?

    private var entries: [CTStoryRegistry.Entry] {
        let needle = search.lowercased()
        let eraLocations = era.flatMap { seed in graph?.groups.first { $0.seed == seed } }.map { Set($0.locations) }
        return registry.entries.filter { e in
            (kind == "All" || (kind == "Bits") == e.isBit || (kind == "Named" && e.name != nil))
                && (needle.isEmpty || e.symbol.lowercased().contains(needle) || e.addr.lowercased().contains(needle)
                    || (e.name?.lowercased().contains(needle) ?? false) || (e.notes?.lowercased().contains(needle) ?? false))
                && (location.map { e.locations.contains($0) } ?? true)
                && (eraLocations.map { !$0.isDisjoint(with: e.locations) } ?? true)
        }
    }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Search symbol, name, address or notes", text: $search).textFieldStyle(.roundedBorder)
                HStack {
                    Picker("", selection: $kind) {
                        ForEach(["All", "Bits", "Bytes", "Named"], id: \.self) { Text($0) }
                    }.labelsHidden().frame(width: 90)
                    TextField("location", value: $location, format: .number).frame(width: 70)
                    Picker("Era", selection: $era) {
                        Text("Any era").tag(Int?.none)
                        ForEach(graph?.groups ?? []) { g in Text(g.name ?? String(format: "group $%03X", g.seed)).tag(Int?.some(g.seed)) }
                    }.frame(width: 170)
                }
                let shown = entries
                List(shown, selection: $selection) { e in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.name ?? e.symbol).font(.system(.body, design: .monospaced))
                        Text("\(e.addr)\(e.bit.map { ".\($0)" } ?? "")  " + CTStory.Kind.allCases.compactMap { k in
                            e.counts[k.rawValue].map { "\(k.rawValue) \($0)" } }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }.tag(e.symbol)
                }
                Text("\(shown.count) of \(registry.entries.count) entries · \(registry.unused.count) unused bytes · "
                     + "\(registry.totals.references) references in \(registry.totals.packs) packs")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(minWidth: 320, idealWidth: 380)
            Group {
                if let symbol = selection, let entry = registry.entries.first(where: { $0.symbol == symbol }) {
                    StoryFlagDetail(store: store, registry: $registry, entry: entry).id(symbol)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Unused bytes").font(.headline)
                        ScrollView {
                            Text(registry.unused.joined(separator: "  ")).font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.padding()
                }
            }
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private struct StoryFlagDetail: View {
    let store: ProjectStore
    @Binding var registry: CTStoryRegistry
    let entry: CTStoryRegistry.Entry
    @State private var name = ""
    @State private var notes = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.symbol).font(.title3.monospaced()).textSelection(.enabled)
            Text("\(entry.addr)\(entry.bit.map { " bit \($0)" } ?? " (byte)") · \(entry.locations.count) locations"
                 + (entry.isBit ? " · a project flag: scenes use this symbol" : ""))
                .foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("only with evidence"))
                TextField("Notes", text: $notes, axis: .vertical).lineLimit(2...5)
            }
            HStack {
                Text("A name becomes a second flag symbol on the same bit; the generated symbol stays.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Save") {
                    if let updated = store.annotateStory(registry, symbol: entry.symbol, name: name, notes: notes) {
                        registry = updated
                    }
                }.keyboardShortcut("s", modifiers: .command)
            }
            Text("Event references").font(.headline)
            Table(entry.references.indices.map { Row(index: $0, reference: entry.references[$0]) }) {
                TableColumn("Locations") { Text($0.reference.site.locations.map { String(format: "$%03X", $0) }.joined(separator: " ")) }
                TableColumn("Pack") { Text("\($0.reference.site.entry)") }.width(44)
                TableColumn("Obj.func") { Text($0.reference.site.functions.prefix(3).map { "\($0[0]).\($0[1])" }.joined(separator: " ")) }
                TableColumn("Offset") { Text(String(format: "$%04X", $0.reference.site.offset)).monospaced() }.width(56)
                TableColumn("Opcode") { Text(CTEventISA.opcodes[$0.reference.site.opcode].name) }
                TableColumn("Kind") { r in Text(r.reference.access.kind.rawValue + (r.reference.access.cmp.map { " \($0) \(r.reference.access.value ?? 0)" } ?? "")) }
            }
            .frame(minHeight: 160)
            if !entry.code.isEmpty {
                Text("Code outside the event VM").font(.headline)
                List(entry.code.indices, id: \.self) { i in
                    let c = entry.code[i]
                    Text("\(c.status) · \(c.where_) · \(c.mnemonic)\(c.routine.map { " · \($0)" } ?? "")")
                        .font(.system(.caption, design: .monospaced))
                }.frame(minHeight: 60, maxHeight: 140)
            }
            HStack {
                Text("ROM scripts are not Studio scenes: the Scenes pane cannot open them. Disassemble a pack with")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Copy command") {
                    let pack = entry.references.first?.site.entry ?? 0
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("chronoforge event disasm <rom.sfc> \(pack)", forType: .string)
                }.controlSize(.small)
            }
        }
        .padding()
        .onAppear { name = entry.name ?? ""; notes = entry.notes ?? "" }
    }

    struct Row: Identifiable {
        let index: Int
        let reference: CTStory.Reference
        var id: Int { index }
    }
}

/// Locations in inferred era groups, joined by the event scripts' location changes.
struct StoryEraGraphView: View {
    let store: ProjectStore
    @Binding var graph: CTEraGraph
    @Binding var location: Int?
    let showFlags: (Int) -> Void
    @State private var names: [Int: String] = [:]

    private static let cell = CGSize(width: 46, height: 30), perRow = 4, columnGap: CGFloat = 36, top: CGFloat = 34

    /// Columns: each group, then the locations with edges but no group.
    private var columns: [(title: String, seed: Int?, nodes: [Int])] {
        let grouped = Set(graph.groups.flatMap(\.locations))
        let loose = Set(graph.edges.flatMap { [$0.from, $0.to] }).subtracting(grouped).sorted()
        return graph.groups.map { (($0.name ?? String(format: "group $%03X", $0.seed)) + " (inferred)", $0.seed, $0.locations) }
            + [("ungrouped", nil, loose)]
    }

    private var positions: [Int: CGPoint] {
        var out: [Int: CGPoint] = [:]
        var x: CGFloat = 12
        for column in columns {
            for (i, n) in column.nodes.enumerated() {
                out[n] = CGPoint(x: x + CGFloat(i % Self.perRow) * Self.cell.width + Self.cell.width / 2,
                                 y: Self.top + CGFloat(i / Self.perRow) * Self.cell.height + Self.cell.height / 2)
            }
            x += CGFloat(Self.perRow) * Self.cell.width + Self.columnGap
        }
        return out
    }

    var body: some View {
        let positions = self.positions, columns = self.columns
        let width = CGFloat(columns.count) * (CGFloat(Self.perRow) * Self.cell.width + Self.columnGap) + 24
        let rows = ((columns.map(\.nodes.count).max() ?? 0) + Self.perRow - 1) / Self.perRow
        let height = Self.top + CGFloat(rows + 1) * Self.cell.height
        HSplitView {
            ScrollView([.horizontal, .vertical]) {
                Canvas { context, _ in
                    var x: CGFloat = 12
                    for column in columns {
                        context.draw(Text(column.title).font(.caption.bold()), at: CGPoint(x: x, y: 12), anchor: .leading)
                        x += CGFloat(Self.perRow) * Self.cell.width + Self.columnGap
                    }
                    for e in graph.edges {
                        guard let a = positions[e.from], let b = positions[e.to], e.from != e.to else { continue }
                        let selected = location == e.from || location == e.to
                        var path = Path()
                        path.move(to: a)
                        path.addLine(to: b)
                        let color: Color = e.crossGroup ? .orange : selected ? .accentColor : .secondary.opacity(0.25)
                        context.stroke(path, with: .color(color),
                                       style: StrokeStyle(lineWidth: selected || e.crossGroup ? 1.6 : 0.7,
                                                          dash: e.guards.isEmpty ? [] : [3, 2]))
                    }
                    for (n, p) in positions {
                        let rect = CGRect(x: p.x - 19, y: p.y - 10, width: 38, height: 20)
                        let hub = graph.hubs.contains(n)
                        context.fill(Path(roundedRect: rect, cornerRadius: 5),
                                     with: .color(n == location ? .accentColor : hub ? .purple.opacity(0.35) : .gray.opacity(0.18)))
                        context.draw(Text(String(format: "%03X", n)).font(.system(size: 10, design: .monospaced)), at: p)
                    }
                }
                .frame(width: width, height: max(height, 300))
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { point in
                    location = positions.min { hypot($0.value.x - point.x, $0.value.y - point.y)
                        < hypot($1.value.x - point.x, $1.value.y - point.y) }
                        .flatMap { hypot($0.value.x - point.x, $0.value.y - point.y) < 24 ? $0.key : nil }
                }
            }
            .frame(minWidth: 480)
            VStack(alignment: .leading, spacing: 8) {
                Text("Groups").font(.headline)
                Text("Seeded by the bank-$C2 locations the scripts reach ($1F0+); others join the nearest. Inferred: name them only with evidence.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(graph.groups) { g in
                    HStack {
                        Text(String(format: "$%03X", g.seed)).monospaced()
                        TextField("name", text: Binding(get: { names[g.seed] ?? g.name ?? "" }, set: { names[g.seed] = $0 }))
                            .onSubmit { if let updated = store.nameEraGroup(graph, seed: g.seed, name: names[g.seed] ?? "") { graph = updated } }
                        Text("\(g.locations.count)").foregroundStyle(.secondary)
                    }
                }
                Divider()
                if let loc = location {
                    HStack {
                        Text(String(format: "Location $%03X", loc)).font(.headline)
                        Spacer()
                        Button("Flags here") { showFlags(loc) }
                    }
                    let edges = graph.edges.filter { $0.from == loc || $0.to == loc }
                    List(edges) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "$%03X → $%03X  %@ (%d,%d)%@", e.from, e.to, e.kind, e.x ?? 0, e.y ?? 0,
                                        e.crossGroup ? "  cross-group" : "")).monospaced()
                            Text(String(format: "pack %d $%04X", e.entry, e.offset)
                                 + (e.guards.isEmpty ? "  unguarded" : "  if " + e.guards.map { g in
                                     String(format: "7F:%04X", g.addr) + (g.bit.map { ".\($0)" } ?? " \(g.cmp ?? "") \(g.value ?? 0)")
                                         + (g.holds ? "" : " fails") }.joined(separator: ", ")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("\(graph.edges.count) edges · \(graph.edges.filter(\.crossGroup).count) cross-group (orange) · "
                         + "\(graph.edges.filter { !$0.guards.isEmpty }.count) guarded (dashed) · hubs purple. Click a location.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .padding()
            .frame(minWidth: 300, idealWidth: 340)
        }
    }
}
