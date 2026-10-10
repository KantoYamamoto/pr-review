import Foundation

extension ReviewService {
    @concurrent
    public func create(_ pr: PullRequest, repository: Repository) async throws -> Session {
        let copies = try await prepareCopies(repository)
        let id = UUID()
        let latest = try await fetchLatest(pr, repository: repository)
        let path = worktrees.appendingPathComponent(id.uuidString).path
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        _ = try await git(repository.path, ["worktree", "add", "--detach", path, latest.sha])
        var session = Session(id: id, repository: repository, prURL: pr.url, number: pr.number, title: latest.title, sha: latest.sha, path: path)
        do {
            session.copiedFiles = try await installCopies(copies, at: path)
            return session
        } catch {
            // Only remove the new worktree if Git agrees it is clean. The source
            // configuration is never modified, even when creation fails.
            do { _ = try await git(repository.path, ["worktree", "remove", path]) }
            catch { throw ReviewError("レビュー環境の準備に失敗しました。残った環境を確認してください：\(path)\n\(error.localizedDescription)") }
            throw error
        }
    }
    @concurrent
    func fetchLatest(_ pr: PullRequest, repository: Repository) async throws -> (title: String, sha: String) {
        let slug = try Self.githubSlug(await git(repository.path, ["remote", "get-url", "origin"]))
        guard slug.lowercased() == pr.slug.lowercased() else { throw ReviewError("PRと登録リポジトリが一致しません。") }
        let metadata = try await GitHubClient(command: command).metadata(for: pr)
        let reference = "refs/prreview/\(UUID().uuidString)"
        do {
            _ = try await git(repository.path, ["fetch", "--no-tags", "origin", "refs/pull/\(pr.number)/head:\(reference)"])
            let sha = try await git(repository.path, ["rev-parse", reference])
            guard sha == metadata.headRefOid else { throw ReviewError("取得中にPRが更新されました。もう一度取得してください。") }
            _ = try await git(repository.path, ["update-ref", "-d", reference])
            return (metadata.title, sha)
        } catch {
            // Cleanup runs in a fresh task even when a cancellable fetch was stopped.
            let service = self
            _ = try? await Task { try await service.git(repository.path, ["update-ref", "-d", reference]) }.value
            throw error
        }
    }
    @concurrent
    public func update(_ session: Session) async throws -> Session {
        try await checkUpdate(session)
        let latest = try await fetchLatest(PullRequest(session.prURL), repository: session.repository)
        // Recheck after network access so changes made while fetching are preserved.
        try await checkUpdate(session)
        var updated = session
        updated.sha = latest.sha; updated.title = latest.title
        let changed = latest.sha != session.sha
        if changed {
            try await checkCopyCollisions(session, sha: latest.sha)
            // Never force checkout; ignored files that collide with new tracked files
            // must also be protected. No branch is created or moved.
            _ = try await git(session.path, ["checkout", "--detach", "--no-overwrite-ignore", latest.sha])
            updated.updatedAt = Date()
        }
        return updated
    }
    /// Restores a checkout after a failed state save, protecting edits made during saving.
    @concurrent
    func rollback(_ session: Session, to sha: String) async throws {
        try await checkUpdate(session)
        _ = try await git(session.path, ["checkout", "--detach", "--no-overwrite-ignore", sha])
    }
    @concurrent
    func checkUpdate(_ session: Session) async throws {
        let reason = try await inspect(session)
        guard reason.isEmpty else { throw ReviewError("更新せず環境を残しました。\n\n\(reason.description)") }
        let head = try await git(session.path, ["rev-parse", "HEAD"])
        guard head == session.sha else { throw ReviewError("手動で別のコミットへ切り替えられています。更新せず環境を残しました。") }
    }
    public func entry(for session: Session) throws -> URL {
        let root = try ReviewPaths(storage: storage).worktree(for: session)
        return try XcodeProject(root: root.path, relativePath: session.repository.entry).url
    }
    @concurrent
    public func inspect(_ session: Session) async throws -> InspectionReport {
        try await validate(session)
        let copies = try inspectCopies(session)
        let records = try await git(session.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).split(separator: "\0")
        var status: [String] = [], index = 0
        while index < records.count {
            let record = String(records[index])
            let code = String(record.prefix(2)), path = String(record.dropFirst(3))
            if code != "??" || !copies.unchanged.contains(path) { status.append(record) }
            if code.contains("R") || code.contains("C") { index += 1 }
            index += 1
        }
        let commits = try await git(session.path, ["rev-list", "--count", "\(session.sha)..HEAD"])
        let ignoredPaths = try await git(session.path, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard"])
            .split(separator: "\0").map(String.init)
        let ignored = ignoredPaths.filter { !Self.isDisposableXcodeState($0) && !copies.unchanged.contains($0) }
        var notes = copies.notes.map(ReviewBlocker.changedCopy)
        if !status.isEmpty { notes.append(.workingChanges(status)) }
        guard let count = Int(commits) else { throw ReviewError("ローカルコミットの件数を確認できませんでした。") }
        if count != 0 { notes.append(.localCommits(count)) }
        if !ignored.isEmpty { notes.append(.ignoredFiles(ignored)) }
        return InspectionReport(blockers: notes)
    }
    // Only these two ignored UI-state files are disposable. Breakpoints, custom
    // schemes, configs and tracked edits still require the user to preserve them.
    static func isDisposableXcodeState(_ path: String) -> Bool {
        path.range(
            of: #"(?:^|/)[^/]+\.(?:xcodeproj|xcworkspace)/xcuserdata/[^/]+\.xcuserdatad/(?:UserInterfaceState\.xcuserstate|xcschemes/xcschememanagement\.plist)$"#,
            options: .regularExpression
        ) != nil
    }
    @concurrent
    func validate(_ session: Session) async throws {
        let actual = try ReviewPaths(storage: storage).worktree(for: session)
        let root = try await git(session.path, ["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: root).standardizedFileURL == actual else { throw ReviewError("worktreeの場所が一致しません。") }
        let original = try await git(session.repository.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let linked = try await git(session.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard original == linked else { throw ReviewError("worktreeのリポジトリが一致しません。") }
        _ = try await git(session.path, ["cat-file", "-e", "\(session.sha)^{commit}"])
    }
    @concurrent
    public func remove(_ session: Session) async throws {
        let reason = try await inspect(session)
        guard reason.isEmpty else { throw ReviewError(reason.description) }
        // Git can remove ignored copies itself. Copies whose ignore rule changed
        // are temporarily moved aside so non-force removal still checks all other
        // user files. Restore them if Git refuses (e.g. a locked worktree).
        let backup = storage.appendingPathComponent("CopyRemovalBackups/\(UUID().uuidString)")
        var moved: [(original: URL, backup: URL)] = []
        do {
            for copy in session.copiedFiles ?? [] {
                let file = try RepositoryFileSafety.file(root: session.path, relative: copy.path)
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                guard Self.digest(try Data(contentsOf: file)) == copy.sha256 else { throw ReviewError("コピーしたファイルが変更されています：\(copy.path)") }
                if (try? await git(session.path, ["check-ignore", "--quiet", "--", copy.path])) != nil { continue }
                try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let saved = try RepositoryFileSafety.file(root: backup.path, relative: copy.path)
                try FileManager.default.createDirectory(at: saved.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.moveItem(at: file, to: saved)
                moved.append((file, saved))
                guard Self.digest(try Data(contentsOf: saved)) == copy.sha256 else { throw ReviewError("コピーしたファイルが変更されています：\(copy.path)") }
            }
            _ = try await git(session.repository.path, ["worktree", "remove", session.path])
        } catch {
            let originalError = error
            var restorationFailed = false
            for pair in moved.reversed() {
                do {
                    guard FileManager.default.fileExists(atPath: session.path + "/.git") else { throw ReviewError("worktreeがありません。") }
                    let relative = String(pair.original.path.dropFirst(session.path.count + 1))
                    _ = try RepositoryFileSafety.file(root: session.path, relative: relative)
                    try FileManager.default.moveItem(at: pair.backup, to: pair.original)
                } catch { restorationFailed = true }
            }
            if restorationFailed {
                throw ReviewError("環境の削除に失敗しました。復元できなかったコピー設定は次の場所に保管しました：\(backup.path)\n\(originalError.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: backup)
            throw originalError
        }
        try? FileManager.default.removeItem(at: backup)
    }
}
