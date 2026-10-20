// TextCodec.swift — CT-style string codec for the .ctproj round-trip gate (5).
//
// The .ctproj stores plain UTF-8 with control escapes: literal sequences
// "\n" (newline char), "\{wait}", "\{br}", "\{name:xxx}" (backslash + brace
// token). The compiler emits a byte stream; decoding it must return the
// identical UTF-8 (validator gate 5). This is a placeholder ISA shaped like
// the CT text codec (ASCII band + escape tokens), not the real CT substring
// dictionary — the round-trip contract is what the gate enforces.
import Foundation

public enum TextCodec {
    static let esc: UInt8 = 0x01        // control escape prefix
    static let nameTok: UInt8 = 0x02    // \{name:xxx}
    static let utfTok: UInt8 = 0x03     // raw UTF-8 run

    public static func encode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        var utfRun: [UInt8] = []
        func flushUtf() {
            if !utfRun.isEmpty {
                out.append(utfTok); out.append(UInt8(utfRun.count))
                out.append(contentsOf: utfRun)
                utfRun.removeAll(keepingCapacity: true)
            }
        }
        var i = s.startIndex
        while i < s.endIndex {
            let rest = s[i...]
            if rest.hasPrefix("\\{wait}") {
                flushUtf(); out.append(esc); out.append(0x77); i = s.index(i, offsetBy: 7)
            } else if rest.hasPrefix("\\{br}") {
                flushUtf(); out.append(esc); out.append(0x62); i = s.index(i, offsetBy: 5)
            } else if rest.hasPrefix("\\{name:"),
                      let close = rest.firstIndex(of: "}"),
                      rest[s.index(i, offsetBy: 7)..<close].utf8.count <= 255 {
                flushUtf()
                let after = s.index(i, offsetBy: 7)
                let name = String(rest[after..<close])
                out.append(nameTok)
                let nb = Array(name.utf8)
                out.append(UInt8(nb.count)); out.append(contentsOf: nb)
                i = s.index(after: close)
            } else if s[i] == "\n" {
                flushUtf(); out.append(esc); out.append(0x6E); i = s.index(after: i)
            } else if let a = s[i].asciiValue, a >= 0x20, a < 0x7F {
                flushUtf(); out.append(a); i = s.index(after: i)
            } else {
                // Split only at scalar boundaries, including a single grapheme
                // with hundreds of combining marks. Each length is one byte.
                for scalar in String(s[i]).unicodeScalars {
                    let bytes = Array(String(scalar).utf8)
                    if utfRun.count + bytes.count > 255 { flushUtf() }
                    utfRun.append(contentsOf: bytes)
                }
                i = s.index(after: i)
            }
        }
        flushUtf()
        return out
    }

    public static func decode(_ bytes: [UInt8]) -> String {
        var s = ""
        var i = 0
        while i < bytes.count {
            switch bytes[i] {
            case esc:
                i += 1
                if i < bytes.count {
                    switch bytes[i] {
                    case 0x6E: s.append("\n")
                    case 0x77: s.append("\\{wait}")
                    case 0x62: s.append("\\{br}")
                    default: break
                    }
                    i += 1
                }
            case nameTok:
                i += 1
                if i < bytes.count {
                    let n = Int(bytes[i]); i += 1
                    let end = min(i + n, bytes.count)
                    s.append("\\{name:\(String(decoding: bytes[i..<end], as: UTF8.self))}")
                    i = end
                }
            case utfTok:
                i += 1
                if i < bytes.count {
                    let n = Int(bytes[i]); i += 1
                    let end = min(i + n, bytes.count)
                    s.append(String(decoding: bytes[i..<end], as: UTF8.self))
                    i = end
                }
            default:
                s.append(Character(UnicodeScalar(bytes[i])))
                i += 1
            }
        }
        return s
    }
}
