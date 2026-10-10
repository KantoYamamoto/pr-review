import Foundation
import Darwin

public struct BuildDestination: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var platform: String
    public var label: String { "\(name)（\(platform)）" }
    public init(id: String, name: String, platform: String) {
        self.id = id; self.name = name; self.platform = platform
    }
}

public struct BuildSettings: Codable, Sendable, Equatable {
    public var scheme: String
    public var destination: BuildDestination
    public init(scheme: String, destination: BuildDestination) {
        self.scheme = scheme; self.destination = destination
    }
}

public enum BuildAction: String, Codable, Sendable, CaseIterable {
    case build, test
    public var label: String { self == .build ? "ビルド" : "テスト" }
}

public enum BuildStatus: String, Codable, Sendable {
    case succeeded, failed, cancelled
    public var label: String {
        switch self {
        case .succeeded: "成功"
        case .failed: "失敗"
        case .cancelled: "中断"
        }
    }
}

public struct BuildRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sha: String
    public var configuration: BuildSettings
    public var action: BuildAction
    public var status: BuildStatus
    public var date: Date
    public var logPath: String
    public var resultPath: String?
    /// External source changes during execution invalidate a successful command result.
    public var sourceModified: Bool
}

/// Xcode metadata and explicitly requested builds. No automatic builds or simulator provisioning.
public struct XcodeBuildService: Sendable {
    public typealias RunCommand = @Sendable (String, [String], CommandRunner.OutputHandler?) async throws -> CommandResult
    public let storage: URL
    private let command: RunCommand
    private let inspect: @Sendable (Session) async throws -> InspectionReport
    private let packageOptions = ["-disableAutomaticPackageResolution", "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates"]

    public init(storage: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PRReview"),
                command: @escaping RunCommand = { try await CommandRunner.runCommand($0, $1, onOutput: $2) },
                inspect: (@Sendable (Session) async throws -> InspectionReport)? = nil) {
        self.storage = storage.standardizedFileURL
        self.command = command
        self.inspect = inspect ?? { try await ReviewService(storage: storage).inspect($0) }
    }

    @concurrent
    public func schemes(_ session: Session) async throws -> [String] {
        let arguments = try containerArguments(session) + packageOptions + ["-list", "-json"]
        let result = try await command("xcrun", ["xcodebuild"] + arguments, nil)
        try requireSuccess(result)
        return try Self.parseSchemes(result.standardOutput)
    }

    @concurrent
    public func destinations(_ session: Session, scheme: String) async throws -> [BuildDestination] {
        try validateScheme(scheme)
        let arguments = try containerArguments(session) + packageOptions + ["-scheme", scheme, "-showdestinations"]
        let result = try await command("xcrun", ["xcodebuild"] + arguments, nil)
        try requireSuccess(result)
        return Self.parseDestinations(result.standardOutput)
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
        let sessionRoot = try artifacts(for: session.id)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let runID = UUID()
        let runRoot = sessionRoot.appendingPathComponent(runID.uuidString, isDirectory: true)
        try requireSafePath(runRoot)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let derivedData = sessionRoot.appendingPathComponent("DerivedData", isDirectory: true)
        try requireSafePath(derivedData)
        let logURL = runRoot.appendingPathComponent("build.log")
        let resultURL = runRoot.appendingPathComponent("Result.xcresult", isDirectory: true)
        let log = try BuildLog(url: logURL)
        let arguments = ["xcodebuild"] + container + packageOptions + [
            "-scheme", settings.scheme,
            "-destination", "platform=\(settings.destination.platform),id=\(settings.destination.id)",
            "-derivedDataPath", derivedData.path,
            "-resultBundlePath", resultURL.path,
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
        // Cancellation must still return a durable record. The coordinator persists it
        // outside the cancelled task, and waits for subprocess teardown before unlocking.
        var sourceModified = false
        if status != .cancelled {
            do {
                let finalHead = try await git(session, ["rev-parse", "HEAD"])
                let finalInspection = try await inspect(session)
                if finalHead != head || !finalInspection.isEmpty { status = .failed; sourceModified = true }
            } catch { status = .failed; sourceModified = true }
        }
        return BuildRecord(id: runID, sha: head, configuration: settings, action: action, status: status,
                           date: Date(), logPath: logURL.path,
                           resultPath: FileManager.default.fileExists(atPath: resultURL.path) ? resultURL.path : nil,
                           sourceModified: sourceModified)
    }

    /// Only the UUID-derived directory is removable; saved log paths are never trusted as deletion targets.
    public func removeArtifacts(sessionID: UUID) throws {
        let root = try artifacts(for: sessionID)
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        } catch { throw ReviewError("レビュー環境は削除しましたが、ビルドデータの削除に失敗しました：\(root.path)\n\(error.localizedDescription)") }
    }

    public func removeArtifacts(for session: Session) throws {
        try removeArtifacts(sessionID: session.id)
    }

    @concurrent
    public func cleanupArtifacts(for session: Session) async throws {
        try removeArtifacts(for: session)
    }

