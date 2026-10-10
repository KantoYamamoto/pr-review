import Foundation

struct GitHubClient: Sendable {
    struct Metadata: Decodable, Sendable {
        let title: String
        let headRefOid: String
    }
    let command: @Sendable (String, [String]) async throws -> String

    @concurrent
    func metadata(for pr: PullRequest) async throws -> Metadata {
        let json = try await command("gh", ["pr", "view", pr.url, "--json", "title,headRefOid"])
        return try JSONDecoder().decode(Metadata.self, from: Data(json.utf8))
    }

    static func repositorySlug(_ remote: String) throws -> String {
        var value = remote
        if value.hasPrefix("git@github.com:") { value = String(value.dropFirst("git@github.com:".count)) }
        else if let url = URL(string: remote), url.host?.lowercased() == "github.com", ["https", "ssh"].contains(url.scheme ?? "") {
            value = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else { throw ReviewError("originがgithub.comのリポジトリではありません。GitHubのみ対応しています。") }
        if value.hasSuffix(".git") { value = String(value.dropLast(4)) }
        let parts = value.split(separator: "/")
        guard parts.count == 2 else { throw ReviewError("originのURLを確認してください。") }
        return value
    }
}
