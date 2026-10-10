import Foundation
import Synchronization
import Testing
@testable import PRReview

@Suite("Application termination")
@MainActor
struct ReviewModelTests {
    @Test func failedSavePreventsQuitAndAllowsRetry() async throws {
        let storage = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let id = UUID()
        let path = storage.appendingPathComponent("Worktrees/\(id.uuidString)")
        let project = path.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: project.appendingPathComponent("project.pbxproj"))
        let session = Session(id: id, repository: Repository(path: "/unused", slug: "owner/repo", entry: "App.xcodeproj"),
                              prURL: "https://github.com/owner/repo/pull/1", number: 1, title: "test", sha: "abc", path: path.path)
        var state = SavedState(); state.sessions = [session]
        let initial = state
        let fail = Mutex(true)
        let store = StateStore(storage: storage, load: { initial }, save: { _ in
            if fail.withLock({ $0 }) { throw ReviewError("disk unavailable") }
        })
        let builds = XcodeBuildService(storage: storage, command: { name, _, _ in
            if name == "git" {
                return CommandResult(standardOutput: "abc", standardError: "", exitCode: 0, terminationDescription: "exited(0)")
            }
            throw CancellationError()
        }, inspect: { _ in InspectionReport(blockers: []) })
        let coordinator = ReviewCoordinator(service: ReviewService(storage: storage), store: store, buildService: builds)
        let settings = BuildSettings(scheme: "App", destination: BuildDestination(id: "Mac", name: "My Mac", platform: "macOS"))
        await #expect(throws: ReviewError.self) {
            try await coordinator.runBuild(session, settings: settings, action: .build)
        }
        let model = ReviewModel(coordinator: coordinator)
        #expect(coordinator.hasUnsavedChanges)
        #expect(await model.shutdown() == false)
        #expect(!model.shuttingDown)
        #expect(model.error?.contains("終了を中止") == true)
        #expect(coordinator.state.sessions.first?.buildRecords?.count == 1)
        fail.withLock { $0 = false }
        #expect(await model.shutdown())
        #expect(!coordinator.hasUnsavedChanges)
    }
}
