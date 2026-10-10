import Foundation

/// Persisted before creation. The random identifier gives a recoverable, exact device name.
public struct ManagedSimulator: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var repository: String
    public var number: Int
    public var templateID: String
    public var deviceType: String
    public var runtime: String
    public var deviceID: String?
    public var deviceLabel: String
    public var name: String { "PR Review \(id.uuidString) · \(deviceLabel)" }
    public var label: String { "\(repository) #\(number) · \(deviceLabel)" }
}

public struct SimulatorLaunchRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID = UUID()
    public var sha: String
    public var date: Date = Date()
    public var status: BuildStatus
    public var buildID: UUID?
    public var simulatorName: String?
    public var message: String
}

struct SimulatorApp: Sendable {
    let url: URL
    let bundleID: String
}

public struct SimulatorLaunchResult: Sendable {
    public let record: SimulatorLaunchRecord
    public let deviceID: String?
}
