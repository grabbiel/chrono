import Foundation

/// Deterministic standalone text build. These are real TextWin payloads, but
/// offsets belong to this artifact; ROM relocation/repacking is a separate step.
public enum CTDialogueArchive {
    public struct Record: Codable, Equatable, Sendable {
        public let id: String
        public let offset: Int
        public let length: Int
        public let uncompressedLength: Int
    }
    public struct Build: Codable, Equatable, Sendable {
        public let schema: String
        public let romSHA256: String
        public let records: [Record]
        public let bytes: [UInt8]
    }
    public static func compile(_ project: CTProject) throws -> Build {
        guard let profile = project.textProfile else {
            throw CTTextError("project has no strings/ct-text-profile.json; import a verified ROM text profile first")
        }
        let codec = try CTTextCodec(profile: profile)
        var bytes: [UInt8] = [], records: [Record] = []
        for (id, text) in project.dialogue.strings.sorted(by: { $0.key < $1.key }) {
            do {
                let analysis = try codec.analyzeMessage(text)
                records.append(Record(id: id, offset: bytes.count, length: analysis.bytes.count,
                                      uncompressedLength: analysis.uncompressedBytes))
                bytes += analysis.bytes
            } catch { throw CTTextError("dialogue \(id): \(error)") }
        }
        return Build(schema: "ct-dialogue/1", romSHA256: profile.romSHA256, records: records, bytes: bytes)
    }
}
