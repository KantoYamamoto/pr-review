import Foundation

/// Xcode metadata and explicitly requested builds. No automatic builds or simulator provisioning.
public struct XcodeBuildService: Sendable {
    public typealias RunCommand = @Sendable (String, [String], CommandRunner.OutputHandler?) async throws -> CommandResult
    public let storage: URL
    private let artifacts: BuildArtifactStore
    private let command: RunCommand
    private let inspect: @Sendable (Session) async throws -> InspectionReport
    private let packageOptions = ["-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates"]

    public init(storage: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PRReview"),
                command: @escaping RunCommand = { try await CommandRunner.runCommand($0, $1, onOutput: $2) },
                inspect: (@Sendable (Session) async throws -> InspectionReport)? = nil) {
        self.storage = storage.standardizedFileURL
        self.artifacts = BuildArtifactStore(storage: storage.standardizedFileURL)
        self.command = command
        self.inspect = inspect ?? { try await ReviewService(storage: storage).inspect($0) }
    }

    @concurrent
    public func schemes(_ session: Session) async throws -> [String] {
        let arguments = try containerArguments(session) + packageOptions + ["-list", "-json"]
        let result = try await command("xcrun", ["xcodebuild"] + arguments, nil)
        try requireSuccess(result)
        return try XcodeBuildOutput.parseSchemes(result.standardOutput)
    }

    @concurrent
    public func destinations(_ session: Session, scheme: String) async throws -> [BuildDestination] {
        try validateScheme(scheme)
        let arguments = try containerArguments(session) + packageOptions + ["-scheme", scheme, "-showdestinations"]
        let result = try await command("xcrun", ["xcodebuild"] + arguments, nil)
        try requireSuccess(result)
        return XcodeBuildOutput.parseDestinations(result.standardOutput)
    }

    @concurrent
    public func run(_ session: Session, settings: BuildSettings, action: BuildAction,
                    onOutput: CommandRunner.OutputHandler? = nil) async throws -> BuildRecord {
        try Task.checkCancellation()
        try validateScheme(settings.scheme)
        guard !settings.destination.id.isEmpty, !settings.destination.id.contains(","),
              !settings.destination.id.contains("\n"),
              ["macOS", "iOS Simulator"].contains(settings.destination.platform) else {
            throw ReviewError("MacまたはiOS Simulatorの実行先を選んでください。")
        }
        let container = try containerArguments(session)
        let initialInspection = try await inspect(session)
        guard initialInspection.isEmpty else {
            throw ReviewError("ビルド前にレビュー環境の変更を保存・整理してください。\n\n\(initialInspection.description)")
        }
        // A manually switched HEAD cannot be labelled as the saved PR commit.
        let head = try await git(session, ["rev-parse", "HEAD"])
        guard head == session.sha else { throw ReviewError("レビューのコミットと現在のHEADが異なります。最新コミットを取得し直してください。") }
        let run = try artifacts.prepareRun(for: session.id)
        let log = try BuildLog(url: run.log)
        let arguments = ["xcodebuild"] + container + packageOptions + [
            "-scheme", settings.scheme,
            "-destination", "platform=\(settings.destination.platform),id=\(settings.destination.id)",
            "-derivedDataPath", run.derivedData.path,
            "-resultBundlePath", run.result.path,
            action.rawValue
        ]
        var status: BuildStatus
        do {
            let result = try await command("xcrun", arguments) { text in
                await log.append(text)
                await onOutput?(text)
            }
            status = result.succeeded ? .succeeded : .failed
            await log.append("\n終了：\(result.terminationDescription)\n")
        } catch is CancellationError {
            status = .cancelled
            await log.append("\nユーザーによって中断されました。\n")
        } catch {
            status = Task.isCancelled ? .cancelled : .failed
            await log.append("\n\(error.localizedDescription)\n")
        }
        try await log.close()
        // A cancelled build still returns its outcome after subprocess teardown,
        // so the coordinator can persist it before releasing the operation gate.
        var sourceModified = false
        if status != .cancelled {
            do {
                let finalHead = try await git(session, ["rev-parse", "HEAD"])
                let finalInspection = try await inspect(session)
                if finalHead != head || !finalInspection.isEmpty { status = .failed; sourceModified = true }
            } catch { status = .failed; sourceModified = true }
        }
        return BuildRecord(id: run.id, sha: head, configuration: settings, action: action, status: status,
                           date: Date(), logPath: run.log.path,
                           resultPath: FileManager.default.fileExists(atPath: run.result.path) ? run.result.path : nil,
                           sourceModified: sourceModified)
    }

    public func removeArtifacts(for session: Session) throws {
        try artifacts.removeArtifacts(for: session)
    }

    @concurrent
    public func cleanupArtifacts(for session: Session) async throws {
        try artifacts.removeArtifacts(for: session)
    }

    public func validateArtifactURL(_ path: String, session: Session) throws -> URL {
        try artifacts.validateArtifactURL(path, session: session)
    }

    public func artifacts(for sessionID: UUID) throws -> URL {
        try artifacts.artifacts(for: sessionID)
    }

    private func containerArguments(_ session: Session) throws -> [String] {
        let root = try ReviewPaths(storage: storage).worktree(for: session)
        return try XcodeProject(root: root.path, relativePath: session.repository.entry).buildArguments
    }

    private func validateScheme(_ scheme: String) throws {
        guard !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !scheme.contains("\0") else {
            throw ReviewError("Schemeを選んでください。")
        }
    }

    private func git(_ session: Session, _ arguments: [String]) async throws -> String {
        let result = try await command("git", ["-c", "core.hooksPath=/dev/null", "-C", session.path] + arguments, nil)
        try requireSuccess(result)
        return result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func requireSuccess(_ result: CommandResult) throws {
        guard result.succeeded else {
            throw ReviewError("Xcodeの操作が失敗しました（\(result.terminationDescription)）\n\((result.standardError + result.standardOutput).suffix(6000))")
        }
    }
}
