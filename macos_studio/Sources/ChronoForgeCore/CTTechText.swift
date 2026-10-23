// CTTechText.swift — tech names and descriptions.
// Names: TechNames ($CC:15C4), 11 bytes per id: an optional icon byte ($2F on
// the magic), then glyphs ($FF a blank), $EF-padded. Menu_TechDrawName draws
// all 11 tiles and TextWin_ExtTechName stops at the first $EF, so a name is at
// most 11 glyphs (10 after the icon) and holds no $EF.
// Descriptions: MenuRom_TechTextTable ($CC:3A09, BattleCD_ShowTechInfo and
// Menu_TechTextSetup): 121 bank-$CC pointers (tech ids 0-$74, then the
// menu's page titles), the strings at $CC:3B0D-$CC:43AE in the dialogue codec.
// The 18 bytes between the two ($CC:3AFB) are not read and stay.
import Foundation

public enum CTTechText {
    public static let nameTiles = 11, pad: UInt8 = 0xEF, blank: UInt8 = 0xFF
    public static let tablePC = 0x0C3A09, strings = 121
    public static let bodyPC = 0x0C3B0D, bodyEnd = 0x0C43AF

    // MARK: Names

    /// The name's glyph bytes of an 11-byte record (the icon skipped, the pad dropped).
    static func nameGlyphs(_ raw: [UInt8]) -> (icon: UInt8?, glyphs: [UInt8]) {
        let icon: UInt8? = raw[0] < 0xA0 && raw[0] != pad && raw[0] != blank ? raw[0] : nil
        return (icon, raw.dropFirst(icon == nil ? 0 : 1).filter { $0 != pad })
    }

    /// The name as the import decodes it (CTTechROM.decode), for comparing.
    static func decodeName(_ raw: [UInt8], codec: CTTextCodec) throws -> String {
        try nameGlyphs(raw).glyphs.map { $0 == blank ? " " : try codec.decode([$0]) }.joined()
            .trimmingCharacters(in: .whitespaces)
    }

    /// The 11 bytes of `name` after `icon`: blanks $FF, {gXX} for a raw glyph,
    /// $EF-padded. Throws past the menu's 11 tiles or on an unknown glyph.
    public static func encodeName(_ name: String, icon: Int?) throws -> [UInt8] {
        var out: [UInt8] = icon.map { [UInt8($0)] } ?? []
        let chars = Array(name)
        var i = 0
        while i < chars.count {
            if chars[i] == "{", i + 4 < chars.count, chars[i + 1] == "g", chars[i + 4] == "}",
               let v = UInt8(String(chars[(i + 2)...(i + 3)]), radix: 16), v != pad {
                out.append(v); i += 5; continue
            }
            if chars[i] == " " { out.append(blank) }
            else if let v = CTTextCodec.glyphByte(String(chars[i])), v != pad, v != blank { out.append(v) }
            else { throw CTROMBuildError("tech name \(String(reflecting: name)): no glyph for \(String(reflecting: String(chars[i])))") }
            i += 1
        }
        let room = nameTiles - (icon == nil ? 0 : 1)
        guard out.count <= nameTiles else {
            throw CTROMBuildError("tech name \(String(reflecting: name)) is \(out.count - nameTiles + room) glyphs; " +
                                  "the menu draws \(nameTiles) tiles (\(room) after the icon)")
        }
        return out + [UInt8](repeating: pad, count: nameTiles - out.count)
    }

    /// Glyphs a name takes and the room it has (for the Studio's fits / overflows).
    public static func nameWidth(_ name: String, icon: Int?) -> (used: Int, room: Int)? {
        guard let bytes = try? encodeName(String(name.prefix(64)), icon: nil) else { return nil }
        return (bytes.filter { $0 != pad }.count, nameTiles - (icon == nil ? 0 : 1))
    }

    // MARK: Descriptions

    /// Per string, its bytes up to (not with) its $00; nil when a pointer leaves the span.
    public static func descriptionBytes(rom: [UInt8]) -> [[UInt8]?] {
        (0..<strings).map { n in
            let at = 0x0C0000 + Int(rom[tablePC + 2 * n]) | Int(rom[tablePC + 2 * n + 1]) << 8
            guard at >= bodyPC, at < bodyEnd, let end = rom[at..<bodyEnd].firstIndex(of: 0) else { return nil }
            return Array(rom[at..<end])
        }
    }

