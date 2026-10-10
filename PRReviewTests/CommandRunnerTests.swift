import Foundation
import Darwin
import Testing
@testable import PRReview

struct CommandRunnerTests {
    @Test func stdoutRemainsMachineReadableWhenStderrContainsDiagnostics() async throws {
        let result = try await CommandRunner.runCommand("/bin/sh", ["-c", "printf '{\"value\":42}'; printf 'warning\\n' >&2"])
        #expect(result.succeeded)
        #expect(result.standardError == "warning\n")
        #expect(try JSONDecoder().decode([String: Int].self, from: Data(result.standardOutput.utf8)) == ["value": 42])
    }

    @Test func unsuccessfulExitIsAResultAndHighLevelRunThrows() async throws {
        let result = try await CommandRunner.runCommand("/bin/sh", ["-c", "printf 'diagnostic' >&2; exit 23"])
        #expect(result.exitCode == 23)
        #expect(!result.succeeded)
        await #expect(throws: ReviewError.self) {
            try await CommandRunner.run("/bin/sh", ["-c", "printf 'diagnostic' >&2; exit 23"])
        }
    }

    @Test func nulDelimitedFilenamesPreserveWhitespaceAndLiteralArguments() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try await CommandRunner.git(directory.path, ["init", "--quiet"])
        let filename = " leading $(touch injected); [name]\n"
        try Data().write(to: directory.appendingPathComponent(filename))
        let output = try await CommandRunner.git(directory.path, ["ls-files", "-z", "--others"])
        #expect(output == filename + "\0")
        let echoed = try await CommandRunner.runCommand("/usr/bin/printf", ["%s", filename])
        #expect(echoed.standardOutput == filename)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("injected").path))
    }

    @Test(arguments: [false, true])
    func streamsBothOutputsBeforeExitAndCancelsTheProcessGroup(parentIgnoresTermination: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pidFile = directory.appendingPathComponent("pids")
        let received = ReceivedOutput()
        // Also cover a parent exiting before its TERM-ignoring child.
        let trap = parentIgnoresTermination ? "trap '' TERM" : "trap 'exit 0' TERM"
        let script = trap + "; /bin/sh -c 'trap \"\" TERM; /bin/sleep 30' & child=$!; printf '%s %s' \"$$\" \"$child\" > \"$1\"; printf 'stdout ready\\n'; printf 'stderr ready\\n' >&2; wait"
        let task = Task {
            try await CommandRunner.runCommand("/bin/sh", ["-c", script, "fixture", pidFile.path]) {
                await received.append($0)
            }
        }
        defer { task.cancel() }
        for _ in 0..<200 {
            if await received.containsBothStreams { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await received.containsBothStreams)
        let pids = try String(contentsOf: pidFile, encoding: .utf8).split(separator: " ").compactMap { Int32($0) }
        #expect(pids.count == 2)
        defer { if let parent = pids.first { Darwin.kill(-parent, SIGKILL) } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        for _ in 0..<200 {
            if pids.allSatisfy(hasExited) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(pids.allSatisfy(hasExited))
    }

    private func hasExited(_ pid: Int32) -> Bool {
        if Darwin.kill(pid, 0) == -1 && errno == ESRCH { return true }
        // An orphaned child may briefly remain a zombie until launchd reaps it.
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, 4, &info, &size, nil, 0) == 0 else { return false }
        return size == 0 || Int32(info.kp_proc.p_stat) == SZOMB
    }
}

private actor ReceivedOutput {
    private var text = ""
    func append(_ value: String) { text += value }
    var containsBothStreams: Bool { text.contains("stdout ready\n") && text.contains("stderr ready\n") }
}
