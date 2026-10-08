import SwiftUI
import AppKit

@MainActor
final class ReviewModel: ObservableObject {
    @Published var state = SavedState()
    @Published var input = ""
    @Published var busy = false
    @Published var activity = "PRのURLを貼り付けて、Xcodeでレビューを始めましょう。"
    @Published var error: String?
    @Published var selected: UUID?
    @Published var removal: Session?
    @Published var editingRepository: Repository?
    let service = ReviewService()
    init() {
        do { state = try service.load() } catch { self.error = "保存状態を読み込めませんでした。\n\(error.localizedDescription)" }
    }
    var session: Session? { state.sessions.first { $0.id == selected } }
    func perform<T>(_ label: String, operation: @escaping () throws -> T, failure: ((Error) -> Void)? = nil, completion: @escaping (T) throws -> Void) {
        guard !busy else { return }
        busy = true; activity = label
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) { try operation() }.value
                try completion(result)
            } catch {
                if let failure { failure(error) } else { self.error = error.localizedDescription }
                activity = "操作を完了できませんでした。"
            }
            busy = false
        }
    }
    func addRepository() {
        let folder = NSOpenPanel()
        folder.message = "普段使っているローカルのGitリポジトリを選択"
        folder.canChooseDirectories = true; folder.canChooseFiles = false; folder.allowsMultipleSelection = false
        guard folder.runModal() == .OK, let root = folder.url else { return }
        let project = NSOpenPanel()
        project.message = "このリポジトリで開く.xcworkspaceまたは.xcodeprojを選択"
        project.directoryURL = root; project.canChooseFiles = true; project.canChooseDirectories = true
        project.treatsFilePackagesAsDirectories = false; project.allowsMultipleSelection = false
        guard project.runModal() == .OK, let entry = project.url else { return }
        perform("リポジトリを確認中…", operation: { try self.service.register(path: root.path, entryPath: entry.path) }) { repo in
            var next = self.state
            next.repositories.removeAll { $0.slug.lowercased() == repo.slug.lowercased() }
            next.repositories.append(repo)
            try self.service.save(next); self.state = next
            self.activity = "\(repo.slug)を登録しました。"
        }
    }
    func create() {
        do {
            let pr = try PullRequest(input)
            if let existing = state.sessions.first(where: { $0.prURL == pr.url }) {
                selected = existing.id; open(existing); return
            }
            guard let repo = state.repositories.first(where: { $0.slug.lowercased() == pr.slug.lowercased() }) else {
                throw ReviewError("\(pr.slug)のローカルリポジトリを「リポジトリ登録」から登録してください。")
            }
            perform("PRを取得してworktreeを作成中…", operation: { try self.service.create(pr, repository: repo) }) { session in
                // Retain the live session even if persistence fails; do not delete user files on a save error.
                self.state.sessions.insert(session, at: 0); self.selected = session.id
                try self.service.save(self.state)
                self.input = ""; self.activity = "レビュー環境を作成しました。"
                self.open(session)
            }
        } catch { self.error = error.localizedDescription }
    }
    func saveCopies(_ repository: Repository, paths: [String], onError: @escaping (String) -> Void) {
        perform("コピー設定を確認中…", operation: { try self.service.configureCopies(repository, paths: paths) }, failure: { onError($0.localizedDescription) }) { configured in
            var next = self.state
            guard let index = next.repositories.firstIndex(where: { $0.id == repository.id }) else {
                throw ReviewError("登録リポジトリが変更されています。設定を開き直してください。")
            }
            next.repositories[index] = configured
            try self.service.save(next); self.state = next
            self.editingRepository = nil
            self.activity = "コピー設定を保存しました。次のレビュー環境から適用します。"
        }
    }
    func open(_ session: Session) {
        do {
            let entry = try service.entry(for: session)
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
                throw ReviewError("Xcodeが見つかりません。")
            }
            NSWorkspace.shared.open([entry], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in self.error = error.localizedDescription } }
            }
        } catch { self.error = error.localizedDescription }
    }
    func checkRemoval(_ session: Session) {
        perform("変更とローカルコミットを確認中…", operation: { try self.service.inspect(session) }) { reason in
            if reason.isEmpty { self.removal = session; self.activity = "削除前の確認が完了しました。" }
            else { self.error = "環境を残しました。\n\n\(reason)"; self.activity = "保存されていないファイルを確認してください。" }
        }
    }
    func update(_ session: Session) {
        perform("PRの最新コミットを取得中…", operation: { try self.service.update(session) }) { updated in
            if let index = self.state.sessions.firstIndex(where: { $0.id == updated.id }) {
                self.state.sessions[index] = updated
            }
            self.activity = updated.sha == session.sha
                ? "すでに最新のコミットです。"
                : "最新コミット（\(updated.sha.prefix(10))）に更新しました。"
        }
    }
    func remove(_ session: Session) {
        perform("レビュー環境を削除中…", operation: { try self.service.remove(session) }) { _ in
            self.state.sessions.removeAll { $0.id == session.id }; self.selected = nil
            try self.service.save(self.state)
            self.activity = "レビュー環境を削除しました。"
        }
    }
}
