import Foundation
import Observation

struct ProjectSelection: Identifiable {
    let id = UUID()
    let root: String
    let entries: [String]
}

/// Presentation state only. ReviewCoordinator owns persisted data and mutation order.
@MainActor @Observable
final class ReviewModel {
    let coordinator: ReviewCoordinator
    var input = ""
    var activity = "PRのURLを貼り付けて、Xcodeでレビューを始めましょう。"
    var error: String?
    var selected: UUID?
    var removal: Session?
    var managingSimulators = false
    var editingRepository: Repository?
    var projectSelection: ProjectSelection?
    var projectSelectionError: String?
    var buildConfiguration: BuildConfigurationModel?
    var liveLog = ""
    var runningBuild: UUID?
    var shuttingDown = false
    private(set) var working = false
    @ObservationIgnored private var task: Task<Void, Never>?

    init(coordinator: ReviewCoordinator = ReviewCoordinator()) {
        self.coordinator = coordinator
        error = coordinator.loadError
    }
    var state: SavedState { coordinator.state }
    var busy: Bool { working || coordinator.busy || shuttingDown }
    var session: Session? { state.sessions.first { $0.id == selected } }

    private func launch(_ label: String, operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        activity = label
        working = true
        task = Task {
            defer { task = nil; working = false }
            do { try await operation() }
            catch is CancellationError { activity = "操作を中断しました。" }
            catch { self.error = error.localizedDescription; activity = "操作を完了できませんでした。" }
        }
    }
    func addRepository() {
        launch("リポジトリを選択してください。") {
            guard let root = await MacIntegration.chooseRepository() else { self.activity = "登録をキャンセルしました。"; return }
            self.activity = "Xcodeプロジェクトを検索中…"
            let found = try await self.coordinator.discover(path: root.path)
            if found.entries.count == 1 {
                try await self.register(root: found.root, entry: found.entries[0])
            } else if found.entries.isEmpty {
                guard let entry = await MacIntegration.chooseProject(root: found.root) else { return }
                try await self.register(root: found.root, entry: entry.path)
            } else {
                self.projectSelectionError = nil
                self.projectSelection = ProjectSelection(root: found.root, entries: found.entries)
                self.activity = "開くXcodeプロジェクトを選んでください。"
            }
        }
    }
    private func register(root: String, entry: String) async throws {
        let path = entry.hasPrefix("/") ? entry : URL(fileURLWithPath: root).appendingPathComponent(entry).path
        let repo = try await coordinator.register(path: root, entryPath: path)
        projectSelection = nil
        activity = "\(repo.slug)を登録しました。"
    }
    func registerRepository(root: String, entry: String) {
        launch("リポジトリを確認中…") {
            do { try await self.register(root: root, entry: entry) }
            catch { self.projectSelectionError = error.localizedDescription }
        }
    }
    func chooseProjectManually(root: String) {
        launch("開くプロジェクトを選択してください。") {
            guard let entry = await MacIntegration.chooseProject(root: root) else { return }
            do { try await self.register(root: root, entry: entry.path) }
            catch { self.projectSelectionError = error.localizedDescription }
        }
    }
    func create() {
        launch("PRを取得してworktreeを作成中…") {
            let pr = try PullRequest(self.input)
            if let existing = self.state.sessions.first(where: { $0.prURL == pr.url }) {
                self.selected = existing.id
                try await MacIntegration.openXcode(self.coordinator.projectURL(for: existing))
                return
            }
            guard let repo = self.state.repositories.first(where: { $0.slug.lowercased() == pr.slug.lowercased() }) else {
                throw ReviewError("\(pr.slug)のローカルリポジトリを「リポジトリ登録」から登録してください。")
            }
            let session = try await self.coordinator.create(pr, repository: repo)
            self.selected = session.id; self.input = ""
            self.activity = "レビュー環境を作成しました。"
            try await MacIntegration.openXcode(self.coordinator.projectURL(for: session))
        }
    }
    func saveCopies(_ repository: Repository, paths: [String], onError: @escaping (String) -> Void) {
        launch("コピー設定を確認中…") {
            do {
                _ = try await self.coordinator.configureCopies(repository, paths: paths)
                self.editingRepository = nil
                self.activity = "コピー設定を保存しました。次のレビュー環境から適用します。"
            } catch { onError(error.localizedDescription) }
        }
    }
    func open(_ session: Session) {
        launch("Xcodeで開いています…") {
            try await MacIntegration.openXcode(self.coordinator.projectURL(for: session))
            self.activity = "Xcodeで開きました。"
        }
    }
    func checkRemoval(_ session: Session) {
        launch("変更とローカルコミットを確認中…") {
            let report = try await self.coordinator.inspect(session)
            if report.isEmpty { self.removal = session; self.activity = "削除前の確認が完了しました。" }
            else { throw ReviewError("環境を残しました。\n\n\(report.description)") }
        }
    }
    func update(_ session: Session) {
        launch("PRの最新コミットを取得中…") {
            let updated = try await self.coordinator.update(session)
            self.liveLog = ""
            self.activity = updated.sha == session.sha ? "すでに最新のコミットです。" : "最新コミット（\(updated.sha.prefix(10))）に更新しました。"
        }
    }
    func remove(_ session: Session, keepSimulators: Bool = false) {
        launch("レビュー環境とビルドデータを削除中…") {
            try await self.coordinator.remove(session, keepSimulators: keepSimulators)
            self.selected = nil; self.liveLog = ""
            self.activity = "レビュー環境を削除しました。"
        }
    }
    func configureBuild(_ session: Session) {
        guard !busy else { return }
        let configuration = BuildConfigurationModel(session: session, coordinator: coordinator)
        buildConfiguration = configuration
        reloadBuildConfiguration(configuration)
    }
    func reloadBuildConfiguration(_ configuration: BuildConfigurationModel) {
        launch("Schemeと実行先を取得中…") {
            await configuration.load()
            self.activity = "Schemeと実行先を選択してください。"
        }
    }
    func loadDestinations(_ configuration: BuildConfigurationModel) {
        launch("実行先を取得中…") { await configuration.loadDestinations() }
    }
    func saveBuildSettings(_ configuration: BuildConfigurationModel) {
        guard !busy else { return }
        if configuration.save() {
            buildConfiguration = nil
            activity = "ビルド設定を保存しました。"
        }
    }
    func openArtifact(_ path: String, session: Session) {
        do { MacIntegration.openArtifact(try coordinator.artifactURL(path, for: session)) }
        catch { self.error = error.localizedDescription }
    }
    func runBuild(_ session: Session, action: BuildAction) {
        guard let settings = session.repository.buildSettings else { configureBuild(session); return }
        launch("\(action.label)を実行中…") {
            self.runningBuild = session.id; self.liveLog = ""
            defer { self.runningBuild = nil }
            let record = try await self.coordinator.runBuild(session, settings: settings, action: action) { output in
                await self.appendLog(output)
            }
            self.activity = "\(record.action.label)：\(record.status.label)"
        }
    }
    func runOnSimulator(_ session: Session) {
        guard session.repository.buildSettings != nil else { configureBuild(session); return }
        launch("Simulatorで起動中…") {
            self.runningBuild = session.id; self.liveLog = ""
            defer { self.runningBuild = nil }
            let result = try await self.coordinator.runOnSimulator(session) { await self.appendLog($0) }
            self.activity = "Simulator起動：\(result.record.status.label)"
            if result.record.status == .failed { self.error = result.record.message }
            if let deviceID = result.deviceID {
                do { try await MacIntegration.openSimulator(deviceID: deviceID) }
                catch { self.error = "アプリは起動しましたが、Simulatorの画面を開けませんでした。XcodeからDevice HubまたはSimulatorを開いてください。\n\(error.localizedDescription)" }
            }
        }
    }
    func removeSimulator(_ owned: ManagedSimulator) {
        launch("専用Simulatorを削除中…") {
            try await self.coordinator.removeSimulator(owned.id)
            self.activity = "専用Simulatorを削除しました。"
        }
    }
    private func appendLog(_ output: String) {
        liveLog.append(output)
        if liveLog.count > 40_000 { liveLog = String(liveLog.suffix(40_000)) }
    }
    func retrySave() {
        do { try coordinator.retrySave(); activity = "状態を保存しました。" }
        catch { self.error = error.localizedDescription }
    }
    func cancelBuild() { if runningBuild != nil { task?.cancel() } }
    func shutdown() async -> Bool {
        shuttingDown = true
        MacIntegration.cancelSelection()
        if runningBuild != nil || buildConfiguration != nil { task?.cancel() }
        await task?.value
        if coordinator.hasUnsavedChanges {
            do { try coordinator.retrySave() }
            catch {
                self.error = "状態を保存できないため終了を中止しました。保存先を確認し、「状態を再保存」を実行してください。\n\(error.localizedDescription)"
                shuttingDown = false
                return false
            }
        }
        return true
    }
}
