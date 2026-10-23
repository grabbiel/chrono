// CTDialogueNames.swift — the names a message or description draws ($7E:2C23,
// codes $13-$20 and the party codes $1B-$1D), taken from the project's
// character import instead of placeholders: each playable character's name by
// its record's character id, falling back to the game's default names. The
// ROM keeps its defaults dictionary-compressed in a message table, not as a
// name table, so the fallbacks are the known names (CTCharacterROM.names) and
// "Epoch" for name 7 (code $20).
import Foundation

extension CTDialogueSettings {
    /// The default names 0-7: Crono ... Magus, then Epoch.
    public static let defaultNames: [String] = CTCharacterROM.names.map { $0.capitalized } + ["Epoch"]

    /// Display names by character id 0-6 from `project` (playable characters with a record).
    public static func projectNames(_ project: CTProject) -> [Int: String] {
        var out: [Int: String] = [:]
        for c in project.characters.values {
            guard let id = c.pc?.charId, (0..<7).contains(id), !c.name.isEmpty else { continue }
            out[id] = c.name
        }
        return out
    }

    /// Names 0-7 as glyph bytes (at most 5 drawn), from `names` (by character
    /// id) or the defaults; `party` the 3 member ids; the rest placeholders.
    public static func named(_ names: [Int: String], codec: CTTextCodec, party: [Int] = [0, 1, 2],
                             press: Int = 1, place: Int = 1) -> CTDialogueSettings {
        var s = CTDialogueSettings.placeholder(press: press, place: place)
        var glyphs: [[UInt8]] = []
        for i in 0..<8 {
            let name = names[i] ?? defaultNames[i]
            glyphs.append(nameGlyphs(name, codec: codec))
        }
        s.names = glyphs
        s.party = party
        return s
    }

    /// A name's glyph bytes (raw, no dictionary): the first 5, as TextWin draws at most 5.
    public static func nameGlyphs(_ name: String, codec: CTTextCodec) -> [UInt8] {
        guard let bytes = try? codec.encode(name, compress: false) else { return [] }
        var out: [UInt8] = []
        for b in bytes where b >= UInt8(CTDialogueROM.firstGlyph) {
            out.append(b)
            if out.count == CTDialogueROM.charNameMax { break }
        }
        return out
    }
}
