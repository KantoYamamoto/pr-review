import Foundation

/// Resolves literal relative paths without following symlinks or entering Git metadata.
enum RepositoryFileSafety {
    static func file(root: String, relative: String) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.contains("\0"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git" }) else {
            throw ReviewError("リポジトリ内の相対パスが不正です：\(relative)")
        }
        var url = URL(fileURLWithPath: root).standardizedFileURL
        guard url.resolvingSymlinksInPath() == url else { throw ReviewError("リポジトリのルートがシンボリックリンクです。") }
        for component in parts {
            url.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw ReviewError("シンボリックリンクがパスに含まれています：\(relative)")
            }
        }
        return url
    }
}
