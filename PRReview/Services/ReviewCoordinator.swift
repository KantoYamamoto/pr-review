import Foundation
import Observation

/// Owns lifecycle transactions and persistence. The explicit gate remains held across
/// suspension points; actor isolation alone does not prevent overlapping operations.
@MainActor
@Observable
public final class ReviewCoordinator {
    public private(set) var state: SavedState
    public private(set) var busy = false
    public private(set) var loadError: String?
    public private(set) var hasUnsavedChanges = false
    @ObservationIgnored private let service: ReviewService
    @ObservationIgnored private let buildService: XcodeBuildService
    @ObservationIgnored private let store: StateStore

    public init(service: ReviewService = ReviewService(), store: StateStore? = nil, buildService: XcodeBuildService? = nil) {
        self.service = service
        self.store = store ?? service.stateStore
        self.buildService = buildService ?? XcodeBuildService(storage: service.storage)
        do { state = try self.store.load() }
        catch {
            state = SavedState()
            loadError = "保存状態を読み込めませんでした。既存の保存ファイルは保持しています。\n\(error.localizedDescription)"
        }
    }

    func runExclusive<T: Sendable>(operation: @MainActor () async throws -> T) async throws -> T {
        guard !busy else { throw ReviewError("別の操作を実行中です。完了してからもう一度お試しください。") }
        if let loadError { throw ReviewError(loadError) }
        busy = true
        defer { busy = false }
        return try await operation()
    }

    public func discover(path: String) async throws -> ProjectDiscovery {
        try await runExclusive { try await service.discoverProjects(path: path) }
    }

    @discardableResult
    public func register(path: String, entryPath: String) async throws -> Repository {
        try await runExclusive {
            var repository = try await service.register(path: path, entryPath: entryPath)
            var next = state
            if let index = next.repositories.firstIndex(where: { $0.slug.lowercased() == repository.slug.lowercased() }) {
                repository.id = next.repositories[index].id
                repository.copyPaths = next.repositories[index].copyPaths
                repository.buildSettings = next.repositories[index].buildSettings
                next.repositories[index] = repository
            } else { next.repositories.append(repository) }
            try persist(next)
            return repository
        }
    }

    @discardableResult
    public func configureCopies(_ repository: Repository, paths: [String]) async throws -> Repository {
        try await runExclusive {
            guard let index = state.repositories.firstIndex(where: { $0.id == repository.id }) else {
                throw ReviewError("登録リポジトリが変更されています。設定を開き直してください。")
            }
            let configured = try await service.configureCopies(state.repositories[index], paths: paths)
            var next = state; next.repositories[index] = configured
            try persist(next)
            return configured
        }
    }

    public func create(_ pr: PullRequest, repository: Repository) async throws -> Session {
        try await runExclusive {
            if let existing = state.sessions.first(where: { $0.prURL == pr.url }) { return existing }
            let repository = try currentRepository(repository.id)
            let service = service
            // Do not cancel a transaction after Git begins changing the filesystem.
            // The gate stays held until the task and its recovery work are complete.
            let session = try await Task { try await service.create(pr, repository: repository) }.value
            state.sessions.insert(session, at: 0)
            do { try persist(state) }
            catch {
                hasUnsavedChanges = true
                throw ReviewError("レビュー環境を作成しましたが、状態を保存できませんでした。環境は保持しています：\(session.path)\n「状態を再保存」を実行してください。\n\(error.localizedDescription)")
            }
            return session
        }
    }

    public func update(_ session: Session) async throws -> Session {
        try await runExclusive {
            let index = try currentIndex(session)
            let session = state.sessions[index]
            let service = service
            let updated = try await Task { try await service.update(session) }.value
            var next = state; next.sessions[index] = updated
            do { try persist(next) }
            catch {
                let saveError = error
                if updated.sha != session.sha {
                    do { try await Task { try await service.rollback(updated, to: session.sha) }.value }
                    catch {
                        state = next
                        hasUnsavedChanges = true
                        throw ReviewError("状態の保存と元のコミットへの復帰に失敗しました。環境は保持しています：\(session.path)\n現在のHEADを確認し、状態を再保存してください。\n\(error.localizedDescription)")
                    }
                }
                throw saveError
            }
            return updated
        }
    }

    public func inspect(_ session: Session) async throws -> InspectionReport {
        try await runExclusive {
            let index = try currentIndex(session)
            return try await service.inspect(state.sessions[index])
        }
    }

