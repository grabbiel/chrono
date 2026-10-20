// SharedPaneKit.swift — reusable editor scaffolding for all panes.
import SwiftUI
import ChronoForgeCore

/// Master list + detail used by every module pane.
struct EntityListView<Detail: View>: View {
    let title: String
    let ids: [String]
    @Binding var selection: String?
    @ViewBuilder var detail: (String) -> Detail

    var body: some View {
        NavigationSplitView {
            List(ids, id: \.self, selection: $selection) { id in
                NavigationLink(id, value: id)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 200)
        } detail: {
            if let selection { detail(selection) }
            else { ContentUnavailableView(title, systemImage: "list.bullet") }
        }
        .navigationTitle(title)
    }
}

/// Edits a copy of an entity; Apply pushes it back. Re-seeds when the
/// entity changes identity (selection) or content (external save).
struct EditorHost<T: Equatable, Content: View>: View {
    let entity: T
    let apply: (T) -> Void
    @ViewBuilder let content: (Binding<T>) -> Content
    @State private var copy: T?

    var body: some View {
        Group {
            if copy != nil {
                content(Binding<T>(
                    get: { _copy.wrappedValue! },
                    set: { _copy.wrappedValue = $0 }))
            }
        }
        .onAppear { copy = entity }
    }
}

struct ApplyBar: View {
    let apply: () -> Void
    var body: some View {
        HStack {
            Spacer()
            Button("Apply", action: apply).keyboardShortcut("s", modifiers: .command)
        }
    }
}

struct StatField: View {
    let label: String
    @Binding var value: Int
    init(_ label: String, _ value: Binding<Int>) { self.label = label; _value = value }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            TextField("", value: $value, format: .number)
                .frame(minWidth: 70)
        }
    }
}

/// Binding into an optional nested stats struct (missing -> zero default).
func statsBinding(_ b: Binding<CharacterDef.Stats?>,
                  _ keyPath: WritableKeyPath<CharacterDef.Stats, Int>) -> Binding<Int> {
    Binding(
        get: { b.wrappedValue?[keyPath: keyPath] ?? 0 },
        set: { v in
            var s = b.wrappedValue ?? CharacterDef.Stats(hp: 0, mp: 0, atk: 0, def: 0, mag: 0, spd: 0)
            s[keyPath: keyPath] = v
            b.wrappedValue = s
        })
}

/// Binding into an optional [String: Int] map.
func dictBinding(_ b: Binding<[String: Int]?>, _ key: String) -> Binding<Int> {
    Binding(
        get: { b.wrappedValue?[key] ?? 0 },
        set: { v in
            var d = b.wrappedValue ?? [:]
            d[key] = v
            b.wrappedValue = d
        })
}

struct OptionalTextField: View {
    let label: String
    @Binding var value: String?
    var body: some View {
        TextField(label, text: Binding(
            get: { value ?? "" },
            set: { value = $0.isEmpty ? nil : $0 }))
    }
}

struct OptionalIntField: View {
    let label: String
    @Binding var value: Int?
    let range: ClosedRange<Int>
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { value ?? range.lowerBound },
                set: { value = $0 }), in: range) {
                Text("\(value.map(String.init) ?? "—")")
            }
        }
    }
}

struct BoolToggle: View {
    let label: String
    @Binding var value: Bool?
    var body: some View {
        Toggle(label, isOn: Binding(
            get: { value ?? false },
            set: { value = $0 }))
    }
}