    /// Validate persisted paths before opening them in Finder or Xcode.
    public func validateArtifactURL(_ path: String, session: Session) throws -> URL {
        let root = try artifacts(for: session.id)
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/") else { throw ReviewError("管理対象外のビルドログは開けません。") }
        let components = url.path.dropFirst(root.path.count + 1).split(separator: "/")
        guard components.count == 2, UUID(uuidString: String(components[0])) != nil,
              ["build.log", "Result.xcresult"].contains(String(components[1])) else {
            throw ReviewError("ビルド成果物のパスが不正です。")
        }
        try requireSafePath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ReviewError("ビルドログ・結果が見つかりません。") }
        return url
    }

    public func artifacts(for sessionID: UUID) throws -> URL {
        let root = storage.appendingPathComponent("Builds", isDirectory: true).appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try requireSafePath(root)
        return root
    }

    private func requireSafePath(_ url: URL) throws {
        let path = url.standardizedFileURL
        guard path.path.hasPrefix(storage.path + "/"), storage.resolvingSymlinksInPath() == storage else {
            throw ReviewError("ビルドデータの保存先が管理対象外です。")
        }
        var current = storage
        let relative = path.path.dropFirst(storage.path.count + 1)
        for part in relative.split(separator: "/") {
            current.appendPathComponent(String(part))
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) == nil else {
                throw ReviewError("ビルドデータの保存先がシンボリックリンクです。削除・上書きせず保護しました。")
            }
        }
    }

    private func containerArguments(_ session: Session) throws -> [String] {
        let root = URL(fileURLWithPath: session.path).standardizedFileURL
        let expected = storage.appendingPathComponent("Worktrees", isDirectory: true).appendingPathComponent(session.id.uuidString)
        let components = session.repository.entry.split(separator: "/", omittingEmptySubsequences: false)
        guard root == expected, root.resolvingSymlinksInPath() == root,
              !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw ReviewError("Xcodeプロジェクトのパスが不正です。")
        }
        var entry = root
        for component in components {
            entry.appendPathComponent(String(component))
            guard (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path)) == nil else {
                throw ReviewError("Xcodeプロジェクトのシンボリックリンクは開けません。")
            }
        }
        guard ["xcodeproj", "xcworkspace"].contains(entry.pathExtension),
              (try? FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType) == .typeDirectory else {
            throw ReviewError("このPRには登録したXcodeプロジェクトがありません。")
        }
        let marker = entry.appendingPathComponent(entry.pathExtension == "xcworkspace" ? "contents.xcworkspacedata" : "project.pbxproj")
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: marker.path)) == nil,
              (try? FileManager.default.attributesOfItem(atPath: marker.path)[.type] as? FileAttributeType) == .typeRegular else {
            throw ReviewError("Xcodeプロジェクトの構成ファイルが見つかりません。")
        }
        return [entry.pathExtension == "xcworkspace" ? "-workspace" : "-project", entry.path]
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

    static func parseSchemes(_ output: String) throws -> [String] {
        struct Container: Decodable { var schemes: [String]? }
        struct Listing: Decodable { var project: Container?; var workspace: Container? }
        let listing = try JSONDecoder().decode(Listing.self, from: Data(output.utf8))
        return Array(Set(listing.workspace?.schemes ?? listing.project?.schemes ?? [])).sorted()
    }

    /// xcodebuild has no JSON destination listing. Accept only explicit supported
    /// platform/ID records in its compatible section, and reject unavailable rows.
    static func parseDestinations(_ output: String) -> [BuildDestination] {
        let expression = try! NSRegularExpression(pattern: #"(?:^|,\s*)(platform|arch|id|OS|name|error):\s*(.*?)(?=,\s*(?:platform|arch|id|OS|name|error):|$)"#)
        var compatible = false
        var destinations: [BuildDestination] = []
        for line in output.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("destinations compatible with") || lower.contains("available destinations for") { compatible = true; continue }
            if lower.contains("destinations incompatible with") || lower.contains("ineligible destinations") { compatible = false; continue }
            guard compatible, line.contains("{"), line.contains("}"), !line.contains("error:") else { continue }
            var fields: [String: String] = [:]
            let body = String(line.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst().dropLast())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Device names may contain commas and colons; split only at known keys.
            for match in expression.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                guard let key = Range(match.range(at: 1), in: body), let value = Range(match.range(at: 2), in: body) else { continue }
                fields[String(body[key])] = body[value].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard let id = fields["id"], !id.isEmpty, !id.contains("placeholder"),
                  let name = fields["name"], let platform = fields["platform"],
                  ["macOS", "iOS Simulator"].contains(platform),
                  !destinations.contains(where: { $0.id == id && $0.platform == platform }) else { continue }
            destinations.append(BuildDestination(id: id, name: name, platform: platform))
        }
        return destinations.sorted { $0.label < $1.label }
    }
}

private actor BuildLog {
    private let handle: FileHandle
    private var failure: (any Error)?
    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ReviewError("ビルドログを安全に作成できませんでした。") }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func append(_ text: String) {
        do { try handle.write(contentsOf: Data(text.utf8)) }
        catch { failure = error }
    }
    func close() throws {
        try handle.close()
        if let failure { throw failure }
    }
}
