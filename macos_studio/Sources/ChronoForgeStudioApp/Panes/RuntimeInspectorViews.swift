// RuntimeInspectorViews.swift — the Play window's inspector: each object's
// function, call level, position, wait state and call stack; the party,
// gold, items, palette animation and stopped objects (State); the story
// flags by registry symbol, highlighted when they change, with the
// instruction that changed them, editable as the flags a run starts with;
// breakpoints on a flag or an instruction; and the change log.
import SwiftUI
import ChronoForgeCore

/// The function of `object` whose start is the nearest at or before `pos`.
private func functionLabel(_ pack: CTEventPack, object o: Int, pos: Int) -> String {
    guard o < pack.functions.count else { return "" }
    let starts = pack.functions[o].enumerated().filter { $0.element <= pos }
    guard let best = starts.max(by: { $0.element < $1.element }) else { return "" }
    return "f\(best.offset)"
}

struct RuntimeObjectsView: View {
    let session: RuntimeSession

    var body: some View {
        let _ = session.revision
        let field = session.field, pack = field.vm.pack
        let leader = field.vm.wram[WRAM.partyObjSlot]
        List {
            ForEach(0..<pack.objectCount, id: \.self) { o in
                let s = field.objectState(o)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("obj \(o)").bold().frame(width: 52, alignment: .leading)
                        Text(String(format: "kind $%02X", s.kind)).foregroundStyle(s.kind & 0x80 != 0 ? .secondary : .primary)
                        if Int(leader) == 2 * o { Text("leader").font(.caption).foregroundStyle(.blue) }
                        if s.active { Image(systemName: "eye").font(.caption) }
                        Spacer()
                        Text(functionLabel(pack, object: o, pos: s.scriptPos) + String(format: " $%04X", s.scriptPos))
                            .monospaced()
                        Text("level \(s.level)").monospaced()
                    }
                    HStack(spacing: 10) {
                        Text("tile \(s.tileX),\(s.tileY)")
                        Text(String(format: "pos $%04X,$%04X", s.posX, s.posY))
                        Text("facing \(s.facing)")
                        if s.moveFrames > 0 { Text("moving \(s.moveFrames)") }
                        if s.waitTimer > 0 { Text("wait \(s.waitTimer)") }
                        if let last = session.debugger.lastInstruction[o] { Text(String(format: "last $%04X op $%02X", last.offset, last.opcode)) }
                    }
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !s.callStack.isEmpty {
                        Text("stack: " + s.callStack.map { String(format: "level %d → $%04X", $0.level, $0.resume) }.joined(separator: ", "))
                            .font(.caption.monospaced())
                    }
                    if let why = s.stopped {
                        Text("stopped: \(why)").font(.caption).foregroundStyle(.red)
                    }
                }
            }
        }
    }
}

struct RuntimeFlagsView: View {
    let session: RuntimeSession
    @State private var showAll = false
    @State private var filter = ""

    private struct Row: Identifiable {
        var id: String { "\(address)#\(bit ?? -1)" }
        var address: Int, bit: Int?, name: String
    }

