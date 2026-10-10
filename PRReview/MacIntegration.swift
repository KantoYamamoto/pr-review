import AppKit

/// AppKit presentation stays on the main actor; service code never opens dialogs.
@MainActor
enum MacIntegration {
    private static var activePanel: NSOpenPanel?
    static func cancelSelection() { activePanel?.cancel(nil) }
    static func chooseRepository() async -> URL? {
        let panel = NSOpenPanel()
        panel.message = "普段使っているローカルのGitリポジトリを選択"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        return await present(panel).first
    }

    static func chooseProject(root: String) async -> URL? {
        let panel = NSOpenPanel()
        panel.message = "このリポジトリで開く.xcworkspaceまたは.xcodeprojを選択"
        panel.directoryURL = URL(fileURLWithPath: root)
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.treatsFilePackagesAsDirectories = false
        return await present(panel).first
    }

    static func chooseCopyFiles(repository: Repository) async -> [URL] {
        let panel = NSOpenPanel()
        panel.message = "リポジトリ内のignoreされている設定ファイルを選択"
        panel.directoryURL = URL(fileURLWithPath: repository.path)
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        return await present(panel)
    }

    private static func present(_ panel: NSOpenPanel) async -> [URL] {
        await withCheckedContinuation { continuation in
            activePanel = panel
            let completion: (NSApplication.ModalResponse) -> Void = { response in
                activePanel = nil
                continuation.resume(returning: response == .OK ? panel.urls : [])
            }
            if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: completion) }
            else { panel.begin(completionHandler: completion) }
        }
    }

    static func openArtifact(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    static func openSimulator(deviceID: String) async throws {
        guard UUID(uuidString: deviceID) != nil else { throw ReviewError("SimulatorのIDが不正です。") }
        let developer = URL(fileURLWithPath: try await CommandRunner.run("xcode-select", ["-p"]))
        let simulator = developer.appendingPathComponent("Applications/Simulator.app")
        let hub = developer.deletingLastPathComponent().appendingPathComponent("Applications/DeviceHub.app")
        let useHub = !FileManager.default.fileExists(atPath: simulator.path)
        let app = useHub ? hub : simulator
        guard FileManager.default.fileExists(atPath: app.path) else { throw ReviewError("選択中のXcodeにSimulatorの表示アプリが見つかりません。") }
        let configuration = NSWorkspace.OpenConfiguration()
        if !useHub { configuration.arguments = ["-CurrentDeviceUDID", deviceID] }
        _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    static func openXcode(_ entry: URL) async throws {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            throw ReviewError("Xcodeが見つかりません。")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open([entry], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
