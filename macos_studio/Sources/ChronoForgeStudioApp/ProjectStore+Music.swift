// ProjectStore+Music.swift — the Music pane's tracker edits (saved, with undo),
// instrument auditions and the driver tables the echo designer and rack read.
import SwiftUI
import ChronoForgeCore

extension ProjectStore {
    /// Save an edit of listing `rel` from `old` to `new` and register its undo
    /// (and that undo's redo) with `undoManager`; `show` puts the text in the
    /// editor each time. Returns false (with the reason in the status line)
    /// when the new text does not assemble or cannot be saved.
    @discardableResult
    public func editSong(_ rel: String, from old: String, to new: String, name: String,
                         undoManager: UndoManager?, show: @escaping @MainActor (String) -> Void) -> Bool {
        do { _ = try CTSongListing.assembleSong(new) } catch {
            statusMessage = "\(name): \(error)"
            statusIsError = true
            return false
        }
        guard writeSongListing(rel, new) else { return false }
        show(new)
        statusMessage = "\(name) — saved \((rel as NSString).lastPathComponent)"
        undoManager?.registerUndo(withTarget: self) { store in
            MainActor.assumeIsolated {
                store.editSong(rel, from: new, to: old, name: name, undoManager: undoManager, show: show)
            }
        }
        undoManager?.setActionName(name)
        return true
    }

    /// Apply `edit` to the listing's document and save it as `editSong` does.
    @discardableResult
    public func editSong(_ rel: String, text: String, name: String, undoManager: UndoManager?,
                         show: @escaping @MainActor (String) -> Void,
                         _ edit: (inout CTSongDocument) throws -> Void) -> Bool {
        var doc = CTSongDocument(listing: text)
        do { try edit(&doc) } catch {
            statusMessage = "\(name): \(error)"
            statusIsError = true
            return false
        }
        return editSong(rel, from: text, to: doc.listing, name: name, undoManager: undoManager, show: show)
    }

    /// The playback ROM, or nil (asking for it in the status line).
    func musicROM() -> [UInt8]? {
        guard let path = playbackROMPath, let rom = try? Self.playbackROM(path) else {
            statusMessage = "choose the CT ROM (Sound ROM… in the playback bar) to read the driver's tables"
            statusIsError = true
            return nil
        }
        return rom
    }

    /// The song's instruments for a sample list, with the ROM's words.
    public func instrumentRack(samples: [Int]) -> [CTSongInstrument]? {
        guard let rom = musicROM() else { return nil }
        do { return try CTSongInstrument.rack(rom: rom, samples: samples) } catch {
            statusMessage = "instruments: \(error)"
            statusIsError = true
            return nil
        }
    }

    /// The driver's four FIR sets, from the playback ROM.
    public func driverFIRSets() -> [[Int8]]? {
        guard let rom = musicROM() else { return nil }
        return try? CTSongEcho.firSets(rom: rom)
    }

    /// Plays one note on instrument `slot` through the driver, in place of song `song`.
    public func audition(slot: Int, number: Int, tables: CTSongTables, replacing song: Int) {
        let text = CTSongInstrument.audition(slot: slot, number: number, tables: tables)
        playListing(text, replacing: song, title: String(format: "sample $%02X %@", 0x20 + slot, CTSongTimeline.noteName(number)))
    }
}
