import Foundation

/// Versioned Studio interchange format (.cfscene), explicitly distinct from ROM data.
/// CFSC | version:u8 | object:u8 | internal EventBytecode payload.
/// Graph layout belongs to the project JSON, not executable scene data.
public enum EventSceneArchive {
    public static func encode(_ scene: EventScene) throws -> Data {
        try EventBytecode.validate(scene)
        return Data([0x43, 0x46, 0x53, 0x43, 1, UInt8(scene.object)] + (try EventBytecode.compile(scene.funcs)))
    }
    public static func decode(_ data: Data) throws -> EventScene {
        let bytes = Array(data)
        guard bytes.count >= 7, Array(bytes.prefix(4)) == [0x43, 0x46, 0x53, 0x43] else {
            throw EventBytecode.CompileError("not a ChronoForge scene archive (expected CFSC header)")
        }
        guard bytes[4] == 1 else { throw EventBytecode.CompileError("unsupported scene archive version \(bytes[4])") }
        let scene = EventScene(object: Int(bytes[5]), funcs: try EventBytecode.decompile(Array(bytes.dropFirst(6))))
        try EventBytecode.validate(scene)
        return scene
    }
}
