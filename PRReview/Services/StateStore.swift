import Foundation

/// Atomic JSON persistence, kept separate from Git and review lifecycle operations.
public struct StateStore: Sendable {
    public let storage: URL
    private let loadOverride: (@Sendable () throws -> SavedState)?
    private let saveOverride: (@Sendable (SavedState) throws -> Void)?

    public init(storage: URL, load: (@Sendable () throws -> SavedState)? = nil, save: (@Sendable (SavedState) throws -> Void)? = nil) {
        self.storage = storage
        self.loadOverride = load
        self.saveOverride = save
    }
    public func load() throws -> SavedState {
        if let loadOverride { return try loadOverride() }
        let file = storage.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return SavedState() }
        return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
    }
    public func save(_ state: SavedState) throws {
        if let saveOverride { try saveOverride(state); return }
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let file = storage.appendingPathComponent("state.json")
        // If loading failed, preserve the existing file instead of overwriting
        // the user's registered repositories and review sessions with defaults.
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: file, options: .atomic)
    }
}
