import Foundation

enum RecordingStore {
    /// Tests keep their data in a temporary folder instead of the user's.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = directoryOverride ?? base.appendingPathComponent("BrumlikAI", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var recordingsDirectory: URL {
        let dir = storageDirectory.appendingPathComponent("recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var indexURL: URL {
        storageDirectory.appendingPathComponent("recordings.json")
    }

    static func load() -> [Recording] {
        guard let data = try? Data(contentsOf: indexURL) else { return [] }
        return (try? JSONDecoder().decode([Recording].self, from: data)) ?? []
    }

    static func save(_ recordings: [Recording]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(recordings) {
            try? data.write(to: indexURL)
        }
    }

    static func systemPartURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent("\(id.uuidString).system.caf")
    }

    static func micPartURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent("\(id.uuidString).mic.caf")
    }

    static func mixedURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent("\(id.uuidString).m4a")
    }

    /// Your side alone, small, for telling the speakers apart. Kept only until the call is transcribed.
    static func myTrackURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent("\(id.uuidString).me.m4a")
    }

    /// The other side alone, small, for telling the speakers apart. Kept only until the call is transcribed.
    static func otherTrackURL(for id: UUID) -> URL {
        recordingsDirectory.appendingPathComponent("\(id.uuidString).other.m4a")
    }

    static func removeParts(for id: UUID) {
        try? FileManager.default.removeItem(at: systemPartURL(for: id))
        try? FileManager.default.removeItem(at: micPartURL(for: id))
    }

    static func removeTracks(for id: UUID) {
        try? FileManager.default.removeItem(at: myTrackURL(for: id))
        try? FileManager.default.removeItem(at: otherTrackURL(for: id))
    }

    /// Removes every file of a recording: parts, the mixed file and leftover upload chunks.
    static func removeFiles(for id: UUID) {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: recordingsDirectory.path) else { return }
        for name in names where name.hasPrefix(id.uuidString) {
            try? fileManager.removeItem(at: recordingsDirectory.appendingPathComponent(name))
        }
    }
}
