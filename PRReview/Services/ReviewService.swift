import Foundation
import CryptoKit
import Darwin

public struct ReviewError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PullRequest: Equatable {
    public let owner: String
    public let repository: String
    public let number: Int
    public var slug: String { "\(owner)/\(repository)" }
    public var url: String { "https://github.com/\(slug)/pull/\(number)" }
    public init(_ input: String) throws {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host?.lowercased() == "github.com",
              url.user == nil, url.password == nil else {
            throw ReviewError("GitHubのPR URLを入力してください。https://github.com/owner/repo/pull/123")
        }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[2] == "pull", let n = Int(parts[3]), n > 0,
              parts[0].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil,
              parts[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw ReviewError("PR URLの形式を確認してください。")
        }
        owner = parts[0]; repository = parts[1]; number = n
    }
}

public struct Repository: Codable, Identifiable, Equatable {
    public var id: UUID
    public var path: String
    public var slug: String
    public var entry: String
    public var copyPaths: [String]?
    public init(path: String, slug: String, entry: String, copyPaths: [String] = []) {
        id = UUID(); self.path = path; self.slug = slug; self.entry = entry; self.copyPaths = copyPaths
    }
}

public struct CopiedFile: Codable, Equatable {
    public var path: String
    public var sha256: String
}

public struct Session: Codable, Identifiable, Equatable {
    public var id: UUID
    public var repository: Repository
    public var prURL: String
    public var number: Int
    public var title: String
    public var sha: String
    public var path: String
    public var createdAt: Date
    public var updatedAt: Date?
    public var copiedFiles: [CopiedFile]?
    public init(id: UUID, repository: Repository, prURL: String, number: Int, title: String, sha: String, path: String) {
        self.id = id; self.repository = repository; self.prURL = prURL; self.number = number
        self.title = title; self.sha = sha; self.path = path; self.createdAt = Date()
    }
}

public struct SavedState: Codable {
    public var repositories: [Repository] = []
    public var sessions: [Session] = []
    public init() {}
}

public enum Commands {
    // GUI-launched apps do not inherit an interactive shell's PATH.
    public static func executable(_ name: String) throws -> String {
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw ReviewError("\(name)が見つかりません。\(name == "gh" ? "Homebrewでghをインストールし、ターミナルでgh auth loginを実行してください。" : "Xcode Command Line Toolsをインストールしてください。")")
    }

    public static func run(_ name: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try executable(name))
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GH_PROMPT_DISABLED"] = "1"
        process.environment = environment
        // File-backed output avoids pipe-buffer deadlocks on large fetch output.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer { try? FileManager.default.removeItem(at: output) }
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        process.standardOutput = handle; process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let string = String(decoding: try Data(contentsOf: output), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw ReviewError("\(name)が失敗しました（\(process.terminationStatus)）\n\(string.suffix(6000))")
        }
        return arguments.contains("-z") ? string : string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func git(_ path: String, _ arguments: [String]) throws -> String {
        try run("git", ["-c", "core.hooksPath=/dev/null", "-C", path] + arguments)
    }
}

