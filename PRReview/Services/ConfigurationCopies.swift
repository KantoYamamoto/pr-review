import Foundation
import CryptoKit

extension ReviewService {
    @concurrent
    public func configureCopies(_ repository: Repository, paths: [String]) async throws -> Repository {
        var configured = repository
        configured.copyPaths = Array(Set(paths)).sorted()
        _ = try await prepareCopies(configured)
        return configured
    }
    public func relativeCopyPath(_ file: URL, repository: Repository) throws -> String {
        let root = URL(fileURLWithPath: repository.path).standardizedFileURL
        let candidate = file.standardizedFileURL
        guard candidate.path.hasPrefix(root.path + "/") else { throw ReviewError("リポジトリ内のファイルを選んでください。") }
        let relative = String(candidate.path.dropFirst(root.path.count + 1))
        _ = try RepositoryFileSafety.file(root: root.path, relative: relative)
        return relative
    }
    @concurrent
    func prepareCopies(_ repository: Repository) async throws -> [(path: String, data: Data)] {
        var copies: [(path: String, data: Data)] = []
        for path in repository.copyPaths ?? [] {
            let file = try RepositoryFileSafety.file(root: repository.path, relative: path)
            try await requireIgnoredUntracked(path, root: repository.path)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ReviewError("通常のファイルだけをコピーできます：\(path)") }
            copies.append((path, try Data(contentsOf: file)))
        }
        return copies
    }
    @concurrent
    func requireIgnoredUntracked(_ path: String, root: String) async throws {
        guard try await git(root, ["ls-files", "-z", "--", path]).isEmpty else { throw ReviewError("Git管理済みファイルはコピー対象にできません：\(path)") }
        do { _ = try await git(root, ["check-ignore", "--quiet", "--", path]) }
        catch { throw ReviewError("コピー対象はGitのignore設定に含めてください：\(path)") }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    func inspectCopies(_ session: Session) throws -> (unchanged: Set<String>, notes: [String]) {
        var unchanged = Set<String>(), notes: [String] = []
        for copy in session.copiedFiles ?? [] {
            let file = try RepositoryFileSafety.file(root: session.path, relative: copy.path)
            // Missing copies contain no user data to discard. Do not recreate them.
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            if attributes[.type] as? FileAttributeType == .typeRegular,
               Self.digest(try Data(contentsOf: file)) == copy.sha256 {
                unchanged.insert(copy.path)
            } else {
                notes.append(copy.path)
            }
        }
        return (unchanged, notes)
    }
    @concurrent
    func checkCopyCollisions(_ session: Session, sha: String) async throws {
        for copy in session.copiedFiles ?? [] {
            let parts = copy.path.split(separator: "/")
            let paths = (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
            let entries = try await git(session.path, ["ls-tree", "-z", sha, "--"] + paths).split(separator: "\0")
            if entries.contains(where: { !$0.hasPrefix("040000 tree ") }) {
                throw ReviewError("最新のPRとコピー先が衝突します。更新せず環境を残しました：\(copy.path)")
            }
        }
    }
}
