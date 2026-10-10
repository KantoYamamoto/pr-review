import Foundation

extension ReviewService {
    /// Discover file-backed containers without traversing ignored directories or package interiors.
    @concurrent
    public func discoverProjects(path: String) async throws -> ProjectDiscovery {
        let root = URL(fileURLWithPath: try await git(path, ["rev-parse", "--show-toplevel"])).resolvingSymlinksInPath().path
        _ = try Self.githubSlug(await git(root, ["remote", "get-url", "origin"]))
        let files = try await git(root, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"])
        let excluded: Set<String> = [".git", ".build", "build", "deriveddata", "pods", "carthage", "node_modules", ".swiftpm"]
        var candidates = Set<String>()
        var examined = Set<String>()
        for file in files.split(separator: "\0") {
            let parts = file.split(separator: "/").map(String.init)
            for (index, part) in parts.enumerated() {
                if excluded.contains(part.lowercased()) { break }
                let ext = URL(fileURLWithPath: part).pathExtension
                if ["xcodeproj", "xcworkspace"].contains(ext) {
                    let entry = parts.prefix(index + 1).joined(separator: "/")
                    if examined.insert(entry).inserted, (try? validateProject(root: root, relative: entry)) != nil { candidates.insert(entry) }
                    break
                }
                // Other bundles/packages must not contribute embedded projects.
                if ["app", "framework", "bundle", "xcassets", "xcarchive", "playground", "xcframework"].contains(ext) { break }
            }
        }
        return ProjectDiscovery(root: root, entries: candidates.sorted {
            let left = $0.hasSuffix(".xcworkspace"), right = $1.hasSuffix(".xcworkspace")
            return left == right ? $0 < $1 : left
        })
    }
    func validateProject(root: String, relative: String) throws {
        let entry = try RepositoryFileSafety.file(root: root, relative: relative)
        let marker: String
        switch entry.pathExtension {
        case "xcodeproj": marker = "project.pbxproj"
        case "xcworkspace": marker = "contents.xcworkspacedata"
        default: throw ReviewError(".xcworkspaceまたは.xcodeprojを選んでください。")
        }
        let file = try RepositoryFileSafety.file(root: root, relative: relative + "/" + marker)
        guard try FileManager.default.attributesOfItem(atPath: entry.path)[.type] as? FileAttributeType == .typeDirectory,
              try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else {
            throw ReviewError("Xcodeプロジェクトの構成ファイルが見つかりません：\(relative)")
        }
    }
    @concurrent
    public func register(path: String, entryPath: String) async throws -> Repository {
        let root = try await git(path, ["rev-parse", "--show-toplevel"])
        let remote = try await git(root, ["remote", "get-url", "origin"])
        let slug = try Self.githubSlug(remote)
        let rootURL = URL(fileURLWithPath: root).resolvingSymlinksInPath()
        let entryURL = URL(fileURLWithPath: entryPath).standardizedFileURL
        guard entryURL.path.hasPrefix(rootURL.path + "/"),
              ["xcodeproj", "xcworkspace"].contains(entryURL.pathExtension) else {
            throw ReviewError("リポジトリ内の.xcworkspaceまたは.xcodeprojを選んでください。")
        }
        let relative = String(entryURL.path.dropFirst(rootURL.path.count + 1))
        try validateProject(root: rootURL.path, relative: relative)
        return Repository(path: rootURL.path, slug: slug, entry: relative)
    }
    public static func githubSlug(_ remote: String) throws -> String {
        try GitHubClient.repositorySlug(remote)
    }
}
