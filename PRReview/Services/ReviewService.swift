import Foundation

public struct ReviewService: Sendable {
    public let storage: URL
    let command: @Sendable (String, [String]) async throws -> String
    public var stateStore: StateStore { StateStore(storage: storage) }
    public var worktrees: URL { storage.appendingPathComponent("Worktrees", isDirectory: true) }
    public init(storage: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PRReview"), command: @escaping @Sendable (String, [String]) async throws -> String = CommandRunner.run) {
        self.storage = storage
        self.command = command
    }
    @concurrent
    func git(_ path: String, _ arguments: [String]) async throws -> String {
        try await GitClient(command: command).run(at: path, arguments)
    }
}