    private var rows: [Row] {
        if let reg = session.registry, !showAll {
            return reg.entries.map { Row(address: 0x7F0000 | $0.address, bit: $0.bit, name: $0.name ?? $0.symbol) }
                .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        }
        return (0..<0x200).map { 0x7F0000 + $0 }.map { Row(address: $0, bit: nil, name: session.flagName($0, bit: nil)) }
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        let _ = session.revision
        VStack(alignment: .leading) {
            HStack {
                TextField("Filter", text: $filter).frame(maxWidth: 180)
                Toggle("Every story byte", isOn: $showAll).disabled(session.registry == nil)
                Spacer()
                Button("Restart with these flags") { try? session.restart(location: session.location) }
                    .help("Edits set the flags a run starts with; Evt_InitObjects reads them, so they apply on restart.")
            }
            if session.registry == nil {
                Text("No story registry in the project (Story pane → Import Story from ROM): flags show by address.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            List(rows) { r in row(r) }
        }
    }

    private func row(_ r: Row) -> some View {
        let w = session.field.vm.wram
        let value = w[r.address]
        let recent = session.debugger.recentChanges(r.address, within: 120).first {
            r.bit == nil || ($0.old ^ $0.new) & UInt8(1 << (r.bit! & 7)) != 0
        }
        let start = session.startFlags[r.address]
        return HStack {
            Text(r.name).monospaced().frame(minWidth: 160, alignment: .leading)
            Text(String(format: "$%06X", r.address)).font(.caption.monospaced()).foregroundStyle(.secondary)
            if let bit = r.bit {
                Toggle("", isOn: Binding(get: { (start ?? value) & UInt8(1 << bit) != 0 }, set: { on in
                    var v = session.startFlags[r.address] ?? value
                    if on { v |= UInt8(1 << bit) } else { v &= ~UInt8(1 << bit) }
                    session.startFlags[r.address] = v
                })).labelsHidden().toggleStyle(.checkbox)
            } else {
                TextField("", value: Binding(get: { Int(start ?? value) }, set: { session.startFlags[r.address] = UInt8($0 & 0xFF) }),
                          format: .number).frame(width: 50)
            }
            if start != nil { Image(systemName: "pencil").foregroundStyle(.orange).help("set at the next restart") }
            Spacer()
            if let c = recent {
                Text(String(format: "frame %d: obj %d $%04X op $%02X  %02X→%02X", c.frame, c.object, c.offset, c.opcode, c.old, c.new))
                    .font(.caption.monospaced())
            }
            Menu {
                Button("Break when it changes") { session.debugger.breakpoints.insert(.flag(address: r.address, bit: r.bit)) }
            } label: { Image(systemName: "pause.circle") }.menuStyle(.borderlessButton).frame(width: 28)
        }
        .padding(.vertical, 1)
        .background(recent != nil ? Color.yellow.opacity(0.25) : Color.clear)
    }
}

struct RuntimeBreakpointsView: View {
    let session: RuntimeSession
    @State private var offset = ""
    @State private var object = ""

    var body: some View {
        let _ = session.revision
        VStack(alignment: .leading) {
            HStack {
                TextField("offset (hex)", text: $offset).frame(width: 100)
                TextField("object (any)", text: $object).frame(width: 100)
                Button("Break at instruction") {
                    if let o = Int(offset, radix: 16) {
                        session.debugger.breakpoints.insert(.instruction(offset: o, object: Int(object)))
                        offset = ""
                    }
                }
            }
            Text("Flag breakpoints: the pause button beside a flag (Flags tab).").font(.caption).foregroundStyle(.secondary)
            List(Array(session.debugger.breakpoints).sorted { "\($0)" < "\($1)" }, id: \.self) { b in
                HStack {
                    Text(RuntimeSession.describe(b)).monospaced()
                    Spacer()
                    Button("Remove", systemImage: "trash") { session.debugger.breakpoints.remove(b) }.labelStyle(.iconOnly)
                }
            }
            if let h = session.debugger.lastHit {
                Text("last hit: frame \(h.frame), object \(h.object) " + String(format: "$%04X op $%02X", h.offset, h.opcode))
                    .font(.caption.monospaced())
            }
        }
    }
}

struct RuntimeChangesView: View {
    let session: RuntimeSession

    var body: some View {
        let _ = session.revision
        List(session.debugger.changes.suffix(300).reversed()) { c in
            HStack {
                Text("frame \(c.frame)").frame(width: 80, alignment: .leading)
                Text(session.flagName(c.address, bit: nil)).frame(minWidth: 120, alignment: .leading)
                Text(String(format: "%02X→%02X", c.old, c.new))
                Spacer()
                Text(String(format: "obj %d $%04X op $%02X", c.object, c.offset, c.opcode)).foregroundStyle(.secondary)
            }
            .font(.caption.monospaced())
        }
    }
}

/// The state the opcodes change: the party (Menu_PartyOrder), gold and
/// items with the logged changes, the palette animator's records and the
/// colours the palette opcodes wrote, and the objects stopped (unmodelled
/// opcodes and the like) with why.
struct RuntimeStateView: View {
    let session: RuntimeSession

    private static let animKinds = ["none", "ROM frames", "rotate", "rotate up", "fade white", "fade",
                                    "pulse white", "pulse"]

    var body: some View {
        let _ = session.revision
        let field = session.field, vm = field.vm
        List {
            Section("Party") {
                let order = field.partyOrder
                HStack(spacing: 14) {
                    ForEach(0..<9, id: \.self) { k in
                        VStack(spacing: 2) {
                            Text(order[k].map { "PC \($0)" } ?? "—").monospaced()
                            Text(k < 3 ? "active" : "reserve").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Gold and items") {
                Text("gold \(field.gold)").monospaced()
                let items = field.inventory
                Text(items.isEmpty ? "no items" : items.prefix(40).map { String(format: "$%02X×%d", $0.item, $0.count) }
                        .joined(separator: "  "))
                    .font(.caption.monospaced()).textSelection(.enabled)
                if field.changes.isEmpty {
                    Text("No party, item or gold changes yet.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(field.changes.suffix(100).enumerated().reversed()), id: \.offset) { _, c in
                    HStack {
                        Text("frame \(c.frame)").frame(width: 80, alignment: .leading)
                        Text(c.change.what)
                        Spacer()
                        Text(String(format: "obj %d $%04X op $%02X", c.change.slot / 2, c.change.offset, c.change.opcode))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption.monospaced())
                }
            }
            Section("Palette animation") {
                ForEach(0..<WRAM.fieldAnimBCount, id: \.self) { k in
                    let at = WRAM.fieldAnimB + k * WRAM.fieldAnimBSize
                    let kind = Int(vm.wram[at] >> 4)
                    if kind != 0 {
                        HStack {
                            Text("record \(k)").frame(width: 70, alignment: .leading)
                            Text(kind < Self.animKinds.count ? Self.animKinds[kind] : "frame list").frame(width: 90, alignment: .leading)
                            Text("frame \(vm.wram[at + 3]), tick \(vm.wram[at + 4])/\(vm.wram[at + 5])")
                            Spacer()
                            Text((0..<WRAM.fieldAnimBSize).map { String(format: "%02X", vm.wram[at + $0]) }.joined(separator: " "))
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption.monospaced())
                    }
                }
                let written = vm.paletteWrites.sorted()
                Text(written.isEmpty ? "The palette opcodes wrote no colours yet."
                                     : "\(written.count) colours written by the palette opcodes and their records:")
                    .font(.caption).foregroundStyle(.secondary)
                if !written.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(14), spacing: 2), count: 16), spacing: 2) {
                        ForEach(written.prefix(256), id: \.self) { c in
                            Self.colour(vm.wram.word(WRAM.palCgramBuf + 2 * c))
                                .frame(width: 14, height: 14)
                                .help(String(format: "colour %d: $%04X", c, vm.wram.word(WRAM.palCgramBuf + 2 * c)))
                        }
                    }
                }
            }
            Section("Stopped objects") {
                if vm.stopped.isEmpty {
                    Text("None: every object runs modelled code.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(vm.stopped.keys.sorted(), id: \.self) { slot in
                    HStack(alignment: .top) {
                        Text("obj \(slot / 2)").frame(width: 52, alignment: .leading)
                        Text(vm.stopped[slot] ?? "").foregroundStyle(.red)
                    }
                    .font(.caption.monospaced())
                }
            }
        }
    }

    /// A BGR555 colour.
    static func colour(_ v: Int) -> Color {
        Color(red: Double(v & 0x1F) / 31, green: Double(v >> 5 & 0x1F) / 31, blue: Double(v >> 10 & 0x1F) / 31)
    }
}
