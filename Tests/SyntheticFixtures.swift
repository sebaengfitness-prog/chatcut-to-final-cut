import Foundation

/// Public, synthetic metadata only. No editor installation or playable media is needed.
enum SyntheticFixtures {
    static var directory: URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Tests/Fixtures")
    }
    static var inputURL: URL { directory.appendingPathComponent("linked-av.xml") }
    static var warningURL: URL { directory.appendingPathComponent("linked-av.warnings.json") }

    static func makeMedia(in scratch: URL) throws -> URL {
        let root = scratch.appendingPathComponent("synthetic-media")
        let media = root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for filename in ["Camera A.mov", "Camera B.mov", "Sound.wav"] {
            // The converter reads XML metadata and checks paths; it does not decode media.
            try Data("Synthetic test placeholder; this is not playable media.\n".utf8)
                .write(to: media.appendingPathComponent(filename))
        }
        return root
    }
}
