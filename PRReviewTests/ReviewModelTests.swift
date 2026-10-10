import Foundation
import Synchronization
import Testing
@testable import PRReview

@Suite("Application termination")
@MainActor
struct ReviewModelTests {
    @Test func failedSavePreventsQuitAndAllowsRetry() async throws {
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = Session(id: UUID(), repository: Repository(path: "/unused", slug: "owner/repo", entry: "App.xcodeproj"),
                              prURL: "https://github.com/owner/repo/pull/1", number: 1, title: "test", sha: "abc", path: "/unused")
        var state = SavedState(); state.sessions = [session]
        let initial = state
        let fail = Mutex(true)
        let store = StateStore(storage: storage, load: { initial }, save: { _ in
            if fail.withLock({ $0 }) { throw ReviewError("disk unavailable") }
        })
        let coordinator = ReviewCoordinator(service: ReviewService(storage: storage), store: store)
        let record = BuildRecord(id: UUID(), sha: session.sha,
                                 configuration: BuildSettings(scheme: "App", destination: BuildDestination(id: "Mac", name: "My Mac", platform: "macOS")),
                                 action: .build, status: .cancelled, date: Date(), logPath: "/unused", resultPath: nil, sourceModified: false)
        do { try coordinator.recordBuild(record, for: session); Issue.record("Save should fail") } catch {}
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
