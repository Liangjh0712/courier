import Foundation

/// What survives a restart: the history and the draft with its pictures, in
/// ~/Library/Application Support/Courier/state.json.
public struct SavedState: Codable, Equatable {
    public struct SavedPicture: Codable, Equatable {
        public var id: Int
        public var png: Data
        public init(id: Int, png: Data) {
            self.id = id
            self.png = png
        }
    }

    public var history: [String]
    public var text: String
    public var pictures: [SavedPicture]?

    public init(history: [String] = [], text: String = "", pictures: [SavedPicture]? = nil) {
        self.history = history
        self.text = text
        self.pictures = pictures
    }

    public static func load(from url: URL) -> SavedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SavedState.self, from: data)
    }

    public func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public let historyMax = 50

/// Adds a sent message to the history: newest last, no repeats, at most historyMax.
public func remember(_ s: String, in history: inout [String]) {
    guard !s.isEmpty else { return }
    history.removeAll { $0 == s }
    history.append(s)
    if history.count > historyMax { history.removeFirst(history.count - historyMax) }
}

public enum Paths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Courier")
    }
    public static var state: URL { support.appendingPathComponent("state.json") }
    public static var log: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Courier.log")
    }
}
