import Foundation

enum ClientStore {
    private static var fileURL: URL {
        RecordingStore.storageDirectory.appendingPathComponent("clients.json")
    }

    static func load() -> [Client] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.brumlik.decode([Client].self, from: data)) ?? []
    }

    static func save(_ clients: [Client]) {
        let encoder = JSONEncoder.brumlik
        if let data = try? encoder.encode(clients) {
            try? data.write(to: fileURL)
        }
    }
}

extension JSONDecoder {
    static let brumlik: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

extension JSONEncoder {
    static let brumlik: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
