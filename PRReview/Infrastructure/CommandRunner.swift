import Foundation
import Subprocess

/// Keeps machine-readable stdout separate from diagnostics emitted on stderr.
public struct CommandResult: Sendable {
    public let standardOutput: String
    public let standardError: String
    public let exitCode: Int32?
    public let terminationDescription: String
    public var succeeded: Bool { exitCode == 0 }
}

public enum CommandRunner {
    public typealias OutputHandler = @Sendable (String) async -> Void

    // GUI-launched applications do not inherit an interactive shell's PATH.
    public static func executable(_ name: String) throws -> String {
        if name.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: name) { return name }
        for directory in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] {
            let path = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw ReviewError("\(name)が見つかりません。\(name == "gh" ? "Homebrewでghをインストールし、ターミナルでgh auth loginを実行してください。" : "Xcode Command Line Toolsをインストールしてください。")")
    }

    /// Git's NUL-delimited filenames must survive without whitespace trimming.
    public static func run(_ name: String, _ arguments: [String]) async throws -> String {
        let result = try await runCommand(name, arguments)
        guard result.succeeded else {
            throw ReviewError("\(name)が失敗しました（\(result.terminationDescription)）\n\((result.standardError + result.standardOutput).suffix(6000))")
        }
        return arguments.contains("-z") ? result.standardOutput : result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func git(_ path: String, _ arguments: [String]) async throws -> String {
        try await run("git", ["-c", "core.hooksPath=/dev/null", "-C", path] + arguments)
    }

    /// Streaming retains only the final 4 MiB per stream; the callback receives every line.
    /// Without a callback, complete machine-readable output is collected up to 64 MiB.
    public static func runCommand(_ name: String, _ arguments: [String], onOutput: OutputHandler? = nil) async throws -> CommandResult {
        try Task.checkCancellation()
        var options = PlatformOptions()
        // A distinct group lets cancellation terminate xcodebuild and its children
        // without ever signaling the application itself.
        options.processGroupID = 0
        let teardown: [TeardownStep] = [.gracefulShutDown(toProcessGroup: true, allowedDurationToNextStep: .seconds(2))]
        options.teardownSequence = teardown
        let environment = Environment.inherit.updating([
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "GIT_TERMINAL_PROMPT": "0",
            "GH_PROMPT_DISABLED": "1"
        ])
        let result = try await Subprocess.run(
            .path(.init(try executable(name))), arguments: Arguments(arguments), environment: environment,
            platformOptions: options, input: .none, output: .sequence, error: .sequence
        ) { execution in
            defer {
                // Cancellation can close the output streams without throwing.
                if Task.isCancelled { try? execution.send(signal: .kill, toProcessGroup: true) }
            }
            // Drain both pipes concurrently, including when one of them is very large.
            do {
                async let stdout = collect(execution.standardOutput, onOutput: onOutput)
                async let stderr = collect(execution.standardError, onOutput: onOutput)
                return try await (stdout, stderr)
            } catch {
                await execution.teardown(using: teardown)
                // Teardown can finish when the parent exits before its children.
                // Kill any remaining group members while the parent's PID has
                // not yet been reaped/reused (Execution is still in scope).
                try? execution.send(signal: .kill, toProcessGroup: true)
                throw error
            }
        }
        try Task.checkCancellation()
        let exitCode: Int32?
        switch result.terminationStatus {
        case .exited(let code): exitCode = code
        case .signaled: exitCode = nil
        }
        return CommandResult(standardOutput: result.closureResult.0, standardError: result.closureResult.1,
                             exitCode: exitCode, terminationDescription: result.terminationStatus.description)
    }

    private static func collect(_ stream: SubprocessOutputSequence, onOutput: OutputHandler?) async throws -> String {
        let limit = onOutput == nil ? 64 * 1024 * 1024 : 4 * 1024 * 1024
        var captured = Data()
        var line = Data()
        for try await buffer in stream {
            let bytes = buffer.withUnsafeBytes { Data($0) }
            captured.append(bytes)
            if captured.count > limit {
                guard onOutput != nil else { throw ReviewError("コマンドの出力が64 MiBを超えました。") }
                captured.removeFirst(captured.count - limit)
            }
            if let onOutput {
                line.append(bytes)
                while let end = line.firstIndex(of: 0x0A) {
                    let next = line.index(after: end)
                    let text = String(decoding: line[..<next], as: UTF8.self)
                    line.removeSubrange(..<next)
                    await onOutput(text)
                }
                guard line.count <= 1024 * 1024 else { throw ReviewError("コマンドのログ1行が1 MiBを超えました。") }
            }
        }
        if let onOutput, !line.isEmpty { await onOutput(String(decoding: line, as: UTF8.self)) }
        return String(decoding: captured, as: UTF8.self)
    }
}
