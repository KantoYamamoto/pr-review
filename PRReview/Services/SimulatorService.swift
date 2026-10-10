import Foundation

/// Only list operations can use a selected development device. Mutations require an
/// exact match to a persisted creation intent, including name, runtime and device type.
public struct SimulatorService: Sendable {
    private let command: XcodeBuildService.RunCommand

    public init(command: @escaping XcodeBuildService.RunCommand = { try await CommandRunner.runCommand($0, $1, onOutput: $2) }) {
        self.command = command
    }

    @concurrent
    public func configuration(for session: Session, destination: BuildDestination) async throws -> ManagedSimulator {
        guard destination.platform == "iOS Simulator", UUID(uuidString: destination.id) != nil else {
            throw ReviewError("「設定…」でiOS Simulatorを選択してください。")
        }
        let devices = try await listDevices()
        guard let pair = devices.first(where: { $0.value.contains { $0.udid == destination.id } }),
              let device = pair.value.first(where: { $0.udid == destination.id }), device.isAvailable,
              pair.key.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-"),
              let type = device.deviceTypeIdentifier, !type.isEmpty else {
            throw ReviewError("保存したSimulatorが利用できません。XcodeのSettings > ComponentsでiOS runtimeをインストールし、「設定…」で実行先を選び直してください。")
        }
        try await requireRuntime(pair.key)
        return ManagedSimulator(id: UUID(), sessionID: session.id, repository: session.repository.slug,
                                number: session.number, templateID: destination.id, deviceType: type,
                                runtime: pair.key, deviceLabel: device.name)
    }

    /// The coordinator shields this short creation transaction from cancellation.
    @concurrent
    public func ensureDevice(_ owned: ManagedSimulator) async throws -> String {
        try await requireRuntime(owned.runtime)
        if let existing = try await findDevice(owned) {
            guard existing.isAvailable else { throw ReviewError("レビュー用Simulatorを利用できません。XcodeのSettings > Componentsでruntimeを確認してください。") }
            return existing.udid
        }
        let result = try await execute(["create", owned.name, owned.deviceType, owned.runtime], stage: "Simulatorの作成")
        let id = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        var createdIntent = owned
        createdIntent.deviceID = id
        guard UUID(uuidString: id) != nil, let created = try await findDevice(createdIntent), created.udid == id else {
            throw ReviewError("作成したSimulatorを確認できませんでした。作成記録を保持しています。再実行するか「専用Simulatorの管理…」を確認してください。")
        }
        return id
    }

    @concurrent
    func launch(_ app: SimulatorApp, on owned: ManagedSimulator, deviceID: String,
                onOutput: CommandRunner.OutputHandler?) async throws {
        // Resolve ownership again immediately before each mutation, never use "booted".
        try await validateDevice(deviceID, owned: owned)
        _ = try await execute(["bootstatus", deviceID, "-b"], stage: "Simulatorの起動", output: onOutput)
        try await validateDevice(deviceID, owned: owned)
        _ = try await execute(["install", deviceID, app.url.path], stage: "アプリのインストール", output: onOutput)
        try await validateDevice(deviceID, owned: owned)
        _ = try await execute(["launch", "--terminate-running-process", deviceID, app.bundleID], stage: "アプリの起動", output: onOutput)
    }

    @concurrent
    public func remove(_ owned: ManagedSimulator) async throws {
        guard let device = try await findDevice(owned) else { return }
        if device.state != "Shutdown" {
            _ = try await execute(["shutdown", device.udid], stage: "専用Simulatorの停止")
        }
        try await validateDevice(device.udid, owned: owned)
        _ = try await execute(["delete", device.udid], stage: "専用Simulatorの削除")
    }

    private func validateDevice(_ id: String, owned: ManagedSimulator) async throws {
        try Task.checkCancellation()
        guard let device = try await findDevice(owned), device.udid == id else {
            throw ReviewError("専用Simulatorの作成記録と端末が一致しません。操作を中止しました。")
        }
    }

    private func findDevice(_ owned: ManagedSimulator) async throws -> Device? {
        let devices = try await listDevices()
        let all = devices.flatMap { runtime, devices in devices.map { (runtime, $0) } }
        let matches = all.filter { $0.1.name == owned.name }
        if let id = owned.deviceID {
            guard UUID(uuidString: id) != nil else { throw ReviewError("専用Simulatorの保存済みIDが不正です。") }
            if let device = all.first(where: { $0.1.udid == id }) {
                guard device.1.name == owned.name else {
                    throw ReviewError("専用Simulatorの名前が作成記録から変更されています。端末は変更・削除していません。Device HubまたはSimulatorで名前を戻してから再試行してください。")
                }
            } else {
                guard matches.isEmpty else { throw ReviewError("作成記録と異なるIDのSimulatorが同じ名前で存在します。端末は変更・削除していません。") }
                return nil
            }
        }
        guard matches.count <= 1 else { throw ReviewError("同名の専用Simulatorが複数あります。Device HubまたはSimulatorで確認してください。端末は削除していません。") }
        guard let match = matches.first else { return nil }
        guard match.0 == owned.runtime, match.1.deviceTypeIdentifier == owned.deviceType,
              UUID(uuidString: match.1.udid) != nil else {
            throw ReviewError("専用Simulatorのruntimeまたは端末種別が作成記録と異なります。端末は変更・削除していません。")
        }
        return match.1
    }

    private func listDevices() async throws -> [String: [Device]] {
        let result = try await execute(["list", "devices", "--json"], stage: "Simulator一覧の取得")
        return try JSONDecoder().decode(DeviceList.self, from: Data(result.standardOutput.utf8)).devices
    }

    private func requireRuntime(_ id: String) async throws {
        let result = try await execute(["list", "runtimes", "--json"], stage: "runtime一覧の取得")
        let runtimes = try JSONDecoder().decode(RuntimeList.self, from: Data(result.standardOutput.utf8)).runtimes
        guard id.hasPrefix("com.apple.CoreSimulator.SimRuntime.iOS-"),
              runtimes.contains(where: { $0.identifier == id && $0.isAvailable }) else {
            throw ReviewError("\(id) が利用できません。XcodeのSettings > Componentsで対応するiOS runtimeをインストールしてください。")
        }
    }

    private func execute(_ arguments: [String], stage: String, output: CommandRunner.OutputHandler? = nil) async throws -> CommandResult {
        try Task.checkCancellation()
        await output?("\n\(stage)…\n")
        let result = try await command("xcrun", ["simctl"] + arguments, output)
        guard result.succeeded else {
            throw ReviewError("\(stage)に失敗しました（\(result.terminationDescription)）。\n\((result.standardError + result.standardOutput).suffix(4000))\nDevice HubまたはSimulatorで端末の状態を確認してください。")
        }
        return result
    }

    private struct DeviceList: Decodable { let devices: [String: [Device]] }
    private struct Device: Decodable {
        let name: String
        let udid: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String?
        let state: String
    }
    private struct RuntimeList: Decodable { let runtimes: [Runtime] }
    private struct Runtime: Decodable { let identifier: String; let isAvailable: Bool }
}
