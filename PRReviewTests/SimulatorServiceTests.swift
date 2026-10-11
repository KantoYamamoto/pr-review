import Foundation
import Testing
import Synchronization
@testable import PRReview

@Suite("Review Simulator ownership and failures")
struct SimulatorServiceTests {
    @Test func creationReusesOwnedDeviceAndNeverMutatesTemplate() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe()
        let service = SimulatorService(command: { try await probe.run($0, $1, $2) })
        let owned = try await service.configuration(for: fixture.session, destination: fixture.settings.destination)
        let first = try await service.ensureDevice(owned)
        #expect(first != fixture.settings.destination.id)
        #expect(try await service.ensureDevice(owned) == first)
        try await service.launch(SimulatorApp(url: fixture.directory.appendingPathComponent("App.app"), bundleID: "dev.fixture.app"), on: owned, deviceID: first, onOutput: nil)
        try await service.remove(owned)
        let commands = await probe.commands
        #expect(commands.filter { $0.contains("create") }.count == 1)
        #expect(commands.contains { $0.contains("install") && $0.contains(first) })
        #expect(commands.contains { $0.contains("delete") && $0.contains(first) })
        let mutations = commands.filter { !$0.contains("list") }
        #expect(!mutations.contains { $0.contains(fixture.settings.destination.id) })
        #expect(!commands.contains { $0.contains("all") || $0.contains("booted") || $0.contains("clone") || $0.contains("erase") })
    }

    @Test func mismatchedRuntimeCannotDeleteOrLaunchDevice() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe()
        let service = SimulatorService(command: { try await probe.run($0, $1, $2) })
        var owned = try await service.configuration(for: fixture.session, destination: fixture.settings.destination)
        _ = try await service.ensureDevice(owned)
        owned.runtime = "com.apple.CoreSimulator.SimRuntime.iOS-99-0"
        await #expect(throws: ReviewError.self) { try await service.remove(owned) }
        #expect(!(await probe.commands).contains { $0.contains("delete") || $0.contains("shutdown") })
    }

    @Test func forgedDeviceIDAndRenamedDeviceAreProtected() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe()
        let service = SimulatorService(command: { try await probe.run($0, $1, $2) })
        var owned = try await service.configuration(for: fixture.session, destination: fixture.settings.destination)
        _ = try await service.ensureDevice(owned)
        owned.deviceID = SimulatorProbe.templateID
        await #expect(throws: ReviewError.self) { try await service.remove(owned) }
        owned.deviceID = SimulatorProbe.ownedID
        await probe.renameOwned("Renamed manually")
        await #expect(throws: ReviewError.self) { try await service.remove(owned) }
        #expect(!(await probe.commands).contains { $0.contains("delete") || $0.contains("shutdown") })
    }

    @Test @MainActor func failedDeletionRetainsOwnershipRecordForRetry() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe(failing: "delete")
        let coordinator = try fixture.coordinator(probe: probe)
        let result = try await coordinator.runOnSimulator(fixture.session)
        #expect(result.record.status == .succeeded)
        let owned = try #require(coordinator.state.simulators?.first)
        await #expect(throws: ReviewError.self) { try await coordinator.removeSimulator(owned.id) }
        #expect(coordinator.state.simulators?.first == owned)
        #expect(try StateStore(storage: fixture.directory).load().simulators?.first == owned)
    }

    @Test @MainActor func creationBeforeDeviceIDSaveIsRecoveredByExactIntentName() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe()
        _ = try fixture.coordinator(probe: probe)
        let service = SimulatorService(command: { try await probe.run($0, $1, $2) })
        let intent = try await service.configuration(for: fixture.session, destination: fixture.settings.destination)
        let store = StateStore(storage: fixture.directory)
        var saved = try store.load(); saved.simulators = [intent]; try store.save(saved)
        let created = try await service.ensureDevice(intent)
        let restarted = try fixture.coordinator(probe: probe, initialize: false)
        let result = try await restarted.runOnSimulator(fixture.session)
        #expect(result.deviceID == created)
        #expect(restarted.state.simulators?.first?.deviceID == created)
        #expect((await probe.commands).filter { $0.contains("create") }.count == 1)
    }

    @Test(arguments: ["runtime", "build", "bootstatus", "install", "launch", "cancel"])
    @MainActor
    func failuresArePersistedWithoutReportingLaunchSuccess(stage: String) async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe(failing: stage)
        let coordinator = try fixture.coordinator(probe: probe)
        let result = try await coordinator.runOnSimulator(fixture.session)
        #expect(result.deviceID == nil)
        #expect(result.record.status == (stage == "cancel" ? .cancelled : .failed))
        #expect(!result.record.message.isEmpty)
        let stored = try StateStore(storage: fixture.directory).load()
        #expect(stored.sessions.first?.simulatorLaunches?.last?.status == result.record.status)
        let commands = await probe.commands
        if ["runtime", "build"].contains(stage) { #expect(!commands.contains { $0.contains("install") || $0.contains("create") }) }
        if ["bootstatus", "install", "cancel"].contains(stage) { #expect(!commands.contains { $0.contains("launch") }) }
        if stage == "install" { #expect(result.record.message.contains("インストール")) }
        if stage == "launch" {
            #expect(stored.sessions.first?.buildRecords?.last?.status == .succeeded)
            #expect(result.record.message.contains("アプリの起動"))
        }
    }

    @Test @MainActor func creationIntentIsSavedBeforeCreateAndSurvivesRestart() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe(intentStorage: fixture.directory)
        let coordinator = try fixture.coordinator(probe: probe)
        let first = try await coordinator.runOnSimulator(fixture.session)
        #expect(first.record.status == .succeeded)
        let secondCoordinator = try fixture.coordinator(probe: probe, initialize: false)
        let second = try await secondCoordinator.runOnSimulator(fixture.session)
        #expect(first.deviceID == second.deviceID)
        #expect((await probe.commands).filter { $0.contains("create") }.count == 1)
        #expect(coordinator.state.simulators?.count == 1)
        #expect(secondCoordinator.state.sessions.first?.buildRecords?.count == 2)
        let owned = try #require(secondCoordinator.state.simulators?.first)
        try await secondCoordinator.removeSimulator(owned.id)
        #expect(secondCoordinator.state.simulators?.isEmpty == true)
    }

    @Test @MainActor func failedIntentSavePreventsCreation() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe()
        _ = try fixture.coordinator(probe: probe)
        let backing = StateStore(storage: fixture.directory)
        let store = StateStore(storage: fixture.directory, save: { state in
            if !(state.simulators ?? []).isEmpty { throw ReviewError("disk unavailable") }
            try backing.save(state)
        })
        let coordinator = fixture.makeCoordinator(probe: probe, store: store)
        let result = try await coordinator.runOnSimulator(fixture.session)
        #expect(result.record.status == .failed)
        #expect(!((await probe.commands).contains { $0.contains("create") }))
        #expect((try backing.load().simulators ?? []).isEmpty)
    }

    @Test(arguments: [false, true]) @MainActor
    func failedDeviceIDSaveRecoversWithoutCreatingAnotherDevice(restart: Bool) async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe(intentStorage: fixture.directory)
        _ = try fixture.coordinator(probe: probe)
        let backing = StateStore(storage: fixture.directory)
        let failSave = Mutex(true)
        let store = StateStore(storage: fixture.directory, save: { state in
            if state.simulators?.contains(where: { $0.deviceID != nil }) == true,
               failSave.withLock({ $0 }) { throw ReviewError("device ID save failed") }
            try backing.save(state)
        })
        let coordinator = fixture.makeCoordinator(probe: probe, store: store)
        await #expect(throws: ReviewError.self) { try await coordinator.runOnSimulator(fixture.session) }
        let owned = try #require(coordinator.state.simulators?.first)
        #expect(owned.deviceID == SimulatorProbe.ownedID)
        #expect(coordinator.hasUnsavedChanges)
        let savedIntent = try #require(backing.load().simulators?.first)
        #expect(savedIntent.id == owned.id)
        #expect(savedIntent.deviceID == nil)
        #expect(!((await probe.commands).contains { $0.contains("install") || $0.contains("launch") }))

        failSave.withLock { $0 = false }
        let recovered: ReviewCoordinator
        if restart {
            recovered = try fixture.coordinator(probe: probe, initialize: false)
        } else {
            try coordinator.retrySave()
            #expect(!coordinator.hasUnsavedChanges)
            #expect(try backing.load().simulators?.first?.deviceID == SimulatorProbe.ownedID)
            recovered = coordinator
        }
        let result = try await recovered.runOnSimulator(fixture.session)
        #expect(result.record.status == .succeeded)
        #expect(result.deviceID == SimulatorProbe.ownedID)
        #expect(try backing.load().simulators?.first?.deviceID == SimulatorProbe.ownedID)
        let commands = await probe.commands
        #expect(commands.filter { $0.contains("create") }.count == 1)
        expectOnlyOwnedDeviceMutations(commands)
    }

    @Test(arguments: [false, true]) @MainActor
    func failedSaveAfterDeletionRecoversWithoutDeletingAgain(restart: Bool) async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let probe = SimulatorProbe()
        let initial = try fixture.coordinator(probe: probe)
        #expect(try await initial.runOnSimulator(fixture.session).record.status == .succeeded)
        let owned = try #require(initial.state.simulators?.first)
        let backing = StateStore(storage: fixture.directory)
        let failSave = Mutex(true)
        let store = StateStore(storage: fixture.directory, save: { state in
            if state.simulators?.isEmpty == true, failSave.withLock({ $0 }) {
                throw ReviewError("deleted device state save failed")
            }
            try backing.save(state)
        })
        let coordinator = fixture.makeCoordinator(probe: probe, store: store)
        await #expect(throws: ReviewError.self) { try await coordinator.removeSimulator(owned.id) }
        #expect(coordinator.state.simulators?.isEmpty == true)
        #expect(coordinator.hasUnsavedChanges)
        #expect(await probe.ownedName == nil)
        #expect(try backing.load().simulators?.first == owned)

        failSave.withLock { $0 = false }
        if restart {
            let recovered = try fixture.coordinator(probe: probe, initialize: false)
            try await recovered.removeSimulator(owned.id)
            #expect(recovered.state.simulators?.isEmpty == true)
        } else {
            try coordinator.retrySave()
            #expect(!coordinator.hasUnsavedChanges)
        }
        #expect(try backing.load().simulators?.isEmpty == true)
        let commands = await probe.commands
        #expect(commands.filter { $0.contains("delete") }.count == 1)
        #expect(commands.filter { $0.contains("create") }.count == 1)
        expectOnlyOwnedDeviceMutations(commands)
    }

    @Test(.timeLimit(.minutes(1))) @MainActor
    func cancellationDuringCreationWaitsForOwnershipSaveAndAllowsReuse() async throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let gate = SimulatorCreationGate()
        let probe = SimulatorProbe(intentStorage: fixture.directory, creationGate: gate)
        let coordinator = try fixture.coordinator(probe: probe)
        let operation = Task { try await coordinator.runOnSimulator(fixture.session) }
        do {
            try await gate.waitUntilEntered()
            let savedIntent = try #require(StateStore(storage: fixture.directory).load().simulators?.first)
            #expect(savedIntent.deviceID == nil)
            operation.cancel()
            #expect(coordinator.busy)
            await #expect(throws: ReviewError.self) { try await coordinator.removeSimulator(savedIntent.id) }
            #expect(!((await probe.commands).contains { $0.contains("install") || $0.contains("delete") }))
            await gate.release()

            let result = try await operation.value
            #expect(result.record.status == .cancelled)
            #expect(result.deviceID == nil)
            #expect(!coordinator.busy)
            let saved = try StateStore(storage: fixture.directory).load()
            #expect(saved.simulators?.first?.deviceID == SimulatorProbe.ownedID)
            #expect(saved.sessions.first?.simulatorLaunches?.last?.status == .cancelled)
            #expect(!((await probe.commands).contains { $0.contains("install") || $0.contains("launch") }))

            let recovered = try fixture.coordinator(probe: probe, initialize: false)
            let next = try await recovered.runOnSimulator(fixture.session)
            #expect(next.record.status == .succeeded)
            #expect(next.deviceID == SimulatorProbe.ownedID)
            let commands = await probe.commands
            #expect(commands.filter { $0.contains("create") }.count == 1)
            expectOnlyOwnedDeviceMutations(commands)
        } catch {
            await gate.release()
            operation.cancel()
            _ = try? await operation.value
            throw error
        }
    }

    @Test func builtProductsRejectOutsidePathsSymlinksAndAmbiguousApps() throws {
        let fixture = try SimulatorFixture()
        defer { fixture.remove() }
        let derived = fixture.derivedData
        let good = try fixture.writeProduct()
        let app = try SimulatorProduct.resolve(good, derivedData: derived)
        #expect(app.bundleID == "dev.fixture.app")
        let targets = try JSONSerialization.jsonObject(with: Data(good.utf8)) as! [[String: Any]]
        let multiple = try JSONSerialization.data(withJSONObject: targets + targets)
        #expect(throws: ReviewError.self) { try SimulatorProduct.resolve(String(decoding: multiple, as: UTF8.self), derivedData: derived) }
        let outside = fixture.directory.appendingPathComponent("outside")
        #expect(throws: ReviewError.self) { try SimulatorProduct.resolve(fixture.productMetadata(directory: outside), derivedData: derived) }
        let product = app.url
        try FileManager.default.moveItem(at: product, to: outside)
        try FileManager.default.createSymbolicLink(at: product, withDestinationURL: outside)
        #expect(throws: ReviewError.self) { try SimulatorProduct.resolve(good, derivedData: derived) }
    }

    @Test func previousStateWithoutSimulatorKeysDecodes() throws {
        let data = Data(#"{"repositories":[],"sessions":[]}"#.utf8)
        let state = try JSONDecoder().decode(SavedState.self, from: data)
        #expect(state.simulators == nil)
    }
}

