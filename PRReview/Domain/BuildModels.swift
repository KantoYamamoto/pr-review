import Foundation

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
