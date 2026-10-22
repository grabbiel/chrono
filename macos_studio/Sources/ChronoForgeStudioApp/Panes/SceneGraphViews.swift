// SceneGraphViews.swift — Module 8's node graph of a raised event pack:
// one column per object, one node per function (functions sharing an entry
// are one node), calls as arrows labelled with their mode and level
// (CTSceneGraph; Evt_Op02-07 in event_vm_isa.json).
import SwiftUI
import ChronoForgeCore

struct SceneNodeGraph: View {
    let analysis: CTSceneAnalysis
    @Binding var selection: SceneSelection
    @State private var onlySelected = false

    private static let nodeW: CGFloat = 150, nodeH: CGFloat = 34, colW: CGFloat = 190, rowH: CGFloat = 46

    private var graph: CTSceneGraph { CTSceneGraph(analysis) }

    var body: some View {
        let g = graph
        let rows = Dictionary(grouping: g.nodes, by: \.object).mapValues { $0.sorted { $0.function < $1.function } }
        func origin(_ n: CTSceneGraph.Node) -> CGPoint? {
            guard let r = rows[n.object]?.firstIndex(of: n) else { return nil }
            return CGPoint(x: 20 + CGFloat(n.object) * Self.colW, y: 40 + CGFloat(r) * Self.rowH)
        }
        let height = 80 + CGFloat(rows.values.map(\.count).max() ?? 1) * Self.rowH
        let width = 40 + CGFloat(analysis.objectCount) * Self.colW
        let edges = g.edges.filter { e in
            !onlySelected || selection.object == nil || e.from.object == selection.object || e.to?.object == selection.object
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(g.nodes.count) functions · \(g.edges.count) calls").font(.caption).foregroundStyle(.secondary)
                Toggle("Only the selected object's calls", isOn: $onlySelected).toggleStyle(.checkbox).font(.caption)
            }
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, _ in
                        for k in 0..<analysis.objectCount {
                            let x = 20 + CGFloat(k) * Self.colW
                            ctx.draw(Text("obj \(k) · \(analysis.objects[k].kind)").font(.caption.bold()),
                                     at: CGPoint(x: x + Self.nodeW / 2, y: 18))
                        }
                        for e in edges {
                            guard let a = origin(e.from) else { continue }
                            let start = CGPoint(x: a.x + Self.nodeW, y: a.y + Self.nodeH / 2)
                            let end: CGPoint
                            if let to = e.to, let b = origin(to) {
                                end = CGPoint(x: b.x, y: b.y + Self.nodeH / 2)
                            } else {
                                end = CGPoint(x: start.x + 30, y: start.y - 14)       // a party member: no node here
                            }
                            let hot = selection.object == e.from.object && selection.function == e.from.function
                                || (e.to.map { selection.object == $0.object && selection.function == $0.function } ?? false)
                            var p = Path()
                            p.move(to: start)
                            p.addCurve(to: end, control1: CGPoint(x: start.x + 50, y: start.y),
                                       control2: CGPoint(x: end.x - 50, y: end.y))
                            p.move(to: CGPoint(x: end.x - 7, y: end.y - 4)); p.addLine(to: end)
                            p.addLine(to: CGPoint(x: end.x - 7, y: end.y + 4))
                            let color: Color = e.mode == .wait ? .orange : e.mode == .retry ? .yellow : .accentColor
                            ctx.stroke(p, with: .color(color.opacity(hot ? 1 : 0.45)),
                                       style: StrokeStyle(lineWidth: hot ? 2.5 : 1.2, dash: e.mode == .start ? [4, 3] : []))
                            if hot || edges.count < 40 {
                                let label = "\(e.mode.rawValue) L\(e.level)" + (e.member.map { " PC\($0)" } ?? "")
                                ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(color),
                                         at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 - 6))
                            }
                        }
                    }
                    ForEach(g.nodes) { n in
                        if let o = origin(n) { node(n).offset(x: o.x, y: o.y) }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
            }
            Text("Arrows: calls (solid wait, yellow retry, dashed start) with the level they run at; 0 is the most urgent.")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func node(_ n: CTSceneGraph.Node) -> some View {
        let o = analysis.objects[n.object]
        let isCont = n.function == CTSceneGraph.continuation
        let f = isCont ? nil : o.functions[n.function]
        let aliases = o.functions.filter { $0.alias == n.function }.count
        let title = isCont ? "continuation" : "func \(n.function) \(CTSceneAnalysis.role(n.function))" + (aliases > 0 ? " +\(aliases)" : "")
        let count = isCont ? o.continuation.count : f?.statements.count ?? 0
        let selected = selection.object == n.object && selection.function == n.function
        return VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption.bold()).lineLimit(1)
            Text("\(count) statements").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 6)
        .frame(width: Self.nodeW, height: Self.nodeH, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .secondary.opacity(0.4)))
        .onTapGesture {
            let entry = isCont ? o.continuation.first : f.map(\.entry)
            selection = SceneSelection(object: n.object, function: n.function, offset: entry)
        }
    }
}