private func expectOnlyOwnedDeviceMutations(_ commands: [[String]]) {
    let mutations = commands.filter { $0.first == "simctl" && !$0.contains("list") && !$0.contains("create") }
    #expect(mutations.allSatisfy { $0.contains(SimulatorProbe.ownedID) && !$0.contains(SimulatorProbe.templateID) })
    #expect(!commands.contains { $0.contains("all") || $0.contains("booted") || $0.contains("erase") || $0.contains("clone") })
}

private struct SimulatorFixture: Sendable {
    let directory: URL
    let session: Session
    let settings = BuildSettings(scheme: "App", destination: BuildDestination(id: SimulatorProbe.templateID, name: "iPhone", platform: "iOS Simulator"))
    var derivedData: URL { directory.appendingPathComponent("Builds/\(session.id.uuidString)/DerivedData") }
    init() throws {
        directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let id = UUID()
        let path = directory.appendingPathComponent("Worktrees/\(id.uuidString)")
        try FileManager.default.createDirectory(at: path.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        try Data("project".utf8).write(to: path.appendingPathComponent("App.xcodeproj/project.pbxproj"))
        var repository = Repository(path: path.path, slug: "fixture/simulator", entry: "App.xcodeproj")
        repository.buildSettings = settings
        session = Session(id: id, repository: repository, prURL: "https://github.com/fixture/simulator/pull/1", number: 1, title: "Fixture", sha: "abc123", path: path.path)
    }
    @MainActor func coordinator(probe: SimulatorProbe, initialize: Bool = true) throws -> ReviewCoordinator {
        if initialize {
            var state = SavedState(); state.sessions = [session]; state.repositories = [session.repository]
            try StateStore(storage: directory).save(state)
        }
        return makeCoordinator(probe: probe)
    }
    @MainActor func makeCoordinator(probe: SimulatorProbe, store: StateStore? = nil) -> ReviewCoordinator {
        let builds = XcodeBuildService(storage: directory, command: { name, args, output in
            if args.contains("-showBuildSettings") { return SimulatorProbe.result(try writeProduct()) }
            return try await probe.run(name, args, output)
        }, inspect: { _ in InspectionReport(blockers: []) })
        return ReviewCoordinator(service: ReviewService(storage: directory), store: store, buildService: builds,
                                 simulatorService: SimulatorService(command: { try await probe.run($0, $1, $2) }))
    }
    func writeProduct() throws -> String {
        let directory = derivedData.appendingPathComponent("Build/Products/Debug-iphonesimulator")
        let app = directory.appendingPathComponent("App.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "dev.fixture.app", "CFBundleSupportedPlatforms": ["iPhoneSimulator"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Info.plist"))
        return productMetadata(directory: directory)
    }
    func productMetadata(directory: URL) -> String {
        let targets = [["buildSettings": ["PRODUCT_TYPE": "com.apple.product-type.application", "PLATFORM_NAME": "iphonesimulator",
                                          "TARGET_BUILD_DIR": directory.path, "FULL_PRODUCT_NAME": "App.app", "PRODUCT_BUNDLE_IDENTIFIER": "dev.fixture.app"]]]
        return String(decoding: try! JSONSerialization.data(withJSONObject: targets), as: UTF8.self)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}

private actor SimulatorProbe {
    static let templateID = "11111111-1111-1111-1111-111111111111"
    static let ownedID = "22222222-2222-2222-2222-222222222222"
    static let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-26-0"
    var commands: [[String]] = []
    var ownedName: String?
    var booted = false
    let failing: String?
    let intentStorage: URL?
    let creationGate: SimulatorCreationGate?
    init(failing: String? = nil, intentStorage: URL? = nil, creationGate: SimulatorCreationGate? = nil) {
        self.failing = failing; self.intentStorage = intentStorage; self.creationGate = creationGate
    }
    func renameOwned(_ name: String) { ownedName = name }
    func run(_ name: String, _ args: [String], _ output: CommandRunner.OutputHandler?) async throws -> CommandResult {
        commands.append(args)
        if name == "git" { return Self.result("abc123\n") }
        if args.contains("runtimes") {
            return Self.result(#"{"runtimes":[{"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-26-0","isAvailable":\#(failing == "runtime" ? "false" : "true")}]}"#)
        }
        if args.contains("devices") {
            func device(_ id: String, _ name: String, _ state: String) -> [String: Any] {
                ["udid": id, "name": name, "state": state, "isAvailable": true, "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-17"]
            }
            var devices = [device(Self.templateID, "iPhone", "Shutdown")]
            if let ownedName { devices.append(device(Self.ownedID, ownedName, booted ? "Booted" : "Shutdown")) }
            let data = try JSONSerialization.data(withJSONObject: ["devices": [Self.runtime: devices]])
            return Self.result(String(decoding: data, as: UTF8.self))
        }
        if let failing, args.contains(failing) { return Self.result("failure at \(failing)", code: 1) }
        if failing == "cancel", args.contains("install") { throw CancellationError() }
        if let index = args.firstIndex(of: "create") {
            ownedName = args[index + 1]
            if let intentStorage {
                let saved = try StateStore(storage: intentStorage).load()
                guard saved.simulators?.contains(where: { $0.name == ownedName }) == true else {
                    throw ReviewError("Creation without a saved ownership intent")
                }
            }
            await creationGate?.pause()
            return Self.result(Self.ownedID)
        }
        if args.contains("bootstatus") { booted = true }
        if args.contains("shutdown") { booted = false }
        if args.contains("delete") { ownedName = nil }
        await output?("simulator output\n")
        return Self.result("ok")
    }
    static func result(_ text: String, code: Int32 = 0) -> CommandResult {
        CommandResult(standardOutput: text, standardError: "", exitCode: code, terminationDescription: "exit \(code)")
    }
}

/// A cancellation-insensitive creation command, released explicitly by the test.
private actor SimulatorCreationGate {
    private var entered = false
    private var released = false
    private var entryWaiter: CheckedContinuation<Void, any Error>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async throws {
        try Task.checkCancellation()
        if entered { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { entryWaiter = continuation }
            }
        } onCancel: {
            Task { await self.cancelEntryWaiter() }
        }
    }

    private func cancelEntryWaiter() {
        entryWaiter?.resume(throwing: CancellationError())
        entryWaiter = nil
    }

    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        if released { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