    public func remove(_ session: Session) async throws {
        try await runExclusive {
            let index = try currentIndex(session)
            let session = state.sessions[index]
            let service = service
            try await Task { try await service.remove(session) }.value
            // Removal cannot be rolled back. Keep in-memory state accurate even if
            // writing JSON fails, and allow an explicit retry without touching Git.
            state.sessions.removeAll { $0.id == session.id }
            var errors: [String] = []
            do { try persist(state) }
            catch {
                hasUnsavedChanges = true
                errors.append("状態を保存できませんでした。「状態を再保存」を実行してください。\n\(error.localizedDescription)")
            }
            let buildService = buildService
            do { try await Task { try await buildService.cleanupArtifacts(for: session) }.value }
            catch { errors.append("ビルドデータの削除に失敗しました。データは保持しています。\n\(error.localizedDescription)") }
            if !errors.isEmpty { throw ReviewError("レビュー環境は削除しました。\n" + errors.joined(separator: "\n\n")) }
        }
    }

    public func projectURL(for session: Session) throws -> URL {
        let index = try currentIndex(session)
        return try service.entry(for: state.sessions[index])
    }

    public func relativeCopyPath(_ file: URL, repository: Repository) throws -> String {
        try service.relativeCopyPath(file, repository: currentRepository(repository.id))
    }

    public func artifactURL(_ path: String, for session: Session) throws -> URL {
        let index = try currentIndex(session)
        return try buildService.validateArtifactURL(path, session: state.sessions[index])
    }

    public func schemes(for session: Session) async throws -> [String] {
        try await runExclusive {
            let index = try currentIndex(session)
            return try await buildService.schemes(state.sessions[index])
        }
    }

    public func destinations(for session: Session, scheme: String) async throws -> [BuildDestination] {
        try await runExclusive {
            let index = try currentIndex(session)
            return try await buildService.destinations(state.sessions[index], scheme: scheme)
        }
    }

    public func runBuild(_ session: Session, settings: BuildSettings, action: BuildAction,
                         onOutput: CommandRunner.OutputHandler? = nil) async throws -> BuildRecord {
        try await runExclusive {
            let index = try currentIndex(session)
            let session = state.sessions[index]
            // Builds are cancellable, unlike worktree mutation transactions. The
            // build service waits for subprocess teardown before returning a record.
            let record = try await buildService.run(session, settings: settings, action: action, onOutput: onOutput)
            try recordBuild(record, for: session)
            return record
        }
    }

    /// Called inside a gated build operation after execution completes.
    private func recordBuild(_ record: BuildRecord, for session: Session) throws {
        let index = try currentIndex(session)
        guard record.sha == state.sessions[index].sha else { throw ReviewError("ビルド対象のコミットが変わっています。") }
        state.sessions[index].buildRecords = (state.sessions[index].buildRecords ?? []) + [record]
        do { try persist(state) }
        catch { hasUnsavedChanges = true; throw error }
    }

    /// A selection becomes this review's configuration and the default for future reviews.
    public func saveBuildSettings(_ settings: BuildSettings, for session: Session) throws {
        guard !busy else { throw ReviewError("別の操作を実行中です。") }
        if let loadError { throw ReviewError(loadError) }
        let index = try currentIndex(session)
        var next = state
        next.sessions[index].repository.buildSettings = settings
        if let repositoryIndex = next.repositories.firstIndex(where: { $0.id == state.sessions[index].repository.id }) {
            next.repositories[repositoryIndex].buildSettings = settings
        }
        try persist(next)
    }

    public func retrySave() throws {
        guard !busy else { throw ReviewError("別の操作を実行中です。") }
        if let loadError { throw ReviewError(loadError) }
        try persist(state)
    }

    private func currentRepository(_ id: UUID) throws -> Repository {
        guard let repository = state.repositories.first(where: { $0.id == id }) else {
            throw ReviewError("登録リポジトリが見つかりません。登録を確認してください。")
        }
        return repository
    }

    private func currentIndex(_ session: Session) throws -> Int {
        guard let index = state.sessions.firstIndex(where: { $0.id == session.id }),
              state.sessions[index].path == session.path, state.sessions[index].sha == session.sha else {
            throw ReviewError("レビュー環境が変更されています。選択し直してください。")
        }
        return index
    }

    private func persist(_ next: SavedState) throws {
        try store.save(next)
        state = next
        hasUnsavedChanges = false
    }
}