public struct ReviewService {
    public let storage: URL
    private let command: (String, [String]) throws -> String
    public var worktrees: URL { storage.appendingPathComponent("Worktrees", isDirectory: true) }
    public init(storage: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PRReview"), command: @escaping (String, [String]) throws -> String = Commands.run) {
        self.storage = storage
        self.command = command
    }
    private func git(_ path: String, _ arguments: [String]) throws -> String {
        // check-ignore consumes literal filenames and rejects pathspec magic.
        let literal = arguments.first == "check-ignore" ? [] : ["--literal-pathspecs"]
        return try command("git", ["-c", "core.hooksPath=/dev/null"] + literal + ["-C", path] + arguments)
    }
    public func load() throws -> SavedState {
        let file = storage.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return SavedState() }
        return try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
    }
    public func save(_ state: SavedState) throws {
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
    public func register(path: String, entryPath: String) throws -> Repository {
        let root = try git(path, ["rev-parse", "--show-toplevel"])
        let remote = try git(root, ["remote", "get-url", "origin"])
        let slug = try Self.githubSlug(remote)
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let entryURL = URL(fileURLWithPath: entryPath).resolvingSymlinksInPath()
        guard entryURL.path.hasPrefix(rootURL.path + "/"),
              ["xcodeproj", "xcworkspace"].contains(entryURL.pathExtension) else {
            throw ReviewError("リポジトリ内の.xcworkspaceまたは.xcodeprojを選んでください。")
        }
        return Repository(path: rootURL.path, slug: slug, entry: String(entryURL.path.dropFirst(rootURL.path.count + 1)))
    }
    public static func githubSlug(_ remote: String) throws -> String {
        var value = remote
        if value.hasPrefix("git@github.com:") { value = String(value.dropFirst("git@github.com:".count)) }
        else if let url = URL(string: remote), url.host?.lowercased() == "github.com", ["https", "ssh"].contains(url.scheme ?? "") {
            value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { throw ReviewError("originがgithub.comのリポジトリではありません。初版はGitHubのみ対応です。") }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let parts = value.split(separator: "/")
        guard parts.count == 2 else { throw ReviewError("originのURLを確認してください。") }
        return value
    }
    public func create(_ pr: PullRequest, repository: Repository) throws -> Session {
        let copies = try prepareCopies(repository)
        let id = UUID()
        let latest = try fetchLatest(pr, repository: repository)
        let path = worktrees.appendingPathComponent(id.uuidString).path
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        _ = try git(repository.path, ["worktree", "add", "--detach", path, latest.sha])
        var session = Session(id: id, repository: repository, prURL: pr.url, number: pr.number, title: latest.title, sha: latest.sha, path: path)
        do {
            // Validate every destination before writing any local configuration.
            for copy in copies {
                let destination = try checkedFile(root: path, relative: copy.path)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw ReviewError("PR内にコピー先が存在します：\(copy.path)")
                }
                try requireIgnoredUntracked(copy.path, root: path)
            }
            for copy in copies {
                let destination = try checkedFile(root: path, relative: copy.path)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                _ = try checkedFile(root: path, relative: copy.path)
                let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
                guard descriptor >= 0 else { throw ReviewError("コピー先に安全にファイルを作成できません：\(copy.path)") }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                do { try handle.write(contentsOf: copy.data); try handle.close() }
                catch { try? handle.close(); throw error }
            }
            session.copiedFiles = copies.map { CopiedFile(path: $0.path, sha256: Self.digest($0.data)) }
            return session
        } catch {
            // Only remove the new worktree if Git agrees it is clean. The source
            // configuration is never modified, even when creation fails.
            do { _ = try git(repository.path, ["worktree", "remove", path]) }
            catch { throw ReviewError("レビュー環境の準備に失敗しました。残った環境を確認してください：\(path)\n\(error.localizedDescription)") }
            throw error
        }
    }
    public func configureCopies(_ repository: Repository, paths: [String]) throws -> Repository {
        var configured = repository
        configured.copyPaths = Array(Set(paths)).sorted()
        _ = try prepareCopies(configured)
        return configured
    }
    public func relativeCopyPath(_ file: URL, repository: Repository) throws -> String {
        let root = URL(fileURLWithPath: repository.path).standardizedFileURL
        let candidate = file.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { throw ReviewError("リポジトリ内のファイルを選んでください。") }
        let relative = String(candidate.path.dropFirst(root.path.count + 1))
        _ = try checkedFile(root: root.path, relative: relative)
        return relative
    }
    private func prepareCopies(_ repository: Repository) throws -> [(path: String, data: Data)] {
        try (repository.copyPaths ?? []).map { path in
            let file = try checkedFile(root: repository.path, relative: path)
            try requireIgnoredUntracked(path, root: repository.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ReviewError("通常のファイルだけをコピーできます：\(path)") }
            return (path, try Data(contentsOf: file))
        }
    }
    private func requireIgnoredUntracked(_ path: String, root: String) throws {
        guard try git(root, ["ls-files", "-z", "--", path]).isEmpty else { throw ReviewError("Git管理済みファイルはコピー対象にできません：\(path)") }
        do { _ = try git(root, ["check-ignore", "--quiet", "--", path]) }
        catch { throw ReviewError("コピー対象はGitのignore設定に含めてください：\(path)") }
    }
    private func checkedFile(root: String, relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw ReviewError("コピー対象の相対パスが不正です：\(relative)")
        }
        var url = URL(fileURLWithPath: root).standardizedFileURL
        guard url.resolvingSymlinksInPath() == url else { throw ReviewError("コピー元・先のルートがシンボリックリンクです。") }
        for component in parts {
            url.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw ReviewError("シンボリックリンクはコピー対象にできません：\(relative)")
            }
        }
        return url
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private func inspectCopies(_ session: Session) throws -> (unchanged: Set<String>, notes: [String]) {
        var unchanged = Set<String>(), notes: [String] = []
        for copy in session.copiedFiles ?? [] {
            let file = try checkedFile(root: session.path, relative: copy.path)
            // Missing copies contain no user data to discard. Do not recreate them.
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if attributes[.type] as? FileAttributeType == .typeRegular,
               Self.digest(try Data(contentsOf: file)) == copy.sha256 {
                unchanged.insert(copy.path)
            } else {
                notes.append("コピーしたファイルが変更されています：\(copy.path)\n必要な内容を元のリポジトリ等へ保存してください。")
            }
        }
        return (unchanged, notes)
    }
    private func checkCopyCollisions(_ session: Session, sha: String) throws {
        for copy in session.copiedFiles ?? [] {
            let parts = copy.path.split(separator: "/")
            let paths = (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
            let entries = try git(session.path, ["ls-tree", "-z", sha, "--"] + paths).split(separator: "\0")
            if entries.contains(where: { !$0.hasPrefix("040000 tree ") }) {
                throw ReviewError("最新のPRとコピー先が衝突します。更新せず環境を残しました：\(copy.path)")
            }
        }
    }
    private func fetchLatest(_ pr: PullRequest, repository: Repository) throws -> (title: String, sha: String) {
        let slug = try Self.githubSlug(git(repository.path, ["remote", "get-url", "origin"]))
        guard slug.lowercased() == pr.slug.lowercased() else { throw ReviewError("PRと登録リポジトリが一致しません。") }
        let json = try command("gh", ["pr", "view", pr.url, "--json", "title,headRefOid"])
        struct Metadata: Decodable { let title: String; let headRefOid: String }
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(json.utf8))
        let reference = "refs/prreview/\(UUID().uuidString)"
        defer { _ = try? git(repository.path, ["update-ref", "-d", reference]) }
        _ = try git(repository.path, ["fetch", "--no-tags", "origin", "refs/pull/\(pr.number)/head:\(reference)"])
        let sha = try git(repository.path, ["rev-parse", reference])
        guard sha == metadata.headRefOid else { throw ReviewError("取得中にPRが更新されました。もう一度取得してください。") }
        return (metadata.title, sha)
    }
    public func update(_ session: Session) throws -> Session {
        try checkUpdate(session)
        let latest = try fetchLatest(PullRequest(session.prURL), repository: session.repository)
        // Recheck after network access so changes made while fetching are preserved.
        try checkUpdate(session)
        var state = try load()
        guard let index = state.sessions.firstIndex(where: { $0.id == session.id }),
              state.sessions[index].sha == session.sha, state.sessions[index].path == session.path else {
            throw ReviewError("保存されたレビュー環境が変更されています。アプリを再起動してください。")
        }
        var updated = session
        updated.sha = latest.sha; updated.title = latest.title
        let changed = latest.sha != session.sha
        if changed {
            try checkCopyCollisions(session, sha: latest.sha)
            // Never force checkout; ignored files that collide with new tracked files
            // must also be protected. No branch is created or moved.
            _ = try git(session.path, ["checkout", "--detach", "--no-overwrite-ignore", latest.sha])
            updated.updatedAt = Date()
        }
        state.sessions[index] = updated
        do { try save(state) }
        catch {
            if changed {
                do { _ = try git(session.path, ["checkout", "--detach", "--no-overwrite-ignore", session.sha]) }
                catch { throw ReviewError("状態の保存と元のコミットへの復帰に失敗しました。現在のHEADを確認してください。\n\(error.localizedDescription)") }
            }
            throw error
        }
        return updated
    }
    private func checkUpdate(_ session: Session) throws {
        let reason = try inspect(session)
        guard reason.isEmpty else { throw ReviewError("更新せず環境を残しました。\n\n\(reason)") }
        let head = try git(session.path, ["rev-parse", "HEAD"])
        guard head == session.sha else { throw ReviewError("手動で別のコミットへ切り替えられています。更新せず環境を残しました。") }
    }
    public func entry(for session: Session) throws -> URL {
        let root = URL(fileURLWithPath: session.path).resolvingSymlinksInPath()
        let entry = root.appendingPathComponent(session.repository.entry).resolvingSymlinksInPath()
        guard entry.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: entry.path) else {
            throw ReviewError("このPRには登録したXcodeプロジェクトがありません。Finderで確認してください。")
        }
        return entry
    }
    public func inspect(_ session: Session) throws -> String {
        try validate(session)
        let copies = try inspectCopies(session)
        let records = try git(session.path, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]).split(separator: "\0")
        var status: [String] = [], index = 0
        while index < records.count {
            let record = String(records[index])
            let code = String(record.prefix(2)), path = String(record.dropFirst(3))
            if code != "??" || !copies.unchanged.contains(path) { status.append(record) }
            if code.contains("R") || code.contains("C") { index += 1 }
            index += 1
        }
        let commits = try git(session.path, ["rev-list", "--count", "\(session.sha)..HEAD"])
        let ignoredPaths = try git(session.path, ["ls-files", "-z", "--others", "--ignored", "--exclude-standard"])
            .split(separator: "\0").map(String.init)
        let ignored = ignoredPaths.filter { !Self.isDisposableXcodeState($0) && !copies.unchanged.contains($0) }.joined(separator: "\n")
        var notes = copies.notes
        if !status.isEmpty { notes.append("未コミット／未追跡の変更があります：\n\(status.joined(separator: "\n").prefix(3000))") }
        if commits != "0" { notes.append("レビュー中のコミットから追加されたローカルコミットが\(commits)件あります。") }
        if !ignored.isEmpty { notes.append("Git管理外（ignored）のファイルがあります：\n\(ignored.prefix(2000))\n必要なファイルを保存するか、不要な生成物を手動で削除してください。") }
        return notes.joined(separator: "\n\n")
    }
    // Only these two ignored UI-state files are disposable. Breakpoints, custom
    // schemes, configs and tracked edits still require the user to preserve them.
    static func isDisposableXcodeState(_ path: String) -> Bool {
        path.range(
            of: #"(?:^|/)[^/]+\.(?:xcodeproj|xcworkspace)/xcuserdata/[^/]+\.xcuserdatad/(?:UserInterfaceState\.xcuserstate|xcschemes/xcschememanagement\.plist)$"#,
            options: .regularExpression
        ) != nil
    }
    private func validate(_ session: Session) throws {
        let expected = worktrees.appendingPathComponent(session.id.uuidString).standardizedFileURL
        let actual = URL(fileURLWithPath: session.path).standardizedFileURL
        guard expected == actual, actual.resolvingSymlinksInPath() == actual else { throw ReviewError("管理対象外のパスのため削除を中止しました。") }
        let root = try git(session.path, ["rev-parse", "--show-toplevel"])
        guard URL(fileURLWithPath: root).standardizedFileURL == actual else { throw ReviewError("worktreeの場所が一致しません。") }
        let original = try git(session.repository.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let linked = try git(session.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard original == linked else { throw ReviewError("worktreeのリポジトリが一致しません。") }
        _ = try git(session.path, ["cat-file", "-e", "\(session.sha)^{commit}"])
    }
    public func remove(_ session: Session) throws {
        let reason = try inspect(session)
        guard reason.isEmpty else { throw ReviewError(reason) }
        // Copies whose ignore rule was removed by a newer PR are untracked, so
        // delete only verified copies explicitly before Git's non-force removal.
        for copy in session.copiedFiles ?? [] {
            let file = try checkedFile(root: session.path, relative: copy.path)
            if FileManager.default.fileExists(atPath: file.path) {
                guard Self.digest(try Data(contentsOf: file)) == copy.sha256 else { throw ReviewError("コピーしたファイルが変更されています：\(copy.path)") }
                try FileManager.default.removeItem(at: file)
            }
        }
        _ = try git(session.repository.path, ["worktree", "remove", session.path])
    }
}
