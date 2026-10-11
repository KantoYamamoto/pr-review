import Foundation

public struct ReviewError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct PullRequest: Equatable, Sendable {
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

public struct Repository: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var path: String
    public var slug: String
    public var entry: String
    public var copyPaths: [String]?
    public var buildSettings: BuildSettings?
    public init(path: String, slug: String, entry: String, copyPaths: [String] = []) {
        id = UUID(); self.path = path; self.slug = slug; self.entry = entry; self.copyPaths = copyPaths
    }
}

public struct CopiedFile: Codable, Equatable, Sendable {
    public var path: String
    public var sha256: String
}

public struct Session: Codable, Identifiable, Equatable, Sendable {
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
    public var buildRecords: [BuildRecord]?
    public var simulatorLaunches: [SimulatorLaunchRecord]?
    public init(id: UUID, repository: Repository, prURL: String, number: Int, title: String, sha: String, path: String) {
        self.id = id; self.repository = repository; self.prURL = prURL; self.number = number
        self.title = title; self.sha = sha; self.path = path; self.createdAt = Date()
    }
}

public struct SavedState: Codable, Sendable {
    public var repositories: [Repository] = []
    public var sessions: [Session] = []
    public var simulators: [ManagedSimulator]?
    public init() {}
}

public struct ProjectDiscovery: Sendable, Equatable {
    public let root: String
    public let entries: [String]
}

public enum ReviewBlocker: Sendable, Equatable {
    case changedCopy(String)
    case workingChanges([String])
    case localCommits(Int)
    case ignoredFiles([String])

    public var description: String {
        switch self {
        case .changedCopy(let path):
            return "コピーしたファイルが変更されています：\(path)\n必要な内容を元のリポジトリ等へ保存してください。"
        case .workingChanges(let paths):
            return "未コミット／未追跡の変更があります：\n\(paths.joined(separator: "\n").prefix(3000))"
        case .localCommits(let count):
            return "レビュー中のコミットから追加されたローカルコミットが\(count)件あります。"
        case .ignoredFiles(let paths):
            return "Git管理外（ignored）のファイルがあります：\n\(paths.joined(separator: "\n").prefix(2000))\n必要なファイルを保存するか、不要な生成物を手動で削除してください。"
        }
    }
}

public struct InspectionReport: Sendable, Equatable {
    public let blockers: [ReviewBlocker]
    public var isEmpty: Bool { blockers.isEmpty }
    public var description: String { blockers.map(\.description).joined(separator: "\n\n") }
}
