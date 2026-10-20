// Bounded logical execution trace of the Studio AST. No SNES timing claims.
import Foundation

public enum EventPreview {
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public var id: Int
        public var frame: Int
        public var function: Int
        public var action: String
        public var detail: String
    }
    public struct Result: Codable, Equatable, Sendable {
        public var entries: [Entry]
        public var elapsedFrames: Int
        public var flags: [String]
        public var stopReason: String
    }

    /// Calls stop at the map boundary: ctproj/1 has no map-to-function binding.
    /// Dialogue is recorded without inventing a dismissal duration.
    public static func run(_ scene: EventScene, entry: Int = 0,
                           flags initialFlags: Set<String> = [],
                           dialogue: [String: String] = [:],
                           stepLimit: Int = 1000) throws -> Result {
        try EventBytecode.validate(scene)
        guard (1...100_000).contains(stepLimit) else {
            throw EventBytecode.CompileError("preview step limit must be in 1...100000")
        }
        let funcs = Dictionary(uniqueKeysWithValues: scene.funcs.map { ($0.index, $0.stmts) })
        guard let body = funcs[entry] else { throw EventBytecode.CompileError("missing entry function \(entry)") }
        var pending = Array(body.reversed())
        var function = entry, frame = 0
        var flags = initialFlags
        var entries: [Entry] = []
        var stop = "Function completed"
        while let stmt = pending.popLast() {
            guard entries.count < stepLimit else { stop = "Step limit reached (possible loop)"; break }
            var detail = ""
            switch stmt {
            case .text(let id): detail = dialogue[id] ?? "Unresolved dialogue: \(id)"
            case .ifFlag(let s, _, _): detail = flags.contains(s) ? "then branch" : "else branch"
            case .callObject, .callMember: detail = "other objects are not simulated; this one goes on"
            case .ct: detail = "CT opcode, not simulated"
            default: break
            }
            entries.append(Entry(id: entries.count, frame: frame, function: function,
                                 action: EventDSL.summary(stmt), detail: detail))
            switch stmt {
            case .nop, .text, .callObject, .callMember, .ct: break
            case .wait(let frames): frame += frames
            case .setFlag(let s): flags.insert(s)
            case .clearFlag(let s): flags.remove(s)
            case .ifFlag(let s, let t, let e): pending.append(contentsOf: (flags.contains(s) ? t : e).reversed())
            case .jump(let target):
                function = target
                pending = Array(funcs[target]!.reversed())
            case .call(let map, let target):
                stop = "Stopped at external call \(map)#\(target): map/function binding is not defined"
                pending.removeAll()
            }
        }
        return Result(entries: entries, elapsedFrames: frame, flags: flags.sorted(), stopReason: stop)
    }
}

public enum EventReferences {
    /// Validate both arms of every conditional, including branches a preview doesn't take.
    public static func issues(in scene: EventScene, flags: Set<String>,
                              strings: Set<String>, maps: Set<String>,
                              scenes: [String: EventScene]? = nil) -> [String] {
        var issues: [String] = []
        func walk(_ stmts: [EventStmt], path: String, depth: Int) {
            guard depth <= EventBytecode.maximumNesting else { return }
            for (i, stmt) in stmts.enumerated() {
                let location = "\(path)/\(i)"
                func flag(_ s: String) {
                    if !flags.contains(s) { issues.append("\(location): unknown flag \"\(s)\"") }
                }
                switch stmt {
                case .setFlag(let s), .clearFlag(let s): flag(s)
                case .ifFlag(let s, let t, let e):
                    flag(s)
                    walk(t, path: location + "/then", depth: depth + 1)
                    walk(e, path: location + "/else", depth: depth + 1)
                case .text(let s):
                    if !strings.contains(s) { issues.append("\(location): unknown dialogue string \"\(s)\"") }
                case .call(let m, _):
                    if !maps.contains(m) { issues.append("\(location): call to unknown map \"\(m)\"") }
                case .callObject(let id, let index, _, _):
                    guard let scenes else { break }
                    if let target = scenes[id] {
                        if !target.funcs.contains(where: { $0.index == index }) {
                            issues.append("\(location): scene \"\(id)\" has no func \(index)")
                        }
                    } else { issues.append("\(location): call to unknown scene \"\(id)\"") }
                case .ct(let opcode, let operands):
                    if let problem = CTEventLowering.ctProblem(opcode: opcode, operands: operands) {
                        issues.append("\(location): \(problem)")
                    }
                default: break
                }
            }
        }
        for f in scene.funcs { walk(f.stmts, path: "func \(f.index)", depth: 0) }
        return issues
    }
}