    /// Each tech's description, decoded (nil where it does not decode).
    public static func fillDescriptions(rom: [UInt8], codec: CTTextCodec, techs: inout [TechSystemDef.Tech]) {
        let bytes = descriptionBytes(rom: rom)
        for i in techs.indices where bytes.indices.contains(techs[i].id) {
            techs[i].description = bytes[techs[i].id].flatMap { try? codec.decode($0) }
        }
    }

    /// The pointer table and strings when a description differs from the
    /// base's; nil when none does. Unchanged strings keep their bytes and
    /// identical strings share one copy.
    static func descriptionTable(_ s: TechSystemDef, rom: [UInt8], codec: CTTextCodec) throws -> [UInt8]? {
        let base = descriptionBytes(rom: rom)
        guard base.allSatisfy({ $0 != nil }) else { throw CTROMBuildError("techs: the base ROM's description table leaves its span") }
        var strings = base.map { $0! }
        var changed = false
        for t in s.techs {
            guard let text = t.description, strings.indices.contains(t.id) else { continue }
            if (try? codec.decode(strings[t.id])) == text { continue }
            var bytes: [UInt8]
            do { bytes = try codec.compileMessage(text) } catch {
                throw CTROMBuildError(String(format: "tech $%02X description: %@", t.id, "\(error)"))
            }
            bytes.removeLast()                         // the $00 every string gets below
            strings[t.id] = bytes
            changed = true
        }
        guard changed else { return nil }
        var pointers: [Int] = [], body: [UInt8] = [], at: [[UInt8]: Int] = [:]
        for str in strings {
            if let p = at[str] { pointers.append(p); continue }
            let p = bodyPC + body.count
            at[str] = p; pointers.append(p)
            body += str + [0]
        }
        guard bodyPC + body.count <= bodyEnd else {
            throw CTROMBuildError("techs: the descriptions take \(body.count) bytes; \(bodyEnd - bodyPC) fit at $CC:3B0D")
        }
        body += [UInt8](repeating: 0, count: bodyEnd - bodyPC - body.count)
        return pointers.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8 & 0xFF)] } + body
    }

    // MARK: Writes and checks

    /// Changed names in place and, when a description changed, the repacked table.
    public static func writes(_ s: TechSystemDef, rom: [UInt8], codec: CTTextCodec) throws -> [(pc: Int, bytes: [UInt8], what: String)] {
        var out: [(pc: Int, bytes: [UInt8], what: String)] = []
        for t in s.techs where t.id != 0 {
            let at = CTTechROM.namesPC + nameTiles * t.id
            let raw = Array(rom[at..<(at + nameTiles)])
            if (try? decodeName(raw, codec: codec)) == t.name { continue }
            let icon = nameGlyphs(raw).icon.map(Int.init)
            do { out.append((at, try encodeName(t.name, icon: icon), String(format: "tech $%02X name", t.id))) }
            catch { throw CTROMBuildError(String(format: "techs: tech $%02X: %@", t.id, "\(error)")) }
        }
        if let table = try descriptionTable(s, rom: rom, codec: codec) {
            out.append((tablePC, Array(table.prefix(2 * strings)), "tech descriptions"))
            out.append((bodyPC, Array(table.dropFirst(2 * strings)), "tech descriptions text"))
        }
        return out
    }

    /// Names that encode and fit, descriptions that compile (the Validator; no ROM).
    public static func check(_ s: TechSystemDef, codec: CTTextCodec) -> [String] {
        var out: [String] = []
        for t in s.techs where t.id != 0 {
            do { _ = try encodeName(t.name, icon: t.icon) } catch { out.append(String(format: "tech $%02X: %@", t.id, "\(error)")) }
            if let text = t.description {
                do { _ = try codec.compileMessage(text) } catch { out.append(String(format: "tech $%02X description: %@", t.id, "\(error)")) }
            }
        }
        return out
    }
}
