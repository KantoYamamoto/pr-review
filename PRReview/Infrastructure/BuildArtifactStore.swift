import Foundation

/// Artifact ownership comes from session/run UUIDs, never from persisted log paths.
struct BuildArtifactStore: Sendable {
    let storage: URL

    struct Run: Sendable {
        let id: UUID
        let derivedData: URL
        let log: URL
        let result: URL
    }

    func prepareRun(for sessionID: UUID) throws -> Run {
        let sessionRoot = try artifacts(for: sessionID)
        try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let id = UUID()
        let runRoot = sessionRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try requireSafePath(runRoot)
        try FileManager.default.createDirectory(at: runRoot, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let derivedData = sessionRoot.appendingPathComponent("DerivedData", isDirectory: true)
        try requireSafePath(derivedData)
        return Run(id: id, derivedData: derivedData, log: runRoot.appendingPathComponent("build.log"),
                   result: runRoot.appendingPathComponent("Result.xcresult", isDirectory: true))
    }

    func removeArtifacts(sessionID: UUID) throws {
        let root = try artifacts(for: sessionID)
        do {
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
        } catch { throw ReviewError("ビルドデータの削除に失敗しました：\(root.path)\n\(error.localizedDescription)") }
    }

    func removeArtifacts(for session: Session) throws {
        try removeArtifacts(sessionID: session.id)
    }

    /// Validate persisted paths before opening them in Finder or Xcode.
    func validateArtifactURL(_ path: String, session: Session) throws -> URL {
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

    func artifacts(for sessionID: UUID) throws -> URL {
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
}
