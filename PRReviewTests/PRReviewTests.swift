import XCTest
@testable import PRReview

@MainActor
final class PRReviewTests: XCTestCase {
    func testProjectDiscoveryFiltersAndSortsRealContainers() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: session.repository.path)
        _ = try TestCommands.git(root.path, ["remote", "add", "origin", "https://github.com/owner/repo.git"])
        func container(_ path: String, marker: String = "project.pbxproj") throws {
            let folder = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: folder.appendingPathComponent(marker))
        }
        try container("Z App.xcodeproj")
        try container("Nested/A.xcodeproj")
        try container("Review.xcworkspace", marker: "contents.xcworkspacedata")
        try container("Z App.xcodeproj/project.xcworkspace", marker: "contents.xcworkspacedata")
        try container("Pods/Dependency.xcodeproj")
        try container("ignored/Hidden.xcodeproj")
        try container("build/Generated.xcodeproj")
        try container("Package.bundle/Embedded.xcodeproj")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Invalid.xcodeproj"), withIntermediateDirectories: true)
        try Data("fake".utf8).write(to: root.appendingPathComponent("File.xcodeproj"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Linked.xcodeproj").path, withDestinationPath: root.appendingPathComponent("Z App.xcodeproj").path)
        // A tracked dependency is excluded too, while tracked ordinary projects remain discoverable.
        _ = try TestCommands.git(root.path, ["add", "Pods", "Nested"])
        let found = try await service.discoverProjects(path: root.appendingPathComponent("Nested").path)
        await expectEqual(found.root, root.path)
        await expectEqual(found.entries, ["Review.xcworkspace", "Nested/A.xcodeproj", "Z App.xcodeproj"])
        let registered = try await service.register(path: root.path, entryPath: root.appendingPathComponent(found.entries[0]).path)
        await expectEqual(registered.entry, "Review.xcworkspace")
        for invalid in ["Invalid.xcodeproj", "File.xcodeproj", "Linked.xcodeproj", "Missing.xcodeproj"] {
            await expectThrowsError(try await service.register(path: root.path, entryPath: root.appendingPathComponent(invalid).path))
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("Nested/A.xcodeproj/project.pbxproj"))
        await expectFalse(try await service.discoverProjects(path: root.path).entries.contains("Nested/A.xcodeproj"))
    }

    func testDiscoveryReturnsNoCandidatesAndRejectsSymlinkMarker() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = URL(fileURLWithPath: session.repository.path)
        _ = try TestCommands.git(root.path, ["remote", "add", "origin", "https://github.com/owner/repo.git"])
        await expectEqual(try await service.discoverProjects(path: root.path).entries, [])
        let project = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: project.appendingPathComponent("project.pbxproj").path, withDestinationPath: root.appendingPathComponent("tracked.txt").path)
        await expectEqual(try await service.discoverProjects(path: root.path).entries, [])
        await expectThrowsError(try await service.register(path: root.path, entryPath: project.path))
    }

    func testSavePreservesCorruptExistingState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = ReviewService(storage: directory)
        let file = directory.appendingPathComponent("state.json")
        let original = Data("{incomplete saved state".utf8)
        try original.write(to: file)
        await expectThrowsError(try service.stateStore.load())
        await expectThrowsError(try service.stateStore.save(SavedState()))
        await expectEqual(try Data(contentsOf: file), original)
    }

    func testPRParsing() async throws {
        let pr = try PullRequest(" https://github.com/owner/repo/pull/42/files?diff=split ")
        await expectEqual(pr.url, "https://github.com/owner/repo/pull/42")
        for invalid in ["https://evil.test/a/b/pull/1", "https://github.com/a/b/pull/0", "https://github.com/a/b/issues/1", "file:///tmp/repo", "https://user@github.com/a/b/pull/1"] {
            await expectThrowsError(try PullRequest(invalid))
        }
        await expectEqual(try ReviewService.githubSlug("git@github.com:owner/repo.git"), "owner/repo")
        await expectThrowsError(try ReviewService.githubSlug("https://evil.test/owner/repo.git"))
    }

    func fixture() throws -> (URL, ReviewService, Session) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try TestCommands.git(repo.path, ["init"])
        _ = try TestCommands.git(repo.path, ["config", "commit.gpgsign", "false"])
        _ = try TestCommands.git(repo.path, ["config", "user.name", "Test"])
        _ = try TestCommands.git(repo.path, ["config", "user.email", "test@example.invalid"])
        try Data("initial".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try Data("ignored/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        _ = try TestCommands.git(repo.path, ["add", "."])
        _ = try TestCommands.git(repo.path, ["commit", "-m", "initial"])
        let sha = try TestCommands.git(repo.path, ["rev-parse", "HEAD"])
        let service = ReviewService(storage: directory.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: service.worktrees, withIntermediateDirectories: true)
        let id = UUID()
        let path = service.worktrees.appendingPathComponent(id.uuidString).path
        _ = try TestCommands.git(repo.path, ["worktree", "add", "--detach", path, sha])
        let repository = Repository(path: repo.path, slug: "owner/repo", entry: "App.xcodeproj")
        let session = Session(id: id, repository: repository, prURL: "https://github.com/owner/repo/pull/1", number: 1, title: "Test", sha: sha, path: path)
        return (directory, service, session)
    }

    func testCleanRemovalLeavesMainWorkUntouched() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = URL(fileURLWithPath: session.repository.path).appendingPathComponent("tracked.txt")
        try Data("unfinished main work".utf8).write(to: main)
        await expectEqual(try await service.inspect(session).description, "")
        var state = SavedState(); state.sessions = [session]
        try service.stateStore.save(state)
        await expectEqual(try service.stateStore.load().sessions, [session])
        try await service.remove(session)
        await expectFalse(FileManager.default.fileExists(atPath: session.path))
        await expectEqual(try String(contentsOf: main, encoding: .utf8), "unfinished main work")
        await expectFalse(try TestCommands.git(session.repository.path, ["worktree", "list", "--porcelain"]).contains(session.path))
    }

    func testRefusesModifiedUntrackedIgnoredAndLocalCommits() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: session.path)
        let tracked = worktree.appendingPathComponent("tracked.txt")
        try Data("changed".utf8).write(to: tracked)
        await expectThrowsError(try await service.remove(session))
        _ = try TestCommands.git(session.path, ["restore", "tracked.txt"])
        let untracked = worktree.appendingPathComponent("secret.xcconfig")
        try Data("local config".utf8).write(to: untracked)
        await expectThrowsError(try await service.remove(session))
        try FileManager.default.removeItem(at: untracked)
        let ignored = worktree.appendingPathComponent("ignored")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: ignored.appendingPathComponent("config"))
        await expectThrowsError(try await service.remove(session))
        try FileManager.default.removeItem(at: ignored)
        try Data("local commit".utf8).write(to: tracked)
        _ = try TestCommands.git(session.path, ["add", "."])
        _ = try TestCommands.git(session.path, ["commit", "-m", "review edits"])
        await expectThrowsError(try await service.remove(session))
        await expectTrue(FileManager.default.fileExists(atPath: session.path))
    }

    func testRefusesForgedPathAndEscapingProject() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var forged = session; forged.path = session.repository.path
        await expectThrowsError(try await service.remove(forged))
        var escape = session; escape.repository.entry = "../../repository"
        await expectThrowsError(try service.entry(for: escape))
        await expectTrue(FileManager.default.fileExists(atPath: session.repository.path))
    }

    func testRemovesWorktreeWithIgnoredXcodeUIState() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: session.path)
        _ = try TestCommands.git(session.path, ["config", "--add", "core.excludesFile", directory.appendingPathComponent("excludes").path])
        try Data("xcuserdata/\n".utf8).write(to: directory.appendingPathComponent("excludes"))
        for path in [
            "ExampleApp.xcodeproj/project.xcworkspace/xcuserdata/developer.xcuserdatad/UserInterfaceState.xcuserstate",
            "ExampleApp.xcodeproj/xcuserdata/developer.xcuserdatad/xcschemes/xcschememanagement.plist",
            "Nested/App.xcworkspace/xcuserdata/another.xcuserdatad/UserInterfaceState.xcuserstate"
        ] {
            let file = worktree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("generated state".utf8).write(to: file)
        }
        await expectEqual(try await service.inspect(session).description, "")
        try await service.remove(session)
        await expectFalse(FileManager.default.fileExists(atPath: session.path))
    }

    func testXcodeStateExceptionDoesNotDiscardBreakpointsOrTrackedEdits() async throws {
        let (directory, service, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: initial.path)
        let excludes = directory.appendingPathComponent("excludes")
        try Data("xcuserdata/\n".utf8).write(to: excludes)
        _ = try TestCommands.git(initial.path, ["config", "core.excludesFile", excludes.path])
        let base = "ExampleApp.xcodeproj/xcuserdata/developer.xcuserdatad/"
        for path in ["xcdebugger/Breakpoints_v2.xcbkptlist", "xcschemes/Custom.xcscheme", "secrets.xcconfig"] {
            let file = worktree.appendingPathComponent(base + path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file)
            await expectThrowsError(try await service.remove(initial))
            await expectTrue(FileManager.default.fileExists(atPath: file.path))
            try FileManager.default.removeItem(at: file)
        }
        let state = worktree.appendingPathComponent(base + "UserInterfaceState.xcuserstate")
        try Data("tracked state".utf8).write(to: state)
        _ = try TestCommands.git(initial.path, ["add", "-f", state.path])
        _ = try TestCommands.git(initial.path, ["commit", "-m", "track state"])
        var session = initial
        session.sha = try TestCommands.git(initial.path, ["rev-parse", "HEAD"])
        try Data("edited tracked state".utf8).write(to: state)
        await expectThrowsError(try await service.remove(session))
    }

    // Only GitHub metadata / origin identity are simulated. Fetch and checkout
    // use a real bare repository with GitHub-style PR refs.
    func remoteService(directory: URL, service: ReviewService, session: Session, sha: String) throws -> ReviewService {
        let remote = directory.appendingPathComponent("remote.git")
        _ = try TestCommands.run("git", ["init", "--bare", remote.path])
        _ = try TestCommands.git(session.repository.path, ["remote", "add", "origin", remote.path])
        _ = try TestCommands.git(session.repository.path, ["push", "origin", "\(sha):refs/pull/1/head"])
        var state = SavedState(); state.sessions = [session]
        try service.stateStore.save(state)
        return ReviewService(storage: service.storage, command: { name, args in
            if name == "gh" { return "{\"title\":\"Updated PR\",\"headRefOid\":\"\(sha)\"}" }
            if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
            return try TestCommands.run(name, args)
        })
    }

    func testUpdateFetchesLatestDetachedCommitAndPersistsBaseline() async throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainFile = URL(fileURLWithPath: session.repository.path).appendingPathComponent("tracked.txt")
        try Data("new PR version".utf8).write(to: mainFile)
        _ = try TestCommands.git(session.repository.path, ["commit", "-am", "additional PR commit"])
        let sha = try TestCommands.git(session.repository.path, ["rev-parse", "HEAD"])
        let service = try remoteService(directory: directory, service: original, session: session, sha: sha)
        try Data("unfinished main work".utf8).write(to: mainFile)
        let worktree = URL(fileURLWithPath: session.path)
        let stateFile = worktree.appendingPathComponent("App.xcodeproj/xcuserdata/test.xcuserdatad/UserInterfaceState.xcuserstate")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("UI state".utf8).write(to: stateFile)
        let excludes = directory.appendingPathComponent("excludes")
        try Data("xcuserdata/\n".utf8).write(to: excludes)
        _ = try TestCommands.git(session.path, ["config", "core.excludesFile", excludes.path])

        let updated = try await ReviewCoordinator(service: service).update(session)
        await expectEqual(updated.sha, sha)
        await expectEqual(updated.id, session.id)
        await expectEqual(updated.path, session.path)
        await expectNotNil(updated.updatedAt)
        await expectEqual(try service.stateStore.load().sessions.first, updated)
        await expectEqual(try TestCommands.git(session.path, ["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD")
        await expectEqual(try String(contentsOf: worktree.appendingPathComponent("tracked.txt"), encoding: .utf8), "new PR version")
        await expectEqual(try String(contentsOf: mainFile, encoding: .utf8), "unfinished main work")
        await expectEqual(try String(contentsOf: stateFile, encoding: .utf8), "UI state")
        // A second refresh is a no-op and retains its last update date.
        await expectEqual(try await ReviewCoordinator(service: service).update(updated), updated)
        await expectEqual(try TestCommands.git(session.repository.path, ["for-each-ref", "refs/prreview"]), "")
        try await service.remove(updated)
    }

    func testUpdateProtectsEditsUntrackedIgnoredAndLocalCommits() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: session.path)
        let tracked = worktree.appendingPathComponent("tracked.txt")
        try Data("edited".utf8).write(to: tracked)
        await expectThrowsError(try await service.update(session))
        await expectEqual(try String(contentsOf: tracked, encoding: .utf8), "edited")
        _ = try TestCommands.git(session.path, ["restore", "tracked.txt"])
        for path in ["local.xcconfig", "ignored/secrets"] {
            let file = worktree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file)
            await expectThrowsError(try await service.update(session))
            await expectEqual(try String(contentsOf: file, encoding: .utf8), "keep")
            try FileManager.default.removeItem(at: file)
        }
        try Data("local commit".utf8).write(to: tracked)
        _ = try TestCommands.git(session.path, ["commit", "-am", "local review edits"])
        let head = try TestCommands.git(session.path, ["rev-parse", "HEAD"])
        await expectThrowsError(try await service.update(session))
        await expectEqual(try TestCommands.git(session.path, ["rev-parse", "HEAD"]), head)
    }

    func testUpdateHandlesForcePushedPRWithoutMerging() async throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try TestCommands.git(session.repository.path, ["checkout", "--orphan", "rewritten"])
        _ = try TestCommands.git(session.repository.path, ["commit", "-m", "rewritten PR"])
        let sha = try TestCommands.git(session.repository.path, ["rev-parse", "HEAD"])
        let service = try remoteService(directory: directory, service: original, session: session, sha: sha)
        let updated = try await ReviewCoordinator(service: service).update(session)
        await expectEqual(updated.sha, sha)
        await expectEqual(try TestCommands.git(session.path, ["rev-parse", "HEAD"]), sha)
        await expectEqual(try await service.inspect(updated).description, "")
    }

    func testFetchRaceLeavesReviewAtOriginalCommit() async throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let underlying = try remoteService(directory: directory, service: original, session: session, sha: session.sha)
        let service = ReviewService(storage: underlying.storage, command: { name, args in
            if name == "gh" { return "{\"title\":\"PR\",\"headRefOid\":\"0000000000000000000000000000000000000000\"}" }
            if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
            return try TestCommands.run(name, args)
        })
        await expectThrowsError(try await service.update(session))
        await expectEqual(try TestCommands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
        await expectEqual(try service.stateStore.load().sessions.first, session)
        await expectEqual(try TestCommands.git(session.repository.path, ["for-each-ref", "refs/prreview"]), "")
    }

    func testUpdateDoesNotOverwriteIgnoredStateNewlyTrackedByPR() async throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relative = "App.xcodeproj/xcuserdata/test.xcuserdatad/UserInterfaceState.xcuserstate"
        let mainFile = URL(fileURLWithPath: session.repository.path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: mainFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PR version".utf8).write(to: mainFile)
        _ = try TestCommands.git(session.repository.path, ["add", "-f", relative])
        _ = try TestCommands.git(session.repository.path, ["commit", "-m", "new tracked state"])
        let sha = try TestCommands.git(session.repository.path, ["rev-parse", "HEAD"])
        let service = try remoteService(directory: directory, service: original, session: session, sha: sha)
        let local = URL(fileURLWithPath: session.path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep local state".utf8).write(to: local)
        let excludes = directory.appendingPathComponent("excludes")
        try Data("xcuserdata/\n".utf8).write(to: excludes)
        _ = try TestCommands.git(session.path, ["config", "core.excludesFile", excludes.path])
        await expectThrowsError(try await service.update(session))
        await expectEqual(try String(contentsOf: local, encoding: .utf8), "keep local state")
        await expectEqual(try TestCommands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
        await expectEqual(try service.stateStore.load().sessions.first, session)
    }

    func writeConfig(_ relative: String, root: String, content: String = "test configuration") throws -> URL {
        let file = URL(fileURLWithPath: root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
        return file
    }

    func copyFixture() async throws -> (URL, ReviewService, Session) {
        let (directory, original, initial) = try fixture()
        let path = "ignored/GoogleService-Info.plist"
        _ = try writeConfig(path, root: initial.repository.path)
        let repository = try await original.configureCopies(initial.repository, paths: [path])
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        let session = try await service.create(PullRequest(initial.prURL), repository: repository)
        var state = try service.stateStore.load(); state.sessions = [session]; state.repositories = [repository]
        try service.stateStore.save(state)
        return (directory, service, session)
    }

    func testLegacyStateDecodesWithoutCopySettings() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var state = SavedState(); state.sessions = [session]; state.repositories = [session.repository]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        var repos = try XCTUnwrap(json["repositories"] as? [[String: Any]])
        repos[0].removeValue(forKey: "copyPaths"); json["repositories"] = repos
        var sessions = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        sessions[0].removeValue(forKey: "copiedFiles")
        var repo = try XCTUnwrap(sessions[0]["repository"] as? [String: Any])
        repo.removeValue(forKey: "copyPaths"); sessions[0]["repository"] = repo; json["sessions"] = sessions
        let decoded = try JSONDecoder().decode(SavedState.self, from: JSONSerialization.data(withJSONObject: json))
        await expectNil(decoded.repositories[0].copyPaths)
        await expectNil(decoded.sessions[0].copiedFiles)
        await expectEqual(try await service.inspect(decoded.sessions[0]).description, "")
    }

    func testCopyConfigurationRejectsTrackedUnsafeDirectoryAndSymlinkPaths() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = session.repository
        _ = try writeConfig("ignored/valid.xcconfig", root: repo.path)
        let outside = try writeConfig("outside", root: directory.path)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/ignored/link", withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/ignored/broken", withDestinationPath: directory.path + "/missing")
        for path in ["tracked.txt", "../outside", outside.path, ".git/config", "ignored/../valid.xcconfig", "ignored//valid.xcconfig", "ignored", "ignored/link", "ignored/broken"] {
            await expectThrowsError(try await service.configureCopies(repo, paths: [path]), path)
        }
        let configured = try await service.configureCopies(repo, paths: ["ignored/valid.xcconfig", "ignored/valid.xcconfig"])
        await expectEqual(configured.copyPaths, ["ignored/valid.xcconfig"])
        await expectThrowsError(try service.relativeCopyPath(outside, repository: repo))
    }

    func testCreationCopiesIgnoredConfigsWithPrivatePermissionsAndSafeCleanup() async throws {
        let (directory, service, session) = try await copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relative = "ignored/GoogleService-Info.plist"
        let copy = URL(fileURLWithPath: session.path).appendingPathComponent(relative)
        let source = URL(fileURLWithPath: session.repository.path).appendingPathComponent(relative)
        await expectEqual(try String(contentsOf: copy, encoding: .utf8), "test configuration")
        await expectEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        await expectEqual(session.copiedFiles?.count, 1)
        await expectEqual(session.copiedFiles?.first?.sha256.count, 64)
        await expectFalse(String(decoding: try JSONEncoder().encode(session), as: UTF8.self).contains("test configuration"))
        await expectEqual(try service.stateStore.load().sessions.first, session)
        try Data("changed source".utf8).write(to: source)
        await expectEqual(try await service.inspect(session).description, "")
        try await service.remove(session)
        await expectEqual(try String(contentsOf: source, encoding: .utf8), "changed source")
    }

    func testEditedCopiesBlockUpdateAndRemovalAfterReload() async throws {
        let (directory, service, session) = try await copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist")
        try Data("edited locally".utf8).write(to: copy)
        let loaded = try XCTUnwrap(service.stateStore.load().sessions.first)
        await expectTrue(try await service.inspect(loaded).description.contains("コピーしたファイルが変更されています"))
        await expectThrowsError(try await service.update(loaded))
        await expectThrowsError(try await service.remove(loaded))
        await expectEqual(try String(contentsOf: copy, encoding: .utf8), "edited locally")
        await expectEqual(try TestCommands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
        try FileManager.default.removeItem(at: copy)
        await expectEqual(try await service.inspect(loaded).description, "")
        try await service.remove(loaded)
    }

    func testCopySymlinkReplacementIsProtected() async throws {
        let (directory, service, session) = try await copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist")
        let outside = try writeConfig("outside-config", root: directory.path, content: "keep outside")
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.createSymbolicLink(atPath: copy.path, withDestinationPath: outside.path)
        await expectThrowsError(try await service.remove(session))
        await expectThrowsError(try await service.update(session))
        await expectEqual(try String(contentsOf: outside, encoding: .utf8), "keep outside")
    }

    func testUpdatePreservesCopiesWhenIgnoreRuleDisappears() async throws {
        let (directory, service, session) = try await copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = session.repository.path
        try Data("".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(".gitignore"))
        _ = try TestCommands.git(root, ["commit", "-am", "remove ignore rule"])
        let sha = try TestCommands.git(root, ["rev-parse", "HEAD"])
        _ = try TestCommands.git(root, ["push", "origin", "HEAD:refs/pull/1/head"])
        let updatedService = ReviewService(storage: service.storage, command: { name, args in
            if name == "gh" { return "{\"title\":\"Updated\",\"headRefOid\":\"\(sha)\"}" }
            if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
            return try TestCommands.run(name, args)
        })
        let updated = try await ReviewCoordinator(service: updatedService).update(session)
        await expectEqual(updated.copiedFiles, session.copiedFiles)
        await expectEqual(updated.sha, sha)
        await expectEqual(try String(contentsOf: URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist"), encoding: .utf8), "test configuration")
        await expectEqual(try await updatedService.inspect(updated).description, "")
        try await updatedService.remove(updated)
        await expectTrue(FileManager.default.fileExists(atPath: root + "/ignored/GoogleService-Info.plist"))
    }

    func testUpdateStopsBeforePRTracksCopyOrReplacesItsParentWithSymlink() async throws {
        for symlink in [false, true] {
            let (directory, service, session) = try await copyFixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let root = session.repository.path
            if symlink {
                try FileManager.default.removeItem(atPath: root + "/ignored")
                try FileManager.default.createSymbolicLink(atPath: root + "/ignored", withDestinationPath: "other-directory")
                _ = try TestCommands.git(root, ["add", "-f", "ignored"])
            } else {
                _ = try TestCommands.git(root, ["add", "-f", "ignored/GoogleService-Info.plist"])
            }
            _ = try TestCommands.git(root, ["commit", "-m", "PR collision"])
            let sha = try TestCommands.git(root, ["rev-parse", "HEAD"])
            _ = try TestCommands.git(root, ["push", "origin", "HEAD:refs/pull/1/head"])
            let updatedService = ReviewService(storage: service.storage, command: { name, args in
                if name == "gh" { return "{\"title\":\"Collision\",\"headRefOid\":\"\(sha)\"}" }
                if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
                return try TestCommands.run(name, args)
            })
            await expectThrowsError(try await updatedService.update(session))
            await expectEqual(try TestCommands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
            await expectEqual(try String(contentsOf: URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist"), encoding: .utf8), "test configuration")
            await expectEqual(try updatedService.stateStore.load().sessions.first, session)
        }
    }

    func testCreationFailureDoesNotLeaveNewWorktreeWhenPRDoesNotIgnoreCopy() async throws {
        let (directory, original, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The user's local ignore rule is not present in the PR snapshot.
        let source = try writeConfig("local.xcconfig", root: initial.repository.path)
        try Data("local.xcconfig\n".utf8).write(to: URL(fileURLWithPath: initial.repository.path).appendingPathComponent(".gitignore"))
        let configured = try await original.configureCopies(initial.repository, paths: ["local.xcconfig"])
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        let before = try TestCommands.git(initial.repository.path, ["worktree", "list", "--porcelain"])
        await expectThrowsError(try await service.create(PullRequest(initial.prURL), repository: configured))
        await expectEqual(try TestCommands.git(initial.repository.path, ["worktree", "list", "--porcelain"]), before)
        await expectEqual(try String(contentsOf: source, encoding: .utf8), "test configuration")
    }

    func testCopyPathsWithWhitespaceAndGitPathspecCharactersAreLiteral() async throws {
        let (directory, original, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relative = "ignored/ :(glob)* config\nfile.xcconfig "
        _ = try writeConfig(relative, root: initial.repository.path)
        let configured = try await original.configureCopies(initial.repository, paths: [relative])
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        let session = try await service.create(PullRequest(initial.prURL), repository: configured)
        await expectEqual(try await service.inspect(session).description, "")
        try await service.remove(session)
    }

    func testLockedRemovalPreservesCopiesEvenWhenSourceIsGone() async throws {
        for losesIgnoreRule in [false, true] {
            let (directory, service, initial) = try await copyFixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            var session = initial
            var removalService = service
            let root = initial.repository.path
            if losesIgnoreRule {
                try Data("".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(".gitignore"))
                _ = try TestCommands.git(root, ["commit", "-am", "remove ignore rule"])
                let sha = try TestCommands.git(root, ["rev-parse", "HEAD"])
                _ = try TestCommands.git(root, ["push", "origin", "HEAD:refs/pull/1/head"])
                removalService = ReviewService(storage: service.storage, command: { name, args in
                    if name == "gh" { return "{\"title\":\"Updated\",\"headRefOid\":\"\(sha)\"}" }
                    if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
                    return try TestCommands.run(name, args)
                })
                session = try await ReviewCoordinator(service: removalService).update(initial)
            }
            let relative = "ignored/GoogleService-Info.plist"
            let copy = URL(fileURLWithPath: session.path).appendingPathComponent(relative)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: copy.path)
            try FileManager.default.removeItem(atPath: root + "/" + relative)
            _ = try TestCommands.git(root, ["worktree", "lock", session.path])
            await expectThrowsError(try await removalService.remove(session))
            await expectEqual(try String(contentsOf: copy, encoding: .utf8), "test configuration")
            await expectEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            await expectEqual(try removalService.stateStore.load().sessions.first, session)
            await expectEqual(try await removalService.inspect(session).description, "")
            _ = try TestCommands.git(root, ["worktree", "unlock", session.path])
            try await removalService.remove(session)
        }
    }
    func testCoordinatorRollsBackCheckoutWhenSavingFails() async throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeConfig("tracked.txt", root: session.repository.path, content: "new PR")
        _ = try TestCommands.git(session.repository.path, ["commit", "-am", "new commit"])
        let sha = try TestCommands.git(session.repository.path, ["rev-parse", "HEAD"])
        let service = try remoteService(directory: directory, service: original, session: session, sha: sha)
        let store = StateStore(storage: service.storage, save: { _ in throw ReviewError("disk unavailable") })
        let coordinator = ReviewCoordinator(service: service, store: store)
        await expectThrowsError(try await coordinator.update(session))
        await expectEqual(try TestCommands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
        await expectEqual(coordinator.state.sessions.first?.sha, session.sha)
        await expectEqual(try service.stateStore.load().sessions.first?.sha, session.sha)
        await expectFalse(coordinator.busy)
    }

    func testCreateUsesCurrentRepositorySettingsFromStoredState() async throws {
        let (directory, original, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        let settings = BuildSettings(scheme: "App", destination: BuildDestination(id: "Mac", name: "My Mac", platform: "macOS"))
        var repository = initial.repository
        repository.buildSettings = settings
        var state = SavedState()
        state.repositories = [repository]
        try service.stateStore.save(state)
        let path = "ignored/local.xcconfig"
        _ = try writeConfig(path, root: repository.path, content: "local settings")
        let coordinator = ReviewCoordinator(service: service)
        _ = try await coordinator.configureCopies(initial.repository, paths: [path])
        let session = try await coordinator.create(PullRequest(initial.prURL), repository: initial.repository)
        await expectEqual(session.repository.buildSettings, settings)
        await expectEqual(session.repository.copyPaths, [path])
        await expectEqual(session.copiedFiles?.map(\.path), [path])
        let copy = URL(fileURLWithPath: session.path).appendingPathComponent(path)
        await expectEqual(try String(contentsOf: copy, encoding: .utf8), "local settings")
        await expectEqual(try service.stateStore.load().sessions.first, session)
    }

    func testBuildDefaultsUseStoredSessionRepositoryIdentity() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = Repository(path: "/other", slug: "owner/other", entry: "Other.xcodeproj")
        var state = SavedState()
        state.repositories = [session.repository, other]
        state.sessions = [session]
        try service.stateStore.save(state)
        let coordinator = ReviewCoordinator(service: service)
        var snapshot = session
        snapshot.repository = other
        let settings = BuildSettings(scheme: "App", destination: BuildDestination(id: "Mac", name: "My Mac", platform: "macOS"))
        try coordinator.saveBuildSettings(settings, for: snapshot)
        let saved = try service.stateStore.load()
        await expectEqual(saved.sessions.first?.repository.buildSettings, settings)
        await expectEqual(saved.repositories.first?.buildSettings, settings)
        await expectNil(saved.repositories.last?.buildSettings)
    }

    func testCoordinatorRetainsCreatedSessionOnSaveFailureAndCanRetry() async throws {
        let (directory, original, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        var initialState = SavedState()
        initialState.repositories = [initial.repository]
        try service.stateStore.save(initialState)
        let failure = RetryableSave(store: service.stateStore)
        let store = StateStore(storage: service.storage, save: { try failure.save($0) })
        let coordinator = ReviewCoordinator(service: service, store: store)
        await expectThrowsError(try await coordinator.create(PullRequest(initial.prURL), repository: initial.repository))
        let created = try XCTUnwrap(coordinator.state.sessions.first)
        await expectTrue(FileManager.default.fileExists(atPath: created.path + "/.git"))
        await expectTrue(coordinator.hasUnsavedChanges)
        await expectTrue(try service.stateStore.load().sessions.isEmpty)
        failure.allowSaving()
        try coordinator.retrySave()
        await expectFalse(coordinator.hasUnsavedChanges)
        await expectEqual(try service.stateStore.load().sessions.first, created)
    }

    func testCoordinatorReflectsSuccessfulRemovalWhenSaveFailsAndCanRetry() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var initial = SavedState(); initial.sessions = [session]
        try service.stateStore.save(initial)
        let failure = RetryableSave(store: service.stateStore)
        let store = StateStore(storage: service.storage, save: { try failure.save($0) })
        let coordinator = ReviewCoordinator(service: service, store: store)
        await expectThrowsError(try await coordinator.remove(session))
        await expectFalse(FileManager.default.fileExists(atPath: session.path))
        await expectTrue(coordinator.state.sessions.isEmpty)
        await expectTrue(coordinator.hasUnsavedChanges)
        failure.allowSaving()
        try coordinator.retrySave()
        await expectTrue(try service.stateStore.load().sessions.isEmpty)
        await expectFalse(coordinator.hasUnsavedChanges)
    }

    func testCoordinatorGateRemainsHeldAcrossAwaitAndReleasesAfterCancellation() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = ReviewCoordinator(service: service)
        let pause = OperationPause()
        let first = Task { try await coordinator.runExclusive { await pause.hold(); return 42 } }
        await pause.waitUntilEntered()
        await expectTrue(coordinator.busy)
        await expectThrowsError(try await coordinator.remove(session))
        first.cancel()
        await pause.resume()
        await expectEqual(try await first.value, 42)
        await expectFalse(coordinator.busy)
        await expectEqual(try await coordinator.runExclusive { 7 }, 7)
    }

    func testCoordinatorProtectsCorruptLoadedStateFromAllMutations() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: service.storage, withIntermediateDirectories: true)
        let file = service.storage.appendingPathComponent("state.json")
        let corrupt = Data("broken state".utf8)
        try corrupt.write(to: file)
        let coordinator = ReviewCoordinator(service: service)
        await expectNotNil(coordinator.loadError)
        await expectThrowsError(try await coordinator.remove(session))
        await expectThrowsError(try coordinator.retrySave())
        await expectEqual(try Data(contentsOf: file), corrupt)
        await expectTrue(FileManager.default.fileExists(atPath: session.path))
    }

    func testStructuredInspectionIncludesChangedCopiesAndUntrackedPaths() async throws {
        let (directory, service, session) = try await copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeConfig("ignored/GoogleService-Info.plist", root: session.path, content: "edited")
        _ = try writeConfig("new.xcconfig", root: session.path)
        let report = try await service.inspect(session)
        await expectTrue(report.blockers.contains(.changedCopy("ignored/GoogleService-Info.plist")))
        await expectTrue(report.blockers.contains { if case .workingChanges(let records) = $0 { return records.contains { $0.contains("new.xcconfig") } }; return false })
    }
    func testCoordinatorUsesStoredCopyFingerprintsInsteadOfCallerSnapshot() async throws {
        let (directory, service, session) = try await copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "ignored/GoogleService-Info.plist"
        let file = try writeConfig(path, root: session.path, content: "user changes")
        var snapshot = session
        snapshot.copiedFiles = [CopiedFile(path: path, sha256: ReviewService.digest(try Data(contentsOf: file)))]
        let coordinator = ReviewCoordinator(service: service)
        let report = try await coordinator.inspect(snapshot)
        await expectTrue(report.blockers.contains(.changedCopy(path)))
        await expectThrowsError(try await coordinator.remove(snapshot))
        await expectEqual(try String(contentsOf: file, encoding: .utf8), "user changes")
        await expectEqual(coordinator.state.sessions.first, session)
    }

    func testUpdatePreservesBuildSettingsSavedAfterSessionWasSelected() async throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try remoteService(directory: directory, service: original, session: session, sha: session.sha)
        let coordinator = ReviewCoordinator(service: service)
        let settings = BuildSettings(scheme: "App", destination: BuildDestination(id: "Mac", name: "My Mac", platform: "macOS"))
        try coordinator.saveBuildSettings(settings, for: session)
        let updated = try await coordinator.update(session)
        await expectEqual(updated.repository.buildSettings, settings)
        await expectEqual(try service.stateStore.load().sessions.first?.repository.buildSettings, settings)
    }

    func testCoordinatorPersistsCancelledBuildAfterExecutionStops() async throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try writeConfig("App.xcodeproj/project.pbxproj", root: session.path)
        var initial = SavedState(); initial.sessions = [session]
        try service.stateStore.save(initial)
        let pause = OperationPause()
        let buildService = XcodeBuildService(storage: service.storage, command: { name, arguments, output in
            if name == "git" {
                return CommandResult(standardOutput: try TestCommands.run(name, arguments), standardError: "", exitCode: 0, terminationDescription: "exited(0)")
            }
            await output?("building\n")
            await pause.hold()
            try Task.checkCancellation()
            return CommandResult(standardOutput: "", standardError: "", exitCode: 0, terminationDescription: "exited(0)")
        }, inspect: { _ in InspectionReport(blockers: []) })
        let coordinator = ReviewCoordinator(service: service, buildService: buildService)
        let settings = BuildSettings(scheme: "App", destination: BuildDestination(id: "host", name: "My Mac", platform: "macOS"))
        let task = Task { try await coordinator.runBuild(session, settings: settings, action: .build) }
        await pause.waitUntilEntered()
        await expectTrue(coordinator.busy)
        await expectThrowsError(try await coordinator.update(session))
        task.cancel()
        await pause.resume()
        let record = try await task.value
        await expectEqual(record.status, .cancelled)
        await expectEqual(try service.stateStore.load().sessions.first?.buildRecords?.last, record)
        await expectTrue(FileManager.default.fileExists(atPath: record.logPath))
        await expectFalse(coordinator.busy)
    }
}

// Keep setup commands synchronous and isolated to tests. Production commands use
// structured async execution; tiny local fixture commands cannot fill pipe buffers.
private enum TestCommands {
    static func run(_ name: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/" + name)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = FileManager.default.createFile(atPath: output.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        try process.run(); process.waitUntilExit()
        let string = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ReviewError(string) }
        return arguments.contains("-z") ? string : string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func git(_ path: String, _ arguments: [String]) throws -> String {
        try run("git", ["-c", "core.hooksPath=/dev/null", "-C", path] + arguments)
    }
}

@MainActor private func expectEqual<T: Equatable>(_ lhs: @autoclosure @MainActor () async throws -> T, _ rhs: @autoclosure @MainActor () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { let actual = try await lhs(); let expected = try await rhs(); XCTAssertEqual(actual, expected, file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
@MainActor private func expectTrue(_ expression: @autoclosure @MainActor () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertTrue(value, file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
@MainActor private func expectFalse(_ expression: @autoclosure @MainActor () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertFalse(value, file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
@MainActor private func expectNil<T>(_ expression: @autoclosure @MainActor () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertNil(value, file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
@MainActor private func expectNotNil<T>(_ expression: @autoclosure @MainActor () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async {
    do { let value = try await expression(); XCTAssertNotNil(value, file: file, line: line) }
    catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
}
@MainActor private func expectThrowsError<T>(_ expression: @autoclosure @MainActor () async throws -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected error. " + message, file: file, line: line) }
    catch { }
}

private final class RetryableSave: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = true
    private let store: StateStore
    init(store: StateStore) { self.store = store }
    func allowSaving() { lock.withLock { fails = false } }
    func save(_ state: SavedState) throws {
        let shouldFail = lock.withLock { fails }
        if shouldFail { throw ReviewError("disk unavailable") }
        try store.save(state)
    }
}

private actor OperationPause {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        waiter?.resume(); waiter = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { waiter = $0 } }
    }
    func resume() { release?.resume(); release = nil }
}
