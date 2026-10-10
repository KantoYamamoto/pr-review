import Foundation

/// Git arguments remain literal; hooks are disabled for application-owned operations.
struct GitClient: Sendable {
    let command: @Sendable (String, [String]) async throws -> String

    @concurrent
    func run(at path: String, _ arguments: [String]) async throws -> String {
        // check-ignore consumes literal filenames and rejects pathspec magic.
        let literal = arguments.first == "check-ignore" ? [] : ["--literal-pathspecs"]
        return try await command("git", ["-c", "core.hooksPath=/dev/null"] + literal + ["-C", path] + arguments)
    }
}
