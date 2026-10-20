// A deterministic, bounded parser for the Studio's ctproj/1 scene language.
import Foundation

public struct EventDSLError: Error, CustomStringConvertible, Sendable {
    public let line: Int
    public let column: Int
    public let message: String
    public var description: String { "line \(line), column \(column): \(message)" }
}

public enum EventDSL {
    public static func parse(_ source: String) throws -> EventScene {
        guard source.utf8.count <= 1_048_576 else {
            throw EventDSLError(line: 1, column: 1, message: "scene exceeds 1 MiB")
        }
        var parser = Parser(tokens: try lex(source))
        return try parser.scene()
    }

    /// Layout is stored separately in .event.json and never changes script semantics.
    public static func format(_ scene: EventScene) -> String {
        var lines = ["obj \(scene.object) {"]
        for function in scene.funcs {
            lines.append("  func \(function.index) {")
            lines += format(function.stmts, indent: "    ")
            lines.append("  }")
        }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func summary(_ stmt: EventStmt) -> String {
        switch stmt {
        case .nop: return "nop"
        case .wait(let f): return "wait \(f)"
        case .setFlag(let s): return "set_flag \(quote(s))"
        case .clearFlag(let s): return "clear_flag \(quote(s))"
        case .text(let s): return "text \(quote(s))"
        case .call(let m, let f): return "call \(quote(m))#\(f)"
        case .jump(let f): return "jump func\(f)"
        case .ifFlag(let s, _, _): return "if \(quote(s))"
        case .callObject(let id, let f, let mode, let level): return "call_obj \(quote(id))#\(f) \(mode.rawValue) level \(level)"
        case .callMember(let m, let f, let mode, let level): return "call_pc \(m)#\(f) \(mode.rawValue) level \(level)"
        case .ct(let opcode, let operands):
            return (["ct", CTEventISA.opcodes[Int(opcode)].name] + operands.map { String(format: "$%02X", $0) }).joined(separator: " ")
        }
    }

    /// `$XX` (or an opcode name such as Op94_WalkToObj) as an opcode byte.
    static func opcodeByte(_ token: String) -> UInt8? {
        if let byte = hexByte(token) { return byte }
        return CTEventISA.opcodes.firstIndex { $0.name == token }.map(UInt8.init)
    }
    static func hexByte(_ token: String) -> UInt8? {
        guard token.count == 3, token.hasPrefix("$") else { return nil }
        return UInt8(token.dropFirst(), radix: 16)
    }

    private static func quote(_ s: String) -> String {
        // JSON string syntax also defines DSL escaping, including control characters.
        String(decoding: try! JSONEncoder().encode(s), as: UTF8.self)
    }

    private static func format(_ stmts: [EventStmt], indent: String) -> [String] {
        var lines: [String] = []
        for stmt in stmts {
            if case .ifFlag(_, let t, let e) = stmt {
                lines.append(indent + summary(stmt) + " {")
                lines += format(t, indent: indent + "  ")
                if !e.isEmpty {
                    lines.append(indent + "} else {")
                    lines += format(e, indent: indent + "  ")
                }
                lines.append(indent + "}")
            } else { lines.append(indent + summary(stmt)) }
        }
        return lines
    }

    private struct Token {
        var value: String
        var quoted = false
        var line: Int
        var column: Int
    }

    private static func lex(_ source: String) throws -> [Token] {
        let chars = Array(source)
        var i = 0, line = 1, column = 1
        var lineHasToken = false
        var result: [Token] = []
        func advance() {
            if chars[i].isNewline { line += 1; column = 1; lineHasToken = false }
            else { column += 1 }
            i += 1
        }
        while i < chars.count {
            let c = chars[i]
            if c.isWhitespace { advance(); continue }
            if (c == "#" && !lineHasToken) || (c == "/" && i + 1 < chars.count && chars[i + 1] == "/") {
                while i < chars.count && !chars[i].isNewline { advance() }
                continue
            }
            let start = i, startLine = line, startColumn = column
            lineHasToken = true
            if c == "\"" {
                advance()
                var closed = false
                while i < chars.count {
                    if chars[i] == "\"" { advance(); closed = true; break }
                    if chars[i] == "\\" {
                        advance()
                        if i < chars.count { advance() }
                    } else { advance() }
                }
                guard closed, let value = try? JSONDecoder().decode(String.self,
                    from: Data(String(chars[start..<i]).utf8)) else {
                    throw EventDSLError(line: startLine, column: startColumn, message: "invalid or unterminated quoted identifier")
                }
                result.append(Token(value: value, quoted: true, line: startLine, column: startColumn))
            } else if "{}#".contains(c) {
                advance()
                result.append(Token(value: String(c), line: startLine, column: startColumn))
            } else {
                while i < chars.count && !chars[i].isWhitespace && !"{}#\"".contains(chars[i]) {
                    if chars[i] == "/", i + 1 < chars.count, chars[i + 1] == "/" { break }
                    advance()
                }
                result.append(Token(value: String(chars[start..<i]), line: startLine, column: startColumn))
            }
        }
        result.append(Token(value: "", line: line, column: column))
        return result
    }

    private struct Parser {
        let tokens: [Token]
        var i = 0
        var current: Token { tokens[i] }
        func error(_ message: String) -> EventDSLError {
            EventDSLError(line: current.line, column: current.column, message: message)
        }
        func isToken(_ value: String) -> Bool { !current.quoted && current.value == value }
        mutating func take(_ value: String) throws {
            guard isToken(value) else { throw error("expected '\(value)', got '\(current.value)'") }
            i += 1
        }
        mutating func identifier() throws -> String {
            guard !current.value.isEmpty, current.quoted || !["{", "}", "#"].contains(current.value) else {
                throw error("expected identifier")
            }
            defer { i += 1 }
            return current.value
        }
        mutating func number(_ range: ClosedRange<Int>, prefix: String = "") throws -> Int {
            var value = current.value
            if !prefix.isEmpty && value.hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) }
            guard !current.quoted, let n = Int(value), range.contains(n) else {
                throw error("expected integer in \(range.lowerBound)...\(range.upperBound)")
            }
            i += 1
            return n
        }
        mutating func scene() throws -> EventScene {
            try take("obj")
            let object = try number(0...15)
            try take("{")
            var funcs: [EventFunc] = []
            var ids = Set<Int>()
            while !isToken("}") {
                try take("func")
                let index = try number(0...15)
                guard ids.insert(index).inserted else { throw error("duplicate function \(index)") }
                funcs.append(EventFunc(index: index, stmts: try block(depth: 0)))
            }
            try take("}")
            guard isToken("") else { throw error("unexpected content after object") }
            let scene = EventScene(object: object, funcs: funcs)
            do { try EventBytecode.validate(scene) }
            catch { throw self.error(String(describing: error)) }
            return scene
        }
        mutating func block(depth: Int) throws -> [EventStmt] {
            guard depth <= EventBytecode.maximumNesting else { throw error("conditional nesting limit exceeded") }
            try take("{")
            var stmts: [EventStmt] = []
            while !isToken("}") {
                let op = current
                guard !op.quoted, !op.value.isEmpty else { throw error("expected statement or '}'") }
                i += 1
                switch op.value {
                case "nop": stmts.append(.nop)
                case "wait": stmts.append(.wait(frames: try number(0...65535)))
                case "text": stmts.append(.text(stringID: try identifier()))
                case "set_flag": stmts.append(.setFlag(symbol: try identifier()))
                case "clear_flag": stmts.append(.clearFlag(symbol: try identifier()))
                case "jump": stmts.append(.jump(funcIndex: try number(0...15, prefix: "func")))
                case "call":
                    let map = try identifier()
                    try take("#")
                    stmts.append(.call(map: map, funcIndex: try number(0...15)))
                case "call_obj", "call_pc":
                    let target: EventStmt
                    if op.value == "call_obj" {
                        let scene = try identifier()
                        try take("#")
                        target = .callObject(scene: scene, funcIndex: try number(0...15), mode: .wait, level: 4)
                    } else {
                        let member = try number(0...2)
                        try take("#")
                        target = .callMember(member: member, funcIndex: try number(0...15), mode: .wait, level: 4)
                    }
                    var mode = EventCallMode.wait, level = 4
                    if !current.quoted, let m = EventCallMode(rawValue: current.value) { mode = m; i += 1 }
                    if isToken("level") { try take("level"); level = try number(0...6) }
                    switch target {
                    case .callObject(let scene, let f, _, _): stmts.append(.callObject(scene: scene, funcIndex: f, mode: mode, level: level))
                    case .callMember(let member, let f, _, _): stmts.append(.callMember(member: member, funcIndex: f, mode: mode, level: level))
                    default: break
                    }
                case "ct":
                    guard !current.quoted, let opcode = EventDSL.opcodeByte(current.value) else {
                        throw error("expected an opcode ($XX or a name such as Op94_WalkToObj)")
                    }
                    i += 1
                    var operands: [UInt8] = []
                    while !current.quoted, let byte = EventDSL.hexByte(current.value) {
                        guard operands.count < 255 else { throw error("ct takes at most 255 operand bytes") }
                        operands.append(byte); i += 1
                    }
                    stmts.append(.ct(opcode: opcode, operands: operands))
                case "if":
                    let symbol = try identifier()
                    let yes = try block(depth: depth + 1)
                    var no: [EventStmt] = []
                    if isToken("else") { try take("else"); no = try block(depth: depth + 1) }
                    stmts.append(.ifFlag(symbol: symbol, then: yes, else: no))
                default:
                    throw EventDSLError(line: op.line, column: op.column, message: "unknown statement '\(op.value)'")
                }
            }
            try take("}")
            return stmts
        }
    }
}
