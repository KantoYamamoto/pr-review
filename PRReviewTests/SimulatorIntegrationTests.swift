import Foundation
import Testing
@testable import PRReview

@MainActor
struct SimulatorIntegrationTests {
    /// Opt-in: boots one new, app-owned device; never boots or installs into the template.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRREVIEW_SIMULATOR_INTEGRATION"] == "1"), .timeLimit(.minutes(5)))
    func realIOSBuildLaunchReuseRetainAndDelete() async throws {
        let listing = try await CommandRunner.run("xcrun", ["simctl", "list", "devices", "available", "--json"])
        let devices = try JSONSerialization.jsonObject(with: Data(listing.utf8)) as! [String: Any]
        let byRuntime = devices["devices"] as! [String: [[String: Any]]]
        let prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        let runtime = try #require(byRuntime.keys.sorted().last {
            $0.hasPrefix(prefix) && (Int($0.dropFirst(prefix.count).split(separator: "-").first ?? "") ?? 0) >= 26
                && !(byRuntime[$0] ?? []).isEmpty
        })
        let template = try #require(byRuntime[runtime]?.first)
        let templateID = try #require(template["udid"] as? String)
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        var preserveFixture = false
        defer { if !preserveFixture { try? FileManager.default.removeItem(at: directory) } }
        let root = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try SmokeProject.write(to: root, iOS: true)
        _ = try await CommandRunner.git(root.path, ["init", "--quiet"])
        _ = try await CommandRunner.git(root.path, ["add", "."])
        _ = try await CommandRunner.git(root.path, ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "fixture"])
        let sha = try await CommandRunner.git(root.path, ["rev-parse", "HEAD"])
        let service = ReviewService(storage: directory.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: service.worktrees, withIntermediateDirectories: true)
        let id = UUID()
        let path = service.worktrees.appendingPathComponent(id.uuidString).path
        _ = try await CommandRunner.git(root.path, ["worktree", "add", "--detach", path, sha])
        var repository = Repository(path: root.path, slug: "fixture/ios", entry: "Smoke.xcodeproj")
        repository.buildSettings = BuildSettings(scheme: "Smoke", destination: BuildDestination(id: templateID, name: template["name"] as! String, platform: "iOS Simulator"))
        let session = Session(id: id, repository: repository, prURL: "https://github.com/fixture/ios/pull/1", number: 1, title: "Simulator fixture", sha: sha, path: path)
        var state = SavedState(); state.repositories = [repository]; state.sessions = [session]
        try service.stateStore.save(state)
        let coordinator = ReviewCoordinator(service: service)
        do {
            let first = try await coordinator.runOnSimulator(session)
            #expect(first.record.status == .succeeded, "\(first.record.message)")
            if first.record.status != .succeeded {
                if let log = coordinator.state.sessions.first?.buildRecords?.last?.logPath {
                    print(try String(contentsOfFile: log, encoding: .utf8).suffix(12000))
                }
            }
            let deviceID = try #require(first.deviceID)
            #expect(deviceID != templateID)
            let dataPath = try await CommandRunner.run("xcrun", ["simctl", "get_app_container", deviceID, "dev.fixture.review-simulator", "data"])
            var sentinel = URL(fileURLWithPath: dataPath).appendingPathComponent("Documents/reuse-sentinel")
            try Data("keep across launch".utf8).write(to: sentinel)
            let second = try await coordinator.runOnSimulator(session)
            #expect(second.record.status == .succeeded, "\(second.record.message)")
            #expect(second.deviceID == deviceID)
            // CoreSimulator can relocate the data container during an upgrade install.
            let reinstalledData = try await CommandRunner.run("xcrun", ["simctl", "get_app_container", deviceID, "dev.fixture.review-simulator", "data"])
            sentinel = URL(fileURLWithPath: reinstalledData).appendingPathComponent("Documents/reuse-sentinel")
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep across launch")
            // A protected worktree also protects its Simulator.
            try Data("unsaved".utf8).write(to: URL(fileURLWithPath: path).appendingPathComponent("untracked.txt"))
            await #expect(throws: ReviewError.self) { try await coordinator.remove(session) }
            #expect(coordinator.state.simulators?.count == 1)
            try FileManager.default.removeItem(at: URL(fileURLWithPath: path).appendingPathComponent("untracked.txt"))
            try await coordinator.remove(session, keepSimulators: true)
            #expect(coordinator.state.sessions.isEmpty)
            let owned = try #require(coordinator.state.simulators?.first)
            #expect(try String(contentsOf: sentinel, encoding: .utf8) == "keep across launch")
            try await coordinator.removeSimulator(owned.id)
            #expect(coordinator.state.simulators?.isEmpty == true)
            let after = try await CommandRunner.run("xcrun", ["simctl", "list", "devices", "--json"])
            #expect(!after.contains(deviceID))
            #expect(after.contains(templateID))
            #expect(!FileManager.default.fileExists(atPath: path))
        } catch {
            // Cleanup only records created by this test, even on assertion/command failure.
            for owned in coordinator.state.simulators ?? [] {
                do { try await coordinator.removeSimulator(owned.id) }
                catch {
                    preserveFixture = true
                    print("Cleanup failed; ownership state retained at \(service.storage.path): \(error)")
                }
            }
            throw error
        }
    }
}
