import XCTest
@testable import PRReview

final class PRReviewTests: XCTestCase {
    func testSavePreservesCorruptExistingState() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let service = ReviewService(storage: directory)
        let file = directory.appendingPathComponent("state.json")
        let original = Data("{incomplete saved state".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try service.load())
        XCTAssertThrowsError(try service.save(SavedState()))
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testPRParsing() throws {
        let pr = try PullRequest(" https://github.com/owner/repo/pull/42/files?diff=split ")
        XCTAssertEqual(pr.url, "https://github.com/owner/repo/pull/42")
        for invalid in ["https://evil.test/a/b/pull/1", "https://github.com/a/b/pull/0", "https://github.com/a/b/issues/1", "file:///tmp/repo", "https://user@github.com/a/b/pull/1"] {
            XCTAssertThrowsError(try PullRequest(invalid))
        }
        XCTAssertEqual(try ReviewService.githubSlug("git@github.com:owner/repo.git"), "owner/repo")
        XCTAssertThrowsError(try ReviewService.githubSlug("https://evil.test/owner/repo.git"))
    }

    func fixture() throws -> (URL, ReviewService, Session) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repo = directory.appendingPathComponent("repository")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        _ = try Commands.git(repo.path, ["init"])
        _ = try Commands.git(repo.path, ["config", "commit.gpgsign", "false"])
        _ = try Commands.git(repo.path, ["config", "user.name", "Test"])
        _ = try Commands.git(repo.path, ["config", "user.email", "test@example.invalid"])
        try Data("initial".utf8).write(to: repo.appendingPathComponent("tracked.txt"))
        try Data("ignored/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
        _ = try Commands.git(repo.path, ["add", "."])
        _ = try Commands.git(repo.path, ["commit", "-m", "initial"])
        let sha = try Commands.git(repo.path, ["rev-parse", "HEAD"])
        let service = ReviewService(storage: directory.appendingPathComponent("state"))
        try FileManager.default.createDirectory(at: service.worktrees, withIntermediateDirectories: true)
        let id = UUID()
        let path = service.worktrees.appendingPathComponent(id.uuidString).path
        _ = try Commands.git(repo.path, ["worktree", "add", "--detach", path, sha])
        let repository = Repository(path: repo.path, slug: "owner/repo", entry: "App.xcodeproj")
        let session = Session(id: id, repository: repository, prURL: "https://github.com/owner/repo/pull/1", number: 1, title: "Test", sha: sha, path: path)
        return (directory, service, session)
    }

    func testCleanRemovalLeavesMainWorkUntouched() throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let main = URL(fileURLWithPath: session.repository.path).appendingPathComponent("tracked.txt")
        try Data("unfinished main work".utf8).write(to: main)
        XCTAssertEqual(try service.inspect(session), "")
        var state = SavedState(); state.sessions = [session]
        try service.save(state)
        XCTAssertEqual(try service.load().sessions, [session])
        try service.remove(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(try String(contentsOf: main, encoding: .utf8), "unfinished main work")
        XCTAssertFalse(try Commands.git(session.repository.path, ["worktree", "list", "--porcelain"]).contains(session.path))
    }

