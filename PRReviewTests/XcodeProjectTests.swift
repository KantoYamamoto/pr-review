import Foundation
import Testing
@testable import PRReview

@Suite("Xcode container boundaries")
struct XcodeProjectTests {
    @Test(arguments: ["App.xcodeproj", "Nested/App.xcworkspace"])
    func openingAndBuildingResolveTheSameContainer(_ entry: String) async throws {
        let fixture = try ProjectFixture(entry: entry)
        defer { fixture.remove() }
        let service = ReviewService(storage: fixture.storage)
        let project = try XcodeProject(root: fixture.session.path, relativePath: entry)
        #expect(try service.entry(for: fixture.session) == project.url)
        let builds = fixture.buildService { arguments in
            #expect(arguments.contains(project.url.path))
            #expect(arguments.contains(entry.hasSuffix("xcworkspace") ? "-workspace" : "-project"))
        }
        #expect(try await builds.schemes(fixture.session) == ["App"])
    }

    @Test(arguments: ["../App.xcodeproj", "/App.xcodeproj", ".git/App.xcodeproj", "App.xcodeproj/", "", "Other.txt"])
    func malformedEntriesAreRejectedBeforeOpeningOrRunningXcode(_ entry: String) async throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        var session = fixture.session
        session.repository.entry = entry
        try await expectRejected(session, fixture: fixture)
    }

    @Test(arguments: ["container", "marker", "worktree", "missingMarker", "forgedWorktree"])
    func unsafeContainersAreRejectedByBothEntryPoints(_ kind: String) async throws {
        let fixture = try ProjectFixture()
        defer { fixture.remove() }
        let container = URL(fileURLWithPath: fixture.session.path).appendingPathComponent("App.xcodeproj")
        var session = fixture.session
        switch kind {
        case "container":
            let moved = fixture.storage.appendingPathComponent("Moved.xcodeproj")
            try FileManager.default.moveItem(at: container, to: moved)
            try FileManager.default.createSymbolicLink(at: container, withDestinationURL: moved)
        case "marker":
            let marker = container.appendingPathComponent("project.pbxproj")
            let moved = fixture.storage.appendingPathComponent("project.pbxproj")
            try FileManager.default.moveItem(at: marker, to: moved)
            try FileManager.default.createSymbolicLink(at: marker, withDestinationURL: moved)
        case "worktree":
            let worktree = URL(fileURLWithPath: session.path)
            let moved = fixture.storage.appendingPathComponent("MovedWorktree")
            try FileManager.default.moveItem(at: worktree, to: moved)
            try FileManager.default.createSymbolicLink(at: worktree, withDestinationURL: moved)
        case "missingMarker":
            try FileManager.default.removeItem(at: container.appendingPathComponent("project.pbxproj"))
        default:
            session.id = UUID()
        }
        try await expectRejected(session, fixture: fixture)
    }

    private func expectRejected(_ session: Session, fixture: ProjectFixture) async throws {
        #expect(throws: ReviewError.self) { try ReviewService(storage: fixture.storage).entry(for: session) }
        let builds = fixture.buildService { _ in Issue.record("Unsafe container reached xcodebuild") }
        await #expect(throws: ReviewError.self) { try await builds.schemes(session) }
    }
}

private struct ProjectFixture {
    let storage: URL
    let session: Session

    init(entry: String = "App.xcodeproj") throws {
        storage = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let id = UUID()
        let path = storage.appendingPathComponent("Worktrees/\(id.uuidString)")
        let container = path.appendingPathComponent(entry)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let marker = entry.hasSuffix("xcworkspace") ? "contents.xcworkspacedata" : "project.pbxproj"
        try Data("fixture".utf8).write(to: container.appendingPathComponent(marker))
        session = Session(id: id, repository: Repository(path: "/unused", slug: "owner/repo", entry: entry),
                          prURL: "https://github.com/owner/repo/pull/1", number: 1, title: "PR", sha: "abc", path: path.path)
    }

    func buildService(check: @escaping @Sendable ([String]) -> Void) -> XcodeBuildService {
        XcodeBuildService(storage: storage, command: { _, arguments, _ in
            check(arguments)
            return CommandResult(standardOutput: #"{"project":{"schemes":["App"]}}"#,
                                 standardError: "", exitCode: 0, terminationDescription: "exited(0)")
        })
    }

    func remove() { try? FileManager.default.removeItem(at: storage) }
}
