import Foundation

struct ReviewPaths: Sendable {
    let storage: URL

    var worktrees: URL {
        storage.standardizedFileURL.appendingPathComponent("Worktrees", isDirectory: true)
    }

    func worktree(for session: Session) throws -> URL {
        let expected = worktrees.appendingPathComponent(session.id.uuidString).standardizedFileURL
        let actual = URL(fileURLWithPath: session.path).standardizedFileURL
        guard actual == expected, actual.resolvingSymlinksInPath() == actual else {
            throw ReviewError("管理対象外のレビュー環境です。パスを確認してください。")
        }
        return actual
    }
}