    func testRefusesModifiedUntrackedIgnoredAndLocalCommits() throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: session.path)
        let tracked = worktree.appendingPathComponent("tracked.txt")
        try Data("changed".utf8).write(to: tracked)
        XCTAssertThrowsError(try service.remove(session))
        _ = try Commands.git(session.path, ["restore", "tracked.txt"])
        let untracked = worktree.appendingPathComponent("secret.xcconfig")
        try Data("local config".utf8).write(to: untracked)
        XCTAssertThrowsError(try service.remove(session))
        try FileManager.default.removeItem(at: untracked)
        let ignored = worktree.appendingPathComponent("ignored")
        try FileManager.default.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: ignored.appendingPathComponent("config"))
        XCTAssertThrowsError(try service.remove(session))
        try FileManager.default.removeItem(at: ignored)
        try Data("local commit".utf8).write(to: tracked)
        _ = try Commands.git(session.path, ["add", "."])
        _ = try Commands.git(session.path, ["commit", "-m", "review edits"])
        XCTAssertThrowsError(try service.remove(session))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
    }

    func testRefusesForgedPathAndEscapingProject() throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var forged = session; forged.path = session.repository.path
        XCTAssertThrowsError(try service.remove(forged))
        var escape = session; escape.repository.entry = "../../repository"
        XCTAssertThrowsError(try service.entry(for: escape))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.repository.path))
    }

    func testRemovesWorktreeWithIgnoredXcodeUIState() throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: session.path)
        _ = try Commands.git(session.path, ["config", "--add", "core.excludesFile", directory.appendingPathComponent("excludes").path])
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
        XCTAssertEqual(try service.inspect(session), "")
        try service.remove(session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.path))
    }

    func testXcodeStateExceptionDoesNotDiscardBreakpointsOrTrackedEdits() throws {
        let (directory, service, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: initial.path)
        let excludes = directory.appendingPathComponent("excludes")
        try Data("xcuserdata/\n".utf8).write(to: excludes)
        _ = try Commands.git(initial.path, ["config", "core.excludesFile", excludes.path])
        let base = "ExampleApp.xcodeproj/xcuserdata/developer.xcuserdatad/"
        for path in ["xcdebugger/Breakpoints_v2.xcbkptlist", "xcschemes/Custom.xcscheme", "secrets.xcconfig"] {
            let file = worktree.appendingPathComponent(base + path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file)
            XCTAssertThrowsError(try service.remove(initial))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            try FileManager.default.removeItem(at: file)
        }
        let state = worktree.appendingPathComponent(base + "UserInterfaceState.xcuserstate")
        try Data("tracked state".utf8).write(to: state)
        _ = try Commands.git(initial.path, ["add", "-f", state.path])
        _ = try Commands.git(initial.path, ["commit", "-m", "track state"])
        var session = initial
        session.sha = try Commands.git(initial.path, ["rev-parse", "HEAD"])
        try Data("edited tracked state".utf8).write(to: state)
        XCTAssertThrowsError(try service.remove(session))
    }

    // Only GitHub metadata / origin identity are simulated. Fetch and checkout
    // use a real bare repository with GitHub-style PR refs.
    func remoteService(directory: URL, service: ReviewService, session: Session, sha: String) throws -> ReviewService {
        let remote = directory.appendingPathComponent("remote.git")
        _ = try Commands.run("git", ["init", "--bare", remote.path])
        _ = try Commands.git(session.repository.path, ["remote", "add", "origin", remote.path])
        _ = try Commands.git(session.repository.path, ["push", "origin", "\(sha):refs/pull/1/head"])
        var state = SavedState(); state.sessions = [session]
        try service.save(state)
        return ReviewService(storage: service.storage, command: { name, args in
            if name == "gh" { return "{\"title\":\"Updated PR\",\"headRefOid\":\"\(sha)\"}" }
            if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
            return try Commands.run(name, args)
        })
    }

    func testUpdateFetchesLatestDetachedCommitAndPersistsBaseline() throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let mainFile = URL(fileURLWithPath: session.repository.path).appendingPathComponent("tracked.txt")
        try Data("new PR version".utf8).write(to: mainFile)
        _ = try Commands.git(session.repository.path, ["commit", "-am", "additional PR commit"])
        let sha = try Commands.git(session.repository.path, ["rev-parse", "HEAD"])
        let service = try remoteService(directory: directory, service: original, session: session, sha: sha)
        try Data("unfinished main work".utf8).write(to: mainFile)
        let worktree = URL(fileURLWithPath: session.path)
        let stateFile = worktree.appendingPathComponent("App.xcodeproj/xcuserdata/test.xcuserdatad/UserInterfaceState.xcuserstate")
        try FileManager.default.createDirectory(at: stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("UI state".utf8).write(to: stateFile)
        let excludes = directory.appendingPathComponent("excludes")
        try Data("xcuserdata/\n".utf8).write(to: excludes)
        _ = try Commands.git(session.path, ["config", "core.excludesFile", excludes.path])

        let updated = try service.update(session)
        XCTAssertEqual(updated.sha, sha)
        XCTAssertEqual(updated.id, session.id)
        XCTAssertEqual(updated.path, session.path)
        XCTAssertNotNil(updated.updatedAt)
        XCTAssertEqual(try service.load().sessions.first, updated)
        XCTAssertEqual(try Commands.git(session.path, ["rev-parse", "--abbrev-ref", "HEAD"]), "HEAD")
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("tracked.txt")), "new PR version")
        XCTAssertEqual(try String(contentsOf: mainFile), "unfinished main work")
        XCTAssertEqual(try String(contentsOf: stateFile), "UI state")
        // A second refresh is a no-op and retains its last update date.
        XCTAssertEqual(try service.update(updated), updated)
        XCTAssertEqual(try Commands.git(session.repository.path, ["for-each-ref", "refs/prreview"]), "")
        try service.remove(updated)
    }

    func testUpdateProtectsEditsUntrackedIgnoredAndLocalCommits() throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worktree = URL(fileURLWithPath: session.path)
        let tracked = worktree.appendingPathComponent("tracked.txt")
        try Data("edited".utf8).write(to: tracked)
        XCTAssertThrowsError(try service.update(session))
        XCTAssertEqual(try String(contentsOf: tracked), "edited")
        _ = try Commands.git(session.path, ["restore", "tracked.txt"])
        for path in ["local.xcconfig", "ignored/secrets"] {
            let file = worktree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: file)
            XCTAssertThrowsError(try service.update(session))
            XCTAssertEqual(try String(contentsOf: file), "keep")
            try FileManager.default.removeItem(at: file)
        }
        try Data("local commit".utf8).write(to: tracked)
        _ = try Commands.git(session.path, ["commit", "-am", "local review edits"])
        let head = try Commands.git(session.path, ["rev-parse", "HEAD"])
        XCTAssertThrowsError(try service.update(session))
        XCTAssertEqual(try Commands.git(session.path, ["rev-parse", "HEAD"]), head)
    }

    func testUpdateHandlesForcePushedPRWithoutMerging() throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try Commands.git(session.repository.path, ["checkout", "--orphan", "rewritten"])
        _ = try Commands.git(session.repository.path, ["commit", "-m", "rewritten PR"])
        let sha = try Commands.git(session.repository.path, ["rev-parse", "HEAD"])
        let service = try remoteService(directory: directory, service: original, session: session, sha: sha)
        let updated = try service.update(session)
        XCTAssertEqual(updated.sha, sha)
        XCTAssertEqual(try Commands.git(session.path, ["rev-parse", "HEAD"]), sha)
        XCTAssertEqual(try service.inspect(updated), "")
    }

    func testFetchRaceLeavesReviewAtOriginalCommit() throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let underlying = try remoteService(directory: directory, service: original, session: session, sha: session.sha)
        let service = ReviewService(storage: underlying.storage, command: { name, args in
            if name == "gh" { return "{\"title\":\"PR\",\"headRefOid\":\"0000000000000000000000000000000000000000\"}" }
            if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
            return try Commands.run(name, args)
        })
        XCTAssertThrowsError(try service.update(session))
        XCTAssertEqual(try Commands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
        XCTAssertEqual(try service.load().sessions.first, session)
        XCTAssertEqual(try Commands.git(session.repository.path, ["for-each-ref", "refs/prreview"]), "")
    }

    func testUpdateDoesNotOverwriteIgnoredStateNewlyTrackedByPR() throws {
        let (directory, original, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relative = "App.xcodeproj/xcuserdata/test.xcuserdatad/UserInterfaceState.xcuserstate"
        let mainFile = URL(fileURLWithPath: session.repository.path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: mainFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("PR version".utf8).write(to: mainFile)
        _ = try Commands.git(session.repository.path, ["add", "-f", relative])
        _ = try Commands.git(session.repository.path, ["commit", "-m", "new tracked state"])
        let sha = try Commands.git(session.repository.path, ["rev-parse", "HEAD"])
        let service = try remoteService(directory: directory, service: original, session: session, sha: sha)
        let local = URL(fileURLWithPath: session.path).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep local state".utf8).write(to: local)
        let excludes = directory.appendingPathComponent("excludes")
        try Data("xcuserdata/\n".utf8).write(to: excludes)
        _ = try Commands.git(session.path, ["config", "core.excludesFile", excludes.path])
        XCTAssertThrowsError(try service.update(session))
        XCTAssertEqual(try String(contentsOf: local), "keep local state")
        XCTAssertEqual(try Commands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
        XCTAssertEqual(try service.load().sessions.first, session)
    }

    func writeConfig(_ relative: String, root: String, content: String = "test configuration") throws -> URL {
        let file = URL(fileURLWithPath: root).appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: file)
        return file
    }

    func copyFixture() throws -> (URL, ReviewService, Session) {
        let (directory, original, initial) = try fixture()
        let path = "ignored/GoogleService-Info.plist"
        _ = try writeConfig(path, root: initial.repository.path)
        let repository = try original.configureCopies(initial.repository, paths: [path])
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        let session = try service.create(PullRequest(initial.prURL), repository: repository)
        var state = try service.load(); state.sessions = [session]; state.repositories = [repository]
        try service.save(state)
        return (directory, service, session)
    }

    func testLegacyStateDecodesWithoutCopySettings() throws {
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
        XCTAssertNil(decoded.repositories[0].copyPaths)
        XCTAssertNil(decoded.sessions[0].copiedFiles)
        XCTAssertEqual(try service.inspect(decoded.sessions[0]), "")
    }

    func testCopyConfigurationRejectsTrackedUnsafeDirectoryAndSymlinkPaths() throws {
        let (directory, service, session) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repo = session.repository
        _ = try writeConfig("ignored/valid.xcconfig", root: repo.path)
        let outside = try writeConfig("outside", root: directory.path)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/ignored/link", withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: repo.path + "/ignored/broken", withDestinationPath: directory.path + "/missing")
        for path in ["tracked.txt", "../outside", outside.path, ".git/config", "ignored/../valid.xcconfig", "ignored//valid.xcconfig", "ignored", "ignored/link", "ignored/broken"] {
            XCTAssertThrowsError(try service.configureCopies(repo, paths: [path]), path)
        }
        let configured = try service.configureCopies(repo, paths: ["ignored/valid.xcconfig", "ignored/valid.xcconfig"])
        XCTAssertEqual(configured.copyPaths, ["ignored/valid.xcconfig"])
        XCTAssertThrowsError(try service.relativeCopyPath(outside, repository: repo))
    }

    func testCreationCopiesIgnoredConfigsWithPrivatePermissionsAndSafeCleanup() throws {
        let (directory, service, session) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relative = "ignored/GoogleService-Info.plist"
        let copy = URL(fileURLWithPath: session.path).appendingPathComponent(relative)
        let source = URL(fileURLWithPath: session.repository.path).appendingPathComponent(relative)
        XCTAssertEqual(try String(contentsOf: copy), "test configuration")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(session.copiedFiles?.count, 1)
        XCTAssertEqual(session.copiedFiles?.first?.sha256.count, 64)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(session), as: UTF8.self).contains("test configuration"))
        XCTAssertEqual(try service.load().sessions.first, session)
        try Data("changed source".utf8).write(to: source)
        XCTAssertEqual(try service.inspect(session), "")
        try service.remove(session)
        XCTAssertEqual(try String(contentsOf: source), "changed source")
    }

    func testEditedCopiesBlockUpdateAndRemovalAfterReload() throws {
        let (directory, service, session) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist")
        try Data("edited locally".utf8).write(to: copy)
        let loaded = try XCTUnwrap(service.load().sessions.first)
        XCTAssertTrue(try service.inspect(loaded).contains("コピーしたファイルが変更されています"))
        XCTAssertThrowsError(try service.update(loaded))
        XCTAssertThrowsError(try service.remove(loaded))
        XCTAssertEqual(try String(contentsOf: copy), "edited locally")
        XCTAssertEqual(try Commands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
        try FileManager.default.removeItem(at: copy)
        XCTAssertEqual(try service.inspect(loaded), "")
        try service.remove(loaded)
    }

    func testCopySymlinkReplacementIsProtected() throws {
        let (directory, service, session) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist")
        let outside = try writeConfig("outside-config", root: directory.path, content: "keep outside")
        try FileManager.default.removeItem(at: copy)
        try FileManager.default.createSymbolicLink(atPath: copy.path, withDestinationPath: outside.path)
        XCTAssertThrowsError(try service.remove(session))
        XCTAssertThrowsError(try service.update(session))
        XCTAssertEqual(try String(contentsOf: outside), "keep outside")
    }

    func testUpdatePreservesCopiesWhenIgnoreRuleDisappears() throws {
        let (directory, service, session) = try copyFixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = session.repository.path
        try Data("".utf8).write(to: URL(fileURLWithPath: root).appendingPathComponent(".gitignore"))
        _ = try Commands.git(root, ["commit", "-am", "remove ignore rule"])
        let sha = try Commands.git(root, ["rev-parse", "HEAD"])
        _ = try Commands.git(root, ["push", "origin", "HEAD:refs/pull/1/head"])
        let updatedService = ReviewService(storage: service.storage, command: { name, args in
            if name == "gh" { return "{\"title\":\"Updated\",\"headRefOid\":\"\(sha)\"}" }
            if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
            return try Commands.run(name, args)
        })
        let updated = try updatedService.update(session)
        XCTAssertEqual(updated.copiedFiles, session.copiedFiles)
        XCTAssertEqual(updated.sha, sha)
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist")), "test configuration")
        XCTAssertEqual(try updatedService.inspect(updated), "")
        try updatedService.remove(updated)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root + "/ignored/GoogleService-Info.plist"))
    }

    func testUpdateStopsBeforePRTracksCopyOrReplacesItsParentWithSymlink() throws {
        for symlink in [false, true] {
            let (directory, service, session) = try copyFixture()
            defer { try? FileManager.default.removeItem(at: directory) }
            let root = session.repository.path
            if symlink {
                try FileManager.default.removeItem(atPath: root + "/ignored")
                try FileManager.default.createSymbolicLink(atPath: root + "/ignored", withDestinationPath: "other-directory")
                _ = try Commands.git(root, ["add", "-f", "ignored"])
            } else {
                _ = try Commands.git(root, ["add", "-f", "ignored/GoogleService-Info.plist"])
            }
            _ = try Commands.git(root, ["commit", "-m", "PR collision"])
            let sha = try Commands.git(root, ["rev-parse", "HEAD"])
            _ = try Commands.git(root, ["push", "origin", "HEAD:refs/pull/1/head"])
            let updatedService = ReviewService(storage: service.storage, command: { name, args in
                if name == "gh" { return "{\"title\":\"Collision\",\"headRefOid\":\"\(sha)\"}" }
                if Array(args.suffix(3)) == ["remote", "get-url", "origin"] { return "https://github.com/owner/repo.git" }
                return try Commands.run(name, args)
            })
            XCTAssertThrowsError(try updatedService.update(session))
            XCTAssertEqual(try Commands.git(session.path, ["rev-parse", "HEAD"]), session.sha)
            XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: session.path).appendingPathComponent("ignored/GoogleService-Info.plist")), "test configuration")
            XCTAssertEqual(try updatedService.load().sessions.first, session)
        }
    }

    func testCreationFailureDoesNotLeaveNewWorktreeWhenPRDoesNotIgnoreCopy() throws {
        let (directory, original, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        // The user's local ignore rule is not present in the PR snapshot.
        let source = try writeConfig("local.xcconfig", root: initial.repository.path)
        try Data("local.xcconfig\n".utf8).write(to: URL(fileURLWithPath: initial.repository.path).appendingPathComponent(".gitignore"))
        let configured = try original.configureCopies(initial.repository, paths: ["local.xcconfig"])
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        let before = try Commands.git(initial.repository.path, ["worktree", "list", "--porcelain"])
        XCTAssertThrowsError(try service.create(PullRequest(initial.prURL), repository: configured))
        XCTAssertEqual(try Commands.git(initial.repository.path, ["worktree", "list", "--porcelain"]), before)
        XCTAssertEqual(try String(contentsOf: source), "test configuration")
    }

    func testCopyPathsWithWhitespaceAndGitPathspecCharactersAreLiteral() throws {
        let (directory, original, initial) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let relative = "ignored/ :(glob)* config\nfile.xcconfig "
        _ = try writeConfig(relative, root: initial.repository.path)
        let configured = try original.configureCopies(initial.repository, paths: [relative])
        let service = try remoteService(directory: directory, service: original, session: initial, sha: initial.sha)
        let session = try service.create(PullRequest(initial.prURL), repository: configured)
        XCTAssertEqual(try service.inspect(session), "")
        try service.remove(session)
    }
}
