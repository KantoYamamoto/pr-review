import Foundation
import Testing
@testable import PRReview

@Suite("Xcode build workflows")
struct BuildServiceTests {
    @Test func metadataParsersFilterUnavailableDevicesAndPreserveNames() throws {
        #expect(try XcodeBuildOutput.parseSchemes(#"{"workspace":{"schemes":["Z","A","A"]}}"#) == ["A", "Z"])
        #expect(try XcodeBuildOutput.parseSchemes(#"{"project":{"schemes":["App"]}}"#) == ["App"])
        let output = """
        Available destinations for the "App" scheme:
          { platform:macOS, arch:arm64, id:MAC, name:My Mac }
          { platform:macOS, arch:x86_64, id:MAC, name:My Mac }
          { platform:iOS Simulator, arch:arm64, id:SIM, OS:26.0, name:iPhone, QA: device }
          { platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }
          { platform:iOS, id:PHONE, name:Connected Phone }
          { platform:iOS Simulator, id:BAD, name:Broken, error:Runtime missing }
        Ineligible destinations for the "App" scheme:
          { platform:macOS, id:BADMAC, name:Other Mac }
        """
        let destinations = XcodeBuildOutput.parseDestinations(output)
        #expect(destinations.count == 2)
        #expect(destinations.contains(BuildDestination(id: "SIM", name: "iPhone, QA: device", platform: "iOS Simulator")))
        #expect(destinations.contains(BuildDestination(id: "MAC", name: "My Mac", platform: "macOS")))
        // Xcode 27 uses a different section heading and whitespace after the opening brace.
        #expect(XcodeBuildOutput.parseDestinations("""
            Destinations compatible with the "App" scheme:
                { platform:macOS, arch:arm64,id:MAC, name:My Mac }
            Destinations incompatible with the "App" scheme:
                { platform:iOS Simulator, id:UNAVAILABLE, name:Missing runtime }
            """
        ) == [BuildDestination(id: "MAC", name: "My Mac", platform: "macOS")])
    }

    @Test func metadataUsesExplicitWorktreeContainerAndNoPackageResolution() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let probe = BuildCommandProbe(mode: .success)
        let service = fixture.service(probe)
        #expect(try await service.schemes(fixture.session) == ["App"])
        let arguments = try #require(await probe.arguments.last)
        #expect(arguments.contains("-list"))
        #expect(arguments.contains("-json"))
        #expect(arguments.contains("-disableAutomaticPackageResolution"))
        #expect(arguments.contains(fixture.session.path + "/App.xcodeproj"))
    }

    @Test(arguments: [BuildCommandProbe.Mode.success, .failure, .cancelled])
    func runsKeepLogsAndReturnOutcome(_ mode: BuildCommandProbe.Mode) async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let probe = BuildCommandProbe(mode: mode)
        let service = fixture.service(probe)
        let record = try await service.run(fixture.session, settings: fixture.settings, action: .test)
        let expected: BuildStatus = switch mode { case .success: .succeeded; case .failure: .failed; case .cancelled: .cancelled }
        #expect(record.status == expected)
        #expect(record.sha == fixture.session.sha)
        #expect(record.configuration == fixture.settings)
        #expect(!record.sourceModified)
        let log = try service.validateArtifactURL(record.logPath, session: fixture.session)
        #expect(try String(contentsOf: log, encoding: .utf8).contains("compiler output"))
        let mode = try FileManager.default.attributesOfItem(atPath: log.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let arguments = try #require(await probe.arguments.first(where: { $0.contains("test") }))
        #expect(arguments.contains("platform=iOS Simulator,id=SIM"))
        #expect(arguments.contains(try service.artifacts(for: fixture.session.id).appendingPathComponent("DerivedData").path))
        #expect(arguments.contains("-resultBundlePath"))
        #expect(!arguments.contains("install"))
        try service.removeArtifacts(for: fixture.session)
        #expect(!FileManager.default.fileExists(atPath: log.path))
    }

    @Test func changedSourcesCannotProduceVerifiedSuccess() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let inspections = BuildInspectionProbe()
        let service = XcodeBuildService(storage: fixture.directory, command: { try await BuildCommandProbe(mode: .success).run($0, $1, $2) },
                                        inspect: { _ in await inspections.next() })
        let record = try await service.run(fixture.session, settings: fixture.settings, action: .build)
        #expect(record.status == .failed)
        #expect(record.sourceModified)
    }

    @Test func initiallyDirtySourcesAreRejectedBeforeArtifactsExist() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let service = XcodeBuildService(storage: fixture.directory,
                                        inspect: { _ in InspectionReport(blockers: [.workingChanges(["M App.swift"])]) })
        await #expect(throws: ReviewError.self) {
            try await service.run(fixture.session, settings: fixture.settings, action: .build)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("Builds").path))
    }

    @Test func symlinkArtifactsAndForgedSavedPathsAreProtected() throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        let service = fixture.service(BuildCommandProbe(mode: .success))
        let outside = fixture.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: fixture.directory.appendingPathComponent("Builds"), withDestinationURL: outside)
        #expect(throws: ReviewError.self) { try service.removeArtifacts(for: fixture.session) }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(throws: ReviewError.self) { try service.validateArtifactURL(sentinel.path, session: fixture.session) }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent("Builds"))
        let run = try service.artifacts(for: fixture.session.id).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let log = run.appendingPathComponent("build.log")
        try FileManager.default.createSymbolicLink(at: log, withDestinationURL: sentinel)
        #expect(throws: ReviewError.self) { try service.validateArtifactURL(log.path, session: fixture.session) }
    }
}

private struct BuildFixture: Sendable {
    let directory: URL
    let session: Session
    let settings = BuildSettings(scheme: "App", destination: BuildDestination(id: "SIM", name: "iPhone", platform: "iOS Simulator"))
    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let id = UUID()
        let root = directory.appendingPathComponent("Worktrees", isDirectory: true).appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try Data("project".utf8).write(to: root.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        session = Session(id: id, repository: Repository(path: root.path, slug: "owner/repo", entry: "App.xcodeproj"),
                          prURL: "https://github.com/owner/repo/pull/1", number: 1, title: "PR", sha: "abc123", path: root.path)
    }
    func service(_ probe: BuildCommandProbe) -> XcodeBuildService {
        XcodeBuildService(storage: directory, command: { try await probe.run($0, $1, $2) }, inspect: { _ in InspectionReport(blockers: []) })
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

actor BuildCommandProbe {
    enum Mode: Sendable { case success, failure, cancelled }
    let mode: Mode
    var arguments: [[String]] = []
    init(mode: Mode) { self.mode = mode }
    func run(_ name: String, _ arguments: [String], _ output: CommandRunner.OutputHandler?) async throws -> CommandResult {
        self.arguments.append(arguments)
        if name == "git" { return result("abc123\n") }
        if arguments.contains("-list") { return result(#"{"project":{"schemes":["App"]}}"#) }
        await output?("compiler output\n")
        if mode == .cancelled { throw CancellationError() }
        return result("compiler output\n", code: mode == .failure ? 65 : 0)
    }
    private func result(_ text: String, code: Int32 = 0) -> CommandResult {
        CommandResult(standardOutput: text, standardError: "", exitCode: code, terminationDescription: "exit \(code)")
    }
}

private actor BuildInspectionProbe {
    var calls = 0
    func next() -> InspectionReport {
        calls += 1
        return InspectionReport(blockers: calls == 1 ? [] : [.workingChanges(["M App.swift"])])
    }
}

@Suite("Build configuration drafts")
@MainActor
struct BuildConfigurationTests {
    @Test func loadingUsesSavedSelectionAndOnlySaveChangesDefaults() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        var session = fixture.session
        session.repository.buildSettings = fixture.settings
        var state = SavedState()
        state.sessions = [session]
        state.repositories = [session.repository]
        let store = StateStore(storage: fixture.directory)
        try store.save(state)
        let builds = configurationService(fixture: fixture)
        let coordinator = ReviewCoordinator(service: ReviewService(storage: fixture.directory), buildService: builds)
        let draft = BuildConfigurationModel(session: session, coordinator: coordinator)
        #expect(draft.settings == nil)
        await draft.load()
        #expect(draft.error == nil)
        #expect(draft.settings == fixture.settings)
        draft.selectScheme("Other")
        #expect(draft.destinations.isEmpty)
        #expect(draft.destinationID.isEmpty)
        #expect(draft.settings == nil)
        #expect(!draft.save())
        #expect(try store.load().repositories.first?.buildSettings == fixture.settings)
        await draft.loadDestinations()
        #expect(draft.save())
        let saved = try store.load()
        #expect(saved.sessions.first?.repository.buildSettings?.scheme == "Other")
        #expect(saved.repositories.first?.buildSettings?.scheme == "Other")
    }

    @Test func failedReloadClearsCandidatesWithoutChangingStoredSettings() async throws {
        let fixture = try BuildFixture()
        defer { fixture.remove() }
        var state = SavedState()
        state.sessions = [fixture.session]
        let store = StateStore(storage: fixture.directory)
        try store.save(state)
        let failed = XcodeBuildService(storage: fixture.directory, command: { _, _, _ in throw ReviewError("Xcode unavailable") })
        let coordinator = ReviewCoordinator(service: ReviewService(storage: fixture.directory), buildService: failed)
        let draft = BuildConfigurationModel(session: fixture.session, coordinator: coordinator)
        await draft.load()
        #expect(draft.error?.contains("Xcode unavailable") == true)
        #expect(draft.schemes.isEmpty)
        #expect(draft.destinations.isEmpty)
        #expect(draft.settings == nil)
        #expect(!draft.save())
        #expect(try store.load().sessions.first?.repository.buildSettings == nil)
    }

    private func configurationService(fixture: BuildFixture) -> XcodeBuildService {
        XcodeBuildService(storage: fixture.directory, command: { _, arguments, _ in
            let output = arguments.contains("-list") ? #"{"project":{"schemes":["App","Other"]}}"# : """
            Available destinations for the selected scheme:
                { platform:iOS Simulator, id:SIM, name:iPhone }
            """
            return CommandResult(standardOutput: output, standardError: "", exitCode: 0, terminationDescription: "exited(0)")
        })
    }
}
